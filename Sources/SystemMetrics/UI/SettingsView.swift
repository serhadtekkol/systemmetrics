import SwiftUI

struct SettingsView: View {
    @Bindable var settings: AppSettings
    var onQuit: () -> Void

    var body: some View {
        Form {
            Section {
                Picker("Güncelleme sıklığı", selection: $settings.refreshInterval) {
                    ForEach(AppSettings.intervals, id: \.self) { interval in
                        Text("\(Int(interval)) sn").tag(interval)
                    }
                }
                .pickerStyle(.segmented)

                Picker("Menü çubuğu", selection: $settings.menuBarContent) {
                    ForEach(MenuBarContent.allCases) { content in
                        Text(content.title).tag(content)
                    }
                }
            }

            Section {
                Toggle("Girişte başlat", isOn: $settings.launchAtLogin)
                if let error = settings.launchAtLoginError {
                    // Red marks the problem; the message itself stays in label colors for contrast.
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Girişte başlat ayarlanamadı.")
                            Text(error)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(Theme.Load.high)
                    }
                }
            }

            Section {
                HStack {
                    Spacer()
                    Button("SystemMetrics'ten Çık", action: onQuit)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 380)
        .fixedSize(horizontal: false, vertical: true)
    }
}

#Preview("Ayarlar") {
    SettingsView(settings: AppSettings(), onQuit: {})
}
