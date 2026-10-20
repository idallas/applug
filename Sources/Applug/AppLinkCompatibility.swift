import AppKit
import Darwin

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
        // Only dial if a Twist Commando in this session is the one listening on the port. Otherwise
        // something else grabbed it first (another account's process, say, since loopback ports are
        // shared across accounts), and connecting would hand it our controls and let it drive them.
        // There's no key on the App Link port, so this ownership check is what keeps it to our own apps.
        guard trustsListener(onPort: settings.port) else {
            // The app is running but isn't on the port yet, or isn't the one holding it. Look again later.
            schedule(after: delay)
            delay = min(delay * 2, .seconds(60))
            return
        }
        let connection = LineConnection.loopback(port: settings.port)
        self.connection = connection
        connect(connection)
    }

    /// Whether a running `onlyWhileRunning` app owns the listening socket on `port`. True in tests,
    /// which set `onlyWhileRunning` to nil to dial a fake listener regardless.
    private func trustsListener(onPort port: UInt16) -> Bool {
        guard let prefix = settings.onlyWhileRunning else { return true }
        let pids = NSWorkspace.shared.runningApplications
            .filter { $0.bundleIdentifier?.hasPrefix(prefix) == true }
            .map(\.processIdentifier)
        return pids.contains { Self.process($0, listensOn: port) }
    }

    /// Whether process `pid` holds a TCP socket listening on `port` (local port set, no peer).
    private static func process(_ pid: pid_t, listensOn port: UInt16) -> Bool {
        let size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard size > 0 else { return false }
        let capacity = Int(size) / MemoryLayout<proc_fdinfo>.stride
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: capacity)
        let written = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, size)
        guard written > 0 else { return false }
        let count = min(Int(written) / MemoryLayout<proc_fdinfo>.stride, capacity)
        for fd in fds.prefix(count) where fd.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
            var info = socket_fdinfo()
            let infoSize = Int32(MemoryLayout<socket_fdinfo>.size)
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &info, infoSize) == infoSize,
                  info.psi.soi_kind == SOCKINFO_TCP else { continue }
            let socket = info.psi.soi_proto.pri_tcp.tcpsi_ini
            let localPort = UInt16(bigEndian: UInt16(truncatingIfNeeded: socket.insi_lport))
            let peerPort = UInt16(bigEndian: UInt16(truncatingIfNeeded: socket.insi_fport))
            if localPort == port && peerPort == 0 { return true }
        }
        return false
    }

    /// Twist Commando's process id while it runs (the app itself, not a helper); 0 when no app is required.
    private func targetPID() -> pid_t? {
        guard let prefix = settings.onlyWhileRunning else { return 0 }
        let matches = NSWorkspace.shared.runningApplications.filter { $0.bundleIdentifier?.hasPrefix(prefix) == true }
        return (matches.first { $0.activationPolicy != .prohibited } ?? matches.first)?.processIdentifier
    }
}
