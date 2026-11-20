import Foundation
import Darwin
import CryptoKit
import SystemConfiguration

struct Failure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
let files = FileManager.default
let parent = URL(fileURLWithPath: "/Library/Application Support")
let base = parent.appendingPathComponent("NeSpatPrivileged")
let app = base.appendingPathComponent("NeSpat.app")
let installedHelper = app.appendingPathComponent("Contents/Library/Helpers/NeSpatPrivilegeHelper")
let daemons = URL(fileURLWithPath: "/Library/LaunchDaemons")
let labels = ["local.nespat.recovery", "local.nespat.privilege-helper"]
let resources = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.deletingLastPathComponent()

@discardableResult func run(_ executable: String, _ args: [String]) throws -> String {
    let p = Process(), pipe = Pipe()
    p.executableURL = URL(fileURLWithPath: executable)
    p.arguments = args
    p.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C"]
    p.standardOutput = pipe
    try p.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    guard p.terminationStatus == 0 else { throw Failure("Не удалось выполнить \(executable) (\(p.terminationStatus))") }
    return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
}
func publish(_ from: URL, _ to: URL) throws {
    guard renamex_np(from.path, to.path, UInt32(RENAME_EXCL)) == 0 else { throw Failure("Путь уже занят или недоступен: \(to.path)") }
}
func secureDirectory(_ url: URL) throws {
    var s = stat()
    guard lstat(url.path,&s) == 0, s.st_uid == 0, s.st_mode & S_IFMT == S_IFDIR, s.st_mode & 0o022 == 0 else { throw Failure("Небезопасный каталог: \(url.path)") }
    errno = 0
    if let acl = acl_get_file(url.path, ACL_TYPE_EXTENDED) { acl_free(UnsafeMutableRawPointer(acl)); throw Failure("ACL каталога требует проверки: \(url.path)") }
    guard errno == ENOENT else { throw Failure("Не удалось проверить ACL") }
}
func write(_ bytes: Data, _ url: URL, mode: mode_t) throws {
    try bytes.write(to: url, options: .atomic)
    guard chmod(url.path, mode) == 0 else { throw Failure("Не удалось задать права") }
}
func plist(_ label: String) throws -> Data {
    let watch = label == labels[0]
    var spec: [String: Any] = ["Label":label,"ProgramArguments":[installedHelper.path, watch ? "--watch-exclusive" : "--serve-local"],"RunAtLoad":true,"KeepAlive":true,"ThrottleInterval":2]
    if !watch { spec["MachServices"] = [label:true] }
    return try PropertyListSerialization.data(fromPropertyList: spec, format: .xml, options: 0)
}
func verify(_ bundle: URL) throws {
    let pins = try JSONDecoder().decode([String:String].self, from: Data(contentsOf: resources.appendingPathComponent("pins.json")))
    for (key,id,path) in [("guiHash","local.nespat.app",bundle),("helperHash",labels[1],bundle.appendingPathComponent("Contents/Library/Helpers/NeSpatPrivilegeHelper"))] {
        guard let hash = pins[key], hash.count == 40, hash.allSatisfy(\.isHexDigit) else { throw Failure("Повреждён профиль пакета") }
        try run("/usr/bin/codesign", ["--verify","--strict","--deep","-R=cdhash H\"\(hash)\" and identifier \"\(id)\"",path.path])
    }
}
func install() throws {
    guard geteuid() == 0, CommandLine.arguments.last == "/" else { throw Failure("Требуется установка на загрузочный диск от администратора") }
    for path in ["/","/Library",parent.path,daemons.path] { try secureDirectory(URL(fileURLWithPath:path)) }
    // The installed uninstaller owns the disable/restore/bootout sequence.
    // It takes the same directory lock as install; invoke it before taking that lock.
    if files.fileExists(atPath: base.path) {
        try secureDirectory(base)
        guard files.fileExists(atPath:base.appendingPathComponent("public-install-v1").path) else { throw Failure("Обнаружена другая установка NeSpat") }
        let previousVersion = Bundle(url:app)?.object(forInfoDictionaryKey:"CFBundleShortVersionString") as? String
        guard let previousVersion else { throw Failure("Версия установленного приложения неизвестна") }
        if previousVersion.compare("1.1.0", options:.numeric) == .orderedAscending {
            let settings = try run("/usr/bin/pmset", ["-g"])
            guard settings.components(separatedBy:.newlines).contains(where: {
                $0.split(whereSeparator: { $0.isWhitespace }) == ["SleepDisabled","0"]
            }) else { throw Failure("Для обновления требуется подтверждённый обычный сон") }
            let proc = try run("/bin/ps", ["-axo","comm="])
            guard !proc.components(separatedBy:.newlines).contains(app.appendingPathComponent("Contents/MacOS/NeSpat").path) else {
                throw Failure("Завершите сессию и выберите «Выход» в панели NeSpat перед обновлением")
            }
            let tool = base.appendingPathComponent("Uninstall")
            var st = stat()
            guard lstat(tool.path,&st) == 0, st.st_uid == 0, st.st_mode & S_IFMT == S_IFREG, st.st_mode & 0o022 == 0 else { throw Failure("Проверка прежнего деинсталлятора не прошла") }
            try run(tool.path, ["--uninstall"])
        }
    }
    let fd = open(parent.path,O_RDONLY|O_DIRECTORY|O_NOFOLLOW)
    guard fd >= 0 else { throw Failure("Каталог установки недоступен") }; defer { close(fd) }
    guard flock(fd,LOCK_EX|LOCK_NB) == 0 else { throw Failure("Другая установка уже выполняется") }
    var uid: uid_t = 0, gid: gid_t = 0
    guard let user = SCDynamicStoreCopyConsoleUser(nil,&uid,&gid) as String?, uid >= 501, user != "loginwindow" else { throw Failure("Войдите в обычную учётную запись Mac") }
    let profileURL = base.appendingPathComponent("LocalTrust/profile.json")
    func launchGUI() throws {
        try run("/bin/launchctl",["asuser",String(uid),"/usr/bin/sudo","-H","-u","#\(uid)","/usr/bin/open",app.path])
    }
    let destinations = labels.map { daemons.appendingPathComponent($0+".plist") }
    let existing = files.fileExists(atPath: base.path)
    if existing {
        try secureDirectory(base)
        guard files.fileExists(atPath: base.appendingPathComponent("public-install-v1").path) else { throw Failure("Уже установлена другая версия NeSpat. Завершите сессию и удалите прежнюю версию её деинсталлятором.") }
        try verify(app)
    } else {
        for url in destinations + [URL(fileURLWithPath:"/Library/LaunchAgents/local.nespat.gui.plist")] {
            var s = stat()
            guard lstat(url.path,&s) != 0, errno == ENOENT else { throw Failure("Обнаружена предыдущая служба: \(url.path)") }
        }
        for label in labels {
            if (try? run("/bin/launchctl",["print","system/"+label])) != nil { throw Failure("Служба уже загружена") }
        }
    }
    let stage = parent.appendingPathComponent(".NeSpat-install-"+UUID().uuidString)
    try files.createDirectory(at: stage, withIntermediateDirectories:false, attributes:[.posixPermissions:0o700])
    defer { try? files.removeItem(at:stage) }
    let payload = stage.appendingPathComponent("payload")
    for (name,mode) in [("",0o755),("LocalTrust",0o755),("Runtime",0o755),("State",0o700)] {
        try files.createDirectory(at: name.isEmpty ? payload : payload.appendingPathComponent(name), withIntermediateDirectories:false, attributes:[.posixPermissions:mode])
    }
    let stagedApp = payload.appendingPathComponent("NeSpat.app")
    try run("/usr/bin/ditto",["-x","-k",resources.appendingPathComponent("app.zip").path,payload.path])
    try run("/usr/sbin/chown",["-R","-P","root:wheel",stagedApp.path])
    try run("/bin/chmod",["-RN",stagedApp.path])
    try run("/bin/chmod",["-R","go-w",stagedApp.path])
    try verify(stagedApp)
    guard var profile = try JSONSerialization.jsonObject(with: Data(contentsOf:resources.appendingPathComponent("pins.json"))) as? [String:Any] else { throw Failure("Неверный формат профиля") }
    profile.merge(["version":1,"setup":UUID().uuidString,"allowedUID":uid,"enabled":false,"exclusiveControl":true,"selectedLifetime":true,"trialOnly":false,"trialOnBattery":false,"hostModel":try run("/usr/sbin/sysctl",["-n","hw.model"]),"osBuild":try run("/usr/bin/sw_vers",["-buildVersion"])]) { _,v in v }
    func encoded(_ obj: Any) throws -> Data { try JSONSerialization.data(withJSONObject:obj, options:[.sortedKeys,.withoutEscapingSlashes]) }
    try write(try encoded(profile),payload.appendingPathComponent("LocalTrust/profile.json"),mode:0o644)
    let empty = Data("{\"generation\":1,\"version\":2}".utf8)
    let hash = SHA256.hash(data:empty).map { String(format:"%02x",$0) }.joined()
    try write(try encoded(["payload":empty.base64EncodedString(),"sha256":hash]),payload.appendingPathComponent("State/authority.json"),mode:0o600)
    for name in ["lock","setter.lock"] { try write(Data(),payload.appendingPathComponent("State/"+name),mode:0o600) }
    try write(Data(),payload.appendingPathComponent("public-install-v1"),mode:0o644)
    for label in labels { try write(try plist(label),stage.appendingPathComponent(label),mode:0o644) }
    try files.copyItem(at: resources.appendingPathComponent("setup"), to: payload.appendingPathComponent("Uninstall"))
    try files.copyItem(at: resources.appendingPathComponent("pins.json"), to: payload.appendingPathComponent("pins.json"))
    if existing {
        guard let saved = try JSONSerialization.jsonObject(with: Data(contentsOf:profileURL)) as? [String:Any],
              saved["allowedUID"] as? UInt32 == uid, saved["hostModel"] as? String == profile["hostModel"] as? String,
              saved["osBuild"] as? String == profile["osBuild"] as? String,
              saved["guiHash"] as? String == profile["guiHash"] as? String,
              saved["helperHash"] as? String == profile["helperHash"] as? String else { throw Failure("Сменился владелец, выпуск или версия macOS. Используйте деинсталлятор прежней версии.") }
        profile = saved
    } else { try publish(payload,base) }
    if profile["enabled"] as? Bool != true {
        try run(installedHelper.path,["--check-removable"])
        try run(installedHelper.path,["--check-local"])
    }
    for (label,dst) in zip(labels,destinations) {
        if files.fileExists(atPath:dst.path) {
            guard try Data(contentsOf:dst) == Data(contentsOf:stage.appendingPathComponent(label)) else { throw Failure("Конфликт службы " + label) }
        } else { try publish(stage.appendingPathComponent(label),dst) }
        if (try? run("/bin/launchctl",["print","system/"+label])) == nil {
            try run("/bin/launchctl",["bootstrap","system",dst.path])
        }
    }
    try run("/bin/launchctl",["asuser",String(uid),"/usr/bin/sudo","-H","-u","#\(uid)",app.appendingPathComponent("Contents/MacOS/NeSpat").path,"--verify-local-service"])
    if profile["enabled"] as? Bool != true {
        profile["enabled"] = true
        try write(try encoded(profile),profileURL,mode:0o644)
    }
    _ = symlink(app.path, "/Applications/NeSpat.app")
    try launchGUI()
}
func uninstall() throws {
    guard geteuid() == 0, URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.path == base.appendingPathComponent("Uninstall").path else { throw Failure("Запустите установленный деинсталлятор от администратора") }
    try secureDirectory(parent)
    try secureDirectory(base)
    let fd = open(parent.path,O_RDONLY|O_DIRECTORY|O_NOFOLLOW)
    guard fd >= 0 else { throw Failure("Каталог недоступен") }; defer { close(fd) }
    guard flock(fd,LOCK_EX|LOCK_NB) == 0 else { throw Failure("Другая установка уже выполняется") }
    try verify(app)
    let url = base.appendingPathComponent("LocalTrust/profile.json")
    guard var profile = try JSONSerialization.jsonObject(with:Data(contentsOf:url)) as? [String:Any] else { throw Failure("Повреждён профиль") }
    let destinations = labels.map { daemons.appendingPathComponent($0+".plist") }
    for (label,dst) in zip(labels,destinations) where files.fileExists(atPath:dst.path) {
        guard try Data(contentsOf:dst) == plist(label) else { throw Failure("Неизвестный файл службы") }
    }
    profile["enabled"] = false
    try write(try JSONSerialization.data(withJSONObject:profile),url,mode:0o644)
    for label in labels.reversed() {
        try run(installedHelper.path,["--check-removable"])
        if (try? run("/bin/launchctl",["print","system/"+label])) != nil { try run("/bin/launchctl",["bootout","system/"+label]) }
    }
    try run(installedHelper.path,["--check-removable"])
    for dst in destinations where files.fileExists(atPath:dst.path) { try files.removeItem(at:dst) }
    let link = "/Applications/NeSpat.app"
    if (try? files.destinationOfSymbolicLink(atPath:link)) == app.path { try files.removeItem(atPath:link) }
    try files.removeItem(at:base)
}

do {
    if CommandLine.arguments.dropFirst().count == 2, CommandLine.arguments[1] == "--verify" { try verify(URL(fileURLWithPath:CommandLine.arguments[2])) }
    else if CommandLine.arguments.dropFirst() == ["--uninstall"] { try uninstall() }
    else { try install() }
} catch { fputs("NeSpat: "+error.localizedDescription+"\n",stderr); exit(1) }
