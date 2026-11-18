import Foundation

/// Fixed negative probes only, gated by the protected acceptance profile and exact running GUI pin.
/// Uses the same strict channel (OS root credentials + helper code requirement), never a raw proxy.
public enum AcceptanceRPCProbe {
    static func denial(_ bytes: Data, id: UUID, epoch: UUID, malformed: Bool) throws {
        if malformed {
            guard bytes == HelperWire.denied else { throw PrivilegeError.unconfirmed }
        } else {
            let object = try HelperWire.object(bytes)
            guard Set(object.keys) == ["version", "epoch", "id", "payload"], HelperWire.version(object),
                  object["epoch"] as? String == epoch.uuidString, object["id"] as? String == id.uuidString,
                  let payload = object["payload"] as? [String: Any], Set(payload.keys) == ["error"],
                  payload["error"] as? String == "denied-or-unconfirmed" else { throw PrivilegeError.unconfirmed }
        }
    }
    public static func run() async throws {
        let profile = try LocalTrustProfile.load()
        guard profile.acceptanceOnly, profile.allowedUID == getuid(),
              profile.guiPin.matchesHardenedFile(Bundle.main.bundleURL) else { throw PrivilegeError.blocked }
        let names = Operation.allProbeOperations
        for name in names + ["sleepnow", "setDisabled"] {
            let channel = NSXPCHelperChannel(policy: try profile.policy)
            defer { channel.invalidate() }
            channel.activate()
            let hello = HelperHello(epoch: UUID(), nonce: UUID()), id = UUID()
            let response = try await exchange(channel, try HelperWire.hello(hello), hello: true)
            guard response.peer.isRoot, try HelperWire.decodeHello(response.bytes, response: true) == hello else { throw PrivilegeError.denied }
            var request: [String: Any] = ["version": 1, "id": id.uuidString, "operation": name]
            if ["changeDeadline", "end", "recover", "heartbeat", "pollRecovery"].contains(name) { request["session"] = UUID().uuidString }
            let bytes = try JSONSerialization.data(withJSONObject: ["version": 1, "epoch": hello.epoch.uuidString, "request": request], options: [.sortedKeys])
            let reply = try await exchange(channel, bytes, hello: false)
            guard reply.peer == response.peer else { throw PrivilegeError.denied }
            try denial(reply.bytes, id: id, epoch: hello.epoch, malformed: !names.contains(name))
            print("VERIFIED acceptance RPC denied: \(name); helper PID=\(reply.peer.pid) EUID=\(reply.peer.euid)")
        }
    }
    private static func exchange(_ channel: NSXPCHelperChannel, _ data: Data, hello: Bool) async throws -> HelperChannelReply {
        try await withCheckedThrowingContinuation { continuation in
            let once = ProbeOnce(continuation)
            channel.onFailure { once.finish(.failure(.connection)) }
            DispatchQueue.global().asyncAfter(deadline: .now() + 10) { once.finish(.failure(.timeout)) }
            if hello { channel.handshake(data, reply: once.finish) } else { channel.request(data, reply: once.finish) }
        }
    }
}
private extension Operation {
    static let allProbeOperations = ["status", "begin", "changeDeadline", "end", "recover", "revoke", "heartbeat", "pollRecovery"]
}
private final class ProbeOnce: @unchecked Sendable {
    let lock = NSLock()
    var continuation: CheckedContinuation<HelperChannelReply, any Error>?
    init(_ continuation: CheckedContinuation<HelperChannelReply, any Error>) { self.continuation = continuation }
    func finish(_ result: Result<HelperChannelReply, PrivilegeTransportError>) {
        lock.lock(); let next = continuation; continuation = nil; lock.unlock()
        next?.resume(with: result.mapError { $0 as any Error })
    }
}
