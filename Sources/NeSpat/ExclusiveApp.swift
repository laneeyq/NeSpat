import AppKit
import MenuBarExtraAccess
import SwiftUI
import NeSpatPrivilegeCore

private typealias PanelState<Value> = SwiftUI.State<Value>

@MainActor final class PanelReadings: ObservableObject {
    @Published var sample = StatsSampler.Sample()
    @Published var helper = false
    @Published var watchdog = false
    @Published var permitted = false
    @Published var power = ObservedSleep.unknown
    private let sampler = StatsSampler()
    private var timer: Timer?

    init(poll: Bool = true) {
        if poll {
            refresh()
            timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            }
        }
    }

    private func refresh() {
        sample = sampler.sample()
        power = SystemSleepObservation.read()
        let profile = try? LocalTrustProfile.load()
        permitted = profile?.currentlyEnabled == true
        if let profile, let boot = SystemBootIdentity.read() {
            helper = ServicePulse.current(.helper, boot: boot, setup: profile.setupID) != nil
            watchdog = ServicePulse.current(.watchdog, boot: boot, setup: profile.setupID) != nil
        } else { helper = false; watchdog = false }
    }

    var menuTitle: String {
        let temp = sample.temperatureC.map { "\(Int($0.rounded()))°" } ?? "—"
        let cpu = sample.cpuPercent.map(Fmt.percent) ?? "—"
        let mem = sample.memTotalBytes > 0 ? Fmt.percent(100 * Double(sample.memUsedBytes) / Double(sample.memTotalBytes)) : "—"
        return [temp, cpu, mem].joined(separator: " ")
    }
}

@MainActor struct ExclusiveNeSpatApp: App {
    @StateObject private var mode = AutomaticModeModel()
    @StateObject private var readings = PanelReadings()
    @PanelState private var presented = false
    init() {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: "exclusive.durationChoice") == nil else { return }
        let previous = defaults.integer(forKey: "exclusive.durationMinutes")
        if [60, 180, 480].contains(previous) {
            defaults.set(previous, forKey: "exclusive.durationChoice")
        } else if let saved = defaults.string(forKey: "durationChoice.v6") {
            if saved.hasPrefix("custom:"), let seconds = try? CustomDuration.seconds(String(saved.dropFirst(7))) {
                defaults.set(String(Int(seconds / 60)), forKey: "exclusive.customMinutes")
                defaults.set(-1, forKey: "exclusive.durationChoice")
            } else if let minutes = ["Без лимита": 0, "1 ч": 60, "3 ч": 180, "8 ч": 480][saved] {
                defaults.set(minutes, forKey: "exclusive.durationChoice")
            }
        }
    }
    private var menuTitle: String {
        let warning = "⚠ " + readings.menuTitle
        if mode.error != nil || !readings.helper || !readings.watchdog || readings.power == .unknown { return warning }
        switch mode.state {
        case .blocked, .fault, .recovering: return warning
        case .prepared, .closed: return readings.power == .disabled ? "☕ " + readings.menuTitle : readings.menuTitle
        default: return readings.power == .disabled ? warning : readings.menuTitle
        }
    }
    var body: some Scene {
        MenuBarExtra {
            ExclusivePanel(mode: mode, readings: readings)
        } label: {
            Text(menuTitle)
                .font(.system(size: 14)).monospacedDigit()
                .frame(minWidth: 100, alignment: .leading)
        }
        .menuBarExtraAccess(isPresented: $presented) { item in
            item.autosaveName = NSStatusItem.AutosaveName("local.nespat.statusItem.v2")
            item.isVisible = true
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor struct ExclusivePanel: View {
    @ObservedObject var mode: AutomaticModeModel
    @ObservedObject var readings: PanelReadings
    @AppStorage("exclusive.durationChoice") private var minutes = 60
    @AppStorage("exclusive.customMinutes") private var customMinutes = "30"
    @AppStorage("automaticMode.requested.v1") private var automatic = false
    @PanelState private var login = LoginItem.isEnabled
    @PanelState private var loginError: String?
    @PanelState private var draftMinutes = ""
    @PanelState private var durationError: String?

    private var active: Bool {
        guard readings.power == .disabled else { return false }
        switch mode.state { case .prepared, .closed: return true; default: return false }
    }
    private var canStart: Bool {
        (minutes != -1 || (try? CustomDuration.seconds(customMinutes)) != nil) && readings.permitted && readings.helper && readings.watchdog && readings.power == .enabled
    }
    private var divider: some View { Divider().padding(.horizontal, 14).padding(.vertical, 6) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Не спать").fontWeight(.semibold)
                    Spacer()
                    Toggle("Не спать", isOn: Binding(get: { active }, set: { on in
                        if on { mode.startOnce() } else { mode.setRequested(false) }
                    })).labelsHidden().toggleStyle(.switch).controlSize(.small)
                        .disabled(!active && (!canStart || mode.needsSafeQuit))
                }
                TimelineView(.periodic(from: .now, by: 1)) { clock in
                    Text(status(at: clock.date))
                        .font(.system(size: 11)).monospacedDigit()
                        .foregroundStyle(active ? Color.green : Color.secondary)
                }
                if let error = mode.error { Text(error).font(.system(size: 11)).foregroundStyle(.red) }
                if readings.power == .disabled {
                    Button("Аварийное восстановление…") { mode.restoreNow() }.buttonStyle(.borderless)
                } else if mode.needsSafeQuit && !active {
                    Button("Отменить подготовку") { mode.setRequested(false) }.buttonStyle(.borderless)
                }
            }.padding(.horizontal, 14).padding(.top, 4)
            divider
            VStack(alignment: .leading, spacing: 6) {
                Text("Длительность").font(.system(size: 11)).foregroundStyle(.secondary)
                DurationPresets(selection: $minutes)
                    .frame(maxWidth: .infinity)
                    .accessibilityLabel("Длительность")
                Text("Своя длительность, мин").font(.system(size: 11)).foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    TextField("Минуты", text: $draftMinutes)
                        .accessibilityLabel("Своя длительность в минутах")
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(applyMinutes)
                    Button("Применить", action: applyMinutes)
                }
                .controlSize(.small)
                if let durationError {
                    Text(durationError).font(.system(size: 11)).foregroundStyle(.red)
                } else if minutes == -1 {
                    Text("Выбрано: \(customMinutes) мин").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            .disabled(mode.needsSafeQuit)
            .onAppear { draftMinutes = customMinutes }
            .onChange(of: minutes) { durationError = nil }
            .padding(.horizontal, 14)
            divider
            PanelMetrics(sample: readings.sample)
            divider
            HStack {
                Spacer()
                Button {
                    NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"))
                } label: { Label("Мониторинг системы", systemImage: "activity") }
                .buttonStyle(.borderless).foregroundStyle(.primary)
                Spacer()
            }.padding(.horizontal, 14)
            divider
            VStack(alignment: .leading, spacing: 6) {
                Toggle("Автоматический режим", isOn: Binding(get: { automatic }, set: mode.setRequested))
                    .disabled(!automatic && !canStart)
                HStack {
                    Toggle("Запускать при входе", isOn: Binding(get: { login }, set: { on in
                        let changed = LoginItem.setEnabled(on)
                        login = LoginItem.isEnabled
                        loginError = changed ? nil : "Проверьте объекты входа в системных настройках."
                    }))
                    Spacer()
                    Button("Выход") {
                        Task {
                            if !mode.needsSafeQuit && readings.power == .enabled { NSApp.terminate(nil) }
                            else if await mode.prepareToQuit() { NSApp.terminate(nil) }
                        }
                    }.buttonStyle(.borderless).foregroundStyle(.primary).keyboardShortcut("q")
                }
                if let loginError { Text(loginError).font(.system(size: 11)) }
            }.toggleStyle(.checkbox).controlSize(.small).padding(.horizontal, 14).padding(.bottom, 2)
        }
        .padding(.vertical, 8).frame(width: 300).fixedSize(horizontal: false, vertical: true)
        .font(.system(size: 13))
        .background {
            GeometryReader { geometry in
                PanelWindowSize(height: geometry.size.height)
            }
        }
    }

    private func applyMinutes() {
        guard !mode.needsSafeQuit else { return }
        do {
            let seconds = try CustomDuration.seconds(draftMinutes)
            _ = try CustomDuration.deadline(seconds: seconds, now: Date())
            customMinutes = String(Int(seconds / 60))
            draftMinutes = customMinutes
            minutes = -1
            durationError = nil
        } catch {
            durationError = error.localizedDescription
        }
    }

    private func status(at now: Date) -> String {
        if active, let end = mode.deadline { return "Включено · осталось " + Fmt.duration(max(0, end.timeIntervalSince(now))) }
        if active { return "Включено · без лимита" }
        if !readings.helper { return "Служба NeSpat недоступна" }
        if !readings.watchdog { return "Служба восстановления недоступна" }
        if mode.error != nil, readings.power == .enabled { return "Сон разрешён · проверяем завершение сессии" }
        if mode.needsSafeQuit { return mode.title }
        if readings.power == .disabled { return "Запрет сна включён · владение не подтверждено" }
        if readings.power == .unknown { return "Не удалось подтвердить состояние сна" }
        return readings.permitted ? "Выключено · обычный сон" : "Выключено · требуется разрешение администратора"
    }
}

// With a custom duration active, all four preset segments should be unselected.
private struct DurationPresets: NSViewRepresentable {
    @Binding var selection: Int
    @Environment(\.isEnabled) private var isEnabled
    private static let choices = [("Без лимита", 0), ("1 ч", 60), ("3 ч", 180), ("8 ч", 480)]

    func makeCoordinator() -> Coordinator { Coordinator(selection: $selection) }
    func makeNSView(context: Context) -> NSSegmentedControl {
        let control = NSSegmentedControl(labels: Self.choices.map { $0.0 }, trackingMode: .selectOne,
                                         target: context.coordinator, action: #selector(Coordinator.pick(_:)))
        control.controlSize = .small
        let font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        control.font = font
        control.segmentDistribution = .fill
        // Reserve enough room for the full label, then share the rest among the hour presets.
        let labelWidth = (Self.choices[0].0 as NSString).size(withAttributes: [.font: font]).width
        control.setWidth(ceil(labelWidth) + 12, forSegment: 0)
        control.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return control
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSSegmentedControl, context: Context) -> CGSize? {
        guard let width = proposal.width, width.isFinite else { return nil }
        return CGSize(width: width, height: nsView.intrinsicContentSize.height)
    }

    func updateNSView(_ control: NSSegmentedControl, context: Context) {
        control.selectedSegment = Self.choices.firstIndex { $0.1 == selection } ?? -1
        control.isEnabled = isEnabled
    }
    @MainActor final class Coordinator: NSObject {
        let selection: Binding<Int>
        init(selection: Binding<Int>) { self.selection = selection }
        @objc func pick(_ sender: NSSegmentedControl) {
            guard choices.indices.contains(sender.selectedSegment) else { return }
            selection.wrappedValue = choices[sender.selectedSegment].1
        }
    }
}

private struct PanelWindowSize: NSViewRepresentable {
    let height: CGFloat
    func makeNSView(context: Context) -> Probe { Probe() }
    func updateNSView(_ view: Probe, context: Context) { view.schedule(height) }

    final class Probe: NSView {
        private var contentHeight: CGFloat = 0
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            schedule(contentHeight)
        }
        func schedule(_ height: CGFloat) {
            contentHeight = height
            DispatchQueue.main.async { [weak self] in
                guard let self, let window, height > 0, height == contentHeight else { return }
                var frame = window.frame
                let target = window.frameRect(forContentRect: NSRect(x: 0, y: 0, width: 300, height: ceil(height))).height
                guard abs(target - frame.height) >= 1 else { return }
                frame.origin.y = frame.maxY - target
                frame.size.height = target
                window.setFrame(frame, display: true)
            }
        }
    }
}
