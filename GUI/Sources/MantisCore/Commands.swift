import Foundation

public enum FieldKind: Sendable { case text, number, integer, toggle, choice([String]), file, files, numbers, json }
public struct ParameterField: Identifiable, Sendable {
    public var id: String { key }
    public let key: String
    public let label: String
    public let kind: FieldKind
    public let initial: String
    public let optional: Bool
    public init(_ key: String, _ label: String, _ kind: FieldKind, _ initial: String = "", optional: Bool = false) {
        self.key = key; self.label = label; self.kind = kind; self.initial = initial; self.optional = optional
    }
}
public struct CommandForm: Identifiable, Sendable {
    public var id: String { title }
    public let title: String
    public let method: String
    public let help: String
    public let fields: [ParameterField]
    public let fixed: [String: JSONValue]
    public let requires: String?
    public init(_ title: String, _ method: String, _ help: String, _ fields: [ParameterField] = [], fixed: [String: JSONValue] = [:], requires: String? = "stack") {
        self.title = title; self.method = method; self.help = help; self.fields = fields; self.fixed = fixed; self.requires = requires
    }
}
public enum CommandCatalog {
    public static var methods: Set<String> { Set(WorkflowSection.allCases.flatMap { forms(for: $0).map(\.method) }).union(["view", "export"]) }
    public static func forms(for section: WorkflowSection) -> [CommandForm] {
        switch section {
        case .load:
            return [
                .init("Open stack", "open", "Read an original stack or a 4D NPZ/HDF5 dataset. No duplicate averaging or implicit normalization.", [.init("path", "Stack file", .file), .init("selection", "Region/channel pairs [[0,0]]", .json, optional: true), .init("pre_normalized", "Input is already optical density", .toggle, "false")], requires: nil),
                .init("Inspect file", "inspect_file", "List available file-plugin regions and channels before choosing a selection.", [.init("path", "Stack file", .file)], requires: nil),
                .init("Build image stack", "build_stack", "File order and energy order must match exactly. Use one energy per single-frame file.", [.init("paths", "Single-frame files (ordered)", .files), .init("energies", "Photon energies (eV)", .numbers)], requires: nil)
            ]
        case .preprocess:
            return [
                .init("Normalize from I₀ file", "normalize", "Two-column energy / incident flux CSV or XAS. Transmission and I₀ must be positive.", [.init("path", "Incident-flux spectrum", .file)], fixed: ["mode": .string("file")]),
                .init("Normalize from rectangle", "normalize", "Draw a rectangle in the image, then use its exclusive-upper-bound pixel coordinates.", [.init("bounds", "x₀, y₀, x₁, y₁", .numbers)], fixed: ["mode": .string("roi")]),
                .init("Normalize from histogram", "normalize", "Select the inclusive intensity limits for incident-flux pixels.", [.init("min", "Minimum intensity", .number), .init("max", "Maximum intensity", .number)], fixed: ["mode": .string("histogram")]),
                .init("Use pre-normalized data", "normalize", "Explicitly declare that values already represent optical density; this is not an automatic correction.", fixed: ["mode": .string("pre_normalized")]),
                .init("Align images", "align", "Fourier registration or explicit per-energy [dx,dy] shifts. Downstream analyses are invalidated.", [.init("reference", "Reference energy index", .integer, "0"), .init("upsample_factor", "Subpixel upsample factor", .integer, "10"), .init("manual_shifts", "Manual shifts [[dx,dy],…]", .json, optional: true), .init("crop", "Crop aligned overlap", .toggle, "true")]),
                .init("Crop stack", "crop", "Pixel bounds and energy indices have exclusive upper limits. Original data remains recoverable with Reset.", [.init("bounds", "x₀, y₀, x₁, y₁", .numbers), .init("energy_range", "First, last exclusive energy index", .numbers)]),
                .init("Subtract dark signal", "dark", "Explicit subtraction; invalid transmission is reported, never clipped.", [.init("value", "Dark signal", .number, "0")]),
                .init("Despike", "despike", "Apply the engine's explicit despiking routine and record its parameters.", [.init("sigma", "Sigma threshold", .number, "5")]),
                .init("Remove image", "remove_image", "Remove one energy frame; invalidates derived analyses.", [.init("index", "Energy index", .integer, "0")]),
                .init("Restore original stack", "reset", "Discard processing and derived analysis for this session. The input file is never modified."),
                .init("Spectral ROI map", "spectral_roi", "Compute −log(mean(post intensity) / mean(pre intensity)). Range upper limits are exclusive.", [.init("pre", "Pre-edge first, last exclusive", .numbers), .init("post", "Post-edge first, last exclusive", .numbers)]),
                .init("Absorbed dose", "dose", "Henke dose workflow. Use measured detector efficiency, composition, pixel dimensions and dwell time; result in Gray.", [.init("composition", "Chemical composition", .text), .init("detector_efficiency", "Detector efficiency (fraction 0–1)", .number, "0.3"), .init("pixel_size_x", "Pixel width (µm)", .number), .init("pixel_size_y", "Pixel height (µm)", .number), .init("dwell_time", "Dwell time (ms)", .number)], requires: "normalized")
            ]
        case .pca:
            return [
                .init("Calculate PCA", "pca", "Use the original MANTiS PCA convention. Examine eigenimages and the scree spectrum before selecting significant components.", [.init("components", "Significant components (optional)", .integer, optional: true)], requires: "normalized"),
                .init("Calculate clusters", "cluster", "k-means classification with explicit reproducible seed.", [.init("clusters", "Number of clusters", .integer, "5"), .init("components", "Significant components", .integer, "3"), .init("remove_first", "Reduce thickness effects", .toggle, "false"), .init("sigma_split", "Divide clusters with large sigma", .toggle, "false"), .init("seed", "Random seed", .integer, "0")], requires: "pca"),
                .init("Find key energies", "key_energies", "Extract key energies from the original PCA-based algorithm.", [.init("threshold", "Detection threshold", .number, "0.1")], requires: "pca")
            ]
        case .spectral:
            return [
                .init("Calculate spectral maps", "spectral", "Load/remap reference spectra and inspect raw or PCA-fitted maps. Added references persist in this session.", [.init("paths", "Reference spectra", .files, optional: true), .init("add_clusters", "Add cluster spectra", .toggle, "false"), .init("flat", "Add a flat spectrum", .toggle, "false"), .init("use_pca", "Fit references with PCA", .toggle, "false")], requires: "normalized"),
                .init("Remove reference", "spectral", "Remove the zero-based target reference and recalculate maps.", [.init("remove", "Reference index", .integer, "0")], requires: "normalized"),
                .init("Reorder reference", "spectral", "Move a target spectrum from one zero-based index to another.", [.init("move", "From, to indices", .numbers)], requires: "normalized"),
                .init("Composite RGB", "rgb", "Assign target-map indices to red, green and blue. Display scaling does not alter map values.", [.init("channels", "Red, green, blue map indices", .numbers, "0, 1, 2")], requires: "normalized")
            ]
        case .nnma:
            return [.init("Calculate NNMA", "nnma", "Original non-negative approximation; negative input is rejected rather than silently clamped. Cluster/standard initialization requires matching component counts.", [.init("components", "Components", .integer, "3"), .init("iterations", "Maximum iterations", .integer, "100"), .init("seed", "Random seed", .integer, "0"), .init("initialization", "Initialization", .choice(["random", "clusters", "standards"]), "random"), .init("paths", "Standard spectra", .files, optional: true), .init("lambda_sparse", "Sparseness λ", .number, "0"), .init("lambda_cluster", "Cluster similarity λ", .number, "0"), .init("lambda_smooth", "Smoothness λ", .number, "0")], requires: "normalized")]
        case .peaks:
            return [.init("Identify peaks", "peaks", "Peak positions are compared with the original predefined reference labels and citations; they are not proof of chemical identity.", [.init("threshold", "Detection threshold", .number, "0.03")])]
        case .fitting:
            return [.init("Fit spectrum", "fit_peaks", "Use an external spectrum or the selected ROI/pixel spectrum. Optional initial arrays must match the number of steps/peaks. No fabricated fit certainty.", [.init("path", "Spectrum file (optional)", .file, optional: true), .init("steps", "Absorption steps", .integer, "1"), .init("peaks", "Gaussian peaks", .integer, "1"), .init("baseline", "Initial baseline", .number, "0"), .init("step_params", "Step [amplitude, center, width] triples", .numbers, optional: true), .init("peak_amplitudes", "Peak amplitudes", .numbers, optional: true), .init("peak_centers", "Peak centers (eV)", .numbers, optional: true), .init("peak_widths", "Peak widths (eV)", .numbers, optional: true)])]
        case .tomography:
            return [.init("Reconstruct volume", "tomography", "Requires 4D input with an explicit theta axis. SIRT/TV use the supported original routines; FBP is explicitly selected. Numeric volumes are included in NPZ/HDF5 exports.", [.init("energy_index", "Energy index", .integer, "0"), .init("algorithm", "Reconstruction algorithm", .choice(["sirt", "tv", "fbp"]), "sirt"), .init("iterations", "Iterations", .integer, "20"), .init("beta", "TV regularization β", .number, "0.1"), .init("slice_index", "Volume slice index (optional)", .integer, optional: true)], requires: "normalized")]
        case .settings, .versions: return []
        }
    }
    public static func parameters(for form: CommandForm, values: [String: String]) throws -> [String: JSONValue] {
        var params = form.fixed
        for field in form.fields {
            let text = (values[field.key] ?? field.initial).trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty && field.optional { continue }
            switch field.kind {
            case .toggle: params[field.key] = .bool(text == "true")
            case .text, .file, .choice:
                guard !text.isEmpty else { throw EngineFailure("parameter", "\(field.label) is required.") }
                params[field.key] = .string(text)
            case .files:
                let paths = text.split(separator: "\n").map(String.init)
                guard !paths.isEmpty else { throw EngineFailure("parameter", "Choose \(field.label).") }
                params[field.key] = .array(paths.map(JSONValue.string))
            case .integer:
                guard let value = Int(text) else { throw EngineFailure("parameter", "\(field.label) must be an integer.") }
                params[field.key] = .number(Double(value))
            case .number:
                guard let value = Double(text), value.isFinite else { throw EngineFailure("parameter", "\(field.label) must be finite.") }
                params[field.key] = .number(value)
            case .numbers:
                let tokens = text.split(whereSeparator: { $0 == "," || $0.isWhitespace })
                let numbers = tokens.compactMap { Double($0) }
                guard !tokens.isEmpty, tokens.count == numbers.count, numbers.allSatisfy(\.isFinite) else { throw EngineFailure("parameter", "\(field.label) needs comma-separated finite numbers.") }
                params[field.key] = .array(numbers.map(JSONValue.number))
            case .json:
                do { params[field.key] = try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)) }
                catch { throw EngineFailure("parameter", "\(field.label) must be valid JSON.") }
            }
        }
        return params
    }
}
