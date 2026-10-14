import AppKit
import SwiftUI
import MantisCore

@MainActor
final class ApplicationDelegate: NSObject, NSApplicationDelegate {
    var model: WorkspaceModel?
    private var terminating = false
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminating, let model else { return .terminateNow }
        terminating = true
        Task { await model.close(); DispatchQueue.main.async { sender.terminate(nil) } }
        // Avoid a nested AppKit modal loop starving the MainActor cleanup task.
        return .terminateCancel
    }
}

@main
struct MantisApp: App {
    @NSApplicationDelegateAdaptor(ApplicationDelegate.self) private var delegate
    @StateObject private var model = WorkspaceModel()
    var body: some Scene {
        Window("MANTiS — Spectromicroscopy", id: "workspace") {
            WorkspaceView(model: model)
                .task {
                    delegate.model = model
                    if let report = argument("--smoke-report") { await smoke(report: report) }
                    else { model.connect() }
                }
        }
        .defaultSize(width: 1320, height: 900)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Stack…") { model.openStack() }.keyboardShortcut("o").disabled(model.busy || !model.supports("open"))
                Button("Export Results…") { model.export() }.keyboardShortcut("s", modifiers: [.command, .shift]).disabled(!model.canExport)
            }
            CommandMenu("Analysis") {
                ForEach(WorkflowSection.allCases) { section in Button(section.rawValue) { model.section = section } }
                Divider()
                Button("Cancel & Reset Session", role: .destructive) { model.cancel() }.disabled(!model.busy)
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
        var record: [String: Any] = ["window_visible": window != nil, "content_width": window?.contentView?.bounds.width ?? 0, "content_height": window?.contentView?.bounds.height ?? 0, "connected": model.connected, "status": model.status, "image_count": model.availableImages.count, "pca_ready": model.snapshot?.pca_ready ?? false]
        if let error = model.error { record["error"] = error }
        if let source = model.snapshot?.source { record["source"] = source }
        do { try JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: report), options: .atomic) }
        catch { fputs("Cannot write smoke report: \(error)\n", stderr) }
        DispatchQueue.main.async { NSApp.terminate(nil) }
    }
}