import Foundation

/// A provider saying where it listens (the `object` of `announce` and `goodbye`).
public struct Announcement: Equatable, Sendable {
    public var app: String
    public var name: String
    public var port: UInt16
    public var `protocol`: Int
    /// What consumers send back in their `hello`. Distributed notifications reach only this user's
    /// processes, so other accounts on the Mac (and web pages) can't learn it.
    public var key: String
    /// The provider's process, so consumers can check it really is the app it says.
    public var pid: Int32?

    public init(app: String, name: String, port: UInt16, protocol: Int = applugProtocolVersion, key: String, pid: Int32? = nil) {
        self.app = app
        self.name = name
        self.port = port
        self.protocol = `protocol`
        self.key = key
        self.pid = pid
    }

    /// The JSON string posted as a notification's object.
    public var json: String {
        var object: [String: Any] = ["app": app, "name": name, "port": Int(port), "protocol": self.protocol, "key": key]
        if let pid { object["pid"] = Int(pid) }
        return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    /// Reads an announcement, or nil if it isn't a usable one. Lenient about extra fields,
    /// strict about the ones it needs.
    public init?(json: String) {
        guard json.utf8.count <= Limits.maxLineBeforeHello,
              let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawApp = object["app"] as? String, let rawName = object["name"] as? String,
              let rawKey = object["key"] as? String,
              let port = (object["port"] as? NSNumber)?.intValue, (1024...65535).contains(port),
              let version = (object["protocol"] as? NSNumber)?.intValue
        else { return nil }
        let app = Limits.name(rawApp)
        let key = Limits.name(rawKey)
        guard !app.isEmpty, app == rawApp, key.count >= 16, key == rawKey else { return nil }
        let name = Limits.name(rawName)
        self.init(
            app: app, name: name.isEmpty ? app : name, port: UInt16(port), protocol: version, key: key,
            pid: (object["pid"] as? NSNumber).map(\.intValue).flatMap { Int32(exactly: $0) }
        )
    }

    /// A new random key: 128 bits, as hex.
    static func makeKey() -> String {
        var generator = SystemRandomNumberGenerator()
        return (0..<2).map { _ in String(format: "%016llx", generator.next() as UInt64) }.joined()
    }
}

/// The distributed notifications providers and consumers find each other with (SPEC.md › Finding providers).
public struct Discovery: Sendable, Equatable {
    /// The notification names' prefix. Only tests use anything but the default.
    public var prefix: String

    public static let standard = Discovery(prefix: "dev.applug")

    public init(prefix: String) { self.prefix = prefix }

    public var announceName: Notification.Name { Notification.Name("\(prefix).announce") }
    public var queryName: Notification.Name { Notification.Name("\(prefix).query") }
    public var goodbyeName: Notification.Name { Notification.Name("\(prefix).goodbye") }

    func post(_ name: Notification.Name, object: String?) {
        DistributedNotificationCenter.default().postNotificationName(name, object: object, userInfo: nil, deliverImmediately: true)
    }

    /// Observes one of the names on the main queue, until `bag` stops or goes away.
    @MainActor
    func observe(_ name: Notification.Name, in bag: ObserverBag, _ handler: @escaping @MainActor (String?) -> Void) {
        bag.add(bag.center.addObserver(forName: name, object: nil, queue: .main) { note in
            let object = note.object as? String
            MainActor.assumeIsolated { handler(object) }
        })
    }
}

/// Notification observers, removed on `removeAll()` or when the bag is released,
/// so a provider or consumer dropped without `stop()` doesn't leave them behind.
final class ObserverBag: @unchecked Sendable {
    let center: NotificationCenter
    private let lock = NSLock()
    private var tokens: [NSObjectProtocol] = []

    init(_ center: NotificationCenter = DistributedNotificationCenter.default()) {
        self.center = center
    }

    func add(_ token: NSObjectProtocol) {
        lock.withLock { tokens.append(token) }
    }

    func removeAll() {
        let tokens = lock.withLock {
            let tokens = self.tokens
            self.tokens.removeAll()
            return tokens
        }
        for token in tokens { center.removeObserver(token) }
    }

    deinit { removeAll() }
}
