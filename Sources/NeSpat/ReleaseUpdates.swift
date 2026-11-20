import AppKit
import CryptoKit
import Foundation

@MainActor final class ReleaseUpdates: ObservableObject {
    static let shared = ReleaseUpdates()
    @Published private(set) var message: String?
    @Published private(set) var package: URL?
    private var checking = false
    private let repo = "laneeyq/NeSpat"
    private struct Release: Decodable {
        struct Asset: Decodable { let name: String; let digest: String?; let size: Int }
        let tag_name: String
        let draft: Bool
        let prerelease: Bool
        let assets: [Asset]
    }
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
            let api = URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!
            let (data, response) = try await URLSession.shared.data(from: api)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
            let release = try JSONDecoder().decode(Release.self, from: data)
            let tag = release.tag_name
            let version = String(tag.dropFirst())
            guard !release.draft, !release.prerelease, tag.first == "v",
                  version.range(of: #"^[0-9]{1,5}\.[0-9]{1,5}\.[0-9]{1,5}$"#, options: .regularExpression) != nil,
                  let installed = Bundle.main.object(forInfoDictionaryKey:"CFBundleShortVersionString") as? String else { throw URLError(.cannotParseResponse) }
            guard version.compare(installed, options:.numeric) == .orderedDescending else {
                message = manual ? "Установлена актуальная версия" : nil
                return
            }
            guard let asset = release.assets.first(where: { $0.name == "NeSpat-Update.pkg" }),
                  (1...50_000_000).contains(asset.size), let digest = asset.digest else { throw URLError(.resourceUnavailable) }
            let url = URL(string:"https://github.com/\(repo)/releases/download/\(tag)/NeSpat-Update.pkg")!
            let (file, download) = try await URLSession.shared.download(from:url)
            guard (download as? HTTPURLResponse)?.statusCode == 200,
                  let bytes = try? Data(contentsOf:file, options:.mappedIfSafe), bytes.count == asset.size,
                  "sha256:" + SHA256.hash(data:bytes).map({String(format:"%02x",$0)}).joined() == digest else {
                throw URLError(.cannotDecodeContentData)
            }
            let folder = try FileManager.default.url(for:.cachesDirectory,in:.userDomainMask,appropriateFor:nil,create:true)
                .appendingPathComponent("local.nespat.app/Updates")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories:true, attributes:[.posixPermissions:0o700])
            let target = folder.appendingPathComponent("NeSpat-\(version).pkg")
            try bytes.write(to:target, options:.atomic)
            package = target
            message = "Готово обновление \(version)"
        } catch {
            if manual { message = "Не удалось проверить выпуск на GitHub. Повторите позже." }
        }
    }
}
