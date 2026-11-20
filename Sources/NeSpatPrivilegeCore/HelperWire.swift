import Foundation
import CoreFoundation

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
        try JSONSerialization.data(withJSONObject: ["version":1, "kind":response ? "helloReply" : "hello",
            "epoch":value.epoch.uuidString,"nonce":value.nonce.uuidString], options:[.sortedKeys])
    }
    static func decodeHello(_ bytes: Data, response: Bool = false) throws -> HelperHello {
        let f = try object(bytes, limit: 512)
        guard Set(f.keys) == ["version","kind","epoch","nonce"], version(f),
              f["kind"] as? String == (response ? "helloReply" : "hello"),
              let e = f["epoch"] as? String, let epoch = UUID(uuidString:e),
              let n = f["nonce"] as? String, let nonce = UUID(uuidString:n) else { throw PrivilegeTransportError.malformed }
        return HelperHello(epoch:epoch,nonce:nonce)
    }
    static func requestData(_ value: Request) throws -> Data {
        try value.encoded()
    }
    static func operation(_ value: Request, epoch: UUID) throws -> Data {
        try JSONSerialization.data(withJSONObject:["version":1,"epoch":epoch.uuidString,
            "request":object(requestData(value),limit:4096)],options:[.sortedKeys])
    }
    static func decodeOperation(_ bytes: Data, epoch: UUID) throws -> (Request, Data) {
        let f = try object(bytes)
        guard Set(f.keys) == ["version","epoch","request"], version(f),
              f["epoch"] as? String == epoch.uuidString, let request = f["request"] as? [String:Any] else { throw PrivilegeTransportError.malformed }
        let data = try JSONSerialization.data(withJSONObject:request,options:[.sortedKeys])
        return (try Request.decode(data), data)
    }
    static func operationReply(_ bytes: Data, id: UUID, epoch: UUID) throws -> Data {
        guard bytes.count <= 4096, let payload = try JSONSerialization.jsonObject(with: bytes) as? [String:Any] else {
            throw PrivilegeTransportError.malformed
        }
        return try JSONSerialization.data(withJSONObject:["version":1,"epoch":epoch.uuidString,
            "id":id.uuidString,"payload":payload],options:[.sortedKeys])
    }
    static func decodeReply(_ bytes: Data, id: UUID, epoch: UUID) throws -> Reply {
        let f = try object(bytes)
        guard Set(f.keys) == ["version","epoch","id","payload"], version(f),
              f["epoch"] as? String == epoch.uuidString, f["id"] as? String == id.uuidString,
              let p = f["payload"] as? [String:Any], Set(p.keys).isSubset(of:["state","session","deadline","authorityExpires","active","fullAuthority","recoveryTicket","selectedLifetime"]),
              let s = p["state"] as? String, let state = ObservedSleep(rawValue:s) else { throw PrivilegeTransportError.malformed }
        var session: UUID?, deadline: Date?
        if let value = p["session"] {
            guard let text = value as? String, let id = UUID(uuidString:text) else { throw PrivilegeTransportError.malformed }
            session = id
        }
        if let value = p["deadline"] {
            guard session != nil, let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(),
                  n.doubleValue.isFinite, abs(n.doubleValue) <= 9_007_199_254_740_992 else { throw PrivilegeTransportError.malformed }
            deadline = Date(timeIntervalSinceReferenceDate:n.doubleValue)
        }
        var expires: TimeInterval?
        if let value = p["authorityExpires"] {
            guard session != nil, let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(),
                  n.doubleValue.isFinite, n.doubleValue >= 0 else { throw PrivilegeTransportError.malformed }
            expires = n.doubleValue
        }
        var active: Bool?, full: Bool?, selected: Bool?
        for key in ["active", "fullAuthority", "selectedLifetime"] {
            if let value = p[key] {
                guard CFGetTypeID(value as CFTypeRef) == CFBooleanGetTypeID(), let flag = value as? Bool else { throw PrivilegeTransportError.malformed }
                if key == "active" { active = flag } else if key == "fullAuthority" { full = flag } else { selected = flag }
            }
        }
        var ticket: String?
        if let value = p["recoveryTicket"] {
            guard session != nil, let text = value as? String, text.utf8.count == 64,
                  text.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { throw PrivilegeTransportError.malformed }
            ticket = text
        }
        return Reply(state:state,session:session,deadline:deadline,authorityExpires:expires,active:active,fullAuthority:full,recoveryTicket:ticket,selectedLifetime:selected)
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
