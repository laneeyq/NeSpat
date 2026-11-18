import Foundation
import Testing
@testable import NeSpat

@Suite @MainActor
struct JournalLossQuitTests {
    @Test(arguments: [SleepState.disabled, .unknown])
    func emptyReplacementKeepsQuitBlockedAcrossTicks(_ state: SleepState) {
        let f = Fixture(); f.active(); let model = f.model()
        f.session = Session(); f.state = state
        model.tick(); model.tick()
        #expect(!model.prepareToQuit())
        #expect(!model.prepareToQuit())
        #expect(f.calls.isEmpty)
        #expect(f.saved.isEmpty)
        #expect(model.operationError != nil)
        #expect(model.menuTitle.hasPrefix("⚠"))
    }

    @Test(arguments: [SleepState.disabled, .unknown])
    func actualJournalDisappearanceBlocksQuit(_ state: SleepState) throws {
        let base = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let dir = base.appendingPathComponent(".build/journal-loss-tests/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("session.json")
        let f = Fixture(); f.active(); try SessionStore.save(f.session, to: file)
        var deps = f.dependencies
        deps.load = { try SessionStore.load(from: file) }
        deps.save = { try SessionStore.save($0, to: file) }
        let model = AppModel(testTimer: false, dependencies: deps, startTimer: false)
        try FileManager.default.removeItem(at: file)
        f.state = state
        model.tick()
        #expect(!model.prepareToQuit())
        #expect(f.calls.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test func directQuitDetectsLossWithoutTimer() {
        let f = Fixture(); f.active(); let model = f.model()
        f.session = Session()
        #expect(!model.prepareToQuit())
        #expect(f.calls.isEmpty)
    }
    @Test func reappearingRecordCannotSilentlyRecoverAuthority() {
        let f = Fixture(); f.active(); let original = f.session; let model = f.model()
        f.session = Session(); model.tick()
        f.session = original; f.session.until = f.now.addingTimeInterval(-1)
        model.tick()
        #expect(!model.prepareToQuit())
        #expect(f.calls.isEmpty)
        model.forceRestoreSleep()
        #expect(f.state == .enabled)
        #expect(model.prepareToQuit())
    }

    @Test func replacementUUIDCannotAuthorizeAutomaticRestore() {
        let f = Fixture(); f.active(); let model = f.model()
        f.session.identifier = UUID(); f.session.until = f.now.addingTimeInterval(-1)
        model.tick()
        #expect(!model.prepareToQuit())
        #expect(f.calls.isEmpty)
    }

    @Test func observedOrdinarySleepResolvesLoss() {
        let f = Fixture(); f.active(); let model = f.model()
        f.session = Session(); model.tick()
        #expect(!model.prepareToQuit())
        f.state = .enabled; model.tick()
        #expect(model.operationError == nil)
        #expect(model.prepareToQuit())
        #expect(f.calls.isEmpty)
    }

    @Test func canceledExplicitRecoveryDoesNotClearHistory() {
        let f = Fixture(); f.active(); let model = f.model()
        f.session = Session(); model.tick()
        f.outcome = .canceled; model.forceRestoreSleep()
        model.tick()
        #expect(!model.prepareToQuit())
        #expect(f.calls.count == 1)
        #expect(f.state == .disabled)
    }

    @Test func foreignObserverAndConfirmedForeignSuccessorCanQuitWithoutMutation() {
        let f = Fixture(); f.active(); f.session.owner?.pid = 456; f.otherOwnerAlive = true
        let model = f.model(); let foreign = f.session
        #expect(model.prepareToQuit())
        #expect(f.session == foreign)
        #expect(f.saved.isEmpty)
        #expect(f.calls.isEmpty)

        let owner = Fixture(); owner.active(); let ownModel = owner.model()
        owner.session = Session(); ownModel.tick()
        owner.session = foreign; owner.otherOwnerAlive = true
        let writes = owner.saved.count
        #expect(ownModel.prepareToQuit())
        #expect(owner.saved.count == writes)
        #expect(owner.session == foreign)
        #expect(owner.calls.isEmpty)
    }

    @Test func lostIdentityCannotEraseRememberedOwnership() {
        let f = Fixture(); f.active(); let model = f.model()
        f.identityAvailable = false; f.session = Session()
        model.tick()
        #expect(!model.prepareToQuit())
        f.identityAvailable = true; model.tick()
        #expect(!model.prepareToQuit())
        #expect(f.calls.isEmpty)
    }

    @Test(arguments: [0, 1])
    func incompleteLocalClaimCannotDisappearIntoObserverState(_ variant: Int) {
        let f = Fixture(); f.active()
        if variant == 0 { f.session.phase = .pending }
        else { f.session.identifier = nil }
        let model = f.model()
        f.session = Session(); model.tick(); model.tick()
        #expect(!model.prepareToQuit())
        #expect(f.calls.isEmpty)
    }

}
