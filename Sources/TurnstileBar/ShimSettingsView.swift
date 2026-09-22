import SwiftUI
import TurnstileCore

@MainActor
final class ShimSettingsModel: ObservableObject {
    @Published private(set) var settings = ShimSettings(machine: MachineConfig())
    @Published var newTool = ""
    @Published private(set) var message: String?
    /// Where the login shell finds each tool; nil while it's being asked.
    @Published private(set) var locations: [String: ShellCheck.Location]?

    struct Row: Identifiable {
        let name: String
        let custom: Bool
        var id: String { name }
    }

    enum Status {
        case checking, gated, bypassed(String), notInstalled, off
    }

    var rows: [Row] {
        Classifier.defaultShims.map { Row(name: $0, custom: false) } + settings.custom.map { Row(name: $0, custom: true) }
    }

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

    func status(of row: Row) -> Status {
        guard row.custom || settings.enabledDefaults.contains(row.name) else { return .off }
        switch locations.map({ $0[row.name] }) {
        case nil: return .checking
        case .shimmed(let real)?: return real == nil ? .notInstalled : .gated
        case .elsewhere(let path)?: return .bypassed(path)
        case .missing?, nil?: return .notInstalled
        }
    }

    func path(of row: Row) -> String? {
        switch locations?[row.name] {
        case .shimmed(let real)?: return real.map(abbreviatingHome)
        case .elsewhere(let path)?: return abbreviatingHome(path)
        case .missing?, nil: return nil
        }
    }

    /// Asks a login shell, not this app's own PATH, which is bare for an app opened from Finder.
    func check() {
        let tools = rows.map(\.name)
        let shims = paths.shims
        let bare = ShellCheck.bareEnvironment(from: environment)
        locations = nil
        Task.detached(priority: .userInitiated) {
            let output = ShellCheck.ask(ShellCheck.probes[1], tools: tools, environment: bare) ?? ""
            let found = ShellCheck.locations(output: output, shimsDir: shims)
            await MainActor.run { self.locations = found }
        }
    }

    private func abbreviatingHome(_ path: String) -> String {
        let home = homeDirectory(environment)
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
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
            check()
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

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Table(model.rows) {
                TableColumn("On") { row in
                    Toggle("Intercept \(row.name)", isOn: Binding(
                        get: { row.custom || model.settings.enabledDefaults.contains(row.name) },
                        set: { model.setDefault(row.name, enabled: $0) }
                    ))
                    .toggleStyle(.checkbox)
                    .labelsHidden()
                    .disabled(row.custom)
                }
                .width(28)
                TableColumn("Tool") { row in
                    Text(row.name).font(.body.monospaced())
                }
                .width(min: 80, ideal: 100)
                TableColumn("Status") { row in
                    ToolStatusLabel(status: model.status(of: row))
                }
                .width(min: 90, ideal: 110)
                TableColumn("Path") { row in
                    let path = model.path(of: row)
                    Text(path ?? "—")
                        .foregroundStyle(.secondary)
                        .truncationMode(.middle)
                        .help(path ?? "")
                }
                TableColumn("") { row in
                    if row.custom {
                        Button("Remove", systemImage: "minus.circle") { model.removeCustom(row.name) }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.borderless)
                            .help("Stop intercepting \(row.name)")
                    }
                }
                .width(20)
            }
            .tableStyle(.bordered(alternatesRowBackgrounds: true))
            .scrollIndicators(.visible)

            HStack {
                TextField("Add a tool, e.g. bazel", text: $model.newTool)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { model.addCustom() }
                Button("Add") { model.addCustom() }
                    .disabled(model.newTool.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Recheck", systemImage: "arrow.clockwise") { model.check() }
                    .labelStyle(.iconOnly)
                    .disabled(model.locations == nil)
                    .help("Ask your login shell again where each tool comes from")
            }

            Text("Status is what your login shell runs. Quick commands still pass straight through; custom tools use the compile queue unless a command rule says otherwise.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let message = model.message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(20)
        .frame(width: 520, height: 500)
        .task { model.check() }
    }
}

private struct ToolStatusLabel: View {
    let status: ShimSettingsModel.Status

    var body: some View {
        switch status {
        case .checking:
            ProgressView().controlSize(.small)
        case .gated:
            Label("Gated", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .bypassed(let path):
            Label("Bypassed", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .help("Your login shell finds \(path) before the shim. Run `turnstile init` to fix PATH.")
        case .notInstalled:
            Label("Not installed", systemImage: "circle.dashed").foregroundStyle(.secondary)
        case .off:
            Label("Off", systemImage: "circle").foregroundStyle(.secondary)
        }
    }
}
