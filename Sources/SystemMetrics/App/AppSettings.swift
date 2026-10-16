import Foundation
import Observation
import ServiceManagement

enum MenuBarContent: String, CaseIterable, Identifiable {
    case cpuAndMemory, iconOnly, cpuOnly, memoryOnly
    var id: String { rawValue }
    var title: String {
        switch self {
        case .cpuAndMemory: "CPU ve RAM"
        case .iconOnly: "Yalnızca ikon"
        case .cpuOnly: "Yalnızca CPU"
        case .memoryOnly: "Yalnızca RAM"
        }
    }
}

@MainActor
@Observable
final class AppSettings {
    static let intervals: [Double] = [1, 2, 5]
    @ObservationIgnored private let defaults: UserDefaults

    var refreshInterval: Double { didSet { defaults.set(refreshInterval, forKey: "refreshInterval") } }
    var menuBarContent: MenuBarContent { didSet { defaults.set(menuBarContent.rawValue, forKey: "menuBarContent") } }
    var launchAtLogin: Bool {
        didSet {
            guard launchAtLogin != oldValue else { return }
            do {
                if launchAtLogin { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                launchAtLoginError = nil
            } catch {
                launchAtLoginError = error.localizedDescription
                launchAtLogin = SMAppService.mainApp.status == .enabled
            }
        }
    }
    var launchAtLoginError: String?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored = defaults.double(forKey: "refreshInterval")
        refreshInterval = Self.intervals.contains(stored) ? stored : 2
        menuBarContent = defaults.string(forKey: "menuBarContent").flatMap(MenuBarContent.init) ?? .cpuAndMemory
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}
