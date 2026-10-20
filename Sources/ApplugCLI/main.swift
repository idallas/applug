import Applug
import Foundation

let usage = """
    applug: try out Applug providers and consumers on this Mac.

      applug list                    Find providers and list their controls
      applug watch [APP] [--meters]  Print every change (and meter levels with --meters)
      applug turn APP ID VALUE       Move a level to VALUE (0 to 1)
      applug step APP ID STEPS       Move a steps control (negative goes back)
      applug press APP ID            Press and let go
      applug demo [--app-link]       Offer a few made-up controls, as a provider
                                     (--app-link: to Twist Commando 0.14 too, which remembers it)

    APP is a bundle identifier or a provider's name (case doesn't matter).
    """

setvbuf(stdout, nil, _IOLBF, 0)
var arguments = Array(CommandLine.arguments.dropFirst())
let showMeters = arguments.contains("--meters")
let appLink = arguments.contains("--app-link")
arguments.removeAll { $0 == "--meters" || $0 == "--app-link" }
guard let command = arguments.first else {
    print(usage)
    exit(0)
}
let rest = Array(arguments.dropFirst())

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("applug: \(message)\n".utf8))
    exit(1)
}

func after(_ seconds: Double, _ work: @escaping @MainActor () -> Void) {
    DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { MainActor.assumeIsolated { work() } }
}

func describe(_ control: Control) -> String {
    var parts = ["\(control.id)", "(\(control.kind)\(control.readOnly ? ", read-only" : ""))", "\"\(control.name)\""]
    if let on = control.on { parts.append(on ? "on" : "off") }
    if let value = control.value { parts.append(String(format: "%.3f", value)) }
    if let text = control.text { parts.append("· \(text)") }
    if let channels = control.channels, control.kind == .meter { parts.append("\(channels == 2 ? "stereo" : "mono")") }
    return parts.joined(separator: " ")
}

func printProvider(_ provider: ApplugConsumer.Provider) {
    print("\(provider.name) (\(provider.app)\(provider.version.map { " \($0)" } ?? ""))\(provider.isConnected ? "" : ", not connected")")
    var group: String?
    for control in provider.controls {
        if control.group != group, let heading = control.group { print("  \(heading)") }
        group = control.group
        print("\(group == nil ? "  " : "    ")\(describe(control))")
    }
}

let consumer = ApplugConsumer(app: "dev.applug.cli", name: "applug", version: nil)

/// Waits for providers to connect, then runs `work` with the one matching `query` (or all, if nil).
@MainActor func withProviders(matching query: String?, wait: Double = 1.5, _ work: @escaping @MainActor ([ApplugConsumer.Provider]) -> Void) {
    consumer.start()
    after(wait) {
        let connected = consumer.providers.filter(\.isConnected)
        guard let query = query?.lowercased() else { return work(connected) }
        let matches = connected.filter { $0.app.lowercased() == query || $0.name.lowercased() == query }
        guard !matches.isEmpty else {
            fail("no provider \"\(query)\" answered" + (connected.isEmpty ? "" : " (found: \(connected.map(\.name).joined(separator: ", ")))"))
        }
        work(matches)
    }
}

func requireControl(_ rest: [String], count: Int) -> (app: String, id: String) {
    guard rest.count >= count else { print(usage); exit(2) }
    return (rest[0], rest[1])
}

switch command {
case "list":
    withProviders(matching: nil) { providers in
        if providers.isEmpty { print("No providers answered.") }
        for (index, provider) in providers.enumerated() {
            if index > 0 { print("") }
            printProvider(provider)
        }
        exit(0)
    }

case "watch":
    let query = rest.first
    var shown: [String: ApplugConsumer.Provider] = [:]
    consumer.onChange = { provider in
        if let query, provider.app.lowercased() != query.lowercased() && provider.name.lowercased() != query.lowercased() { return }
        let old = shown[provider.app]
        shown[provider.app] = provider
        guard let old, old.isConnected == provider.isConnected else {
            print(provider.isConnected ? "+ \(provider.name) connected" : "- \(provider.name) went away")
            if provider.isConnected {
                printProvider(provider)
                if showMeters {
                    for meter in provider.controls where meter.kind == .meter { consumer.watchMeter(app: provider.app, id: meter.id, true) }
                }
            }
            return
        }
        for control in provider.controls where old.control(control.id) != control {
            print("  \(provider.name): \(describe(control))")
        }
    }
    consumer.onMeter = { app, id, levels in
        print("  \(shown[app]?.name ?? app) \(id): " + levels.map { String(format: "%.1f dB", $0) }.joined(separator: " / "))
    }
    consumer.onError = { app, message in print("  \(shown[app]?.name ?? app) error: \(message)") }
    consumer.start()
    print("Watching for providers. Ctrl-C to stop.")

case "turn", "step", "press":
    let target = requireControl(rest, count: command == "press" ? 2 : 3)
    withProviders(matching: target.app) { providers in
        let provider = providers[0]
        guard let control = provider.control(target.id) else {
            fail("\(provider.name) has no control \"\(target.id)\" (has: \(provider.controls.map(\.id).joined(separator: ", ")))")
        }
        let sent: Bool
        switch command {
        case "turn":
            guard let value = Double(rest[2]) else { fail("VALUE must be a number from 0 to 1") }
            sent = consumer.turn(app: provider.app, id: control.id, value: value)
        case "step":
            guard let steps = Int(rest[2]) else { fail("STEPS must be a whole number") }
            sent = consumer.turn(app: provider.app, id: control.id, steps: steps)
        default:
            sent = consumer.tap(app: provider.app, id: control.id)
        }
        guard sent else { fail("\(control.id) is a \(control.kind)\(control.readOnly ? " (read-only)" : ""); it can't be used that way") }
        // Give the provider a moment to reply with its new state.
        after(0.5) {
            print(describe(consumer.provider(provider.app)?.control(control.id) ?? control))
            exit(0)
        }
    }

case "demo":
    var level = 0.5
    var on = false
    var position = 0
    let items = ["Alpha", "Bravo", "Charlie", "Delta", "Echo"]
    func levelText(_ value: Double) -> String { String(format: "%.0f dB", -60 + value * 60) }
    let provider = ApplugProvider(app: "dev.applug.demo", name: "Applug Demo", version: nil, controls: [
        Control(id: "power", name: "Power", kind: .toggle, text: "Off", on: false),
        Control(id: "volume", name: "Volume", kind: .level, value: level, text: levelText(level)),
        Control(id: "item", name: "Item", kind: .steps, text: items[0]),
        Control(id: "ping", name: "Ping", kind: .button),
        Control(id: "clock", name: "Seconds", kind: .level, value: 0, text: "0 s", group: "Readouts", readOnly: true),
        Control(id: "wave", name: "Wave", kind: .meter, group: "Readouts", channels: 2),
    ])
    if appLink { provider.appLinkCompatibility = AppLinkCompatibility() }
    provider.onTurn = { turn in
        if turn.id == "volume", let value = turn.value {
            level = value
            provider.set("volume", value: level, text: levelText(level))
        } else if turn.id == "item", let steps = turn.steps {
            position = ((position + steps) % items.count + items.count) % items.count
            provider.set("item", text: items[position])
        }
        print("\(turn.from.name) turned \(turn.id): \(turn.value.map { String(format: "%.3f", $0) } ?? "\(turn.steps ?? 0) steps")")
    }
    provider.onPress = { press in
        print("\(press.from.name) \(press.down ? "pressed" : "let go of") \(press.id)")
        guard press.down else { return }
        switch press.id {
        case "power":
            on.toggle()
            provider.set("power", text: on ? "On" : "Off", on: on)
        case "volume":
            level = 0.5
            provider.set("volume", value: level, text: levelText(level))
        default:
            provider.set(press.id)
        }
    }
    provider.onConsumersChange = { consumers in
        print("Consumers: \(consumers.isEmpty ? "none" : consumers.map(\.name).joined(separator: ", "))")
    }
    provider.onWatchedMetersChange = { print("Watched meters: \($0.isEmpty ? "none" : $0.sorted().joined(separator: ", "))") }
    provider.start()
    let started = Date()
    Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
        MainActor.assumeIsolated {
            let t = Date().timeIntervalSince(started)
            if provider.watchedMeters.contains("wave") {
                let left = 20 * log10(max(abs(sin(t * 2)), 0.001))
                let right = 20 * log10(max(abs(cos(t * 2)), 0.001))
                provider.sendMeter("wave", levels: [left, right])
            }
            let seconds = Int(t) % 60
            if Int(t * 20) % 20 == 0 { provider.set("clock", value: Double(seconds) / 59, text: "\(seconds) s") }
        }
    }
    after(0.5) {
        if let port = provider.port { print("Applug Demo is listening on 127.0.0.1:\(port). Ctrl-C to stop.") }
        if let problem = provider.problem { fail(problem) }
    }
    signal(SIGINT, SIG_IGN)
    let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    interrupt.setEventHandler {
        MainActor.assumeIsolated { provider.stop() }
        exit(0)
    }
    interrupt.resume()
    withExtendedLifetime(interrupt) { RunLoop.main.run() }

default:
    print(usage)
    exit(2)
}

// Distributed notifications arrive through the main run loop.
RunLoop.main.run()
