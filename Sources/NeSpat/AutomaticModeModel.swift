import Foundation
import SwiftUI
import NeSpatPrivilegeCore

@MainActor final class AutomaticModeModel: ObservableObject {
    @Published private(set) var requested: Bool
    @Published private(set) var state = AutomaticSessionService.State.off
    @Published private(set) var power = ObservedSleep.unknown
    @Published private(set) var error: String?
    @Published private(set) var deadline: Date?
    private let service: AutomaticSessionService
    private var task: Task<Void, Never>?
    private let save: (Bool) -> Void
    init(backend: any AutomaticSessionBackend = LocalAutomaticBackend(), requested: Bool? = nil,
         start: Bool = true, save: ((Bool) -> Void)? = nil) {
        self.requested = requested ?? UserDefaults.standard.bool(forKey: "automaticMode.requested.v1")
        self.save = save ?? { UserDefaults.standard.set($0, forKey: "automaticMode.requested.v1") }
        service = AutomaticSessionService(backend: backend)
        if start {
            task = Task { [weak self] in
                guard let self else { return }
                await self.service.setDesired(self.requested)
                while !Task.isCancelled {
                    await self.refresh()
                    do { try await Task.sleep(for: .seconds(5)) } catch { return }
                }
            }
        }
    }
    deinit { task?.cancel() }
    func configureLogin() {
        do {
            let profile = try LocalTrustProfile.load()
            guard profile.guiPin.matchesHardenedFile(Bundle.main.bundleURL),
                  Bundle.main.bundleURL.standardizedFileURL.path == LocalTrustProfile.appPath else { throw PrivilegeError.blocked }
            if !FileManager.default.fileExists(atPath: "/Library/LaunchAgents/local.nespat.gui.plist") {
                guard LoginItem.setEnabled(true) else { throw PrivilegeError.blocked }
            }
            setRequested(true)
        } catch { self.error = "Сначала требуется отдельно разрешённая локальная установка службы. Система не изменена." }
    }
    func restoreNow() {
        requested = false; save(false)
        Task { await service.restoreNow(); await refresh() }
    }
    func prepareToQuit() async -> Bool {
        // Suspend this process for safe exit; retain the user's startup intent.
        await service.setDesired(false); await refresh()
        return power == .enabled && SystemSleepObservation.read() == .enabled
    }
    var needsSafeQuit: Bool {
        if requested { return true }
        switch state { case .prepared, .closed, .recovering: return true; default: return false }
    }
    func startOnce() {
        requested = true
        Task { await service.setDesired(true); await refresh() }
    }
    func setRequested(_ on: Bool) {
        requested = on; save(on)
        Task { await service.setDesired(on); await refresh() }
    }
    func refresh() async {
        await service.poll()
        if requested, await service.sessionFinished {
            requested = false
            await service.setDesired(false)
        }
        state = await service.state; power = await service.observedPower
        error = await service.operationError; deadline = await service.deadline
    }
    var menuTitle: String {
        switch state {
        case .prepared, .closed: "Auto ☀︎"
        case .preparing: "Auto …"
        case .recovering, .blocked, .fault: "Auto ⚠︎"
        case .off: "Auto ○"
        }
    }
    var title: String {
        switch state {
        case .off: "Автоматический режим выключен"
        case .preparing: "Подготовка Mac к закрытию крышки"
        case .prepared: "Mac подготовлен"
        case .closed: "Крышка закрыта · запрет сна подтверждён"
        case .recovering: "Восстановление сна ещё не подтверждено"
        case .blocked(let reason), .fault(let reason): reason
        }
    }
}
