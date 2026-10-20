import Foundation
import Network
import os

/// Offers an app's controls to any consumer on this Mac (SPEC.md).
///
/// ```swift
/// let provider = ApplugProvider(name: "ThUNER", controls: [
///     Control(id: "radio", name: "Radio Mode", kind: .toggle, on: false),
/// ])
/// provider.onPress = { press in if press.down { model.radio.toggle() } }
/// provider.start()
/// // whenever the state changes, and after every turn or press:
/// provider.set("radio", text: model.radio ? "On" : "Off", on: model.radio)
/// ```
@MainActor
public final class ApplugProvider {
    /// A consumer moved a level or steps control.
    public struct Turn: Sendable {
        public let id: String
        /// A level's new position, 0…1.
        public let value: Double?
        /// A steps control's movement (negative goes back).
        public let steps: Int?
        public let from: Hello

        public init(id: String, value: Double? = nil, steps: Int? = nil, from: Hello) {
            self.id = id
            self.value = value
            self.steps = steps
            self.from = from
        }
    }

    /// A consumer pressed (`down`) or let go of a control.
    public struct Press: Sendable {
        public let id: String
        public let down: Bool
        public let from: Hello

        public init(id: String, down: Bool, from: Hello) {
            self.id = id
            self.down = down
            self.from = from
        }
    }

    public let identity: Hello
    public private(set) var controls: [Control]
    /// The port it's listening on, once it is.
    public private(set) var port: UInt16?
    /// Consumers that have said hello.
    public var consumers: [Hello] { sessions.compactMap { $0.ready ? $0.peer : nil } }
    /// Meters at least one consumer is watching. Measure only these.
    public private(set) var watchedMeters: Set<String> = []
    /// Why it isn't listening, if it isn't.
    public private(set) var problem: String?

    public var onTurn: ((Turn) -> Void)?
    public var onPress: ((Press) -> Void)?
    public var onWatchedMetersChange: ((Set<String>) -> Void)?
    public var onConsumersChange: (([Hello]) -> Void)?

    /// Announced, and required in every consumer's `hello`. New at each `start()`.
    private(set) var key = Announcement.makeKey()

    private let discovery: Discovery
    private let listenerHandle = ListenerHandle()
    private var listener: NWListener? { listenerHandle.listener }
    private var sessions: [Session] = []
    private let observers = ObserverBag()
    private var running = false
    private var restartTask: Task<Void, Never>?
    /// Controls touched by a turn or press since their last update: the next `set` goes out even if nothing changed.
    private var echoDue: Set<String> = []
    private var lastAnnounce: ContinuousClock.Instant?
    private var announceTask: Task<Void, Never>?
    private let log = Logger(subsystem: "dev.applug", category: "provider")

    public init(
        app: String = Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName,
        name: String,
        version: String? = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
        controls: [Control],
        discovery: Discovery = .standard
    ) {
        self.identity = Hello(app: Limits.name(app), name: Limits.name(name), version: version.map(Limits.name))
        self.controls = Limits.tidy(controls)
        self.discovery = discovery
    }

    // MARK: Starting and stopping

    public func start() {
        guard !running else { return }
        running = true
        key = Announcement.makeKey()
        discovery.observe(discovery.queryName, in: observers) { [weak self] _ in self?.announceSoon() }
        listen()
    }

    /// Says goodbye and closes every connection.
    public func stop() {
        guard running else { return }
        running = false
        if let port { discovery.post(discovery.goodbyeName, object: announcement(port: port).json) }
        observers.removeAll()
        restartTask?.cancel()
        restartTask = nil
        announceTask?.cancel()
        announceTask = nil
        listenerHandle.replace(with: nil, goodbye: nil)
        port = nil
        for session in sessions { session.connection.close() }
        sessions.removeAll()
        updateWatchedMeters()
    }

    private func listen() {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        let listener: NWListener
        do {
            listener = try NWListener(using: parameters)
        } catch {
            fail("Couldn't listen: \(error.localizedDescription)")
            return
        }
        listenerHandle.replace(with: listener, goodbye: nil)
        listener.newConnectionHandler = { [weak self] connection in
            MainActor.assumeIsolated {
                guard let self, self.hasRoom else { return connection.cancel() }
                self.adopt(LineConnection(connection))
            }
        }
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            MainActor.assumeIsolated {
                guard let self, let listener, listener === self.listener else { return }
                switch state {
                case .ready:
                    guard let port = listener.port?.rawValue else { return }
                    self.port = port
                    self.problem = nil
                    // If this provider is released without stop(), the handle still says goodbye.
                    self.listenerHandle.replace(with: listener, goodbye: (self.discovery, self.announcement(port: port).json))
                    self.announce()
                case .failed(let error):
                    self.fail("Couldn't listen: \(error.localizedDescription)")
                default:
                    break
                }
            }
        }
        listener.start(queue: .main)
    }

    /// Whether another consumer can connect: at most 64, and at most 16 still to say hello.
    private var hasRoom: Bool {
        sessions.count < Limits.maxConnections
            && sessions.filter { !$0.ready }.count < Limits.maxConnectionsBeforeHello
    }

    private func fail(_ message: String) {
        log.error("\(message, privacy: .public)")
        problem = message
        listenerHandle.replace(with: nil, goodbye: nil)
        port = nil
        restartTask?.cancel()
        restartTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard let self, !Task.isCancelled, self.running else { return }
            self.listen()
        }
    }

    private func announcement(port: UInt16) -> Announcement {
        Announcement(app: identity.app, name: identity.name, port: port, key: key, pid: ProcessInfo.processInfo.processIdentifier)
    }

    private func announce() {
        guard running, let port else { return }
        lastAnnounce = .now
        discovery.post(discovery.announceName, object: announcement(port: port).json)
    }

    /// Answers a query: at most one announcement a second, however many queries arrive.
    private func announceSoon() {
        guard running, announceTask == nil else { return }
        let wait = lastAnnounce.map { .seconds(1) - (ContinuousClock.now - $0) } ?? .zero
        guard wait > .zero else { return announce() }
        announceTask = Task { [weak self] in
            try? await Task.sleep(for: wait)
            guard let self, !Task.isCancelled else { return }
            self.announceTask = nil
            self.announce()
        }
    }

    // MARK: Changing controls

    /// Replaces the list of controls (and their state), and sends it to every consumer.
    public func setControls(_ controls: [Control]) {
        self.controls = Limits.tidy(controls)
        echoDue.formIntersection(self.controls.map(\.id))
        for session in sessions where session.ready {
            session.connection.send(.controls(self.controls))
            session.subscriptions.formIntersection(meterIDs)
        }
        updateWatchedMeters()
    }

    /// Changes a control's state. Sends only what changed, except right after a turn or press,
    /// when the state goes out regardless so consumers settle on it.
    public func set(_ id: String, value: Double? = nil, text: String? = nil, on: Bool? = nil) {
        change(Update(id: id, value: value, text: text.map { .some($0) }, on: on))
    }

    /// Removes a control's text.
    public func clearText(_ id: String) {
        change(Update(id: id, text: .some(nil)))
    }

    private func change(_ requested: Update) {
        let id = requested.id
        guard let index = controls.firstIndex(where: { $0.id == id }) else { return }
        let old = controls[index]
        controls[index].apply(requested)
        let now = controls[index]

        var update = Update(id: id)
        if now.value != old.value { update.value = now.value }
        if now.text != old.text { update.text = .some(now.text) }
        if now.on != old.on { update.on = now.on }
        if echoDue.remove(id) != nil {
            if update.value == nil { update.value = now.value }
            if update.text == nil, let text = now.text { update.text = .some(text) }
            if update.on == nil { update.on = now.on }
        }
        guard !update.isEmpty else { return }
        broadcast(update)
    }

    /// Renames a control.
    public func rename(_ id: String, to name: String) {
        let name = Limits.name(name)
        guard !name.isEmpty, let index = controls.firstIndex(where: { $0.id == id }), controls[index].name != name else { return }
        controls[index].name = name
        broadcast(Update(id: id, name: name))
    }

    /// Sends a meter's peak levels (dBFS per channel) to consumers watching it. About 20 times a second.
    public func sendMeter(_ id: String, levels: [Double]) {
        guard watchedMeters.contains(id), !levels.isEmpty else { return }
        let rounded = levels.prefix(2).map(Limits.meterLevel)
        for session in sessions where session.ready && session.subscriptions.contains(id) {
            session.connection.send(.meter(id: id, levels: rounded))
        }
    }

    private func broadcast(_ update: Update) {
        for session in sessions where session.ready {
            session.connection.send(.update(update))
        }
    }

    private var meterIDs: Set<String> { Set(controls.filter { $0.kind == .meter }.map(\.id)) }

    // MARK: Connections

    private func adopt(_ connection: LineConnection) {
        let session = Session(connection: connection)
        sessions.append(session)
        connection.maxLine = Limits.maxLineBeforeHello
        connection.onMessage = { [weak self, weak session] message in
            guard let self, let session else { return }
            self.handle(message, from: session)
        }
        connection.onClose = { [weak self, weak session] in
            guard let self, let session else { return }
            session.handshakeTimeout?.cancel()
            self.sessions.removeAll { $0 === session }
            if session.ready { self.onConsumersChange?(self.consumers) }
            self.updateWatchedMeters()
        }
        // A consumer has a few seconds to say hello.
        session.handshakeTimeout = Task { [weak session] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, let session, !session.ready else { return }
            session.connection.close(sayingError: "Send hello first")
        }
        connection.start()
    }

    private func handle(_ message: Message, from session: Session) {
        switch message {
        case .hello(let hello):
            guard !session.ready else { return }   // a second hello changes nothing
            guard let offered = hello.key, Self.same(offered, key) else {
                return session.connection.close(sayingError: "hello needs the \"key\" from the announcement")
            }
            session.peer = Hello(app: hello.app, name: hello.name, version: hello.version, protocolVersion: hello.protocolVersion)
            session.ready = true
            session.handshakeTimeout?.cancel()
            session.connection.maxLine = Limits.maxLine
            session.connection.send(.hello(identity))
            session.connection.send(.controls(controls))
            onConsumersChange?(consumers)
        case _ where !session.ready:
            session.connection.close(sayingError: "Send hello first")
        case .turn(let id, let value, let steps):
            guard let control = control(id) else {
                return session.connection.send(.error("No control \"\(id)\""))
            }
            // Turns on things that don't turn are ignored (SPEC.md › turn).
            guard control.isTurnable, let peer = session.peer else { return }
            if control.kind == .level, let value {
                echoDue.insert(id)
                onTurn?(Turn(id: id, value: Limits.clamp(value), from: peer))
            } else if control.kind == .steps, let steps, steps != 0 {
                echoDue.insert(id)
                onTurn?(Turn(id: id, steps: steps, from: peer))
            }
        case .press(let id, let down):
            guard let control = control(id) else {
                return session.connection.send(.error("No control \"\(id)\""))
            }
            guard control.kind.presses, let peer = session.peer else { return }
            echoDue.insert(id)
            onPress?(Press(id: id, down: down, from: peer))
        case .meterSubscribe(let id, let on):
            guard let control = control(id), control.kind == .meter else {
                return session.connection.send(.error("No meter \"\(id)\""))
            }
            if on { session.subscriptions.insert(id) } else { session.subscriptions.remove(id) }
            updateWatchedMeters()
        case .error(let text):
            log.info("\(session.peer?.name ?? "consumer", privacy: .private) says: \(text, privacy: .private)")
        default:
            break
        }
    }

    private func control(_ id: String) -> Control? {
        controls.first { $0.id == id }
    }

    private func updateWatchedMeters() {
        let watched = sessions.reduce(into: Set<String>()) { $0.formUnion($1.subscriptions) }
        guard watched != watchedMeters else { return }
        watchedMeters = watched
        onWatchedMetersChange?(watched)
    }

    /// Compares keys without stopping at the first difference.
    private static func same(_ a: String, _ b: String) -> Bool {
        let a = Array(a.utf8), b = Array(b.utf8)
        guard a.count == b.count else { return false }
        return zip(a, b).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }
}

/// One consumer's connection to a provider.
@MainActor
private final class Session {
    let connection: LineConnection
    var peer: Hello?
    var ready = false
    var subscriptions: Set<String> = []
    var handshakeTimeout: Task<Void, Never>?

    init(connection: LineConnection) {
        self.connection = connection
    }
}

/// Holds the listener so that a provider released without `stop()` still stops listening
/// and says goodbye, instead of leaving an open port that accepts connections nobody handles.
private final class ListenerHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var current: NWListener?
    private var goodbye: (Discovery, String)?

    var listener: NWListener? { lock.withLock { current } }

    func replace(with listener: NWListener?, goodbye: (Discovery, String)?) {
        let old: NWListener? = lock.withLock {
            let old = current
            current = listener
            self.goodbye = goodbye
            return old
        }
        if let old, old !== listener { old.cancel() }
    }

    deinit {
        current?.cancel()
        if let (discovery, json) = goodbye { discovery.post(discovery.goodbyeName, object: json) }
    }
}
