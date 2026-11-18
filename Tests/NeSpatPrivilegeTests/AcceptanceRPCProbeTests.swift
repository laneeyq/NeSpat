import Foundation
import Testing
@testable import NeSpatPrivilegeCore
@Suite struct AcceptanceRPCProbeTests {
    @Test func exactNegativeReplyRequired() throws {
        let id = UUID(), epoch = UUID()
        let bytes = try HelperWire.operationReply(Data(#"{"error":"denied-or-unconfirmed"}"#.utf8), id: id, epoch: epoch)
        try AcceptanceRPCProbe.denial(bytes, id: id, epoch: epoch, malformed: false)
        #expect(throws: (any Error).self) { try AcceptanceRPCProbe.denial(bytes, id: UUID(), epoch: epoch, malformed: false) }
        #expect(throws: (any Error).self) { try AcceptanceRPCProbe.denial(bytes, id: id, epoch: UUID(), malformed: false) }
    }
    @Test func successOrSilenceNeverCountsAsDenial() {
        for bytes in [Data(), Data(#"{"state":"enabled","fullAuthority":true}"#.utf8)] {
            #expect(throws: (any Error).self) { try AcceptanceRPCProbe.denial(bytes, id: UUID(), epoch: UUID(), malformed: false) }
        }
    }
    @Test func malformedOperationMustHaveExactRejection() throws {
        try AcceptanceRPCProbe.denial(HelperWire.denied, id: UUID(), epoch: UUID(), malformed: true)
        #expect(throws: (any Error).self) { try AcceptanceRPCProbe.denial(Data(), id: UUID(), epoch: UUID(), malformed: true) }
    }
}
