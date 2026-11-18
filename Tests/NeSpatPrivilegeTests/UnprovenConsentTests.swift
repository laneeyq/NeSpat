import Foundation
import Testing
@testable import NeSpatPrivilegeCore

@Suite struct UnprovenConsentTests {
    @Test(arguments:["GUI says yes","cached right","preauthorized right"])
    func unprovenConsentCannotBecomeFullAuthority(_ claim:String) throws {
        let f=PrivilegeFixture(), c=try f.engine.enrollmentChallenge(for:f.peer)
        #expect(throws:PrivilegeError.blocked) {try SystemConsentVerifier.authorize(c)}
        #expect(throws:PrivilegeError.denied) {try f.engine.admit(f.peer,expires:f.uptime+100)}
        let bytes=try JSONSerialization.data(withJSONObject:["version":1,"id":UUID().uuidString,
            "operation":"begin","consent":claim,"confirmedAt":f.uptime,"expires":f.uptime+100],options:[.sortedKeys])
        #expect(throws:PrivilegeError.malformed) {try Request.decode(bytes)}
        #expect(throws:PrivilegeError.denied) {try f.engine.handle(Request(operation:.begin),from:f.peer)}
        #expect(f.changes.isEmpty && f.journal.writes == 0)
    }
    @Test func canceledVerifierDoesNotUseLifetimePolicyAsConsent() throws {
        let f=PrivilegeFixture(), endpoint=PrivilegeEndpoint(engine:f.engine,peer:f.peer,enrollment:{_ in nil})
        endpoint.request(try HelperWire.requestData(Request(operation:.begin))) {#expect($0 == HelperWire.denied)}
        #expect(throws:PrivilegeError.denied) {try f.engine.handle(Request(operation:.begin),from:f.peer)}
        #expect(f.changes.isEmpty && f.journal.writes == 0)
    }
}
