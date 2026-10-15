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
    public let origin_x: Int?
    public let origin_y: Int?
    public let visible_width: Int?
    public let visible_height: Int?
    public let minimum: Double?
    public let maximum: Double?
    public let mean: Double?
    public let histogram_counts: [Int]?
    public let histogram_edges: [Double]?
    public var roi_histogram_counts: [Int]?
    public var roi_histogram_edges: [Double]?
    public var roi_minimum: Double?
    public var roi_maximum: Double?
    public var roi_mean: Double?
    public var x0: Int { origin_x ?? 0 }
    public var y0: Int { origin_y ?? 0 }
    public var visibleWidth: Int { visible_width ?? full_width }
    public var visibleHeight: Int { visible_height ?? full_height }
}
public struct SpatialAxes: Codable, Sendable {
    public let x: [Double]
    public let y: [Double]
    public let unit: String?
}
public struct Spectrum: Codable, Sendable, Identifiable {
    public var id: String { name }
    public let name: String
    public let x: [Double]
    public let y: [Double]
    public init(name: String, x: [Double], y: [Double]) {
        self.name = name; self.x = x; self.y = y
    }
}
public struct ROIItem: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var index: Int
    public var label: String
    public var colorHex: String
    public var bounds: [Int] // [x0, y0, x1, y1] bounding box for selection/centering
    public var polygon: [[Double]]? // actual lasso geometry, nil for rectangle or pixel
    public init(id: UUID = UUID(), index: Int, label: String, colorHex: String, bounds: [Int], polygon: [[Double]]? = nil) {
        self.id = id; self.index = index; self.label = label; self.colorHex = colorHex; self.bounds = bounds
        self.polygon = polygon
    }
}
public struct ROIPresets: Sendable {
    public static let colors: [String] = [
        "#E41A1C", // 1: 鲜红 Red
        "#377EB8", // 2: 鲜蓝 Blue
        "#4DAF4A", // 3: 翠绿 Green
        "#984EA3", // 4: 紫罗兰 Purple
        "#FF7F00", // 5: 橙色 Orange
        "#E7298A", // 6: 品红 Magenta
        "#A65628", // 7: 棕色 Brown
        "#17BECF", // 8: 青色 Cyan
        "#E6AB02", // 9: 金黄 Gold
        "#1B9E77"  // 10: 墨绿 Teal
    ]
}
public struct HistoryEntry: Codable, Sendable {
    public let method: String
    public let params: [String: JSONValue]
    public init(method: String, params: [String: JSONValue]) {
        self.method = method
        self.params = params
    }
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
    public let spatial: SpatialAxes?
    public let history: [HistoryEntry]
    public let theta: [Double]?
    public let theta_index: Int?
    public init(source: String, shape: [Int], energies: [Double], normalized: Bool, pca_ready: Bool, clusters_ready: Bool, energy_index: Int, selected_x: Int, selected_y: Int, images: [ScientificImage], spectra: [Spectrum], metrics: [String: JSONValue], spatial: SpatialAxes? = nil, history: [HistoryEntry] = [], theta: [Double]? = nil, theta_index: Int? = nil) {
        self.source = source; self.shape = shape; self.energies = energies
        self.normalized = normalized; self.pca_ready = pca_ready; self.clusters_ready = clusters_ready
        self.energy_index = energy_index; self.selected_x = selected_x; self.selected_y = selected_y
        self.images = images; self.spectra = spectra; self.metrics = metrics
        self.spatial = spatial; self.history = history; self.theta = theta; self.theta_index = theta_index
    }
    public static func decode(_ data: Data) throws -> Snapshot {
        let snapshot = try JSONDecoder().decode(Self.self, from: data)
        guard snapshot.shape.count >= 3, snapshot.shape.allSatisfy({ $0 > 0 }),
              snapshot.energies.count == snapshot.shape[2], snapshot.energies.allSatisfy(\.isFinite),
              snapshot.energies.indices.contains(snapshot.energy_index),
              (0..<snapshot.shape[0]).contains(snapshot.selected_x), (0..<snapshot.shape[1]).contains(snapshot.selected_y) else {
            throw EngineFailure("invalid_snapshot", "Invalid stack shape, energy axis or selected pixel.")
        }
        if let spatial = snapshot.spatial {
            guard spatial.x.count == snapshot.shape[0], spatial.y.count == snapshot.shape[1],
                  spatial.x.allSatisfy(\.isFinite), spatial.y.allSatisfy(\.isFinite),
                  spatial.unit == nil || spatial.unit?.isEmpty == false else {
                throw EngineFailure("invalid_snapshot", "Invalid spatial coordinates or units.")
            }
        }
        for image in snapshot.images {
            let channels = image.channels ?? 1
            guard (1...256).contains(image.width), (1...256).contains(image.height),
                  image.full_width > 0, image.full_height > 0, [1, 3].contains(channels),
                  image.x0 >= 0, image.y0 >= 0, image.visibleWidth > 0, image.visibleHeight > 0,
                  image.x0 <= image.full_width - image.visibleWidth,
                  image.y0 <= image.full_height - image.visibleHeight,
                  image.values.count == image.width * image.height * channels,
                  image.values.allSatisfy(\.isFinite) else { throw EngineFailure("invalid_snapshot", "Invalid display image dimensions or values.") }
            if let counts = image.histogram_counts, let edges = image.histogram_edges {
                guard !counts.isEmpty, edges.count == counts.count + 1,
                      counts.allSatisfy({ $0 >= 0 }), edges.allSatisfy(\.isFinite),
                      zip(edges, edges.dropFirst()).allSatisfy({ $0 < $1 }),
                      let minimum = image.minimum, let maximum = image.maximum,
                      let mean = image.mean, minimum.isFinite, maximum.isFinite, mean.isFinite,
                      minimum <= mean, mean <= maximum else {
                    throw EngineFailure("invalid_snapshot", "Invalid visible-image histogram.")
                }
            } else if image.histogram_counts != nil || image.histogram_edges != nil {
                throw EngineFailure("invalid_snapshot", "Incomplete visible-image histogram.")
            }
            if let counts = image.roi_histogram_counts, let edges = image.roi_histogram_edges {
                guard !counts.isEmpty, edges.count == counts.count + 1,
                      counts.allSatisfy({ $0 >= 0 }), edges.allSatisfy(\.isFinite),
                      zip(edges, edges.dropFirst()).allSatisfy({ $0 < $1 }),
                      let minimum = image.roi_minimum, let maximum = image.roi_maximum,
                      let mean = image.roi_mean, minimum.isFinite, maximum.isFinite, mean.isFinite,
                      minimum <= mean, mean <= maximum else {
                    throw EngineFailure("invalid_snapshot", "Invalid ROI histogram.")
                }
            } else if image.roi_histogram_counts != nil || image.roi_histogram_edges != nil {
                throw EngineFailure("invalid_snapshot", "Incomplete ROI histogram.")
            }
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
