import XCTest
@testable import MantisCore

final class UpdateTransactionTests: XCTestCase {
    private func fixture() throws -> (target: URL, staging: URL, backup: URL, failed: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mantis-transaction-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("Mantis.app")
        let staging = root.appendingPathComponent("staging.app")
        for (url, value) in [(target, "old"), (staging, "new")] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try Data(value.utf8).write(to: url.appendingPathComponent("version"))
        }
        return (target, staging, root.appendingPathComponent("backup.app"), root.appendingPathComponent("failed.app"))
    }

    private func version(_ app: URL) throws -> String {
        try String(contentsOf: app.appendingPathComponent("version"), encoding: .utf8)
    }

    func testInstallVerificationFailureRollsBack() throws {
        let f = try fixture()
        XCTAssertThrowsError(try UpdateInstallationTransaction.install(
            staging: f.staging, target: f.target, backup: f.backup, failed: f.failed,
            verify: { _ in throw MantisError("bad signature") },
            launch: { _ in XCTFail("Must not launch unverified app") },
            writeReport: { XCTFail("Must not report success") }
        ))
        XCTAssertEqual(try version(f.target), "old")
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.backup.path))
    }

    func testLaunchFailureRollsBack() throws {
        let f = try fixture()
        XCTAssertThrowsError(try UpdateInstallationTransaction.install(
            staging: f.staging, target: f.target, backup: f.backup, failed: f.failed,
            verify: { _ in },
            launch: { _ in throw MantisError("launch failed") },
            writeReport: { XCTFail("Must not report success") }
        ))
        XCTAssertEqual(try version(f.target), "old")
    }

    func testRollbackFailurePreservesOnlyBackup() throws {
        let f = try fixture()
        XCTAssertThrowsError(try UpdateInstallationTransaction.install(
            staging: f.staging, target: f.target, backup: f.backup, failed: f.failed,
            verify: { _ in throw MantisError("verify failed") },
            launch: { _ in },
            writeReport: {},
            move: { source, target in
                if source == f.backup { throw MantisError("restore denied") }
                try FileManager.default.moveItem(at: source, to: target)
            }
        )) { error in
            XCTAssertTrue(error.localizedDescription.contains(f.backup.path))
        }
        XCTAssertEqual(try version(f.backup), "old")
        XCTAssertEqual(try version(f.failed), "new")
    }

    func testFailedNewBundleCannotBeMovedPreservesBothCopies() throws {
        let f = try fixture()
        XCTAssertThrowsError(try UpdateInstallationTransaction.install(
            staging: f.staging, target: f.target, backup: f.backup, failed: f.failed,
            verify: { _ in throw MantisError("verify failed") },
            launch: { _ in },
            writeReport: {},
            move: { source, target in
                if target == f.failed { throw MantisError("move denied") }
                try FileManager.default.moveItem(at: source, to: target)
            }
        ))
        XCTAssertEqual(try version(f.backup), "old")
        XCTAssertEqual(try version(f.target), "new")
    }

    func testMissingTargetFailsBeforeAnyMove() throws {
        let f = try fixture()
        try FileManager.default.removeItem(at: f.target)
        XCTAssertThrowsError(try UpdateInstallationTransaction.install(
            staging: f.staging, target: f.target, backup: f.backup, failed: f.failed,
            verify: { _ in XCTFail("Must not verify without a target") },
            launch: { _ in XCTFail("Must not launch") },
            writeReport: { XCTFail("Must not report success") }
        )) { error in
            XCTAssertTrue(error.localizedDescription.contains(f.target.path))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.backup.path))
    }
}
