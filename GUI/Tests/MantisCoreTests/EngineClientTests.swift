import XCTest
@testable import MantisCore

final class EngineClientTests: XCTestCase, @unchecked Sendable {
    func script(_ text: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mantis-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("engine.sh")
        try text.write(to: file, atomically: true, encoding: .utf8)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return file
    }
    func testTimeoutReapsEngineAndAllowsFreshHandshake() async throws {
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: marker) }
        let file = try script("""
        printf '%s' $$ > '\(marker.path)'
        trap '' TERM
        while :; do :; done
        """)
        let client = EngineClient(executable: URL(fileURLWithPath: "/bin/sh"), arguments: [file.path], timeout: 0.15)
        do { _ = try await client.request("hello"); XCTFail("Unresponsive engine must fail") }
        catch { XCTAssertEqual((error as? EngineFailure)?.code, "timeout") }
        let pid = try XCTUnwrap(Int32(String(contentsOf: marker, encoding: .utf8)))
        XCTAssertEqual(kill(pid, 0), -1, "Timed-out engine must be reaped")
        await client.stop()
    }
    func testCancellationReapsEngine() async throws {
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: marker) }
        let file = try script("""
        printf '%s' $$ > '\(marker.path)'
        trap '' TERM
        while :; do :; done
        """)
        let client = EngineClient(executable: URL(fileURLWithPath: "/bin/sh"), arguments: [file.path], timeout: 10)
        let task = Task { try await client.request("hello") }
        for _ in 0..<100 where !FileManager.default.fileExists(atPath: marker.path) { try await Task.sleep(for: .milliseconds(10)) }
        let pid = try XCTUnwrap(Int32(String(contentsOf: marker, encoding: .utf8)))
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled request must fail") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(kill(pid, 0), -1)
        await client.stop()
    }
    func testScientificFailurePreservesProcessAndDrainsDiagnostics() async throws {
        let file = try script("""
        read hello
        printf '%s\\n' '{"id":1,"protocol":1,"ok":true,"result":{"engine_version":"fixture","protocol":1,"capabilities":["view"]}}'
        read first
        i=0; while [ "$i" -lt 2000 ]; do printf '%080d\\n' 0 >&2; i=$((i+1)); done
        printf '%s\\n' '{"id":2,"protocol":1,"ok":false,"error":{"code":"invalid_data","message":"Bad input"}}'
        read second
        printf '%s\\n' '{"id":3,"protocol":1,"ok":true,"result":{"preserved":true}}'
        """)
        let client = EngineClient(executable: URL(fileURLWithPath: "/bin/sh"), arguments: [file.path], timeout: 3)
        do { _ = try await client.request("view"); XCTFail("Must report scientific failure") }
        catch { XCTAssertEqual((error as? EngineFailure)?.code, "invalid_data") }
        let next = try await client.request("view")
        XCTAssertEqual(try JSONDecoder().decode([String: Bool].self, from: next), ["preserved": true])
        await client.stop()
    }
    func testLaunchHandshakeAndSequentialRequest() async throws {
        let file = try script("""
        read hello
        printf '%s\n' '{"id":1,"protocol":1,"ok":true,"result":{"engine_version":"3.3.0","protocol":1,"capabilities":["view"]}}'
        read command
        printf '%s\n' '{"id":2,"protocol":1,"ok":true,"result":{"source":"synthetic fixture"}}'
        """)
        let client = EngineClient(executable: URL(fileURLWithPath: "/bin/sh"), arguments: [file.path])
        let data = try await client.request("view")
        XCTAssertEqual(String(data: data, encoding: .utf8), #"{"source":"synthetic fixture"}"#)
        await client.stop()
    }
}
