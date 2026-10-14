import SwiftUI
import AppKit
import MantisCore

struct WorkspaceView: View {
    @ObservedObject var model: WorkspaceModel
    var body: some View {
        NavigationSplitView {
            sidebar.navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 250)
        } detail: { detail }
        .frame(minWidth: 1080, minHeight: 720)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { model.openStack() } label: { Label("Open Stack", systemImage: "folder") }.disabled(model.busy || !model.supports("open"))
                Picker("Export format", selection: $model.exportFormat) { ForEach(["npz", "hdf5", "csv", "png", "pdf", "svg"], id: \.self) { Text($0.uppercased()).tag($0) } }.frame(width: 90)
                Button { model.export() } label: { Label("Export", systemImage: "square.and.arrow.up") }.disabled(!model.canExport)
                    .help(model.showsEngineCurrentView ? "Export the current session" : "Image formats export the engine's current view; switch to that panel or use a numeric format")
                if model.busy { Button("Cancel & Reset", role: .destructive) { model.cancel() } }
            }
        }
    }
    var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "waveform.path.ecg.rectangle").font(.system(size: 28)).foregroundStyle(.teal)
                VStack(alignment: .leading, spacing: 2) { Text("MANTiS").font(.title2.bold()); Text("SPECTROMICROSCOPY").font(.system(size: 8, weight: .semibold)).tracking(1.8).foregroundStyle(.secondary) }
            }.padding(20)
            List(selection: $model.section) {
                Section("WORKFLOW") {
                    ForEach(WorkflowSection.allCases.filter { $0 != .settings }) { section in
                        HStack(spacing: 10) { Image(systemName: section.symbol).frame(width: 19); Text(section.rawValue) }.padding(.vertical, 5).tag(section)
                    }
                }
                Section { Label("Settings", systemImage: "gearshape").padding(.vertical, 5).tag(WorkflowSection.settings) }
            }.listStyle(.sidebar)
            Divider()
            VStack(alignment: .leading, spacing: 7) {
                Label(model.connected ? "Private engine connected" : "Not connected", systemImage: model.connected ? "checkmark.circle.fill" : "circle.dotted").foregroundStyle(model.connected ? .green : .secondary)
                Text("Native 1.0.0 · Protocol 1").font(.caption).foregroundStyle(.secondary)
            }.font(.caption).padding(16)
        }.background(.ultraThinMaterial)
    }
    var detail: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(model.section.rawValue).font(.system(size: 26, weight: .semibold))
                    Text(model.section.subtitle).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                if model.busy { ProgressView().controlSize(.small).padding(.top, 8) }
            }.padding(.horizontal, 24).padding(.vertical, 20)
            Divider()
            if model.section == .settings { settings }
            else {
                HSplitView {
                    ScrollView {
                        VStack(spacing: 16) {
                            sourceSummary
                            imageCard
                            SpectraChart(spectra: model.shown?.spectra ?? [], selectedEnergy: selectedEnergy, selectEnergy: model.selectEnergy)
                                .frame(height: 285).surface()
                            if let inspection = model.inspection, model.section == .load {
                                GroupBox("File inspection") { Text(inspection).font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                            }
                            resultDetails
                        }.padding(20)
                    }.frame(minWidth: 490)
                    ParameterInspector(model: model).frame(minWidth: 280, idealWidth: 310, maxWidth: 360)
                }
            }
            Divider()
            statusBar
        }.background(Color(nsColor: .underPageBackgroundColor))
        .onChange(of: model.section) { _, _ in model.selectedImage = 0 }
    }
    private var selectedEnergy: Double? {
        guard let s = model.snapshot, s.energies.indices.contains(model.energyIndex) else { return nil }
        return s.energies[model.energyIndex]
    }
    private var sourceSummary: some View {
        HStack(spacing: 24) {
            VStack(alignment: .leading, spacing: 4) {
                Text("SOURCE").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                Text(model.snapshot.map { URL(fileURLWithPath: $0.source).lastPathComponent } ?? "No dataset loaded").font(.headline).lineLimit(1).help(model.snapshot?.source ?? "")
            }
            Spacer()
            summaryValue("SHAPE", model.snapshot?.shape.map(String.init).joined(separator: " × ") ?? "—")
            summaryValue("SIGNAL", model.snapshot.map { $0.normalized ? "Optical density" : "Intensity" } ?? "—")
        }.padding(16).surface()
    }
    private func summaryValue(_ title: String, _ value: String) -> some View { VStack(alignment: .leading, spacing: 4) { Text(title).font(.caption2.weight(.semibold)).foregroundStyle(.secondary); Text(value).font(.system(.callout, design: .monospaced)) } }
    private var imageCard: some View {
        VStack(spacing: 12) {
            HStack {
                Label("Image workspace", systemImage: "viewfinder").font(.headline)
                Spacer()
                if !model.availableImages.isEmpty {
                    Picker("Image", selection: $model.selectedImage) { ForEach(Array(model.availableImages.enumerated()), id: \.offset) { index, image in Text(image.title).tag(index) } }.labelsHidden().frame(maxWidth: 210)
                }
            }
            if let image = model.image {
                ScientificCanvas(model: model, image: image).frame(height: 320)
                HStack {
                    Picker("Selection", selection: $model.roiMode) { ForEach(["Pixel", "Rectangle", "Lasso"], id: \.self) { Text($0).tag($0) } }.pickerStyle(.segmented).frame(maxWidth: 260)
                    Button("Clear ROI") { model.rectangle = nil; model.polygon = nil; model.updateView() }
                    Spacer()
                    if let s = model.snapshot { Text("x \(s.selected_x) · y \(s.selected_y)").monospacedDigit().foregroundStyle(.secondary) }
                }.disabled(model.busy)
                HStack {
                    Text("Energy").font(.caption)
                    Slider(value: Binding(get: { Double(model.energyIndex) }, set: { model.energyIndex = Int($0) }), in: 0...Double(max(1, (model.snapshot?.energies.count ?? 1)-1)), step: 1, onEditingChanged: { editing in if !editing { model.updateView() } })
                    Text(selectedEnergy.map { String(format: "%.3f eV", $0) } ?? "—").font(.system(.caption, design: .monospaced)).frame(width: 105, alignment: .trailing)
                }.disabled(model.busy || (model.snapshot?.energies.count ?? 0) < 2)
                HStack {
                    Picker("Signal", selection: $model.display) { Text("Intensity").tag("intensity"); Text("Optical density").tag("od") }.frame(maxWidth: 220).onChange(of: model.display) { _, _ in model.updateView() }
                    Spacer()
                    Text("Display \(image.width) × \(image.height); export retains full data").font(.caption2).foregroundStyle(.secondary)
                }.disabled(model.busy)
                if let theta = model.snapshot?.theta, !theta.isEmpty {
                    Picker("Projection angle", selection: $model.thetaIndex) { ForEach(theta.indices, id: \.self) { Text("\(theta[$0], specifier: "%.2f")°").tag($0) } }.onChange(of: model.thetaIndex) { _, _ in model.updateView() }.disabled(model.busy)
                }
                DisclosureGroup("Display contrast — does not change scientific data") {
                    VStack {
                        HStack { Text("Min").frame(width: 45); Slider(value: $model.contrastLow, in: 0...0.99); Text("Max").frame(width: 45); Slider(value: $model.contrastHigh, in: 0.01...1) }
                        HStack { Text("Gamma").frame(width: 45); Slider(value: $model.gamma, in: 0.1...4); Picker("Palette", selection: $model.colorMap) { ForEach(["Viridis", "Grayscale", "Diverging"], id: \.self) { Text($0).tag($0) } }; Button("Reset") { model.contrastLow = 0; model.contrastHigh = 1; model.gamma = 1 } }
                    }.font(.caption).padding(.top, 8)
                }.font(.caption)
            } else {
                VStack(spacing: 16) {
                    Image(systemName: "square.stack.3d.up").font(.system(size: 48, weight: .ultraLight)).foregroundStyle(.teal)
                    Text("Start with your measurements").font(.title3.weight(.medium))
                    Text("Load a spectral stack to inspect images and spectra.\nNo demonstration data is loaded automatically.").multilineTextAlignment(.center).foregroundStyle(.secondary)
                    Button("Open Stack…") { model.openStack() }.buttonStyle(.borderedProminent).tint(.teal).disabled(!model.supports("open") || model.busy)
                    Text("HDF5 · SDF · STK · TIFF · XRM · NPZ · plugin formats").font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity).frame(height: 340)
            }
        }.padding(16).surface()
    }
    @ViewBuilder private var resultDetails: some View {
        if let s = model.shown {
            if !s.metrics.isEmpty {
                DisclosureGroup("Numerical results & reference annotations") {
                    VStack(alignment: .leading, spacing: 10) { ForEach(s.metrics.keys.sorted(), id: \.self) { key in VStack(alignment: .leading, spacing: 3) { Text(key).font(.caption.bold()); Text(s.metrics[key]?.string ?? s.metrics[key]?.description ?? "").font(.system(.caption, design: .monospaced)).textSelection(.enabled) }.frame(maxWidth: .infinity, alignment: .leading) } }.padding(.top, 12)
                }.padding(16).surface()
            }
            DisclosureGroup("Processing history · \(s.history.count) operations") {
                VStack(alignment: .leading, spacing: 10) { ForEach(Array(s.history.enumerated()), id: \.offset) { i, entry in VStack(alignment: .leading, spacing: 2) { Text("\(i+1). \(entry.method)").font(.caption.bold()); Text(JSONValue.object(entry.params).description).font(.system(.caption2, design: .monospaced)).textSelection(.enabled) } } }.frame(maxWidth: .infinity, alignment: .leading).padding(.top, 12)
            }.padding(16).surface()
        }
    }
    private var statusBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let error = model.error { HStack(alignment: .top) { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange); Text(error).textSelection(.enabled); Spacer(); Button { model.error = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain) }.font(.caption).padding(.bottom, 3) }
            HStack { Circle().fill(model.busy ? .orange : model.connected ? .green : .secondary).frame(width: 6,height: 6); Text(model.status).font(.caption); Spacer(); if !model.connected && !model.busy { Button("Connect Engine") { model.connect() }.controlSize(.small).disabled(model.preview) }; Text("Input files are never overwritten").font(.caption2).foregroundStyle(.secondary) }
        }.padding(.horizontal, 20).padding(.vertical, 10).background(.bar)
    }
    private var settings: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                GroupBox("Independent versions") {
                    Grid(alignment: .leading, horizontalSpacing: 60, verticalSpacing: 12) {
                        GridRow { Text("Native interface"); Text("1.0.0 (build 1)").monospaced() }
                        GridRow { Text("Numerical engine"); Text(model.handshake?.engine_version ?? "Not connected").monospaced() }
                        GridRow { Text("Wire protocol"); Text("1").monospaced() }
                        GridRow { Text("Compatibility"); Text("macOS 14 or newer") }
                    }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                }
                GroupBox("Private engine") {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("The GUI launches only its private Contents/Resources/engine/mantis-engine. It never invokes a user-installed MANTiS CLI.")
                        Text("Development override: MANTIS_ENGINE_PATH must be an explicit executable absolute path. Cancellation terminates and reaps the process, clears this session and requires a new connection.").foregroundStyle(.secondary)
                        Button(model.connected ? "Reconnect (clears session)" : "Connect Engine") { if model.connected { model.cancel() } else { model.connect() } }.disabled(model.busy || model.preview)
                    }.padding(12)
                }
                GroupBox("Advertised capabilities") { Text(model.handshake?.capabilities.sorted().joined(separator: " · ") ?? "Unavailable until handshake succeeds").font(.system(.callout, design: .monospaced)).textSelection(.enabled).padding(12).frame(maxWidth: .infinity, alignment: .leading) }
                GroupBox("Scientific provenance") { Text("Processing parameters and deterministic seeds are kept in engine history. Display contrast is not processing. NPZ and HDF5 exports retain numerical analysis and original/processed data; CSV and graphics export displayed results. Peak annotations are references, not chemical identification certainty.").padding(12) }
            }.padding(28)
        }
    }
}

struct ParameterInspector: View {
    @ObservedObject var model: WorkspaceModel
    @State private var expanded: String?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack { Text("PARAMETERS").font(.caption.weight(.semibold)).tracking(1); Spacer(); Image(systemName: "slider.horizontal.3") }.foregroundStyle(.secondary)
                ForEach(CommandCatalog.forms(for: model.section)) { form in
                    DisclosureGroup(isExpanded: Binding(get: { expanded == form.id }, set: { expanded = $0 ? form.id : nil })) {
                        CommandEditor(model: model, form: form).padding(.top, 10)
                    } label: { Text(form.title).font(.callout.weight(.medium)) }
                    Divider()
                }
                Text("Pixel and energy indices start at 0. Crop/ROI upper bounds are exclusive. Unsupported engine methods stay disabled.").font(.caption).foregroundStyle(.secondary)
            }.padding(18)
        }.background(Color(nsColor: .controlBackgroundColor))
        .onChange(of: model.section, initial: true) { _, section in expanded = CommandCatalog.forms(for: section).first?.id }
    }
}

struct CommandEditor: View {
    @ObservedObject var model: WorkspaceModel
    let form: CommandForm
    @State private var values: [String: String] = [:]
    private func binding(_ field: ParameterField) -> Binding<String> { Binding(get: { values[field.key] ?? field.initial }, set: { values[field.key] = $0 }) }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(form.help).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ForEach(form.fields) { field in
                VStack(alignment: .leading, spacing: 5) {
                    switch field.kind {
                    case .toggle:
                        Toggle(field.label, isOn: Binding(get: { binding(field).wrappedValue == "true" }, set: { binding(field).wrappedValue = $0 ? "true" : "false" }))
                    case .choice(let options):
                        Picker(field.label, selection: binding(field)) { ForEach(options, id: \.self) { Text($0).tag($0) } }
                    case .file, .files:
                        Text(field.label).font(.caption)
                        HStack { TextField(field.optional ? "Optional" : "Choose file…", text: binding(field)).textFieldStyle(.roundedBorder); Button { if let paths = model.chooseFiles(multiple: isMultiple(field)) { binding(field).wrappedValue = paths.joined(separator: "\n") } } label: { Image(systemName: "folder") } }
                        if isMultiple(field), !binding(field).wrappedValue.isEmpty { Text(binding(field).wrappedValue).font(.caption2).lineLimit(5).textSelection(.enabled) }
                    default:
                        Text(field.label).font(.caption)
                        TextField(field.optional ? "Automatic / omitted" : field.label, text: binding(field)).textFieldStyle(.roundedBorder)
                    }
                }
            }
            if form.fields.contains(where: { $0.key == "bounds" }), let rect = model.rectangle {
                Button("Use drawn rectangle") { values["bounds"] = rect.map(String.init).joined(separator: ", ") }.font(.caption)
            }
            if form.fields.contains(where: { $0.key == "energy_range" }), let s = model.snapshot {
                Button("Use all energies") { values["energy_range"] = "0, \(s.energies.count)" }.font(.caption)
            }
            Button(form.title) {
                do { model.run(form.method, try CommandCatalog.parameters(for: form, values: values)) }
                catch { model.error = error.localizedDescription }
            }.buttonStyle(.borderedProminent).tint(.teal).disabled(!model.enabled(form))
            if !model.supports(form.method) { Text("Requires engine capability: \(form.method)").font(.caption2).foregroundStyle(.secondary) }
        }.font(.callout).disabled(model.busy || model.preview)
    }
    private func isMultiple(_ field: ParameterField) -> Bool { if case .files = field.kind { true } else { false } }
}

private struct Surface: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    func body(content: Content) -> some View {
        content.background(scheme == .dark ? Color(white: 0.16) : .white, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(.primary.opacity(0.07), lineWidth: 1))
    }
}
extension View { func surface() -> some View { modifier(Surface()) } }
