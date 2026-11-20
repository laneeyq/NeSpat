import AppKit
import ServiceManagement

let fm = FileManager.default
let bundle = Bundle.main
let base = URL(fileURLWithPath: "/Library/Application Support/NeSpatPrivileged")
let panel = base.appendingPathComponent("NeSpat.app")

func destination(bundlePath: String, profile: [String: Any]?, panelExists: Bool) -> String {
    if bundlePath != "/Applications/NeSpat.app" { return "move" }
    let expected = bundle.object(forInfoDictionaryKey:"CFBundleShortVersionString") as? String ?? ""
    let installed = Bundle(url:panel)?.object(forInfoDictionaryKey:"CFBundleShortVersionString") as? String ?? ""
    if panelExists, installed.compare(expected, options:.numeric) != .orderedAscending, profile?["enabled"] as? Bool == true { return "panel" }
    return "setup"
}

func message(_ title: String, _ detail: String) {
    let alert = NSAlert()
    alert.messageText = title
    alert.informativeText = detail
    NSApplication.shared.activate(ignoringOtherApps: true)
    alert.runModal()
}

// SMAppService registers the application in /Applications that owns the login item.
let options = Array(CommandLine.arguments.dropFirst())
if options.count == 1, ["--login-status", "--login-enable", "--login-disable"].contains(options[0]) {
    guard bundle.bundlePath == "/Applications/NeSpat.app" else { exit(1) }
    do {
        switch options[0] {
        case "--login-enable": try SMAppService.mainApp.register()
        case "--login-disable": try SMAppService.mainApp.unregister()
        default: break
        }
        print(SMAppService.mainApp.status == .enabled ? "enabled" : "disabled")
        exit(0)
    } catch { exit(1) }
}

let profile = (try? Data(contentsOf: base.appendingPathComponent("LocalTrust/profile.json")))
    .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
let action = destination(bundlePath: bundle.bundlePath, profile: profile, panelExists: fm.fileExists(atPath: panel.path))
if CommandLine.arguments.dropFirst() == ["--check-launch-route"] {
    print(action)
} else if action == "move" {
    message("Перенесите NeSpat в Программы", "Перетащите NeSpat.app на папку Applications в образе. Затем откройте NeSpat из Программ.")
} else {
    if action == "setup", NSRunningApplication.runningApplications(withBundleIdentifier:"local.nespat.app").contains(where: { $0.bundleURL?.standardizedFileURL == panel.standardizedFileURL }) {
        message("Завершите работу NeSpat", "Остановите сессию, выберите «Выход» в панели и снова откройте NeSpat из Программ.")
        exit(0)
    }
    let target = action == "panel" ? panel : bundle.url(forResource: "Services", withExtension: "pkg")
    if let target, NSWorkspace.shared.open(target) {
        exit(0)
    }
    message("Не удалось открыть NeSpat", "Скопируйте приложение заново из образа выпуска.")
}
