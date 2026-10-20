import Foundation

/// The protocol version this package speaks.
public let applugProtocolVersion = 3

/// Who's on the other end of a connection, from its `hello`.
public struct Hello: Equatable, Sendable {
    public var app: String
    public var name: String
    public var version: String?
    public var protocolVersion: Int?
    /// A consumer's: the key from the provider's announcement, so only apps that saw it can connect.
    public var key: String?

    public init(app: String, name: String, version: String? = nil, protocolVersion: Int? = applugProtocolVersion, key: String? = nil) {
        self.app = app
        self.name = name
        self.version = version
        self.protocolVersion = protocolVersion
        self.key = key
    }
}

/// Twist Commando's reply on the App Link 1 port.
public struct Welcome: Equatable, Sendable {
    public var app: String?
    public var version: String?
    public var protocolVersion: Int?
    public var meters: Bool
}

/// One line on the wire.
public enum Message: Equatable, Sendable {
    case hello(Hello)
    case welcome(Welcome)
    case controls([Control])
    case update(Update)
    case meter(id: String, levels: [Double])
    case turn(id: String, value: Double?, steps: Int?)
    case press(id: String, down: Bool)
    case meterSubscribe(id: String, on: Bool)
    case error(String)
    /// A `type` this package doesn't know. Ignored, so newer peers can add messages.
    case unknown(type: String)

    public struct DecodeError: Error, Equatable, CustomStringConvertible {
        public let description: String
    }

    // MARK: Decoding

    /// Reads one line (without its newline). Lenient like App Link: unknown fields are
    /// ignored and numbers can arrive as integers or decimals.
    public static func decode(_ line: Data) throws -> Message {
        guard let object = try? JSONSerialization.jsonObject(with: line), let json = object as? [String: Any],
              let type = json["type"] as? String
        else { throw DecodeError(description: "Each line must be a JSON object with a \"type\"") }

        func string(_ key: String) -> String? { json[key] as? String }
        func number(_ key: String) -> Double? { (json[key] as? NSNumber).flatMap { isBool($0) ? nil : $0.doubleValue } }
        func bool(_ key: String) -> Bool? { (json[key] as? NSNumber).flatMap { isBool($0) ? $0.boolValue : nil } }
        func int(_ key: String) -> Int? { number(key).flatMap(Message.int) }
        func id() throws -> String {
            guard let id = string("id").map(Limits.name), !id.isEmpty else { throw DecodeError(description: "\(type) needs an \"id\"") }
            return id
        }

        switch type {
        case "hello":
            guard let app = string("app").map({ Limits.name($0.trimmingCharacters(in: .whitespacesAndNewlines)) }), !app.isEmpty else {
                throw DecodeError(description: "hello needs \"app\": your bundle identifier")
            }
            let name = string("name").map(Limits.name).flatMap { $0.isEmpty ? nil : $0 } ?? app
            return .hello(Hello(
                app: app, name: name, version: string("version").map(Limits.name),
                protocolVersion: int("protocol"), key: string("key").map(Limits.name)
            ))
        case "welcome":
            return .welcome(Welcome(
                app: string("app").map(Limits.name), version: string("version").map(Limits.name),
                protocolVersion: int("protocol"), meters: bool("meters") ?? false
            ))
        case "controls":
            guard let list = json["controls"] as? [Any] else {
                throw DecodeError(description: "controls needs a \"controls\" array")
            }
            return .controls(list.compactMap { ($0 as? [String: Any]).flatMap(control) })
        case "update":
            var update = Update(id: try id())
            update.value = number("value")
            if json.keys.contains("text") { update.text = .some(string("text")) }
            update.on = bool("on")
            update.name = string("name")
            return .update(update)
        case "meter":
            // One per channel (at most two), in dBFS.
            let numbers = (json["levels"] as? [Any])?.prefix(2).compactMap { ($0 as? NSNumber).flatMap { isBool($0) ? nil : $0.doubleValue } }
            guard let numbers, !numbers.isEmpty else { throw DecodeError(description: "meter needs \"levels\"") }
            return .meter(id: try id(), levels: numbers.map(Limits.meterLevel))
        case "turn":
            let steps = int("steps").map { min(max($0, -maxSteps), maxSteps) }
            let value = number("value").flatMap { $0.isFinite ? $0 : nil }
            guard value != nil || steps != nil else { throw DecodeError(description: "turn needs \"value\" or \"steps\"") }
            return .turn(id: try id(), value: value, steps: steps)
        case "press":
            return .press(id: try id(), down: bool("down") ?? true)
        case "meterSubscribe":
            return .meterSubscribe(id: try id(), on: bool("on") ?? true)
        case "error":
            return .error(Limits.text(string("message") ?? ""))
        default:
            return .unknown(type: type)
        }
    }

    private static func control(_ json: [String: Any]) -> Control? {
        guard let id = json["id"] as? String, !id.isEmpty, let kind = json["kind"] as? String else { return nil }
        func number(_ key: String) -> Double? { (json[key] as? NSNumber).flatMap { isBool($0) ? nil : $0.doubleValue } }
        func bool(_ key: String) -> Bool? { (json[key] as? NSNumber).flatMap { isBool($0) ? $0.boolValue : nil } }
        return Control(
            id: id, name: json["name"] as? String, kind: Control.Kind(rawValue: kind),
            value: number("value"), text: json["text"] as? String, on: bool("on"),
            group: json["group"] as? String, channels: number("channels").flatMap(int),
            readOnly: bool("readOnly") ?? false
        )
    }

    /// The most a single `turn` moves a steps control.
    static let maxSteps = 10_000

    /// A whole number from JSON, or nil when it's out of range. `Int(Double)` would crash on 1e300.
    private static func int(_ number: Double) -> Int? {
        guard number.isFinite, abs(number) <= 1_000_000_000 else { return nil }
        return Int(number.rounded())
    }

    private static func isBool(_ number: NSNumber) -> Bool {
        CFGetTypeID(number) == CFBooleanGetTypeID()
    }

    // MARK: Encoding

    /// The message as one line, newline included.
    public func encoded() -> Data {
        var data = (try? JSONSerialization.data(withJSONObject: jsonObject, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
        data.append(0x0A)
        return data
    }

    var jsonObject: [String: Any] {
        switch self {
        case .hello(let hello):
            var json: [String: Any] = ["type": "hello", "app": hello.app, "name": hello.name]
            if let version = hello.version { json["version"] = version }
            if let p = hello.protocolVersion { json["protocol"] = p }
            if let key = hello.key { json["key"] = key }
            return json
        case .welcome(let welcome):
            var json: [String: Any] = ["type": "welcome", "meters": welcome.meters]
            if let app = welcome.app { json["app"] = app }
            if let version = welcome.version { json["version"] = version }
            if let p = welcome.protocolVersion { json["protocol"] = p }
            return json
        case .controls(let controls):
            return ["type": "controls", "controls": controls.map(Message.json(for:))]
        case .update(let update):
            var json: [String: Any] = ["type": "update", "id": update.id]
            if let value = update.value { json["value"] = Message.number(value) }
            if let text = update.text { json["text"] = text ?? NSNull() }
            if let on = update.on { json["on"] = on }
            if let name = update.name { json["name"] = name }
            return json
        case .meter(let id, let levels):
            return ["type": "meter", "id": id, "levels": levels.map(Message.number)]
        case .turn(let id, let value, let steps):
            var json: [String: Any] = ["type": "turn", "id": id]
            if let value { json["value"] = Message.number(value) }
            if let steps { json["steps"] = steps }
            return json
        case .press(let id, let down):
            return ["type": "press", "id": id, "down": down]
        case .meterSubscribe(let id, let on):
            return ["type": "meterSubscribe", "id": id, "on": on]
        case .error(let message):
            return ["type": "error", "message": message]
        case .unknown(let type):
            return ["type": type]
        }
    }

    /// A number written the shortest way that reads back the same: 0.1, not 0.10000000000000001.
    static func number(_ value: Double) -> Any {
        value.isFinite ? NSDecimalNumber(string: "\(value)") : 0
    }

    static func json(for control: Control) -> [String: Any] {
        var json: [String: Any] = ["id": control.id, "name": control.name, "kind": control.kind.rawValue]
        if let value = control.value { json["value"] = Message.number(value) }
        if let text = control.text { json["text"] = text }
        if let on = control.on { json["on"] = on }
        if let group = control.group { json["group"] = group }
        if let channels = control.channels { json["channels"] = channels }
        if control.readOnly { json["readOnly"] = true }
        return json
    }
}
