import SwiftUI
import TurnstileCore

struct SettingsView: View {
    @ObservedObject var monitor: Monitor

    var body: some View {
        TabView {
            GeneralSettingsView(monitor: monitor)
                .tabItem { Label("General", systemImage: "gearshape") }
            ShimSettingsView()
                .tabItem { Label("Tools", systemImage: "hammer") }
        }
    }
}

/// The app's own switches, kept out of the menu so it only shows what's running.
struct GeneralSettingsView: View {
    @ObservedObject var monitor: Monitor

    var body: some View {
        Form {
            Section {
                Toggle(isOn: Binding(get: { !monitor.disabled }, set: { monitor.setGating($0) })) {
                    Text("Gate heavy commands")
                    Text("Builds and tests wait until there's memory and a free slot. Off lets every command run ungated, on every shell, until you turn it back on.")
                }
            }

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
