import XCTest
import MantisCore
@testable import Mantis

@MainActor
final class WorkspaceTests: XCTestCase {
    func fixture(_ title: String = "Intensity", normalized: Bool = true, pca: Bool = false, clusters: Bool = false, theta: Int? = nil) throws -> Snapshot {
        var value: [String: Any] = ["source": "/measurement.npz", "shape": [2,2,2], "energies": [280,281], "normalized": normalized, "pca_ready": pca, "clusters_ready": clusters, "energy_index": 0, "selected_x": 0, "selected_y": 0, "images": [["title": title, "width": 2, "height": 2, "full_width": 2, "full_height": 2, "values": [1,2,3,4]]], "spectra": [], "metrics": [:], "history": []]
        if let theta { value["theta"] = [0,90]; value["theta_index"] = theta }
        return try Snapshot.decode(JSONSerialization.data(withJSONObject: value))
    }
    func testDisplayExportRefusesCachedResultDifferentFromEngineCurrentView() throws {
        let model = WorkspaceModel()
        model.handshake = try JSONDecoder().decode(EngineHello.self, from: Data(#"{"engine_version":"test","protocol":1,"capabilities":["export"]}"#.utf8))
        model.accept(try fixture(), method: "open", target: .load)
        model.accept(try fixture("PCA", pca: true), method: "pca", target: .pca)
        model.accept(try fixture("Target", pca: true), method: "spectral", target: .spectral)
        model.section = .pca
        model.exportFormat = "png"
        XCTAssertFalse(model.canExport, "Never export a target map while showing PCA")
        model.exportFormat = "npz"
        XCTAssertTrue(model.canExport, "Numeric session exports are independent of the active view")
    }
    func testDownsampledImageUsesOriginalAspectRatio() throws {
        let image = try JSONDecoder().decode(ScientificImage.self, from: Data(#"{"title":"wide","width":256,"height":256,"full_width":1024,"full_height":512,"values":[]}"#.utf8))
        let canvas = ScientificCanvas(model: WorkspaceModel(preview: true), image: image)
        let rect = canvas.plotRect(in: CGSize(width: 600, height: 400))
        XCTAssertEqual(rect.width / rect.height, 2, accuracy: 0.00001)
    }
    func testViewAfterThetaChangeInvalidatesAllAnalyses() throws {
        let model = WorkspaceModel(preview: true)
        model.accept(try fixture(theta: 0), method: "open", target: .load)
        model.accept(try fixture("PCA", pca: true, theta: 0), method: "pca", target: .pca)
        model.accept(try fixture("Target", pca: true, theta: 0), method: "spectral", target: .spectral)
        model.accept(try fixture(theta: 1), method: "view", target: .load)
        XCTAssertTrue(model.results.isEmpty)
    }
    func testClosingClearsAllVisibleData() async throws {
        let model = WorkspaceModel(preview: true)
        model.accept(try fixture(), method: "open", target: .load)
        await model.close()
        XCTAssertNil(model.shown)
        XCTAssertNil(model.snapshot)
    }
    func testPCARecalculationInvalidatesDependentResultsButKeepsStackView() throws {
        let model = WorkspaceModel(preview: true)
        model.accept(try fixture(), method: "open", target: .load)
        model.results[.spectral] = try fixture("Old target", pca: true, clusters: true)
        model.results[.nnma] = try fixture("Old NNMA", pca: true, clusters: true)
        model.accept(try fixture("New PCA", pca: true), method: "pca", target: .pca)
        XCTAssertNil(model.results[.spectral])
        XCTAssertNil(model.results[.nnma])
        XCTAssertEqual(model.stackView?.images.first?.title, "Intensity")
        model.section = .pca
        XCTAssertEqual(model.shown?.images.first?.title, "New PCA")
    }
    func testUnrelatedSectionDoesNotShowAnotherAnalysis() throws {
        let model = WorkspaceModel(preview: true)
        model.snapshot = try fixture("Eigenimage", pca: true)
        model.results[.pca] = model.snapshot
        model.section = .nnma
        XCTAssertNil(model.shown, "Never label a PCA result as an NNMA result")
    }
}
