import SwiftUI
import AppKit

/// One place for the app's surfaces, spacing and elevation.
///
/// The page canvas is deliberately **not** `NSColor.underPageBackgroundColor`: in light
/// appearance that resolves to 58.8% gray, which turns white cards into harsh, dirty
/// rectangles. Everything here is appearance-aware and set explicitly, so a card stays
/// distinguishable from the page in both appearances.
enum Theme {
    // MARK: Spacing scale

    /// Horizontal inset shared by the page header, the scrolling content and the status
    /// bar, so their left edges line up exactly.
    static let contentInset: CGFloat = 24
    static let sectionSpacing: CGFloat = 16
    static let cardInset: CGFloat = 16
    static let sidebarInset: CGFloat = 20
    static let sidebarIconWidth: CGFloat = 20
    static let sidebarIconSpacing: CGFloat = 8
    static let cornerRadius: CGFloat = 10

    // MARK: Surfaces

    /// Page canvas behind the cards.
    static func page(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 0.106, green: 0.110, blue: 0.118)
                        : Color(red: 0.949, green: 0.957, blue: 0.969)
    }

    /// Card / tile surface: white in light appearance, lighter than the page in dark.
    static func surface(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 0.169, green: 0.176, blue: 0.188) : Color.white
    }

    /// Navigation column: a step darker than the page so it reads as chrome, not content.
    static func sidebar(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 0.086, green: 0.090, blue: 0.098)
                        : Color(red: 0.925, green: 0.933, blue: 0.945)
    }

    /// Parameter inspector: between page and card so the column separates from both.
    static func inspector(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 0.137, green: 0.143, blue: 0.153)
                        : Color(red: 0.973, green: 0.978, blue: 0.985)
    }

    /// Status strip along the bottom edge.
    static func statusBar(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 0.125, green: 0.129, blue: 0.137)
                        : Color(red: 0.961, green: 0.969, blue: 0.980)
    }

    /// Hinted drop area inside the empty state.
    static func dropArea(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 0.145, green: 0.153, blue: 0.169)
                        : Color(red: 0.937, green: 0.953, blue: 0.965)
    }

    static func border(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.085) : Color.black.opacity(0.075)
    }

    /// Dashed outline of the empty-state drop area: needs more contrast than a hairline
    /// card border or it disappears on a dim display.
    static func dropBorder(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.26) : Color.black.opacity(0.22)
    }

    /// The accent is unchanged: only surfaces were asked to change.
    static let accent = Color.teal
}

// MARK: - Backgrounds

private struct PageBackground: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    func body(content: Content) -> some View { content.background(Theme.page(scheme)) }
}

private struct PanelBackground: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    var fill: (ColorScheme) -> Color
    func body(content: Content) -> some View { content.background(fill(scheme)) }
}

// MARK: - Elevation

/// Card surface with a hairline border and an appearance-aware shadow.
private struct Surface: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
        content
            .background(Theme.surface(scheme), in: shape)
            .overlay(shape.stroke(Theme.border(scheme), lineWidth: 1))
            .shadow(color: .black.opacity(scheme == .dark ? 0.30 : 0.065),
                    radius: scheme == .dark ? 6 : 4, x: 0, y: scheme == .dark ? 2 : 1)
    }
}

/// Dashed, tinted container for the "drop or open a file" hint.
private struct DropArea: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
        content
            .background(Theme.dropArea(scheme), in: shape)
            .overlay(shape.strokeBorder(Theme.dropBorder(scheme),
                                        style: StrokeStyle(lineWidth: 1.5, dash: [6, 5])))
    }
}

extension View {
    func surface() -> some View { modifier(Surface()) }
    func dropArea() -> some View { modifier(DropArea()) }
    func pageBackground() -> some View { modifier(PageBackground()) }
    func sidebarBackground() -> some View { modifier(PanelBackground(fill: Theme.sidebar)) }
    func inspectorBackground() -> some View { modifier(PanelBackground(fill: Theme.inspector)) }
    func statusBarBackground() -> some View { modifier(PanelBackground(fill: Theme.statusBar)) }
}

extension Color {
    init(hex: String) {
        let clean = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: clean).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch clean.count {
        case 3:
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6:
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8:
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (255, 0, 0, 0)
        }
        self.init(.sRGB, red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255, opacity: Double(a) / 255)
    }
}
