import SwiftUI
import AppKit
import MantisCore

struct WorkspaceView: View {
    @ObservedObject var model: WorkspaceModel
    @EnvironmentObject private var preferences: InterfacePreferences
    private func tr(_ key: String) -> String { InterfaceText.value(key, language: preferences.language) }
    private var workspaceLayout: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 228)
            Divider()
            detail.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 1080, minHeight: 720)
        .tint(Theme.accent)
    }
    var body: some View {
        workspaceLayout
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { model.openStack() } label: { Label(tr("Open Stack"), systemImage: "folder") }.disabled(model.busy || !model.supports("open"))
                Picker(tr("Export format"), selection: $model.exportFormat) { ForEach(["npz", "hdf5", "csv", "png", "pdf", "svg"], id: \.self) { Text($0.uppercased()).tag($0) } }.frame(width: 90)
                Button { model.export() } label: { Label(tr("Export"), systemImage: "square.and.arrow.up") }.disabled(!model.canExport)
                    .help(model.showsEngineCurrentView ? "Export the current session" : "Image formats export the engine's current view; switch to that panel or use a numeric format")
                if model.busy { Button(tr("Cancel & Reset"), role: .destructive) { model.cancel() } }
            }
        }
    }
    var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            BrandMark().padding(.horizontal, Theme.sidebarInset).padding(.top, 22).padding(.bottom, 18)
            Divider().padding(.horizontal, Theme.sidebarInset).padding(.bottom, 10)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text(tr("WORKFLOW"))
                        .font(.caption2.weight(.semibold)).tracking(1.2).foregroundStyle(.secondary)
                        .padding(.horizontal, Theme.sidebarInset).padding(.bottom, 12)
                    ForEach(WorkflowSection.allCases) { section in
                        Button { model.section = section } label: {
                            SidebarRow(symbol: section.symbol, title: tr(section.rawValue), selected: model.section == section)
                        }.buttonStyle(.plain).padding(.horizontal, 10).padding(.bottom, 3)
                    }
                }.padding(.top, 5)
            }
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: Theme.sidebarIconSpacing) {
                    Image(systemName: model.connected ? "checkmark.circle.fill" : "circle.dotted")
                        .frame(width: Theme.sidebarIconWidth, alignment: .center)
                    Text(tr(model.connected ? "Engine connected" : "Not connected"))
                }.foregroundStyle(model.connected ? Color.green : Color.secondary)
                HStack(spacing: 8) {
                    Menu {
                        ForEach(InterfaceLanguage.allCases) { language in
                            Button { preferences.language = language } label: {
                                if preferences.language == language { Label(language.label, systemImage: "checkmark") }
                                else { Text(language.label) }
                            }
                        }
                    } label: {
                        Label(preferences.language.label, systemImage: "globe")
                            .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .menuStyle(.borderlessButton)
                    .help(tr("Language"))
                    HStack(spacing: 1) {
                        ForEach(InterfaceAppearance.allCases) { appearance in
                            Button { preferences.appearance = appearance } label: {
                                Image(systemName: appearance.symbol)
                                    .frame(width: 25, height: 24)
                                    .background(preferences.appearance == appearance ? Theme.surface(effectiveScheme) : Color.clear,
                                                in: RoundedRectangle(cornerRadius: 6))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(tr(appearance.rawValue.capitalized))
                            .help(tr(appearance.rawValue.capitalized))
                        }
                    }
                    .padding(3).background(Theme.page(effectiveScheme), in: RoundedRectangle(cornerRadius: 8))
                }
            }.font(.caption).padding(.horizontal, Theme.sidebarInset).padding(.vertical, 14)
        }.sidebarBackground()
    }
    @Environment(\.colorScheme) private var effectiveScheme
    var detail: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(tr(model.section.rawValue)).font(.system(size: 28, weight: .bold, design: .rounded))
                    Text(tr(model.section.subtitle)).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                if model.busy { ProgressView().controlSize(.small).padding(.top, 8) }
            }.padding(.horizontal, Theme.contentInset).padding(.vertical, 18)
            Divider()
            if model.section == .settings { settings }
            else if model.section == .versions { VersionManagementView(model: model) }
            else {
                HSplitView {
                    ScrollView {
                        VStack(spacing: Theme.sectionSpacing) {
                            sourceSummary
                            imageCard
                            SpectraChart(spectra: model.shown?.spectra ?? [], selectedEnergy: selectedEnergy, selectEnergy: model.selectEnergy)
                                .frame(height: 285).surface()
                            if let inspection = model.inspection, model.section == .load {
                                GroupBox(tr("File inspection")) { Text(inspection).font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                            }
                            resultDetails
                        }.padding(Theme.contentInset)
                    }.frame(minWidth: 490)
                    ParameterInspector(model: model).frame(minWidth: 280, idealWidth: 310, maxWidth: 360)
                }
            }
            Divider()
            statusBar
        }.pageBackground()
        .onChange(of: model.section) { _, _ in model.selectedImage = 0 }
    }
    private var selectedEnergy: Double? {
        guard let s = model.snapshot, s.energies.indices.contains(model.energyIndex) else { return nil }
        return s.energies[model.energyIndex]
    }
    private var sourceSummary: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "square.stack.3d.up.fill")
                    .font(.title3).foregroundStyle(Theme.accent)
                    .frame(width: 38, height: 38)
                    .background(Theme.accent.opacity(0.11), in: RoundedRectangle(cornerRadius: 11))
                VStack(alignment: .leading, spacing: 3) {
                    Text(tr("SOURCE")).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    Text(model.snapshot.map { URL(fileURLWithPath: $0.source).lastPathComponent } ?? tr("No dataset loaded"))
                        .font(.headline).lineLimit(1).help(model.snapshot?.source ?? "")
                }
                Spacer(minLength: 8)
                if model.snapshot != nil {
                    Label(model.snapshot?.normalized == true ? "OD" : tr("Intensity"), systemImage: "checkmark.circle.fill")
                        .font(.caption.weight(.medium)).foregroundStyle(Theme.accent)
                        .padding(.horizontal, 9).padding(.vertical, 5)
                        .background(Theme.accent.opacity(0.1), in: Capsule())
                }
            }
            Divider()
            HStack(spacing: 20) {
                summaryValue("SHAPE", model.snapshot?.shape.map(String.init).joined(separator: " × ") ?? "—")
                Divider().frame(height: 31)
                summaryValue("SIGNAL", model.snapshot.map { tr($0.normalized ? "Optical density" : "Intensity") } ?? "—")
                Divider().frame(height: 31)
                summaryValue("Energy", model.snapshot?.energies.count.description ?? "—")
                Spacer(minLength: 0)
            }
        }.padding(Theme.cardInset).surface()
    }
    private func summaryValue(_ title: String, _ value: String) -> some View { VStack(alignment: .leading, spacing: 4) { Text(tr(title)).font(.caption2.weight(.semibold)).foregroundStyle(.secondary); Text(value).font(.system(.callout, design: .monospaced)).lineLimit(1) } }
    private var imageCard: some View {
        VStack(spacing: 12) {
            HStack {
                Label(tr("Image workspace"), systemImage: "viewfinder").font(.headline)
                Spacer()
                if !model.availableImages.isEmpty {
                    Picker(tr("Image"), selection: $model.selectedImage) { ForEach(Array(model.availableImages.enumerated()), id: \.offset) { index, image in Text(image.title).tag(index) } }.labelsHidden().frame(maxWidth: 210)
                }
            }
            if let image = model.image {
                ScientificCanvas(model: model, image: image).frame(height: 320)
                HStack {
                    Picker(tr("Selection"), selection: $model.roiMode) { ForEach(["Pixel", "Rectangle", "Lasso"], id: \.self) { Text(tr($0)).tag($0) } }.pickerStyle(.segmented).frame(maxWidth: 260)
                    Button(tr("Clear ROI")) { model.rectangle = nil; model.polygon = nil; model.updateView() }
                    Spacer()
                    if let s = model.snapshot { Text("x \(s.selected_x) · y \(s.selected_y)").monospacedDigit().foregroundStyle(.secondary) }
                }.disabled(model.busy)
                HStack {
                    Text(tr("Energy")).font(.caption)
                    Slider(value: Binding(get: { Double(model.energyIndex) }, set: { model.energyIndex = Int($0) }), in: 0...Double(max(1, (model.snapshot?.energies.count ?? 1)-1)), step: 1, onEditingChanged: { editing in if !editing { model.updateView() } })
                    Text(selectedEnergy.map { String(format: "%.3f eV", $0) } ?? "—").font(.system(.caption, design: .monospaced)).frame(width: 105, alignment: .trailing)
                }.disabled(model.busy || (model.snapshot?.energies.count ?? 0) < 2)
                HStack {
                    Picker(tr("Signal"), selection: $model.display) { Text(tr("Intensity")).tag("intensity"); Text(tr("Optical density")).tag("od") }.frame(maxWidth: 220).onChange(of: model.display) { _, _ in model.updateView() }
                    Spacer()
                    Text(preferences.language == .simplifiedChinese ? "显示 \(image.width) × \(image.height)；导出保留完整数据" : "Display \(image.width) × \(image.height); export retains full data").font(.caption2).foregroundStyle(.secondary)
                }.disabled(model.busy)
                if let theta = model.snapshot?.theta, !theta.isEmpty {
                    Picker(tr("Projection angle"), selection: $model.thetaIndex) { ForEach(theta.indices, id: \.self) { Text("\(theta[$0], specifier: "%.2f")°").tag($0) } }.onChange(of: model.thetaIndex) { _, _ in model.updateView() }.disabled(model.busy)
                }
                DisclosureGroup(tr("Display contrast — does not change scientific data")) {
                    VStack {
                        HStack { Text(tr("Min")).frame(width: 45); Slider(value: $model.contrastLow, in: 0...0.99); Text(tr("Max")).frame(width: 45); Slider(value: $model.contrastHigh, in: 0.01...1) }
                        HStack { Text(tr("Gamma")).frame(width: 45); Slider(value: $model.gamma, in: 0.1...4); Picker(tr("Palette"), selection: $model.colorMap) { ForEach(["Viridis", "Grayscale", "Diverging"], id: \.self) { Text(tr($0)).tag($0) } }; Button(tr("Reset")) { model.contrastLow = 0; model.contrastHigh = 1; model.gamma = 1 } }
                    }.font(.caption).padding(.top, 8)
                }.font(.caption)
            } else {
                VStack(spacing: 16) {
                    VStack(spacing: 14) {
                        Image(systemName: "square.stack.3d.up").font(.system(size: 44, weight: .ultraLight)).foregroundStyle(Theme.accent)
                        Text(tr("Start with your measurements")).font(.title3.weight(.medium))
                        Text(tr("Load a spectral stack to inspect images and spectra.\nNo demonstration data is loaded automatically."))
                            .multilineTextAlignment(.center).foregroundStyle(.secondary)
                        Button(tr("Open Stack…")) { model.openStack() }.buttonStyle(.borderedProminent).tint(Theme.accent)
                            .disabled(!model.supports("open") || model.busy)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 28)
                    .dropArea()

                    Text(tr("HDF5 · SDF · STK · TIFF · XRM · NPZ · plugin formats")).font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity)
            }
        }.padding(16).surface()
    }
    @ViewBuilder private var resultDetails: some View {
        if let s = model.shown {
            if !s.metrics.isEmpty {
                DisclosureGroup(tr("Numerical results & reference annotations")) {
                    VStack(alignment: .leading, spacing: 10) { ForEach(s.metrics.keys.sorted(), id: \.self) { key in VStack(alignment: .leading, spacing: 3) { Text(key).font(.caption.bold()); Text(s.metrics[key]?.string ?? s.metrics[key]?.description ?? "").font(.system(.caption, design: .monospaced)).textSelection(.enabled) }.frame(maxWidth: .infinity, alignment: .leading) } }.padding(.top, 12)
                }.padding(16).surface()
            }
            DisclosureGroup(preferences.language == .simplifiedChinese ? "处理历史 · \(s.history.count) 次操作" : "Processing history · \(s.history.count) operations") {
                VStack(alignment: .leading, spacing: 10) { ForEach(Array(s.history.enumerated()), id: \.offset) { i, entry in VStack(alignment: .leading, spacing: 2) { Text("\(i+1). \(entry.method)").font(.caption.bold()); Text(JSONValue.object(entry.params).description).font(.system(.caption2, design: .monospaced)).textSelection(.enabled) } } }.frame(maxWidth: .infinity, alignment: .leading).padding(.top, 12)
            }.padding(16).surface()
        }
    }
    private var statusBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let error = model.error { HStack(alignment: .top) { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange); Text(error).textSelection(.enabled); Spacer(); Button { model.error = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain) }.font(.caption).padding(.bottom, 3) }
            HStack { Circle().fill(model.busy ? .orange : model.connected ? .green : .secondary).frame(width: 6,height: 6); Text(InterfaceText.status(model.status, language: preferences.language)).font(.caption); Spacer(); if !model.connected && !model.busy { Button(tr("Connect Engine")) { model.connect() }.controlSize(.small).disabled(model.preview) }; Text(tr("Input files are never overwritten")).font(.caption2).foregroundStyle(.secondary) }
        }.padding(.horizontal, Theme.contentInset).padding(.vertical, 10).statusBarBackground()
    }
    private var settings: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text(tr("Startup & Window")).font(.headline).padding(.bottom, 12)
                Divider()
                HStack {
                    Label(tr("Launch at Login"), systemImage: "power")
                    Spacer()
                    Toggle(tr("Launch at Login"), isOn: Binding(
                        get: { StartupSettings.systemEnabled },
                        set: { enabled in
                            do { try StartupSettings.setLaunchAtLogin(enabled, preferences: preferences) }
                            catch { model.error = preferences.language == .simplifiedChinese ? "登录项设置失败：\(error.localizedDescription)" : "Could not change login item: \(error.localizedDescription)" }
                        }
                    )).labelsHidden().toggleStyle(.switch)
                        .disabled(!Bundle.main.bundleURL.path.hasPrefix("/Applications/"))
                        .help(tr("Install the app in Applications to enable login launch."))
                }.padding(.vertical, 14)
                Divider()
                HStack {
                    Label(tr("Silent Launch"), systemImage: "moon.zzz")
                    Spacer()
                    Toggle(tr("Silent Launch"), isOn: $preferences.silentLaunch)
                        .labelsHidden().toggleStyle(.switch)
                        .help(tr("Hide the window only when launched at login. Manual launches show it."))
                }.padding(.vertical, 14)
                Divider()
                HStack {
                    Label(tr("Close Behavior"), systemImage: "macwindow.on.rectangle")
                    Spacer()
                    Picker(tr("Close Behavior"), selection: $preferences.closeBehavior) {
                        Text(tr("Quit MANTiS")).tag(AppCloseBehavior.quit)
                        Text(tr("Keep in Menu Bar")).tag(AppCloseBehavior.menuBar)
                    }.labelsHidden().frame(width: 190)
                }.padding(.vertical, 14)
                Text(tr("Closing to the menu bar keeps this analysis session in memory. Quit MANTiS to end the session and stop its engine."))
                    .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
            }.padding(20).frame(maxWidth: 850, alignment: .leading).surface()
                .padding(Theme.contentInset).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct BrandMark: View {
    /// The brand artwork lives in the app bundle (copied by scripts/build_gui.sh).
    /// Fall back to the type lockup so previews and tests render without the bundle.
    private static let artwork: NSImage? = {
        guard let url = Bundle.main.url(forResource: "Mantis_logo_about", withExtension: "png") else { return nil }
        return NSImage(contentsOf: url)
    }()
    var body: some View {
        if let image = Self.artwork {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: 168)
                .accessibilityLabel("MANTiS — Multivariate Analysis Tool for Spectromicroscopy")
        } else {
            HStack(spacing: 10) {
                Image(systemName: "waveform.path.ecg.rectangle").font(.system(size: 28)).foregroundStyle(.teal)
                VStack(alignment: .leading, spacing: 2) { Text("MANTiS").font(.title2.bold()); Text("SPECTROMICROSCOPY").font(.system(size: 8, weight: .semibold)).tracking(1.8).foregroundStyle(.secondary) }
            }
        }
    }
}

struct ParameterInspector: View {
    @ObservedObject var model: WorkspaceModel
    @EnvironmentObject private var preferences: InterfacePreferences
    private func tr(_ key: String) -> String { InterfaceText.value(key, language: preferences.language) }
    @State private var expanded: String?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack { Text(tr("PARAMETERS")).font(.caption.weight(.semibold)).tracking(1); Spacer(); Image(systemName: "slider.horizontal.3") }.foregroundStyle(.secondary)
                ForEach(CommandCatalog.forms(for: model.section)) { form in
                    DisclosureGroup(isExpanded: Binding(get: { expanded == form.id }, set: { expanded = $0 ? form.id : nil })) {
                        CommandEditor(model: model, form: form).padding(.top, 10)
                    } label: { Text(tr(form.title)).font(.callout.weight(.medium)) }
                    Divider()
                }
                Text(tr("Pixel and energy indices start at 0. Crop/ROI upper bounds are exclusive. Unsupported engine methods stay disabled.")).font(.caption).foregroundStyle(.secondary)
            }.padding(18)
        }.inspectorBackground()
        .onChange(of: model.section, initial: true) { _, section in expanded = CommandCatalog.forms(for: section).first?.id }
    }
}

/// Navigation row with the icon in a fixed-width column, so every label starts at the
/// same x regardless of how wide its SF Symbol is (a `Label` does not guarantee that).
struct SidebarRow: View {
    let symbol: String
    let title: String
    let selected: Bool
    var body: some View {
        HStack(spacing: Theme.sidebarIconSpacing) {
            Image(systemName: symbol)
                .frame(width: Theme.sidebarIconWidth, alignment: .center)
                .foregroundStyle(selected ? Theme.accent : .secondary)
            Text(title).fontWeight(selected ? .semibold : .regular)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10).padding(.vertical, 10)
        .background(selected ? Theme.accent.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 9))
        .contentShape(Rectangle())
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct CommandEditor: View {
    @ObservedObject var model: WorkspaceModel
    @EnvironmentObject private var preferences: InterfacePreferences
    private func tr(_ key: String) -> String { InterfaceText.value(key, language: preferences.language) }
    let form: CommandForm
    @State private var values: [String: String] = [:]
    private func binding(_ field: ParameterField) -> Binding<String> { Binding(get: { values[field.key] ?? field.initial }, set: { values[field.key] = $0 }) }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.snapshot != nil && form.method == "open" {
                Text(tr("Choose another file and open it in place of the current stack."))
                    .font(.caption).foregroundStyle(Theme.accent)
            }
            Text(tr(form.help)).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ForEach(form.fields) { field in
                VStack(alignment: .leading, spacing: 5) {
                    switch field.kind {
                    case .toggle:
                        Toggle(tr(field.label), isOn: Binding(get: { binding(field).wrappedValue == "true" }, set: { binding(field).wrappedValue = $0 ? "true" : "false" }))
                    case .choice(let options):
                        Picker(tr(field.label), selection: binding(field)) { ForEach(options, id: \.self) { Text(tr($0)).tag($0) } }
                    case .file, .files:
                        Text(tr(field.label)).font(.caption)
                        HStack { TextField(tr(field.optional ? "Optional" : "Choose file…"), text: binding(field)).textFieldStyle(.roundedBorder); Button { if let paths = model.chooseFiles(multiple: isMultiple(field)) { binding(field).wrappedValue = paths.joined(separator: "\n") } } label: { Image(systemName: "folder") } }
                        if isMultiple(field), !binding(field).wrappedValue.isEmpty { Text(binding(field).wrappedValue).font(.caption2).lineLimit(5).textSelection(.enabled) }
                    default:
                        Text(tr(field.label)).font(.caption)
                        TextField(tr(field.optional ? "Automatic / omitted" : field.label), text: binding(field)).textFieldStyle(.roundedBorder)
                    }
                }
            }
            if form.fields.contains(where: { $0.key == "bounds" }), let rect = model.rectangle {
                Button(tr("Use drawn rectangle")) { values["bounds"] = rect.map(String.init).joined(separator: ", ") }.font(.caption)
            }
            if form.fields.contains(where: { $0.key == "energy_range" }), let s = model.snapshot {
                Button(tr("Use all energies")) { values["energy_range"] = "0, \(s.energies.count)" }.font(.caption)
            }
            Button(tr(form.title)) {
                do { model.run(form.method, try CommandCatalog.parameters(for: form, values: values)) }
                catch { model.error = error.localizedDescription }
            }.buttonStyle(.borderedProminent).tint(Theme.accent).disabled(!model.enabled(form))
            if !model.supports(form.method) { Text(preferences.language == .simplifiedChinese ? "需要引擎能力：\(form.method)" : "Requires engine capability: \(form.method)").font(.caption2).foregroundStyle(.secondary) }
        }.font(.callout).disabled(model.busy || model.preview)
    }
    private func isMultiple(_ field: ParameterField) -> Bool { if case .files = field.kind { true } else { false } }
}