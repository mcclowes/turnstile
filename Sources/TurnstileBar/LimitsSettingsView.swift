import AppKit
import SwiftUI
import TurnstileCore

@MainActor
final class LimitsSettingsModel: ObservableObject {
    @Published private(set) var settings = LimitSettings()
    @Published private(set) var message: String?

    let cpuCount = SystemMemory.cpuCount
    let physical = SystemMemory.physical
    private let configPath: String

    init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        configPath = ConfigLoader.globalPath(environment: environment)
        reload()
    }

    /// A value equal to the default is stored as the default, so the file only records real choices.
    func setSlots(_ value: Int, for cls: ResourceClass) {
        update { $0.concurrency[cls] = value == MachineConfig().concurrencyLimit(for: cls, cpuCount: cpuCount) ? nil : value }
    }

    func setReserve(_ bytes: UInt64) {
        update { $0.reserve = bytes == MachineConfig().reserveBytes ? nil : bytes }
    }

    func setKillMultiplier(_ value: Double) {
        update { $0.killMultiplier = value == Pressure.defaultKillMultiplier ? nil : value }
    }

    func setMaxMemory(_ bytes: UInt64?) { update { $0.maxMemory = bytes } }
    func setPause(_ on: Bool) { update { $0.pause = on } }
    func setInject(_ on: Bool) { update { $0.inject = on } }
    func restoreDefaults() { update { $0 = LimitSettings() } }

    func reload() {
        do {
            guard let data = FileManager.default.contents(atPath: configPath) else { return }
            settings = LimitSettings(file: try ConfigFile.decode(data))
            message = nil
        } catch {
            message = "Couldn't read settings: \(error.localizedDescription)"
        }
    }

    func openConfigFile() {
        do {
            if !FileManager.default.fileExists(atPath: configPath) { try write(ConfigJSON.edit(Data()) { _ in }) }
            NSWorkspace.shared.open(URL(fileURLWithPath: configPath))
        } catch {
            message = "Couldn't create \(configPath): \(error.localizedDescription)"
        }
    }

    private func update(_ change: (inout LimitSettings) -> Void) {
        var next = settings
        change(&next)
        do {
            try write(next.updatingConfig(FileManager.default.contents(atPath: configPath) ?? Data()))
            settings = next
            message = nil
        } catch {
            message = "Couldn't update limits: \(error.localizedDescription)"
            reload()
        }
    }

    private func write(_ data: Data) throws {
        try FileManager.default.createDirectory(atPath: (configPath as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try data.write(to: URL(fileURLWithPath: configPath), options: .atomic)
    }
}

struct LimitsSettingsView: View {
    @StateObject private var model = LimitsSettingsModel()

    private static let halfGB = Bytes.gb / 2
    private static let step = Int(halfGB)

    var body: some View {
        Form {
            Section {
                ForEach(ResourceClass.allCases, id: \.self) { cls in
                    let slots = model.settings.slots(for: cls, cpuCount: model.cpuCount)
                    Stepper(value: Binding(get: { slots }, set: { model.setSlots($0, for: cls) }), in: 1...max(8, model.cpuCount)) {
                        Label {
                            Text("\(cls.rawValue.capitalized): \(slots) at once")
                            if model.settings.concurrency[cls] == nil { Text("Automatic") }
                        } icon: {
                            Image(systemName: MenuBarState.symbol(for: cls))
                        }
                    }
                }
            } header: {
                Text("Slots")
            } footer: {
                caption("Jobs of the same kind that run together, however much memory is spare.")
            }

            Section("Memory") {
                Stepper(value: Binding(get: { model.settings.reserveBytes }, set: { model.setReserve($0) }),
                        in: Self.halfGB...max(Self.halfGB, model.physical / 2), step: Self.step) {
                    Text("Keep \(Bytes.format(model.settings.reserveBytes)) free for everything else")
                    Text("Queued jobs wait rather than eat into this.")
                }
                Toggle(isOn: Binding(get: { model.settings.pause }, set: { model.setPause($0) })) {
                    Text("Pause agent jobs when memory runs low")
                    Text("Paused jobs resume once memory recovers. Off, they keep running and the Mac swaps.")
                }
            }

            Section("Runaways") {
                Stepper(value: Binding(get: { model.settings.killMultiplierValue }, set: { model.setKillMultiplier($0) }),
                        in: 1.5...10, step: 0.5) {
                    Text("Runaway past \(model.settings.killMultiplierValue.formatted())× a command's usual peak")
                    Text("A runaway is paused when memory runs out, and killed if that doesn't help.")
                }
                Toggle(isOn: Binding(get: { model.settings.maxMemory != nil }, set: { model.setMaxMemory($0 ? 8 * Bytes.gb : nil) })) {
                    Text("Hard memory cap")
                    Text("Kills any job past the cap straight away, whatever memory is spare.")
                }
                if let cap = model.settings.maxMemory {
                    Stepper(value: Binding(get: { cap }, set: { model.setMaxMemory($0) }), in: Bytes.gb...max(Bytes.gb, model.physical), step: Int(Bytes.gb)) {
                        Text("Cap at \(Bytes.format(cap))")
                    }
                }
            }

            Section {
                Toggle(isOn: Binding(get: { model.settings.inject }, set: { model.setInject($0) })) {
                    Text("Limit build parallelism")
                    Text("Passes job counts and heap limits sized to free memory into builds and tests.")
                }
            }

            Section {
                HStack {
                    Button("Open config file") { model.openConfigFile() }
                    Spacer()
                    Button("Restore defaults") { model.restoreDefaults() }
                        .disabled(model.settings == LimitSettings())
                }
            } footer: {
                caption("Other settings live in the config file. A project's .turnstilerc can override pausing, parallelism, and runaway limits.")
            }

            if let message = model.message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 500)
        .padding(.vertical, 8)
        .onAppear { model.reload() }
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}
