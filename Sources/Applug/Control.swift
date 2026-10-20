import Foundation

/// One thing a provider offers: a level, a steps control, a switch, a button, or a meter.
public struct Control: Equatable, Sendable, Identifiable, Codable {
    /// What a control is, and so what a consumer can do with it.
    ///
    /// A struct rather than an enum so a consumer can carry kinds it doesn't know
    /// (and skip them) without failing to read the rest.
    public struct Kind: RawRepresentable, Hashable, Sendable, Codable, CustomStringConvertible {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }

        /// Two ends, 0…1: a volume, a threshold. Turned with an absolute value.
        public static let level = Kind(rawValue: "level")
        /// Endless: scrolling, nudging. Turned with a relative count.
        public static let steps = Kind(rawValue: "steps")
        /// A switch the provider flips on press and reports with `on`.
        public static let toggle = Kind(rawValue: "toggle")
        /// Does something once, on press.
        public static let button = Kind(rawValue: "button")
        /// Live levels to watch, sent while subscribed.
        public static let meter = Kind(rawValue: "meter")

        public static let known: [Kind] = [.level, .steps, .toggle, .button, .meter]
        public var isKnown: Bool { Kind.known.contains(self) }
        /// Whether a consumer sends `turn` for it.
        public var turns: Bool { self == .level || self == .steps }
        /// Whether a consumer can send `press` for it (all but meters).
        public var presses: Bool { isKnown && self != .meter }
        public var description: String { rawValue }
    }

    public let id: String
    public var name: String
    public var kind: Kind
    /// A level's position, 0…1.
    public var value: Double?
    /// How the provider shows the current state ("-24 dB", "Playing").
    public var text: String?
    public var on: Bool?
    /// A heading to list it under ("Deck A").
    public var group: String?
    /// A meter's: 1 (mono) or 2 (stereo).
    public var channels: Int?
    /// A level the consumer can show but not turn.
    public var readOnly: Bool

    public init(
        id: String, name: String? = nil, kind: Kind,
        value: Double? = nil, text: String? = nil, on: Bool? = nil,
        group: String? = nil, channels: Int? = nil, readOnly: Bool = false
    ) {
        self.id = id
        self.name = name ?? id
        self.kind = kind
        self.value = value
        self.text = text
        self.on = on
        self.group = group
        self.channels = channels
        self.readOnly = readOnly
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, kind, value, text, on, group, channels, readOnly
    }

    /// Lenient, so controls saved by an older or newer version still load.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let id = try c.decode(String.self, forKey: .id)
        self.init(
            id: id,
            name: try c.decodeIfPresent(String.self, forKey: .name),
            kind: try c.decodeIfPresent(Kind.self, forKey: .kind) ?? .button,
            value: try? c.decodeIfPresent(Double.self, forKey: .value),
            text: try? c.decodeIfPresent(String.self, forKey: .text),
            on: try? c.decodeIfPresent(Bool.self, forKey: .on),
            group: try? c.decodeIfPresent(String.self, forKey: .group),
            channels: try? c.decodeIfPresent(Int.self, forKey: .channels),
            readOnly: (try? c.decodeIfPresent(Bool.self, forKey: .readOnly)) ?? false
        )
    }

    /// Whether a consumer may turn it right now.
    public var isTurnable: Bool { kind.turns && !readOnly }

    /// The control without its live state, for remembering it while the provider is away.
    public var definition: Control {
        var copy = self
        copy.value = nil
        copy.text = nil
        copy.on = nil
        return copy
    }

    /// Applies an `update`'s changes.
    mutating func apply(_ update: Update) {
        if let value = update.value { self.value = Limits.value(value) }
        if let text = update.text { self.text = text.map(Limits.text) }
        if let on = update.on { self.on = on }
        if let name = update.name.map(Limits.name), !name.isEmpty { self.name = name }
    }
}

/// A change to one control's state.
public struct Update: Equatable, Sendable {
    public let id: String
    public var value: Double?
    /// `nil`: unchanged. `.some(nil)`: cleared.
    public var text: String??
    public var on: Bool?
    public var name: String?

    public init(id: String, value: Double? = nil, text: String?? = nil, on: Bool? = nil, name: String? = nil) {
        self.id = id
        self.value = value
        self.text = text
        self.on = on
        self.name = name
    }

    public var isEmpty: Bool { value == nil && text == nil && on == nil && name == nil }
}

/// The protocol's size limits (SPEC.md › Limits), and tidying for text that came from another app.
public enum Limits {
    public static let maxLine = 1 << 20
    /// Until a connection's `hello`: enough for any hello, too little to be useful to anyone else.
    public static let maxLineBeforeHello = 4096
    public static let maxControls = 512
    /// In Unicode scalars, so a name's size in bytes is bounded too.
    public static let maxName = 256
    public static let maxText = 1024
    /// Messages, and bytes, waiting to be sent before a connection is given up on.
    public static let maxQueued = 1000
    public static let maxQueuedBytes = 8 << 20
    /// A provider's connections: all, and those that haven't said hello yet.
    public static let maxConnections = 64
    public static let maxConnectionsBeforeHello = 16
    /// A consumer's providers, connected or remembered.
    public static let maxProviders = 64
    /// Meter levels, in dBFS.
    public static let meterRange: ClosedRange<Double> = -160...24

    static func name(_ string: String) -> String { clean(string, max: maxName) }
    static func text(_ string: String) -> String { clean(string, max: maxText) }
    static func clamp(_ value: Double) -> Double { value.isFinite ? min(max(value, 0), 1) : 0 }
    /// A level's value as stored and sent: 0…1, to 3 decimals.
    static func value(_ value: Double) -> Double { (clamp(value) * 1000).rounded() / 1000 }

    static func meterLevel(_ level: Double) -> Double {
        level.isFinite ? min(max((level * 10).rounded() / 10, meterRange.lowerBound), meterRange.upperBound) : meterRange.lowerBound
    }

    /// Drops control characters and text-direction overrides (which can make a name read as something
    /// it isn't, or inject terminal escapes), and cuts to `max` Unicode scalars.
    static func clean(_ string: String, max: Int) -> String {
        var scalars = String.UnicodeScalarView()
        var count = 0
        for scalar in string.unicodeScalars where !isUnsafe(scalar) {
            guard count < max else { break }
            scalars.append(scalar)
            count += 1
        }
        return String(scalars)
    }

    private static func isUnsafe(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x00...0x1F, 0x7F...0x9F: true                      // C0 and C1 controls, newlines and escapes included
        case 0x061C, 0x200E, 0x200F, 0x202A...0x202E, 0x2066...0x2069: true   // direction marks and overrides
        default: false
        }
    }

    /// Cuts a list of controls to what the protocol allows: ids present and unique, text tidied, at most 512.
    static func tidy(_ controls: [Control]) -> [Control] {
        var seen = Set<String>()
        var result: [Control] = []
        for control in controls {
            let id = name(control.id)
            guard !id.isEmpty, seen.insert(id).inserted else { continue }
            let cleanName = name(control.name)
            var tidy = Control(
                id: id, name: cleanName.isEmpty ? id : cleanName, kind: Control.Kind(rawValue: name(control.kind.rawValue)),
                value: control.value.map(value), text: control.text.map(text), on: control.on,
                group: control.group.map(name), channels: control.channels, readOnly: control.readOnly
            )
            if tidy.kind == .meter { tidy.channels = control.channels == 2 ? 2 : 1 } else { tidy.channels = nil }
            result.append(tidy)
            if result.count == maxControls { break }
        }
        return result
    }
}
