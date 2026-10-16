import XCTest
import Foundation
import MantisCore
@testable import Mantis

@MainActor
final class WorkspaceTests: XCTestCase {
    func fixture(_ title: String = "Intensity", normalized: Bool = true, pca: Bool = false, clusters: Bool = false, theta: Int? = nil) throws -> Snapshot {
        var value: [String: Any] = ["source": "/measurement.npz", "shape": [2,2,2], "energies": [280,281], "normalized": normalized, "pca_ready": pca, "clusters_ready": clusters, "energy_index": 0, "selected_x": 0, "selected_y": 0, "images": [["title": title, "width": 2, "height": 2, "full_width": 2, "full_height": 2, "values": [1,2,3,4]]], "spectra": [], "metrics": [:], "history": []]
        if let theta { value["theta"] = [0,90]; value["theta_index"] = theta }
        return try Snapshot.decode(JSONSerialization.data(withJSONObject: value))
    }
    func testSmokeWindowSelectionUsesLargestVisibleContentAndExcludesHiddenWindows() throws {
        let hidden = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 900),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        let small = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 40, height: 30),
                             styleMask: [.borderless], backing: .buffered, defer: false)
        let large = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 80, height: 60),
                             styleMask: [.borderless], backing: .buffered, defer: false)
        for window in [hidden, small, large] { window.isReleasedWhenClosed = false }
        defer { for window in [hidden, small, large] { window.close() } }
        small.orderBack(nil)
        large.orderBack(nil)
        XCTAssertTrue(SmokeWindowSelection.largestVisible(in: [hidden, small, large]) === large)
        large.orderOut(nil)
        XCTAssertTrue(SmokeWindowSelection.largestVisible(in: [hidden, small, large]) === small)
        small.orderOut(nil)
        XCTAssertNil(SmokeWindowSelection.largestVisible(in: [hidden, small, large]))
    }
    func testImageExportAvailabilityChecksCurrentViewNotDataFormat() throws {
        let model = WorkspaceModel()
        model.handshake = try JSONDecoder().decode(EngineHello.self, from: Data(#"{"engine_version":"test","protocol":1,"capabilities":["export"]}"#.utf8))
        model.accept(try fixture(), method: "open", target: .load)
        model.accept(try fixture("PCA", pca: true), method: "pca", target: .pca)
        model.accept(try fixture("Target", pca: true), method: "spectral", target: .spectral)
        model.section = .pca
        model.exportFormat = "npz"
        XCTAssertFalse(model.canExportImage)
        XCTAssertTrue(model.canExportProcessedData)
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
    func testSpatialAxesAndViewportDecodeAndRejectMalformedMetadata() throws {
        var json: [String: Any] = ["source": "/measurement.hdr", "shape": [4, 3, 2], "energies": [632, 633], "normalized": false, "pca_ready": false, "clusters_ready": false, "energy_index": 0, "selected_x": 1, "selected_y": 1, "images": [["title": "Intensity", "width": 2, "height": 2, "full_width": 4, "full_height": 3, "origin_x": 1, "origin_y": 1, "visible_width": 2, "visible_height": 2, "values": [1,2,3,4]]], "spectra": [], "metrics": [:], "history": [], "spatial": ["x": [10.0, 10.1, 10.2, 10.3], "y": [21.0, 21.2, 21.4], "unit": "µm"]]
        let snapshot = try Snapshot.decode(JSONSerialization.data(withJSONObject: json))
        let spatial = try XCTUnwrap(snapshot.spatial)
        XCTAssertEqual(spatial.x.count, 4)
        XCTAssertEqual(spatial.y.count, 3)
        XCTAssertEqual(spatial.unit, "µm")
        let image = try XCTUnwrap(snapshot.images.first)
        XCTAssertEqual(image.origin_x, 1)
        XCTAssertEqual(image.visible_width, 2)
        json["spatial"] = ["x": [10, 11], "y": [20, 21, 22], "unit": "µm"]
        XCTAssertThrowsError(try Snapshot.decode(JSONSerialization.data(withJSONObject: json)))
    }
    func testZoomKeepsOriginalPixelCoordinatesAndAspectRatio() throws {
        let image = try JSONDecoder().decode(ScientificImage.self, from: Data(#"{"title":"zoom","width":100,"height":50,"full_width":1024,"full_height":512,"origin_x":100,"origin_y":25,"visible_width":400,"visible_height":100,"values":[]}"#.utf8))
        let canvas = ScientificCanvas(model: WorkspaceModel(preview: true), image: image)
        let rect = canvas.plotRect(in: CGSize(width: 600, height: 400))
        XCTAssertEqual(rect.width / rect.height, 4, accuracy: 0.00001)
        XCTAssertEqual(canvas.pixel(CGPoint(x: rect.minX, y: rect.minY), rect: rect).0, 100)
        XCTAssertEqual(canvas.pixel(CGPoint(x: rect.maxX, y: rect.maxY), rect: rect).1, 124)
    }
    func testPhysicalScaleUsesMetadataInsteadOfPixelCount() throws {
        let json: [String: Any] = ["source": "/measurement.hdr", "shape": [4, 4, 2], "energies": [632, 633], "normalized": false, "pca_ready": false, "clusters_ready": false, "energy_index": 0, "selected_x": 1, "selected_y": 1, "images": [["title": "Intensity", "width": 4, "height": 4, "full_width": 4, "full_height": 4, "values": Array(repeating: 1, count: 16)]], "spectra": [], "metrics": [:], "history": [], "spatial": ["x": [0.0, 1.0, 2.0, 3.0], "y": [0.0, 2.0, 4.0, 6.0], "unit": "µm"]]
        let snapshot = try Snapshot.decode(JSONSerialization.data(withJSONObject: json))
        let model = WorkspaceModel(preview: true)
        model.accept(snapshot, method: "open", target: .load)
        let image = try XCTUnwrap(model.image)
        let canvas = ScientificCanvas(model: model, image: image)
        XCTAssertEqual(canvas.plotRect(in: CGSize(width: 400, height: 400)).width / canvas.plotRect(in: CGSize(width: 400, height: 400)).height, 1, accuracy: 0.00001)
        model.spatialDisplay = "physical"
        XCTAssertEqual(canvas.plotRect(in: CGSize(width: 400, height: 400)).width / canvas.plotRect(in: CGSize(width: 400, height: 400)).height, 0.5, accuracy: 0.00001)
    }
    func testMenuBarArtworkLoadsPackagedTransparentImage() throws {
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../Resources/MantisMenuIcon.png").standardizedFileURL
        let image = try XCTUnwrap(MenuBarArtwork.load(from: source))
        XCTAssertEqual(image.size.width, 18)
        XCTAssertEqual(image.size.height, 18)
        XCTAssertFalse(image.isTemplate)
    }
    func testHistogramBinsRepresentEdgesAndNonzeroHeights() {
        let bins = SpectraChart.histogramBins(counts: [0, 3, 5], edges: [26, 100, 175, 255])
        XCTAssertEqual(bins.map(\.count), [0, 3, 5])
        XCTAssertEqual(bins.map(\.low), [26, 100, 175])
        XCTAssertEqual(bins.map(\.high), [100, 175, 255])
        XCTAssertEqual(bins.reduce(0) { $0 + $1.count }, 8)
    }
    func testVisiblePixelHistogramDecodesAndRejectsMismatchedBins() throws {
        var json: [String: Any] = ["source": "/measurement.npz", "shape": [2, 2, 2], "energies": [280, 281], "normalized": false, "pca_ready": false, "clusters_ready": false, "energy_index": 0, "selected_x": 0, "selected_y": 0, "images": [["title": "Intensity", "width": 2, "height": 2, "full_width": 2, "full_height": 2, "values": [1, 2, 3, 4], "minimum": 1.0, "maximum": 4.0, "mean": 2.5, "histogram_counts": [1, 3], "histogram_edges": [1.0, 2.5, 4.0]]], "spectra": [], "metrics": [:], "history": []]
        let snapshot = try Snapshot.decode(JSONSerialization.data(withJSONObject: json))
        let image = try XCTUnwrap(snapshot.images.first)
        XCTAssertEqual(image.histogram_counts, [1, 3])
        XCTAssertEqual(image.histogram_edges, [1.0, 2.5, 4.0])
        XCTAssertEqual(image.mean, 2.5)
        var malformed = try XCTUnwrap(json["images"] as? [[String: Any]])
        malformed[0]["histogram_edges"] = [1.0, 4.0]
        json["images"] = malformed
        XCTAssertThrowsError(try Snapshot.decode(JSONSerialization.data(withJSONObject: json)))
    }
    func testScaleBarLadderAdaptsCorrectlyForMicroAndNanoMeters() throws {
        // Test SDF scale: 52 pixels = 2.6 µm -> target ~572 nm -> chooses 500 nm
        let sdfBar = ScientificCanvas.calculateScaleBar(visibleWidth: 52, plotWidth: 300, physicalPerPixelNm: 50.0)
        XCTAssertEqual(sdfBar.label, "500 nm")
        XCTAssertEqual(sdfBar.barLengthPoints, 57.69, accuracy: 0.1)

        // Test MISTRAL scale: 982 pixels = 12.766 µm -> target ~2.8 µm -> chooses 2 µm
        let mistralBar = ScientificCanvas.calculateScaleBar(visibleWidth: 982, plotWidth: 300, physicalPerPixelNm: 13.0)
        XCTAssertEqual(mistralBar.label, "2 µm")

        // Test zoomed scale: 13 pixels -> target ~143 nm -> chooses 100 nm
        let zoomedBar = ScientificCanvas.calculateScaleBar(visibleWidth: 13, plotWidth: 300, physicalPerPixelNm: 50.0)
        XCTAssertEqual(zoomedBar.label, "100 nm")

        // Test pixel fallback (no physical coordinates)
        let pixelBar = ScientificCanvas.calculateScaleBar(visibleWidth: 52, plotWidth: 300, physicalPerPixelNm: nil as Double?)
        XCTAssertEqual(pixelBar.label, "10 px")
    }
    func testInteractionPointAndPositionFormattingWithPhysicalUnits() throws {
        let model = WorkspaceModel(preview: true)
        let snapshot = try fixture("Intensity")
        model.accept(snapshot, method: "open", target: .load)
        XCTAssertEqual(model.interactionPoint?.0, snapshot.selected_x)
        XCTAssertEqual(model.interactionPoint?.1, snapshot.selected_y)

        model.interactionPoint = (10, 20)
        XCTAssertEqual(model.interactionPoint?.0, 10)
        XCTAssertEqual(model.interactionPoint?.1, 20)
    }
    func testExportDataOptionsNamingAndSelection() throws {
        let model = WorkspaceModel(preview: true)
        model.accept(try largeFixture(), method: "open", target: .load)

        let initialOpts = model.exportDataOptions
        XCTAssertTrue(initialOpts.contains(where: { $0.id == "AllData" }))
        XCTAssertTrue(initialOpts.contains(where: { $0.id == "RawData" }))
        XCTAssertTrue(initialOpts.contains(where: { $0.id == "ProcessedData" }))
        XCTAssertFalse(initialOpts.contains(where: { $0.id == "NormalizedData" }))
        XCTAssertEqual(model.currentDataExportBaseName, "AllData")
        XCTAssertEqual(model.currentImageExportBaseName, "RawDataImage")

        // Add ROI1 and ROI2
        model.addROI(bounds: [10, 10, 20, 20])
        model.addROI(bounds: [25, 25, 35, 35])
        let roiOpts = model.exportDataOptions
        XCTAssertTrue(roiOpts.contains(where: { $0.id == "ROI1" }))
        XCTAssertTrue(roiOpts.contains(where: { $0.id == "ROI2" }))

        // Select ROI1
        model.selectedExportTarget = "ROI1"
        model.selectedROIIndex = 1
        XCTAssertEqual(model.currentDataExportBaseName, "ROI1")
        XCTAssertEqual(model.dataExportParameters(path: "/tmp/ROI1.npz")["spectrum_name"],
                       .string("[1] ROI 1"))
        XCTAssertEqual(model.currentImageExportBaseName, "ROI1Image")
        model.dataExportFormat = "csv"
        XCTAssertEqual(model.currentDataExportBaseName, "SpectraData")
        XCTAssertNil(model.dataExportParameters(path: "/tmp/SpectraData.csv")["spectrum_name"])
        model.dataExportFormat = "npz"

        // Select ROI2 in analysis section
        model.selectedROIIndex = 2
        model.section = .pca
        XCTAssertEqual(model.currentImageExportBaseName, "ROI2ImageMapping")

        // Merge mode naming
        model.section = .load
        model.rois.removeAll()
        model.selectedROIIndex = nil
        model.importFileMode = "merge"
        model.selectedExportTarget = "RawDataMerge"
        XCTAssertEqual(model.currentDataExportBaseName, "RawDataMerge")
        XCTAssertEqual(model.currentImageExportBaseName, "RawDataMergeImage")
    }
    func testNormalizationChoiceRemainsOffAfterViewRefresh() throws {
        let model = WorkspaceModel(preview: true)
        model.accept(try fixture(normalized: true), method: "open", target: .load)
        model.selectedDataGroups.remove("normalization")
        model.accept(try fixture(normalized: true), method: "view", target: .load)
        XCTAssertFalse(model.selectedDataGroups.contains("normalization"))
    }
    func testSwitchingToRawStackDoesNotLeaveUnavailableExportGroupSelected() throws {
        let model = WorkspaceModel(preview: true)
        model.accept(try fixture(normalized: true), method: "open", target: .load)
        XCTAssertTrue(model.selectedDataGroups.contains("normalization"))
        model.accept(try fixture(normalized: false), method: "open", target: .load)
        XCTAssertFalse(model.selectedDataGroups.contains("normalization"))
        XCTAssertTrue(model.canExportProcessedData)
    }
    func testNormalizedImportOffersNormalizationExportByDefault() throws {
        let model = WorkspaceModel(preview: true)
        model.accept(try fixture(normalized: true), method: "open", target: .load)
        XCTAssertTrue(model.availableDataGroups.contains("normalization"))
        XCTAssertTrue(model.selectedDataGroups.contains("normalization"))
    }
    func testCSVExportIgnoresDataGroupSelection() throws {
        let model = WorkspaceModel(preview: true)
        model.accept(try fixture(normalized: false), method: "open", target: .load)
        model.dataExportFormat = "csv"
        model.selectedDataGroups = []
        XCTAssertTrue(model.canExportProcessedData)
        XCTAssertNil(model.dataExportParameters(path: "/tmp/data.csv")["include"])
    }
    func testDataExportChoicesRejectEmptyAndUnavailableNormalization() throws {
        let model = WorkspaceModel(preview: true)
        model.accept(try fixture(normalized: false), method: "open", target: .load)
        XCTAssertTrue(model.selectedDataGroups.contains("processed"))
        XCTAssertFalse(model.availableDataGroups.contains("normalization"))
        model.selectedDataGroups = []
        XCTAssertFalse(model.canExportProcessedData)
        model.selectedDataGroups = ["raw", "spectra"]
        XCTAssertTrue(model.canExportProcessedData)
        XCTAssertEqual(model.dataExportParameters(path: "/tmp/data.npz")["include"],
                       .array([.string("raw"), .string("spectra")]))
    }
    func testWorkflowLogNoLongerRequiresEnableToggle() throws {
        let model = WorkspaceModel(preview: true)
        model.handshake = try JSONDecoder().decode(EngineHello.self, from: Data(#"{"engine_version":"test","protocol":1,"capabilities":["export"]}"#.utf8))
        model.accept(try fixture(), method: "open", target: .load)
        XCTAssertEqual(model.logExportFormat, "json")
        XCTAssertTrue(model.canExportWorkflowLog)
    }
    func testLoadAndExportInspectorOptionsDefaults() throws {
        let model = WorkspaceModel(preview: true)
        XCTAssertEqual(model.importFileMode, "single")
        XCTAssertEqual(model.dataExportFormat, "npz")
        XCTAssertEqual(model.imageExportFormat, "png")
        XCTAssertEqual(model.imageExportDPI, 300)
        XCTAssertEqual(model.logExportFormat, "json")

        model.importFileMode = "merge"
        model.imageExportDPI = 600
        model.logExportFormat = "md"
        XCTAssertEqual(model.importFileMode, "merge")
        XCTAssertEqual(model.imageExportDPI, 600)
        XCTAssertEqual(model.logExportFormat, "md")
    }
    func testImportSelectionGuidanceUsesActualFileFormatWithoutInjectingExamples() throws {
        let model = WorkspaceModel(preview: true)
        model.importFileFormat = "hdr"
        XCTAssertEqual(model.importSelectionGuide.placeholder, "e.g. [[0, 0]] (optional)")
        XCTAssertTrue(model.importSelectionGuide.detail.contains("SDF"))
        XCTAssertNil(try model.parsedImportSelection(), "An example must not become an implicit selection")

        model.importFilePath = "/samples/scan.hdf5.hdf5"
        XCTAssertEqual(model.importSelectionGuide.placeholder, "Leave blank unless selection is required")
        XCTAssertTrue(model.importSelectionGuide.detail.contains("NXstxm"), "Not all HDF5 files are single-channel")
        XCTAssertNil(try model.parsedImportSelection())
        model.importFilePath = "/samples/stack.npz"
        XCTAssertFalse(model.importSelectionGuide.supportsSelection)
    }
    func testImportSelectionGuideUsesLocalizedPlaceholderAndCompactExamples() throws {
        let model = WorkspaceModel(preview: true)
        for (format, placeholder) in [("all", "e.g. [[0, 0]] (optional)"),
                                      ("hdr", "e.g. [[0, 0]] (optional)"),
                                      ("hdf5", "Leave blank unless selection is required"),
                                      ("npz", "No selection needed")] {
            model.importFileFormat = format
            XCTAssertEqual(model.importSelectionGuide.placeholder, placeholder)
            XCTAssertNotEqual(InterfaceText.value(placeholder, language: .simplifiedChinese), placeholder,
                              "Every on-screen placeholder needs a Chinese translation")
        }
        for (english, chinese) in [
            ("Region/channel; e.g. [[0, 0]]", "区域/通道；如 [[0, 0]]"),
            ("MISTRAL: leave blank", "MISTRAL：留空"),
            ("NXstxm region/channel; e.g. [[0, 0]]", "NXstxm 区域/通道；如 [[0, 0]]"),
            ("Usually leave blank", "通常留空")
        ] {
            XCTAssertEqual(InterfaceText.value(english, language: .simplifiedChinese), chinese)
            XCTAssertEqual(InterfaceText.value(english, language: .english), english)
        }
    }
    func testImportSelectionRejectsMalformedPairsAndClearsWhenSourceChanges() throws {
        let model = WorkspaceModel(preview: true)
        model.importFilePath = "/samples/first.hdr"
        model.importSelection = "[[0,1],[1,0]]"
        XCTAssertEqual(try model.parsedImportSelection(), .array([
            .array([.number(0), .number(1)]), .array([.number(1), .number(0)])
        ]))
        model.importFilePath = "/samples/other.hdf5"
        XCTAssertEqual(model.importSelection, "", "An old SDF region cannot silently select an HDF5 channel")
        model.importSelection = "[[0,0]]"
        model.importFileFormat = "npz"
        XCTAssertEqual(model.importSelection, "")
        for invalid in ["[]", "[0,0]", "[[0]]", "[[0,1.5]]", "[[0.0,0]]", "[[0e0,0]]", "[[true,0]]", "[[-1,0]]", "[[0,0,0]]", "[[9007199254740992,0]]", "hello"] {
            model.importFilePath = "/samples/first.hdr"
            model.importSelection = invalid
            XCTAssertThrowsError(try model.parsedImportSelection(), "Invalid input: \(invalid)")
        }
        model.importFilePath = "/samples/stack.npz"
        model.importSelection = "[[0,0]]"
        XCTAssertThrowsError(try model.parsedImportSelection(), "NPZ has no selectable region/channel")
    }
    func testFileInspectionDecodesAndChannelPickerSelectsInteractiveSelections() throws {
        let model = WorkspaceModel(preview: true)
        let json = """
        {
            "path": "/data/test.hdf5",
            "plugin": "NXstxm",
            "file_size": 1048576,
            "scan_type": "NEXAFS",
            "selections": [
                {
                    "selection": [0, 0],
                    "region": "entry",
                    "channel": "detector0",
                    "shape": [4, 2, 3],
                    "axes": ["energy", "sample_y", "sample_x"],
                    "scan_type": "NEXAFS"
                },
                {
                    "selection": [0, 1],
                    "region": "entry",
                    "channel": "detector1",
                    "shape": [4, 2, 3]
                }
            ]
        }
        """
        let info = try JSONDecoder().decode(FileInspectionInfo.self, from: json.data(using: .utf8)!)
        XCTAssertEqual(info.plugin, "NXstxm")
        XCTAssertEqual(info.file_size, 1048576)
        XCTAssertEqual(info.selections.count, 2)
        XCTAssertEqual(info.selections[0].key, "0_0")
        XCTAssertTrue(info.selections[0].displayName.contains("detector0"))
        XCTAssertTrue(info.selections[0].displayName.contains("4 × 2 × 3"))

        model.importFilePath = "/data/test.hdf5"
        model.inspectionInfo = info
        XCTAssertEqual(model.selectedChannelKey, "auto")
        XCTAssertEqual(model.importSelection, "")

        model.selectChannelKey("0_1")
        XCTAssertEqual(model.selectedChannelKey, "0_1")
        XCTAssertEqual(model.importSelection, "[[0, 1]]")
        XCTAssertEqual(try model.parsedImportSelection(), .array([.array([.number(0), .number(1)])]))

        model.selectChannel(region: 0, channel: 0)
        XCTAssertEqual(model.selectedChannelKey, "0_0")
        XCTAssertEqual(model.importSelection, "[[0, 0]]")

        model.selectChannelKey("auto")
        XCTAssertEqual(model.selectedChannelKey, "auto")
        XCTAssertEqual(model.importSelection, "")
        XCTAssertNil(try model.parsedImportSelection())

        model.selectChannelKey("0_0")
        model.importFilePath = "/data/another.hdr"
        XCTAssertEqual(model.selectedChannelKey, "auto")
        XCTAssertEqual(model.importSelection, "")
        XCTAssertNil(model.inspectionInfo)
    }
    func testSelectedROIHistogramDecodesAndRejectsIncompleteMetadata() throws {
        let image: [String: Any] = ["title": "Intensity", "width": 2, "height": 2,
                                    "full_width": 2, "full_height": 2, "values": [1, 2, 3, 4],
                                    "roi_histogram_counts": [2, 1],
                                    "roi_histogram_edges": [0.0, 1.0, 2.0],
                                    "roi_minimum": 0.0, "roi_maximum": 2.0, "roi_mean": 1.0]
        var raw: [String: Any] = ["source": "/tmp/example.npz", "shape": [2, 2, 2],
                                  "energies": [280, 281], "normalized": false, "pca_ready": false,
                                  "clusters_ready": false, "energy_index": 0, "selected_x": 0, "selected_y": 0,
                                  "images": [image], "spectra": [], "metrics": [:], "history": []]
        let snapshot = try Snapshot.decode(JSONSerialization.data(withJSONObject: raw))
        XCTAssertEqual(snapshot.images[0].roi_histogram_counts, [2, 1])
        var incomplete = image
        incomplete.removeValue(forKey: "roi_histogram_edges")
        raw["images"] = [incomplete]
        XCTAssertThrowsError(try Snapshot.decode(JSONSerialization.data(withJSONObject: raw)))
    }
    func testPhysicalPixelResolutionAndColorbarLimits() throws {
        XCTAssertEqual(WorkspaceModel.pixelResolution(axis: [10.0, 10.025, 10.050], unit: "µm"), "0.025000 µm")
        XCTAssertEqual(WorkspaceModel.pixelResolution(axis: [3.0, 3.04, 3.08], unit: "µm"), "0.040000 µm")
        XCTAssertEqual(WorkspaceModel.pixelResolution(axis: [0, 1, 3], unit: "µm"), "—")
        XCTAssertEqual(WorkspaceModel.pixelResolution(axis: [0, 1], unit: nil), "—")
        XCTAssertEqual(WorkspaceModel.pixelResolution(axis: [0, 1], unit: "mm"), "—")
        XCTAssertEqual(WorkspaceModel.pixelResolution(axis: [1.0, 1.1], unit: "μm"), "0.10000 μm")
        let image = try JSONDecoder().decode(ScientificImage.self, from: Data(#"{"title":"Intensity","width":2,"height":2,"full_width":2,"full_height":2,"values":[4,6,5,7],"minimum":0,"maximum":10}"#.utf8))
        let model = WorkspaceModel(preview: true)
        model.contrastLow = 0.2
        model.contrastHigh = 0.8
        let limits = model.displayLimits(for: image)
        XCTAssertEqual(limits?.lower, 2)
        XCTAssertEqual(limits?.upper, 8)
        let canvas = ScientificCanvas(model: model, image: image)
        let rect = canvas.plotRect(in: CGSize(width: 420, height: 320))
        XCTAssertLessThan(rect.maxX + 85, 420)
    }
    func testImageHistogramTracksClearedROIForAllSavedSelectionKinds() throws {
        let model = WorkspaceModel(preview: true)
        let base = try fixture()
        let encoded = try JSONEncoder().encode(base)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        var images = try XCTUnwrap(object["images"] as? [[String: Any]])
        images[0]["roi_histogram_counts"] = [1, 1]
        images[0]["roi_histogram_edges"] = [0.0, 1.0, 2.0]
        images[0]["roi_minimum"] = 0.0
        images[0]["roi_maximum"] = 2.0
        images[0]["roi_mean"] = 1.0
        object["images"] = images
        let stale = try Snapshot.decode(JSONSerialization.data(withJSONObject: object))
        model.accept(stale, method: "open", target: .load)
        XCTAssertTrue(model.addROI(bounds: [0, 0, 1, 1]))
        XCTAssertNotNil(model.image?.roi_histogram_counts)
        model.clearROIs()
        XCTAssertNil(model.image?.roi_histogram_counts)
    }
    func multiImageFixture(_ titles: [String]) throws -> Snapshot {
        let images: [[String: Any]] = titles.enumerated().map { index, title in
            ["title": title, "width": 2, "height": 2, "full_width": 2, "full_height": 2,
             "values": [Double(index + 1), 2, 3, 4]]
        }
        let value: [String: Any] = ["source": "/measurement.npz", "shape": [2, 2, 2], "energies": [280, 281],
                                    "normalized": true, "pca_ready": false, "clusters_ready": false,
                                    "energy_index": 0, "selected_x": 0, "selected_y": 0,
                                    "images": images, "spectra": [], "metrics": [:], "history": []]
        return try Snapshot.decode(JSONSerialization.data(withJSONObject: value))
    }
    func spatialFixture() throws -> Snapshot {
        let value: [String: Any] = ["source": "/measurement.npz", "shape": [2, 2, 2], "energies": [280, 281],
                                    "normalized": true, "pca_ready": false, "clusters_ready": false,
                                    "energy_index": 0, "selected_x": 0, "selected_y": 0,
                                    "images": [["title": "Intensity", "width": 2, "height": 2, "full_width": 2,
                                                "full_height": 2, "values": [1, 2, 3, 4]]],
                                    "spectra": [], "metrics": [:], "history": [],
                                    "spatial": ["x": [0.0, 0.05], "y": [0.0, 0.05], "unit": "µm"]]
        return try Snapshot.decode(JSONSerialization.data(withJSONObject: value))
    }
    func testSourceResolutionUsesFiveSignificantDigitsWithoutUnitConversion() throws {
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(try spatialFixture())) as? [String: Any])
        json["spatial"] = ["x": [0.0, 0.013000000268220901], "y": [0.0, 0.017000000923871994],
                           "unit": "µm", "x_pixel_size": 0.013000000268220901, "y_pixel_size": 0.017000000923871994]
        let source = try Snapshot.decode(JSONSerialization.data(withJSONObject: json))
        let model = WorkspaceModel(preview: true)
        model.accept(source, method: "open", target: .load)
        let original = model.sourceSummaryRows[0].suffix(2).map(\.value)
        XCTAssertEqual(original, ["0.013000 µm", "0.017000 µm"])
        XCTAssertEqual(WorkspaceModel.pixelResolution(axis: [0, 0.05], unit: "µm"), "0.050000 µm")
        XCTAssertEqual(WorkspaceModel.pixelResolution(axis: [], unit: "nm", sourceValue: 13.0), "13.000 nm")
        XCTAssertEqual(WorkspaceModel.pixelResolution(axis: [], unit: "nm", sourceValue: 123456), "1.2346e+05 nm")
        model.zoom(to: 2)
        model.accept(source, method: "view", target: .load)
        XCTAssertEqual(model.sourceSummaryRows[0].suffix(2).map(\.value), original)
    }
    func testSourceSummaryCollapsesMetadataIntoOneRow() throws {
        let model = WorkspaceModel(preview: true)
        model.accept(try spatialFixture(), method: "open", target: .load)
        let rows = model.sourceSummaryRows
        XCTAssertEqual(rows.count, 1, "Metadata must read as a single row, not two stacked rows")
        XCTAssertEqual(rows[0].map(\.label),
                       ["SHAPE", "SIGNAL", "Energy", "Energy range", "X resolution / pixel", "Y resolution / pixel"])
        XCTAssertEqual(rows[0].map(\.value),
                       ["2 × 2 × 2", "Optical density", "2", "280.000–281.000 eV", "0.050000 µm", "0.050000 µm"])
        XCTAssertEqual(rows[0].map { InterfaceText.value($0.value, language: .simplifiedChinese) },
                       ["2 × 2 × 2", "光密度", "2", "280.000–281.000 eV", "0.050000 µm", "0.050000 µm"],
                       "The view renders every cell through the localization table, leaving numbers and units intact")
    }
    func testDeclaredODHasOnlyODSignalAndMatchesEnginePayload() throws {
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(try fixture("Optical density"))) as? [String: Any])
        json["input_is_od"] = true
        json["display"] = "od"
        let model = WorkspaceModel(preview: true)
        model.openAsOpticalDensity = true
        model.accept(try Snapshot.decode(JSONSerialization.data(withJSONObject: json)), method: "open", target: .load)
        XCTAssertEqual(model.signalOptions.map(\.id), ["display:od"])
        XCTAssertEqual(model.display, "od")
        XCTAssertEqual(model.selectedSignalOptionID, "display:od")
        XCTAssertEqual(model.viewParameters()["display"], .string("od"))
        XCTAssertFalse(model.selectSignal("display:intensity"))
        model.openAsOpticalDensity = false
        XCTAssertEqual(model.signalOptions.map(\.id), ["display:od"], "Next-file checkbox must not reinterpret current data")
    }
    func testRecordingHistoryKeepsImportedSignalSemantics() throws {
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(try fixture("Optical density"))) as? [String: Any])
        json["input_is_od"] = true
        json["display"] = "od"
        let model = WorkspaceModel(preview: true)
        model.accept(try Snapshot.decode(JSONSerialization.data(withJSONObject: json)), method: "open", target: .load)
        model.record("note", ["description": .string("display only")])
        XCTAssertEqual(model.snapshot?.input_is_od, true)
        XCTAssertEqual(model.snapshot?.display, "od")
        XCTAssertEqual(model.signalOptions.map(\.id), ["display:od"])
    }
    func testIntensityImportHasOnlyIntensityAndODImportHasOnlyOD() throws {
        let model = WorkspaceModel(preview: true)
        // 1. Raw intensity input (input_is_od is false) -> ONLY Intensity option, no OD conversion in Load Data
        var rawJson = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(try fixture("Intensity", normalized: false))) as? [String: Any])
        rawJson["input_is_od"] = false
        rawJson["display"] = "intensity"
        model.accept(try Snapshot.decode(JSONSerialization.data(withJSONObject: rawJson)), method: "open", target: .load)

        // Dropdown box must have ONLY Intensity option
        XCTAssertEqual(model.signalOptions.map(\.id), ["display:intensity"])
        XCTAssertEqual(model.selectedSignalOptionID, "display:intensity")
        XCTAssertFalse(model.selectSignal("display:od"), "Intensity import must not offer or convert to OD")

        // 2. Direct OD input (input_is_od is true) -> ONLY OD option
        var odJson = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(try fixture("Optical density", normalized: true))) as? [String: Any])
        odJson["input_is_od"] = true
        odJson["display"] = "od"
        model.accept(try Snapshot.decode(JSONSerialization.data(withJSONObject: odJson)), method: "open", target: .load)
        XCTAssertEqual(model.signalOptions.map(\.id), ["display:od"])
        XCTAssertFalse(model.selectSignal("display:intensity"), "OD import must not offer intensity option")
    }
    func testRawImportResetsSignalThenNormalizationEnablesOD() throws {
        let model = WorkspaceModel(preview: true)
        model.display = "od"
        model.accept(try fixture(normalized: false), method: "open", target: .load)
        XCTAssertEqual(model.display, "intensity", "A newly opened raw file cannot inherit OD from the previous file")
        XCTAssertEqual(model.signalOptions.map(\.id), ["display:intensity"], "Raw intensity import offers only Intensity before normalization")
        XCTAssertEqual(model.selectedSignalOptionID, "display:intensity")
        XCTAssertFalse(model.selectSignal("display:od"), "OD cannot be selected before normalization")
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(try fixture("Optical density"))) as? [String: Any])
        json["input_is_od"] = false
        json["display"] = "od"
        model.accept(try Snapshot.decode(JSONSerialization.data(withJSONObject: json)), method: "normalize", target: .preprocess)
        XCTAssertEqual(model.display, "od", "The selector must reflect the signal actually returned by normalize")
        XCTAssertEqual(model.signalOptions.map(\.id), ["display:intensity", "display:od"])
        XCTAssertTrue(model.selectSignal("display:intensity"))
        XCTAssertEqual(model.viewParameters()["display"], .string("intensity"))
    }
    func testSignalPickerMergesDisplayAndImageSelectionIntoOneControl() throws {
        let model = WorkspaceModel(preview: true)
        model.accept(try fixture(normalized: true), method: "open", target: .load)
        XCTAssertEqual(model.signalOptions.map(\.id), ["display:intensity", "display:od"])
        XCTAssertEqual(model.selectedSignalOptionID, "display:intensity")
        XCTAssertFalse(model.showsImagePicker, "A single image must not render a second, duplicate picker")
        XCTAssertTrue(model.selectSignal("display:od"))
        XCTAssertEqual(model.display, "od")
        XCTAssertEqual(model.selectedImage, 0)
        XCTAssertFalse(model.selectSignal("display:fabricated"))

        let multi = WorkspaceModel(preview: true)
        multi.accept(try multiImageFixture(["Intensity", "Clusters"]), method: "open", target: .load)
        XCTAssertTrue(multi.showsImagePicker)
        XCTAssertEqual(multi.signalOptions.map(\.id), ["display:intensity", "display:od", "image:1"])
        XCTAssertTrue(multi.selectSignal("image:1"))
        XCTAssertEqual(multi.selectedImage, 1)
        XCTAssertEqual(multi.display, "intensity", "Choosing an analysis image must not change the display signal")
        XCTAssertEqual(multi.selectedSignalOptionID, "image:1")
    }
    func testMergedImagePickerPreservesFirstAnalysisImage() throws {
        let model = WorkspaceModel(preview: true)
        model.accept(try multiImageFixture(["Clusters", "Cluster distance (spectral SSE)"]),
                     method: "cluster", target: .pca)
        model.section = .pca
        XCTAssertEqual(model.signalOptions.map(\.id), ["image:0", "image:1"])
        XCTAssertEqual(model.selectedSignalOptionID, "image:0")
        XCTAssertTrue(model.selectSignal("image:1"))
        XCTAssertEqual(model.image?.title, "Cluster distance (spectral SSE)")
        XCTAssertTrue(model.selectSignal("image:0"))
        XCTAssertEqual(model.image?.title, "Clusters", "The first analysis image must remain reachable")
        XCTAssertFalse(model.selectSignal("display:od"), "Analysis images are not intensity/OD frames")
    }
    func testEngineImageTitlesAreLocalizedForDisplay() {
        XCTAssertEqual(InterfaceText.value("Clusters", language: .simplifiedChinese), "聚类图")
        XCTAssertEqual(InterfaceText.value("Cluster distance (spectral SSE)", language: .simplifiedChinese), "聚类距离 (谱 SSE)")
        XCTAssertEqual(InterfaceText.value("Clusters", language: .english), "Clusters")
        XCTAssertEqual(InterfaceText.value("Full image", language: .simplifiedChinese), "全图")
        XCTAssertEqual(InterfaceText.value("Selected pixel · signal at current energy", language: .simplifiedChinese), "所选像素 · 当前能量下的信号")
        XCTAssertEqual(InterfaceText.value("PC 3", language: .simplifiedChinese), "PC 3",
                       "Unbounded analysis titles stay opaque")
    }
    func testChartToolbarGroupsFourAlignedControlsWithLegibleReset() {
        XCTAssertEqual(ChartZoomMode.allCases.count, 3)
        XCTAssertEqual(ChartToolbar.allSymbols.count, 4, "Three zoom modes plus reset share one toolbar group")
        XCTAssertEqual(Set(ChartToolbar.allSymbols).count, 4, "Every toolbar control needs a distinct icon")
        XCTAssertEqual(ChartToolbar.symbol(for: .original), "1.magnifyingglass")
        XCTAssertEqual(ChartToolbar.symbol(for: .fit), "arrow.up.left.and.arrow.down.right")
        XCTAssertEqual(ChartToolbar.symbol(for: .box), "rectangle.dashed")
        XCTAssertEqual(ChartToolbar.resetSymbol, "arrow.counterclockwise.circle")
        XCTAssertEqual(ChartToolbar.groupSpacing, 0, "Reset must sit inside the same group as the modes")
        XCTAssertGreaterThanOrEqual(ChartToolbar.buttonHeight, 22)
    }
    func testImageCanvasEnlargesAndColorbarAdaptsToPlotHeight() throws {
        XCTAssertEqual(ScientificCanvas.canvasHeight, 384, accuracy: 0.001,
                       "1.2x of the previous 320 pt canvas")
        let small = ScientificCanvas.colorbarGeometry(plotHeight: 200)
        let large = ScientificCanvas.colorbarGeometry(plotHeight: 320)
        XCTAssertGreaterThan(large.height, small.height, "The bar must grow with the image")
        XCTAssertLessThanOrEqual(large.height, 320)
        XCTAssertGreaterThanOrEqual(small.height, 96)
        XCTAssertEqual(small.width, large.width, "Bar width stays constant so labels keep their gutter")
        let image = try JSONDecoder().decode(ScientificImage.self, from: Data(#"{"title":"Intensity","width":2,"height":2,"full_width":2,"full_height":2,"values":[1,2,3,4]}"#.utf8))
        let rect = ScientificCanvas(model: WorkspaceModel(preview: true), image: image)
            .plotRect(in: CGSize(width: 460, height: ScientificCanvas.canvasHeight))
        XCTAssertLessThanOrEqual(rect.maxX + ScientificCanvas.colorbarRightInset, 460,
                                 "The colorbar and its labels must stay inside the canvas")
    }
    func testCanvasEnlargementIncreasesTheImageNotOnlyItsContainer() throws {
        let image = try JSONDecoder().decode(ScientificImage.self, from: Data(#"{"title":"Intensity","width":2,"height":2,"full_width":2,"full_height":2,"values":[1,2,3,4]}"#.utf8))
        let canvas = ScientificCanvas(model: WorkspaceModel(preview: true), image: image)
        // Previous 420 × 320 layout: min(420 - 2 × 46 - 96, 320 - 2 × 46) = 228 pt.
        let rect = canvas.plotRect(in: CGSize(width: 420, height: ScientificCanvas.canvasHeight))
        XCTAssertGreaterThanOrEqual(rect.width / 228, 1.18,
                                    "Growing only the frame leaves width-constrained images unchanged")
        XCTAssertLessThanOrEqual(rect.width / 228, 1.3)
        XCTAssertGreaterThanOrEqual(rect.minX, 32, "Keep room for the source-coordinate axis")
        XCTAssertLessThanOrEqual(rect.maxX + ScientificCanvas.colorbarRightInset, 420)
        XCTAssertLessThanOrEqual(ScientificCanvas.colorbarGeometry(plotHeight: 40).height, 40,
                                 "A short/wide image must not have a colorbar taller than the image")
    }
    func testDataExportRowOrdersFormatBeforeDataAndUsesTextAction() {
        XCTAssertEqual(WorkspaceModel.dataExportFieldOrder, ["format", "data"])
        XCTAssertEqual(WorkspaceModel.dataExportActionTitle, "Export Data…")
        XCTAssertFalse(WorkspaceModel.dataExportActionUsesIcon)
    }
    func testConnectedStatusIsHiddenInTheBottomBarAsWell() {
        let model = WorkspaceModel(preview: true)
        model.status = "Engine connected"
        XCTAssertNil(model.visibleStatus)
        model.status = "Operation failed"
        XCTAssertEqual(model.visibleStatus, "Operation failed")
        model.status = "Completed open"
        XCTAssertEqual(model.visibleStatus, "Completed open")
    }
    func testSidebarDropsRedundantConnectedLabelButKeepsDisconnectedNotice() {
        XCTAssertNil(WorkspaceModel.sidebarStatusLabel(connected: true),
                     "A connected engine needs no status sentence in the footer")
        XCTAssertEqual(WorkspaceModel.sidebarStatusLabel(connected: false), "Not connected")
    }
    func testAnalysisChartsDoNotRetainUnavailableROISelection() throws {
        let model = WorkspaceModel(preview: true)
        model.accept(try largeFixture(), method: "open", target: .load)
        model.addROI(bounds: [2, 2, 5, 5])
        let base = try multiImageFixture(["PC 1", "PC 2"])
        let analysis = Snapshot(source: base.source, shape: base.shape, energies: base.energies,
                                normalized: true, pca_ready: true, clusters_ready: false,
                                energy_index: 0, selected_x: 0, selected_y: 0, images: base.images,
                                spectra: [Spectrum(name: "PC 1", x: base.energies, y: [1, 2]),
                                          Spectrum(name: "PC 2", x: base.energies, y: [2, 1])], metrics: [:])
        model.accept(analysis, method: "pca", target: .pca)
        model.section = .pca
        XCTAssertEqual(model.selectedSeriesName, "All spectra", "The picker cannot retain an unavailable ROI tag")
        XCTAssertTrue(model.selectSeries(named: "PC 2"))
        XCTAssertEqual(model.selectedSeriesName, "PC 2")
        XCTAssertEqual(model.image?.title, "PC 2", "The histogram must follow the selected eigenimage")
        model.accept(try fixture(), method: "open", target: .load)
        XCTAssertEqual(model.selectedSeriesName, "All spectra")
    }
    func testNonROISeriesNeverKeepsThePreviousROIHistogram() throws {
        let model = WorkspaceModel(preview: true)
        let base = try largeFixture()
        let snapshot = Snapshot(source: base.source, shape: base.shape, energies: base.energies,
                                normalized: base.normalized, pca_ready: false, clusters_ready: false,
                                energy_index: 0, selected_x: 0, selected_y: 0, images: base.images,
                                spectra: [Spectrum(name: "Pixel", x: base.energies, y: [2, 3]),
                                          Spectrum(name: "Full image", x: base.energies, y: [4, 5])],
                                metrics: [:])
        model.accept(snapshot, method: "open", target: .load)
        model.addROI(bounds: [2, 2, 5, 5])
        XCTAssertEqual(model.activeROILabel, "[1] ROI 1")
        XCTAssertTrue(model.selectSeries(named: "Pixel"))
        XCTAssertNil(model.selectedROIIndex)
        XCTAssertNil(model.viewParameters()["roi"])
        XCTAssertTrue(model.selectSeries(named: "Full image"))
        XCTAssertTrue(model.selectSeries(named: "All spectra"))
        model.selectedROIIndex = 1
        XCTAssertEqual(model.activeROILabel, "[1] ROI 1")
    }
    func testHistogramUsesTheSameSeriesSelectionAsTheSpectrum() throws {
        let image = try JSONDecoder().decode(ScientificImage.self, from: Data(#"{"title":"Intensity","width":2,"height":2,"full_width":2,"full_height":2,"values":[1,2,3,4],"minimum":1,"maximum":4,"mean":2.5,"histogram_counts":[2,2],"histogram_edges":[1,2.5,4],"roi_minimum":3,"roi_maximum":4,"roi_mean":3.5,"roi_histogram_counts":[1,1],"roi_histogram_edges":[3,3.5,4]}"#.utf8))
        let spectra = [Spectrum(name: "Pixel", x: [280, 281], y: [1, 9])]
        let pixel = try XCTUnwrap(SpectraChart.selectedHistogram(image: image, spectra: spectra,
            selectedSeries: "Pixel", selectedEnergy: 281, activeROI: nil))
        XCTAssertEqual(pixel.counts.reduce(0, +), 1)
        XCTAssertEqual(pixel.minimum, 9)
        XCTAssertEqual(pixel.maximum, 9)
        XCTAssertEqual(pixel.mean, 9)
        let all = try XCTUnwrap(SpectraChart.selectedHistogram(image: image, spectra: spectra,
            selectedSeries: "All spectra", selectedEnergy: 281, activeROI: nil))
        XCTAssertEqual(all.title, "Visible image pixels · signal distribution")
        XCTAssertEqual(all.counts, [2, 2], "All spectra must not retain the old ROI distribution")
        let roi = try XCTUnwrap(SpectraChart.selectedHistogram(image: image, spectra: spectra,
            selectedSeries: "[1] ROI 1", selectedEnergy: 281, activeROI: "[1] ROI 1"))
        XCTAssertEqual(roi.title, "Selected ROI pixels · signal distribution")
        XCTAssertEqual(roi.counts, [1, 1])
        XCTAssertEqual(roi.mean, 3.5)
    }
    func testSelectingSeriesBindsChartsToTheSameDataset() throws {
        let model = WorkspaceModel(preview: true)
        model.accept(try largeFixture(), method: "open", target: .load)
        XCTAssertTrue(model.addROI(bounds: [2, 2, 5, 5]))
        XCTAssertEqual(model.activeROILabel, "[1] ROI 1")
        XCTAssertTrue(model.selectSeries(named: "[1] ROI 1"))
        XCTAssertEqual(model.selectedROIIndex, 1)
        XCTAssertTrue(model.selectSeries(named: "All spectra"))
        XCTAssertNil(model.selectedROIIndex, "All spectra returns both charts to the full-image dataset")
        XCTAssertNil(model.activeROILabel)
        XCTAssertFalse(model.selectSeries(named: "[9] ROI 9"), "An unknown series must not change the dataset")
    }
    func testClearingROIImmediatelyHidesStaleChartData() throws {
        let model = WorkspaceModel(preview: true)
        let base = try fixture()
        let encoded = try JSONEncoder().encode(base)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object["spectra"] = [
            ["name": "Pixel", "x": [280.0, 281.0], "y": [1.0, 2.0]],
            ["name": "[1] ROI 1", "x": [280.0, 281.0], "y": [2.0, 3.0]]
        ]
        var images = try XCTUnwrap(object["images"] as? [[String: Any]])
        images[0]["roi_histogram_counts"] = [1, 1]
        images[0]["roi_histogram_edges"] = [0.0, 1.0, 2.0]
        images[0]["roi_minimum"] = 0.0
        images[0]["roi_maximum"] = 2.0
        images[0]["roi_mean"] = 1.0
        object["images"] = images
        let stale = try Snapshot.decode(JSONSerialization.data(withJSONObject: object))
        model.accept(stale, method: "open", target: .load)
        XCTAssertTrue(model.addROI(bounds: [0, 0, 1, 1]))
        XCTAssertNotNil(model.image?.roi_histogram_counts)
        model.clearROIs()
        XCTAssertEqual(model.displayedSpectra.map(\.name), ["Pixel"])
        XCTAssertNil(model.image?.roi_histogram_counts)
    }
    func testRemovedROISeriesSelectionFallsBackToFullImage() {
        let spectra = [Spectrum(name: "Pixel", x: [1], y: [2]),
                       Spectrum(name: "Full image", x: [1], y: [3])]
        XCTAssertEqual(SpectraChart.resolvedSeries("[1] ROI 1", in: spectra), "All spectra")
        XCTAssertEqual(SpectraChart.resolvedSeries("Pixel", in: spectra), "Pixel")
    }
    func testBoxSelectionFiltersSpectraAndHistogramSamples() {
        let series = [Spectrum(name: "ROI 1", x: [1, 2, 3, 4], y: [3, 4, 5, 6])]
        let zoomed = SpectraChart.zoomedSpectra(series, x: 1.5...3.5, y: 4...5)
        XCTAssertEqual(zoomed[0].x, [2, 3])
        XCTAssertEqual(zoomed[0].y, [4, 5])
        let bins = SpectraChart.histogramBins(counts: [1, 2, 3, 4], edges: [0, 1, 2, 3, 4])
        // Bars spanning the selected Y interval must remain visible and be
        // clipped by the chart scale, even when their top exceeds the box.
        XCTAssertEqual(SpectraChart.zoomedBins(bins, x: 1...3, y: 0...2).map(\.count), [2, 3])
        XCTAssertEqual(SpectraChart.zoomedBins(bins, x: 1...3, y: 2.5...3.5).map(\.count), [3])
    }
    func testNormalizedStackRejectsODToggleOnlyWhenUnnormalized() throws {
        let model = WorkspaceModel(preview: true)
        model.accept(try fixture(normalized: false), method: "open", target: .load)
        XCTAssertFalse(model.canDisplayOpticalDensity)
        model.accept(try fixture(normalized: true), method: "normalize", target: .preprocess)
        XCTAssertTrue(model.canDisplayOpticalDensity)
    }
    func testROIColorsPersistThroughViewRefresh() throws {
        let model = WorkspaceModel(preview: true)
        model.accept(try largeFixture(), method: "open", target: .load)
        XCTAssertTrue(model.addROI(bounds: [2, 2, 5, 5]))
        XCTAssertTrue(model.setROIColor(index: 1, hex: ROIPresets.colors[5]))
        model.accept(try largeFixture(), method: "view", target: .load)
        XCTAssertEqual(model.rois.first?.colorHex, ROIPresets.colors[5])
    }
    func testPendingROIShapesColorsAndClearPayload() throws {
        let model = WorkspaceModel(preview: true)
        model.accept(try fixture(normalized: false), method: "open", target: .load)
        model.roiMode = "Pixel"
        model.pendingPixel = [1, 1]
        XCTAssertTrue(model.canAddROI)
        XCTAssertTrue(model.addPendingROI())
        XCTAssertEqual(model.rois[0].bounds, [1, 1, 2, 2])
        guard case .array(let saved)? = model.viewParameters()["rois"] else { return XCTFail("Missing ROI list") }
        XCTAssertEqual(saved.count, 1)
        model.roiMode = "Lasso"
        model.polygon = [[0, 0], [2, 0], [2, 2], [0, 2]]
        XCTAssertTrue(model.addPendingROI())
        XCTAssertEqual(model.rois[1].polygon?.count, 4)
        guard case .array(let vertices)? = model.viewParameters()["rois"] else { return XCTFail("Missing ROI list") }
        guard case .object(let second) = vertices[1], case .array(let polygon)? = second["polygon"] else { return XCTFail("Missing saved polygon") }
        XCTAssertEqual(polygon.count, 4)
        XCTAssertTrue(model.setROIColor(index: 2, hex: ROIPresets.colors[3]))
        XCTAssertEqual(model.rois[1].colorHex, ROIPresets.colors[3])
        XCTAssertFalse(model.setROIColor(index: 2, hex: "invalid"))
        model.clearROIs()
        XCTAssertTrue(model.rois.isEmpty)
        XCTAssertNil(model.polygon)
        XCTAssertNil(model.pendingPixel)
        XCTAssertEqual(model.viewParameters()["rois"], .array([]))
        XCTAssertNil(model.viewParameters()["roi"])
        XCTAssertNil(model.viewParameters()["polygon"])
        XCTAssertEqual(model.selectedExportTarget, "AllData")
    }
    func testMultiROIManagementAndBoundsLimit() throws {
        let model = WorkspaceModel(preview: true)
        let snapshot = try largeFixture()
        model.accept(snapshot, method: "open", target: .load)

        // Add 8 ROIs -> no warning
        for i in 1...8 {
            let success = model.addROI(bounds: [i, i, i + 2, i + 2])
            XCTAssertTrue(success)
            XCTAssertNil(model.roiWarning)
        }
        XCTAssertEqual(model.rois.count, 8)

        // 9th ROI -> warning triggered
        XCTAssertTrue(model.addROI(bounds: [10, 10, 12, 12]))
        XCTAssertEqual(model.rois.count, 9)
        XCTAssertNotNil(model.roiWarning)
        XCTAssertTrue(model.roiWarning?.contains("ROI过多") == true)

        // 10th ROI -> accepted with warning
        XCTAssertTrue(model.addROI(bounds: [13, 13, 15, 15]))
        XCTAssertEqual(model.rois.count, 10)

        // 11th ROI -> strictly rejected, remains 10
        XCTAssertFalse(model.addROI(bounds: [16, 16, 18, 18]))
        XCTAssertEqual(model.rois.count, 10)
        XCTAssertTrue(model.roiWarning?.contains("上限") == true)

        // Remove two ROIs -> count drops to 8, warning clears
        model.removeROI(index: 10)
        model.removeROI(index: 9)
        XCTAssertEqual(model.rois.count, 8)
        XCTAssertNil(model.roiWarning)

        // Clear all
        model.clearROIs()
        XCTAssertEqual(model.rois.count, 0)
    }
    func largeFixture() throws -> Snapshot {
        let value: [String: Any] = [
            "source": "/measurement.npz",
            "shape": [100, 100, 10],
            "energies": Array(repeating: 280.0, count: 10),
            "normalized": false,
            "pca_ready": false,
            "clusters_ready": false,
            "energy_index": 0,
            "selected_x": 0,
            "selected_y": 0,
            "images": [["title": "Intensity", "width": 100, "height": 100, "full_width": 100, "full_height": 100, "values": Array(repeating: 1.0, count: 10000)]],
            "spectra": [],
            "metrics": [:],
            "history": []
        ]
        return try Snapshot.decode(JSONSerialization.data(withJSONObject: value))
    }
    func testZoomCentersOnSelectedROI() throws {
        let model = WorkspaceModel(preview: true)
        let snapshot = try largeFixture()
        model.accept(snapshot, method: "open", target: .load)

        // Add ROI near corner: [60, 70, 80, 90] -> center is (70, 80)
        model.addROI(bounds: [60, 70, 80, 90])
        XCTAssertEqual(model.selectedROIIndex, 1)

        // Zoom to 2x without specifying center -> must auto center on the selected ROI
        // With shape (100, 100) and target 2, width=50, height=50
        // Center around (70, 80):
        // x0 = min(100 - 50, max(0, 70 - 25)) = min(50, 45) = 45
        // y0 = min(100 - 50, max(0, 80 - 25)) = min(50, 55) = 50
        model.zoom(to: 2)
        XCTAssertNotNil(model.viewport)
        XCTAssertEqual(model.viewport?[0], 45)
        XCTAssertEqual(model.viewport?[1], 50)
        XCTAssertEqual(model.viewport?[2], 95)
        XCTAssertEqual(model.viewport?[3], 100)
    }
    func testWorkflowLogGenerationJSONAndMarkdown() throws {
        let model = WorkspaceModel(preview: true)
        let snapshot = try fixture("Intensity")
        model.accept(snapshot, method: "open", target: .load)
        model.record("open", ["path": .string("/data.hdr"), "pre_normalized": .bool(false)])

        let jsonLog = try model.generateWorkflowLog(format: "json")
        XCTAssertTrue(jsonLog.contains("/measurement.npz"))
        XCTAssertTrue(jsonLog.contains("open"))

        let mdLog = try model.generateWorkflowLog(format: "md")
        XCTAssertTrue(mdLog.contains("# MANTiS"))
        XCTAssertTrue(mdLog.contains("open"))
    }
    func testInvalidHistogramMeanIsRejected() throws {
        var json: [String: Any] = ["source": "/measurement.npz", "shape": [2, 2, 2], "energies": [280, 281], "normalized": false, "pca_ready": false, "clusters_ready": false, "energy_index": 0, "selected_x": 0, "selected_y": 0, "images": [["title": "Intensity", "width": 2, "height": 2, "full_width": 2, "full_height": 2, "values": [1, 2, 3, 4], "minimum": 1.0, "maximum": 4.0, "mean": 5.0, "histogram_counts": [1, 3], "histogram_edges": [1.0, 2.5, 4.0]]], "spectra": [], "metrics": [:], "history": []]
        XCTAssertThrowsError(try Snapshot.decode(JSONSerialization.data(withJSONObject: json)))
        var image = try XCTUnwrap((json["images"] as? [[String: Any]])?.first)
        image["mean"] = 2.5
        json["images"] = [image]
        XCTAssertNoThrow(try Snapshot.decode(JSONSerialization.data(withJSONObject: json)))
    }
    func testSpectralChartDomainUsesMeasuredPhotonEnergyNotZero() throws {
        let spectrum = try JSONDecoder().decode(Spectrum.self, from: Data(#"{"name":"Pixel","x":[625,640,675],"y":[0.8,0.9,1.1]}"#.utf8))
        let domain = try XCTUnwrap(SpectraChart.domain(for: [spectrum]))
        XCTAssertEqual(domain.x.lowerBound, 625)
        XCTAssertEqual(domain.x.upperBound, 675)
        XCTAssertEqual(domain.y.lowerBound, 0.8)
        XCTAssertEqual(domain.y.upperBound, 1.1)
    }
    func testZoomUpdatesViewportWithoutChangingTheUnderlyingStack() throws {
        let model = WorkspaceModel(preview: true)
        let data = try Snapshot.decode(JSONSerialization.data(withJSONObject: ["source": "/measurement.npz", "shape": [1024, 512, 2], "energies": [280, 281], "normalized": false, "pca_ready": false, "clusters_ready": false, "energy_index": 0, "selected_x": 0, "selected_y": 0, "images": [], "spectra": [], "metrics": [:], "history": []] as [String: Any]))
        model.accept(data, method: "open", target: .load)
        model.zoom(to: 4, centerX: 512, centerY: 256)
        XCTAssertEqual(model.viewport, [384, 192, 640, 320])
        XCTAssertEqual(model.snapshot?.shape, [1024, 512, 2])
        model.zoom(to: 1)
        XCTAssertNil(model.viewport)
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
    func testOpenSelectionUsesHDRFileWithoutChangingInputFiles() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let header = folder.appendingPathComponent("Sol_240309145.hdr")
        let frame = folder.appendingPathComponent("Sol_240309145_a000.xim")
        try Data("header".utf8).write(to: header)
        try Data("frame".utf8).write(to: frame)
        XCTAssertEqual(try WorkspaceModel.stackFile(from: header).resolvingSymlinksInPath(), header.resolvingSymlinksInPath())
        XCTAssertThrowsError(try WorkspaceModel.stackFile(from: folder))
        XCTAssertEqual(try Data(contentsOf: frame), Data("frame".utf8))
    }
    func testOpenSelectionPreservesPluginFallbackForOtherExtensions() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("unknown.xyz")
        try Data().write(to: file)
        XCTAssertEqual(try WorkspaceModel.stackFile(from: file).resolvingSymlinksInPath(), file.resolvingSymlinksInPath())
    }
    func testOpenSelectionUsesLastHDF5Extension() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("scan.hdf5.hdf5")
        try Data().write(to: file)
        XCTAssertEqual(file.pathExtension, "hdf5")
        XCTAssertEqual(try WorkspaceModel.stackFile(from: file).resolvingSymlinksInPath(), file.resolvingSymlinksInPath())
    }
    func testOpenStackRequiresExplicitOpticalDensityDeclaration() throws {
        let model = WorkspaceModel(preview: true)
        XCTAssertFalse(model.openAsOpticalDensity)
        model.openAsOpticalDensity = true
        XCTAssertTrue(model.openAsOpticalDensity)
    }
    func testOpenFormSharesTheMainOpticalDensityDeclaration() throws {
        let form = try XCTUnwrap(CommandCatalog.forms(for: .load).first { $0.method == "open" })
        let model = WorkspaceModel(preview: true)
        model.openAsOpticalDensity = true
        let declared = try CommandEditor.parameters(for: form, values: ["path": "/measurement.hdr"], openAsOpticalDensity: model.openAsOpticalDensity)
        XCTAssertEqual(declared["pre_normalized"], .bool(true))
        model.openAsOpticalDensity = false
        let raw = try CommandEditor.parameters(for: form, values: ["path": "/measurement.hdr", "pre_normalized": "true"], openAsOpticalDensity: model.openAsOpticalDensity)
        XCTAssertEqual(raw["pre_normalized"], .bool(false))
    }
    func testRealFileSelectionResolvesProvidedSDFAndMistralFiles() throws {
        let docs = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("docs")
        let sdf = docs.appendingPathComponent("Sol_240309145/Sol_240309145.hdr")
        let aligned = docs.appendingPathComponent("20230629_E1A_749.7x177.5y_specnorm_aliOF.hdf5.hdf5")
        let plain = docs.appendingPathComponent("20230629_E1A_749.7x177.5y_specnorm.hdf5")
        guard FileManager.default.fileExists(atPath: sdf.path), FileManager.default.fileExists(atPath: aligned.path), FileManager.default.fileExists(atPath: plain.path) else { throw XCTSkip("User-provided datasets are not present") }
        XCTAssertEqual(try WorkspaceModel.stackFile(from: sdf).lastPathComponent, "Sol_240309145.hdr")
        XCTAssertEqual(try WorkspaceModel.stackFile(from: aligned).lastPathComponent, aligned.lastPathComponent)
        XCTAssertEqual(try WorkspaceModel.stackFile(from: plain).lastPathComponent, plain.lastPathComponent)
    }
}
