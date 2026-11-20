import Foundation
import NeSpatNative

public enum PrivilegeTransportError: Error, Equatable, Sendable {
    case closed, unverified, malformed, authentication, timeout, replay, canceled, busy, connection
}
struct HelperPeerCredentials: Equatable, Sendable {
    let pid: Int32
    let euid: UInt32
    var isRoot: Bool { pid > 0 && euid == 0 }
}
struct HelperChannelReply: Sendable { let bytes: Data; let peer: HelperPeerCredentials }
// Internal injection boundary, never a public peer assertion or an activation flag.
// Live implementation delivers only Foundation requirement-checked replies + OS credentials.
protocol HelperChannel: AnyObject, Sendable {
    func onFailure(_ callback: @escaping @Sendable () -> Void)
    func activate()
    func handshake(_ bytes: Data, reply: @escaping @Sendable (Result<HelperChannelReply,PrivilegeTransportError>) -> Void)
    func request(_ bytes: Data, reply: @escaping @Sendable (Result<HelperChannelReply,PrivilegeTransportError>) -> Void)
    func invalidate()
}

/// One connection epoch per instance. No raw connection/proxy, receipt or untyped RPC API.
/// Reconnection requires a new factory result and a fresh handshake; CLOSED is terminal.
public actor PrivilegeTransport {
    public enum State: UInt8, Sendable { case unverified, peerVerified, active, closed }
    private final class NativeEpoch {
        let handle = nespat_transport_new()
        deinit { nespat_transport_drop(handle) }
    }
    private let native = NativeEpoch()
    public var state: State { State(rawValue: nespat_transport_phase(native.handle)) ?? .closed }
    private let channel: any HelperChannel
    private let hello = HelperHello(epoch:UUID(),nonce:UUID())
    private let timeout: TimeInterval
    private let now: @Sendable () -> TimeInterval
    private var waiting: CheckedContinuation<Void,any Error>?
    private var operation: (id:UUID,token:UUID,continuation:CheckedContinuation<Reply,any Error>)?
    private var timer: Task<Void,Never>?
    init(channel: any HelperChannel, timeout: TimeInterval = 10,
         now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.channel=channel; self.timeout=timeout; self.now=now
    }
    deinit { timer?.cancel(); channel.invalidate() }
    public func close() { fail(.closed) }
    private func fail(_ error: PrivilegeTransportError) {
        guard state != .closed else { return }
        nespat_transport_close(native.handle); timer?.cancel(); timer=nil
        let h=waiting, op=operation; waiting=nil; operation=nil
        channel.invalidate()
        h?.resume(throwing:error); op?.continuation.resume(throwing:error)
    }
    private func armTimeout(token: UUID?) throws {
        guard nespat_transport_arm(native.handle, now(), timeout) else { throw PrivilegeTransportError.timeout }
        let interval=timeout, epoch=hello.epoch
        timer=Task { [weak self] in
            do { try await Task.sleep(for:.seconds(interval)) } catch { return }
            await self?.expired(epoch:epoch,token:token)
        }
    }
    private func expired(epoch: UUID, token: UUID?) {
        guard hello.epoch == epoch, state != .closed,
              token == operation?.token, waiting != nil || operation != nil else { return }
        fail(.timeout)
    }
    public func handshake() async throws {
        guard !Task.isCancelled else { fail(.canceled); throw PrivilegeTransportError.canceled }
        guard nespat_transport_start(native.handle) else { fail(.replay); throw PrivilegeTransportError.replay }
        do {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    waiting=continuation
                    do {
                        try armTimeout(token:nil)
                        let epoch=hello.epoch
                        channel.onFailure { [weak self] in Task { await self?.failed(epoch:epoch) } }
                        channel.activate()
                        channel.handshake(try HelperWire.hello(hello)) { [weak self] result in
                            Task { await self?.receivedHello(result,epoch:epoch) }
                        }
                    } catch { fail(.malformed) }
                }
            } onCancel: { [weak self] in Task { await self?.cancel() } }
            if Task.isCancelled { fail(.canceled); throw PrivilegeTransportError.canceled }
        } catch { throw error }
    }
    private func cancel() { fail(.canceled) }
    private func failed(epoch: UUID) { if epoch == hello.epoch { fail(.connection) } }
    private func receivedHello(_ result: Result<HelperChannelReply,PrivilegeTransportError>, epoch: UUID) {
        guard epoch == hello.epoch, state != .closed else { return }
        guard state == .unverified, let continuation=waiting else { fail(.replay); return }
        do {
            let value=try result.get()
            guard value.peer.isRoot else { throw PrivilegeTransportError.authentication }
            guard nespat_transport_timely(native.handle, now()) else { throw PrivilegeTransportError.timeout }
            guard try HelperWire.decodeHello(value.bytes,response:true) == hello else { throw PrivilegeTransportError.replay }
            guard nespat_transport_verify(native.handle, value.peer.pid, value.peer.euid) else { throw PrivilegeTransportError.authentication }
            timer?.cancel(); timer=nil; waiting=nil
            continuation.resume()
        } catch { fail((error as? PrivilegeTransportError) ?? .malformed) }
    }
    public func request(_ request: Request) async throws -> Reply {
        guard !Task.isCancelled else { fail(.canceled); throw PrivilegeTransportError.canceled }
        guard state == .peerVerified || state == .active else { fail(.unverified); throw PrivilegeTransportError.unverified }
        guard operation == nil else { fail(.busy); throw PrivilegeTransportError.busy }
        var id = request.id.uuid
        let reserved = withUnsafeBytes(of: &id) { buffer in
            nespat_transport_reserve(native.handle, buffer.bindMemory(to: UInt8.self).baseAddress!,
                                     request.heartbeatSequence != nil, Int64(request.heartbeatSequence ?? 0))
        }
        guard reserved else { fail(.replay); throw PrivilegeTransportError.replay }
        let bytes: Data
        do { bytes=try HelperWire.operation(request,epoch:hello.epoch) }
        catch { fail(.malformed); throw PrivilegeTransportError.malformed }
        let result: Reply = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let token=UUID(), epoch=hello.epoch
                operation=(request.id,token,continuation)
                do {
                    try armTimeout(token:token)
                    channel.request(bytes) { [weak self] result in
                        Task { await self?.receivedReply(result,epoch:epoch,token:token) }
                    }
                } catch { fail(.timeout) }
            }
        } onCancel: { [weak self] in Task { await self?.cancel() } }
        if Task.isCancelled { fail(.canceled); throw PrivilegeTransportError.canceled }
        return result
    }
    private func receivedReply(_ result: Result<HelperChannelReply,PrivilegeTransportError>, epoch: UUID, token: UUID) {
        guard epoch == hello.epoch, state != .closed else { return }
        guard state == .active, let current=operation, current.token == token else { fail(.replay); return }
        do {
            let value=try result.get()
            guard nespat_transport_peer(native.handle, value.peer.pid, value.peer.euid) else { throw PrivilegeTransportError.authentication }
            guard nespat_transport_timely(native.handle, now()) else { throw PrivilegeTransportError.timeout }
            let reply=try HelperWire.decodeReply(value.bytes,id:current.id,epoch:epoch)
            operation=nil; timer?.cancel(); timer=nil; current.continuation.resume(returning:reply)
        } catch { fail((error as? PrivilegeTransportError) ?? .malformed) }
    }
}

// No public initializer, raw getter or requirement-off switch. Test endpoint injection
// changes only the destination; the exact same strict helper requirement is mandatory.
final class NSXPCHelperChannel: HelperChannel, @unchecked Sendable {
    private let connection: NSXPCConnection
    private let mutex=NSLock()
    private var closed=false
    private var failure: (@Sendable () -> Void)?
    init(policy: SigningPolicy) {
        connection=NSXPCConnection(machServiceName:SigningPolicy.machService,options:.privileged)
        configure(policy)
    }
    init(endpoint: NSXPCListenerEndpoint, policy: SigningPolicy) {
        connection=NSXPCConnection(listenerEndpoint:endpoint); configure(policy)
    }
    private func configure(_ policy: SigningPolicy) {
        connection.installRequirement(policy.helperRequirement)
        connection.remoteObjectInterface=NSXPCInterface(with:VerifiedPrivilegeRPC.self)
        connection.interruptionHandler={ [weak self] in self?.broken() }
        connection.invalidationHandler={ [weak self] in self?.broken() }
    }
    func onFailure(_ callback: @escaping @Sendable () -> Void) { mutex.lock(); failure=callback; mutex.unlock() }
    func activate() { mutex.lock(); let allowed = !closed; mutex.unlock(); if allowed { connection.activate() } }
    private func broken() {
        mutex.lock(); let first = !closed; closed=true; let callback=failure; mutex.unlock()
        if first { connection.invalidate(); callback?() }
    }
    func invalidate() { mutex.lock(); closed=true; failure=nil; mutex.unlock(); connection.invalidate() }
    private func exchange(_ bytes: Data, hello: Bool, reply: @escaping @Sendable (Result<HelperChannelReply,PrivilegeTransportError>) -> Void) {
        mutex.lock(); let allowed = !closed; mutex.unlock()
        guard allowed else { reply(.failure(.closed)); return }
        guard let proxy=connection.remoteObjectProxyWithErrorHandler({ _ in reply(.failure(.connection)) }) as? VerifiedPrivilegeRPC else {
            reply(.failure(.connection)); return
        }
        let received: (Data) -> Void = { [weak self] data in
            guard let self else { reply(.failure(.closed)); return }
            self.mutex.lock(); let allowed = !self.closed; self.mutex.unlock()
            guard allowed else { reply(.failure(.closed)); return }
            do {
                // Reached only after Foundation checks helperRequirement on this reply.
                // OS credentials are never taken from the helper's Data payload.
                try PrivilegeClient.validateReplyPeer(self.connection)
                reply(.success(HelperChannelReply(bytes:data,peer:HelperPeerCredentials(
                    pid:self.connection.processIdentifier,euid:self.connection.effectiveUserIdentifier))))
            } catch { reply(.failure(.authentication)) }
        }
        if hello { proxy.handshake(bytes,reply:received) } else { proxy.request(bytes,reply:received) }
    }
    func handshake(_ bytes: Data, reply: @escaping @Sendable (Result<HelperChannelReply,PrivilegeTransportError>) -> Void) {
        exchange(bytes,hello:true,reply:reply)
    }
    func request(_ bytes: Data, reply: @escaping @Sendable (Result<HelperChannelReply,PrivilegeTransportError>) -> Void) {
        exchange(bytes,hello:false,reply:reply)
    }
}
