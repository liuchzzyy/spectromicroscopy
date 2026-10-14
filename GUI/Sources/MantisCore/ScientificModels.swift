import Foundation

public struct ScientificImage: Codable, Sendable, Identifiable {
    public var id: String { title }
    public let title: String
    public let width: Int
    public let height: Int
    public let full_width: Int
    public let full_height: Int
    public let values: [Double]
    public let channels: Int?
}
public struct Spectrum: Codable, Sendable, Identifiable {
    public var id: String { name }
    public let name: String
    public let x: [Double]
    public let y: [Double]
}
public struct HistoryEntry: Codable, Sendable {
    public let method: String
    public let params: [String: JSONValue]
}
public struct Snapshot: Codable, Sendable {
    public let source: String
    public let shape: [Int]
    public let energies: [Double]
    public let normalized: Bool
    public let pca_ready: Bool
    public let clusters_ready: Bool
    public let energy_index: Int
    public let selected_x: Int
    public let selected_y: Int
    public let images: [ScientificImage]
    public let spectra: [Spectrum]
    public let metrics: [String: JSONValue]
    public let history: [HistoryEntry]
    public let theta: [Double]?
    public let theta_index: Int?
    public static func decode(_ data: Data) throws -> Snapshot {
        let snapshot = try JSONDecoder().decode(Self.self, from: data)
        guard snapshot.shape.count >= 3, snapshot.shape.allSatisfy({ $0 > 0 }),
              snapshot.energies.count == snapshot.shape[2], snapshot.energies.allSatisfy(\.isFinite),
              snapshot.energies.indices.contains(snapshot.energy_index),
              (0..<snapshot.shape[0]).contains(snapshot.selected_x), (0..<snapshot.shape[1]).contains(snapshot.selected_y) else {
            throw EngineFailure("invalid_snapshot", "Invalid stack shape, energy axis or selected pixel.")
        }
        for image in snapshot.images {
            let channels = image.channels ?? 1
            guard (1...256).contains(image.width), (1...256).contains(image.height),
                  image.full_width > 0, image.full_height > 0, [1, 3].contains(channels),
                  image.values.count == image.width * image.height * channels,
                  image.values.allSatisfy(\.isFinite) else { throw EngineFailure("invalid_snapshot", "Invalid display image dimensions or values.") }
        }
        for spectrum in snapshot.spectra {
            guard spectrum.x.count == spectrum.y.count, spectrum.x.allSatisfy(\.isFinite), spectrum.y.allSatisfy(\.isFinite) else {
                throw EngineFailure("invalid_snapshot", "Invalid spectrum axis or values.")
            }
        }
        return snapshot
    }
}

public enum WorkflowSection: String, CaseIterable, Identifiable, Sendable {
    case load = "Load Data", preprocess = "Preprocess", pca = "PCA / Clusterings", spectral = "Spectral Maps", nnma = "NNMA", peaks = "Peak ID", fitting = "Fitting", tomography = "Tomography", versions = "Version Management", settings = "Settings"
    public var id: String { rawValue }
    public var symbol: String {
        switch self {
        case .load: "square.stack.3d.up"
        case .preprocess: "slider.horizontal.3"
        case .pca: "point.3.connected.trianglepath.dotted"
        case .spectral: "square.3.layers.3d"
        case .nnma: "chart.dots.scatter"
        case .peaks: "waveform.path"
        case .fitting: "function"
        case .tomography: "cube.transparent"
        case .versions: "arrow.down.app"
        case .settings: "gearshape"
        }
    }
    public var subtitle: String {
        switch self {
        case .load: "Open a stack, inspect its channels, or assemble individual images."
        case .preprocess: "Inspect, align and normalize without hidden corrections."
        case .pca: "Find significant components and classify spectral similarity."
        case .spectral: "Map reference spectra and examine composition."
        case .nnma: "Extract non-negative spectra with explicit regularization."
        case .peaks: "Compare detected peaks with the original reference table."
        case .fitting: "Fit absorption steps and Gaussian resonances."
        case .tomography: "Reconstruct an energy channel from an explicit angular axis."
        case .versions: "Inspect native GUI and independent CLI releases."
        case .settings: "Manage startup and window behavior."
        }
    }
}
