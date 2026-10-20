import AppKit
import Observation
import os

/// Finds providers on this Mac, connects to each, and keeps their controls and state up to date (SPEC.md).
///
/// ```swift
/// let consumer = ApplugConsumer(name: "Action Hero")
/// consumer.start()
/// // consumer.providers updates as apps come and go (it's @Observable)
/// consumer.tap(app: "com.idallas.thuner", id: "radio")
/// ```
@MainActor
@Observable
public final class ApplugConsumer {
    /// An app offering controls, connected or remembered.
    public struct Provider: Identifiable, Equatable, Sendable, Codable {
        public var id: String { app }
        public let app: String
        public var name: String
        public var version: String?
        /// Known kinds only, in the provider's order. Without state while it's away.
        public var controls: [Control]
        public var isConnected: Bool

        public init(app: String, name: String, version: String? = nil, controls: [Control] = [], isConnected: Bool = false) {
            self.app = app
            self.name = name
            self.version = version
            self.controls = controls
            self.isConnected = isConnected
        }

        public func control(_ id: String) -> Control? { controls.first { $0.id == id } }

        /// What to save to remember it: its controls without their state.
        public var remembered: Provider {
            Provider(app: app, name: name, version: version, controls: controls.map(\.definition), isConnected: false)
        }
    }

    public let identity: Hello
    /// In the order they were first seen. A provider appears once it has connected and sent its controls
    /// (or was passed to `remember(_:)`).
    public private(set) var providers: [Provider] = []

    /// A meter's peak levels (dBFS per channel), for meters you're watching.
    @ObservationIgnored public var onMeter: ((_ app: String, _ id: String, _ levels: [Double]) -> Void)?
    /// A provider's controls or state changed, or it connected or went away.
    @ObservationIgnored public var onChange: ((Provider) -> Void)?
    /// A provider sent an `error`.
    @ObservationIgnored public var onError: ((_ app: String, _ message: String) -> Void)?

    @ObservationIgnored private let discovery: Discovery
    /// Each provider's connection.
    @ObservationIgnored private var links: [String: Link] = [:]
    /// A second connection, to a port newly announced for a provider that's already connected.
    /// It replaces the first only once the app there proves to be the same one.
    @ObservationIgnored private var candidates: [String: Link] = [:]
    /// Meters wanted per provider, kept across reconnects.
    @ObservationIgnored private var wantedMeters: [String: Set<String>] = [:]
    @ObservationIgnored private let observers = ObserverBag()
    @ObservationIgnored private var running = false
    @ObservationIgnored private var requeryTask: Task<Void, Never>?
    @ObservationIgnored private var requeryDelay: Duration = .seconds(3)
    @ObservationIgnored private let log = Logger(subsystem: "dev.applug", category: "consumer")

    public init(
        app: String = Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName,
        name: String,
        version: String? = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
        discovery: Discovery = .standard
    ) {
        self.identity = Hello(app: Limits.name(app), name: Limits.name(name), version: version.map(Limits.name))
        self.discovery = discovery
    }

    // MARK: Starting and stopping

    /// Starts listening for providers and asks who's there.
    public func start() {
        guard !running else { return }
        running = true
        discovery.observe(discovery.announceName, in: observers) { [weak self] object in
            guard let object, let announcement = Announcement(json: object) else { return }
            self?.announced(announcement)
        }
        discovery.observe(discovery.goodbyeName, in: observers) { [weak self] object in
            guard let object, let announcement = Announcement(json: object) else { return }
            self?.heardGoodbye(announcement)
        }
        query()
    }

    public func stop() {
        guard running else { return }
        running = false
        observers.removeAll()
        requeryTask?.cancel()
        requeryTask = nil
        let all = Array(links.values) + Array(candidates.values)
        links.removeAll()
        candidates.removeAll()
        for link in all { link.connection.close() }
        for provider in providers where provider.isConnected {
            modify(provider.app) { $0 = $0.remembered }
        }
    }

    /// Asks every provider to announce itself again.
    public func query() {
        discovery.post(discovery.queryName, object: nil)
    }

    /// Restores providers saved earlier (`Provider.remembered`), so their controls can be shown while they're away.
    public func remember(_ saved: [Provider]) {
        for provider in saved where self.provider(provider.app) == nil && providers.count < Limits.maxProviders {
            let app = Limits.name(provider.app)
            guard !app.isEmpty else { continue }
            let name = Limits.name(provider.name)
            providers.append(Provider(
                app: app, name: name.isEmpty ? app : name, version: provider.version.map(Limits.name),
                controls: Limits.tidy(provider.controls.filter(\.kind.isKnown)).map(\.definition)
            ))
        }
    }

    /// Drops a provider that isn't connected.
    public func forget(_ app: String) {
        guard links[app] == nil else { return }
        providers.removeAll { $0.app == app }
        wantedMeters[app] = nil
    }

    public func provider(_ app: String) -> Provider? { providers.first { $0.app == app } }

    // MARK: Using controls

    /// Moves a level to `value` (0…1). Returns false if there's no such level to turn right now.
    @discardableResult
    public func turn(app: String, id: String, value: Double) -> Bool {
        guard let link = readyLink(app), let control = provider(app)?.control(id), control.isTurnable, control.kind == .level else { return false }
        link.connection.send(.turn(id: id, value: Limits.value(value), steps: nil))
        return true
    }

    /// Moves a steps control by `steps` (negative goes back).
    @discardableResult
    public func turn(app: String, id: String, steps: Int) -> Bool {
        guard steps != 0, let link = readyLink(app), let control = provider(app)?.control(id), control.kind == .steps else { return false }
        link.connection.send(.turn(id: id, value: nil, steps: min(max(steps, -Message.maxSteps), Message.maxSteps)))
        return true
    }

    /// Presses (`down: true`) or lets go of a control.
    @discardableResult
    public func press(app: String, id: String, down: Bool) -> Bool {
        guard let link = readyLink(app), let control = provider(app)?.control(id), control.kind.presses else { return false }
        link.connection.send(.press(id: id, down: down))
        return true
    }

    /// Presses and lets go, for a tap or a click.
    @discardableResult
    public func tap(app: String, id: String) -> Bool {
        guard press(app: app, id: id, down: true) else { return false }
        return press(app: app, id: id, down: false)
    }

    /// Starts or stops receiving a meter's levels (through `onMeter`). Kept across reconnects.
    public func watchMeter(app: String, id: String, _ on: Bool) {
        var wanted = wantedMeters[app] ?? []
        guard on ? wanted.insert(id).inserted : wanted.remove(id) != nil else { return }
        wantedMeters[app] = wanted
        if let link = readyLink(app), provider(app)?.control(id)?.kind == .meter {
            if on { link.subscribed.insert(id) } else { link.subscribed.remove(id) }
            link.connection.send(.meterSubscribe(id: id, on: on))
        }
    }

    // MARK: Connecting

    /// Connects to a provider at a known port, as if it had announced itself.
    public func connect(_ announcement: Announcement) {
        announced(announcement)
    }

    private func announced(_ announcement: Announcement) {
        let app = announcement.app
        guard running, announcement.protocol >= applugProtocolVersion, app != identity.app, Self.plausible(announcement) else { return }
        if let link = links[app] {
            guard link.port != announcement.port else { return }
            if link.ready {
                // Maybe it restarted, maybe someone's pretending. Try the new port alongside the working one.
                guard candidates[app]?.port != announcement.port else { return }
                candidates[app]?.connection.close()
                candidates[app] = open(announcement)
                return
            }
            link.replaced = true
            link.connection.close()
        } else {
            // However many apps announce themselves, keep the list (and connections) bounded.
            let known = provider(app) != nil
            guard known || providers.count + links.count < Limits.maxProviders else { return }
        }
        links[app] = open(announcement)
    }

    /// A cheap check against an app announcing itself as another: if an app with that bundle
    /// identifier is running, the announcement must come from it.
    private static func plausible(_ announcement: Announcement) -> Bool {
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: announcement.app)
        guard !running.isEmpty else { return true }
        guard let pid = announcement.pid else { return false }
        return running.contains { $0.processIdentifier == pid }
    }

    private func open(_ announcement: Announcement) -> Link {
        let app = announcement.app
        let connection = LineConnection.loopback(port: announcement.port)
        let link = Link(app: app, name: announcement.name, connection: connection, port: announcement.port)
        let hello = Hello(app: identity.app, name: identity.name, version: identity.version, key: announcement.key)
        connection.onReady = { [weak connection] in connection?.send(.hello(hello)) }
        connection.onMessage = { [weak self, weak link] message in
            guard let self, let link else { return }
            self.handle(message, link: link)
        }
        connection.onClose = { [weak self, weak link] in
            guard let self, let link else { return }
            self.closed(link)
        }
        link.handshakeTimeout = Task { [weak link] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled, let link, !link.ready else { return }
            link.connection.close(sayingError: "No controls")
        }
        connection.start()
        return link
    }

    /// A goodbye is only a hint (anyone can post one): it means "don't look for me if the connection drops".
    private func heardGoodbye(_ announcement: Announcement) {
        guard let link = links[announcement.app], link.port == announcement.port else { return }
        link.goodbyeHeard = true
    }

    private func closed(_ link: Link) {
        link.handshakeTimeout?.cancel()
        let app = link.app
        if candidates[app] === link {
            candidates[app] = nil
            return
        }
        guard links[app] === link else { return }
        links[app] = nil
        modify(app) { $0 = $0.remembered }
        // The provider restarted and its new port is already being tried: that's its connection now.
        if let candidate = candidates.removeValue(forKey: app) {
            links[app] = candidate
            return
        }
        // Dropped without a goodbye: maybe it restarted its listener. Ask again shortly.
        if running && !link.replaced && !link.goodbyeHeard { requery() }
    }

    /// Asks again after a while, backing off from 3 seconds to a minute while nothing connects.
    private func requery() {
        guard requeryTask == nil else { return }
        let delay = requeryDelay
        requeryDelay = min(requeryDelay * 2, .seconds(60))
        requeryTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, !Task.isCancelled else { return }
            self.requeryTask = nil
            if self.running { self.query() }
        }
    }

    private func readyLink(_ app: String) -> Link? {
        guard let link = links[app], link.ready else { return nil }
        return link
    }

    private func handle(_ message: Message, link: Link) {
        let app = link.app
        switch message {
        case .hello(let hello):
            guard !link.heardHello else { return }
            guard hello.app == app else {
                return link.connection.close(sayingError: "Announced as \(app), but said hello as \(hello.app)")
            }
            link.heardHello = true
            link.name = hello.name
            link.version = hello.version
        case .controls(let list):
            guard link.heardHello else { return link.connection.close(sayingError: "Send hello first") }
            let controls = Limits.tidy(list.filter(\.kind.isKnown))
            let firstList = !link.ready
            if firstList { becameReady(link) }
            guard links[app] === link else { return }
            modify(app) { provider in
                provider.name = link.name
                provider.version = link.version
                provider.controls = controls
                provider.isConnected = true
            }
            // Subscriptions belong to the connection: renew them with the first list, and for meters that just appeared.
            let meters = Set(controls.filter { $0.kind == .meter }.map(\.id))
            let wanted = (wantedMeters[app] ?? []).intersection(meters)
            for id in wanted where firstList || !link.subscribed.contains(id) {
                link.connection.send(.meterSubscribe(id: id, on: true))
            }
            link.subscribed = wanted
        case .update(let update):
            guard link.ready, links[app] === link else { return }
            modify(app) { provider in
                guard let index = provider.controls.firstIndex(where: { $0.id == update.id }) else { return }
                provider.controls[index].apply(update)
            }
        case .meter(let id, let levels):
            guard link.ready, links[app] === link, wantedMeters[app]?.contains(id) == true,
                  let meter = provider(app)?.control(id), meter.kind == .meter
            else { return }
            onMeter?(app, id, Array(levels.prefix(meter.channels ?? 1)))
        case .error(let text):
            log.info("\(app, privacy: .private) says: \(text, privacy: .private)")
            onError?(app, text)
        default:
            break
        }
    }

    /// A connection's first controls: it's the provider's connection from now on.
    private func becameReady(_ link: Link) {
        let app = link.app
        link.ready = true
        link.handshakeTimeout?.cancel()
        requeryDelay = .seconds(3)
        if candidates[app] === link {
            // The newly announced port answered as the same app: switch to it.
            candidates[app] = nil
            let old = links[app]
            links[app] = link
            old?.replaced = true
            old?.connection.close()
        }
        guard links[app] === link else { return }
        if provider(app) == nil {
            guard providers.count < Limits.maxProviders else { return link.connection.close() }
            providers.append(Provider(app: app, name: link.name))
        }
    }

    private func modify(_ app: String, _ change: (inout Provider) -> Void) {
        guard let index = providers.firstIndex(where: { $0.app == app }) else { return }
        var provider = providers[index]
        change(&provider)
        guard provider != providers[index] else { return }
        providers[index] = provider
        onChange?(provider)
    }
}

/// The consumer's connection to one provider.
@MainActor
private final class Link {
    let app: String
    var name: String
    var version: String?
    let connection: LineConnection
    let port: UInt16
    var heardHello = false
    /// It has sent its controls.
    var ready = false
    var goodbyeHeard = false
    /// Closed because another connection took over: no need to look for the provider again.
    var replaced = false
    /// Meters subscribed on this connection.
    var subscribed: Set<String> = []
    var handshakeTimeout: Task<Void, Never>?

    init(app: String, name: String, connection: LineConnection, port: UInt16) {
        self.app = app
        self.name = name
        self.connection = connection
        self.port = port
    }
}
