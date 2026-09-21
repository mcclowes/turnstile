import SwiftUI
import TurnstileCore

@MainActor
final class ShimSettingsModel: ObservableObject {
    @Published private(set) var settings = ShimSettings(machine: MachineConfig())
    @Published var newTool = ""
    @Published private(set) var message: String?

    private let environment: [String: String]
    private let paths: Paths
    private var configPath: String { ConfigLoader.globalPath(environment: environment) }

    init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.environment = environment
        paths = Paths(environment: environment)
        reload()
    }

    func setDefault(_ tool: String, enabled: Bool) {
        if enabled { settings.enabledDefaults.insert(tool) } else { settings.enabledDefaults.remove(tool) }
        save()
    }

    func addCustom() {
        guard let tool = ShimSettings.normalize(newTool) else {
            message = "Enter an executable name, without a path."
            return
        }
        guard !Classifier.defaultShims.contains(tool) else {
            settings.enabledDefaults.insert(tool)
            newTool = ""
            save()
            return
        }
        guard !settings.custom.contains(tool) else {
            message = "\(tool) is already intercepted."
            return
        }
        settings.custom.append(tool)
        newTool = ""
        save()
    }

    func removeCustom(_ tool: String) {
        settings.custom.removeAll { $0 == tool }
        save()
    }

    private func reload() {
        do {
            guard let data = FileManager.default.contents(atPath: configPath) else { return }
            settings = ShimSettings(machine: try ConfigFile.decode(data).machine)
        } catch {
            message = "Couldn't read settings: \(error.localizedDescription)"
        }
    }

    private func save() {
        do {
            let existing = FileManager.default.contents(atPath: configPath) ?? Data()
            let data = try settings.updatingConfig(existing)
            try FileManager.default.createDirectory(
                atPath: (configPath as NSString).deletingLastPathComponent,
                withIntermediateDirectories: true
            )
            try data.write(to: URL(fileURLWithPath: configPath), options: .atomic)
            try rebuildShims()
            message = nil
        } catch {
            message = "Couldn't update shims: \(error.localizedDescription)"
            reload()
        }
    }

    private func rebuildShims() throws {
        let executable = paths.shims + "/turnstile"
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: executable])
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["shims"]
        process.environment = environment
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw CocoaError(.executableRuntimeMismatch) }
    }
}

struct ShimSettingsView: View {
    @StateObject private var model = ShimSettingsModel()

    private let columns = [GridItem(.adaptive(minimum: 130), alignment: .leading)]

    var body: some View {
        Form {
            Section("Built-in tools") {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
                    ForEach(Classifier.defaultShims, id: \.self) { tool in
                        Toggle(tool, isOn: Binding(
                            get: { model.settings.enabledDefaults.contains(tool) },
                            set: { model.setDefault(tool, enabled: $0) }
                        ))
                        .toggleStyle(.checkbox)
                    }
                }
                Text("Turn off tools that shouldn't be intercepted. Quick commands still pass straight through.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Custom tools") {
                ForEach(model.settings.custom, id: \.self) { tool in
                    HStack {
                        Text(tool).font(.body.monospaced())
                        Spacer()
                        Button("Remove", systemImage: "minus.circle") { model.removeCustom(tool) }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.borderless)
                            .help("Stop intercepting \(tool)")
                    }
                }
                HStack {
                    TextField("Executable name", text: $model.newTool)
                        .onSubmit { model.addCustom() }
                    Button("Add") { model.addCustom() }
                        .disabled(model.newTool.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                Text("Custom tools use the compile queue unless a command rule says otherwise.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
    }
}
