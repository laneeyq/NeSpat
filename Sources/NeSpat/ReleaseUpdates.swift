import AppKit
import Foundation

@MainActor final class ReleaseUpdates: ObservableObject {
    static let shared = ReleaseUpdates()
    @Published private(set) var message: String?
    @Published private(set) var package: URL?
    private var checking = false
    private struct Asset: Decodable { let version: String; let path: String }
    func monitor() async {
        while !Task.isCancelled {
            if UserDefaults.standard.object(forKey: "updates.automatic") as? Bool != false {
                await check(manual: false)
            }
            do { try await Task.sleep(for: .seconds(86400)) } catch { return }
        }
    }
    func check(manual: Bool) async {
        guard !checking, package == nil else { return }
        checking = true
        defer { checking = false }
        if manual { message = "Проверяем обновления…" }
        do {
            guard let version = Bundle.main.object(forInfoDictionaryKey:"CFBundleShortVersionString") as? String else { throw URLError(.cannotParseResponse) }
            let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Library/Helpers/check-update")
            let folder = try FileManager.default.url(for:.cachesDirectory,in:.userDomainMask,appropriateFor:nil,create:true)
                .appendingPathComponent("local.nespat.app/Updates")
            let asset = try await Task.detached(priority: .utility) {
                let process = Process(), pipe = Pipe()
                process.executableURL = helper
                process.arguments = [version, folder.path]
                process.standardOutput = pipe
                try process.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                guard process.terminationStatus == 0 else { throw URLError(.badServerResponse) }
                return try JSONDecoder().decode(Asset?.self, from:data)
            }.value
            if let asset {
                package = URL(fileURLWithPath:asset.path)
                message = "Готово обновление \(asset.version)"
            } else { message = manual ? "Установлена актуальная версия" : nil }
        } catch {
            if manual { message = "Не удалось проверить выпуск на GitHub. Повторите позже." }
        }
    }
}
