import AppKit
import SwiftUI
import MantisCore
import UniformTypeIdentifiers

@MainActor
final class WorkspaceModel: ObservableObject {
    @Published var section: WorkflowSection = .load
    @Published var snapshot: Snapshot?
    @Published var results: [WorkflowSection: Snapshot] = [:]
    @Published var handshake: EngineHello?
    @Published var busy = false
    @Published var status = "Not connected"
    @Published var error: String?
    @Published var inspection: String?
    @Published var inspectionInfo: FileInspectionInfo?
    @Published private(set) var filePreview: FilePreview?
    @Published var selectedChannelKey: String = "auto"
    @Published var openAsOpticalDensity = false
    @Published var selectedImage = 0
    @Published var energyIndex = 0
    @Published var thetaIndex = 0
    @Published var display = "intensity"
    @Published var roiMode = "Pixel"
    @Published var rectangle: [Int]?
    @Published var polygon: [[Double]]?
    @Published var pendingPixel: [Int]?
    @Published var contrastLow = 0.0
    @Published var contrastHigh = 1.0
    @Published var gamma = 1.0
    @Published var colorMap = "Viridis"
    @Published var spatialDisplay = "pixels"
    @Published var zoomLevel = 1
    @Published var viewport: [Int]?
    @Published var exportFormat = "npz"
    @Published var lastMethod = ""

    // Load Data - Import settings
    @Published var importFileMode = "single" // "single" or "merge"
    @Published var importFileFormat = "all" {
        didSet {
            if oldValue != importFileFormat {
                importSelection = ""
                inspection = nil
                inspectionInfo = nil
                selectedChannelKey = "auto"
            }
        }
    }
    @Published var importFilePath = "" {
        didSet {
            if oldValue != importFilePath {
                filePreview = nil
                importSelection = ""
                inspection = nil
                inspectionInfo = nil
                selectedChannelKey = "auto"
            }
        }
    }
    @Published var importSelection = "" {
        didSet {
            if oldValue != importSelection {
                syncChannelKeyFromSelection()
            }
        }
    }
    var displayFormatName: String? {
        if let format = (filePreview?.format ?? inspectionInfo?.format)?.trimmingCharacters(in: .whitespacesAndNewlines), !format.isEmpty {
            return format
        }
        let suffix = URL(fileURLWithPath: importFilePath.trimmingCharacters(in: .whitespacesAndNewlines)).pathExtension.lowercased()
        switch suffix {
        case "hdr", "xim": return "SDF"
        case "h5", "hdf5", "hdf", "nxs", "stxm": return "HDF5"
        case "npz": return "NPZ"
        case "tif", "tiff": return "TIFF"
        case "xrm", "txrm": return "XRM"
        case "csv": return "CSV"
        case "json": return "JSON"
        default:
            return importFileFormat != "all" ? importFileFormat.uppercased() : "Default"
        }
    }
    var displayBeamlineName: String {
        if let beamline = (filePreview?.beamline ?? inspectionInfo?.beamline)?.trimmingCharacters(in: .whitespacesAndNewlines), !beamline.isEmpty {
            return beamline
        }
        return "Default"
    }
    struct ImportSelectionGuide {
        let placeholder: String
        let detail: String
        let supportsSelection: Bool
    }
    var importSelectionGuide: ImportSelectionGuide {
        // The chosen file is authoritative; the format picker is only a hint before a path is entered.
        let suffix = URL(fileURLWithPath: importFilePath.trimmingCharacters(in: .whitespacesAndNewlines)).pathExtension.lowercased()
        let format: String
        switch suffix {
        case "hdr": format = "hdr"
        case "h5", "hdf5", "hdf", "nxs", "stxm": format = "hdf5"
        case "npz": format = "npz"
        default: format = importFileFormat
        }
        switch format {
        case "hdr": return ImportSelectionGuide(placeholder: "e.g. [[0, 0]] (optional)",
            detail: "SDF: parameter 1 = region index, parameter 2 = channel index (zero-based); e.g. [[0, 0]]. Leave blank for one pair; inspect multi-pair files.", supportsSelection: true)
        case "hdf5": return ImportSelectionGuide(placeholder: "Leave blank unless selection is required",
            detail: "HDF5: MISTRAL/Exchange need no selection; inspect multi-channel NXstxm and enter [[region, channel]] if required.", supportsSelection: true)
        case "npz": return ImportSelectionGuide(placeholder: "No selection needed",
            detail: "NPZ: region/channel selection is not available.", supportsSelection: false)
        default: return ImportSelectionGuide(placeholder: "e.g. [[0, 0]] (optional)",
            detail: "Optional zero-based [[region, channel]] pairs. Inspect the file before choosing when multiple pairs exist.", supportsSelection: true)
        }
    }
    func parsedImportSelection() throws -> JSONValue? {
        let text = importSelection.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return nil }
        guard importSelectionGuide.supportsSelection else {
            throw EngineFailure("parameter", "This format has no region/channel selection; leave this field blank.")
        }
        guard let data = text.data(using: .utf8),
              let pairs = try? JSONSerialization.jsonObject(with: data) as? [[Any]],
              !pairs.isEmpty,
              pairs.allSatisfy({ indices in
                  indices.count == 2 && indices.allSatisfy({ index in
                      guard let number = index as? NSNumber,
                            CFGetTypeID(number) != CFBooleanGetTypeID(),
                            !["d", "f"].contains(String(cString: number.objCType)) else { return false }
                      let value = number.int64Value
                      return value >= 0 && value <= 9_007_199_254_740_991
                  })
              }) else {
            throw EngineFailure("parameter", "Region/channel pairs must be nonnegative integer JSON pairs like [[0,0]].")
        }
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }
    func selectChannel(region: Int, channel: Int) {
        let key = "\(region)_\(channel)"
        selectedChannelKey = key
        importSelection = "[[\(region), \(channel)]]"
    }
    func selectChannelKey(_ key: String) {
        selectedChannelKey = key
        if key == "auto" {
            importSelection = ""
        } else if key == "manual" {
            // retain current importSelection for manual editing
        } else if let sel = inspectionInfo?.selections.first(where: { $0.key == key }) {
            importSelection = "[[\(sel.selection[0]), \(sel.selection[1])]]"
        }
    }
    func syncChannelKeyFromSelection() {
        let trimmed = importSelection.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            if selectedChannelKey != "auto" { selectedChannelKey = "auto" }
            return
        }
        guard let data = trimmed.data(using: .utf8),
              let pairs = try? JSONSerialization.jsonObject(with: data) as? [[Any]],
              pairs.count == 1,
              let pair = pairs.first, pair.count == 2,
              let r = pair[0] as? Int,
              let c = pair[1] as? Int else {
            if selectedChannelKey != "manual" { selectedChannelKey = "manual" }
            return
        }
        let key = "\(r)_\(c)"
        if inspectionInfo?.selections.contains(where: { $0.key == key }) == true {
            if selectedChannelKey != key { selectedChannelKey = key }
        } else {
            if selectedChannelKey != "manual" { selectedChannelKey = "manual" }
        }
    }
    @Published var mergeFilePaths: [String] = []
    @Published var mergeEnergiesText = ""

    // Load Data - Export settings
    @Published var dataExportFormat = "npz"
    @Published var showInspector: Bool = true
    @Published var dataExportPath = ""
    @Published var selectedExportTarget: String = "AllData"
    @Published var selectedDataGroups: Set<String> = ["processed", "raw", "analysis", "spectra"]
    static let dataGroupOrder = ["processed", "raw", "normalization", "analysis", "spectra"]

    public struct ExportDataOption: Identifiable, Equatable {
        public let id: String
        public let displayName: String
        public let groups: Set<String>
        public let baseFileName: String
    }

    var exportDataOptions: [ExportDataOption] {
        var opts: [ExportDataOption] = []
        let isMerge = importFileMode == "merge" || mergeFilePaths.count >= 2

        // 1. 全选 (AllData)
        let allGroups = Set(availableDataGroups)
        opts.append(ExportDataOption(
            id: "AllData",
            displayName: "AllData",
            groups: allGroups,
            baseFileName: isMerge ? "AllDataMerge" : "AllData"
        ))

        // 2. 原始数据 (RawData / RawDataMerge)
        let rawName = isMerge ? "RawDataMerge" : "RawData"
        opts.append(ExportDataOption(
            id: rawName,
            displayName: rawName,
            groups: ["raw"],
            baseFileName: rawName
        ))

        // 3. 处理后数据 (ProcessedData)
        opts.append(ExportDataOption(
            id: "ProcessedData",
            displayName: "ProcessedData",
            groups: ["processed"],
            baseFileName: "ProcessedData"
        ))

        // 4. 归一化数据 (NormalizedData)
        if snapshot?.normalized == true {
            opts.append(ExportDataOption(
                id: "NormalizedData",
                displayName: "NormalizedData",
                groups: ["normalization"],
                baseFileName: "NormalizedData"
            ))
        }

        // 5. ROI 谱图数据
        if !rois.isEmpty {
            for roi in rois {
                let name = "ROI\(roi.index)"
                opts.append(ExportDataOption(
                    id: name,
                    displayName: name,
                    groups: ["spectra"],
                    baseFileName: name
                ))
            }
        } else {
            opts.append(ExportDataOption(
                id: "SpectraData",
                displayName: "SpectraData",
                groups: ["spectra"],
                baseFileName: "SpectraData"
            ))
        }

        // 6. 分析与映射结果
        if section != .load || !results.isEmpty {
            let mappingName: String
            if let activeROI = rois.first(where: { $0.index == selectedROIIndex }) {
                mappingName = "ROI\(activeROI.index)ImageMapping"
            } else {
                mappingName = "ROIImageMapping"
            }
            opts.append(ExportDataOption(
                id: mappingName,
                displayName: mappingName,
                groups: ["analysis"],
                baseFileName: mappingName
            ))
        }
        return opts
    }

    var currentDataExportBaseName: String {
        if dataExportFormat == "csv" { return "SpectraData" }
        if let opt = exportDataOptions.first(where: { $0.id == selectedExportTarget }) {
            return opt.baseFileName
        }
        let isMerge = importFileMode == "merge" || mergeFilePaths.count >= 2
        return isMerge ? "RawDataMerge" : "RawData"
    }

    var currentImageExportBaseName: String {
        if section != .load {
            if let activeROI = rois.first(where: { $0.index == selectedROIIndex }) {
                return "ROI\(activeROI.index)ImageMapping"
            }
            return "ROIImageMapping"
        } else {
            if let activeROI = rois.first(where: { $0.index == selectedROIIndex }) {
                return "ROI\(activeROI.index)Image"
            }
            let isMerge = importFileMode == "merge" || mergeFilePaths.count >= 2
            return isMerge ? "RawDataMergeImage" : "RawDataImage"
        }
    }

    static func dataGroupLabel(_ group: String) -> String {
        switch group {
        case "processed": return "Processed stack"
        case "raw": return "Raw stack"
        case "normalization": return "OD and normalization"
        case "analysis": return "Analysis results"
        case "spectra": return "Current spectra"
        default: return group
        }
    }
    var availableDataGroups: [String] { Self.dataGroupOrder.filter { $0 != "normalization" || snapshot?.normalized == true } }
    var canExportProcessedData: Bool {
        snapshot != nil && (dataExportFormat == "csv" ||
            (!selectedDataGroups.isEmpty && selectedDataGroups.isSubset(of: Set(availableDataGroups))))
    }
    var canExportWorkflowLog: Bool { snapshot != nil && !busy && supports("export") }
    func dataExportParameters(path: String) -> [String: JSONValue] {
        var params: [String: JSONValue] = ["path": .string(path), "format": .string(dataExportFormat),
                                            "overwrite": .bool(FileManager.default.fileExists(atPath: path))]
        if dataExportFormat != "csv" {
            params["include"] = .array(Self.dataGroupOrder.filter { selectedDataGroups.contains($0) }.map(JSONValue.string))
            if let roi = rois.first(where: { "ROI\($0.index)" == selectedExportTarget }) {
                params["spectrum_name"] = .string(roi.label)
            }
        }
        return params
    }
    @Published var imageExportFormat = "png"
    @Published var imageExportDPI = 300
    @Published var imageExportPath = ""
    @Published var logExportFormat = "json" // "json" or "md"
    @Published var logExportPath = ""
    @Published var interactionPoint: (Int, Int)?

    // Multi-ROI support (up to 10 ROIs)
    @Published var rois: [ROIItem] = []
    @Published var selectedROIIndex: Int? = nil
    @Published private var selectedNonROISeries = "All spectra"
    @Published var roiWarning: String? = nil

    private var client: EngineClient?
    private var operation: Task<Void, Never>?
    private var operationID = UUID()
    private(set) var preview = false
    /// Which panel currently displays the result the engine last produced as its
    /// current view. Graphics exports render that view, not necessarily `shown`.
    private enum EngineView: Equatable { case stack, section(WorkflowSection) }
    private var engineView: EngineView = .stack

    init(preview: Bool = false) { self.preview = preview }
    @Published private(set) var stackView: Snapshot?
    var shown: Snapshot? { results[section] ?? stackView }
    var displayedSpectra: [Spectrum] {
        let activeLabels = Set(rois.map(\.label))
        return (shown?.spectra ?? []).filter { spectrum in
            // Keep unrelated analysis series, but hide a stale ROI curve during removal.
            let isManagedROI = (1...10).contains { spectrum.name == "[\($0)] ROI \($0)" }
            return !isManagedROI || activeLabels.contains(spectrum.name)
        }
    }
    var availableImages: [ScientificImage] { shown?.images ?? [] }
    var image: ScientificImage? {
        guard var value = availableImages.indices.contains(selectedImage) ? availableImages[selectedImage] : availableImages.first else { return nil }
        // Hide the old ROI histogram immediately; the engine then recomputes the full-image view.
        if selectedROIIndex == nil && rois.isEmpty {
            value.roi_histogram_counts = nil
            value.roi_histogram_edges = nil
            value.roi_minimum = nil
            value.roi_maximum = nil
            value.roi_mean = nil
        }
        return value
    }
    var connected: Bool { handshake != nil }
    /// The footer states a connection only when something is wrong: telling a user
    /// that a working engine works is noise.
    static func sidebarStatusLabel(connected: Bool) -> String? { connected ? nil : "Not connected" }
    var visibleStatus: String? { status == "Engine connected" ? nil : status }
    struct SourceSummaryCell: Identifiable, Equatable {
        let label: String
        let value: String
        var id: String { label }
    }
    /// One row of real metadata. Labels and values are raw keys the view localizes.
    var sourceSummaryRows: [[SourceSummaryCell]] {
        let snapshot = self.snapshot
        let range: String = snapshot.flatMap { value in
            guard let first = value.energies.first, let last = value.energies.last else { return nil }
            return String(format: "%.3f–%.3f eV", first, last)
        } ?? "—"
        return [[
            SourceSummaryCell(label: "SHAPE", value: snapshot?.shape.map(String.init).joined(separator: " × ") ?? "—"),
            SourceSummaryCell(label: "SIGNAL", value: snapshot.map { $0.normalized ? "Optical density" : "Intensity" } ?? "—"),
            SourceSummaryCell(label: "Energy", value: snapshot?.energies.count.description ?? "—"),
            SourceSummaryCell(label: "Energy range", value: range),
            SourceSummaryCell(label: "X resolution / pixel",
                              value: Self.pixelResolution(axis: snapshot?.spatial?.x ?? [], unit: snapshot?.spatial?.unit, sourceValue: snapshot?.spatial?.x_pixel_size)),
            SourceSummaryCell(label: "Y resolution / pixel",
                              value: Self.pixelResolution(axis: snapshot?.spatial?.y ?? [], unit: snapshot?.spatial?.unit, sourceValue: snapshot?.spatial?.y_pixel_size)),
        ]]
    }
    struct SignalOption: Identifiable, Hashable {
        public let id: String
        public let title: String
    }
    /// One control for both the display signal and the analysis images, so the header
    /// never shows two boxes that render the same word.
    private var showsStackSignal: Bool {
        guard let first = availableImages.first else { return true }
        return first.title == "Intensity" || first.title == "Optical density"
    }
    var signalOptions: [SignalOption] {
        var options: [SignalOption] = []
        if showsStackSignal {
            if snapshot?.input_is_od != true {
                options.append(SignalOption(id: "display:intensity", title: "Intensity"))
            }
            if canDisplayOpticalDensity { options.append(SignalOption(id: "display:od", title: "Optical density")) }
        }
        for (index, image) in availableImages.enumerated() where !showsStackSignal || index > 0 {
            options.append(SignalOption(id: "image:\(index)", title: image.title))
        }
        return options
    }
    var selectedSignalOptionID: String {
        if showsStackSignal && selectedImage == 0 { return "display:\(display)" }
        return "image:\(availableImages.indices.contains(selectedImage) ? selectedImage : 0)"
    }
    var showsImagePicker: Bool { availableImages.count > 1 }
    @discardableResult
    func selectSignal(_ id: String) -> Bool {
        guard signalOptions.contains(where: { $0.id == id }) else { return false }
        if id.hasPrefix("image:"), let index = Int(id.dropFirst("image:".count)) {
            selectedImage = index
        } else {
            selectedImage = 0
            display = id == "display:od" ? "od" : "intensity"
            updateView()
        }
        return true
    }
    var activeROILabel: String? { rois.first(where: { $0.index == selectedROIIndex })?.label }
    var selectedSeriesName: String {
        if showsStackSignal, let activeROILabel { return activeROILabel }
        return displayedSpectra.contains(where: { $0.name == selectedNonROISeries }) ? selectedNonROISeries : "All spectra"
    }
    /// ROI selection is shared by the spectrum picker, image badges and histogram.
    @discardableResult
    func selectSeries(named name: String) -> Bool {
        guard !busy else { return false }
        if let roi = rois.first(where: { $0.label == name }) {
            guard selectedROIIndex != roi.index else { return true }
            selectedROIIndex = roi.index
            updateView()
            return true
        }
        guard name == "All spectra" || displayedSpectra.contains(where: { $0.name == name }) else { return false }
        let wasROI = selectedROIIndex != nil
        selectedROIIndex = nil
        selectedNonROISeries = name
        if !showsStackSignal, let index = availableImages.firstIndex(where: { $0.title == name }) {
            selectedImage = index
        }
        if wasROI && showsStackSignal { updateView() }
        return true
    }
    static let dataExportFieldOrder = ["format", "data"]
    static let dataExportActionTitle = "Export Data…"
    static let dataExportActionUsesIcon = false
    func supports(_ method: String) -> Bool { handshake?.capabilities.contains(method) == true }
    func enabled(_ form: CommandForm) -> Bool {
        guard !busy, !preview, supports(form.method) else { return false }
        switch form.requires {
        case "stack": return snapshot != nil
        case "normalized": return snapshot?.normalized == true
        case "pca": return snapshot?.pca_ready == true
        default: return true
        }
    }
    func connect() {
        guard !busy, !preview else { return }
        if client == nil {
            do { client = EngineClient(executable: try EngineClient.bundledExecutable()) }
            catch { self.error = error.localizedDescription; status = "Engine unavailable"; return }
        }
        run("hello")
    }
    func run(_ method: String, _ params: [String: JSONValue] = [:]) {
        if filePreview != nil && !["hello", "inspect_file", "preview_file", "open", "build_stack"].contains(method) {
            error = "Read-only preview; spectral analysis is unavailable."
            return
        }
        guard !busy, !preview, let client else { return }
        guard method == "hello" || supports(method) else { error = "This engine does not advertise \(method)."; return }
        busy = true; error = nil; status = "Running \(method)…"; lastMethod = method
        let id = UUID(); operationID = id; let target = section
        operation = Task {
            do {
                let data = try await client.request(method, params: params)
                guard operationID == id, !Task.isCancelled else { return }
                if method == "hello" {
                    handshake = try JSONDecoder().decode(EngineHello.self, from: data)
                } else if method == "preview_file" {
                    acceptPreview(try FilePreview.decode(data))
                } else if method == "inspect_file" {
                    inspection = Self.pretty(data)
                    if let decoded = try? JSONDecoder().decode(FileInspectionInfo.self, from: data) {
                        inspectionInfo = decoded
                        syncChannelKeyFromSelection()
                    }
                } else {
                    let next = try Snapshot.decode(data)
                    accept(next, method: method, target: target)
                }
                status = method == "hello" ? "Engine connected" : "Completed \(method)"
            } catch {
                guard operationID == id else { return }
                self.error = error.localizedDescription; status = "Operation failed"
                if error is CancellationError || ["transport", "timeout", "protocol_mismatch", "invalid_snapshot", "response_id", "response_too_large"].contains((error as? EngineFailure)?.code ?? "") {
                    await client.stop(); clearSession(); status = "Session reset after engine failure"
                }
            }
            if operationID == id { busy = false; operation = nil }
        }
    }
    func acceptPreview(_ value: FilePreview) {
        snapshot = nil; stackView = nil; results.removeAll()
        rois.removeAll(); selectedROIIndex = nil; rectangle = nil; polygon = nil; pendingPixel = nil
        inspection = nil; inspectionInfo = nil
        filePreview = value; section = .load
    }
    func previewFile() {
        let path = importFilePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return }
        run("preview_file", ["path": .string(path)])
    }
    func accept(_ next: Snapshot, method: String, target: WorkflowSection) {
        filePreview = nil
        if snapshot?.theta_index != next.theta_index { results.removeAll() }
        snapshot = next; energyIndex = next.energy_index; thetaIndex = next.theta_index ?? 0
        // The engine owns current-data semantics. The import checkbox belongs to
        // the next file and must never relabel an already loaded stack.
        if let signal = next.display { display = signal }
        else if next.images.first?.title == "Optical density" { display = "od" }
        else if next.images.first?.title == "Intensity" { display = "intensity" }
        if !next.normalized { selectedDataGroups.remove("normalization") }
        else if ["open", "build_stack", "normalize"].contains(method) &&
                    selectedDataGroups == ["processed", "raw", "analysis", "spectra"] {
            selectedDataGroups.insert("normalization")
        }
        interactionPoint = (next.selected_x, next.selected_y)
        let resetMethods: Set<String> = ["open", "build_stack", "normalize", "crop", "dark", "despike", "align", "remove_image", "reset"]
        if method == "pca" || method == "cluster" {
            results[.spectral] = nil; results[.nnma] = nil
        }
        if resetMethods.contains(method) { selectedNonROISeries = "All spectra"; results.removeAll(); rectangle = nil; polygon = nil; pendingPixel = nil; rois.removeAll(); selectedROIIndex = nil; selectedExportTarget = "AllData"; selectedDataGroups = Set(availableDataGroups); selectedImage = 0; viewport = nil; zoomLevel = 1; stackView = next; engineView = .stack }
        else if method != "view" && method != "export" { results[target] = next; selectedImage = 0; engineView = .section(target) }
        if method == "view" { results[target] = nil; stackView = next; engineView = .stack }
        if next.spatial?.unit == nil { spatialDisplay = "pixels" }
    }
    func cancel() {
        guard let client else { return }
        operationID = UUID(); operation?.cancel(); operation = nil
        busy = true; status = "Stopping engine and clearing session…"
        Task { await client.stop(); clearSession(); busy = false; status = "Cancelled — session cleared" }
    }
    func waitUntilIdle() async { await operation?.value }
    func close() async {
        operationID = UUID(); operation?.cancel(); await client?.stop()
        operation = nil; clearSession(); busy = false
    }
    private func clearSession() {
        filePreview = nil
        snapshot = nil; results.removeAll(); handshake = nil; rectangle = nil; polygon = nil; pendingPixel = nil; inspection = nil; inspectionInfo = nil; selectedChannelKey = "auto"
        stackView = nil; selectedImage = 0; energyIndex = 0; thetaIndex = 0; display = "intensity"; viewport = nil; zoomLevel = 1; engineView = .stack
        interactionPoint = nil
        rois.removeAll(); selectedROIIndex = nil; selectedNonROISeries = "All spectra"; roiWarning = nil
    }
    static func pixelResolution(axis: [Double], unit: String?, sourceValue: Double? = nil) -> String {
        // Five significant digits are display-only; source metadata and exports
        // retain full precision and the source unit, independently of zoom.
        if let sourceValue, sourceValue.isFinite, sourceValue > 0, let unit {
            return String(format: "%#.5g %@", sourceValue, unit)
        }
        guard let unit, ["µm", "μm", "um", "nm"].contains(unit), axis.count >= 2 else { return "—" }
        let steps = zip(axis, axis.dropFirst()).map { abs($1 - $0) }
        guard let first = steps.first, first.isFinite, first > 0,
              steps.allSatisfy({ $0.isFinite && abs($0 - first) <= max(1e-9, first * 1e-3) }) else { return "—" }
        return String(format: "%#.5g %@", first, unit)
    }
    func displayLimits(for image: ScientificImage) -> (lower: Double, upper: Double)? {
        guard image.channels != 3, let low = image.minimum ?? image.values.min(),
              let high = image.maximum ?? image.values.max(), low.isFinite, high.isFinite else { return nil }
        let span = high - low
        let lowerFraction = min(0.99, max(0, contrastLow))
        let upperFraction = max(lowerFraction + 0.001, min(1, contrastHigh))
        return (low + span * lowerFraction, low + span * upperFraction)
    }
    var canAddROI: Bool {
        guard let s = snapshot, !busy, rois.count < 10 else { return false }
        switch roiMode {
        case "Pixel":
            guard let p = pendingPixel, p.count == 2 else { return false }
            return (0..<s.shape[0]).contains(p[0]) && (0..<s.shape[1]).contains(p[1])
        case "Rectangle":
            guard let bounds = rectangle, bounds.count == 4 else { return false }
            return bounds[2] > bounds[0] && bounds[3] > bounds[1]
        case "Lasso":
            guard let vertices = polygon else { return false }
            return vertices.count >= 3 && vertices.allSatisfy({ $0.count == 2 && $0.allSatisfy(\.isFinite) })
        default: return false
        }
    }
    @discardableResult
    func addPendingROI() -> Bool {
        guard canAddROI else { return false }
        switch roiMode {
        case "Pixel":
            guard let p = pendingPixel else { return false }
            let saved = addROI(bounds: [p[0], p[1], p[0] + 1, p[1] + 1])
            if saved { pendingPixel = nil }
            return saved
        case "Rectangle":
            guard let bounds = rectangle else { return false }
            return addROI(bounds: bounds)
        case "Lasso":
            guard let vertices = polygon, let s = snapshot else { return false }
            let xs = vertices.map { $0[0] }, ys = vertices.map { $0[1] }
            guard let xMin = xs.min(), let xMax = xs.max(), let yMin = ys.min(), let yMax = ys.max() else { return false }
            let bounds = [max(0, Int(floor(xMin))), max(0, Int(floor(yMin))),
                          min(s.shape[0], Int(ceil(xMax)) + 1), min(s.shape[1], Int(ceil(yMax)) + 1)]
            return addROI(bounds: bounds, polygon: vertices)
        default: return false
        }
    }
    @discardableResult
    func setROIColor(index: Int, hex: String) -> Bool {
        guard ROIPresets.colors.contains(hex), let position = rois.firstIndex(where: { $0.index == index }) else { return false }
        rois[position].colorHex = hex
        return true
    }
    @discardableResult
    func addROI(bounds: [Int], polygon vertices: [[Double]]? = nil) -> Bool {
        guard let s = snapshot, bounds.count == 4,
              bounds[0] >= 0, bounds[1] >= 0, bounds[2] <= s.shape[0], bounds[3] <= s.shape[1],
              bounds[2] > bounds[0], bounds[3] > bounds[1] else { return false }
        if let vertices {
            guard vertices.count >= 3 && vertices.allSatisfy({ $0.count == 2 && $0.allSatisfy(\.isFinite) }) else { return false }
        }
        if rois.count >= 10 {
            roiWarning = "已达 ROI 上限（最多 10 个）"
            return false
        }
        let usedIndices = Set(rois.map(\.index))
        let nextIndex = (1...10).first { !usedIndices.contains($0) } ?? (rois.count + 1)
        let color = ROIPresets.colors[(nextIndex - 1) % ROIPresets.colors.count]
        let item = ROIItem(index: nextIndex, label: "[\(nextIndex)] ROI \(nextIndex)", colorHex: color, bounds: bounds, polygon: vertices)
        rois.append(item)
        rois.sort(by: { $0.index < $1.index })
        selectedROIIndex = nextIndex
        roiWarning = rois.count > 8 ? "ROI过多（当前已有 \(rois.count) 个，上限 10 个）" : nil
        rectangle = nil
        polygon = nil
        pendingPixel = nil
        updateView()
        return true
    }
    func removeROI(index: Int) {
        rois.removeAll(where: { $0.index == index })
        if selectedROIIndex == index { selectedROIIndex = rois.last?.index }
        if selectedExportTarget == "ROI\(index)" {
            selectedExportTarget = "AllData"
            selectedDataGroups = Set(availableDataGroups)
        }
        if rois.count <= 8 { roiWarning = nil }
        updateView()
    }
    func clearROIs() {
        rois.removeAll()
        selectedROIIndex = nil
        selectedExportTarget = "AllData"
        selectedDataGroups = Set(availableDataGroups)
        roiWarning = nil
        rectangle = nil
        polygon = nil
        pendingPixel = nil
        updateView()
    }
    func chooseFiles(multiple: Bool = false) -> [String]? {
        guard !busy, !preview else { return nil }
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = multiple
        return panel.runModal() == .OK ? panel.urls.map(\.path) : nil
    }
    static func stackFile(from selected: URL) throws -> URL {
        let url = selected.standardizedFileURL
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &directory), !directory.boolValue else {
            throw EngineFailure("file_error", "Select a stack file directly; for SDF choose its .hdr file, not the folder.")
        }
        return url
    }
    func openStack() {
        guard supports("open"), !busy, !preview, let selected = chooseFiles()?.first else { return }
        openStack(at: URL(fileURLWithPath: selected))
    }
    func openStack(at selected: URL, selection: JSONValue? = nil) {
        guard supports("open"), !busy, !preview else { return }
        do {
            let file = try Self.stackFile(from: selected)
            section = .load
            var params: [String: JSONValue] = ["path": .string(file.path), "pre_normalized": .bool(openAsOpticalDensity)]
            if let selection { params["selection"] = selection }
            run("open", params)
        } catch { self.error = error.localizedDescription; status = "Operation failed" }
    }
    /// Formats rendered from the engine's current view; numeric formats export the whole session.
    static let displayFormats: Set<String> = ["png", "pdf", "svg"]
    var showsEngineCurrentView: Bool {
        switch engineView {
        case .stack: return results[section] == nil
        case .section(let owner): return results[section] != nil && owner == section
        }
    }
    var canDisplayOpticalDensity: Bool { snapshot?.normalized == true }
    var canExportImage: Bool { !busy && !preview && snapshot != nil && supports("export") && showsEngineCurrentView }
    var canExport: Bool {
        guard !busy, !preview, snapshot != nil, supports("export") else { return false }
        return !Self.displayFormats.contains(exportFormat) || showsEngineCurrentView
    }
    func export() {
        guard canExport else {
            if snapshot != nil, Self.displayFormats.contains(exportFormat), !showsEngineCurrentView {
                error = "The engine's current view is not on screen. Recalculate this panel or choose a numeric format before exporting an image."
            }
            return
        }
        let panel = NSSavePanel(); panel.nameFieldStringValue = "mantis-results.\(exportFormat)"
        panel.allowedContentTypes = [UTType(filenameExtension: exportFormat) ?? .data]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        // NSSavePanel obtains explicit replacement consent when the target exists.
        run("export", ["path": .string(url.path), "format": .string(exportFormat), "overwrite": .bool(FileManager.default.fileExists(atPath: url.path))])
    }
    func record(_ method: String, _ params: [String: JSONValue]) {
        if let s = snapshot {
            var h = s.history
            h.append(HistoryEntry(method: method, params: params))
            let updated = Snapshot(source: s.source, shape: s.shape, energies: s.energies, normalized: s.normalized, pca_ready: s.pca_ready, clusters_ready: s.clusters_ready, energy_index: s.energy_index, selected_x: s.selected_x, selected_y: s.selected_y, images: s.images, spectra: s.spectra, metrics: s.metrics, spatial: s.spatial, history: h, theta: s.theta, theta_index: s.theta_index, input_is_od: s.input_is_od, display: s.display)
            snapshot = updated
            stackView = updated
        }
    }
    func generateWorkflowLog(format: String) throws -> String {
        guard let s = snapshot else { throw EngineFailure("invalid_state", "No dataset loaded") }
        if format.lowercased() == "json" {
            var historyArray: [[String: Any]] = []
            for entry in s.history {
                var item: [String: Any] = ["method": entry.method]
                if let data = try? JSONEncoder().encode(entry.params),
                   let obj = try? JSONSerialization.jsonObject(with: data) {
                    item["params"] = obj
                } else {
                    item["params"] = entry.params.description
                }
                historyArray.append(item)
            }
            var metricsDict: [String: Any] = [:]
            for (k, v) in s.metrics {
                metricsDict[k] = v.string ?? v.description
            }
            let log: [String: Any] = [
                "source": s.source,
                "shape": s.shape,
                "energies": s.energies,
                "normalized": s.normalized,
                "history": historyArray,
                "metrics": metricsDict
            ]
            let data = try JSONSerialization.data(withJSONObject: log, options: [.prettyPrinted, .sortedKeys])
            return String(data: data, encoding: .utf8) ?? "{}"
        } else {
            var md = "# MANTiS 工作日志\n\n"
            md += "## 数据源信息\n"
            md += "- **数据源路径**: `\(s.source)`\n"
            md += "- **数据维度**: `\(s.shape.map(String.init).joined(separator: " × "))`\n"
            md += "- **信号状态**: `\(s.normalized ? "已归一化 (光密度)" : "未归一化 (强度)")`\n"
            if let first = s.energies.first, let last = s.energies.last {
                md += "- **能量范围**: `\(String(format: "%.3f–%.3f eV (%d 点)", first, last, s.energies.count))`\n"
            }
            md += "\n## 执行命令与参数历史\n"
            if s.history.isEmpty {
                md += "（本次会话尚无记录操作）\n"
            } else {
                for (i, entry) in s.history.enumerated() {
                    md += "\(i + 1). **\(entry.method)**\n"
                    md += "   - 参数: `\(JSONValue.object(entry.params).description)`\n"
                }
            }
            if !s.metrics.isEmpty {
                md += "\n## 分析指标与计算结果\n"
                for (k, v) in s.metrics.sorted(by: { $0.key < $1.key }) {
                    md += "- **\(k)**: `\(v.description)`\n"
                }
            }
            return md
        }
    }
    func importSingleStack() {
        let path = importFilePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else {
            if let chosen = chooseFiles()?.first {
                importFilePath = chosen
                importSingleStack()
            }
            return
        }
        do {
            let selection = try parsedImportSelection()
            openStack(at: URL(fileURLWithPath: path), selection: selection)
        } catch {
            self.error = error.localizedDescription
        }
    }
    func importMergedStack() {
        guard !mergeFilePaths.isEmpty else {
            error = "Select at least two single-frame files."
            return
        }
        let tokens = mergeEnergiesText.split(whereSeparator: { $0 == "," || $0.isWhitespace })
        let energies = tokens.compactMap { Double($0) }
        guard energies.count == mergeFilePaths.count else {
            error = "Number of energies (\(energies.count)) must match number of files (\(mergeFilePaths.count))."
            return
        }
        section = .load
        run("build_stack", [
            "paths": .array(mergeFilePaths.map(JSONValue.string)),
            "energies": .array(energies.map(JSONValue.number))
        ])
    }
    func inspectFile() {
        let path = importFilePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return }
        section = .load
        if client == nil {
            connect()
        }
        run("inspect_file", ["path": .string(path)])
    }
    func exportProcessedData() {
        guard canExportProcessedData, !busy, !preview, supports("export") else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(currentDataExportBaseName).\(dataExportFormat)"
        panel.allowedContentTypes = [UTType(filenameExtension: dataExportFormat) ?? .data]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        run("export", dataExportParameters(path: url.path))
    }
    func exportImage() {
        guard canExportImage else {
            if snapshot != nil, !showsEngineCurrentView {
                error = "The engine's current view is not on screen. Recalculate this panel before exporting an image."
            }
            return
        }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(currentImageExportBaseName).\(imageExportFormat)"
        panel.allowedContentTypes = [UTType(filenameExtension: imageExportFormat) ?? .data]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        run("export", [
            "path": .string(url.path),
            "format": .string(imageExportFormat),
            "dpi": .number(Double(imageExportDPI)),
            "overwrite": .bool(FileManager.default.fileExists(atPath: url.path))
        ])
    }
    func exportWorkflowLog() {
        guard canExportWorkflowLog, !preview else { return }
        let fmt = logExportFormat.lowercased()
        let ext = fmt == "md" ? "md" : "json"
        let isMerge = importFileMode == "merge" || mergeFilePaths.count >= 2
        let baseName = isMerge ? "RawDataMergeWorkLog" : "RawDataWorkLog"
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(baseName).\(ext)"
        panel.allowedContentTypes = [UTType(filenameExtension: ext) ?? .data]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        // Route through the engine: it records this export and protects input files.
        run("export", ["path": .string(url.path), "format": .string(fmt),
                       "overwrite": .bool(FileManager.default.fileExists(atPath: url.path))])
    }
    func viewParameters(x: Int? = nil, y: Int? = nil) -> [String: JSONValue] {
        guard let s = snapshot else { return [:] }
        let targetX = x ?? s.selected_x, targetY = y ?? s.selected_y
        var params: [String: JSONValue] = ["energy_index": .number(Double(energyIndex)),
                                            "x": .number(Double(targetX)), "y": .number(Double(targetY)),
                                            "display": .string(display),
                                            "rois": .array(rois.map { roi in
                                                var item: [String: JSONValue] = ["label": .string(roi.label)]
                                                if let vertices = roi.polygon {
                                                    item["polygon"] = .array(vertices.map { .array($0.map(JSONValue.number)) })
                                                } else { item["bounds"] = .integers(roi.bounds) }
                                                return .object(item)
                                            })]
        if let viewport { params["viewport"] = .integers(viewport) }
        if let active = rois.first(where: { $0.index == selectedROIIndex }) {
            if let vertices = active.polygon {
                params["polygon"] = .array(vertices.map { .array($0.map(JSONValue.number)) })
            } else { params["roi"] = .integers(active.bounds) }
        } else if rois.isEmpty {
            if let rectangle { params["roi"] = .integers(rectangle) }
            if let polygon { params["polygon"] = .array(polygon.map { .array($0.map(JSONValue.number)) }) }
        }
        if s.theta != nil || s.shape.count == 4 { params["theta_index"] = .number(Double(thetaIndex)) }
        return params
    }
    func updateView(x: Int? = nil, y: Int? = nil) {
        guard snapshot != nil, !busy else { return }
        if let x, let y { interactionPoint = (x, y) }
        run("view", viewParameters(x: x, y: y))
    }
    func zoom(to level: Int, centerX: Int? = nil, centerY: Int? = nil) {
        guard let s = snapshot, !busy, s.shape.count >= 2 else { return }
        let target = min(16, max(1, level))
        guard target != zoomLevel || (centerX != nil && centerY != nil) else { return }
        zoomLevel = target
        if target == 1 {
            viewport = nil
        } else {
            let width = max(1, s.shape[0] / target), height = max(1, s.shape[1] / target)
            var targetCX = centerX
            var targetCY = centerY
            if targetCX == nil && targetCY == nil {
                // If an ROI is selected, center on the selected ROI automatically
                if let active = rois.first(where: { $0.index == selectedROIIndex }) ?? rois.last {
                    targetCX = (active.bounds[0] + active.bounds[2]) / 2
                    targetCY = (active.bounds[1] + active.bounds[3]) / 2
                } else if let rect = rectangle, rect.count == 4 {
                    targetCX = (rect[0] + rect[2]) / 2
                    targetCY = (rect[1] + rect[3]) / 2
                }
            }
            let cx = targetCX ?? ((viewport?[0] ?? 0) + (viewport?[2] ?? s.shape[0])) / 2
            let cy = targetCY ?? ((viewport?[1] ?? 0) + (viewport?[3] ?? s.shape[1])) / 2
            let x0 = min(s.shape[0] - width, max(0, cx - width / 2))
            let y0 = min(s.shape[1] - height, max(0, cy - height / 2))
            viewport = [x0, y0, x0 + width, y0 + height]
        }
        updateView()
    }
    func selectEnergy(_ energy: Double) {
        guard let s = snapshot, let index = s.energies.indices.min(by: { abs(s.energies[$0] - energy) < abs(s.energies[$1] - energy) }) else { return }
        energyIndex = index; updateView()
    }
    static func pretty(_ data: Data) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data), let formatted = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) else { return String(data: data, encoding: .utf8) ?? "" }
        return String(data: formatted, encoding: .utf8) ?? ""
    }
}
