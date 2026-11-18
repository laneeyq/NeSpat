import Foundation
import Darwin

// MARK: - Пути

enum Paths {
    static var supportDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("NeSpat", isDirectory: true)
    }

    static var sessionFile: URL { supportDir.appendingPathComponent("session.json") }

    static var logDir: URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/NeSpat", isDirectory: true)
    }

    static var watchdogLog: URL { logDir.appendingPathComponent("watchdog.log") }

    static func ensureDir(_ url: URL) {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
}

// MARK: - Запуск процессов (без shell)

enum Proc {
    struct Result {
        let code: Int32
        let out: String
        let err: String
        var ok: Bool { code == 0 }
    }

    /// Запускает исполняемый файл с фиксированным argv. Без shell, без интерполяции.
    @discardableResult
    static func run(_ path: String, _ args: [String]) -> Result {
        runTimed(path, args, timeout: 120)
    }

    /// Drain both pipes without blocking. Authorization and subprocess failure must not freeze
    /// the GUI forever. A timeout is an ambiguous outcome, never permission to claim success.
    static func runTimed(_ path: String, _ args: [String], timeout: TimeInterval) -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        let stdout = Pipe(), stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        let outFD = stdout.fileHandleForReading.fileDescriptor
        let errFD = stderr.fileHandleForReading.fileDescriptor
        for fd in [outFD, errFD] { _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) }
        defer {
            try? stdout.fileHandleForReading.close()
            try? stderr.fileHandleForReading.close()
        }
        do { try process.run() }
        catch { return Result(code: -1, out: "", err: error.localizedDescription) }
        try? stdout.fileHandleForWriting.close()
        try? stderr.fileHandleForWriting.close()
        var out = Data(), err = Data()
        var truncated = false
        func drain(_ fd: Int32, into data: inout Data) {
            var bytes = [UInt8](repeating: 0, count: 8192)
            // Bound work per iteration so an output flood cannot bypass the deadline.
            for _ in 0..<32 {
                let count = read(fd, &bytes, bytes.count)
                guard count > 0 else { break }
                if data.count + count <= 1_048_576 { data.append(contentsOf: bytes.prefix(count)) }
                else { truncated = true }
            }
        }
        let deadline = ProcessInfo.processInfo.systemUptime + max(0, timeout)
        var timedOut = false
        while true {
            drain(outFD, into: &out); drain(errFD, into: &err)
            if !process.isRunning { break }
            if ProcessInfo.processInfo.systemUptime >= deadline {
                timedOut = true
                process.terminate()
                let grace = ProcessInfo.processInfo.systemUptime + 0.5
                while process.isRunning, ProcessInfo.processInfo.systemUptime < grace {
                    drain(outFD, into: &out); drain(errFD, into: &err)
                    Thread.sleep(forTimeInterval: 0.01)
                }
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                break
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        process.waitUntilExit()
        drain(outFD, into: &out); drain(errFD, into: &err)
        let detail = timedOut ? "\nКоманда превысила время ожидания; результат неизвестен." : (truncated ? "\nВывод команды превысил лимит." : "")
        return Result(code: timedOut ? -2 : (truncated ? -3 : process.terminationStatus),
                      out: String(decoding: out, as: UTF8.self), err: String(decoding: err, as: UTF8.self) + detail)
    }

    static func displaysleepnow() -> Result {
        run("/usr/bin/pmset", ["displaysleepnow"])
    }
}

// MARK: - Форматирование (русский UI)

enum Fmt {
    static func percent(_ v: Double) -> String {
        "\(Int(v.rounded()))%"
    }

    static func gb(_ bytes: UInt64) -> String {
        let g = Double(bytes) / 1_073_741_824
        if g < 10 { return String(format: "%.1f ГБ", g) }
        return String(format: "%.0f ГБ", g)
    }

    static func duration(_ seconds: TimeInterval) -> String {
        // Never display zero before the absolute deadline; keep seconds visible above an hour.
        guard seconds.isFinite, seconds <= CustomDuration.exactSeconds else { return "—" }
        let total = Int(max(0, seconds).rounded(.up))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return "\(h) ч " + String(format: "%02d мин %02d с", m, s) }
        if m > 0 { return String(format: "%d мин %02d с", m, s) }
        return "\(s) с"
    }
}

// MARK: - Лог сторожа

enum Log {
    private static let queue = DispatchQueue(label: "local.nespat.log")

    static func watchdog(_ message: String) {
        queue.sync {
            Paths.ensureDir(Paths.logDir)
            let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
            if let handle = FileHandle(forWritingAtPath: Paths.watchdogLog.path) {
                handle.seekToEndOfFile()
                handle.write(line.data(using: .utf8)!)
                handle.closeFile()
            } else {
                FileManager.default.createFile(atPath: Paths.watchdogLog.path, contents: line.data(using: .utf8))
            }
        }
    }
}
