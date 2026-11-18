import Foundation
import Testing
@testable import NeSpat
@testable import NeSpatPrivilegeCore

// No live invoker: fake receives ONLY the same allowlisted constant used by the GUI plan.
private struct EmergencyPlanProbe: FixedPowerInvoking {
    let performPlan:(FixedPowerInvocation)->Int32
    func perform(_ plan:FixedPowerInvocation) throws ->Int32 {performPlan(plan)}
}
@Suite @MainActor struct EmergencyReceiptTests {
    private func directory() throws ->URL {
        let root=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let dir=root.appendingPathComponent(".build/v77-receipts/\(UUID())")
        try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true);return dir
    }
    private func dependencies(_ f:Fixture) ->EmergencySleep.Dependencies {
        let d=f.dependencies
        return .init(lock:d.lock,load:d.load,save:d.save,identity:d.identity,readState:d.readState,
            snapshot:{.init(sample:f.sample,thermalSerious:f.thermal)},restore:{d.setSleep(false,false)},
            request:{f.emergencyRequests += 1;return f.emergencyResult},now:d.now)
    }
    @Test(arguments:[0,1,2]) func actualReceiptRecordsRequestFailedOrBlockedAndReason(_ variant:Int) throws {
        let f=Fixture();f.active();f.sample.temperatureC=95
        if variant == 1 {f.emergencyResult = .failed}
        if variant == 2 {f.emergencyResult = .blocked}
        let id=try #require(f.session.identifier),dir=try directory(),file=dir.appendingPathComponent("result.json")
        defer {try? FileManager.default.removeItem(at:dir)}
        var d=dependencies(f)
        d.recordResult={try EmergencyReceiptStore.save(.init(session:$0,result:$1,recordedAt:$2),to:file)}
        let result=EmergencySleep.run(expectedSession:id,dependencies:d)
        let stored=try JSONDecoder().decode(EmergencyReceipt.self,from:Data(contentsOf:file))
        #expect(stored.session == id && stored.recordedAt == f.now)
        #expect(stored.outcome == (variant == 0 ? .requested : .failure) && stored.message.contains("сон"))
        #expect(stored.message.contains("95"))
        #expect(stored == EmergencyReceipt(session:id,result:result,recordedAt:f.now))
        #expect(f.state == .enabled && !f.session.owned && f.emergencyRequests == 1)
        #expect((try FileManager.default.attributesOfItem(atPath:file.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }
    @Test func fixedEmergencyPlanRunsOnlyAfterIndependentNoAndFinalCriticalCheck() throws {
        let f=Fixture();f.active();f.thermal=true
        let id=try #require(f.session.identifier);var d=dependencies(f),plans:[FixedPowerInvocation]=[]
        let fake=EmergencyPlanProbe {plan in
            #expect(f.held && f.state == .enabled && !f.session.owned && f.session.emergencyAttempt != nil)
            #expect(SafetyPolicy.emergencyReason(sample:f.sample,thermalSerious:f.thermal) != nil)
            plans.append(plan);return 0
        }
        d.request={ (try? fake.perform(EmergencySleep.invocation)) == 0 ? .requested : .failed }
        guard case .requested = EmergencySleep.run(expectedSession:id,dependencies:d) else {Issue.record("Mock request failed");return}
        #expect(plans == [.emergencySleep] && plans.first?.arguments == ["sleepnow"])
        #expect(f.calls.map(\.disabled) == [false])
    }
    @Test func receiptFailureDoesNotRepeatRequestOrEraseRecoveryEvidence() {
        let f=Fixture();f.active();f.thermal=true;let id=f.session.identifier!
        var d=dependencies(f);d.recordResult={_,_,_ in throw CocoaError(.fileWriteNoPermission)}
        guard case .failure(let message,_) = EmergencySleep.run(expectedSession:id,dependencies:d) else {Issue.record("Write error hidden");return}
        #expect(message.contains("отчёт") && f.state == .enabled && !f.session.owned && f.emergencyRequests == 1)
        #expect(EmergencySleep.run(expectedSession:id,dependencies:d) == .skipped && f.emergencyRequests == 1)
        let g=Fixture();g.active();g.thermal=true;g.applyState=false;var failed=dependencies(g)
        failed.recordResult=d.recordResult
        guard case .failure(_,let retry?) = EmergencySleep.run(expectedSession:g.session.identifier!,dependencies:failed) else {Issue.record("Cooldown lost");return}
        #expect(g.session.owned && g.session.retryAfter == retry && g.emergencyRequests == 0)
    }
    @Test(arguments:[SleepState.disabled,.unknown]) func diagnosticReceiptCannotAuthorizeRecoveryAfterJournalLoss(_ state:SleepState) {
        let f=Fixture();f.active();let model=f.model()
        let old=f.session.identifier!;f.session=Session();f.state=state
        // Even a forged successful diagnostic report is not passed into the model's authority path.
        let forged=EmergencyReceipt(session:old,result:.requested("untrusted diagnostic"),recordedAt:f.now)
        #expect(forged.outcome == .requested)
        model.tick();#expect(!model.prepareToQuit() && f.calls.isEmpty && model.status != .off)
    }
}
