import Foundation
import Testing
@testable import NeSpat

@Suite @MainActor
struct IncompleteSessionQuitTests {
    @Test func missingIdentifierBlocksQuitWithoutLosingJournal() {
        let f = Fixture(); f.active(); f.session.identifier = nil
        let model = f.model(); let journal = f.session
        #expect(!model.prepareToQuit())
        #expect(f.session == journal)
        #expect(f.calls.isEmpty)
        #expect(model.operationError != nil)
    }

    @Test(arguments: [0, 1, 2, 3, 4, 5, 6])
    func incompleteOwnedRecordNeverAllowsUnrestoredQuit(_ variant: Int) {
        for state in [SleepState.disabled, .unknown] {
            let f = Fixture(); f.active()
            switch variant {
            case 0: f.session.originalSleepDisabled = nil
            case 1: f.session.originalSleepDisabled = true
            case 2: f.session.phase = nil
            case 3: f.session.phase = .pending
            case 4: f.session.owner = nil
            case 5: f.session.identifier = nil; f.session.owner = nil; f.session.phase = nil
            default: f.session.owner?.bootID = "old-boot"
            }
            f.state = state
            let model = f.model(); let journal = f.session
            #expect(!model.prepareToQuit())
            #expect(f.session == journal)
            #expect(f.calls.isEmpty)
            #expect(model.operationError != nil)
        }
    }

    @Test func incompleteForeignLiveRecordIsNotProvenForeignOwnership() {
        let f = Fixture(); f.active(); f.session.owner?.pid = 456
        f.otherOwnerAlive = true; f.session.identifier = nil
        let model = f.model()
        #expect(!model.prepareToQuit())
        #expect(f.calls.isEmpty)
    }

    @Test func confirmedForeignLiveOwnerKeepsOriginalQuitBehavior() {
        let f = Fixture(); f.active(); f.session.owner?.pid = 456; f.otherOwnerAlive = true
        let journal = f.session; let model = f.model()
        #expect(model.prepareToQuit())
        #expect(f.session == journal)
        #expect(f.saved.isEmpty)
        #expect(f.calls.isEmpty)
    }

    @Test func inconsistentUnownedActivePhaseBlocksQuit() {
        let f = Fixture(); f.active(); f.session.owned = false
        let model = f.model()
        #expect(!model.prepareToQuit())
        #expect(f.calls.isEmpty)
    }

    @Test func confirmedOrdinarySleepAllowsIncompleteCurrentRecordToEnd() {
        let f = Fixture(); f.active(); f.session.identifier = nil; f.state = .enabled
        let model = f.model()
        #expect(model.prepareToQuit())
        #expect(!f.session.owned)
        #expect(f.calls.isEmpty)
    }

    @Test func lossOfIdentityInsideRestoreCannotPermitQuit() {
        let f = Fixture(); f.active()
        var track = false
        var reads = 0
        var deps = f.dependencies
        deps.readState = {
            if track { reads += 1; if reads == 2 { f.identityAvailable = false } }
            return f.state
        }
        let model = AppModel(testTimer: false, dependencies: deps, startTimer: false)
        track = true
        #expect(!model.prepareToQuit())
        #expect(f.calls.isEmpty)
        #expect(f.session.owned)
    }

    @Test func invalidSerializedPhaseAndMissingRequiredFlagBlockQuit() throws {
        for json in [#"{"owned":true,"pid":123,"phase":"invalid"}"#, #"{"pid":123}"#] {
            let f = Fixture(); f.state = .disabled
            var deps = f.dependencies
            deps.load = { try JSONDecoder().decode(Session.self, from: Data(json.utf8)) }
            let model = AppModel(testTimer: false, dependencies: deps, startTimer: false)
            #expect(!model.prepareToQuit())
            #expect(f.calls.isEmpty)
            #expect(model.operationError != nil)
        }
    }
}
