import XCTest
@testable import Mantis

final class VersionManagementTests: XCTestCase {
    func testReleaseParserRejectsWrongRepositoryAssetOrTag() throws {
        let valid = #"{"tag_name":"v1.0.1","html_url":"https://github.com/liuchzzyy/spectromicroscopy/releases/tag/v1.0.1","body":"Release notes","assets":[{"name":"Mantis-1.0.1-arm64.dmg","browser_download_url":"https://github.com/liuchzzyy/spectromicroscopy/releases/download/v1.0.1/Mantis-1.0.1-arm64.dmg","size":1234}]}"#
        let parsed = try GUIRelease.parse(Data(valid.utf8))
        XCTAssertEqual(parsed.version, "1.0.1")
        XCTAssertEqual(parsed.dmgSize, 1234)
        XCTAssertThrowsError(try GUIRelease.parse(Data(valid.replacingOccurrences(of: "Mantis-1.0.1-arm64.dmg", with: "other.dmg").utf8)))
        XCTAssertThrowsError(try GUIRelease.parse(Data(valid.replacingOccurrences(of: "v1.0.1", with: "../oops").utf8)))
    }
    func testVerifiedDownloadCopiesOnlyMatchingDigestAndNeverOverwrites() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mantis-update-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("download.dmg")
        try Data("abc".utf8).write(to: source)
        let destination = root.appendingPathComponent("saved.dmg")
        let valid = #"{"tag_name":"v1.0.1","html_url":"https://github.com/liuchzzyy/spectromicroscopy/releases/tag/v1.0.1","assets":[{"name":"Mantis-1.0.1-arm64.dmg","browser_download_url":"https://github.com/liuchzzyy/spectromicroscopy/releases/download/v1.0.1/Mantis-1.0.1-arm64.dmg","size":3,"digest":"sha256:ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"}]}"#
        let release = try GUIRelease.parse(Data(valid.utf8))
        try await VerifiedUpdateDownload.save(release, to: destination, fetch: { _ in (source, HTTPURLResponse(url: release.dmgURL, statusCode: 200, httpVersion: nil, headerFields: nil)!) })
        XCTAssertEqual(try Data(contentsOf: destination), Data("abc".utf8))
        do {
            try await VerifiedUpdateDownload.save(release, to: destination, fetch: { _ in (source, HTTPURLResponse(url: release.dmgURL, statusCode: 200, httpVersion: nil, headerFields: nil)!) })
            XCTFail("Must not overwrite")
        } catch { /* expected */ }
        XCTAssertEqual(try Data(contentsOf: destination), Data("abc".utf8))
        let wrong = try GUIRelease.parse(Data(valid.replacingOccurrences(of: "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", with: String(repeating: "0", count: 64)).utf8))
        let rejected = root.appendingPathComponent("rejected.dmg")
        do {
            try await VerifiedUpdateDownload.save(wrong, to: rejected, fetch: { _ in (source, HTTPURLResponse(url: release.dmgURL, statusCode: 200, httpVersion: nil, headerFields: nil)!) })
            XCTFail("Must reject wrong digest")
        } catch { /* expected */ }
        XCTAssertFalse(FileManager.default.fileExists(atPath: rejected.path))
    }
    func testVersionComparatorDoesNotOfferOlderRelease() {
        XCTAssertTrue(GUIRelease.isNewer("1.2.0", than: "1.1.9"))
        XCTAssertFalse(GUIRelease.isNewer("1.0.0", than: "1.0.0"))
        XCTAssertFalse(GUIRelease.isNewer("1.0.0", than: "1.0.1"))
    }
    @MainActor func testExplicitCLILocationPersistsWithoutChangingBundledEngine() {
        let suite = "mantis.cli.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = InterfacePreferences(defaults: defaults)
        XCTAssertNil(first.cliPath)
        first.cliPath = "/example/.venv/bin/mantis-xray"
        XCTAssertEqual(InterfacePreferences(defaults: defaults).cliPath, "/example/.venv/bin/mantis-xray")
    }
    func testCLIProbeAcceptsActualVersionAndRejectsOtherExecutableOutput() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mantis-cli-probe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("mantis-xray")
        try "#!/bin/sh\nprintf 'mantis-xray CLI 3.3.0\\n'\n".write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        XCTAssertEqual(CLIVersion.read(from: file), "3.3.0")
        try "#!/bin/sh\nprintf 'mantis-engine 3.3.0\\n'\n".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertNil(CLIVersion.read(from: file))
    }
    func testCLIDirectoryPackageVersionReading() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mantis-pkg-\(UUID().uuidString)")
        let pkg = root.appendingPathComponent("mantis_xray")
        try FileManager.default.createDirectory(at: pkg, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let initPy = pkg.appendingPathComponent("__init__.py")
        try "__version__ = '3.3.0'\n".write(to: initPy, atomically: true, encoding: .utf8)
        XCTAssertEqual(CLIVersion.read(from: pkg), "3.3.0")
    }
    func testCompanionSHA256AssetParsing() throws {
        let json = #"""
        {
            "tag_name": "v1.0.1",
            "html_url": "https://github.com/liuchzzyy/spectromicroscopy/releases/tag/v1.0.1",
            "body": "Notes",
            "assets": [
                {
                    "name": "Mantis-1.0.1-arm64.dmg",
                    "browser_download_url": "https://github.com/liuchzzyy/spectromicroscopy/releases/download/v1.0.1/Mantis-1.0.1-arm64.dmg",
                    "size": 50000000
                },
                {
                    "name": "Mantis-1.0.1-arm64.dmg.sha256",
                    "browser_download_url": "https://github.com/liuchzzyy/spectromicroscopy/releases/download/v1.0.1/Mantis-1.0.1-arm64.dmg.sha256",
                    "size": 100
                }
            ]
        }
        """#
        let release = try GUIRelease.parse(Data(json.utf8))
        XCTAssertNil(release.sha256)
        XCTAssertEqual(release.sha256URL?.lastPathComponent, "Mantis-1.0.1-arm64.dmg.sha256")
        let updated = release.withSHA256("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(updated.sha256, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }
    func testIndependentCLIIsNotGuessedFromGUIOrEngine() {
        XCTAssertEqual(CLIVersion.status(installedExecutable: nil), "Not installed")
        XCTAssertEqual(CLIVersion.status(installedExecutable: "mantis-engine"), "Not installed")
    }
}
