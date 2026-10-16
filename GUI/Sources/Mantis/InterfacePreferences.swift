import Foundation
import SwiftUI

enum InterfaceAppearance: String, CaseIterable, Identifiable {
    case light, dark, system
    var id: String { rawValue }
    var symbol: String {
        switch self { case .light: "sun.max"; case .dark: "moon"; case .system: "desktopcomputer" }
    }
    var colorScheme: ColorScheme? {
        switch self { case .light: .light; case .dark: .dark; case .system: nil }
    }
}

enum InterfaceLanguage: String, CaseIterable, Identifiable {
    case english = "en", simplifiedChinese = "zh-Hans"
    var id: String { rawValue }
    var label: String { self == .english ? "English" : "简体中文" }
}

enum AppCloseBehavior: String, CaseIterable, Identifiable {
    case quit, menuBar
    var id: String { rawValue }
}

@MainActor
final class InterfacePreferences: ObservableObject {
    static let appearanceKey = "interface.appearance"
    static let languageKey = "interface.language"
    static let launchAtLoginKey = "interface.launchAtLogin"
    static let silentLaunchKey = "interface.silentLaunch"
    static let closeBehaviorKey = "interface.closeBehavior"
    static let cliPathKey = "interface.cliPath"
    private let defaults: UserDefaults
    @Published var appearance: InterfaceAppearance {
        didSet { defaults.set(appearance.rawValue, forKey: Self.appearanceKey) }
    }
    @Published var language: InterfaceLanguage {
        didSet { defaults.set(language.rawValue, forKey: Self.languageKey) }
    }
    @Published var launchAtLogin: Bool {
        didSet { defaults.set(launchAtLogin, forKey: Self.launchAtLoginKey) }
    }
    @Published var silentLaunch: Bool {
        didSet { defaults.set(silentLaunch, forKey: Self.silentLaunchKey) }
    }
    @Published var closeBehavior: AppCloseBehavior {
        didSet { defaults.set(closeBehavior.rawValue, forKey: Self.closeBehaviorKey) }
    }
    @Published var cliPath: String? {
        didSet {
            if let cliPath { defaults.set(cliPath, forKey: Self.cliPathKey) }
            else { defaults.removeObject(forKey: Self.cliPathKey) }
        }
    }
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        appearance = InterfaceAppearance(rawValue: defaults.string(forKey: Self.appearanceKey) ?? "") ?? .system
        language = InterfaceLanguage(rawValue: defaults.string(forKey: Self.languageKey) ?? "") ?? .english
        launchAtLogin = defaults.bool(forKey: Self.launchAtLoginKey)
        silentLaunch = defaults.bool(forKey: Self.silentLaunchKey)
        closeBehavior = AppCloseBehavior(rawValue: defaults.string(forKey: Self.closeBehaviorKey) ?? "") ?? .quit
        cliPath = defaults.string(forKey: Self.cliPathKey)
    }
}

/// UI copy only. Dataset paths, scientific names, and arbitrary engine results are opaque.
enum InterfaceText {
    private static let chinese: [String: String] = [
        "WORKFLOW": "工作流程", "Load Data": "导入数据", "Preprocess": "预处理", "PCA / Clusterings": "PCA / 聚类",
        "Version Management": "版本管理", "Inspect native GUI and independent CLI releases.": "查看原生 GUI 与独立 CLI 的版本及更新。",
        "Manage startup and window behavior.": "管理开机启动与关闭窗口行为。",
        "Startup & Window": "启动与窗口", "Launch at Login": "开机自启", "Silent Launch": "静默启动",
        "Close Behavior": "关闭行为", "Quit MANTiS": "退出 MANTiS", "Keep in Menu Bar": "保留在菜单栏",
        "Desktop GUI": "桌面客户端 (GUI)", "Command Line (CLI)": "命令行工具 (CLI)",
        "CLI installation": "CLI 安装与升级", "Install CLI…": "安装 CLI…", "Update CLI…": "升级 CLI…",
        "The CLI is a separate Python installation. This action uses an isolated environment and never replaces the GUI's private engine.": "CLI 是独立的 Python 安装；此操作使用隔离环境，不会替换 GUI 的私有计算引擎。",
        "Mantis.app · native interface": "Mantis.app · 原生图形界面",
        "Separately installed mantis-xray; not the private engine": "独立安装的 mantis-xray；不是 GUI 私有引擎",
        "Check & Install": "检查与安装", "Check for Updates": "检查更新",
        "Checking GitHub Releases…": "正在查询 GitHub Releases…", "Unavailable": "暂不可用",
        "Not checked": "待检查", "Not detected": "未检测到", "Detecting…": "检测中…",
        "Download verified DMG": "下载已校验 DMG", "View Release": "查看 Release",
        "Manual installation only: verify the checksum, then replace Mantis.app. No update is installed automatically.": "仅支持手动安装：校验下载文件后替换 Mantis.app；应用不会自动安装。",
        "The CLI is installed and updated separately; GUI updates replace only the app and its private engine.": "CLI 单独安装及更新；GUI 更新仅替换应用与私有计算引擎。",
        "Release Notes": "版本说明", "View all Releases in browser": "在浏览器查看所有 Releases",
        "Current Version": "当前版本", "Latest Version": "最新版本",
        "New GUI release found, but no verifiable checksum; open the Release manually.": "发现新 GUI 版本，但缺少可核验的校验值；请手动查看 Release。",
        "A new GUI release is available. Review its Release page and install a verified DMG manually.": "发现新 GUI 版本；请查看 Release 并手动安装通过校验的 DMG。",
        "GUI updates require a manual, verified DMG install. The CLI remains separate.": "GUI 更新需手动安装经过校验的 DMG；CLI 仍单独更新。",
        "Download verified DMG…": "下载并校验 DMG…", "Downloading and verifying DMG…": "正在下载并校验 DMG…",
        "Downloading and verifying update…": "正在下载并校验安装包…",
        "Release has no SHA-256 digest; verified download is unavailable.": "Release 缺少 SHA-256 校验值，无法提供校验下载。",
        "Destination already exists. Select a new filename; existing files are never replaced.": "目标文件已存在；请选择新文件名，不会覆盖现有文件。",
        "Verified DMG saved to: ": "已校验 DMG，保存至：", "Download failed: ": "下载失败：",
        "This local GUI is newer than the public Release; no downgrade is offered.": "当前本地 GUI 比公开 Release 更新；不会降级。",
        "The GUI is up to date.": "GUI 已是最新版本。", "Update check unavailable: ": "检查更新失败：",
        "Confirm Update": "确认更新", "Cancel": "取消", "Change Path…": "选择路径…",
        "Location:": "路径：", "Installed at: ": "安装位置：",
        "Automatic update only supports /Applications/Mantis.app. Please install Mantis.app into Applications or download the DMG manually.": "自动更新仅支持 /Applications/Mantis.app；请将 Mantis.app 安装到“应用程序”文件夹，或下载 DMG 手动安装。",
        "Current installation is missing the update helper; please install the new version manually.": "当前安装缺少更新组件，请手动安装新版。",
        "Install the app in Applications to enable login launch.": "将应用安装到“应用程序”后才能设置开机自启。",
        "Hide the window only when launched at login. Manual launches show it.": "仅在登录自启时隐藏窗口；手动启动仍显示窗口。",
        "Closing to the menu bar keeps this analysis session in memory. Quit MANTiS to end the session and stop its engine.": "保留在菜单栏时分析会话仍在内存中；完全退出 MANTiS 将结束会话并停止计算引擎。",
        "Open a stack, inspect its channels, or assemble individual images.": "导入数据栈、检查通道，或组合单帧图像。",
        "Inspect, align and normalize without hidden corrections.": "检查、配准与归一化；不进行隐式修正。",
        "Find significant components and classify spectral similarity.": "筛选显著组分并按谱图相似性分类。",
        "Map reference spectra and examine composition.": "映射参考谱图并检查组分分布。",
        "Extract non-negative spectra with explicit regularization.": "通过显式正则化提取非负谱图。",
        "Compare detected peaks with the original reference table.": "将检测到的峰与原始参考表比较。",
        "Fit absorption steps and Gaussian resonances.": "拟合吸收台阶与 Gaussian 共振峰。",
        "Reconstruct an energy channel from an explicit angular axis.": "基于显式角度轴重建能量通道。",
        "Independent native interface and private numerical engine.": "独立的原生界面与私有数值引擎。",
        "Spectral Maps": "谱图映射", "NNMA": "NNMA 分析", "Peak ID": "峰识别", "Fitting": "谱图拟合",
        "Tomography": "断层重建", "Settings": "设置", "Open Stack": "打开数据栈", "Open Stack…": "打开数据栈…",
        "Show import parameters": "显示导入参数",
        "Import Options": "导入设置", "Export Options": "导出设置",
        "File Mode": "文件模式", "Single Stack": "单一文件导入", "Merge Multiple Files": "合并多个文件导入",
        "File Info": "文件信息", "Format": "格式", "File Path": "文件路径",
        "Auto / All Supported": "自动识别 / 支持全部格式",
        "Select .hdr, .h5, or .npz file": "选择 .hdr、.h5 或 .npz 文件",
        "Parameters": "参数配置", "Region / Channel (Optional)": "区域 / 通道 (可选)",
        "e.g. [[0, 0]] or blank": "例如 [[0, 0]]，留空则默认",
        "Inspect File": "检查文件", "files selected": "个文件已选择",
        "Choose Files…": "选择文件…",
        "Photon energies in eV (comma or space separated)": "光子能量序列 (eV，逗号或空格分隔)",
        "Build Stack": "构建数据栈", "Processed Data Export": "处理数据导出",
        "Export Data…": "导出数据…", "Export Work Log": "导出工作日志", "Image Export": "图像导出", "DPI": "分辨率 (DPI)",
        "Export content": "导出内容", "Processed stack": "处理后数据", "Raw stack": "原始数据",
        "OD and normalization": "OD 与归一化", "Analysis results": "分析结果", "Current spectra": "当前谱图",
        "CSV exports current spectra only; data choices apply to NPZ/HDF5.": "CSV 仅导出当前谱图；数据选择适用于 NPZ/HDF5。",
        "Analysis results are session-wide; ROI mapping is a suggested filename, not an ROI-only dataset.": "分析结果属于整个会话；ROI 映射只是建议文件名，并非单个 ROI 专属数据。",
        "Export Image…": "导出图像…",
        "Exports complete command chain, parameters, and results.": "导出从数据导入到最终操作的完整命令链、参数配置及结果说明。",
        "Log Format": "日志格式", "Export Log…": "导出日志…", "Position": "位置",
        "Operations": "项操作", "operations": "项操作",
        "Crop Stack": "裁剪数据栈",
        "Spectral Analysis": "谱图分析",
        "Include": "包含数据组", "Overwrite": "覆盖现有文件", "Spectrum Name": "谱线名称",
        "Random Seed": "随机种子",
        "Remove First": "排除第一成分", "Sigma Split": "Sigma 拆分", "Bounds": "坐标范围",
        "Energy Range": "能量范围", "Mode": "模式", "Reference": "参考图像",
        "Upsample Factor": "上采样倍数", "Crop Overlap": "裁剪黑边", "Value": "数值",
        "Lee Sigma": "平滑阈值", "File Paths": "文件路径列表", "Energies": "能量点列表",
        "Algorithm": "算法", "Convention": "计算约定", "Threshold": "阈值",
        "Shifts": "位移列表", "Display Signal": "显示信号",
        "items": "项", "null": "无",
        "processed": "处理后数据", "raw": "原始数据", "normalization": "归一化",
        "analysis": "分析结果", "spectra": "谱图", "od": "光密度", "intensity": "强度",
        "Processing History": "处理历史",
        "Structured history of all operations applied to this dataset.": "应用于此数据集的完整结构化操作历史。",
        "Show Raw Parameters": "显示原始参数",
        "No operations recorded yet.": "尚未记录任何操作。",
        "Update View / ROI": "视图与选区更新",
        "No custom parameters": "无自定义参数",
        "Path": "文件路径", "Energy Frame": "能量帧", "Viewport": "视口",
        "Yes": "是", "No": "否",
        "Add ROI": "添加 ROI", "Too many ROIs": "ROI过多", "Clear Selected": "清除选中",
        "Original": "原始比例", "Fit Data": "最适应大小", "Box Zoom": "框选放大", "Reset Zoom": "重置缩放",
        "ROI": "选区", "ROIs": "多选区",
        "Photon energy (eV)": "光子能量 (eV)",
        "Mean": "平均值",
        "Export": "导出", "Export format": "导出格式", "Cancel & Reset": "取消并重置",
        "Engine connected": "计算引擎已连接", "Not connected": "未连接", "Engine unavailable": "计算引擎不可用",
        "Connect Engine": "连接计算引擎", "Input files are never overwritten": "不会覆盖输入文件",
        "SOURCE": "数据来源", "SHAPE": "数据维度", "SIGNAL": "信号类型", "No dataset loaded": "尚未载入数据",
        "Energy range": "能量范围", "X resolution / pixel": "横向分辨率/像素", "Y resolution / pixel": "纵向分辨率/像素",
        "ROI color": "ROI 颜色",
        "Intensity": "强度", "Optical density": "光密度", "Image workspace": "图像工作区",
        "Clusters": "聚类图", "Cluster distance (spectral SSE)": "聚类距离 (谱 SSE)",
        "Image": "图像", "Selection": "选择工具", "Pixel": "像素", "Rectangle": "矩形", "Lasso": "套索",
        "Clear ROI": "清除 ROI", "Energy": "能量", "Signal": "信号", "Projection angle": "投影角度",
        "Display Setting": "显示设置", "Scale": "比例", "Pixel proportions": "按像素比例", "Actual spatial scale": "按实际空间比例",
        "Visible region": "可见区域",
        "Physical units not available; showing pixel coordinates": "无可靠空间单位；仅显示像素坐标",
        "Use measured spatial coordinates for image proportions": "按实测空间坐标调整图像比例",
        "Zoom": "缩放", "Zoom in": "放大", "Zoom out": "缩小", "Fit": "适合窗口", "Double-click an image location to zoom into its source pixels.": "双击图像位置以源数据像素为中心放大。",
        "Display changes never modify scientific data.": "显示调整不修改科研数据。", "Preview sampling; export retains full data": "预览采样 · 导出完整数据",
        "Choose an input file in the Parameters panel → Open stack.": "在右侧“参数 → 打开数据栈”中选择输入文件。",
        "No source is loaded. Image and charts appear here after import.": "尚无数据；导入后在此显示图像和图表。",
        "Data import": "数据导入", "Choose a stack file below; build from multiple frames in the separate form.": "在下方选择数据栈文件；多帧图像请使用单独的构建表单。",
        "Choose stack file…": "选择数据栈文件…", "Select a file, not a folder; SDF uses the .hdr file.": "请选择文件而非文件夹；SDF 请选 .hdr。",
        "Enter a full path or choose a stack file above.": "输入完整路径，或点击上方按钮选择文件。",
        "Output": "输出", "Export the current session": "导出当前会话",
        "Image formats export the engine's current view; switch to that panel or use a numeric format": "图像格式导出引擎的当前视图；请切换到对应面板或选择数值格式",
        "Min": "最小值", "Max": "最大值", "Gamma": "Gamma", "Palette": "色图", "Reset": "重置",
        "Grayscale": "灰度", "Diverging": "发散", "Start with your measurements": "从测量数据开始",
        "Load a spectral stack to inspect images and spectra.\nNo demonstration data is loaded automatically.": "导入谱图数据栈以检查图像与谱图。\n不会自动载入演示数据。",
        "File inspection": "文件检查", "Numerical results & reference annotations": "数值结果与参考注释",
        "HDF5 · SDF · STK · TIFF · XRM · NPZ · plugin formats": "HDF5 · SDF · STK · TIFF · XRM · NPZ · 插件格式",
        "Input is already optical density (OD)": "输入已是光密度 (OD)",
        "Enable only for measured optical density; a filename containing specnorm is not proof of OD.": "仅当输入确为光密度时勾选；文件名含 specnorm 不代表已是 OD。",
        "Select the SDF .hdr file or an HDF5 stack.": "请选择 SDF .hdr 文件或 HDF5 数据栈。",
        "Opening does not normalize transmission. For raw intensity, use an I₀ file or another explicit normalization step.": "打开文件不会自动归一化透射强度；原始强度请用 I₀ 文件或其他显式归一化步骤。",
        "This declaration applies to the next file you open; it never changes the current stack.": "此声明只用于下次打开文件，不会改变当前数据栈。",
        "Hide parameters": "隐藏参数", "Show parameters": "显示参数",
        "Hide parameters panel": "隐藏右侧参数栏", "Show parameters panel": "显示右侧参数栏",
        "Spectra & diagnostics": "谱图解析", "Spectral analysis": "谱图解析", "Series": "谱线", "All spectra": "全部谱线",
        "Data": "数据", "Full image": "全图", "ROI mean": "ROI 平均值",
        "Selected pixel · signal at current energy": "所选像素 · 当前能量下的信号",
        "One source pixel at the selected photon energy.": "当前光子能量下单个源像素的信号。",
        "Selected spectrum · signal vs energy": "所选谱线 · 信号随能量变化",
        "Histogram covers every source pixel in the current view, not the sampled preview.": "统计当前视野全部源像素，而非抽样预览。",
        "Selected ROI pixels · intensity distribution": "选中 ROI 像素 · 信号分布",
        "Selected ROI pixels · signal distribution": "选中 ROI 像素 · 信号分布",
        "ROI histogram covers all source pixels selected by the ROI.": "直方图统计 ROI 内的全部源像素。",
        "Visible image pixels · intensity distribution": "可见像素 · 信号分布",
        "Visible image pixels · signal distribution": "可见像素 · 信号分布", "Pixels": "像素数",
        "Visible series: minimum, maximum and mean": "当前谱线：最小值、最大值和平均值",
        "No spectrum yet": "暂无谱图", "Open a stack or run an analysis to inspect its spectra.": "导入数据栈或运行分析后查看谱图。",
        "Signal (series units)": "信号（序列单位）", "Photon energy (eV) / diagnostic axis": "光子能量 (eV) / 诊断坐标",
        "Iteration": "迭代次数", "Component": "组分序号",
        "PARAMETERS": "参数", "Optional": "可选", "Choose file…": "选择文件…", "Automatic / omitted": "自动 / 不填写",
        "Pixel and energy indices start at 0. Crop/ROI upper bounds are exclusive. Unsupported engine methods stay disabled.": "像素与能量索引从 0 开始；裁剪/ROI 上界不包含在内。引擎不支持的操作保持禁用。",
        "Input is already optical density": "输入数据已是光密度", "Stack file": "数据栈文件",
        "Region/channel pairs [[0,0]]": "区域/通道组合 [[0,0]]", "Use drawn rectangle": "使用已绘制矩形",
        "Use all energies": "使用全部能量点", "Photon energies (eV)": "光子能量 (eV)",
        "Single-frame files (ordered)": "单帧文件（按顺序）",
        "Read an original stack or a 4D NPZ/HDF5 dataset. No duplicate averaging or implicit normalization.": "读取原始数据栈或 4D NPZ/HDF5；不合并重复能量点，也不自动归一化。",
        "List available file-plugin regions and channels before choosing a selection.": "选择前列出文件插件支持的区域和通道。",
        "Two-column energy / incident flux CSV or XAS. Transmission and I₀ must be positive.": "使用两列能量/入射光强 CSV 或 XAS 文件；透射强度及 I₀ 必须为正。",
        "Draw a rectangle in the image, then use its exclusive-upper-bound pixel coordinates.": "在图像上绘制矩形，使用像素坐标，上界不包含在内。",
        "Select the inclusive intensity limits for incident-flux pixels.": "选择入射光强像素的强度上下限（均包含）。",
        "Explicitly declare that values already represent optical density; this is not an automatic correction.": "显式声明输入值已为光密度；此操作不是自动修正。",
        "Fourier registration or explicit per-energy [dx,dy] shifts. Downstream analyses are invalidated.": "傅里叶配准或逐能量指定 [dx,dy] 位移；后续分析结果将失效。",
        "Pixel bounds and energy indices have exclusive upper limits. Original data remains recoverable with Reset.": "像素边界及能量索引上界不包含在内；重置可恢复原始数据。",
        "Explicit subtraction; invalid transmission is reported, never clipped.": "显式扣除暗信号；无效透射值会报错，不会被静默截断。",
        "Apply the engine's explicit despiking routine and record its parameters.": "运行引擎的去尖峰流程并记录参数。",
        "Remove one energy frame; invalidates derived analyses.": "删除一个能量帧；衍生分析结果将失效。",
        "Discard processing and derived analysis for this session. The input file is never modified.": "丢弃本次会话的处理与衍生分析；不会修改输入文件。",
        "Compute −log(mean(post intensity) / mean(pre intensity)). Range upper limits are exclusive.": "计算 −log(后沿平均强度 / 前沿平均强度)；区间上界不包含在内。",
        "Henke dose workflow. Use measured detector efficiency, composition, pixel dimensions and dwell time; result in Gray.": "Henke 剂量流程：需提供实测探测器效率、组成、像素尺寸与驻留时间；结果单位为 Gray。",
        "Use the original MANTiS PCA convention. Examine eigenimages and the scree spectrum before selecting significant components.": "沿用原版 MANTiS PCA 约定；选择显著组分前请检查特征图像与 scree 谱。",
        "k-means classification with explicit reproducible seed.": "k-means 分类，并显式指定可复现的随机种子。",
        "Extract key energies from the original PCA-based algorithm.": "使用原版基于 PCA 的算法提取关键能量。",
        "Load/remap reference spectra and inspect raw or PCA-fitted maps. Added references persist in this session.": "载入并重映射参考谱，检查原始或 PCA 拟合映射；新增参考谱保留在本次会话中。",
        "Remove the zero-based target reference and recalculate maps.": "按从 0 开始的索引删除目标参考谱，并重新计算映射。",
        "Move a target spectrum from one zero-based index to another.": "将目标谱从一个从 0 开始的索引移动到另一个索引。",
        "Assign target-map indices to red, green and blue. Display scaling does not alter map values.": "将目标映射索引分配给红、绿、蓝通道；显示缩放不修改映射值。",
        "Original non-negative approximation; negative input is rejected rather than silently clamped. Cluster/standard initialization requires matching component counts.": "原版非负近似；拒绝负值输入，不进行静默截断。聚类/标准谱初始化要求组分数匹配。",
        "Peak positions are compared with the original predefined reference labels and citations; they are not proof of chemical identity.": "将峰位与原预定义参考标签及文献比较；该匹配不能单独证实化学身份。",
        "Use an external spectrum or the selected ROI/pixel spectrum. Optional initial arrays must match the number of steps/peaks. No fabricated fit certainty.": "使用外部谱或选定 ROI/像素谱；可选初始数组须与台阶/峰数匹配，不虚构拟合确定性。",
        "Requires 4D input with an explicit theta axis. SIRT/TV use the supported original routines; FBP is explicitly selected. Numeric volumes are included in NPZ/HDF5 exports.": "需要具有显式 theta 轴的 4D 输入。SIRT/TV 使用受支持的原版流程；FBP 需显式选择。数值体数据包含于 NPZ/HDF5 导出。",
        "File order and energy order must match exactly. Use one energy per single-frame file.": "文件与能量点顺序必须一致；每个单帧文件对应一个能量点。",
        "Independent versions": "独立版本", "Native interface": "原生界面", "Numerical engine": "数值引擎",
        "Wire protocol": "通信协议", "Compatibility": "兼容性", "Private engine": "私有计算引擎",
        "Advertised capabilities": "引擎能力", "Scientific provenance": "科研数据溯源",
        "Unavailable until handshake succeeds": "连接成功后可用", "Reconnect (clears session)": "重新连接（清空会话）",
        "Appearance": "外观", "Language": "语言", "Light": "浅色", "Dark": "深色", "System": "跟随系统",
        "Operation failed": "操作失败", "Session reset after engine failure": "引擎失败，会话已重置",
        "Stopping engine and clearing session…": "正在停止引擎并清空会话…", "Cancelled — session cleared": "已取消 — 会话已清空",
        "Open stack": "打开数据栈", "Inspect file": "检查文件", "Build image stack": "构建图像栈",
        "Choose another file and open it in place of the current stack.": "选择其他文件并替换当前会话的数据栈。",
        "Calculate PCA": "计算 PCA", "Calculate clusters": "计算聚类", "Use pre-normalized data": "使用已归一化数据",
        "Fit spectrum": "拟合谱图", "Reconstruct volume": "重建体数据", "Identify peaks": "识别峰",
        "Calculate spectral maps": "计算谱图映射", "Calculate NNMA": "计算 NNMA",
        "Normalize from I₀ file": "使用 I₀ 文件归一化", "Normalize from rectangle": "使用矩形区域归一化",
        "Normalize from histogram": "使用直方图归一化", "Align images": "配准图像", "Crop stack": "裁剪数据栈",
        "Subtract dark signal": "扣除暗信号", "Despike": "去除尖峰", "Remove image": "删除能量帧",
        "Restore original stack": "恢复原始数据栈", "Spectral ROI map": "谱图 ROI 映射",
        "Absorbed dose": "吸收剂量", "Find key energies": "查找关键能量",
        "Remove reference": "删除参考谱", "Reorder reference": "调整参考谱顺序", "Composite RGB": "合成 RGB",
        "Incident-flux spectrum": "入射光强谱", "x₀, y₀, x₁, y₁": "x₀, y₀, x₁, y₁",
        "Minimum intensity": "最小强度", "Maximum intensity": "最大强度",
        "Reference energy index": "参考能量索引", "Subpixel upsample factor": "亚像素上采样倍数",
        "Manual shifts [[dx,dy],…]": "手动位移 [[dx,dy],…]", "Crop aligned overlap": "裁剪配准后的重叠区",
        "First, last exclusive energy index": "起始、终止能量索引（不含终止）", "Dark signal": "暗信号",
        "Sigma threshold": "Sigma 阈值", "Energy index": "能量索引",
        "Pre-edge first, last exclusive": "前沿起始、终止索引（不含终止）",
        "Post-edge first, last exclusive": "后沿起始、终止索引（不含终止）",
        "Chemical composition": "化学组成", "Detector efficiency (fraction 0–1)": "探测器效率（0–1）",
        "Pixel width (µm)": "像素宽度 (µm)", "Pixel height (µm)": "像素高度 (µm)",
        "Dwell time (ms)": "驻留时间 (ms)", "Significant components (optional)": "显著组分数（可选）",
        "Number of clusters": "聚类数", "Significant components": "显著组分数",
        "Reduce thickness effects": "减小厚度效应", "Divide clusters with large sigma": "拆分高方差聚类",
        "Random seed": "随机种子", "Detection threshold": "检测阈值", "Reference spectra": "参考谱图",
        "Add cluster spectra": "添加聚类谱", "Add a flat spectrum": "添加平坦谱",
        "Fit references with PCA": "使用 PCA 拟合参考谱", "Reference index": "参考谱索引",
        "From, to indices": "起始、目标索引", "Red, green, blue map indices": "红、绿、蓝映射索引",
        "Components": "组分数", "Maximum iterations": "最大迭代次数", "Initialization": "初始化方式",
        "Standard spectra": "标准谱", "Sparseness λ": "稀疏度 λ",
        "Cluster similarity λ": "聚类相似度 λ", "Smoothness λ": "平滑度 λ",
        "Spectrum file (optional)": "谱图文件（可选）", "Absorption steps": "吸收台阶数",
        "Gaussian peaks": "Gaussian 峰数", "Initial baseline": "初始基线",
        "Step [amplitude, center, width] triples": "台阶 [振幅, 中心, 宽度] 三元组",
        "Peak amplitudes": "峰振幅", "Peak centers (eV)": "峰中心 (eV)",
        "Peak widths (eV)": "峰宽 (eV)", "Reconstruction algorithm": "重建算法",
        "Iterations": "迭代次数", "TV regularization β": "TV 正则化 β",
        "Volume slice index (optional)": "体数据切片索引（可选）",
        "The GUI launches only its private Contents/Resources/engine/mantis-engine. It never invokes a user-installed MANTiS CLI.": "GUI 仅启动应用包内的私有数值引擎，不调用用户安装的 MANTiS CLI。",
        "Development override: MANTIS_ENGINE_PATH must be an explicit executable absolute path. Cancellation terminates and reaps the process, clears this session and requires a new connection.": "开发覆盖：MANTIS_ENGINE_PATH 必须是可执行文件的绝对路径。取消操作将终止并回收进程、清空当前会话，之后需要重新连接。",
        "Processing parameters and deterministic seeds are kept in engine history. Display contrast is not processing. NPZ and HDF5 exports retain numerical analysis and original/processed data; CSV and graphics export displayed results. Peak annotations are references, not chemical identification certainty.": "引擎历史记录处理参数与确定性随机种子。显示设置不属于数据处理。NPZ 和 HDF5 导出保留原始/处理数据与数值分析；CSV 和图形导出展示结果。峰标注只是参考，不能单独确证化学身份。"
    ]
    static func value(_ english: String, language: InterfaceLanguage) -> String {
        language == .simplifiedChinese ? chinese[english] ?? english : english
    }
    static func status(_ text: String, language: InterfaceLanguage) -> String {
        guard language == .simplifiedChinese else { return text }
        if text.hasPrefix("Completed ") { return "已完成 " + text.dropFirst("Completed ".count) }
        if text.hasPrefix("Running ") { return "正在运行 " + text.dropFirst("Running ".count) }
        return value(text, language: language)
    }
}
