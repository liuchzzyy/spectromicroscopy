import Foundation

public struct EngineFailure: Error, LocalizedError, Sendable {
    public let code: String
    public let message: String
    public init(_ code: String, _ message: String) { self.code = code; self.message = message }
    public var errorDescription: String? { "\(code): \(message)" }
}

public enum Wire {
    public static let protocolVersion = 1
    public static func validateResponse(_ data: Data, id: Int) throws -> Data {
        let object: [String: JSONValue]
        do { object = try JSONDecoder().decode([String: JSONValue].self, from: data) }
        catch { throw EngineFailure("invalid_response", "The engine returned malformed JSON.") }
        guard object["protocol"] == .number(Double(protocolVersion)) else {
            throw EngineFailure("protocol_mismatch", "The bundled engine does not support protocol 1.")
        }
        guard object["id"] == .number(Double(id)) else { throw EngineFailure("response_id", "Unexpected response identifier.") }
        guard case .bool(let ok) = object["ok"] else { throw EngineFailure("invalid_response", "Missing boolean response status.") }
        if !ok {
            guard case .object(let failure) = object["error"], let code = failure["code"]?.string, let message = failure["message"]?.string else {
                throw EngineFailure("invalid_response", "Missing structured engine error.")
            }
            throw EngineFailure(code, message)
        }
        guard case .object(let result) = object["result"] else { throw EngineFailure("invalid_response", "Missing result object.") }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(result)
    }
}
