import AppKit
import Foundation
import Darwin
import MantisCore

@main enum MantisUpdater {
    static func main() {
        guard CommandLine.arguments.count == 6 else {
            fputs("Mantis update: 更新参数不完整\n", stderr)
            exit(1)
        }
        let args = CommandLine.arguments
        let source = URL(fileURLWithPath: args[1], isDirectory: true)
        let target = URL(fileURLWithPath: args[2], isDirectory: true)
        let expectedVersion = args[3]
        let oldPID = Int32(args[4]) ?? -1
        let report = URL(fileURLWithPath: args[5])
        do {
            try perform(source: source, target: target, expectedVersion: expectedVersion, oldPID: oldPID, report: report)
        } catch {
            try? "更新失败：\(error.localizedDescription)".write(to: report, atomically: true, encoding: .utf8)
            if FileManager.default.fileExists(atPath: target.path) {
                NSWorkspace.shared.openApplication(at: target, configuration: NSWorkspace.OpenConfiguration()) { _, _ in }
                RunLoop.current.run(until: Date().addingTimeInterval(1))
            }
            fputs("Mantis update: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    private struct Failure: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    private static func info(_ app: URL) -> [String: Any]? {
        let plist = app.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plist),
              let dictionary = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return nil }
        return dictionary
    }

    private static func version(_ app: URL) -> String? {
        info(app)?["CFBundleShortVersionString"] as? String
    }

    private static func verified(_ app: URL, expected: String) throws {
        guard version(app) == expected,
              info(app)?["CFBundleIdentifier"] as? String == "org.spectromicroscopy.mantis" else {
            throw Failure("应用版本或标识不匹配：\(app.path)")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["--verify", "--deep", "--strict", app.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw Failure("应用签名校验失败") }
    }

    private static func perform(source: URL, target: URL, expectedVersion: String, oldPID: Int32, report: URL) throws {
        let fm = FileManager.default
        guard oldPID > 1, source.pathExtension == "app", target.pathExtension == "app",
              source.lastPathComponent == "Mantis.app", target.lastPathComponent == "Mantis.app",
              !source.resolvingSymlinksInPath().path.hasPrefix(target.resolvingSymlinksInPath().path + "/"),
              fm.fileExists(atPath: target.path) else { throw Failure("更新路径无效") }
        try verified(source, expected: expectedVersion)
        let original = version(target)
        guard let original else { throw Failure("原应用无效") }
        try verified(target, expected: original)
        let parent = target.deletingLastPathComponent()
        let backup = parent.appendingPathComponent(".Mantis-backup-\(UUID().uuidString).app")
        let staging = parent.appendingPathComponent(".Mantis-staging-\(UUID().uuidString).app")
        guard fm.isWritableFile(atPath: parent.path) else { throw Failure("应用目录不可写；请在 Finder 中手动更新") }
        // Never replace a running executable; wait for old process to exit
        for _ in 0..<300 {
            if kill(oldPID, 0) != 0 { break }
            Thread.sleep(forTimeInterval: 0.1)
        }
        guard kill(oldPID, 0) != 0 else { throw Failure("MANTiS 未退出，未替换应用") }
        let copies = Process()
        copies.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        copies.arguments = [source.path, staging.path]
        try copies.run()
        copies.waitUntilExit()
        guard copies.terminationStatus == 0 else { throw Failure("复制新版本失败") }
        defer { try? fm.removeItem(at: staging) }
        try verified(staging, expected: expectedVersion)
        let failed = parent.appendingPathComponent(".Mantis-failed-\(UUID().uuidString).app")
        let outcome = try UpdateInstallationTransaction.install(
            staging: staging, target: target, backup: backup, failed: failed,
            verify: { try verified($0, expected: expectedVersion) },
            launch: { target in
                nonisolated(unsafe) var launchResult: Result<Void, Error>?
                NSWorkspace.shared.openApplication(at: target, configuration: NSWorkspace.OpenConfiguration()) { app, error in
                    if let error { launchResult = .failure(error) }
                    else if app == nil { launchResult = .failure(Failure("Launch Services 未返回新应用")) }
                    else { launchResult = .success(()) }
                }
                let deadline = Date().addingTimeInterval(15)
                while launchResult == nil && Date() < deadline {
                    RunLoop.current.run(until: Date().addingTimeInterval(0.05))
                }
                guard let launchResult else { throw Failure("新应用重启超时") }
                try launchResult.get()
            },
            writeReport: {
                try "已更新至 MANTiS \(expectedVersion)；旧版保存在 \(backup.path)".write(to: report, atomically: true, encoding: .utf8)
            })
        if let warning = outcome.reportWarning {
            fputs("Mantis update: 已启动新版，但无法保存更新报告：\(warning)\n", stderr)
        }
    }
}
