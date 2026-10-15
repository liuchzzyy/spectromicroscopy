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


def test_connected_copy_is_not_rendered_in_either_status_area():
    source = VIEWS.read_text()
    assert 'if let status = model.visibleStatus' in source
    assert 'Text(InterfaceText.status(model.status' not in source
    assert 'Text(tr(model.connected ? "Engine connected"' not in source


def test_interactive_smoke_is_opt_in_and_uses_isolated_preferences():
    source = APP.read_text()
    assert 'CommandLine.arguments.contains("--smoke-report")' in source
    assert 'if !CommandLine.arguments.contains("--smoke-stay-open")' in source
