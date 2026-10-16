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

    func testImportSelectionCopyIsBilingual() {
        let pairs = [
            ("Other Parameters", "其他参数"),
            ("e.g. [[0, 0]] (optional)", "例如 [[0, 0]]（可选）"),
            ("Leave blank unless selection is required", "无需选择时留空"),
            ("No selection needed", "无需区域 / 通道选择"),
            ("Region/channel; e.g. [[0, 0]]", "区域/通道；如 [[0, 0]]"),
            ("MISTRAL: leave blank", "MISTRAL：留空"),
            ("NXstxm region/channel; e.g. [[0, 0]]", "NXstxm 区域/通道；如 [[0, 0]]"),
            ("Usually leave blank", "通常留空"),
            ("SDF: parameter 1 = region index, parameter 2 = channel index (zero-based); e.g. [[0, 0]]. Leave blank for one pair; inspect multi-pair files.", "SDF：参数1=区域索引，参数2=通道索引（从 0 开始），例如 [[0, 0]]。仅一组时留空，多组请先检查文件。"),
            ("HDF5: MISTRAL/Exchange need no selection; inspect multi-channel NXstxm and enter [[region, channel]] if required.", "HDF5：MISTRAL/Exchange 无需选择；多通道 NXstxm 请先检查文件，必要时填写 [[区域, 通道]]。"),
            ("NPZ: region/channel selection is not available.", "NPZ：不支持区域 / 通道选择。"),
            ("Optional zero-based [[region, channel]] pairs. Inspect the file before choosing when multiple pairs exist.", "可选从 0 开始的 [[区域, 通道]]；有多组时请先检查文件。")
        ]
        for (english, chinese) in pairs {
            XCTAssertEqual(InterfaceText.value(english, language: .english), english)
            XCTAssertEqual(InterfaceText.value(english, language: .simplifiedChinese), chinese)
        }
    }
    func testStatusLocalizationKeepsMethodIdentity() {
        XCTAssertEqual(InterfaceText.status("Completed pca", language: .simplifiedChinese), "已完成 pca")
        XCTAssertEqual(InterfaceText.status("Operation failed", language: .simplifiedChinese), "操作失败")
    }
}
