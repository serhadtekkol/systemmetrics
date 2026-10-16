import SwiftUI

/// Control Center–style module: rounded fill, symbol + uppercase title, optional trailing accessory.
struct Card<Accessory: View, Content: View>: View {
    var title: String
    var symbol: String
    @ViewBuilder var accessory: Accessory
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            HStack(spacing: Theme.Space.xs) {
                Image(systemName: symbol)
                    .imageScale(.small)
                Text(title.uppercased(with: Locale(identifier: "tr_TR")))
                    .tracking(0.3)
                Spacer(minLength: Theme.Space.xs)
                accessory
            }
            .font(Theme.Font.cardTitle)
            .foregroundStyle(Theme.textSecondary)
            .lineLimit(1)

            content
        }
        .padding(Theme.Space.l)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.cardFill, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
    }
}

extension Card where Accessory == EmptyView {
    init(title: String, symbol: String, @ViewBuilder content: () -> Content) {
        self.init(title: title, symbol: symbol, accessory: { EmptyView() }, content: content)
    }
}

/// "—" plus "veri yok", used wherever a metric could not be read.
struct UnavailableLabel: View {
    var body: some View {
        Text("veri yok")
            .font(Theme.Font.caption)
            .foregroundStyle(Theme.textSecondary)
    }
}

/// Small rounded pill used for the uptime and Docker status.
struct Pill<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        HStack(spacing: Theme.Space.xs) { content }
            .font(Theme.Font.micro)
            .padding(.horizontal, Theme.Space.s)
            .padding(.vertical, Theme.Space.xxs + 1)
            .background(Theme.chipFill, in: Capsule())
    }
}

/// Coloured status dot. Always paired with a text label.
struct StatusDot: View {
    var color: Color
    var body: some View {
        Circle().fill(color).frame(width: 6, height: 6)
    }
}

#Preview("Card") {
    Card(title: "CPU", symbol: "cpu", accessory: { Text("10 çekirdek") }) {
        Text("İçerik").font(Theme.Font.body)
    }
    .frame(width: 170, height: 120)
    .padding()
}
