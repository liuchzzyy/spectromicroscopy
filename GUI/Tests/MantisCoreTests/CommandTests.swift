import XCTest
@testable import MantisCore
final class CommandTests: XCTestCase {
    func testAllContractWorkflowsHaveForms() {
        let expected: Set<String> = ["open","inspect_file","build_stack","view","normalize","crop","dark","despike","align","remove_image","reset","pca","cluster","export","spectral","rgb","nnma","peaks","fit_peaks","tomography","key_energies","spectral_roi","dose"]
        XCTAssertEqual(CommandCatalog.methods, expected)
    }
}
