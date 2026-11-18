import AppKit

let fm = FileManager.default
let bundle = Bundle.main
let base = URL(fileURLWithPath: "/Library/Application Support/NeSpatPrivileged")
let panel = base.appendingPathComponent("NeSpat.app")

func destination(bundlePath: String, profile: [String: Any]?, panelExists: Bool) -> String {
    if bundlePath != "/Applications/NeSpat.app" { return "move" }
    if panelExists, profile?["enabled"] as? Bool == true { return "panel" }
    return "setup"
}

func message(_ title: String, _ detail: String) {
    let alert = NSAlert()
    alert.messageText = title
    alert.informativeText = detail
    NSApplication.shared.activate(ignoringOtherApps: true)
    alert.runModal()
}

let profile = (try? Data(contentsOf: base.appendingPathComponent("LocalTrust/profile.json")))
    .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
let action = destination(bundlePath: bundle.bundlePath, profile: profile, panelExists: fm.fileExists(atPath: panel.path))
if CommandLine.arguments.dropFirst() == ["--check-launch-route"] {
    print(action)
} else if action == "move" {
    message("Перенесите NeSpat в Программы", "Перетащите NeSpat.app на папку Applications в образе. Затем откройте NeSpat из Программ.")
} else {
    let target = action == "panel" ? panel : bundle.url(forResource: "Services", withExtension: "pkg")
    if let target, NSWorkspace.shared.open(target) {
        exit(0)
    }
    message("Не удалось открыть NeSpat", "Скопируйте приложение заново из образа выпуска.")
}
