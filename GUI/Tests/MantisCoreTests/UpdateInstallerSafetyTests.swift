import XCTest
@testable import Mantis
import MantisCore

final class UpdateInstallerSafetyTests: XCTestCase {
    private func preparedFixture() throws -> PreparedUpdate {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mantis-handoff-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return PreparedUpdate(app: root.appendingPathComponent("Mantis.app"), helper: root.appendingPathComponent("MantisUpdater"))
    }

    func testFailedHandoffCleansStaging() throws {
        let prepared = try preparedFixture()
        let root = prepared.app.deletingLastPathComponent()
        XCTAssertThrowsError(try UpdateInstaller.handoff(
            prepared, target: root.appendingPathComponent("installed.app"), version: "fixture",
            report: root.appendingPathComponent("report"), launch: { _ in throw MantisError("spawn failed") }
        ))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    func testSuccessfulHandoffKeepsHelperAndStaging() throws {
        let prepared = try preparedFixture()
        let root = prepared.app.deletingLastPathComponent()
        var launched = false
        try UpdateInstaller.handoff(
            prepared, target: root.appendingPathComponent("installed.app"), version: "fixture",
            report: root.appendingPathComponent("report"), launch: { process in
                XCTAssertEqual(process.executableURL, prepared.helper)
                launched = true
            }
        )
        XCTAssertTrue(launched)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.path))
    }

    func testCancelledHandoffCleansStagingWithoutLaunching() async throws {
        let prepared = try preparedFixture()
        let root = prepared.app.deletingLastPathComponent()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try UpdateInstaller.handoff(
                prepared, target: root.appendingPathComponent("installed.app"), version: "fixture",
                report: root.appendingPathComponent("report"), launch: { _ in XCTFail("Cancelled handoff launched") }
            )
        }
        do {
            try await task.value
            XCTFail("Cancelled handoff must throw")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    func testReportSetupFailureCleansStaging() throws {
        let prepared = try preparedFixture()
        let root = prepared.app.deletingLastPathComponent()
        let blocker = root.appendingPathComponent("not-a-directory")
        try Data().write(to: blocker)
        XCTAssertThrowsError(try UpdateInstaller.handoff(
            prepared, target: root.appendingPathComponent("installed.app"), version: "fixture",
            report: blocker.appendingPathComponent("report"), launch: { _ in XCTFail("Report setup failed but helper launched") }
        ))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    func testDownloadDigestMatchesKnownSHA256() throws {
        let prepared = try preparedFixture()
        let file = prepared.app.deletingLastPathComponent().appendingPathComponent("download")
        try Data("abc".utf8).write(to: file)
        XCTAssertEqual(try UpdateInstaller.downloadDigest(file), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }
}
