import SwiftUI

// Claude-style palette: warm cream light mode, warm charcoal dark mode,
// terracotta accent. Headings use the system serif (New York).

struct Palette {
    let background: Color
    let panel: Color
    let border: Color
    let text: Color
    let textDim: Color
    let accent: Color
    let accentText: Color
    let green: Color
    let amber: Color
    let red: Color

    static let light = Palette(
        background: Color(hex: 0xFAF9F5),
        panel: Color(hex: 0xFDFCFA),
        border: Color(hex: 0xDAD9D4),
        text: Color(hex: 0x3D3929),
        textDim: Color(hex: 0x83827D),
        accent: Color(hex: 0xC96442),
        accentText: Color(hex: 0xA14D2E),
        green: Color(hex: 0x30A14E),
        amber: Color(hex: 0xB8860B),
        red: Color(hex: 0xC0392B)
    )

    static let dark = Palette(
        background: Color(hex: 0x262624),
        panel: Color(hex: 0x30302E),
        border: Color(hex: 0x44443F),
        text: Color(hex: 0xF5F4EF),
        textDim: Color(hex: 0xA8A69E),
        accent: Color(hex: 0xD97757),
        accentText: Color(hex: 0xE5987A),
        green: Color(hex: 0x39D353),
        amber: Color(hex: 0xE0B34F),
        red: Color(hex: 0xE06C5C)
    )

    static func forScheme(_ scheme: ColorScheme) -> Palette {
        scheme == .dark ? .dark : .light
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}

struct CardBackground: ViewModifier {
    let palette: Palette
    func body(content: Content) -> some View {
        content
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(palette.panel)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(palette.border, lineWidth: 1)
            )
    }
}

extension View {
    func card(_ palette: Palette) -> some View {
        modifier(CardBackground(palette: palette))
    }
}

// GitHub heatmap ramps, per theme.
func heatColor(level: Int, dark: Bool) -> Color {
    let light: [UInt32] = [0xEBEDF0, 0x9BE9A8, 0x40C463, 0x30A14E, 0x216E39]
    let darkRamp: [UInt32] = [0x393936, 0x0E4429, 0x006D32, 0x26A641, 0x39D353]
    let ramp = dark ? darkRamp : light
    return Color(hex: ramp[max(0, min(4, level))])
}
