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
                Button(InterfaceText.value("Open Stack…", language: preferences.language)) { model.openStack() }.keyboardShortcut("o").disabled(model.busy || !model.supports("open"))
                Button(preferences.language == .simplifiedChinese ? "导出结果…" : "Export Results…") { model.export() }.keyboardShortcut("s", modifiers: [.command, .shift]).disabled(!model.canExport)
            }
            CommandMenu(preferences.language == .simplifiedChinese ? "分析" : "Analysis") {
                ForEach(WorkflowSection.allCases) { section in Button(InterfaceText.value(section.rawValue, language: preferences.language)) { model.section = section } }
                Divider()
                Button(preferences.language == .simplifiedChinese ? "取消并重置会话" : "Cancel & Reset Session", role: .destructive) { model.cancel() }.disabled(!model.busy)
            }
        }
        MenuBarExtra("MANTiS", systemImage: "waveform.path.ecg.rectangle") {
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
                model.run("open", ["path": .string(path), "pre_normalized": .bool(CommandLine.arguments.contains("--smoke-pre-normalized"))])
                await model.waitUntilIdle()
                if model.snapshot?.normalized == true {
                    model.section = .pca; model.run("pca"); await model.waitUntilIdle()
                }
                if let destination = argument("--smoke-export"), model.snapshot != nil, model.error == nil {
                    model.run("export", ["path": .string(destination), "format": .string("npz"), "overwrite": .bool(false)])
                    await model.waitUntilIdle()
                }
            }
        }
        try? await Task.sleep(for: .milliseconds(300))
        let window = NSApp.windows.first { $0.isVisible && $0.contentView != nil }
        var record: [String: Any] = ["window_visible": window != nil, "content_width": window?.contentView?.bounds.width ?? 0, "content_height": window?.contentView?.bounds.height ?? 0, "connected": model.connected, "status": model.status, "section": model.section.rawValue, "image_count": model.availableImages.count, "pca_ready": model.snapshot?.pca_ready ?? false, "language": preferences.language.rawValue, "appearance": preferences.appearance.rawValue]
        if let snapshot = model.snapshot { record["shape"] = snapshot.shape; record["energy_count"] = snapshot.energies.count; record["normalized"] = snapshot.normalized }
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
        DispatchQueue.main.async { NSApp.terminate(nil) }
    }
}