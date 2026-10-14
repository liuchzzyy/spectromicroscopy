import SwiftUI
import Charts
import MantisCore

struct ScientificCanvas: View {
    @ObservedObject var model: WorkspaceModel
    let image: ScientificImage
    @State private var points: [CGPoint] = []
    private let inset: CGFloat = 28
    var body: some View {
        GeometryReader { geometry in
            let rect = plotRect(in: geometry.size)
            Canvas { context, size in
                context.fill(Path(rect), with: .color(.black))
                let low = image.values.min() ?? 0
                let high = image.values.max() ?? 1
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
                            let adjusted = pow(max(0, min(1, (scaled - model.contrastLow) / max(0.001, model.contrastHigh - model.contrastLow))), 1 / model.gamma)
                            color = displayColor(adjusted)
                        }
                        context.fill(Path(CGRect(x: rect.minX + Double(x) * dw, y: rect.minY + Double(y) * dh, width: dw + 0.4, height: dh + 0.4)), with: .color(color))
                    }
                }
                let stroke = Color.white.opacity(0.9)
                if let bounds = model.rectangle, bounds.count == 4 {
                    let p0 = screen(x: Double(bounds[0]), y: Double(bounds[1]), rect: rect)
                    let p1 = screen(x: Double(bounds[2]), y: Double(bounds[3]), rect: rect)
                    context.stroke(Path(CGRect(x: p0.x, y: p0.y, width: p1.x - p0.x, height: p1.y - p0.y)), with: .color(stroke), style: StrokeStyle(lineWidth: 1.5, dash: [5,3]))
                }
                if let polygon = model.polygon, polygon.count > 2 {
                    var path = Path(); path.addLines(polygon.map { screen(x: $0[0], y: $0[1], rect: rect) }); path.closeSubpath()
                    context.stroke(path, with: .color(stroke), lineWidth: 1.5)
                }
                if let s = model.snapshot {
                    let p = screen(x: Double(s.selected_x) + 0.5, y: Double(s.selected_y) + 0.5, rect: rect)
                    var path = Path(); path.move(to: CGPoint(x: p.x - 7, y: p.y)); path.addLine(to: CGPoint(x: p.x + 7, y: p.y)); path.move(to: CGPoint(x: p.x, y: p.y - 7)); path.addLine(to: CGPoint(x: p.x, y: p.y + 7))
                    context.stroke(path, with: .color(.white), lineWidth: 1.5)
                }
                if let first = points.first, let last = points.last {
                    var path = Path()
                    if model.roiMode == "Rectangle" { path.addRect(CGRect(x: min(first.x,last.x), y: min(first.y,last.y), width: abs(last.x-first.x), height: abs(last.y-first.y))) }
                    else { path.addLines(points) }
                    context.stroke(path, with: .color(.yellow), lineWidth: 1.5)
                }
                context.draw(Text("0").font(.caption2).foregroundColor(.secondary), at: CGPoint(x: rect.minX, y: rect.maxY + 13))
                context.draw(Text("\(image.full_width) px").font(.caption2).foregroundColor(.secondary), at: CGPoint(x: rect.maxX - 14, y: rect.maxY + 13))
                context.draw(Text("y").font(.caption2).foregroundColor(.secondary), at: CGPoint(x: rect.minX - 14, y: rect.midY))
                context.draw(Text("x").font(.caption2).foregroundColor(.secondary), at: CGPoint(x: rect.midX, y: rect.maxY + 13))
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                guard !model.busy, rect.contains(value.startLocation) else { return }
                let clamped = CGPoint(x: min(rect.maxX, max(rect.minX, value.location.x)), y: min(rect.maxY, max(rect.minY, value.location.y)))
                if points.isEmpty { points = [value.startLocation] }
                if model.roiMode == "Lasso" { points.append(clamped) }
                else { points = [value.startLocation, clamped] }
            }.onEnded { value in
                defer { points = [] }
                guard !model.busy, rect.contains(value.startLocation) else { return }
                let first = pixel(value.startLocation, rect: rect)
                let last = pixel(value.location, rect: rect)
                switch model.roiMode {
                case "Rectangle":
                    model.polygon = nil
                    model.rectangle = [min(first.0,last.0), min(first.1,last.1), min(image.full_width,max(first.0,last.0)+1), min(image.full_height,max(first.1,last.1)+1)]
                case "Lasso":
                    guard points.count > 2 else { return }
                    model.rectangle = nil
                    model.polygon = points.map { p in let xy = pixel(p, rect: rect); return [Double(xy.0),Double(xy.1)] }
                default: model.rectangle = nil; model.polygon = nil
                }
                model.updateView(x: last.0, y: last.1)
            })
            .accessibilityLabel("\(image.title), \(image.full_width) by \(image.full_height) pixels")
            .accessibilityHint("Choose Pixel, Rectangle or Lasso, then click or drag to inspect spectra.")
        }
    }
    func plotRect(in size: CGSize) -> CGRect {
        let maxWidth = max(1, size.width - inset * 2), maxHeight = max(1, size.height - inset * 2)
        let scale = min(maxWidth / Double(image.full_width), maxHeight / Double(image.full_height))
        let width = Double(image.full_width) * scale, height = Double(image.full_height) * scale
        return CGRect(x: (size.width - width) / 2, y: (size.height - height) / 2, width: width, height: height)
    }
    private func pixel(_ p: CGPoint, rect: CGRect) -> (Int, Int) {
        (min(image.full_width-1, max(0, Int((p.x - rect.minX) / rect.width * Double(image.full_width)))), min(image.full_height-1, max(0, Int((p.y-rect.minY) / rect.height * Double(image.full_height)))))
    }
    private func screen(x: Double, y: Double, rect: CGRect) -> CGPoint { CGPoint(x: rect.minX + x / Double(image.full_width) * rect.width, y: rect.minY + y / Double(image.full_height) * rect.height) }
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

struct SpectraChart: View {
    let spectra: [Spectrum]
    let selectedEnergy: Double?
    let selectEnergy: (Double) -> Void
    @State private var selectedSeries = "All spectra"
    private var visible: [Spectrum] { selectedSeries == "All spectra" ? spectra : spectra.filter { $0.name == selectedSeries } }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Spectra & diagnostics", systemImage: "waveform.path").font(.headline)
                Spacer()
                Picker("Series", selection: $selectedSeries) {
                    Text("All spectra").tag("All spectra")
                    ForEach(spectra) { Text($0.name).tag($0.name) }
                }.labelsHidden().frame(maxWidth: 220)
            }
            if spectra.isEmpty {
                ContentUnavailableView("No spectrum yet", systemImage: "waveform.path", description: Text("Open a stack or run an analysis to inspect its spectra."))
            } else {
                Chart {
                    ForEach(visible) { spectrum in
                        ForEach(Array(spectrum.x.indices), id: \.self) { i in
                            LineMark(x: .value("Axis", spectrum.x[i]), y: .value("Signal", spectrum.y[i]))
                                .foregroundStyle(by: .value("Series", spectrum.name))
                        }
                    }
                    if let selectedEnergy { RuleMark(x: .value("Selected energy", selectedEnergy)).foregroundStyle(.secondary.opacity(0.5)).lineStyle(StrokeStyle(dash: [4,4])) }
                }
                .chartXAxisLabel(axisLabel).chartYAxisLabel("Signal (series units)")
                .chartLegend(position: .bottom, spacing: 8)
                .chartOverlay { proxy in
                    GeometryReader { geo in
                        Rectangle().fill(.clear).contentShape(Rectangle()).onTapGesture { point in
                            guard let frame = proxy.plotFrame else { return }
                            let x = point.x - geo[frame].origin.x
                            if let energy: Double = proxy.value(atX: x) { selectEnergy(energy) }
                        }
                    }
                }
            }
        }.padding(16)
    }
    private var axisLabel: String {
        let names = visible.map(\.name).joined(separator: " ").lowercased()
        if names.contains("convergence") || names.contains("cost") { return "Iteration" }
        if names.contains("eigenvalue") && visible.count == 1 { return "Component" }
        return "Photon energy (eV) / diagnostic axis"
    }
}
