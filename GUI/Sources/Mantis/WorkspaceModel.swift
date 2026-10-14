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
    @Published var selectedImage = 0
    @Published var energyIndex = 0
    @Published var thetaIndex = 0
    @Published var display = "intensity"
    @Published var roiMode = "Pixel"
    @Published var rectangle: [Int]?
    @Published var polygon: [[Double]]?
    @Published var contrastLow = 0.0
    @Published var contrastHigh = 1.0
    @Published var gamma = 1.0
    @Published var colorMap = "Viridis"
    @Published var exportFormat = "npz"
    @Published var lastMethod = ""
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
    var availableImages: [ScientificImage] { shown?.images ?? [] }
    var image: ScientificImage? { availableImages.indices.contains(selectedImage) ? availableImages[selectedImage] : availableImages.first }
    var connected: Bool { handshake != nil }
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
                } else if method == "inspect_file" {
                    inspection = Self.pretty(data)
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
    func accept(_ next: Snapshot, method: String, target: WorkflowSection) {
        if snapshot?.theta_index != next.theta_index { results.removeAll() }
        snapshot = next; energyIndex = next.energy_index; thetaIndex = next.theta_index ?? 0
        let resetMethods: Set<String> = ["open", "build_stack", "normalize", "crop", "dark", "despike", "align", "remove_image", "reset"]
        if method == "pca" || method == "cluster" {
            results[.spectral] = nil; results[.nnma] = nil
        }
        if resetMethods.contains(method) { results.removeAll(); rectangle = nil; polygon = nil; selectedImage = 0; stackView = next; engineView = .stack }
        else if method != "view" && method != "export" { results[target] = next; selectedImage = 0; engineView = .section(target) }
        if method == "view" { results[target] = nil; stackView = next; engineView = .stack }
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
        snapshot = nil; results.removeAll(); handshake = nil; rectangle = nil; polygon = nil; inspection = nil
        stackView = nil; selectedImage = 0; energyIndex = 0; thetaIndex = 0; display = "intensity"; engineView = .stack
    }
    func chooseFiles(multiple: Bool = false) -> [String]? {
        guard !busy, !preview else { return nil }
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = multiple
        return panel.runModal() == .OK ? panel.urls.map(\.path) : nil
    }
    func openStack() {
        guard supports("open"), let path = chooseFiles()?.first else { return }
        section = .load; run("open", ["path": .string(path), "pre_normalized": .bool(false)])
    }
    /// Formats rendered from the engine's current view; numeric formats export the whole session.
    static let displayFormats: Set<String> = ["png", "pdf", "svg"]
    var showsEngineCurrentView: Bool {
        switch engineView {
        case .stack: return results[section] == nil
        case .section(let owner): return results[section] != nil && owner == section
        }
    }
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
    func updateView(x: Int? = nil, y: Int? = nil) {
        guard let s = snapshot, !busy else { return }
        var params: [String: JSONValue] = ["energy_index": .number(Double(energyIndex)), "x": .number(Double(x ?? s.selected_x)), "y": .number(Double(y ?? s.selected_y)), "display": .string(display)]
        if let rectangle { params["roi"] = .integers(rectangle) }
        if let polygon { params["polygon"] = .array(polygon.map { .array($0.map(JSONValue.number)) }) }
        if s.theta != nil || s.shape.count == 4 { params["theta_index"] = .number(Double(thetaIndex)) }
        run("view", params)
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
