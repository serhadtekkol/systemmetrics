import SwiftUI

/// Names that come from outside the app — container names from the Docker daemon, volume names
/// from any disk someone plugs in — are untrusted. They are shown verbatim (never as a
/// `LocalizedStringKey`, so no Markdown or format interpretation), on one line, and cleaned of
/// characters that can make one string look like another.
enum UntrustedText {
    /// Longest name kept, in characters; the view truncates further to fit its column.
    static let maxLength = 64

    /// Any whitespace run (tabs and newlines included) becomes one space. Drops the remaining
    /// control characters and Unicode format characters (general category Cf) such as the bidi
    /// embeddings/overrides U+202A–U+202E and isolates U+2066–U+2069 that can reverse how a name
    /// reads, zero-width spaces and soft hyphens. Kept: ZWNJ/ZWJ (U+200C/U+200D, needed by
    /// Persian and emoji sequences) and tag characters (U+E0020–U+E007F, flag sequences).
    /// An empty result shows as "—".
    private static func keptFormatScalars(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value == 0x200C || scalar.value == 0x200D || (0xE0020...0xE007F).contains(scalar.value)
    }

    static func clean(_ raw: String) -> String {
        var scalars = String.UnicodeScalarView()
        var lastWasSpace = false
        for scalar in raw.unicodeScalars {
            if scalar.properties.isWhitespace {
                if !lastWasSpace && !scalars.isEmpty { scalars.append(" ") }
                lastWasSpace = true
                continue
            }
            switch scalar.properties.generalCategory {
            case .format where keptFormatScalars(scalar):
                scalars.append(scalar)
                lastWasSpace = false
            case .format, .control, .surrogate, .privateUse, .unassigned:
                continue
            default:
                scalars.append(scalar)
                lastWasSpace = false
            }
        }
        var cleaned = String(scalars).trimmingCharacters(in: .whitespaces)
        if cleaned.count > maxLength { cleaned = String(cleaned.prefix(maxLength - 1)) + "…" }
        return cleaned.isEmpty ? "—" : cleaned
    }
}

/// One-line, verbatim, cleaned text for an untrusted name.
struct UntrustedName: View {
    var raw: String
    var truncation: Text.TruncationMode = .middle

    var body: some View {
        Text(verbatim: UntrustedText.clean(raw))
            .lineLimit(1)
            .truncationMode(truncation)
    }
}
