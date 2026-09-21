import Foundation
import ServiceManagement
import TurnstileCore
import UserNotifications

/// Polls the daemon's status. It never starts or keeps the daemon alive: when it's idle, the menu says so and waits.
final class Monitor: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    @Published private(set) var snapshot: StatusSnapshot?
    @Published private(set) var message: String?
    @Published private(set) var launchAtLogin = false
    @Published private(set) var evidence: Health.Evidence?
    /// Read on every poll, so a `turnstile disable` in a shell shows within seconds.
    @Published private(set) var disabled = false
    /// A flag file like `disabled`, so it holds across daemon restarts.
    @Published private(set) var queuePaused = false
    @Published private(set) var notifying = Set(MenuBarState.Event.Kind.allCases.filter { Monitor.isOn($0) })

    private let paths = Paths()
    private let queue = DispatchQueue(label: "turnstile.monitor")
    private var timer: Timer?
    private var healthTimer: Timer?
    /// Notifications and login items need a real app bundle, which `swift run` doesn't give us.
    private let bundled = Bundle.main.bundleIdentifier != nil

    var canLaunchAtLogin: Bool { bundled }
    var canNotify: Bool { bundled }

    override init() {
        super.init()
        if bundled {
            launchAtLogin = SMAppService.mainApp.status == .enabled
            let center = UNUserNotificationCenter.current()
            center.delegate = self
            center.setNotificationCategories(Set(MenuBarState.Event.Kind.allCases.filter { !$0.actions.isEmpty }.map(Monitor.category)))
            center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
        poll()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.poll() }
        checkHealth()
        // None of what this checks changes quickly.
        healthTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in self?.checkHealth() }
    }

    /// A fixed snapshot for rendering the panel: no polling, no notifications, no daemon.
    init(fixture: StatusSnapshot?, disabled: Bool = false, queuePaused: Bool = false) {
        super.init()
        snapshot = fixture
        self.disabled = disabled
        self.queuePaused = queuePaused
        evidence = nil
    }

    /// Skew is derived from each status poll; the rest comes from the filesystem, never from starting the daemon.
    var health: [Health.Finding] {
        evidence.map { Health.findings($0, snapshot: snapshot) } ?? []
    }

    func checkHealth() {
        queue.async { [paths] in
            let evidence = Health.gather(paths: paths)
            DispatchQueue.main.async { self.evidence = evidence }
        }
    }

    func poll() {
        queue.async { [paths] in
            let status = Client.connect(socketPath: paths.socket)?.roundTrip(Message(type: "status"), timeout: 2)?.status
            let disabled = paths.isDisabled
            let queuePaused = paths.isQueuePaused
            DispatchQueue.main.async {
                self.disabled = disabled
                self.queuePaused = queuePaused
                self.update(status)
            }
        }
    }

    private func update(_ status: StatusSnapshot?) {
        for event in MenuBarState.events(from: snapshot, to: status) where notifying.contains(event.kind) { notify(event) }
        snapshot = status
        // A running daemon usually means a shim just registered something, so don't wait five minutes to say so.
        if status != nil, let evidence, evidence.lastGated == nil { checkHealth() }
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

    /// A flag file the shims read, so it works whether or not the daemon is running.
    func setGating(_ enabled: Bool) {
        do {
            try paths.setDisabled(!enabled)
        } catch {
            message = "Couldn't turn gating \(enabled ? "on" : "off"): \(error.localizedDescription)"
        }
        disabled = paths.isDisabled
    }

    /// Running jobs carry on; the daemon picks the change up on its next tick.
    func setQueuePaused(_ paused: Bool) {
        do {
            try paths.setQueuePaused(paused)
        } catch {
            message = "Couldn't \(paused ? "pause" : "resume") the queue: \(error.localizedDescription)"
        }
        queuePaused = paths.isQueuePaused
    }

    func clearMessage() {
        message = nil
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            message = "Couldn't change the login item: \(error.localizedDescription)"
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func setNotifying(_ kind: MenuBarState.Event.Kind, _ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: Monitor.defaultsKey(kind))
        if enabled { notifying.insert(kind) } else { notifying.remove(kind) }
    }

    private static func defaultsKey(_ kind: MenuBarState.Event.Kind) -> String { "notify.\(kind.rawValue)" }

    private static func isOn(_ kind: MenuBarState.Event.Kind) -> Bool {
        UserDefaults.standard.object(forKey: defaultsKey(kind)) as? Bool ?? kind.isOnByDefault
    }

    private static func category(_ kind: MenuBarState.Event.Kind) -> UNNotificationCategory {
        let actions = kind.actions.map {
            UNNotificationAction(identifier: $0.message, title: $0.title, options: $0.message == "kill" ? [.destructive] : [])
        }
        return UNNotificationCategory(identifier: kind.rawValue, actions: actions, intentIdentifiers: [])
    }

    private func notify(_ event: MenuBarState.Event) {
        guard bundled else { return }
        let content = UNMutableNotificationContent()
        content.title = event.title
        content.body = event.body
        content.categoryIdentifier = event.kind.rawValue
        if let job = event.job { content.userInfo = ["job": job] }
        switch event.kind.urgency {
        case .passive: content.interruptionLevel = .passive
        case .active: content.interruptionLevel = .active
        case .timeSensitive: content.interruptionLevel = .timeSensitive
        }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    /// Resume or Kill from a notification goes through the same control path as the menu.
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        let content = response.notification.request.content
        let kind = MenuBarState.Event.Kind(rawValue: content.categoryIdentifier)
        if let job = content.userInfo["job"] as? Int64, kind?.actions.contains(where: { $0.message == response.actionIdentifier }) == true {
            DispatchQueue.main.async { self.send(response.actionIdentifier, to: job) }
        }
        completionHandler()
    }
}
