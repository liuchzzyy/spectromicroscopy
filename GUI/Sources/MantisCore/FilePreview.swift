import Foundation

/// Read-only plugin output, deliberately separate from a spectral Snapshot.
public struct FilePreview: Decodable, Sendable {
    public enum Kind: String, Decodable, Sendable { case table, image }
    public let path: String
    public let format: String?
    public let beamline: String?
    public let plugin: String
    public let kind: Kind
    public let columns: [String]?
    public let rows: [[Double]]?
    public let width: Int?
    public let height: Int?
    public let values: [Double]?
    public let metadata: [String: JSONValue]
    public let shape: [Int]?
    public let frame_count: Int?

    public static func decode(_ data: Data) throws -> FilePreview {
        let value = try JSONDecoder().decode(Self.self, from: data)
        switch value.kind {
        case .table:
            guard let columns = value.columns, !columns.isEmpty, let rows = value.rows,
                  rows.allSatisfy({ $0.count == columns.count && $0.allSatisfy(\.isFinite) }) else {
                throw EngineFailure("invalid_preview", "Invalid preview table.")
            }
        case .image:
            guard let width = value.width, let height = value.height, width > 0, height > 0,
                  width <= Int.max / height, let values = value.values,
                  values.count == width * height, values.allSatisfy(\.isFinite) else {
                throw EngineFailure("invalid_preview", "Invalid preview image.")
            }
        }
        return value
    }
}
