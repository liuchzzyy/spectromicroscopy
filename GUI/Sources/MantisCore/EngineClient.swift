import Foundation
import Darwin

public enum JSONValue: Codable, Sendable, Equatable {
    case string(String), number(Double), bool(Bool), array([JSONValue]), object([String: JSONValue]), null
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([JSONValue].self) { self = .array(v) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }
    public var string: String? { if case .string(let v) = self { v } else { nil } }
    public var description: String { String(data: (try? JSONEncoder().encode(self)) ?? Data(), encoding: .utf8) ?? "" }
    public static func integers(_ values: [Int]) -> Self { .array(values.map { .number(Double($0)) }) }
}

public struct EngineHello: Codable, Sendable {
    public let engine_version: String
    public let `protocol`: Int
    public let capabilities: [String]
}

/// Serial worker queue owns all pipe I/O. The lock only protects process cancellation.
/// No Foundation blocking reads execute on the main actor; both output pipes are drained.
public final class EngineClient: @unchecked Sendable {
    private let queue = DispatchQueue(label: "org.mantis.engine", qos: .userInitiated)
    private let lock = NSLock()
    private var process: Process?
    private var generation = 0
    private var input: Pipe?
    private var output: Pipe?
    private var diagnostics: Pipe?
    private var remainder = Data()
    private var diagnosticTail = Data()
    private var hello: EngineHello?
    private var nextID = 0
    private let executable: URL
    private let arguments: [String]
    private let timeout: TimeInterval
    private let maximumLineBytes: Int

    public init(executable: URL, arguments: [String] = [], timeout: TimeInterval = 300, maximumLineBytes: Int = 32 * 1024 * 1024) {
        self.executable = executable; self.arguments = arguments
        self.timeout = timeout; self.maximumLineBytes = maximumLineBytes
    }
    public static func bundledExecutable(environment: [String: String] = ProcessInfo.processInfo.environment, bundle: Bundle = .main) throws -> URL {
        if let path = environment["MANTIS_ENGINE_PATH"] {
            guard path.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: path) else {
                throw EngineFailure("engine_path", "MANTIS_ENGINE_PATH must name an executable absolute path.")
            }
            return URL(fileURLWithPath: path)
        }
        guard let url = bundle.resourceURL?.appendingPathComponent("engine/mantis-engine"), FileManager.default.isExecutableFile(atPath: url.path) else {
            throw EngineFailure("missing_engine", "The private engine is missing from this application. Rebuild or reinstall the complete MANTiS app bundle.")
        }
        return url
    }
    public func request(_ method: String, params: [String: JSONValue] = [:]) async throws -> Data {
        let epoch = lock.withLock { generation }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    do {
                        guard self.lock.withLock({ self.generation == epoch }) else { throw CancellationError() }
                        if self.hello == nil {
                            try self.launch(epoch: epoch)
                            let result = try self.exchange("hello", params: [:], epoch: epoch)
                            let hello = try JSONDecoder().decode(EngineHello.self, from: result)
                            guard hello.protocol == Wire.protocolVersion else { throw EngineFailure("protocol_mismatch", "Handshake protocol mismatch.") }
                            self.hello = hello
                            if method == "hello" { continuation.resume(returning: result); return }
                        }
                        guard method == "hello" || self.hello!.capabilities.contains(method) else {
                            throw EngineFailure("unsupported_method", "The bundled engine does not advertise \(method).")
                        }
                        continuation.resume(returning: try self.exchange(method, params: params, epoch: epoch))
                    } catch {
                        // Scientific errors preserve the session; transport errors cannot.
                        if !(error is EngineFailure) || ["protocol_mismatch", "response_id", "invalid_response", "transport", "timeout", "response_too_large"].contains((error as? EngineFailure)?.code ?? "") {
                            self.terminateProcess(); self.clearSession()
                        }
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: { self.interrupt() }
    }
    private func launch(epoch: Int) throws {
        let p = Process(); p.executableURL = executable; p.arguments = arguments
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        p.standardInput = stdin; p.standardOutput = stdout; p.standardError = stderr
        var environment = ProcessInfo.processInfo.environment
        environment["PYTHONUNBUFFERED"] = "1"; environment["MPLBACKEND"] = "Agg"
        p.environment = environment
        try lock.withLock {
            guard generation == epoch else { throw CancellationError() }
            try p.run(); process = p
        }
        input = stdin; output = stdout; diagnostics = stderr
        for handle in [stdin.fileHandleForWriting, stdout.fileHandleForReading, stderr.fileHandleForReading] {
            let fd = handle.fileDescriptor
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        }
        _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
    }
    private struct Request: Encodable { let id: Int; let `protocol` = 1; let method: String; let params: [String: JSONValue] }
    private func exchange(_ method: String, params: [String: JSONValue], epoch: Int) throws -> Data {
        nextID += 1
        var request = try JSONEncoder().encode(Request(id: nextID, method: method, params: params)); request.append(10)
        guard request.count <= 1024 * 1024 else { throw EngineFailure("request_too_large", "Request exceeds 1 MiB.") }
        let deadline = Date().addingTimeInterval(timeout)
        let writeFD = input!.fileHandleForWriting.fileDescriptor
        var offset = 0
        while offset < request.count {
            try check(epoch: epoch, deadline: deadline)
            let count = request.withUnsafeBytes { Darwin.write(writeFD, $0.baseAddress!.advanced(by: offset), request.count - offset) }
            if count > 0 { offset += count }
            else if errno != EAGAIN && errno != EINTR { throw EngineFailure("transport", "Engine input closed.") }
            else { var fd = pollfd(fd: writeFD, events: Int16(POLLOUT), revents: 0); _ = poll(&fd, 1, 50) }
        }
        while true {
            try check(epoch: epoch, deadline: deadline)
            if let newline = remainder.firstIndex(of: 10) {
                let line = remainder.prefix(upTo: newline); remainder.removeSubrange(...newline)
                return try Wire.validateResponse(Data(line), id: nextID)
            }
            var fds = [pollfd(fd: output!.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0), pollfd(fd: diagnostics!.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0)]
            _ = poll(&fds, 2, 50)
            for index in 0..<2 where fds[index].revents != 0 {
                var bytes = [UInt8](repeating: 0, count: 8192)
                let count = Darwin.read(fds[index].fd, &bytes, bytes.count)
                if count > 0 {
                    if index == 0 {
                        remainder.append(contentsOf: bytes.prefix(count))
                        guard remainder.count <= maximumLineBytes else { throw EngineFailure("response_too_large", "Engine response exceeded \(maximumLineBytes) bytes.") }
                    } else {
                        diagnosticTail.append(contentsOf: bytes.prefix(count))
                        if diagnosticTail.count > 65536 { diagnosticTail.removeFirst(diagnosticTail.count - 65536) }
                    }
                } else if count == 0 && index == 0 {
                    throw EngineFailure("transport", "Engine exited before a complete response. " + (String(data: diagnosticTail, encoding: .utf8) ?? ""))
                }
            }
        }
    }
    private func check(epoch: Int, deadline: Date) throws {
        guard lock.withLock({ generation == epoch }) else { throw CancellationError() }
        guard Date() < deadline else { throw EngineFailure("timeout", "Engine timed out. The session has been reset.") }
    }
    private func interrupt() { lock.withLock { generation += 1; if let p = process, p.isRunning { p.terminate() } } }
    private func terminateProcess() {
        let p = lock.withLock { process }
        if let p {
            if p.isRunning { p.terminate() }
            let deadline = Date().addingTimeInterval(0.5)
            while p.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
            if p.isRunning { kill(p.processIdentifier, SIGKILL) }
            p.waitUntilExit()
        }
        lock.withLock { process = nil }
    }
    private func clearSession() {
        for h in [input?.fileHandleForWriting, output?.fileHandleForReading, diagnostics?.fileHandleForReading] { try? h?.close() }
        input = nil; output = nil; diagnostics = nil; hello = nil; nextID = 0; remainder.removeAll(); diagnosticTail.removeAll()
    }
    public func stop() async {
        interrupt()
        await withCheckedContinuation { continuation in queue.async { self.terminateProcess(); self.clearSession(); continuation.resume() } }
    }
    deinit { if let process, process.isRunning { kill(process.processIdentifier, SIGKILL) } }
}
