import AppKit
import Foundation
import CryptoKit
import MantisCore

struct PreparedUpdate: Sendable {
    let app: URL
    let helper: URL
    init(app: URL, helper: URL) {
        self.app = app
        self.helper = helper
    }
}

enum UpdateInstaller {
    struct Failure: LocalizedError {
        let reason: String
        init(_ reason: String) { self.reason = reason }
        var errorDescription: String? { reason }
    }

    static func prepare(_ release: GUIRelease, helper: URL) async throws -> PreparedUpdate {
        try Task.checkCancellation()
        let fm = FileManager.default
        let directory = fm.temporaryDirectory.appendingPathComponent("mantis-update-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        var handedOff = false
        defer { if !handedOff { try? fm.removeItem(at: directory) } }

        var request = URLRequest(url: release.dmgURL)
        request.timeoutInterval = 60
        let (temporary, response) = try await URLSession.shared.download(for: request)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
            throw Failure("下载失败；请检查网络及 GitHub Release 是否公开")
        }
        let dmg = directory.appendingPathComponent(release.dmgURL.lastPathComponent)
        try fm.moveItem(at: temporary, to: dmg)
        let values = try dmg.resourceValues(forKeys: [.fileSizeKey])
        guard Int64(values.fileSize ?? -1) == release.dmgSize else {
            throw Failure("下载文件大小与 Release 不符")
        }
        if let expectedDigest = release.sha256 {
            let digest = try downloadDigest(dmg)
            guard digest == expectedDigest else {
                throw Failure("SHA-256 校验失败，更新已取消")
            }
        }

        try Task.checkCancellation()
        let mount = directory.appendingPathComponent("mount", isDirectory: true)
        try fm.createDirectory(at: mount, withIntermediateDirectories: true)
        try run("/usr/bin/hdiutil", ["attach", "-readonly", "-nobrowse", "-mountpoint", mount.path, dmg.path],
                error: "无法挂载已校验的 DMG")
        defer { try? run("/usr/bin/hdiutil", ["detach", mount.path], error: "卸载 DMG 失败") }

        let candidate = mount.appendingPathComponent("Mantis.app", isDirectory: true)
        let staged = directory.appendingPathComponent("Mantis.app", isDirectory: true)
        try run("/usr/bin/ditto", [candidate.path, staged.path], error: "无法读取 DMG 内的 Mantis.app")
        guard let bundle = Bundle(url: staged),
              bundle.bundleIdentifier == "org.spectromicroscopy.mantis",
              bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String == release.version else {
            throw Failure("下载的应用标识或版本不符")
        }
        try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", staged.path], error: "下载的应用签名校验失败")
        let stagedHelper = directory.appendingPathComponent("MantisUpdater")
        try fm.copyItem(at: helper, to: stagedHelper)
        try Task.checkCancellation()
        handedOff = true
        return PreparedUpdate(app: staged, helper: stagedHelper)
    }

    static func handoff(_ prepared: PreparedUpdate, target: URL, version: String, report: URL,
                               launch: (Process) throws -> Void = { try $0.run() }) throws {
        var handedOff = false
        defer { if !handedOff { try? FileManager.default.removeItem(at: prepared.app.deletingLastPathComponent()) } }
        try Task.checkCancellation()
        try FileManager.default.createDirectory(at: report.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: report)
        let process = Process()
        process.executableURL = prepared.helper
        process.arguments = [prepared.app.path, target.path, version,
                             "\(ProcessInfo.processInfo.processIdentifier)", report.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try Task.checkCancellation()
        try launch(process)
        handedOff = true
    }

    static func downloadDigest(_ file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            try Task.checkCancellation()
            let chunk = try handle.read(upToCount: 1024 * 1024) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static var resultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/MANTiS/update-result.txt")
    }

    private static func run(_ executable: String, _ arguments: [String], error: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw Failure(error) }
    }
}
