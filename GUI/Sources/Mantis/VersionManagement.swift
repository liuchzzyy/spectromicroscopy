import Foundation
import Darwin
import CryptoKit

struct GUIRelease: Decodable, Sendable {
    let version: String
    let tag: String
    let url: URL
    let dmgURL: URL
    let dmgSize: Int64
    let sha256: String?
    let sha256URL: URL?
    let notes: String

    private struct Payload: Decodable {
        let tag_name: String
        let html_url: URL
        let body: String?
        let assets: [Asset]
    }
    private struct Asset: Decodable {
        let name: String
        let browser_download_url: URL
        let digest: String?
        let size: Int64
    }

    static func parse(_ data: Data) throws -> GUIRelease {
        guard data.count < 2_000_000 else { throw VersionError.invalidRelease }
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        let tag = payload.tag_name
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        guard parts(version) != nil,
              (tag == version || tag == "v\(version)"),
              payload.html_url.scheme == "https", payload.html_url.host == "github.com",
              payload.html_url.path == "/liuchzzyy/spectromicroscopy/releases/tag/\(tag)",
              let asset = payload.assets.first(where: { $0.name == "Mantis-\(version)-arm64.dmg" }),
              asset.size > 0, asset.size < 2_000_000_000,
              asset.browser_download_url.scheme == "https", asset.browser_download_url.host == "github.com",
              asset.browser_download_url.path == "/liuchzzyy/spectromicroscopy/releases/download/\(tag)/\(asset.name)" else {
            throw VersionError.invalidRelease
        }
        let digest: String?
        if let raw = asset.digest, raw.hasPrefix("sha256:"), raw.count == 71,
           raw.dropFirst(7).allSatisfy({ $0.isASCII && $0.isHexDigit }) {
            digest = String(raw.dropFirst(7)).lowercased()
        } else {
            digest = nil
        }

        let shaAsset = payload.assets.first(where: {
            $0.name == "\(asset.name).sha256" || $0.name == "Mantis-\(version)-arm64.dmg.sha256"
        })
        let companionURL = shaAsset?.browser_download_url

        return GUIRelease(
            version: version, tag: tag, url: payload.html_url,
            dmgURL: asset.browser_download_url, dmgSize: asset.size,
            sha256: digest, sha256URL: companionURL, notes: payload.body ?? ""
        )
    }

    func withSHA256(_ resolved: String) -> GUIRelease {
        GUIRelease(version: version, tag: tag, url: url, dmgURL: dmgURL,
                   dmgSize: dmgSize, sha256: resolved, sha256URL: sha256URL, notes: notes)
    }

    func resolveDigest() async -> GUIRelease {
        if sha256 != nil { return self }
        guard let sha256URL else { return self }
        var request = URLRequest(url: sha256URL)
        request.timeoutInterval = 15
        request.setValue("MantisNative", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let text = String(data: data, encoding: .utf8) else { return self }
        let hex = text.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
        guard hex.count == 64, hex.allSatisfy({ $0.isASCII && $0.isHexDigit }) else { return self }
        return withSHA256(hex.lowercased())
    }

    static func isNewer(_ version: String, than installed: String) -> Bool {
        guard let next = parts(version), let current = parts(installed) else { return false }
        return current.lexicographicallyPrecedes(next)
    }

    static func parts(_ value: String) -> [Int]? {
        let values = value.split(separator: ".", omittingEmptySubsequences: false)
        guard values.count == 3 else { return nil }
        let parsed = values.compactMap { part -> Int? in
            guard !part.isEmpty, part.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
            return Int(part)
        }
        return parsed.count == 3 ? parsed : nil
    }
}

enum VerifiedUpdateDownload {
    /// Download is a convenience, not an installer. Never replace the existing DMG.
    static func save(_ release: GUIRelease, to destination: URL,
                     fetch: (URL) async throws -> (URL, URLResponse) = { try await URLSession.shared.download(from: $0) }) async throws {
        guard let expected = release.sha256 else { throw VersionError.unverifiedDownload }
        guard !FileManager.default.fileExists(atPath: destination.path) else { throw VersionError.destinationExists }
        let (temporary, response) = try await fetch(release.dmgURL)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              (try? temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) == release.dmgSize else {
            throw VersionError.invalidDownload
        }
        let handle = try FileHandle(forReadingFrom: temporary)
        defer { try? handle.close() }
        var digest = SHA256()
        while true {
            try Task.checkCancellation()
            let chunk = try handle.read(upToCount: 1024 * 1024) ?? Data()
            if chunk.isEmpty { break }
            digest.update(data: chunk)
        }
        let calculated = digest.finalize().map { String(format: "%02x", $0) }.joined()
        guard calculated == expected else { throw VersionError.invalidDownload }
        // create a new destination with O_EXCL to avoid a check-then-replace race.
        let fd = open(destination.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else { throw VersionError.destinationExists }
        var completed = false
        defer {
            close(fd)
            if !completed { try? FileManager.default.removeItem(at: destination) }
        }
        try handle.seek(toOffset: 0)
        while true {
            try Task.checkCancellation()
            let chunk = try handle.read(upToCount: 1024 * 1024) ?? Data()
            if chunk.isEmpty { break }
            try chunk.withUnsafeBytes { buffer in
                guard let base = buffer.baseAddress else { return }
                var offset = 0
                while offset < buffer.count {
                    let written = Darwin.write(fd, base.advanced(by: offset), buffer.count - offset)
                    guard written > 0 else { throw VersionError.invalidDownload }
                    offset += written
                }
            }
        }
        completed = true
    }
}

enum VersionError: LocalizedError {
    case invalidRelease, unavailable, unverifiedDownload, destinationExists, invalidDownload
    var errorDescription: String? {
        switch self {
        case .invalidRelease: "Release metadata does not identify a valid MANTiS arm64 DMG."
        case .unavailable: "No published GUI Release is available yet."
        case .unverifiedDownload: "Release has no SHA-256 digest; download is not offered."
        case .destinationExists: "The destination already exists; select a different filename."
        case .invalidDownload: "DMG download failed size or SHA-256 verification."
        }
    }
}

enum ReleaseCLIVersion {
    static func fetch(tag: String) async -> String? {
        let cleanTag = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidates = [
            "https://raw.githubusercontent.com/liuchzzyy/spectromicroscopy/\(cleanTag)/mantis_xray/__init__.py",
            "https://raw.githubusercontent.com/liuchzzyy/spectromicroscopy/master/mantis_xray/__init__.py"
        ].compactMap { URL(string: $0) }
        for url in candidates {
            var req = URLRequest(url: url)
            req.timeoutInterval = 10
            req.setValue("MantisNative", forHTTPHeaderField: "User-Agent")
            if let (data, resp) = try? await URLSession.shared.data(for: req),
               let http = resp as? HTTPURLResponse, http.statusCode == 200,
               let text = String(data: data, encoding: .utf8) {
                if let match = text.range(of: #"__version__\s*=\s*['"]([^'"]+)['"]"#, options: .regularExpression) {
                    let sub = text[match]
                    let version = sub.split(separator: "=").last?
                        .trimmingCharacters(in: CharacterSet(charactersIn: " \t\r\n'\""))
                    if let version, GUIRelease.parts(version) != nil {
                        return version
                    }
                }
            }
        }
        return nil
    }
}

/// The public CLI is separate from the private engine; neither GUI nor engine version
/// is a valid fallback when a CLI executable cannot be independently identified.
enum CLIVersion {
    static func status(installedExecutable: String?) -> String {
        guard let name = installedExecutable, (name == "mantis-xray" || name == "mantis" || name == "mantis_xray") else { return "Not installed" }
        return name
    }

    static func candidate(preferredPath: String? = nil) -> URL? {
        if let preferred = preferredPath?.trimmingCharacters(in: .whitespacesAndNewlines), !preferred.isEmpty {
            let url = URL(fileURLWithPath: (preferred as NSString).expandingTildeInPath)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        // Known default development and installation locations
        let defaultPaths = [
            "/Users/liuchzzyy/CodeSpace/spectromicroscopy/mantis_xray",
            "/Users/liuchzzyy/CodeSpace/spectromicroscopy/.venv/bin/mantis-xray"
        ]
        for path in defaultPaths {
            if FileManager.default.fileExists(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }
        let envPaths = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        let candidates = envPaths + ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]
        for path in candidates where path.hasPrefix("/") {
            let file = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).appendingPathComponent("mantis-xray")
            if FileManager.default.fileExists(atPath: file.path) { return file }
        }
        return nil
    }

    static func read(from file: URL) -> String? {
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: file.path, isDirectory: &isDir), isDir.boolValue {
            let initPy = file.appendingPathComponent("__init__.py")
            if let content = try? String(contentsOf: initPy, encoding: .utf8) {
                if let match = content.range(of: #"__version__\s*=\s*['"]([^'"]+)['"]"#, options: .regularExpression) {
                    let sub = content[match]
                    let version = sub.split(separator: "=").last?
                        .trimmingCharacters(in: CharacterSet(charactersIn: " \t\r\n'\""))
                    if let version, GUIRelease.parts(version) != nil {
                        return version
                    }
                }
            }
            return nil
        }

        guard file.lastPathComponent == "mantis-xray" || file.lastPathComponent == "mantis" else { return nil }
        // Do not block on a child or descendants holding stdout open. Keep both
        // wall time and output bounded even for an untrusted PATH executable.
        let process = Process(); process.executableURL = file; process.arguments = ["--version"]
        let pipe = Pipe(); process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
        let fd = pipe.fileHandleForReading.fileDescriptor
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        do { try process.run() } catch { return nil }
        var data = Data()
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            var bytes = [UInt8](repeating: 0, count: 128)
            let count = Darwin.read(fd, &bytes, bytes.count)
            if count > 0 {
                data.append(contentsOf: bytes.prefix(count))
                if data.count > 128 { break }
            }
            if !process.isRunning { break }
            Thread.sleep(forTimeInterval: 0.02)
        }
        if process.isRunning {
            process.terminate()
            let end = Date().addingTimeInterval(0.3)
            while process.isRunning && Date() < end { Thread.sleep(forTimeInterval: 0.01) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        process.waitUntilExit()
        guard data.count <= 128, process.terminationStatus == 0,
              let output = String(data: data, encoding: .utf8), output.hasPrefix("mantis-xray CLI "),
              let version = output.split(separator: " ").last.map(String.init),
              GUIRelease.parts(version.trimmingCharacters(in: .whitespacesAndNewlines)) != nil else { return nil }
        return version.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
