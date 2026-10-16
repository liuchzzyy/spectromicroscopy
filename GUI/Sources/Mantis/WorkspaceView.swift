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
        .frame(minWidth: 1320, minHeight: 740)
        .tint(Theme.accent)
    }
    var body: some View {
        workspaceLayout
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
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
                if let label = WorkspaceModel.sidebarStatusLabel(connected: model.connected) {
                    Text(tr(label)).foregroundStyle(.secondary)
                }
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
                if model.section != .settings && model.section != .versions {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) { model.showInspector.toggle() }
                    } label: {
                        Image(systemName: model.showInspector ? "sidebar.trailing" : "sidebar.right")
                            .frame(width: 22, height: 22)
                    }
                    .help(model.showInspector ? tr("Hide parameters panel") : tr("Show parameters panel"))
                    .accessibilityLabel(model.showInspector ? tr("Hide parameters panel") : tr("Show parameters panel"))
                    .padding(.trailing, 8)
                    .padding(.top, 4)
                }
                if model.busy { ProgressView().controlSize(.small).padding(.top, 8) }
            }.padding(.horizontal, Theme.contentInset).padding(.vertical, 18)
            Divider()
            if model.section == .settings { settings }
            else if model.section == .versions { VersionManagementView(model: model) }
            else {
                if model.showInspector {
                    HSplitView {
                        ScrollView {
                            mainWorkspaceContent
                        }.frame(minWidth: 780)
                        ParameterInspector(model: model).frame(minWidth: 300, idealWidth: 340, maxWidth: 400)
                    }
                } else {
                    ScrollView {
                        mainWorkspaceContent
                    }.frame(minWidth: 780)
                }
            }
            Divider()
            statusBar
        }.pageBackground()
        .onChange(of: model.section) { _, _ in model.selectedImage = 0 }
    }
    private var mainWorkspaceContent: some View {
        VStack(spacing: Theme.sectionSpacing) {
            sourceSummary
            HStack(alignment: .top, spacing: Theme.sectionSpacing) {
                imageCard.frame(maxWidth: .infinity, alignment: .topLeading)
                SpectraChart(spectra: model.displayedSpectra, image: model.image, selectedEnergy: selectedEnergy,
                             display: model.display, selectEnergy: model.selectEnergy,
                             roiColors: Dictionary(uniqueKeysWithValues: model.rois.map { ($0.label, $0.colorHex) }),
                             selectedSeries: Binding(get: { model.selectedSeriesName }, set: { model.selectSeries(named: $0) }),
                             activeSeriesLabel: model.activeROILabel, selectionDisabled: model.busy)
                    .frame(maxWidth: .infinity, minHeight: 350, alignment: .topLeading).surface()
            }
            if let inspection = model.inspection, model.section == .load {
                FileInspectionCardView(model: model, rawJson: inspection)
            }
            resultDetails
        }.padding(Theme.contentInset)
    }
    private var selectedEnergy: Double? {
        guard let s = model.snapshot, s.energies.indices.contains(model.energyIndex) else { return nil }
        return s.energies[model.energyIndex]
    }
    private var sourceSummary: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "square.stack.3d.up.fill")
                    .font(.title3).foregroundStyle(Theme.accent)
                    .frame(width: 38, height: 38)
                    .background(Theme.accent.opacity(0.11), in: RoundedRectangle(cornerRadius: 11))
                VStack(alignment: .leading, spacing: 3) {
                    Text(tr("SOURCE")).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    Text(model.snapshot?.source ?? tr("No dataset loaded"))
                        .font(.system(.callout, design: .monospaced))
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
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
            // All measured metadata reads as ONE row so the card stays compact.
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 16) {
                    ForEach(Array(model.sourceSummaryRows.flatMap { $0 }.enumerated()), id: \.offset) { index, cell in
                        if index > 0 { Divider().frame(height: 31) }
                        summaryValue(cell.label, cell.value)
                    }
                }
                .padding(.bottom, 2)
            }
            .accessibilityIdentifier("workspace.source.metadata")
        }.padding(Theme.cardInset).surface()
    }
    private func summaryValue(_ title: String, _ value: String) -> some View { VStack(alignment: .leading, spacing: 4) { Text(tr(title)).font(.caption2.weight(.semibold)).foregroundStyle(.secondary); Text(tr(value)).font(.system(.callout, design: .monospaced)).lineLimit(1).fixedSize(horizontal: true, vertical: false) } }
    private func pointPositionString(snapshot: Snapshot, x: Int, y: Int) -> String {
        let spatial = snapshot.spatial
        if let unit = spatial?.unit, let axes = spatial, axes.x.indices.contains(x), axes.y.indices.contains(y) {
            return String(format: "%@: X %d px (%.3f %@) · Y %d px (%.3f %@)",
                          tr("Position"), x, axes.x[x], unit, y, axes.y[y], unit)
        } else {
            return String(format: "%@: X %d px · Y %d px", tr("Position"), x, y)
        }
    }
    private var imageCard: some View {
        VStack(spacing: 14) {
            HStack {
                Label(tr("Image workspace"), systemImage: "viewfinder").font(.headline)
                Spacer(minLength: 4)
                HStack(spacing: 8) {
                    // One merged control: the display signal plus any analysis images.
                    // Two boxes that both render "Intensity" are one box too many.
                    Picker(tr("Signal"), selection: Binding(
                        get: { model.selectedSignalOptionID },
                        set: { model.selectSignal($0) }
                    )) {
                        ForEach(model.signalOptions) { option in Text(tr(option.title)).tag(option.id) }
                    }
                    .labelsHidden()
                    .frame(width: model.showsImagePicker ? 170 : 128)
                    .disabled(model.busy || model.preview)
                    .help(tr("Signal"))
                    .accessibilityLabel(tr("Signal"))
                }
            }
            if let image = model.image {
                if let s = model.snapshot {
                    let ptX = model.interactionPoint?.0 ?? s.selected_x
                    let ptY = model.interactionPoint?.1 ?? s.selected_y
                    HStack(spacing: 6) {
                        Image(systemName: "crosshair").font(.caption).foregroundStyle(Theme.accent)
                        Text(pointPositionString(snapshot: s, x: ptX, y: ptY))
                            .font(.caption.monospacedDigit().weight(.medium))
                            .foregroundStyle(.primary)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(Color(NSColor.controlBackgroundColor).opacity(0.85), in: RoundedRectangle(cornerRadius: 6))
                }
                ScientificCanvas(model: model, image: image).frame(height: ScientificCanvas.canvasHeight).accessibilityIdentifier("scientific.image.canvas")
                HStack(alignment: .center, spacing: 8) {
                    Text(tr("Selection")).font(.caption.weight(.medium)).fixedSize()
                    Picker(tr("Selection"), selection: $model.roiMode) {
                        ForEach(["Pixel", "Rectangle", "Lasso"], id: \.self) { Text(tr($0)).tag($0) }
                    }
                    .labelsHidden().pickerStyle(.segmented).frame(maxWidth: 160)

                    Button {
                        model.addPendingROI()
                    } label: {
                        Label(tr("Add ROI"), systemImage: "plus")
                    }
                    .font(.caption).fixedSize()
                    .disabled(!model.canAddROI)

                    Button(tr("Clear ROI")) {
                        model.clearROIs()
                    }
                    .font(.caption).fixedSize()
                    .disabled(model.rois.isEmpty && model.rectangle == nil && model.polygon == nil && model.pendingPixel == nil)
                }.disabled(model.busy)

                if let warning = model.roiWarning {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
                        Text(warning).font(.caption2).foregroundStyle(.orange)
                        Spacer()
                    }
                }

                if !model.rois.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(model.rois) { roi in
                                let isSelected = roi.index == model.selectedROIIndex
                                HStack(spacing: 4) {
                                    Menu {
                                        ForEach(ROIPresets.colors, id: \.self) { hex in
                                            Button {
                                                model.setROIColor(index: roi.index, hex: hex)
                                            } label: {
                                                Label(hex, systemImage: roi.colorHex == hex ? "checkmark.circle.fill" : "circle.fill")
                                            }
                                        }
                                    } label: {
                                        Circle().fill(Color(hex: roi.colorHex)).frame(width: 12, height: 12)
                                    }
                                    .menuStyle(.borderlessButton)
                                    .fixedSize()
                                    .help(tr("ROI color"))
                                    .accessibilityLabel(tr("ROI color") + " \(roi.index)")
                                    Text("[\(roi.index)] ROI \(roi.index)").font(.caption2.weight(isSelected ? .bold : .regular))
                                    Button {
                                        model.removeROI(index: roi.index)
                                    } label: {
                                        Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                                    }
                                    .buttonStyle(.plain)
                                }
                                .padding(.horizontal, 8).padding(.vertical, 4)
                                .background(isSelected ? Color(hex: roi.colorHex).opacity(0.2) : Color(NSColor.controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                                .overlay(RoundedRectangle(cornerRadius: 6).stroke(isSelected ? Color(hex: roi.colorHex) : Color.clear, lineWidth: 1.5))
                                .onTapGesture {
                                    model.selectedROIIndex = roi.index
                                    model.updateView()
                                }
                            }
                        }
                    }
                }
                HStack {
                    Text(tr("Energy")).font(.caption)
                    Slider(value: Binding(get: { Double(model.energyIndex) }, set: { model.energyIndex = Int(round($0)) }), in: 0...Double(max(1, (model.snapshot?.energies.count ?? 1)-1)), onEditingChanged: { editing in if !editing { model.updateView() } })
                    Text(selectedEnergy.map { String(format: "%.3f eV", $0) } ?? "—").font(.system(.caption, design: .monospaced)).frame(width: 105, alignment: .trailing)
                }.disabled(model.busy || (model.snapshot?.energies.count ?? 0) < 2)
                HStack(alignment: .top, spacing: 8) {
                    Text("\(image.width) × \(image.height)").font(.caption2.monospacedDigit()).foregroundStyle(.secondary).fixedSize()
                    Text(tr("Preview sampling; export retains full data")).font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }.frame(maxWidth: .infinity, alignment: .leading)
                if let theta = model.snapshot?.theta, !theta.isEmpty {
                    Picker(tr("Projection angle"), selection: $model.thetaIndex) { ForEach(theta.indices, id: \.self) { Text("\(theta[$0], specifier: "%.2f")°").tag($0) } }.onChange(of: model.thetaIndex) { _, _ in model.updateView() }.disabled(model.busy)
                }
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 12) {
                        Picker(tr("Scale"), selection: $model.spatialDisplay) {
                            Text(tr("Pixel proportions")).tag("pixels")
                            Text(tr("Actual spatial scale")).tag("physical")
                        }
                        .disabled(model.snapshot?.spatial?.unit == nil)
                        .help(model.snapshot?.spatial?.unit == nil ? tr("Physical units not available; showing pixel coordinates") : tr("Use measured spatial coordinates for image proportions"))
                        HStack {
                            Text(tr("Zoom")).font(.caption.weight(.medium))
                            Spacer(minLength: 0)
                            Button { model.zoom(to: model.zoomLevel / 2) } label: { Image(systemName: "minus.magnifyingglass") }.disabled(model.zoomLevel == 1 || model.busy)
                                .accessibilityLabel(tr("Zoom out"))
                            Text("\(model.zoomLevel)×").font(.caption.monospacedDigit()).frame(width: 28)
                            Button { model.zoom(to: model.zoomLevel * 2) } label: { Image(systemName: "plus.magnifyingglass") }.disabled(model.zoomLevel == 16 || model.busy)
                                .accessibilityLabel(tr("Zoom in"))
                            Button(tr("Fit")) { model.zoom(to: 1) }.disabled(model.zoomLevel == 1 || model.busy)
                        }
                        Text(tr("Double-click an image location to zoom into its source pixels.")).font(.caption2).foregroundStyle(.secondary)
                        HStack(spacing: 12) {
                            HStack(spacing: 6) {
                                Text(tr("Min")).lineLimit(1).fixedSize()
                                Slider(value: Binding(get: { model.contrastLow },
                                                      set: { model.contrastLow = min($0, model.contrastHigh - 0.01) }), in: 0...0.99)
                                    .accessibilityLabel(tr("Min"))
                                    .frame(minWidth: 44)
                            }
                            HStack(spacing: 6) {
                                Text(tr("Max")).lineLimit(1).fixedSize()
                                Slider(value: Binding(get: { model.contrastHigh },
                                                      set: { model.contrastHigh = max($0, model.contrastLow + 0.01) }), in: 0.01...1)
                                    .accessibilityLabel(tr("Max"))
                                    .frame(minWidth: 44)
                            }
                        }
                        .font(.callout)
                        .accessibilityIdentifier("display.contrast.range")
                        HStack(spacing: 8) {
                            Text(tr("Gamma")).frame(width: 48, alignment: .leading)
                            Slider(value: $model.gamma, in: 0.1...4)
                        }
                        HStack {
                            Picker(tr("Palette"), selection: $model.colorMap) { ForEach(["Viridis", "Grayscale", "Diverging"], id: \.self) { Text(tr($0)).tag($0) } }
                            Button(tr("Reset")) { model.contrastLow = 0; model.contrastHigh = 1; model.gamma = 1 }
                        }
                        Text(tr("Display changes never modify scientific data.")).font(.caption2).foregroundStyle(.secondary)
                    }.padding(.top, 10)
                } label: { Text(tr("Display Setting")).font(.system(size: 16, weight: .semibold)) }
            } else {
                VStack(spacing: 16) {
                    VStack(spacing: 14) {
                        Image(systemName: "square.stack.3d.up").font(.system(size: 44, weight: .ultraLight)).foregroundStyle(Theme.accent)
                        Text(tr("Start with your measurements")).font(.title3.weight(.medium))
                        Text(tr("Load a spectral stack to inspect images and spectra.\nNo demonstration data is loaded automatically."))
                            .multilineTextAlignment(.center).foregroundStyle(.secondary)
                        Text(tr("Choose an input file in the Parameters panel → Open stack."))
                            .font(.callout).foregroundStyle(Theme.accent).multilineTextAlignment(.center)
                        Text(tr("No source is loaded. Image and charts appear here after import."))
                            .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
                    .background(Theme.dropArea(effectiveScheme), in: RoundedRectangle(cornerRadius: Theme.cornerRadius))

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
            ProcessingHistoryView(history: s.history)
        }
    }
    private var statusBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let error = model.error { HStack(alignment: .top) { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange); Text(error).textSelection(.enabled); Spacer(); Button { model.error = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain) }.font(.caption).padding(.bottom, 3) }
            HStack {
                if let status = model.visibleStatus { Text(InterfaceText.status(status, language: preferences.language)).font(.caption) }
                Spacer()
                if !model.connected && !model.busy {
                    Button(tr("Connect Engine")) { model.connect() }.controlSize(.small).disabled(model.preview)
                }
                Text(tr("Input files are never overwritten")).font(.caption2).foregroundStyle(.secondary)
            }
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

struct ProcessingHistoryView: View {
    let history: [HistoryEntry]
    @EnvironmentObject private var preferences: InterfacePreferences
    private func tr(_ key: String) -> String { InterfaceText.value(key, language: preferences.language) }
    @State private var isExpanded = true
    @State private var showRawJSON = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(tr("Structured history of all operations applied to this dataset."))
                        .font(.caption2).foregroundStyle(.secondary)
                    Spacer()
                    Toggle(tr("Show Raw Parameters"), isOn: $showRawJSON)
                        .font(.caption2)
                        .toggleStyle(.checkbox)
                }
                .padding(.bottom, 4)

                if history.isEmpty {
                    Text(tr("No operations recorded yet.")).font(.caption).foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(history.enumerated()), id: \.offset) { index, entry in
                            HStack(alignment: .top, spacing: 12) {
                                VStack(spacing: 0) {
                                    ZStack {
                                        Circle()
                                            .fill(stepColor(for: entry.method))
                                            .frame(width: 22, height: 22)
                                        Text("\(index + 1)")
                                            .font(.system(size: 10, weight: .bold))
                                            .foregroundColor(.white)
                                    }
                                    if index < history.count - 1 {
                                        Rectangle()
                                            .fill(Color.secondary.opacity(0.25))
                                            .frame(width: 2)
                                            .frame(minHeight: 28)
                                    }
                                }
                                .frame(width: 24)

                                VStack(alignment: .leading, spacing: 6) {
                                    HStack(spacing: 8) {
                                        Label(methodTitle(for: entry.method), systemImage: methodIcon(for: entry.method))
                                            .font(.caption.weight(.semibold))
                                        Text(entry.method)
                                            .font(.system(size: 9, design: .monospaced))
                                            .padding(.horizontal, 4).padding(.vertical, 1)
                                            .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 3))
                                        Spacer()
                                    }

                                    if showRawJSON {
                                        Text(JSONValue.object(entry.params).description)
                                            .font(.system(size: 10, design: .monospaced))
                                            .padding(6)
                                            .background(Color(NSColor.textBackgroundColor), in: RoundedRectangle(cornerRadius: 4))
                                            .textSelection(.enabled)
                                    } else {
                                        formattedParams(entry.params)
                                    }
                                }
                                .padding(10)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color(NSColor.controlBackgroundColor).opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
                                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.12), lineWidth: 1))
                            }
                            .padding(.bottom, index < history.count - 1 ? 8 : 0)
                        }
                    }
                }
            }
            .padding(.top, 12)
        } label: {
            HStack(spacing: 8) {
                Label(tr("Processing History"), systemImage: "clock.arrow.circlepath")
                    .font(.headline)
                Spacer()
                Text("\(history.count) " + tr("operations"))
                    .font(.caption.monospacedDigit())
                    .padding(.horizontal, 8).padding(.vertical, 2)
                    .background(Theme.accent.opacity(0.15), in: Capsule())
                    .foregroundStyle(Theme.accent)
            }
        }
        .padding(16)
        .surface()
    }

    private func methodTitle(for method: String) -> String {
        switch method {
        case "open": return tr("Open Stack")
        case "view": return tr("Update View / ROI")
        case "crop": return tr("Crop Stack")
        case "normalize": return tr("Normalize")
        case "pca": return tr("Calculate PCA")
        case "cluster": return tr("Calculate clusters")
        case "export": return tr("Export")
        case "dark": return tr("Subtract dark signal")
        case "align": return tr("Align images")
        case "despike": return tr("Despike")
        case "reset": return tr("Restore original stack")
        case "build_stack": return tr("Build Stack")
        case "spectral": return tr("Spectral Analysis")
        default: return tr(method.capitalized)
        }
    }

    private func methodIcon(for method: String) -> String {
        switch method {
        case "open": return "tray.and.arrow.down"
        case "view": return "eye"
        case "crop": return "crop"
        case "normalize": return "slider.horizontal.below.square.and.square.filled"
        case "pca": return "chart.bar.xaxis"
        case "cluster": return "circle.hexagongrid"
        case "export": return "square.and.arrow.up"
        case "dark": return "moon.fill"
        case "align": return "arrow.up.and.down.and.arrow.left.and.right"
        default: return "gearshape"
        }
    }

    private func stepColor(for method: String) -> Color {
        switch method {
        case "open": return .blue
        case "view": return .teal
        case "crop", "normalize", "dark", "align": return .orange
        case "pca", "cluster": return .purple
        case "export": return .green
        default: return .secondary
        }
    }

    @ViewBuilder
    private func formattedParams(_ params: [String: JSONValue]) -> some View {
        if params.isEmpty {
            Text(tr("No custom parameters")).font(.caption2).foregroundStyle(.secondary)
        } else {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 140, maximum: 280))], alignment: .leading, spacing: 6) {
                ForEach(params.keys.sorted(), id: \.self) { key in
                    if let val = params[key] {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(formatParamKey(key) + ":").font(.caption2.weight(.medium)).foregroundStyle(.secondary)
                            Text(formatParamVal(val)).font(.caption2.monospaced())
                                .lineLimit(key == "sha256" ? 1 : 2)
                                .truncationMode(.middle)
                                .help(val.description)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(Color(NSColor.textBackgroundColor), in: RoundedRectangle(cornerRadius: 4))
                    }
                }
            }
        }
    }

    private func formatParamKey(_ key: String) -> String {
        switch key {
        case "path": return tr("Path")
        case "paths": return tr("File Paths")
        case "pre_normalized": return tr("Optical Density")
        case "energy_index": return tr("Energy Frame")
        case "energies": return tr("Energies")
        case "x": return "X"
        case "y": return "Y"
        case "roi": return "ROI"
        case "rois": return tr("ROIs")
        case "viewport": return tr("Viewport")
        case "format": return tr("Format")
        case "dpi": return "DPI"
        case "include": return tr("Include")
        case "overwrite": return tr("Overwrite")
        case "spectrum_name": return tr("Spectrum Name")
        case "components": return tr("Components")
        case "clusters": return tr("Clusters")
        case "seed": return tr("Random Seed")
        case "remove_first": return tr("Remove First")
        case "sigma_split": return tr("Sigma Split")
        case "bounds": return tr("Bounds")
        case "energy_range": return tr("Energy Range")
        case "mode": return tr("Mode")
        case "reference": return tr("Reference")
        case "upsample_factor": return tr("Upsample Factor")
        case "crop": return tr("Crop Overlap")
        case "value": return tr("Value")
        case "sigma": return tr("Lee Sigma")
        case "algorithm": return tr("Algorithm")
        case "convention": return tr("Convention")
        case "threshold_percent": return tr("Threshold")
        case "shifts": return tr("Shifts")
        case "display": return tr("Display Signal")
        default: return tr(key.capitalized)
        }
    }

    private func formatParamVal(_ val: JSONValue) -> String {
        switch val {
        case .string(let s):
            if s.contains("/") {
                return URL(fileURLWithPath: s).lastPathComponent
            }
            return tr(s)
        case .bool(let b):
            return b ? tr("Yes") : tr("No")
        case .number(let n):
            return n.truncatingRemainder(dividingBy: 1) == 0 ? "\(Int(n))" : String(format: "%.3g", n)
        case .array(let a):
            if a.allSatisfy({ if case .string = $0 { return true } else { return false } }) {
                let items = a.compactMap { if case .string(let s) = $0 { return tr(s) } else { return nil } }
                return items.joined(separator: ", ")
            }
            return "[\(a.count) " + tr("items") + "]"
        case .object:
            return "{...}"
        case .null:
            return tr("null")
        }
    }
}

struct FileInspectionCardView: View {
    @ObservedObject var model: WorkspaceModel
    let rawJson: String
    @EnvironmentObject private var preferences: InterfacePreferences
    private func tr(_ key: String) -> String { InterfaceText.value(key, language: preferences.language) }
    @State private var showRawJson = false

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                // 顶部状态栏
                HStack(alignment: .center, spacing: 8) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.title3)
                        .foregroundStyle(Theme.accent)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(tr("File Inspection Results"))
                                .font(.headline)
                            if let plugin = model.inspectionInfo?.plugin {
                                Text(plugin)
                                    .font(.caption.weight(.semibold))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Theme.accent.opacity(0.14), in: Capsule())
                                    .foregroundStyle(Theme.accent)
                            }
                            if let scanType = model.inspectionInfo?.scan_type {
                                Text(scanType)
                                    .font(.caption)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.secondary.opacity(0.12), in: Capsule())
                                    .foregroundStyle(.secondary)
                            }
                        }
                        if let path = model.inspectionInfo?.path ?? (model.importFilePath.isEmpty ? nil : model.importFilePath) {
                            Text(path)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .lineLimit(1)
                        }
                    }
                    Spacer()
                    if let size = model.inspectionInfo?.file_size {
                        Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                            .font(.system(.caption, design: .monospaced).weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                }

                Divider()

                // 通道列表或单栈说明
                if let selections = model.inspectionInfo?.selections, !selections.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(tr("Detected Channels & Regions"))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)

                        VStack(spacing: 4) {
                            ForEach(selections) { sel in
                                let isSelected = model.selectedChannelKey == sel.key
                                HStack {
                                    Text("[\(sel.selection[0]), \(sel.selection[1])]")
                                        .font(.system(.caption, design: .monospaced).weight(.bold))
                                        .frame(width: 48, alignment: .leading)

                                    VStack(alignment: .leading, spacing: 1) {
                                        Text("\(sel.region) · \(sel.channel)")
                                            .font(.callout.weight(.medium))
                                        if let shape = sel.shape {
                                            let axesText = sel.axes != nil ? " (\(sel.axes!.joined(separator: ", ")))" : ""
                                            Text(tr("Dimensions") + ": \(shape.map(String.init).joined(separator: " × "))" + axesText)
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                        }
                                    }

                                    Spacer()

                                    if isSelected {
                                        Label(tr("Selected"), systemImage: "checkmark.circle.fill")
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(Theme.accent)
                                    } else {
                                        Button(tr("Use This Channel")) {
                                            model.selectChannel(region: sel.selection[0], channel: sel.selection[1])
                                        }
                                        .controlSize(.small)
                                        .buttonStyle(.bordered)
                                    }
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(isSelected ? Theme.accent.opacity(0.08) : Color(NSColor.controlBackgroundColor).opacity(0.5), in: RoundedRectangle(cornerRadius: 7))
                            }
                        }
                    }
                } else if model.inspectionInfo != nil {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.seal.fill")
                            .foregroundStyle(.green)
                            .font(.headline)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(tr("This file is a single stack or self-contained format; no channel selection is required."))
                                .font(.callout)
                            if let shape = model.inspectionInfo?.shape {
                                Text(tr("Dimensions") + ": \(shape.map(String.init).joined(separator: " × "))")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            if let arrays = model.inspectionInfo?.arrays {
                                Text(tr("Arrays") + ": \(arrays.joined(separator: ", "))")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(6)
                }

                DisclosureGroup(tr("Raw Metadata (JSON)"), isExpanded: $showRawJson) {
                    ScrollView(.horizontal) {
                        Text(rawJson)
                            .font(.system(.caption2, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.top, 4)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding(4)
        } label: {
            Label(tr("File inspection"), systemImage: "info.circle")
        }
        .accessibilityIdentifier("load.fileInspectionCard")
    }
}

struct LoadDataInspector: View {
    @ObservedObject var model: WorkspaceModel
    @EnvironmentObject private var preferences: InterfacePreferences
    private func tr(_ key: String) -> String { InterfaceText.value(key, language: preferences.language) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // 1. 导入设置 (Import Options)
            VStack(alignment: .leading, spacing: 12) {
                Label(tr("Import Options"), systemImage: "square.and.arrow.down").font(.headline)

                // 文件模式 (单选)
                VStack(alignment: .leading, spacing: 6) {
                    Text(tr("File Mode")).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Picker(tr("File Mode"), selection: $model.importFileMode) {
                        Text(tr("Single Stack")).tag("single")
                        Text(tr("Merge Multiple Files")).tag("merge")
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }

                Divider()

                if model.importFileMode == "single" {
                    // 单一文件导入
                    VStack(alignment: .leading, spacing: 8) {
                        Text(tr("File Info")).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        HStack {
                            Text(tr("Format")).font(.caption).frame(width: 48, alignment: .leading)
                            Picker(tr("Format"), selection: $model.importFileFormat) {
                                Text(tr("Auto / All Supported")).tag("all")
                                Text("SDF (*.hdr)").tag("hdr")
                                Text("HDF5 (*.h5, *.hdf5)").tag("hdf5")
                                Text("NPZ (*.npz)").tag("npz")
                            }
                            .labelsHidden()
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Text(tr("File Path")).font(.caption2).foregroundStyle(.secondary)
                            HStack {
                                TextField(tr("Select .hdr, .h5, or .npz file"), text: $model.importFilePath)
                                    .textFieldStyle(.roundedBorder)
                                Button {
                                    if let chosen = model.chooseFiles()?.first {
                                        model.importFilePath = chosen
                                        model.inspectFile()
                                    }
                                } label: {
                                    Image(systemName: "folder")
                                }
                                .help(tr("Choose stack file…"))
                            }
                        }
                    }

                    Divider()

                    VStack(alignment: .leading, spacing: 8) {
                        Text(tr("Parameters")).font(.headline)
                        Toggle(tr("Input is already optical density (OD)"), isOn: $model.openAsOpticalDensity)
                            .font(.callout)
                            .toggleStyle(.checkbox)
                            .help(tr("This declaration applies to the next file you open; it never changes the current stack."))
                            .disabled(model.busy)

                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(tr("Other Parameters")).font(.callout.weight(.semibold)).foregroundStyle(.primary)
                                Spacer()
                                if let plugin = model.inspectionInfo?.plugin {
                                    Text(plugin)
                                        .font(.caption2.weight(.semibold))
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Theme.accent.opacity(0.12), in: Capsule())
                                        .foregroundStyle(Theme.accent)
                                }
                            }

                            Picker(tr("Channel / Region"), selection: Binding(
                                get: { model.selectedChannelKey },
                                set: { model.selectChannelKey($0) }
                            )) {
                                Text(tr("Default (Auto)")).tag("auto")
                                if let selections = model.inspectionInfo?.selections, !selections.isEmpty {
                                    ForEach(selections) { sel in
                                        Text(sel.displayName).tag(sel.key)
                                    }
                                }
                                Text(tr("Custom / Manual JSON…")).tag("manual")
                            }
                            .labelsHidden()
                            .accessibilityLabel(tr("Channel / Region"))
                            .disabled(!model.importSelectionGuide.supportsSelection || model.busy)
                            .accessibilityIdentifier("load.channelPicker")

                            if model.selectedChannelKey == "manual" {
                                TextField(tr(model.importSelectionGuide.placeholder), text: $model.importSelection)
                                    .textFieldStyle(.roundedBorder)
                                    .disabled(!model.importSelectionGuide.supportsSelection || model.busy)
                                    .accessibilityLabel(tr("Other Parameters"))
                                    .accessibilityIdentifier("load.selection")
                            }

                            Group {
                                if let info = model.inspectionInfo {
                                    if !info.selections.isEmpty {
                                        HStack(spacing: 4) {
                                            Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.accent)
                                            Text("\(info.plugin) · \(info.selections.count) " + tr("channel(s) detected"))
                                        }
                                    } else {
                                        HStack(spacing: 4) {
                                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.secondary)
                                            Text(tr("Single stack format, no channel selection needed"))
                                        }
                                    }
                                } else if !model.importSelectionGuide.supportsSelection {
                                    HStack(spacing: 4) {
                                        Image(systemName: "info.circle").foregroundStyle(.secondary)
                                        Text(tr("No channel selection needed"))
                                    }
                                } else {
                                    HStack(spacing: 4) {
                                        Image(systemName: "info.circle").foregroundStyle(.secondary)
                                        Text(tr("Select channel above or click 'Inspect File' to detect"))
                                    }
                                }
                            }
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        }
                        .accessibilityIdentifier("load.selectionParameters")

                        HStack(spacing: 8) {
                            Button(tr("Inspect File")) {
                                model.inspectFile()
                            }
                            .disabled(model.importFilePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.busy)

                            Spacer()

                            Button(tr("Open Stack")) {
                                model.importSingleStack()
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(model.importFilePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.busy)
                        }
                        .padding(.top, 4)
                    }
                } else {
                    // 合并多个文件导入
                    VStack(alignment: .leading, spacing: 8) {
                        Text(tr("File Info")).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        HStack {
                            Text("\(model.mergeFilePaths.count) " + tr("files selected"))
                                .font(.caption.monospacedDigit())
                            Spacer()
                            Button(tr("Choose Files…")) {
                                if let chosen = model.chooseFiles(multiple: true) {
                                    model.mergeFilePaths = chosen
                                }
                            }
                        }
                        if !model.mergeFilePaths.isEmpty {
                            ScrollView(.vertical) {
                                VStack(alignment: .leading, spacing: 2) {
                                    ForEach(model.mergeFilePaths.prefix(5), id: \.self) { path in
                                        Text(URL(fileURLWithPath: path).lastPathComponent)
                                            .font(.caption2.monospaced())
                                            .lineLimit(1)
                                    }
                                    if model.mergeFilePaths.count > 5 {
                                        Text("... and \(model.mergeFilePaths.count - 5) more")
                                            .font(.caption2).foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .frame(maxHeight: 70)
                            .padding(6)
                            .background(Color(NSColor.textBackgroundColor), in: RoundedRectangle(cornerRadius: 4))
                        }
                    }

                    Divider()

                    VStack(alignment: .leading, spacing: 8) {
                        Text(tr("Parameters")).font(.headline)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(tr("Photon energies in eV (comma or space separated)")).font(.caption2).foregroundStyle(.secondary)
                            TextField(tr("e.g. 280.0, 280.5, 281.0"), text: $model.mergeEnergiesText)
                                .textFieldStyle(.roundedBorder)
                        }

                        Button(tr("Build Stack")) {
                            model.importMergedStack()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.mergeFilePaths.count < 2 || model.mergeEnergiesText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.busy)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .padding(.top, 4)
                    }
                }
            }
            .padding(14)
            .surface()

            // 2. 导出设置 (Export Options)
            VStack(alignment: .leading, spacing: 14) {
                Label(tr("Export Options"), systemImage: "square.and.arrow.up").font(.headline)

                // Compact data and format pickers share one row with the action.
                VStack(alignment: .leading, spacing: 8) {
                    Text(tr("Processed Data Export")).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    HStack(spacing: 6) {
                        // Format first, then the data selection, then a plain text action.
                        Picker(tr("Format"), selection: $model.dataExportFormat) {
                            ForEach(["npz", "hdf5", "csv"], id: \.self) { Text($0.uppercased()).tag($0) }
                        }
                        .labelsHidden()
                        .frame(width: 62)
                        if model.dataExportFormat != "csv" {
                            Picker(tr("Data"), selection: Binding(
                                get: { model.selectedExportTarget },
                                set: { target in
                                    model.selectedExportTarget = target
                                    if let opt = model.exportDataOptions.first(where: { $0.id == target }) {
                                        model.selectedDataGroups = opt.groups
                                    }
                                }
                            )) {
                                ForEach(model.exportDataOptions) { opt in
                                    Text(opt.displayName).tag(opt.id)
                                }
                            }
                            .labelsHidden()
                            .frame(minWidth: 60, maxWidth: .infinity)
                            .layoutPriority(-1)
                        }
                        Spacer(minLength: 0)
                        Button(tr(WorkspaceModel.dataExportActionTitle)) {
                            model.exportProcessedData()
                        }
                        .fixedSize()
                        .disabled(!model.canExportProcessedData || model.busy || model.preview || !model.supports("export"))
                    }
                    .controlSize(.small)
                    if model.dataExportFormat == "csv" {
                        Text(tr("CSV exports current spectra only; data choices apply to NPZ/HDF5."))
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    else if model.selectedExportTarget.hasPrefix("ROI") && model.selectedExportTarget.hasSuffix("ImageMapping") {
                        Text(tr("Analysis results are session-wide; ROI mapping is a suggested filename, not an ROI-only dataset."))
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }

                Divider()

                // 图像导出
                VStack(alignment: .leading, spacing: 8) {
                    Text(tr("Image Export")).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    HStack(spacing: 4) {
                        Picker(tr("Format"), selection: $model.imageExportFormat) {
                            ForEach(["png", "pdf", "svg"], id: \.self) { Text($0.uppercased()).tag($0) }
                        }
                        .labelsHidden()
                        .frame(width: 56)

                        Picker(tr("DPI"), selection: $model.imageExportDPI) {
                            ForEach([150, 300, 600], id: \.self) { Text("\($0) DPI").tag($0) }
                        }
                        .labelsHidden()
                        .frame(width: 76)

                        Spacer(minLength: 0)
                        Button(tr("Export Image…")) {
                            model.exportImage()
                        }
                        .fixedSize()
                        .disabled(!model.canExportImage)
                    }
                    .controlSize(.small)
                }

                Divider()

                // 操作日志导出：与图片导出相同，选择格式后直接保存。
                VStack(alignment: .leading, spacing: 8) {
                    Text(tr("Export Work Log")).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    HStack {
                        Picker(tr("Log Format"), selection: $model.logExportFormat) {
                            Text("JSON").tag("json")
                            Text("Markdown (.md)").tag("md")
                        }
                        .labelsHidden()
                        Spacer()
                        Button(tr("Export Log…")) { model.exportWorkflowLog() }
                            .fixedSize()
                            .disabled(!model.canExportWorkflowLog || model.preview)
                    }
                    .controlSize(.small)
                }
            }
            .padding(14)
            .surface()
        }
    }
}

struct ParameterInspector: View {
    @ObservedObject var model: WorkspaceModel
    @EnvironmentObject private var preferences: InterfacePreferences
    private func tr(_ key: String) -> String { InterfaceText.value(key, language: preferences.language) }
    @State private var expanded: String?
    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text(tr("PARAMETERS")).font(.title3.weight(.semibold))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("inspector.title")
                    if model.section == .load {
                        LoadDataInspector(model: model)
                    } else {
                        ForEach(CommandCatalog.forms(for: model.section)) { form in
                            DisclosureGroup(isExpanded: Binding(get: { expanded == form.id }, set: { expanded = $0 ? form.id : nil })) {
                                CommandEditor(model: model, form: form).padding(.top, 10)
                            } label: { Text(tr(form.title)).font(.callout.weight(.medium)) }
                            Divider()
                        }
                        Text(tr("Pixel and energy indices start at 0. Crop/ROI upper bounds are exclusive. Unsupported engine methods stay disabled.")).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                // Keep padding inside the proposed split-column width. Intrinsic
                // picker sizes must not expand the scroll document beyond it.
                .frame(width: max(0, geometry.size.width - 2 * Theme.inspectorInset), alignment: .topLeading)
                .padding(.horizontal, Theme.inspectorInset)
                .padding(.vertical, 22)
            }
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
            if form.method == "open" {
                Button { if let path = model.chooseFiles()?.first { values["path"] = path } } label: {
                    Label(tr("Choose stack file…"), systemImage: "folder")
                }
                .help(tr("Select a file, not a folder; SDF uses the .hdr file."))
                .accessibilityIdentifier("load.stack.choose")
            }
            if form.method == "open", let path = values["path"], !path.isEmpty {
                Text(URL(fileURLWithPath: path).lastPathComponent)
                    .font(.caption.monospaced()).lineLimit(2).help(path)
            }
            if form.method == "open" {
                TextField(tr("Stack file"), text: Binding(
                    get: { values["path"] ?? "" }, set: { values["path"] = $0 }
                )).textFieldStyle(.roundedBorder)
                    .help(tr("Enter a full path or choose a stack file above."))
            }
            ForEach(form.fields.filter { !(form.method == "open" && ($0.key == "path" || $0.key == "pre_normalized")) }) { field in
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
                do {
                    let params = try Self.parameters(for: form, values: values, openAsOpticalDensity: model.openAsOpticalDensity)
                    if form.method == "open", case let .string(path)? = params["path"] {
                        let selected = try WorkspaceModel.stackFile(from: URL(fileURLWithPath: path))
                        model.openStack(at: selected, selection: params["selection"])
                    } else {
                        model.run(form.method, params)
                    }
                } catch { model.error = error.localizedDescription }
            }.buttonStyle(.borderedProminent).tint(Theme.accent).disabled(!model.enabled(form))
                .accessibilityIdentifier("command.\(form.method).\(form.id)")
            if !model.supports(form.method) { Text(preferences.language == .simplifiedChinese ? "需要引擎能力：\(form.method)" : "Requires engine capability: \(form.method)").font(.caption2).foregroundStyle(.secondary) }
        }.font(.callout).disabled(model.busy || model.preview)
    }
    static func parameters(for form: CommandForm, values: [String: String], openAsOpticalDensity: Bool) throws -> [String: JSONValue] {
        var params = try CommandCatalog.parameters(for: form, values: values)
        if form.method == "open" { params["pre_normalized"] = .bool(openAsOpticalDensity) }
        return params
    }
    private func isMultiple(_ field: ParameterField) -> Bool { if case .files = field.kind { true } else { false } }
}
