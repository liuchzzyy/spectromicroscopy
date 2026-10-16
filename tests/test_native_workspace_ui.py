"""Source contracts for workspace layout; native builds/smoke cover runtime behavior."""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
VIEWS = ROOT / "GUI/Sources/Mantis/WorkspaceView.swift"
CHARTS = ROOT / "GUI/Sources/Mantis/ScientificViews.swift"
APP = ROOT / "GUI/Sources/Mantis/MantisApp.swift"


def test_workspace_metadata_is_one_row_with_accessible_horizontal_overflow():
    source = VIEWS.read_text()
    summary = source.split("private var sourceSummary:", 1)[1].split("private func summaryValue", 1)[0]
    assert "ScrollView(.horizontal" in summary
    assert "model.sourceSummaryRows.flatMap" in summary


def test_workspace_has_one_localized_signal_picker():
    source = VIEWS.read_text()
    card = source.split("private var imageCard:", 1)[1].split("@ViewBuilder private var resultDetails", 1)[0]
    assert card.count('Picker(tr("Signal")') == 1
    assert 'Picker(tr("Image")' not in card
    assert "Text(tr(option.title))" in card


def test_chart_zoom_toolbars_are_above_the_drag_hit_layer():
    source = CHARTS.read_text()
    # The hit-test layer must be created before the toolbar overlay, otherwise it
    # intercepts clicks that should reach the zoom/reset buttons.
    for start, end in [(".chartXScale(domain: currentXDomain)", "// Legend"),
                       (".chartXScale(domain: histX)", "private var axisLabel")]:
        chart = source.split(start, 1)[1].split(end, 1)[0]
        assert chart.index(".chartOverlay") < chart.index("ChartToolbar(mode:")
    header = source.split('Label(tr("Spectral analysis")', 1)[1].split('if spectra.isEmpty', 1)[0]
    assert header.index('Picker(tr("Series")') < header.index("Spacer(minLength:")


def test_chart_toolbars_reserve_space_without_covering_scientific_marks():
    source = CHARTS.read_text()
    assert source.count('.padding(.top, ChartToolbar.buttonHeight + 12)') == 2
    spectrum = source.split('.chartXScale(domain: currentXDomain)', 1)[1].split('// Legend', 1)[0]
    assert 'AxisMarks(values: .automatic(desiredCount: 3))' in spectrum
    assert 'AxisValueLabel(anchor: value.index == 0 ? .topLeading : .topTrailing)' in spectrum
    assert '.padding(.trailing, 8)' in spectrum


def test_chart_toolbar_has_full_size_hit_targets_and_visible_reset():
    toolbar = CHARTS.read_text().split("struct ChartToolbar: View", 1)[1].split("struct SpectrumSeriesMarks", 1)[0]
    assert toolbar.count(".contentShape(Rectangle())") == 2
    assert '.disabled(!canReset)' not in toolbar
    assert '.font(.system(size: 14, weight: .medium))' in toolbar


def test_data_export_is_format_then_data_then_text_action():
    source = VIEWS.read_text()
    row = source.split('Text(tr("Processed Data Export"))', 1)[1].split('// 图像导出', 1)[0]
    assert row.index('Picker(tr("Format")') < row.index('Picker(tr("Data")')
    assert row.index('Picker(tr("Data")') < row.index('Button(tr(WorkspaceModel.dataExportActionTitle))')
    assert 'Image(systemName:' not in row


def test_inspector_preserves_gutters_and_uses_readable_titles():
    source = VIEWS.read_text()
    inspector = source.split('struct ParameterInspector: View', 1)[1].split('struct SidebarRow: View', 1)[0]
    assert 'Text(tr("PARAMETERS")).font(.title3.weight(.semibold))' in inspector
    assert '.padding(.horizontal, Theme.inspectorInset)' in inspector
    assert '.frame(maxWidth: .infinity, alignment: .leading)' in inspector
    load = source.split('struct LoadDataInspector: View', 1)[1].split('struct ParameterInspector: View', 1)[0]
    assert load.count('Text(tr("Parameters")).font(.headline)') == 2
    data = load.split('Text(tr("Processed Data Export"))', 1)[1].split('// 图像导出', 1)[0]
    assert '.frame(width: 112)' not in data
    assert '.frame(minWidth: 60, maxWidth: .infinity)' in data
    assert '.controlSize(.small)' in data
    image = load.split('// 图像导出', 1)[1].split('// 操作日志导出', 1)[0]
    assert 'HStack(spacing: 4)' in image
    assert '.frame(width: 56)' in image
    assert '.frame(width: 76)' in image


def test_import_channel_picker_and_enhanced_inspection_view():
    source = VIEWS.read_text()
    assert 'struct FileInspectionCardView: View' in source
    assert 'FileInspectionCardView(model: model, rawJson: inspection)' in source

    load = source.split('struct LoadDataInspector: View', 1)[1].split('struct ParameterInspector: View', 1)[0]
    section = load.split('Text(tr("Parameters")).font(.headline)', 1)[1].split('Button(tr("Inspect File"))', 1)[0]
    assert 'DisclosureGroup(' not in section
    assert 'Text(tr("Other Parameters")).font(.callout.weight(.semibold)).foregroundStyle(.primary)' in section
    assert 'Text(tr("Region / Channel (Optional)"))' not in section
    assert 'Picker(tr("Channel / Region"), selection:' in section
    assert '.accessibilityIdentifier("load.channelPicker")' in section
    assert 'TextField(tr(model.importSelectionGuide.placeholder), text: $model.importSelection)' in section
    assert 'model.selectedChannelKey == "manual"' in section
    assert 'Text(tr("Single stack format, no channel selection needed"))' in section
    assert 'Text(tr("Select channel above or click \'Inspect File\' to detect"))' in section


def test_display_limits_keep_each_label_on_one_line_in_one_row():
    source = VIEWS.read_text()
    limits = source.split('.accessibilityIdentifier("display.contrast.range")', 1)[0].rsplit('HStack(spacing: 12)', 1)[-1]
    assert 'Text(tr("Min")).lineLimit(1).fixedSize()' in limits
    assert 'Text(tr("Max")).lineLimit(1).fixedSize()' in limits
    assert '.frame(width: 32' not in limits
    assert limits.count('.frame(minWidth: 44)') == 2


def test_connected_copy_is_not_rendered_in_either_status_area():
    source = VIEWS.read_text()
    assert 'if let status = model.visibleStatus' in source
    assert 'Text(InterfaceText.status(model.status' not in source
    assert 'Text(tr(model.connected ? "Engine connected"' not in source


def test_sidebar_has_no_connected_icon_or_empty_status_row():
    sidebar = VIEWS.read_text().split("var sidebar:", 1)[1].split("@Environment(\\.colorScheme)", 1)[0]
    assert 'model.connected ? "checkmark.circle.fill"' not in sidebar
    assert 'Color.green' not in sidebar
    status_bar = VIEWS.read_text().split("private var statusBar:", 1)[1].split("private var settings:", 1)[0]
    assert 'model.connected ? .green' not in status_bar
    assert 'if let label = WorkspaceModel.sidebarStatusLabel' in sidebar


def test_interactive_smoke_is_opt_in_and_uses_isolated_preferences():
    source = APP.read_text()
    assert 'CommandLine.arguments.contains("--smoke-report")' in source
    assert 'if !CommandLine.arguments.contains("--smoke-stay-open")' in source
