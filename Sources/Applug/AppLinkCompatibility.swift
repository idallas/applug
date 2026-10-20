import AppKit

/// How a provider reaches Twist Commando versions that only speak App Link (SPEC.md › App Link 1 and 2).
public struct AppLinkCompatibility: Sendable, Equatable {
    /// Twist Commando's App Link port.
    public var port: UInt16
    /// Connect only while an app whose bundle identifier starts with this is running.
    /// `nil` connects regardless (tests).
    public var onlyWhileRunning: String?
    /// The first retry's delay (it doubles to a minute), and how long to wait for Twist Commando's
    /// welcome. Only tests change these.
    var retryDelay: Duration = .seconds(4)
    var welcomeTimeout: Duration = .seconds(5)

    public init(port: UInt16 = 9034, onlyWhileRunning: String? = "com.twistcommando.") {
        self.port = port
        self.onlyWhileRunning = onlyWhileRunning
    }
}

/// Decides when to connect to the App Link port: while Twist Commando runs, retrying with backoff,
/// and not at all to a Twist Commando that said it finds Applug providers itself.
@MainActor
final class AppLinkDialer {
    let settings: AppLinkCompatibility
    private let connect: (LineConnection) -> Void
    private var connection: LineConnection?
    private var retryTask: Task<Void, Never>?
    private var delay: Duration
    /// Twist Commando processes that speak Applug. Forgotten when they quit.
    private var applugSpeakers: Set<pid_t> = []
    private let observers = ObserverBag(NSWorkspace.shared.notificationCenter)
    private var running = false

    init(settings: AppLinkCompatibility, connect: @escaping (LineConnection) -> Void) {
        self.settings = settings
        self.connect = connect
        self.delay = settings.retryDelay
    }

    func start() {
        guard !running else { return }
        running = true
        let center = observers.center
        observers.add(center.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let bundle = app?.bundleIdentifier
            MainActor.assumeIsolated { self?.launched(bundle) }
        })
        observers.add(center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let pid = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
            MainActor.assumeIsolated { if let pid { self?.applugSpeakers.remove(pid) } }
        })
        attempt()
    }

    func stop() {
        running = false
        observers.removeAll()
        retryTask?.cancel()
        retryTask = nil
        connection?.close()
        connection = nil
    }

    /// The connection closed. `wasReady`: it got as far as a welcome.
    func ended(wasReady: Bool) {
        connection = nil
        guard running else { return }
        if wasReady { delay = settings.retryDelay }
        schedule(after: delay)
        delay = min(delay * 2, .seconds(60))
    }

    /// The Twist Commando that's running speaks Applug: leave it alone until it relaunches.
    func suppress() {
        if let pid = targetPID() { applugSpeakers.insert(pid) }
    }

    private func launched(_ bundle: String?) {
        guard running, let prefix = settings.onlyWhileRunning, bundle?.hasPrefix(prefix) == true else { return }
        delay = settings.retryDelay
        schedule(after: .seconds(1))
    }

    private func schedule(after delay: Duration) {
        retryTask?.cancel()
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, !Task.isCancelled else { return }
            self.retryTask = nil
            self.attempt()
        }
    }

    private func attempt() {
        guard running, connection == nil, let pid = targetPID(), !applugSpeakers.contains(pid) else { return }
        let connection = LineConnection.loopback(port: settings.port)
        self.connection = connection
        connect(connection)
    }

    /// Twist Commando's process id while it runs (the app itself, not a helper); 0 when no app is required.
    private func targetPID() -> pid_t? {
        guard let prefix = settings.onlyWhileRunning else { return 0 }
        let matches = NSWorkspace.shared.runningApplications.filter { $0.bundleIdentifier?.hasPrefix(prefix) == true }
        return (matches.first { $0.activationPolicy != .prohibited } ?? matches.first)?.processIdentifier
    }
}
