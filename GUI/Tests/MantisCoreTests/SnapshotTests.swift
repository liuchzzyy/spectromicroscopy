import XCTest
@testable import MantisCore
final class SnapshotTests: XCTestCase {
    func testRejectsImageShapeMismatch() {
        let bad = Data(#"{"source":"synthetic","shape":[2,2,2],"energies":[280,281],"normalized":false,"pca_ready":false,"clusters_ready":false,"energy_index":0,"selected_x":0,"selected_y":0,"images":[{"title":"Intensity","width":2,"height":2,"full_width":2,"full_height":2,"values":[1]}],"spectra":[],"metrics":{},"history":[]}"#.utf8)
        XCTAssertThrowsError(try Snapshot.decode(bad))
    }
}
