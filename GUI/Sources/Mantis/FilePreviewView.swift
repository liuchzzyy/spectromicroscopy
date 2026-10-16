import SwiftUI
import MantisCore

struct FilePreviewView: View {
    let preview: FilePreview
    @EnvironmentObject private var preferences: InterfacePreferences
    private func tr(_ key: String) -> String { InterfaceText.value(key, language: preferences.language) }
    private func provenance(_ value: String?) -> String {
        let text = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.isEmpty ? tr("Default") : tr(text)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(tr("File preview")).font(.headline)
            Text(preview.path).font(.callout.monospaced()).textSelection(.enabled)
            HStack {
                Text(tr("Format") + ": " + provenance(preview.format))
                Text(tr("Beamline") + ": " + provenance(preview.beamline))
                Text(preview.plugin).foregroundStyle(.secondary)
            }.font(.callout)
            Text(tr("Read-only preview; spectral analysis is unavailable."))
                .font(.caption).foregroundStyle(.secondary)
            if let shape = preview.shape {
                Text(tr("Dimensions") + ": " + shape.map(String.init).joined(separator: " × "))
            }
            if let count = preview.frame_count {
                Text(tr("Preview frame") + ": 1 / \(count)").font(.caption)
            }
            if preview.kind == .table, let columns = preview.columns, let rows = preview.rows {
                ScrollView([.horizontal, .vertical]) {
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                        Section {
                            ForEach(rows.indices, id: \.self) { row in
                                HStack(spacing: 12) {
                                    ForEach(columns.indices, id: \.self) { column in
                                        Text(String(format: "%#.5g", rows[row][column]))
                                            .frame(width: 140, alignment: .trailing)
                                    }
                                }.padding(.vertical, 5)
                                    .background(row.isMultiple(of: 2) ? Color(nsColor: .controlBackgroundColor) : Color.clear)
                            }
                        } header: {
                            HStack(spacing: 12) {
                                ForEach(columns.indices, id: \.self) { column in
                                    Text(columns[column]).fontWeight(.semibold).frame(width: 140, alignment: .trailing)
                                }
                            }.padding(.vertical, 8).background(Color(nsColor: .windowBackgroundColor))
                        }
                    }.font(.body.monospacedDigit()).textSelection(.enabled)
                }.frame(minHeight: 320, maxHeight: 500)
            } else if let width = preview.width, let height = preview.height, let values = preview.values {
                Canvas { context, size in
                    let low = values.min() ?? 0, high = values.max() ?? 1
                    let scale = min(size.width / Double(width), size.height / Double(height))
                    let origin = CGPoint(x: (size.width - Double(width) * scale) / 2,
                                         y: (size.height - Double(height) * scale) / 2)
                    for y in 0..<height {
                        for x in 0..<width {
                            let level = (values[y * width + x] - low) / max(high - low, 1e-12)
                            let rect = CGRect(x: origin.x + Double(x) * scale, y: origin.y + Double(y) * scale,
                                              width: scale + 0.2, height: scale + 0.2)
                            context.fill(Path(rect), with: .color(Color(white: level)))
                        }
                    }
                }.frame(height: 384).accessibilityLabel(tr("Preview frame"))
            }
            DisclosureGroup(tr("Raw Metadata (JSON)")) {
                Text(JSONValue.object(preview.metadata).description)
                    .font(.caption.monospaced()).textSelection(.enabled)
            }
        }.padding(Theme.cardInset).frame(maxWidth: .infinity, alignment: .leading).surface()
            .accessibilityIdentifier("workspace.filePreview")
    }
}
