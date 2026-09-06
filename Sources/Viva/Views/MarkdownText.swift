import SwiftUI

// Minimal block-level markdown renderer for the feedback summaries:
// headings, bullets, quotes, and inline bold/italic via AttributedString.
struct MarkdownText: View {
    let text: String
    let palette: Palette

    private func inline(_ s: String) -> AttributedString {
        (try? AttributedString(
            markdown: s,
            options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(s)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(Array(text.components(separatedBy: "\n").enumerated()), id: \.offset) { _, raw in
                let line = raw.trimmingCharacters(in: .whitespaces)
                if line.isEmpty {
                    Spacer().frame(height: 2)
                } else if line.hasPrefix("### ") {
                    Text(inline(String(line.dropFirst(4))))
                        .font(.system(.headline, design: .serif))
                        .padding(.top, 6)
                } else if line.hasPrefix("## ") {
                    Text(inline(String(line.dropFirst(3))))
                        .font(.system(.title3, design: .serif))
                        .padding(.top, 8)
                } else if line.hasPrefix("# ") {
                    Text(inline(String(line.dropFirst(2))))
                        .font(.system(.title2, design: .serif))
                        .padding(.top, 8)
                } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
                    HStack(alignment: .top, spacing: 7) {
                        Text("•").foregroundStyle(palette.textDim)
                        Text(inline(String(line.dropFirst(2))))
                    }
                } else if line.hasPrefix("> ") {
                    HStack(alignment: .top, spacing: 8) {
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(palette.border)
                            .frame(width: 3)
                        Text(inline(String(line.dropFirst(2))))
                            .foregroundStyle(palette.textDim)
                    }
                } else {
                    Text(inline(line))
                }
            }
        }
        .font(.system(size: 13))
        .foregroundStyle(palette.text)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
