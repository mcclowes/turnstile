import Foundation
import ServiceManagement
import TurnstileCore
import UserNotifications

/// Polls the daemon's status. It never starts or keeps the daemon alive: when it's idle, the menu says so and waits.
final class Monitor: ObservableObject {
    @Published private(set) var snapshot: StatusSnapshot?
    @Published private(set) var message: String?
    @Published private(set) var launchAtLogin = false

    private let paths = Paths()
    private let queue = DispatchQueue(label: "turnstile.monitor")
    private var timer: Timer?
    /// Notifications and login items need a real app bundle, which `swift run` doesn't give us.
    private let bundled = Bundle.main.bundleIdentifier != nil

    var canLaunchAtLogin: Bool { bundled }

    init() {
        if bundled {
            launchAtLogin = SMAppService.mainApp.status == .enabled
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
        poll()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.poll() }
    }

    func poll() {
        queue.async { [paths] in
            let status = Client.connect(socketPath: paths.socket)?.roundTrip(Message(type: "status"), timeout: 2)?.status
            DispatchQueue.main.async { self.update(status) }
        }
    }

    private func update(_ status: StatusSnapshot?) {
        for event in MenuBarState.events(from: snapshot, to: status) { notify(event) }
        snapshot = status
    }

    func send(_ action: String, to job: Int64) {
        queue.async { [paths] in
            var request = Message(type: action)
            request.target = "\(job)"
            let reply = Client.connect(socketPath: paths.socket)?.roundTrip(request)
            DispatchQueue.main.async {
                self.message = reply?.text ?? "The daemon didn't answer"
                self.poll()
            }
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            message = "Couldn't change the login item: \(error.localizedDescription)"
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    private func notify(_ event: MenuBarState.Event) {
        guard bundled else { return }
        let content = UNMutableNotificationContent()
        content.title = event.title
        content.body = event.body
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}
