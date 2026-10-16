import SwiftUI
import MetricsKit

struct HeaderView: View {
    var hostInfo: HostInfo
    var now: Date
    var onOpenSettings: () -> Void

    var body: some View {
        HStack(spacing: Theme.Space.m) {
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: hostInfo.modelName)
                    .font(Theme.Font.headline)
                Text(verbatim: hostInfo.chip)
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
            .lineLimit(1)
            .accessibilityElement(children: .combine)

            Spacer(minLength: Theme.Space.xs)

            if let boot = hostInfo.bootTime {
                let uptime = Formatters.uptime(since: boot, now: now)
                Pill {
                    Image(systemName: "clock")
                    Text(uptime)
                }
                .foregroundStyle(Theme.textSecondary)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Açık kalma süresi \(uptime)")
            }
            // No quit button here: the header sits on the hover path, and a one-click, unconfirmed
            // quit next to Settings was too easy to hit. Quit lives in the status item's
            // right-click menu and in Settings.
            HeaderButton(symbol: "gearshape", title: "Ayarlar", action: onOpenSettings)
        }
        .padding(.horizontal, Theme.Space.xs)
    }
}

/// Round 28×28 icon button, Control Center style.
private struct HeaderButton: View {
    var symbol: String
    var title: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 28, height: 28)
                .background(Theme.chipFill, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.primary)
        .help(title)
        .accessibilityLabel(title)
    }
}
