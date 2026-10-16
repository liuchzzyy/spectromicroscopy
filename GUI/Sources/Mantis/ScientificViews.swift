import SwiftUI
import Charts
import MantisCore

struct ScientificCanvas: View {
    @ObservedObject var model: WorkspaceModel
    let image: ScientificImage
    @State private var points: [CGPoint] = []
    private let inset: CGFloat = 36
    /// Compact axis/colorbar gutters leave the additional space to the image itself.
    static let colorbarRightInset: CGFloat = 72
    private var colorbarRightInset: CGFloat { image.channels == 3 ? 0 : Self.colorbarRightInset }
    /// 1.2× the previous 320 pt frame so the image reads at a usable size.
    static let canvasHeight: CGFloat = 384
    static let colorbarWidth: CGFloat = 12
    static let colorbarLabelGap: CGFloat = 4
    struct ColorbarGeometry: Equatable {
        let width: CGFloat
        let height: CGFloat
        let labelGap: CGFloat
    }
    /// The bar tracks the plotted image height instead of a fixed 205 pt, so growing
    /// the canvas grows the bar with it while keeping a readable contrast range.
    static func colorbarGeometry(plotHeight: CGFloat) -> ColorbarGeometry {
        let availableHeight = max(1, plotHeight)
        return ColorbarGeometry(width: colorbarWidth,
                                height: min(availableHeight, min(300, max(96, availableHeight * 0.78))),
                                labelGap: colorbarLabelGap)
    }
    private func axisLabel(_ axis: [Double]?, index: Int, unit: String?) -> String {
        guard let axis, axis.indices.contains(index), let unit else { return "\(index) px" }
        return String(format: "%.3f %@", axis[index], unit)
    }
    var body: some View {
        GeometryReader { geometry in
            let rect = plotRect(in: geometry.size)
            Canvas { context, size in
                context.fill(Path(rect), with: .color(.black))
                // The preview's raw extrema can be under-sampled. The engine's
                // full-visible-frame extrema define both the lookup and colorbar.
                let limits = model.displayLimits(for: image)
                let low = limits?.lower ?? 0
                let high = limits?.upper ?? 1
                let span = max(high - low, 1e-12)
                let dw = rect.width / Double(image.width), dh = rect.height / Double(image.height)
                for y in 0..<image.height {
                    for x in 0..<image.width {
                        let index = y * image.width + x
                        let color: Color
                        if image.channels == 3 {
                            color = Color(red: image.values[index * 3], green: image.values[index * 3 + 1], blue: image.values[index * 3 + 2])
                        } else {
                            let scaled = (image.values[index] - low) / span
                            let adjusted = pow(max(0, min(1, scaled)), 1 / max(0.1, model.gamma))
                            color = displayColor(adjusted)
                        }
                        context.fill(Path(CGRect(x: rect.minX + Double(x) * dw, y: rect.minY + Double(y) * dh, width: dw + 0.4, height: dh + 0.4)), with: .color(color))
                    }
                }
                let stroke = Color.white.opacity(0.9)
                // Canvas graphics are plotted in the visible source interval, not
                // the full data bounds, so ROI overlays remain aligned when zoomed.
                // Render all saved multi-ROIs with their assigned colors and number badges
                for roi in model.rois {
                    let color = Color(hex: roi.colorHex)
                    let isSelected = roi.index == model.selectedROIIndex
                    let roiPath: Path
                    let badgeOrigin: CGPoint
                    if let polygon = roi.polygon {
                        var path = Path()
                        path.addLines(polygon.map { screen(x: $0[0], y: $0[1], rect: rect) })
                        path.closeSubpath()
                        roiPath = path
                        badgeOrigin = screen(x: polygon[0][0], y: polygon[0][1], rect: rect)
                    } else {
                        let p0 = screen(x: Double(roi.bounds[0]), y: Double(roi.bounds[1]), rect: rect)
                        let p1 = screen(x: Double(roi.bounds[2]), y: Double(roi.bounds[3]), rect: rect)
                        roiPath = Path(CGRect(x: min(p0.x, p1.x), y: min(p0.y, p1.y),
                                              width: max(2, abs(p1.x-p0.x)), height: max(2, abs(p1.y-p0.y))))
                        badgeOrigin = p0
                    }
                    if isSelected { context.fill(roiPath, with: .color(color.opacity(0.18))) }
                    context.stroke(roiPath, with: .color(color), style: StrokeStyle(lineWidth: isSelected ? 2.5 : 1.5, dash: isSelected ? [6, 2] : [4, 3]))
                    let badgeRect = CGRect(x: badgeOrigin.x + 2, y: badgeOrigin.y + 2, width: 16, height: 16)
                    context.fill(Path(roundedRect: badgeRect, cornerRadius: 3), with: .color(color))
                    context.draw(Text("\(roi.index)").font(.system(size: 10, weight: .bold)).foregroundColor(.white), at: CGPoint(x: badgeRect.midX, y: badgeRect.midY), anchor: .center)
                }

                if let bounds = model.rectangle, bounds.count == 4 {
                    let p0 = screen(x: Double(bounds[0]), y: Double(bounds[1]), rect: rect)
                    let p1 = screen(x: Double(bounds[2]), y: Double(bounds[3]), rect: rect)
                    context.stroke(Path(CGRect(x: min(p0.x,p1.x), y: min(p0.y,p1.y), width: abs(p1.x-p0.x), height: abs(p1.y-p0.y))), with: .color(.yellow), style: StrokeStyle(lineWidth: 1.5, dash: [5,3]))
                }
                if let polygon = model.polygon, polygon.count > 2 {
                    var path = Path(); path.addLines(polygon.map { screen(x: $0[0], y: $0[1], rect: rect) }); path.closeSubpath()
                    context.stroke(path, with: .color(stroke), lineWidth: 1.5)
                }
                if let s = model.snapshot, model.rois.isEmpty {
                    let p = screen(x: Double(s.selected_x) + 0.5, y: Double(s.selected_y) + 0.5, rect: rect)
                    var path = Path(); path.move(to: CGPoint(x: p.x - 7, y: p.y)); path.addLine(to: CGPoint(x: p.x + 7, y: p.y)); path.move(to: CGPoint(x: p.x, y: p.y - 7)); path.addLine(to: CGPoint(x: p.x, y: p.y + 7))
                    context.stroke(path, with: .color(.white), lineWidth: 1.5)
                }
                if let pending = model.pendingPixel, model.roiMode == "Pixel" {
                    let p = screen(x: Double(pending[0]) + 0.5, y: Double(pending[1]) + 0.5, rect: rect)
                    context.stroke(Path(ellipseIn: CGRect(x: p.x - 5, y: p.y - 5, width: 10, height: 10)), with: .color(.yellow), lineWidth: 2)
                }
                if let first = points.first, let last = points.last {
                    var path = Path()
                    if model.roiMode == "Rectangle" { path.addRect(CGRect(x: min(first.x,last.x), y: min(first.y,last.y), width: abs(last.x-first.x), height: abs(last.y-first.y))) }
                    else { path.addLines(points) }
                    context.stroke(path, with: .color(.yellow), lineWidth: 1.5)
                }
                let spatial = model.snapshot?.spatial
                let unit = model.spatialDisplay == "physical" ? spatial?.unit : nil
                let xStart = axisLabel(spatial?.x, index: image.x0, unit: unit)
                let xEnd = axisLabel(spatial?.x, index: image.x0 + image.visibleWidth - 1, unit: unit)
                let yStart = axisLabel(spatial?.y, index: image.y0, unit: unit)
                let yEnd = axisLabel(spatial?.y, index: image.y0 + image.visibleHeight - 1, unit: unit)
                context.draw(Text(xStart).font(.caption2).foregroundColor(.secondary), at: CGPoint(x: rect.minX, y: rect.maxY + 15), anchor: .leading)
                context.draw(Text(xEnd).font(.caption2).foregroundColor(.secondary), at: CGPoint(x: rect.maxX, y: rect.maxY + 15), anchor: .trailing)
                context.draw(Text("X").font(.caption2).foregroundColor(.secondary), at: CGPoint(x: rect.midX, y: rect.maxY + 15))
                var yStartCtx = context
                yStartCtx.translateBy(x: rect.minX - 12, y: rect.minY)
                yStartCtx.rotate(by: .degrees(-90))
                yStartCtx.draw(Text(yStart).font(.caption2).foregroundColor(.secondary), at: .zero, anchor: .trailing)

                var yEndCtx = context
                yEndCtx.translateBy(x: rect.minX - 12, y: rect.maxY)
                yEndCtx.rotate(by: .degrees(-90))
                yEndCtx.draw(Text(yEnd).font(.caption2).foregroundColor(.secondary), at: .zero, anchor: .leading)

                var yTitleCtx = context
                yTitleCtx.translateBy(x: rect.minX - 26, y: rect.midY)
                yTitleCtx.rotate(by: .degrees(-90))
                yTitleCtx.draw(Text("Y").font(.caption2).foregroundColor(.secondary), at: .zero, anchor: .center)

                drawScaleBar(in: rect, context: &context, image: image)
                if let limits {
                    let geometry = Self.colorbarGeometry(plotHeight: rect.height)
                    let bar = CGRect(x: rect.maxX + 11, y: rect.midY - geometry.height / 2,
                                     width: geometry.width, height: geometry.height)
                    let segments = 64
                    for step in 0..<segments {
                        let t = (Double(step) + 0.5) / Double(segments)
                        context.fill(Path(CGRect(x: bar.minX, y: bar.maxY - CGFloat(step + 1) * bar.height / CGFloat(segments),
                                                 width: bar.width, height: bar.height / CGFloat(segments) + 0.6)),
                                     with: .color(displayColor(pow(t, 1 / max(0.1, model.gamma)))))
                    }
                    context.stroke(Path(bar), with: .color(.secondary), lineWidth: 0.7)
                    context.draw(Text(String(format: "%.3g", limits.upper)).font(.caption2.monospacedDigit()),
                                 at: CGPoint(x: bar.maxX + geometry.labelGap, y: bar.minY), anchor: .leading)
                    context.draw(Text(String(format: "%.3g", limits.lower)).font(.caption2.monospacedDigit()),
                                 at: CGPoint(x: bar.maxX + geometry.labelGap, y: bar.maxY), anchor: .leading)
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                guard !model.busy, rect.contains(value.startLocation) else { return }
                let clamped = CGPoint(x: min(rect.maxX, max(rect.minX, value.location.x)), y: min(rect.maxY, max(rect.minY, value.location.y)))
                if points.isEmpty { points = [value.startLocation] }
                if model.roiMode == "Lasso" { points.append(clamped) }
                else { points = [value.startLocation, clamped] }
                model.interactionPoint = pixel(clamped, rect: rect)
            }.onEnded { value in
                defer { points = [] }
                guard !model.busy, rect.contains(value.startLocation) else { return }
                let first = pixel(value.startLocation, rect: rect)
                let last = pixel(value.location, rect: rect)
                model.interactionPoint = last
                switch model.roiMode {
                case "Rectangle":
                    model.pendingPixel = nil
                    model.polygon = nil
                    let b = [min(first.0,last.0), min(first.1,last.1), min(image.full_width,max(first.0,last.0)+1), min(image.full_height,max(first.1,last.1)+1)]
                    model.rectangle = b[2] > b[0] && b[3] > b[1] ? b : nil
                case "Lasso":
                    model.pendingPixel = nil
                    model.rectangle = nil
                    if points.count >= 3 {
                        model.polygon = points.map { p in
                            let xy = pixel(p, rect: rect)
                            return [Double(xy.0) + 0.5, Double(xy.1) + 0.5]
                        }
                    } else { model.polygon = nil }
                default:
                    model.pendingPixel = [last.0, last.1]
                    model.rectangle = nil
                    model.polygon = nil
                }
                model.updateView(x: last.0, y: last.1)
            })
            .accessibilityLabel("\(image.title), visible x \(image.x0) to \(image.x0 + image.visibleWidth - 1), y \(image.y0) to \(image.y0 + image.visibleHeight - 1) pixels")
            .accessibilityHint("Choose Pixel, Rectangle or Lasso, then click or drag to inspect spectra.")
            .onTapGesture(count: 2) { location in
                guard rect.contains(location), !model.busy else { return }
                let (x, y) = pixel(location, rect: rect)
                model.interactionPoint = (x, y)
                if let hit = model.rois.first(where: { x >= $0.bounds[0] && x < $0.bounds[2] && y >= $0.bounds[1] && y < $0.bounds[3] }) {
                    model.selectedROIIndex = hit.index
                }
                model.zoom(to: min(16, model.zoomLevel * 2), centerX: x, centerY: y)
            }
        }
    }
    func plotRect(in size: CGSize) -> CGRect {
        let maxWidth = max(1, size.width - inset * 2 - colorbarRightInset), maxHeight = max(1, size.height - inset * 2)
        var aspect = Double(image.visibleWidth) / Double(image.visibleHeight)
        if model.spatialDisplay == "physical", let spatial = model.snapshot?.spatial,
           spatial.unit != nil, spatial.x.indices.contains(image.x0 + image.visibleWidth - 1),
           spatial.y.indices.contains(image.y0 + image.visibleHeight - 1) {
            let xSpan = abs(spatial.x[image.x0 + image.visibleWidth - 1] - spatial.x[image.x0])
            let ySpan = abs(spatial.y[image.y0 + image.visibleHeight - 1] - spatial.y[image.y0])
            if xSpan > 0 && ySpan > 0 { aspect = (xSpan + xSpan / Double(max(1, image.visibleWidth - 1))) / (ySpan + ySpan / Double(max(1, image.visibleHeight - 1))) }
        }
        let width = min(maxWidth, maxHeight * aspect), height = width / aspect
        return CGRect(x: (size.width - colorbarRightInset - width) / 2, y: (size.height - height) / 2, width: width, height: height)
    }
    public struct ScaleBarResult: Equatable {
        public let label: String
        public let barLengthPoints: CGFloat
        public init(label: String, barLengthPoints: CGFloat) {
            self.label = label
            self.barLengthPoints = barLengthPoints
        }
    }
    public static func calculateScaleBar(visibleWidth: Int, plotWidth: CGFloat, physicalPerPixelNm: Double? = nil) -> ScaleBarResult {
        let width = Double(max(1, visibleWidth))
        let pointsPerDataPixel = Double(plotWidth) / width
        if let nmPerPixel = physicalPerPixelNm, nmPerPixel > 0 {
            let targetNm = 0.22 * width * nmPerPixel
            let ladderNm: [(nm: Double, label: String)] = [
                (1, "1 nm"), (2, "2 nm"), (5, "5 nm"),
                (10, "10 nm"), (20, "20 nm"), (50, "50 nm"),
                (100, "100 nm"), (200, "200 nm"), (500, "500 nm"),
                (1_000, "1 µm"), (2_000, "2 µm"), (5_000, "5 µm"),
                (10_000, "10 µm"), (20_000, "20 µm"), (50_000, "50 µm"),
                (100_000, "100 µm"), (200_000, "200 µm"), (500_000, "500 µm"),
                (1_000_000, "1 mm"), (2_000_000, "2 mm"), (5_000_000, "5 mm")
            ]
            let best = ladderNm.min(by: { abs($0.nm - targetNm) < abs($1.nm - targetNm) }) ?? (1_000, "1 µm")
            let pixelsForBar = best.nm / nmPerPixel
            let points = pixelsForBar * pointsPerDataPixel
            return ScaleBarResult(label: best.label, barLengthPoints: CGFloat(points))
        } else {
            let targetPx = 0.22 * width
            let ladderPx: [Double] = [1, 2, 5, 10, 20, 50, 100, 200, 500, 1000, 2000, 5000]
            let bestPx = ladderPx.min(by: { abs($0 - targetPx) < abs($1 - targetPx) }) ?? 10
            let points = bestPx * pointsPerDataPixel
            return ScaleBarResult(label: "\(Int(bestPx)) px", barLengthPoints: CGFloat(points))
        }
    }
    private func drawScaleBar(in rect: CGRect, context: inout GraphicsContext, image: ScientificImage) {
        let nmPerPixel: Double? = {
            guard let spatial = model.snapshot?.spatial, let unit = spatial.unit,
                  spatial.x.indices.contains(image.x0),
                  spatial.x.indices.contains(image.x0 + image.visibleWidth - 1),
                  image.visibleWidth > 1 else { return nil }
            let span = abs(spatial.x[image.x0 + image.visibleWidth - 1] - spatial.x[image.x0])
            let perPixel = span / Double(image.visibleWidth - 1)
            guard perPixel > 0 else { return nil }
            if unit == "µm" || unit == "μm" || unit == "um" { return perPixel * 1000.0 }
            return perPixel
        }()
        let scaleBar = Self.calculateScaleBar(visibleWidth: image.visibleWidth, plotWidth: rect.width, physicalPerPixelNm: nmPerPixel)
        let barLen = min(rect.width * 0.45, max(24, scaleBar.barLengthPoints))
        let barX = rect.maxX - barLen - 12
        let barY = rect.maxY - 14
        // Direct scale bar without black enclosing background box, using subtle drop-shadow for contrast
        context.fill(Path(CGRect(x: barX, y: barY + 0.8, width: barLen, height: 2.5)), with: .color(.black.opacity(0.6)))
        context.fill(Path(CGRect(x: barX, y: barY, width: barLen, height: 2.5)), with: .color(.white))
        let labelText = Text(scaleBar.label).font(.system(size: 10, weight: .bold))
        context.draw(labelText.foregroundColor(.black.opacity(0.6)), at: CGPoint(x: barX + barLen / 2 + 0.5, y: barY - 6.5), anchor: .center)
        context.draw(labelText.foregroundColor(.white), at: CGPoint(x: barX + barLen / 2, y: barY - 7), anchor: .center)
    }
    func pixel(_ p: CGPoint, rect: CGRect) -> (Int, Int) {
        (min(image.x0 + image.visibleWidth - 1, max(image.x0, image.x0 + Int((p.x - rect.minX) / rect.width * Double(image.visibleWidth)))),
         min(image.y0 + image.visibleHeight - 1, max(image.y0, image.y0 + Int((p.y - rect.minY) / rect.height * Double(image.visibleHeight)))))
    }
    private func screen(x: Double, y: Double, rect: CGRect) -> CGPoint {
        CGPoint(x: rect.minX + (x - Double(image.x0)) / Double(image.visibleWidth) * rect.width,
                y: rect.minY + (y - Double(image.y0)) / Double(image.visibleHeight) * rect.height)
    }
    private func displayColor(_ value: Double) -> Color {
        switch model.colorMap {
        case "Grayscale": return Color(white: value)
        case "Diverging": return value < 0.5 ? Color(red: value * 2, green: value * 2, blue: 1) : Color(red: 1, green: (1-value)*2, blue: (1-value)*2)
        default:
            let stops: [(Double,Double,Double)] = [(0.267,0.005,0.329),(0.230,0.322,0.546),(0.128,0.567,0.551),(0.369,0.789,0.383),(0.993,0.906,0.144)]
            let pos = value * 4, i = min(3,Int(pos)), t = pos - Double(i)
            let a = stops[i], b = stops[i+1]
            return Color(red: a.0+(b.0-a.0)*t, green: a.1+(b.1-a.1)*t, blue: a.2+(b.2-a.2)*t)
        }
    }
}

public enum ChartZoomMode: String, CaseIterable, Identifiable {
    case original = "Original"
    case fit = "Fit Data"
    case box = "Box Zoom"
    public var id: String { rawValue }
}

/// One aligned group of four icon controls (three zoom modes plus reset). The reset
/// control used to float separately with a faint glyph; grouping it at a uniform size
/// with a circle-backed symbol keeps it legible and adjacent to the modes.
struct ChartToolbar: View {
    @EnvironmentObject private var preferences: InterfacePreferences
    private func tr(_ key: String) -> String { InterfaceText.value(key, language: preferences.language) }
    @Binding var mode: ChartZoomMode
    let reset: () -> Void

    static func symbol(for mode: ChartZoomMode) -> String {
        switch mode {
        case .original: "1.magnifyingglass"
        case .fit: "arrow.up.left.and.arrow.down.right"
        case .box: "rectangle.dashed"
        }
    }
    static let resetSymbol = "arrow.counterclockwise.circle"
    static var allSymbols: [String] { ChartZoomMode.allCases.map(symbol(for:)) + [resetSymbol] }
    static let buttonWidth: CGFloat = 30
    static let buttonHeight: CGFloat = 24
    static let groupSpacing: CGFloat = 0

    var body: some View {
        HStack(spacing: Self.groupSpacing) {
            ForEach(ChartZoomMode.allCases) { candidate in
                Button { mode = candidate } label: {
                    Image(systemName: Self.symbol(for: candidate))
                        .font(.system(size: 14, weight: .medium))
                        .frame(width: Self.buttonWidth, height: Self.buttonHeight)
                        .contentShape(Rectangle())
                        .background(mode == candidate ? Theme.accent.opacity(0.22) : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 5))
                        .foregroundStyle(mode == candidate ? Theme.accent : Color.secondary)
                }
                .buttonStyle(.plain)
                .help(tr(candidate.rawValue))
                .accessibilityLabel(tr(candidate.rawValue))
                .accessibilityAddTraits(mode == candidate ? .isSelected : [])
            }
            Divider().frame(height: Self.buttonHeight - 6)
            Button(action: reset) {
                Image(systemName: Self.resetSymbol)
                    .font(.system(size: 14, weight: .medium))
                    .frame(width: Self.buttonWidth, height: Self.buttonHeight)
                    .contentShape(Rectangle())
                    .foregroundStyle(.primary)
            }
            .buttonStyle(.plain)
            // Reset is deliberately available even at the default scale: its
            // recognizable glyph should never fade into the chart background.
            .help(tr("Reset Zoom"))
            .accessibilityLabel(tr("Reset Zoom"))
        }
        .padding(2)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.secondary.opacity(0.22), lineWidth: 0.7))
    }
}

struct SpectrumSeriesMarks: ChartContent {
    let spectrum: Spectrum
    let color: Color
    var body: some ChartContent {
        ForEach(Array(spectrum.x.indices), id: \.self) { i in
            LineMark(
                x: .value("Axis", spectrum.x[i]),
                y: .value("Signal", spectrum.y[i]),
                series: .value("Series", spectrum.name)
            )
            .foregroundStyle(color)
        }
    }
}

struct SpectraChart: View {
    @EnvironmentObject private var preferences: InterfacePreferences
    private func tr(_ key: String) -> String { InterfaceText.value(key, language: preferences.language) }
    let spectra: [Spectrum]
    let image: ScientificImage?
    let selectedEnergy: Double?
    var display: String = "intensity"
    let selectEnergy: (Double) -> Void
    var roiColors: [String: String] = [:]
    @Binding var selectedSeries: String
    var activeSeriesLabel: String? = nil
    var selectionDisabled = false

    // Zoom modes for spectral chart
    @State private var zoomMode: ChartZoomMode = .fit
    @State private var customDomainX: ClosedRange<Double>? = nil
    @State private var customDomainY: ClosedRange<Double>? = nil
    @State private var dragBoxStart: CGPoint? = nil
    @State private var dragBoxCurrent: CGPoint? = nil

    // Zoom modes for histogram
    @State private var histZoomMode: ChartZoomMode = .fit
    @State private var customHistX: ClosedRange<Double>? = nil
    @State private var customHistY: ClosedRange<Double>? = nil
    @State private var histDragStart: CGPoint? = nil
    @State private var histDragCurrent: CGPoint? = nil

    struct HistogramSelection {
        let counts: [Int]
        let edges: [Double]
        let minimum: Double
        let maximum: Double
        let mean: Double
        let title: String
        let help: String
    }
    /// Use full-resolution engine statistics for images/ROIs. A selected pixel is
    /// one measured value at the selected energy, not a distribution over energies.
    static func selectedHistogram(image: ScientificImage?, spectra: [Spectrum], selectedSeries: String,
                                  selectedEnergy: Double?, activeROI: String?) -> HistogramSelection? {
        guard let image else { return nil }
        if selectedSeries == "Pixel", let pixel = spectra.first(where: { $0.name == "Pixel" }),
           let energy = selectedEnergy,
           let index = pixel.x.indices.min(by: { abs(pixel.x[$0] - energy) < abs(pixel.x[$1] - energy) }),
           pixel.y.indices.contains(index) {
            let value = pixel.y[index], halfWidth = max(0.5, abs(value) * 0.01)
            return HistogramSelection(counts: [1], edges: [value - halfWidth, value + halfWidth],
                                      minimum: value, maximum: value, mean: value,
                                      title: "Selected pixel · signal at current energy",
                                      help: "One source pixel at the selected photon energy.")
        }
        let useROI = activeROI != nil && activeROI == selectedSeries
        guard useROI || ["All spectra", "Full image"].contains(selectedSeries) || image.title == selectedSeries else { return nil }
        guard let counts = useROI ? image.roi_histogram_counts : image.histogram_counts,
              let edges = useROI ? image.roi_histogram_edges : image.histogram_edges,
              counts.count + 1 == edges.count,
              let minimum = useROI ? image.roi_minimum : image.minimum,
              let maximum = useROI ? image.roi_maximum : image.maximum,
              let mean = useROI ? image.roi_mean : image.mean else { return nil }
        return HistogramSelection(counts: counts, edges: edges, minimum: minimum, maximum: maximum, mean: mean,
                                  title: useROI ? "Selected ROI pixels · signal distribution" : "Visible image pixels · signal distribution",
                                  help: useROI ? "ROI histogram covers all source pixels selected by the ROI." : "Histogram covers every source pixel in the current view, not the sampled preview.")
    }
    static let histogramMinimumBarPoints: CGFloat = 4
    struct HistogramBin: Identifiable {
        let index: Int
        let low: Double
        let high: Double
        let count: Int
        var id: Int { index }
    }
    static func histogramBins(counts: [Int], edges: [Double]) -> [HistogramBin] {
        guard counts.count + 1 == edges.count else { return [] }
        return counts.indices.map { HistogramBin(index: $0, low: edges[$0], high: edges[$0 + 1], count: counts[$0]) }
    }
    static func zoomedSpectra(_ spectra: [Spectrum], x: ClosedRange<Double>?, y: ClosedRange<Double>?) -> [Spectrum] {
        guard x != nil || y != nil else { return spectra }
        return spectra.map { spectrum in
            let samples = zip(spectrum.x, spectrum.y).filter { point in
                (x.map { $0.contains(point.0) } ?? true) && (y.map { $0.contains(point.1) } ?? true)
            }
            return Spectrum(name: spectrum.name, x: samples.map(\.0), y: samples.map(\.1))
        }
    }
    static func zoomedBins(_ bins: [HistogramBin], x: ClosedRange<Double>?, y: ClosedRange<Double>?) -> [HistogramBin] {
        bins.filter { bin in
            let center = (bin.low + bin.high) / 2
            // A histogram bar spans [0, count], so a box intersecting only
            // part of the bar must still render it, clipped to the plot area.
            return (x.map { $0.contains(center) } ?? true) &&
                   (y.map { $0.upperBound >= 0 && $0.lowerBound <= Double(bin.count) } ?? true)
        }
    }
    static func domain(for spectra: [Spectrum]) -> (x: ClosedRange<Double>, y: ClosedRange<Double>)? {
        let x = spectra.flatMap(\.x), y = spectra.flatMap(\.y)
        guard let xMin = x.min(), let xMax = x.max(), let yMin = y.min(), let yMax = y.max() else { return nil }
        return (xMin == xMax ? xMin - 0.5...xMax + 0.5 : xMin...xMax,
                yMin == yMax ? yMin - 0.5...yMax + 0.5 : yMin...yMax)
    }
    static func resolvedSeries(_ selected: String, in spectra: [Spectrum]) -> String {
        selected == "All spectra" || spectra.contains(where: { $0.name == selected }) ? selected : "All spectra"
    }
    private var visible: [Spectrum] {
        let selection = Self.resolvedSeries(selectedSeries, in: spectra)
        return selection == "All spectra" ? spectra : spectra.filter { $0.name == selection }
    }
    private var renderedSpectra: [Spectrum] {
        Self.zoomedSpectra(visible, x: zoomMode == .box ? customDomainX : nil,
                           y: zoomMode == .box ? customDomainY : nil)
    }
    private var summary: (minimum: Double, maximum: Double, mean: Double)? {
        let values = renderedSpectra.flatMap(\.y)
        guard let minimum = values.min(), let maximum = values.max(), !values.isEmpty else { return nil }
        return (minimum, maximum, values.reduce(0, +) / Double(values.count))
    }
    private func curveColor(for name: String) -> Color {
        if let hex = roiColors[name] { return Color(hex: hex) }
        for k in 1...10 {
            if name.contains("[\(k)]") || name == "ROI \(k)" {
                return Color(hex: ROIPresets.colors[(k - 1) % ROIPresets.colors.count])
            }
        }
        if name == "Pixel" { return Color(red: 0.1, green: 0.7, blue: 0.9) }
        if name == "ROI mean" { return Color.yellow }
        return Theme.accent
    }
    private var currentXDomain: ClosedRange<Double> {
        if let custom = customDomainX, zoomMode == .box { return custom }
        let allX = visible.flatMap(\.x)
        guard let xMin = allX.min(), let xMax = allX.max(), xMax > xMin else { return 0...1 }
        switch zoomMode {
        case .original:
            let gX = spectra.flatMap(\.x)
            return (gX.min() ?? xMin)...(gX.max() ?? xMax)
        case .fit, .box:
            let dx = max(1e-4, (xMax - xMin) * 0.03)
            return (xMin - dx)...(xMax + dx)
        }
    }
    private var currentYDomain: ClosedRange<Double> {
        if let custom = customDomainY, zoomMode == .box { return custom }
        let allY = visible.flatMap(\.y)
        guard let yMin = allY.min(), let yMax = allY.max(), yMax > yMin else { return 0...1 }
        switch zoomMode {
        case .original:
            let gY = spectra.flatMap(\.y)
            let gMin = min(0, gY.min() ?? yMin)
            let gMax = (gY.max() ?? yMax) * 1.05
            return gMin...gMax
        case .fit, .box:
            let dy = max(1e-5, (yMax - yMin) * 0.05)
            return (yMin - dy)...(yMax + dy)
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Label(tr("Spectral analysis"), systemImage: "waveform.path")
                        .font(.headline).fixedSize(horizontal: true, vertical: false)
                    // The series box belongs beside its title, not on a row of its own.
                    if !spectra.isEmpty {
                        Picker(tr("Series"), selection: $selectedSeries) {
                            Text(tr("All spectra")).tag("All spectra")
                            ForEach(spectra) { Text(tr($0.name)).tag($0.name) }
                        }
                        .labelsHidden().frame(maxWidth: 180)
                        .disabled(selectionDisabled)
                        .accessibilityIdentifier("spectra.series.picker")
                    }
                    Spacer(minLength: 0)
                }
            }
            if spectra.isEmpty {
                ContentUnavailableView(tr("No spectrum yet"), systemImage: "waveform.path", description: Text(tr("Open a stack or run an analysis to inspect its spectra.")))
            } else {
                if let summary {
                    HStack(spacing: 12) {
                        Text(String(format: "%@: %.3g", tr("Min"), summary.minimum))
                        Text(String(format: "%@: %.3g", tr("Max"), summary.maximum))
                        Text(String(format: "%@: %.3g", tr("Mean"), summary.mean))
                    }.font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    .accessibilityLabel(tr("Visible series: minimum, maximum and mean"))
                }
                Text(tr("Selected spectrum · signal vs energy")).font(.caption.weight(.semibold))
                Chart {
                    ForEach(renderedSpectra) { spectrum in
                        SpectrumSeriesMarks(spectrum: spectrum, color: curveColor(for: spectrum.name))
                    }
                    if let selectedEnergy, customDomainX == nil || currentXDomain.contains(selectedEnergy) {
                        RuleMark(x: .value("Selected energy", selectedEnergy))
                            .foregroundStyle(.secondary.opacity(0.5))
                            .lineStyle(StrokeStyle(dash: [4, 4]))
                    }
                }
                .chartXScale(domain: currentXDomain)
                .chartYScale(domain: currentYDomain)
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 3)) { value in
                        AxisGridLine()
                        AxisTick()
                        AxisValueLabel(anchor: value.index == 0 ? .topLeading : .topTrailing)
                    }
                }
                .frame(minHeight: 250)
                .chartXAxisLabel(tr(axisLabel))
                .chartYAxisLabel(display == "od" ? tr("Optical density") : tr("Intensity"))
                .chartOverlay { proxy in
                    GeometryReader { geo in
                        ZStack(alignment: .topLeading) {
                            Color.clear
                                .contentShape(Rectangle())
                                .gesture(
                                    DragGesture(minimumDistance: 4)
                                        .onChanged { val in
                                            if zoomMode == .box {
                                                if dragBoxStart == nil { dragBoxStart = val.startLocation }
                                                dragBoxCurrent = val.location
                                            }
                                        }
                                        .onEnded { val in
                                            if zoomMode == .box {
                                                defer { dragBoxStart = nil; dragBoxCurrent = nil }
                                                guard let frame = proxy.plotFrame else { return }
                                                let ox = geo[frame].origin.x, oy = geo[frame].origin.y
                                                let p0 = CGPoint(x: val.startLocation.x - ox, y: val.startLocation.y - oy)
                                                let p1 = CGPoint(x: val.location.x - ox, y: val.location.y - oy)
                                                let minX = min(p0.x, p1.x), maxX = max(p0.x, p1.x)
                                                let minY = min(p0.y, p1.y), maxY = max(p0.y, p1.y)
                                                if maxX - minX > 8, maxY - minY > 8,
                                                   let x1: Double = proxy.value(atX: minX),
                                                   let x2: Double = proxy.value(atX: maxX),
                                                   let y1: Double = proxy.value(atY: maxY),
                                                   let y2: Double = proxy.value(atY: minY),
                                                   x2 > x1, y2 > y1 {
                                                    customDomainX = x1...x2
                                                    customDomainY = y1...y2
                                                }
                                            } else {
                                                guard let frame = proxy.plotFrame else { return }
                                                let x = val.location.x - geo[frame].origin.x
                                                if let energy: Double = proxy.value(atX: x) { selectEnergy(energy) }
                                            }
                                        }
                                )
                            if let s = dragBoxStart, let c = dragBoxCurrent {
                                let r = CGRect(x: min(s.x, c.x), y: min(s.y, c.y), width: abs(c.x - s.x), height: abs(c.y - s.y))
                                Rectangle()
                                    .fill(Theme.accent.opacity(0.2))
                                    .overlay(Rectangle().stroke(Theme.accent, style: StrokeStyle(lineWidth: 1.5, dash: [4, 2])))
                                    .frame(width: r.width, height: r.height)
                                    .offset(x: r.minX, y: r.minY)
                                    .allowsHitTesting(false)
                            }
                        }
                    }
                }
                .padding(.top, ChartToolbar.buttonHeight + 12)
                .padding(.trailing, 8)
                .overlay(alignment: .topLeading) {
                    ChartToolbar(mode: $zoomMode) {
                        customDomainX = nil
                        customDomainY = nil
                        zoomMode = .fit
                    }
                    .padding(6)
                    .accessibilityIdentifier("spectra.zoom.toolbar")
                }

                // Legend
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(renderedSpectra) { spec in
                            HStack(spacing: 4) {
                                RoundedRectangle(cornerRadius: 2).fill(curveColor(for: spec.name)).frame(width: 14, height: 3)
                                Text(tr(spec.name)).font(.caption2)
                            }
                        }
                    }
                    .padding(.horizontal, 4)
                }
            }
            if !selectionDisabled, let histogram = Self.selectedHistogram(
                image: image, spectra: spectra, selectedSeries: selectedSeries,
                selectedEnergy: selectedEnergy, activeROI: activeSeriesLabel) {
                let counts = histogram.counts, edges = histogram.edges
                let minimum = histogram.minimum, maximum = histogram.maximum, mean = histogram.mean
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Text(tr(histogram.title))
                            .font(.callout.weight(.medium))
                            .help(tr(histogram.help))
                        // Same dataset as the spectra above: the histogram names the ROI it summarizes.
                        if let activeSeriesLabel, activeSeriesLabel == selectedSeries {
                            Text(tr(activeSeriesLabel)).font(.caption.monospaced())
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Theme.accent.opacity(0.12), in: Capsule())
                                .foregroundStyle(Theme.accent)
                        }
                        Spacer(minLength: 0)
                    }
                    HStack(spacing: 12) {
                        Text(String(format: "%@: %.3g", tr("Min"), minimum))
                        Text(String(format: "%@: %.3g", tr("Max"), maximum))
                        Text(String(format: "%@: %.3g", tr("Mean"), mean))
                    }.font(.caption.monospacedDigit()).foregroundStyle(.secondary)

                    let eMin = edges.first ?? 0.0, eMax = edges.last ?? 1.0
                    let cMax = Double(counts.max() ?? 1)
                    let histX: ClosedRange<Double> = {
                        if let custom = customHistX, histZoomMode == .box { return custom }
                        if histZoomMode == .fit {
                            let nonzeroIndices = counts.indices.filter { counts[$0] > 0 }
                            if let first = nonzeroIndices.first, let last = nonzeroIndices.last {
                                let fitMin = edges[first], fitMax = edges[last + 1]
                                let d = max(1e-4, (fitMax - fitMin) * 0.04)
                                return (fitMin - d)...(fitMax + d)
                            }
                        }
                        return eMin...eMax
                    }()
                    let histY: ClosedRange<Double> = {
                        if let custom = customHistY, histZoomMode == .box { return custom }
                        return 0...(cMax * 1.08)
                    }()

                    Chart {
                        ForEach(Self.zoomedBins(Self.histogramBins(counts: counts, edges: edges),
                                                x: histZoomMode == .box ? customHistX : nil,
                                                y: histZoomMode == .box ? customHistY : nil)) { bin in
                            BarMark(x: .value("Bin center", (bin.low + bin.high) / 2),
                                    y: .value("Pixels", bin.count),
                                    width: .fixed(Self.histogramMinimumBarPoints))
                                .foregroundStyle(Theme.accent)
                        }
                    }
                    .chartXScale(domain: histX)
                    .chartYScale(domain: histY)
                    .chartXAxis {
                        AxisMarks(values: .automatic(desiredCount: 3)) { value in
                            AxisGridLine()
                            AxisTick()
                            AxisValueLabel {
                                if let v = value.as(Double.self) {
                                    Text(String(format: "%.2g", v)).font(.caption2.monospacedDigit())
                                }
                            }
                        }
                    }
                    .chartYAxis {
                        AxisMarks(values: .automatic(desiredCount: 4)) { value in
                            AxisGridLine()
                            AxisTick()
                            AxisValueLabel {
                                if let v = value.as(Double.self) {
                                    if v >= 1000 {
                                        Text(String(format: "%.1fk", v / 1000.0)).font(.caption2.monospacedDigit())
                                    } else {
                                        Text("\(Int(v))").font(.caption2.monospacedDigit())
                                    }
                                }
                            }
                        }
                    }
                    .chartXAxisLabel(display == "od" ? tr("Optical density") : tr("Intensity"))
                    .chartYAxisLabel(tr("Pixels"))
                    .frame(height: 175)
                    .chartOverlay { proxy in
                        GeometryReader { geo in
                            ZStack(alignment: .topLeading) {
                                Color.clear
                                    .contentShape(Rectangle())
                                    .gesture(
                                        DragGesture(minimumDistance: 4)
                                            .onChanged { val in
                                                if histZoomMode == .box {
                                                    if histDragStart == nil { histDragStart = val.startLocation }
                                                    histDragCurrent = val.location
                                                }
                                            }
                                            .onEnded { val in
                                                if histZoomMode == .box {
                                                    defer { histDragStart = nil; histDragCurrent = nil }
                                                    guard let frame = proxy.plotFrame else { return }
                                                    let ox = geo[frame].origin.x, oy = geo[frame].origin.y
                                                    let p0 = CGPoint(x: val.startLocation.x - ox, y: val.startLocation.y - oy)
                                                    let p1 = CGPoint(x: val.location.x - ox, y: val.location.y - oy)
                                                    let minX = min(p0.x, p1.x), maxX = max(p0.x, p1.x)
                                                    let minY = min(p0.y, p1.y), maxY = max(p0.y, p1.y)
                                                    if maxX - minX > 8, maxY - minY > 8,
                                                       let x1: Double = proxy.value(atX: minX),
                                                       let x2: Double = proxy.value(atX: maxX),
                                                       let y1: Double = proxy.value(atY: maxY),
                                                       let y2: Double = proxy.value(atY: minY),
                                                       x2 > x1, y2 > y1 {
                                                        customHistX = x1...x2
                                                        customHistY = y1...y2
                                                    }
                                                }
                                            }
                                    )
                                if let s = histDragStart, let c = histDragCurrent {
                                    let r = CGRect(x: min(s.x, c.x), y: min(s.y, c.y), width: abs(c.x - s.x), height: abs(c.y - s.y))
                                    Rectangle()
                                        .fill(Theme.accent.opacity(0.2))
                                        .overlay(Rectangle().stroke(Theme.accent, style: StrokeStyle(lineWidth: 1.5, dash: [4, 2])))
                                        .frame(width: r.width, height: r.height)
                                        .offset(x: r.minX, y: r.minY)
                                        .allowsHitTesting(false)
                                }
                            }
                        }
                    }
                    .padding(.top, ChartToolbar.buttonHeight + 12)
                    .padding(.trailing, 8)
                    .overlay(alignment: .topLeading) {
                        ChartToolbar(mode: $histZoomMode) {
                            customHistX = nil
                            customHistY = nil
                            histZoomMode = .fit
                        }
                        .padding(6)
                        .accessibilityIdentifier("histogram.zoom.toolbar")
                    }
                }
            }
        }.padding(16)
    }
    private var axisLabel: String {
        let names = visible.map(\.name).joined(separator: " ").lowercased()
        if names.contains("convergence") || names.contains("cost") { return "Iteration" }
        if names.contains("eigenvalue") && visible.count == 1 { return "Component" }
        return "Photon energy (eV)"
    }
}
