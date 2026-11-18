import Foundation
import Testing
@testable import NeSpatPrivilegeCore

@Suite struct TransportBoundaryRegressionTests {
    @Test func publicClientCannotReturnRawXPCConnection() {
        // Inspect the compiled public API without activating the blocked deployment.
        // A raw result lets a future caller bypass a transport's mandatory peer guard.
        let signature = String(reflecting: type(of: PrivilegeClient.connect))
        #expect(!signature.contains("NSXPCConnection"), "Public transport factory leaks raw XPC: \(signature)")
    }
}
