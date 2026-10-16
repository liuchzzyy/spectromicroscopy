import XCTest
import MantisCore
@testable import Mantis

@MainActor
final class FilePreviewTests: XCTestCase {
    func testPreviewBlocksSpectralCommandsAndClearsOnPathChange() throws {
        let model = WorkspaceModel()
        model.acceptPreview(try FilePreview.decode(Data(#"{"path":"/time.h5","plugin":"time","kind":"image","width":1,"height":1,"values":[1],"metadata":{}}"#.utf8)))
        model.run("pca")
        XCTAssertNotNil(model.error)
        model.importFilePath = "/other.h5"
        XCTAssertNil(model.filePreview)
    }
    func testRejectsMalformedPreviewPayloads() {
        for json in [#"{"path":"a","plugin":"p","kind":"image","width":2,"height":1,"values":[1],"metadata":{}}"#,
                     #"{"path":"a","plugin":"p","kind":"table","columns":["a","b"],"rows":[[1]],"metadata":{}}"#] {
            XCTAssertThrowsError(try FilePreview.decode(Data(json.utf8)))
        }
    }
    func testPreviewCopyAndUnknownProvenance() throws {
        let model = WorkspaceModel()
        model.acceptPreview(try FilePreview.decode(Data(#"{"path":"/scan","plugin":"test","kind":"image","width":2,"height":1,"values":[1,2],"metadata":{},"shape":[2,1,10],"frame_count":10}"#.utf8)))
        XCTAssertEqual(model.displayFormatName, "Default")
        XCTAssertEqual(model.displayBeamlineName, "Default")
        XCTAssertEqual(InterfaceText.value("Preview File", language: .simplifiedChinese), "预览文件")
        XCTAssertEqual(InterfaceText.value("Preview File", language: .english), "Preview File")
    }
    func testTablePreviewClearsSpectralSessionAndShowsProvenance() throws {
        let model = WorkspaceModel()
        let data = Data(#"{"path":"/scan.xdi","format":"XDI","beamline":"BL14W1","plugin":"xdi","kind":"table","columns":["energy","mu"],"rows":[[7100,0.5]],"metadata":{}}"#.utf8)
        let preview = try FilePreview.decode(data)
        model.acceptPreview(preview)
        XCTAssertEqual(model.filePreview?.rows, [[7100, 0.5]])
        XCTAssertEqual(model.displayFormatName, "XDI")
        XCTAssertEqual(model.displayBeamlineName, "BL14W1")
        XCTAssertNil(model.snapshot)
        XCTAssertTrue(model.results.isEmpty)
        XCTAssertFalse(model.canExportProcessedData)
        XCTAssertEqual(model.section, .load)
    }
}
