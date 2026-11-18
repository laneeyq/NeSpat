import Foundation
import Darwin
import Security
import Testing
@testable import NeSpatPrivilegeCore

// Read-only identity of this ordinary-user test executable, a fixture selected by the
// test itself. Production has NO "read arbitrary file then trust it" enrollment path.
func executablePinFixture() throws -> ExactCodePin {
    var code: SecStaticCode?, information: CFDictionary?
    let url=URL(fileURLWithPath:CommandLine.arguments[0])
    try #require(SecStaticCodeCreateWithPath(url as CFURL,[],&code) == errSecSuccess)
    let signed=try #require(code)
    try #require(SecStaticCodeCheckValidity(signed,SecCSFlags(rawValue:kSecCSStrictValidate),nil) == errSecSuccess)
    try #require(SecCodeCopySigningInformation(signed,[],&information) == errSecSuccess)
    let fields=try #require(information as? [String:Any])
    let hash=try #require(fields[kSecCodeInfoUnique as String] as? Data)
    let id=try #require(fields[kSecCodeInfoIdentifier as String] as? String)
    return try ExactCodePin(codeDirectoryHash:hash.map {String(format:"%02x",$0)}.joined(),signingIdentifier:id)
}
private final class PinProbeState: @unchecked Sendable {
    private let mutex=NSLock()
    private var delegates=0, calls=0
    private var response: Data?, failure=false
    func accepted() {mutex.lock();delegates += 1;mutex.unlock()}
    func called() {mutex.lock();calls += 1;mutex.unlock()}
    func received(_ data: Data) {mutex.lock();response=data;mutex.unlock()}
    func failed() {mutex.lock();failure=true;mutex.unlock()}
    var result: (Int,Int,Data?,Bool) {mutex.lock();defer{mutex.unlock()};return(delegates,calls,response,failure)}
}
private final class PinEcho: NSObject, HelperHandshakeRPC {
    weak var connection: NSXPCConnection?
    let state: PinProbeState
    init(_ c:NSXPCConnection,_ state:PinProbeState) {connection=c;self.state=state}
    func handshake(_ bytes:Data,reply:@escaping(Data)->Void) {
        // OS credentials are independent of pin/JSON; this is explicitly NONROOT acceptance.
        guard let connection, NSXPCConnection.current() === connection, connection.processIdentifier == getpid(),
              connection.effectiveUserIdentifier == getuid(), connection.auditSessionIdentifier > 0 else {
            state.failed();reply(HelperWire.denied);return
        }
        state.called();reply(bytes)
    }
}
private final class PinListener: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    let pin: ExactCodePin, state: PinProbeState
    private let mutex=NSLock()
    private var connections:[NSXPCConnection]=[]
    init(_ pin:ExactCodePin,_ state:PinProbeState) {self.pin=pin;self.state=state}
    func listener(_ listener:NSXPCListener,shouldAcceptNewConnection c:NSXPCConnection)->Bool {
        state.accepted();pin.requirePeer(on:c)
        c.exportedInterface=NSXPCInterface(with:HelperHandshakeRPC.self);c.exportedObject=PinEcho(c,state)
        mutex.lock();connections.append(c);mutex.unlock();c.activate();return true
    }
    func close() {mutex.lock();let all=connections;connections.removeAll();mutex.unlock();all.forEach{$0.invalidate()}}
}

@Suite struct ExactCodePinTests {
    @Test func noKeyOrCertificateIsNeededToMatchOneCurrentCodeVersion() throws {
        let pin=try executablePinFixture(), file=URL(fileURLWithPath:CommandLine.arguments[0])
        #expect(pin.codeDirectoryHash.count == 40 && pin.matchesFile(file))
        let strict=try SigningPolicy(teamID:"ABCDE12345")
        #expect(!strict.matchesFile(file,helper:true))
        let wrong=try ExactCodePin(codeDirectoryHash:pin.codeDirectoryHash,signingIdentifier:"other.identifier")
        #expect(!wrong.matchesFile(file))
        let changed=try ExactCodePin(codeDirectoryHash:String(repeating:"0",count:40),signingIdentifier:pin.signingIdentifier)
        #expect(!changed.matchesFile(file))
    }
    @Test func malformedPinsAndIdentifiersCannotCompileBroaderRequirement() throws {
        for hash in ["",String(repeating:"a",count:39),String(repeating:"a",count:41),String(repeating:"g",count:40),String(repeating:"a",count:40)+"\" or true"] {
            #expect(throws:PrivilegeError.blocked) {try ExactCodePin(codeDirectoryHash:hash,signingIdentifier:"local.app")}
        }
        for id in ["","local.app\" or true","/tmp/app","a b",String(repeating:"a",count:256)] {
            #expect(throws:PrivilegeError.blocked) {try ExactCodePin(codeDirectoryHash:String(repeating:"a",count:40),signingIdentifier:id)}
        }
    }
    @Test func replacementUnsignedAndTamperedCopiesAreRejectedWithoutChangingTrust() throws {
        let pin=try executablePinFixture(), repo=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let dir=repo.appendingPathComponent(".build/v76-pins/\(UUID())")
        try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
        defer{try? FileManager.default.removeItem(at:dir)}
        let file=dir.appendingPathComponent("copy")
        let original=try Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[0]))
        try original.write(to:file);#expect(pin.matchesFile(file)) // Same approved bytes, not same pathname.
        var corrupted=original;corrupted[0] ^= 1;try corrupted.write(to:file);#expect(!pin.matchesFile(file))
        try Data("unsigned replacement, never executed".utf8).write(to:file);#expect(!pin.matchesFile(file))
        let unchanged=try executablePinFixture()
        #expect(pin.codeDirectoryHash == unchanged.codeDirectoryHash)
    }
    private func exchange(listenerPin:ExactCodePin,clientPin:ExactCodePin) async throws -> (Int,Int,Data?,Bool) {
        let state=PinProbeState(),delegate=PinListener(listenerPin,state),listener=NSXPCListener.anonymous()
        listenerPin.requireClients(on:listener);listener.delegate=delegate;listener.activate()
        let c=NSXPCConnection(listenerEndpoint:listener.endpoint);clientPin.requirePeer(on:c)
        c.remoteObjectInterface=NSXPCInterface(with:HelperHandshakeRPC.self)
        c.invalidationHandler={state.failed()};c.interruptionHandler={state.failed()};c.activate()
        defer{c.invalidate();delegate.close();listener.invalidate()}
        let proxy=try #require(c.remoteObjectProxyWithErrorHandler{_ in state.failed()} as? HelperHandshakeRPC)
        proxy.handshake(Data("public-pin-probe".utf8)) {data in
            #expect(c.processIdentifier == getpid() && c.effectiveUserIdentifier == getuid())
            #expect(c.effectiveUserIdentifier != 0) // No root-positive scenario is executed.
            state.received(data)
        }
        try await waitForTransport{state.result.2 != nil || state.result.3}
        return state.result
    }
    @Test func actualMutualPinAndOSCredentialsAcceptOnlySelectedNonrootFixture() async throws {
        let pin=try executablePinFixture(), result=try await exchange(listenerPin:pin,clientPin:pin)
        #expect(result.0 == 1 && result.1 == 1 && result.2 == Data("public-pin-probe".utf8))
    }
    @Test(arguments:[false,true]) func actualWrongPinOrIdentifierCannotReachListenerDelegate(_ wrongID:Bool) async throws {
        let pin=try executablePinFixture(), bad=try ExactCodePin(codeDirectoryHash:wrongID ? pin.codeDirectoryHash : String(repeating:"0",count:40),
            signingIdentifier:wrongID ? "other.identifier" : pin.signingIdentifier)
        let result=try await exchange(listenerPin:bad,clientPin:pin)
        #expect(result.0 == 0 && result.1 == 0 && result.2 == nil && result.3)
    }
    @Test func actualClientRejectsUnapprovedHelperPin() async throws {
        let pin=try executablePinFixture(), bad=try ExactCodePin(codeDirectoryHash:String(repeating:"0",count:40),signingIdentifier:pin.signingIdentifier)
        let result=try await exchange(listenerPin:pin,clientPin:bad)
        #expect(result.2 == nil && result.3)
    }
}
