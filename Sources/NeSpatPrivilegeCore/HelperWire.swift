import Foundation
import CoreFoundation
import NeSpatNative

// Separate non-secret handshake: status is deliberately NOT used because it enrolls.
@objc public protocol HelperHandshakeRPC {
    func handshake(_ bytes: Data, reply: @escaping (Data) -> Void)
}
@objc public protocol VerifiedPrivilegeRPC: PrivilegeRPC, HelperHandshakeRPC {}

struct HelperHello: Equatable, Sendable {
    let epoch: UUID
    let nonce: UUID // Public correlation value, never consent or authority.
}
enum HelperWire {
    static func object(_ bytes: Data, limit: Int = 8192) throws -> [String: Any] {
        guard bytes.count <= limit, let fields = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]) == bytes else {
            throw PrivilegeTransportError.malformed
        }
        return fields // Canonical equality also rejects duplicate keys.
    }
    static func version(_ fields: [String: Any]) -> Bool {
        guard let n = fields["version"] as? NSNumber else { return false }
        return CFGetTypeID(n) != CFBooleanGetTypeID() && n.stringValue == "1"
    }
    static func hello(_ value: HelperHello, response: Bool = false) throws -> Data {
        var fields = NeSpatHello(epoch: value.epoch.uuid, nonce: value.nonce.uuid)
        return nespat_hello(&fields, response) as Data
    }
    static func decodeHello(_ bytes: Data, response: Bool = false) throws -> HelperHello {
        var fields = NeSpatHello()
        guard nespat_read_hello(bytes as CFData, response, &fields) else { throw PrivilegeTransportError.malformed }
        return HelperHello(epoch: UUID(uuid: fields.epoch), nonce: UUID(uuid: fields.nonce))
    }
    static func requestData(_ value: Request) throws -> Data { try value.encoded() }
    private static func envelope(_ bytes: Data, epoch: UUID, unwrap: Bool) throws -> Data {
        var id = epoch.uuid
        return try withUnsafeBytes(of: &id) { buffer in
            guard let result = nespat_operation(bytes as CFData, buffer.bindMemory(to: UInt8.self).baseAddress!, unwrap) else {
                throw PrivilegeTransportError.malformed
            }
            return result as Data
        }
    }
    static func operation(_ value: Request, epoch: UUID) throws -> Data {
        try envelope(requestData(value), epoch: epoch, unwrap: false)
    }
    static func decodeOperation(_ bytes: Data, epoch: UUID) throws -> (Request, Data) {
        let data = try envelope(bytes, epoch: epoch, unwrap: true)
        return (try Request.decode(data), data)
    }
    private static func replyPayload(_ bytes: Data, id: UUID, epoch: UUID, unwrap: Bool) throws -> Data {
        var key = NeSpatCorrelation(epoch: epoch.uuid, id: id.uuid)
        guard let result = nespat_reply(bytes as CFData, &key, unwrap) else { throw PrivilegeTransportError.malformed }
        return result as Data
    }
    static func operationReply(_ bytes: Data, id: UUID, epoch: UUID) throws -> Data {
        try replyPayload(bytes, id: id, epoch: epoch, unwrap: false)
    }
    static func decodeReply(_ bytes: Data, id: UUID, epoch: UUID) throws -> Reply {
        let data = try replyPayload(bytes, id: id, epoch: epoch, unwrap: true)
        guard let reply = try? JSONDecoder().decode(Reply.self, from: data) else { throw PrivilegeTransportError.malformed }
        return reply
    }
    static let denied = Data(#"{"error":"denied-or-unconfirmed"}"#.utf8)
}

// Outer protocol gate only; the existing engine/authenticated endpoint remains unchanged.
// This class is exported by the blocked production listener, never by GUI or helper main.
final class HandshakingPrivilegeEndpoint: NSObject, VerifiedPrivilegeRPC, @unchecked Sendable {
    private weak var connection: NSXPCConnection?
    private let installedClientUID: UInt32?
    private let policy: SigningPolicy
    private let engine: PrivilegeEngine
    private let enrollment: (EnrollmentChallenge) -> EnrollmentAuthorization?
    private let mutex = NSLock()
    private var hello: HelperHello?
    private var credentials: HelperPeerCredentials?
    private var audit: UInt32?
    private var closed = false
    private var endpoint: AuthenticatedPrivilegeEndpoint?
    init(connection: NSXPCConnection, policy: SigningPolicy, engine: PrivilegeEngine,
         enrollment: @escaping (EnrollmentChallenge) -> EnrollmentAuthorization?, installedClientUID: UInt32? = nil) {
        self.installedClientUID = installedClientUID
        self.connection=connection; self.policy=policy; self.engine=engine; self.enrollment=enrollment
    }
    private func caller() -> NSXPCConnection? {
        guard let c = connection, c.isCurrentClient(installedUID: installedClientUID) else { return nil }
        return c
    }
    func handshake(_ bytes: Data, reply: @escaping (Data) -> Void) {
        mutex.lock()
        do {
            guard !closed, hello == nil, let c=caller() else { throw PrivilegeTransportError.authentication }
            let value=try HelperWire.decodeHello(bytes)
            let response=try HelperWire.hello(value,response:true)
            hello=value; credentials=HelperPeerCredentials(pid:c.processIdentifier,euid:c.effectiveUserIdentifier)
            audit=UInt32(c.auditSessionIdentifier)
            mutex.unlock(); reply(response) // No enrollment, engine call or authority issued.
        } catch { mutex.unlock(); close(); reply(HelperWire.denied) }
    }
    func request(_ bytes: Data, reply: @escaping (Data) -> Void) {
        mutex.lock()
        do {
            guard !closed, let hello, let c=caller(),
                  credentials == HelperPeerCredentials(pid:c.processIdentifier,euid:c.effectiveUserIdentifier),
                  audit == UInt32(c.auditSessionIdentifier) else { throw PrivilegeTransportError.authentication }
            let (request,data)=try HelperWire.decodeOperation(bytes,epoch:hello.epoch)
            if endpoint == nil { endpoint=AuthenticatedPrivilegeEndpoint(connection:c,policy:policy,engine:engine,enrollment:enrollment) }
            let target=endpoint!
            mutex.unlock()
            target.request(data) { [weak self] response in
                guard let self else { reply(HelperWire.denied); return }
                self.mutex.lock(); let usable = !self.closed && self.hello == hello; self.mutex.unlock()
                guard usable, let wrapped=try? HelperWire.operationReply(response,id:request.id,epoch:hello.epoch) else {
                    self.close(); reply(HelperWire.denied); return
                }
                reply(wrapped)
            }
        } catch { mutex.unlock(); close(); reply(HelperWire.denied) }
    }
    func close() {
        mutex.lock(); closed=true; hello=nil; credentials=nil; audit=nil; let target=endpoint; mutex.unlock()
        target?.close()
    }
}
