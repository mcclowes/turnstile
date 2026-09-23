import SwiftUI
import TurnstileCore

enum SettingsTab: String {
    case general, limits, tools

    /// Shared with the menu panel, so a slot chip can open Settings on Limits.
    static let storageKey = "settingsTab"
}

struct SettingsView: View {
    @ObservedObject var monitor: Monitor
    @AppStorage(SettingsTab.storageKey) private var tab = SettingsTab.general

    var body: some View {
        TabView(selection: $tab) {
            GeneralSettingsView(monitor: monitor)
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(SettingsTab.general)
            LimitsSettingsView()
                .tabItem { Label("Limits", systemImage: "gauge.with.dots.needle.50percent") }
                .tag(SettingsTab.limits)
            ShimSettingsView()
                .tabItem { Label("Tools", systemImage: "hammer") }
                .tag(SettingsTab.tools)
        }
    }
}

/// The app's own switches, kept out of the menu so it only shows what's running.
struct GeneralSettingsView: View {
    @ObservedObject var monitor: Monitor

    var body: some View {
        Form {
            if monitor.canNotify {
                Section("Notify me when") {
                    ForEach(MenuBarState.Event.Kind.allCases, id: \.self) { kind in
                        Toggle(kind.title, isOn: Binding(get: { monitor.notifying.contains(kind) }, set: { monitor.setNotifying(kind, $0) }))
                    }
                }
            }

            if monitor.canLaunchAtLogin {
                Section {
                    Toggle("Launch at login", isOn: Binding(get: { monitor.launchAtLogin }, set: { monitor.setLaunchAtLogin($0) }))
                }
            }

            if let message = monitor.message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            Text("Turnstile \(Turnstile.version)")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity)
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 500)
        .padding(.vertical, 8)
    }
}
