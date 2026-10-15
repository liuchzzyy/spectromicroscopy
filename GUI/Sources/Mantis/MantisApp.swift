import AppKit
import SwiftUI
import MantisCore

@MainActor
final class ApplicationDelegate: NSObject, NSApplicationDelegate {
    var model: WorkspaceModel?
    var preferences: InterfacePreferences?
    private var terminating = false
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        if let preferences, StartupSettings.shouldStartHidden(arguments: CommandLine.arguments, preferences: preferences) {
            // macOS 14 lacks SwiftUI defaultLaunchBehavior. Keep the process and
            // menu extra alive, but order out the initial window after it appears.
            DispatchQueue.main.async { for window in NSApp.windows where window.title == "MANTiS — Spectromicroscopy" { window.orderOut(nil) } }
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        guard let preferences else { return true }
        return StartupSettings.shouldQuitAfterLastWindow(preferences: preferences)
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag, let window = sender.windows.first(where: { $0.title == "MANTiS — Spectromicroscopy" }) {
            window.makeKeyAndOrderFront(nil)
        }
        return true
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminating, let model else { return .terminateNow }
        terminating = true
        Task { await model.close(); DispatchQueue.main.async { sender.reply(toApplicationShouldTerminate: true) } }
        return .terminateLater
    }
}

enum MenuBarArtwork {
    static func load(from url: URL, size: CGFloat = 18) -> NSImage? {
        guard let image = NSImage(contentsOf: url) else { return nil }
        image.size = NSSize(width: size, height: size)
        image.isTemplate = false
        return image
    }
    static func bundled() -> NSImage? {
        guard let url = Bundle.main.resourceURL?.appendingPathComponent("MantisMenuIcon.png") else { return nil }
        return load(from: url)
    }
}

@main
struct MantisApp: App {
    @NSApplicationDelegateAdaptor(ApplicationDelegate.self) private var delegate
    @StateObject private var model = WorkspaceModel()
    @StateObject private var preferences: InterfacePreferences
    init() {
        // Opt-in smoke runs must not change the user's persisted interface choices.
        let defaults = CommandLine.arguments.contains("--smoke-report")
            ? UserDefaults(suiteName: "org.mantis.smoke.\(ProcessInfo.processInfo.processIdentifier)")! : .standard
        _preferences = StateObject(wrappedValue: InterfacePreferences(defaults: defaults))
    }
    var body: some Scene {
        Window("MANTiS — Spectromicroscopy", id: "workspace") {
            WorkspaceView(model: model)
                .environmentObject(preferences)
                .preferredColorScheme(preferences.appearance.colorScheme)
                .task {
                    delegate.model = model
                    delegate.preferences = preferences
                    if let report = argument("--smoke-report") { await smoke(report: report) }
                    else { model.connect() }
                }
        }
        .defaultSize(width: 1320, height: 900)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button(InterfaceText.value("Show import parameters", language: preferences.language)) { model.section = .load }.keyboardShortcut("o")
                Button(preferences.language == .simplifiedChinese ? "导出结果…" : "Export Results…") { model.export() }.keyboardShortcut("s", modifiers: [.command, .shift]).disabled(!model.canExport)
            }
            CommandMenu(preferences.language == .simplifiedChinese ? "分析" : "Analysis") {
                ForEach(WorkflowSection.allCases) { section in Button(InterfaceText.value(section.rawValue, language: preferences.language)) { model.section = section } }
                Divider()
                Button(preferences.language == .simplifiedChinese ? "取消并重置会话" : "Cancel & Reset Session", role: .destructive) { model.cancel() }.disabled(!model.busy)
            }
        }
        MenuBarExtra {
            Button(preferences.language == .simplifiedChinese ? "打开 MANTiS" : "Open MANTiS") {
                if let window = NSApp.windows.first(where: { $0.title == "MANTiS — Spectromicroscopy" }) {
                    window.makeKeyAndOrderFront(nil)
                }
                NSApp.activate(ignoringOtherApps: true)
            }
            Divider()
            Button(preferences.language == .simplifiedChinese ? "退出 MANTiS（清空会话）" : "Quit MANTiS (end session)") {
                NSApp.terminate(nil)
            }
        } label: {
            if let icon = MenuBarArtwork.bundled() {
                Image(nsImage: icon)
                    .renderingMode(.original)
                    .accessibilityLabel("MANTiS")
            } else {
                Image(systemName: "waveform.path.ecg")
                    .accessibilityLabel("MANTiS")
            }
        }
    }
    private func argument(_ flag: String) -> String? {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: flag), args.indices.contains(i + 1) else { return nil }
        return args[i + 1]
    }
    // Explicit opt-in launch harness: runs the real window and private engine, never demo data.
    private func smoke(report: String) async {
        if let raw = argument("--smoke-language"), let language = InterfaceLanguage(rawValue: raw) {
            preferences.language = language
        }
        if let raw = argument("--smoke-appearance"), let appearance = InterfaceAppearance(rawValue: raw) {
            preferences.appearance = appearance
        }
        if let raw = argument("--smoke-section") {
            if let section = WorkflowSection.allCases.first(where: { $0.rawValue == raw }) { model.section = section }
            model.connect(); await model.waitUntilIdle()
        }
        if let path = argument("--smoke-open") {
            model.connect(); await model.waitUntilIdle()
            if model.connected {
                model.openAsOpticalDensity = CommandLine.arguments.contains("--smoke-pre-normalized")
                model.openStack(at: URL(fileURLWithPath: path))
                await model.waitUntilIdle()
                if let zoom = argument("--smoke-zoom").flatMap(Int.init), model.snapshot != nil, model.error == nil {
                    model.zoom(to: zoom)
                    await model.waitUntilIdle()
                }
                if CommandLine.arguments.contains("--smoke-physical"), model.snapshot?.spatial?.unit != nil {
                    model.spatialDisplay = "physical"
                }
                if let roisArg = argument("--smoke-rois") {
                    for roiStr in roisArg.split(separator: ";") {
                        let parts = roiStr.split(separator: ",").compactMap { Int($0) }
                        if parts.count == 4 {
                            await model.waitUntilIdle()
                            model.addROI(bounds: parts)
                            await model.waitUntilIdle()
                        }
                    }
                }
                if CommandLine.arguments.contains("--smoke-clear-rois"), model.snapshot != nil, model.error == nil {
                    model.clearROIs()
                    await model.waitUntilIdle()
                }
                if let series = argument("--smoke-select-series"), model.snapshot != nil, model.error == nil {
                    model.selectSeries(named: series)
                    await model.waitUntilIdle()
                }
                if model.snapshot?.normalized == true && !CommandLine.arguments.contains("--smoke-skip-pca") {
                    model.section = .pca; model.run("pca"); await model.waitUntilIdle()
                }
                if let destination = argument("--smoke-export"), model.snapshot != nil, model.error == nil {
                    model.run("export", ["path": .string(destination), "format": .string("npz"), "overwrite": .bool(false)])
                    await model.waitUntilIdle()
                }
            }
        }
        if let points = argument("--smoke-scroll").flatMap(Double.init),
           let window = NSApp.windows.filter({ $0.isVisible && $0.contentView != nil })
                .max(by: { ($0.contentView?.bounds.width ?? 0) < ($1.contentView?.bounds.width ?? 0) }),
           let root = window.contentView {
            func scrollViews(in view: NSView) -> [NSScrollView] {
                (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap(scrollViews)
            }
            if let target = scrollViews(in: root).first(where: { $0.frame.width > 600 }) {
                target.contentView.scroll(to: NSPoint(x: 0, y: max(0, points)))
                target.reflectScrolledClipView(target.contentView)
            }
        }
        try? await Task.sleep(for: .milliseconds(300))
        let window = NSApp.windows.filter { $0.isVisible && $0.contentView != nil }
            .max { ($0.contentView?.bounds.width ?? 0) * ($0.contentView?.bounds.height ?? 0) <
                   ($1.contentView?.bounds.width ?? 0) * ($1.contentView?.bounds.height ?? 0) }
        var record: [String: Any] = ["window_visible": window != nil, "content_width": window?.contentView?.bounds.width ?? 0, "content_height": window?.contentView?.bounds.height ?? 0, "connected": model.connected, "status": model.status, "section": model.section.rawValue, "image_count": model.availableImages.count, "pca_ready": model.snapshot?.pca_ready ?? false, "language": preferences.language.rawValue, "appearance": preferences.appearance.rawValue]
        if let snapshot = model.snapshot { record["shape"] = snapshot.shape; record["energy_count"] = snapshot.energies.count; record["normalized"] = snapshot.normalized; record["spatial_unit"] = snapshot.spatial?.unit ?? NSNull(); record["energy_first"] = snapshot.energies.first ?? 0; record["energy_last"] = snapshot.energies.last ?? 0 }
        if let image = model.image { record["image_width"] = image.width; record["image_height"] = image.height; record["visible_width"] = image.visibleWidth; record["visible_height"] = image.visibleHeight; record["visible_origin_x"] = image.x0; record["visible_origin_y"] = image.y0; record["histogram_count"] = image.histogram_counts?.reduce(0, +) ?? 0; record["roi_histogram_count"] = image.roi_histogram_counts?.reduce(0, +) ?? 0 }
        record["roi_count"] = model.rois.count
        record["active_roi_label"] = model.activeROILabel ?? NSNull()
        record["selected_series"] = model.selectedSeriesName
        record["signal_option"] = model.selectedSignalOptionID
        record["signal_options"] = model.signalOptions.map(\.id)
        record["spectrum_names"] = model.displayedSpectra.map(\.name)
        record["zoom_level"] = model.zoomLevel
        record["menu_icon_loaded"] = MenuBarArtwork.bundled() != nil
        record["spatial_display"] = model.spatialDisplay
        if let error = model.error { record["error"] = error }
        if let source = model.snapshot?.source { record["source"] = source }
        if let output = argument("--smoke-screenshot"), let window,
           let view = window.contentView,
           let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: bitmap)
            if let png = bitmap.representation(using: .png, properties: [:]) {
                do { try png.write(to: URL(fileURLWithPath: output), options: .atomic); record["screenshot"] = output }
                catch { record["screenshot_error"] = error.localizedDescription }
            }
        }
        do { try JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: report), options: .atomic) }
        catch { fputs("Cannot write smoke report: \(error)\n", stderr) }
        if !CommandLine.arguments.contains("--smoke-stay-open") {
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
}