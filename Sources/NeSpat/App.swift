import AppKit
import MenuBarExtraAccess
import SwiftUI

// Resolve the supported property wrapper type explicitly: CLT 27.2 lacks SwiftUIMacros.
private typealias ViewState<Value> = SwiftUI.State<Value>

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static var model: AppModel?
    static var automatic: AutomaticModeModel?

    enum TerminationDecision: Equatable {
        case allow
        case cancel(String)
    }

    static func terminationDecision(
        model: AppModel?, readState: () -> SleepState = PowerInfo.observedSleepState
    ) -> TerminationDecision {
        guard let model else {
            return readState() == .enabled ? .allow : .cancel(
                "Модель приложения недоступна, обычный сон не подтверждён. Выход остановлен; проверьте сон."
            )
        }
        return model.prepareToQuit() ? .allow : .cancel(
            model.operationError ?? "Проверьте состояние сна и повторите восстановление."
        )
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if let automatic = Self.automatic, automatic.needsSafeQuit {
            Task { @MainActor in
                let safe = await automatic.prepareToQuit()
                if !safe {
                    let alert = NSAlert(); alert.messageText = "Восстановление сна ещё не подтверждено"
                    alert.informativeText = "Фоновая служба продолжает защиту. Повторите выход после подтверждения обычного сна."
                    alert.runModal()
                }
                sender.reply(toApplicationShouldTerminate: safe)
            }
            return .terminateLater
        }
        switch Self.terminationDecision(model: Self.model) {
        case .allow:
            return .terminateNow
        case .cancel(let message):
            let alert = NSAlert()
            alert.messageText = "Сон не восстановлен"
            alert.informativeText = message
            alert.addButton(withTitle: "Остаться в приложении")
            alert.runModal()
            return .terminateCancel
        }
    }
}

// MARK: - Приложение в строке меню

struct NeSpatApp: App {
    @StateObject private var automatic: AutomaticModeModel
    @StateObject private var model: AppModel
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @ViewState private var isMenuPresented = false

    init() {
        let testTimer = CommandLine.arguments.contains("--test-timer")
        let model = AppModel(testTimer: testTimer)
        let automatic = AutomaticModeModel()
        _automatic = StateObject(wrappedValue: automatic)
        AppDelegate.automatic = automatic
        _model = StateObject(wrappedValue: model)
        AppDelegate.model = model
    }

    var body: some Scene {
        MenuBarExtra {
            PanelView(model: model, automatic: automatic)
        } label: {
            // Системный кегль строки меню (menu font 14 pt) + табличные цифры, чтобы ширина не плясала.
            Text(automatic.requested ? automatic.menuTitle : model.menuTitle)
                .font(.system(size: 14, weight: .regular))
                .monospacedDigit()
                .frame(minWidth: 100, alignment: .leading)
        }
        // menuBarExtraAccess обязан идти сразу после MenuBarExtra.
        .menuBarExtraAccess(isPresented: $isMenuPresented) { item in
            // v2: сброс залипшей позиции под вырезом. Preferred Position — только если ещё нет
            // (иначе каждый запуск затирает ⌘-перетаскивание пользователя).
            let name = "local.nespat.statusItem.v2"
            let defaults = UserDefaults.standard
            let visibleKey = "NSStatusItem Visible \(name)"
            let visibleCCKey = "NSStatusItem VisibleCC \(name)"
            let positionKey = "NSStatusItem Preferred Position \(name)"
            defaults.set(true, forKey: visibleKey)
            defaults.set(true, forKey: visibleCCKey)
            if defaults.object(forKey: positionKey) == nil {
                defaults.set(220, forKey: positionKey)
            }
            item.autosaveName = NSStatusItem.AutosaveName(name)
            item.isVisible = true
        }
        .menuBarExtraStyle(.window)
    }
}

// MARK: - Панель (стиль системных меню macOS)

struct PanelView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var automatic: AutomaticModeModel
    init(model: AppModel, automatic: AutomaticModeModel? = nil) {
        self.model = model
        self.automatic = automatic ?? AutomaticModeModel(requested: false, start: false, save: { _ in })
    }
    @ViewState private var customMinutesText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            automaticBlock
            thinDivider
            header
            thinDivider
            if !automatic.needsSafeQuit { durationBlock; thinDivider }
            metrics
            thinDivider
            settings
            thinDivider
            footer
        }
        .padding(.vertical, 8)
        .frame(width: 300)
        .fixedSize(horizontal: false, vertical: true)
        // Явно системный шрифт Apple (SF Pro) — чтобы кириллица не уходила в fallback.
        .font(.system(size: 13))
    }

    private var automaticBlock: some View {
        VStack(alignment: .leading, spacing: 5) {
            Toggle("Автоматически при закрытии крышки", isOn: Binding(get: { automatic.requested }, set: automatic.setRequested))
                .toggleStyle(.switch).controlSize(.small)
            Button("Первоначальная настройка автозапуска") { automatic.configureLogin() }
                .font(.system(size: 11))
            Button("Вернуть обычный сон сейчас") { automatic.restoreNow() }
                .font(.system(size: 11))
            TimelineView(.periodic(from: .now, by: 1)) { context in
                if let deadline = automatic.deadline {
                    let seconds = max(0, deadline.timeIntervalSince(context.date))
                    Text(seconds == 0 ? "Срок истёк · обычный сон ещё не подтверждён" : "\(automatic.title) · осталось \(Fmt.duration(seconds))")
                        .font(.system(size: 11)).monospacedDigit().fixedSize(horizontal: false, vertical: true)
                } else { Text(automatic.title).font(.system(size: 11)).fixedSize(horizontal: false, vertical: true) }
            }
            Text("Служба: \(automatic.error == nil && automatic.power != .unknown ? "связь проверена" : "связь или операция не подтверждена")")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            Text("Независимая служба восстановления: не подключена")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            Text("Системный сон: \(automatic.power == .enabled ? "обычный подтверждён" : automatic.power == .disabled ? "запрет подтверждён" : "неизвестно")")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            if let error = automatic.error {
                Text(error).font(.system(size: 11)).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            if automatic.requested {
                Text("Нужна однократная локальная настройка службы и автозапуска. Пароль не сохраняется.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }.padding(.horizontal, 14)
    }

    private var thinDivider: some View {
        Divider().padding(.horizontal, 14).padding(.vertical, 6)
    }

    // MARK: Шапка

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .center) {
                Text("Не спать")
                    .font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 8)
                Toggle("", isOn: isOnBinding)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .disabled(!model.canToggleMode || automatic.needsSafeQuit)
            }
            // Only this text redraws each second. Safety and metric polling stay in model.tick().
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(automatic.needsSafeQuit ? "Ручное управление приостановлено; режим контролирует служба NeSpat" : model.statusText(at: context.date))
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(statusColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !automatic.needsSafeQuit, let error = model.operationError {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !automatic.needsSafeQuit, model.showsRestoreAction {
                Button("Вернуть обычный сон") { model.forceRestoreSleep() }
                    .buttonStyle(.borderless)
                    .font(.system(size: 11))
                    .padding(.top, 2)
                    .disabled(model.busy || automatic.needsSafeQuit)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 4)
    }

    private var isOnBinding: Binding<Bool> {
        Binding(
            get: { model.modeIsOn },
            set: { model.toggle($0) }
        )
    }

    /// Цвет статуса — системные насыщенные тона, в единой семантике со шкалами.
    private var statusColor: Color {
        if model.emergencyInProgress { return .orange }
        return switch model.status {
        case .on: .green
        case .off: .secondary
        case .foreign: .yellow
        case .unknown: .red
        }
    }

    // MARK: Длительность

    private var durationBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Длительность")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Picker("", selection: Binding(
                get: { model.duration },
                set: { model.setDuration($0) }
            )) {
                ForEach(model.durations) { d in
                    Text(d.rawValue).tag(d)
                }
            }
            .pickerStyle(.segmented)
            .disabled(!model.canToggleMode || automatic.needsSafeQuit)
            .labelsHidden()
            .controlSize(.small)
            Text("Своя длительность, мин").font(.system(size: 11)).foregroundStyle(.secondary)
            HStack {
                TextField(model.customMinutes.map(String.init) ?? "Минуты", text: $customMinutesText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { model.applyCustomMinutes(customMinutesText) }
                Button("Применить") { model.applyCustomMinutes(customMinutesText) }
            }
            .disabled(!model.canToggleMode || automatic.needsSafeQuit)
            if let error = model.durationError {
                Text(error).font(.system(size: 11)).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if model.duration == .custom, let minutes = model.customMinutes {
                Text("Выбрано: \(minutes) мин").font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
    }

    // MARK: Метрики

    private var metrics: some View {
        PanelMetrics(sample: model.sample, lastReason: model.lastReason)
    }

    // MARK: Настройки

    private var settings: some View {
        HStack {
            Spacer()
            Button(action: { model.openActivityMonitor() }) {
                Label("Мониторинг системы", systemImage: "activity")
                    .font(.system(size: 13))
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.primary)
            Spacer()
        }
        .padding(.horizontal, 14)
    }

    // MARK: Низ

    private var footer: some View {
        HStack(alignment: .center) {
            Toggle("Запускать при входе", isOn: Binding(
                get: { model.launchAtLogin },
                set: { model.setLaunchAtLogin($0) }
            ))
            .font(.system(size: 13))
            .toggleStyle(.checkbox)
            .controlSize(.small)
            .tint(.accentColor)

            Spacer(minLength: 8)

            Button("Выход") { model.quit() }
                .buttonStyle(.borderless)
                .font(.system(size: 13))
                .foregroundStyle(.primary)
                .keyboardShortcut("q")
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 2)
    }
}

struct PanelMetrics: View {
    @ViewState private var expanded = false
    @ViewState private var details = BatteryDetails()
    let sample: StatsSampler.Sample
    var lastReason: String? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            barRow(
                "Температура",
                TemperatureReader.validCelsius(sample.temperatureC).map { "\(Int($0.rounded())) °C" } ?? "—",
                fraction: temperatureFraction,
                fill: .load
            )
            barRow(
                "Процессор",
                sample.cpuPercent.map { Fmt.percent($0) } ?? "—",
                fraction: cpuFraction,
                fill: .load
            )
            barRow(
                "Память",
                "\(Fmt.gb(sample.memUsedBytes)) из \(Fmt.gb(sample.memTotalBytes))",
                fraction: memoryFraction,
                fill: .load
            )
            Button {
                expanded.toggle()
                if expanded { details = BatteryDetails.read() }
            } label: {
            barRow(
                expanded ? "Батарея ⌃" : "Батарея ⌄",
                sample.batteryPercent.map { p in
                    let src = StatsSampler.powerSourceText(sample.externalPowerConnected)
                    return "\(p)% · \(src)"
                } ?? "—",
                fraction: sample.batteryPercent.map { CGFloat($0) / 100 },
                fill: .battery(sample.batteryPercent ?? 100)
            )
                .contentShape(Rectangle())
            }.buttonStyle(.plain).help("Показать циклы и ёмкость аккумулятора")
            if expanded {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 3) {
                    detail("Циклы", details.cycles, "")
                    detail("Текущий заряд", details.remaining, " мА·ч")
                    detail("Полная ёмкость", details.full, " мА·ч")
                    detail("Проектная ёмкость", details.design, " мА·ч")
                    detail("От проектной", details.health, "%")
                }.font(.caption).foregroundStyle(.secondary)
                .onChange(of: sample.batteryPercent) { details = BatteryDetails.read() }
            }
            if sample.isCharging == true || sample.isFullyCharged == true || sample.batteryMinutes != nil {
                HStack {
                    if sample.isCharging == true { Text("Заряжается") }
                    else if sample.isFullyCharged == true { Text("Заряжена") }
                    if let minutes = sample.batteryMinutes {
                        Text("\(sample.isCharging == true ? "До зарядки" : "Осталось") ≈ \(minutes / 60) ч \(minutes % 60) мин")
                    }
                }.font(.caption).foregroundStyle(.secondary)
            }
            if let reason = lastReason {
                Text(reason)
                    .font(.system(size: 11))
                    .foregroundStyle(.primary.opacity(0.75))
                    .lineLimit(2)
                    .padding(.top, 2)
            }
        }
        .padding(.horizontal, 14)
    }

    private func detail(_ label: String, _ value: Int?, _ unit: String) -> some View {
        GridRow {
            Text(label)
            Text(value.map { String($0) + unit } ?? "—").monospacedDigit()
        }
    }

    /// Единая метрика: подпись + значение + тонкая шкала.
    /// Честная семантика: длина заливки = значение, цвет = состояние (зелёный/жёлтый/красный),
    /// как у системного индикатора батареи. Радуги по всей ширине больше нет.
    private func barRow(_ label: String, _ value: String, fraction: CGFloat?, fill: BarFill) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(label)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Text(value)
                    .font(.system(size: 13, weight: .medium).monospacedDigit())
                    .foregroundStyle(.primary)
            }
            if let fraction {
                let f = min(max(fraction, 0), 1)
                GeometryReader { geo in
                    let filled = max(4, geo.size.width * f)
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.primary.opacity(0.18))
                        switch fill {
                        case .load:
                            // Градация по всей дорожке, видна только занятая часть:
                            // длина = значение, цвет кончика = состояние.
                            Capsule()
                                .fill(loadGradient)
                                .frame(width: geo.size.width)
                                .mask(
                                    HStack(spacing: 0) {
                                        Rectangle().frame(width: filled)
                                        Spacer(minLength: 0)
                                    }
                                )
                                .overlay(alignment: .leading) {
                                    Capsule()
                                        .fill(gloss)
                                        .frame(width: filled)
                                }
                        case .battery(let percent):
                            Capsule()
                                .fill(batteryColor(percent))
                                .frame(width: filled)
                                .overlay(Capsule().fill(gloss))
                        }
                    }
                }
                .frame(height: 5)
            }
        }
    }

    private enum BarFill {
        case load
        case battery(Int)
    }

    /// Насыщенный «светофор» нагрузки: зелёный → жёлтый → красный по всей дорожке.
    private var loadGradient: LinearGradient {
        LinearGradient(
            colors: [.green, .yellow, .red],
            startPoint: .leading,
            endPoint: .trailing
        )
    }

    /// Батарея: сплошной цвет по уровню заряда (заряд, а не нагрузка).
    private func batteryColor(_ percent: Int) -> Color {
        if percent < 15 { return .red }
        if percent < 30 { return .yellow }
        return .green
    }

    /// 25…85 °C → 0…1: при обычной работе шкала наполнена, но не врёт (35° уже видно).
    private var temperatureFraction: CGFloat? {
        guard let t = TemperatureReader.validCelsius(sample.temperatureC) else { return nil }
        return CGFloat(min(max((t - 25) / 60, 0), 1))
    }

    private var cpuFraction: CGFloat? {
        guard let c = sample.cpuPercent else { return nil }
        return CGFloat(min(max(c / 100, 0), 1))
    }

    private var memoryFraction: CGFloat? {
        guard sample.memTotalBytes > 0 else { return nil }
        return CGFloat(min(1, Double(sample.memUsedBytes) / Double(sample.memTotalBytes)))
    }



    /// Глянцевый блик: светлая полоса сверху капсулы, к низу сходит на нет.
    private var gloss: LinearGradient {
        LinearGradient(
            colors: [
                Color.white.opacity(0.32),
                Color.white.opacity(0.10),
                Color.white.opacity(0.02)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

}
