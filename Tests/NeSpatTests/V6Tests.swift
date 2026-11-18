import Foundation
import Testing
@testable import NeSpat

@Suite @MainActor struct V6Tests {
    @Test func damagedDurationCanBeExplicitlyRestored() {
        let f = Fixture(); f.active(); f.session.durationSeconds = 0
        let model = f.model(); model.forceRestoreSleep()
        #expect(f.calls.count == 1)
        #expect(f.state == .enabled)
        #expect(!f.session.owned)
    }
    @Test(arguments: [false, true]) func invalidTextPreservesPowerStatus(_ active: Bool) {
        let f = Fixture(); if active { f.active() }
        let model = f.model(); let status = model.status; let original = f.session
        model.applyCustomMinutes("0")
        #expect(model.status == status)
        #expect(model.canToggleMode)
        #expect(f.session == original)
        model.applyCustomMinutes("35")
        #expect(model.operationError == nil)
    }
    @Test func selectionSurvivesCompletedSession() {
        let f = Fixture(); let model = f.model()
        model.applyCustomMinutes("35"); model.toggle(true); model.toggle(false)
        let restarted = f.model()
        #expect(restarted.customMinutes == 35)
        #expect(restarted.duration == .custom)
    }
    @Test(arguments: ["0", "-1", "1.5", "text"])
    func inputErrorIsFieldLocalAndClears(_ input: String) {
        let f = Fixture(); f.active(); let model = f.model(); let before = f.session
        model.applyCustomMinutes(input)
        #expect(model.durationError != nil)
        #expect(model.operationError == nil)
        #expect(model.status == .on && model.canToggleMode)
        #expect(!model.showsRestoreAction)
        #expect(f.session == before)
        model.applyCustomMinutes("35")
        #expect(model.durationError == nil)
        #expect(f.session.until == f.now.addingTimeInterval(2100))
    }

    @Test func offPreferenceAndCorruptionAreIndependentOfOwnership() {
        let f = Fixture(); let model = f.model(); model.applyCustomMinutes("165")
        let restarted = f.model()
        #expect(restarted.customMinutes == 165 && restarted.duration == .custom)
        #expect(f.session == Session())
        #expect(f.calls.isEmpty && f.saved.isEmpty)
        f.preference = "custom:99999999999999999999999999"
        let corrupt = f.model()
        #expect(corrupt.status == .off)
        #expect(corrupt.duration == .none)
        #expect(corrupt.durationError != nil)
        #expect(f.calls.isEmpty)
        f.preference = nil; #expect(f.model().duration == .none)
    }

    @Test func realDefaultsAdapterAndActiveDeadline() throws {
        let suite = "NeSpat.v6.tests.\(UUID().uuidString)"
        let prefs = try #require(UserDefaults(suiteName: suite))
        defer { prefs.removePersistentDomain(forName: suite) }
        let f = Fixture(); var deps = f.dependencies
        deps.loadPreference = { prefs.string(forKey: "choice") }
        deps.savePreference = { prefs.set($0, forKey: "choice") }
        let first = AppModel(testTimer: true, dependencies: deps, startTimer: false)
        first.applyCustomMinutes("165")
        let next = AppModel(testTimer: true, dependencies: deps, startTimer: false)
        #expect(next.customMinutes == 165)
        next.toggle(true); next.applyCustomMinutes("35")
        let deadline = f.session.until; f.now = f.now.addingTimeInterval(10)
        let active = AppModel(testTimer: true, dependencies: deps, startTimer: false)
        #expect(active.countdownDeadline == deadline)
        active.toggle(false)
        let ended = AppModel(testTimer: true, dependencies: deps, startTimer: false)
        #expect(ended.customMinutes == 35 && ended.duration == .custom)
    }

    @Test(arguments: [SleepControl.Outcome.canceled, .notConfirmed])
    func failedDamagedRecoveryKeepsRealJournal(_ outcome: SleepControl.Outcome) throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let dir = root.appendingPathComponent(".build/v6/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("session.json")
        let f = Fixture(); f.active(); f.session.durationSeconds = 0; f.outcome = outcome
        let bytes = try JSONEncoder().encode(f.session); try bytes.write(to: file)
        var deps = f.dependencies
        deps.load = { try SessionStore.load(from: file) }
        deps.loadForRecovery = { try SessionStore.load(from: file, validatingTimer: false) }
        deps.save = { try SessionStore.save($0, to: file) }
        let model = AppModel(testTimer: true, dependencies: deps, startTimer: false)
        #expect(f.calls.isEmpty)
        model.forceRestoreSleep()
        #expect(f.calls.count == 1)
        #expect(f.state == .disabled && model.status != .off)
        #expect(try Data(contentsOf: file) == bytes)
        #expect(!model.prepareToQuit())
        f.outcome = .confirmed; model.forceRestoreSleep()
        #expect(try SessionStore.load(from: file).owned == false)
        #expect(f.state == .enabled)
    }

    @Test(arguments: [0, 1, 2, 3, 4])
    func damagedMetadataNeverAuthorizesAutomaticPowerChange(_ variant: Int) {
        let f = Fixture(); f.active(); f.session.durationSeconds = 0
        if variant == 0 { f.session.owner = nil }
        if variant == 1 { f.session.identifier = nil }
        if variant == 2 { f.session.phase = nil }
        if variant == 3 { f.session.owner?.pid = 456; f.otherOwnerAlive = true }
        if variant == 4 { f.session.owner?.bootID = "old-boot" }
        let original = f.session; let model = f.model(); model.tick()
        #expect(f.calls.isEmpty && f.saved.isEmpty)
        #expect(!model.prepareToQuit())
        #expect(f.session == original)
        if variant == 3 {
            model.forceRestoreSleep()
            #expect(f.calls.isEmpty && f.session == original)
        }
        f.state = .unknown; model.forceRestoreSleep()
        #expect(f.calls.isEmpty && f.session == original)
    }
}
