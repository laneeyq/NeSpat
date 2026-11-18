import AppKit
import Foundation
import NeSpatPrivilegeCore

// MARK: - Точка входа: CLI-режимы и GUI

@main
enum Entrypoint {
    @MainActor
    static func main() {
        let args = CommandLine.arguments
        // The signed diagnostic bundle must never initialize the legacy GUI model
        // or its watchdog, including when opened from Finder without arguments.
        if Bundle.main.object(forInfoDictionaryKey: "NeSpatAcceptanceOnly") as? Bool == true {
            let allowed = ["--observe-sleep", "--print-stats", "--debug-sensors", "--verify-acceptance-rpc",
                           "--verify-local-service", "--verify-local-build"]
            if args.count == 1 {
                let sleep = SystemSleepObservation.read()
                let lid = SystemSessionObservation.lidClosed().map { $0 ? "закрыта" : "открыта" } ?? "неизвестно"
                let app = NSApplication.shared
                app.setActivationPolicy(.accessory)
                let alert = NSAlert()
                alert.messageText = "Диагностика NeSpat"
                alert.informativeText = "Крышка: \(lid). Системный сон: \(sleep == .enabled ? "разрешён" : sleep == .disabled ? "запрещён" : "неизвестно"). Управление питанием в этой сборке недоступно."
                app.activate(ignoringOtherApps: true)
                alert.runModal()
                return
            }
            guard args.count == 2, allowed.contains(args[1]) else { exit(64) }
        }
        if Bundle.main.object(forInfoDictionaryKey: "NeSpatExclusive") as? Bool == true {
            if args.count == 1 || args.dropFirst() == ["--auto-agent"] { ExclusiveNeSpatApp.main(); return }
            guard args.count == 2, ["--observe-sleep", "--print-stats", "--verify-local-service",
                "--verify-local-build", "--single-trial"].contains(args[1]) else { exit(64) }
            if args[1] == "--single-trial" {
                Task.detached {
                    do { try await runTrial(); exit(0) }
                    catch { print("Trial unconfirmed: \(error)"); exit(2) }
                }
                dispatchMain()
            }
        }
        if args.contains("--observe-sleep") {
            let state = SystemSleepObservation.read()
            print("SleepDisabled observation: \(state.rawValue)")
            exit(state == .enabled ? 0 : 2)
        }
        if args.contains("--auto-agent") {
            guard let profile = try? LocalTrustProfile.load(), profile.allowedUID == getuid() else { exit(0) }
        }
        if args.contains("--verify-acceptance-rpc") {
            Task.detached {
                do { try await AcceptanceRPCProbe.run(); print("VERIFIED all fixed acceptance RPC denials; no grant issued"); exit(0) }
                catch { print("FAILED acceptance RPC probe: \(error)"); exit(1) }
            }
            dispatchMain()
        }
        if args.contains("--verify-local-service") {
            Task.detached {
                do {
                    let profile = try LocalTrustProfile.load()
                    guard profile.allowedUID == getuid() else { exit(1) }
                    let transport = try PrivilegeClient.connectLocal(profile: profile)
                    try await transport.handshake()
                    print("local root helper: strict mutual-pin handshake verified; no enrollment or power request sent")
                    await transport.close(); exit(0)
                } catch { print("local helper handshake not verified"); exit(1) }
            }
            dispatchMain()
        }
        if args.contains("--verify-local-build") {
            do {
                let app = Bundle.main.bundleURL
                let profile = app.deletingLastPathComponent().appendingPathComponent("profile.json")
                let fields = try JSONSerialization.jsonObject(with: Data(contentsOf: profile)) as? [String: Any]
                guard let gui = fields?["guiHash"] as? String, let helper = fields?["helperHash"] as? String else { exit(1) }
                let g = try ExactCodePin(codeDirectoryHash: gui, signingIdentifier: SigningPolicy.guiIdentifier)
                let h = try ExactCodePin(codeDirectoryHash: helper, signingIdentifier: SigningPolicy.helperIdentifier)
                let verified = g.matchesHardenedFile(app) && h.matchesHardenedFile(app.appendingPathComponent("Contents/Library/Helpers/NeSpatPrivilegeHelper"))
                print("local hardened ad-hoc pins verified: \(verified)")
                exit(verified ? 0 : 1)
            } catch { exit(1) }
        }
        if args.contains("--watchdog") {
            Watchdog.run()
        }
        if args.contains("--print-stats") {
            printStats()
            exit(0)
        }
        if args.contains("--debug-sensors") {
            for s in TemperatureReader.debugSensors() {
                print("\(s.name.padding(toLength: 18, withPad: " ", startingAt: 0))\(String(format: "%.1f", s.value)) °C")
            }
            exit(0)
        }
        NeSpatApp.main()
    }

    private static func runTrial() async throws {
        let profile = try LocalTrustProfile.load()
        guard profile.exclusiveControl, profile.currentlyEnabled, profile.trialOnly,
              SystemSessionObservation.lidClosed() == false, SystemSleepObservation.read() == .enabled else { throw PrivilegeError.blocked }
        let transport = try PrivilegeClient.connectLocal(profile: profile)
        try await transport.handshake()
        do {
            let before = RecoveryPolicy.continuousSeconds()
            let reply = try await transport.request(Request(operation: .begin, minutes: 1))
            guard reply.active == true, let session = reply.session, let limit = reply.authorityExpires,
                  limit <= before + 120, reply.state == .disabled, SystemSleepObservation.read() == .disabled else { throw PrivilegeError.unconfirmed }
            print("Trial active, confirmed Yes, session=\(session), authority remaining=\(limit-before)")
            // Keep the authenticated GUI alive while helper/watchdog enforce the absolute deadline.
            while RecoveryPolicy.continuousSeconds() < limit + 10 {
                try await Task.sleep(for: .seconds(3))
                if SystemSleepObservation.read() == .enabled { break }
                _ = try? await transport.request(Request(operation: .heartbeat, session: session))
            }
            guard SystemSleepObservation.read() == .enabled else { throw PrivilegeError.unconfirmed }
            await transport.close()
            print("Trial completed, confirmed No")
        } catch {
            await transport.close()
            throw error
        }
    }

    /// Проверка из терминала: температура, CPU, память, батарея, сон, крышка.
    private static func printStats() {
        let sampler = StatsSampler()
        // Первый замер CPU без дельты — делаем два с паузой.
        _ = sampler.sample()
        Thread.sleep(forTimeInterval: 1)
        let s = sampler.sample()

        print("Температура чипа: \(s.temperatureC.map { String(format: "%.1f °C", $0) } ?? "—")")
        print("CPU: \(s.cpuPercent.map { String(format: "%.0f%%", $0) } ?? "—")")
        print("Память: \(Fmt.gb(s.memUsedBytes)) из \(Fmt.gb(s.memTotalBytes))")
        if let p = s.batteryPercent {
            print("Батарея: \(p)% (\(StatsSampler.powerSourceText(s.externalPowerConnected)))")
        } else {
            print("Батарея: —")
        }
        switch PowerInfo.observedSleepState() {
        case .disabled: print("Сон: выключен (SleepDisabled=1)")
        case .enabled: print("Сон: включен (обычный)")
        case .unknown: print("Сон: неизвестно")
        }
        print("Крышка: \(PowerInfo.lidClosed().map { $0 ? "закрыта" : "открыта" } ?? "неизвестно")")
    }
}
