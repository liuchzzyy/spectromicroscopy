import XCTest
@testable import Mantis

@MainActor
final class InterfacePreferencesTests: XCTestCase {
    func testSelectionsPersistAcrossInstancesAndRejectUnknownValues() {
        let suite = "mantis.preferences.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = InterfacePreferences(defaults: defaults)
        XCTAssertEqual(first.appearance, .system)
        XCTAssertEqual(first.language, .english)
        first.appearance = .dark
        first.language = .simplifiedChinese
        let second = InterfacePreferences(defaults: defaults)
        XCTAssertEqual(second.appearance, .dark)
        XCTAssertEqual(second.language, .simplifiedChinese)
        defaults.set("invalid", forKey: InterfacePreferences.appearanceKey)
        XCTAssertEqual(InterfacePreferences(defaults: defaults).appearance, .system)
    }

    func testSwitchingLanguageTranslatesNavigationAndPreservesUnknownScientificNames() {
        XCTAssertEqual(InterfaceText.value("PCA / Clusterings", language: .simplifiedChinese), "PCA / 聚类")
        XCTAssertEqual(InterfaceText.value("Load Data", language: .simplifiedChinese), "导入数据")
        XCTAssertEqual(InterfaceText.value("Open Stack", language: .simplifiedChinese), "打开数据栈")
        XCTAssertEqual(InterfaceText.value("Visible image pixels · signal distribution", language: .simplifiedChinese), "可见像素 · 信号分布")
        XCTAssertEqual(InterfaceText.value("Visible image pixels · signal distribution", language: .english), "Visible image pixels · signal distribution")
        XCTAssertEqual(InterfaceText.value("Selected ROI pixels · signal distribution", language: .simplifiedChinese), "选中 ROI 像素 · 信号分布")
        XCTAssertEqual(InterfaceText.value("Selected ROI pixels · signal distribution", language: .english), "Selected ROI pixels · signal distribution")
        XCTAssertEqual(InterfaceText.value("Beamline sample A", language: .simplifiedChinese), "Beamline sample A")
        XCTAssertEqual(InterfaceText.value("Open Stack", language: .english), "Open Stack")
    }

    func testStatusLocalizationKeepsMethodIdentity() {
        XCTAssertEqual(InterfaceText.status("Completed pca", language: .simplifiedChinese), "已完成 pca")
        XCTAssertEqual(InterfaceText.status("Operation failed", language: .simplifiedChinese), "操作失败")
    }
}
