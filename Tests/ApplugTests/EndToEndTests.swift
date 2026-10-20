import Foundation
import Network
import Testing
@testable import Applug

/// Real providers and consumers over loopback, finding each other with distributed notifications.
/// Each test uses its own notification prefix, so it never sees real apps (or other tests).
@MainActor
@Suite(.serialized)
struct EndToEndTests {
    let discovery = Discovery(prefix: "test.applug.\(UUID().uuidString)")

    func makeProvider(_ controls: [Control]? = nil) -> ApplugProvider {
        ApplugProvider(app: "test.provider", name: "Test Provider", version: "1.0", controls: controls ?? [
            Control(id: "radio", name: "Radio Mode", kind: .toggle, text: "Off", on: false),
            Control(id: "threshold", name: "Threshold", kind: .level, value: 0.5, text: "-30 dB"),
            Control(id: "scroll", kind: .steps),
            Control(id: "progress", kind: .level, value: 0.1, readOnly: true),
            Control(id: "input", name: "Input", kind: .meter, channels: 2),
        ], discovery: discovery)
    }

    func makeConsumer(_ name: String = "Test Consumer") -> ApplugConsumer {
        ApplugConsumer(app: "test.consumer.\(name)", name: name, version: nil, discovery: discovery)
    }

    @Test func consumerFindsProviderAndGetsItsControls() async throws {
        let provider = makeProvider()
        provider.start()
        defer { provider.stop() }
        let consumer = makeConsumer()
        consumer.start()
        defer { consumer.stop() }

        #expect(await eventually { consumer.provider("test.provider")?.isConnected == true })
        let found = try #require(consumer.provider("test.provider"))
        #expect(found.name == "Test Provider")
        #expect(found.version == "1.0")
        #expect(found.controls.map(\.id) == ["radio", "threshold", "scroll", "progress", "input"])
        #expect(found.control("threshold")?.text == "-30 dB")
        #expect(await eventually { provider.consumers.map(\.name) == ["Test Consumer"] })
    }

    @Test func providerStartedLaterAnnouncesItself() async throws {
        let consumer = makeConsumer()
        consumer.start()
        defer { consumer.stop() }
        try await Task.sleep(for: .milliseconds(100))
        let provider = makeProvider()
        provider.start()
        defer { provider.stop() }
        #expect(await eventually { consumer.provider("test.provider")?.isConnected == true })
    }

    @Test func turnsAndPressesReachTheProviderAndStateComesBack() async throws {
        let provider = makeProvider()
        var turns: [ApplugProvider.Turn] = []
        var presses: [ApplugProvider.Press] = []
        provider.onTurn = { turn in
            turns.append(turn)
            if let value = turn.value { provider.set(turn.id, value: value, text: "\(Int(value * 100))%") }
        }
        provider.onPress = { press in
            presses.append(press)
            if press.down, press.id == "radio" {
                let on = !(provider.controls.first { $0.id == "radio" }?.on ?? false)
                provider.set("radio", text: on ? "On" : "Off", on: on)
            }
        }
        provider.start()
        defer { provider.stop() }
        let consumer = makeConsumer()
        consumer.start()
        defer { consumer.stop() }
        #expect(await eventually { consumer.provider("test.provider")?.isConnected == true })

        #expect(consumer.tap(app: "test.provider", id: "radio"))
        #expect(await eventually { consumer.provider("test.provider")?.control("radio")?.on == true })
        #expect(consumer.provider("test.provider")?.control("radio")?.text == "On")
        #expect(presses.map(\.down) == [true, false])
        #expect(presses.first?.from.name == "Test Consumer")

        #expect(consumer.turn(app: "test.provider", id: "threshold", value: 0.8))
        #expect(await eventually { consumer.provider("test.provider")?.control("threshold")?.value == 0.8 })
        #expect(consumer.provider("test.provider")?.control("threshold")?.text == "80%")

        #expect(consumer.turn(app: "test.provider", id: "scroll", steps: -2))
        #expect(await eventually { turns.last?.steps == -2 })

        // Things that can't be turned or pressed aren't sent.
        #expect(!consumer.turn(app: "test.provider", id: "progress", value: 0.3))
        #expect(!consumer.turn(app: "test.provider", id: "radio", value: 0.3))
        #expect(!consumer.press(app: "test.provider", id: "input", down: true))
        #expect(!consumer.tap(app: "test.provider", id: "nope"))
    }

    @Test func stateIsEchoedAfterATurnEvenWhenUnchanged() async throws {
        let provider = makeProvider()
        // The provider refuses to go above 0.5, and says so by sending its (unchanged) state.
        provider.onTurn = { turn in provider.set(turn.id, value: min(turn.value ?? 0, 0.5), text: "-30 dB") }
        provider.start()
        defer { provider.stop() }
        let raw = try await rawClient(provider)
        defer { raw.close() }
        raw.send(rawHello(provider))
        #expect(await eventually { raw.lines.contains { $0.contains(#""type":"controls""#) } })

        raw.send(#"{"type":"turn","id":"threshold","value":0.9}"#)
        #expect(await eventually { raw.lines.contains { $0.contains(#""type":"update""#) } })
        let update = try #require(raw.lines.first { $0.contains(#""type":"update""#) })
        #expect(update.contains(#""value":0.5"#))
        #expect(update.contains(#""text":"-30 dB""#))

        // Outside a turn, setting the same state sends nothing.
        let count = raw.lines.count
        provider.set("threshold", value: 0.5, text: "-30 dB")
        try await Task.sleep(for: .milliseconds(200))
        #expect(raw.lines.count == count)
    }

    @Test func clearingTextAndRenamingReachConsumers() async throws {
        let provider = makeProvider()
        provider.start()
        defer { provider.stop() }
        let consumer = makeConsumer()
        consumer.start()
        defer { consumer.stop() }
        #expect(await eventually { consumer.provider("test.provider")?.control("threshold")?.text == "-30 dB" })
        provider.clearText("threshold")
        provider.rename("threshold", to: "Gate\u{202E}Level\n")
        #expect(await eventually { consumer.provider("test.provider")?.control("threshold")?.name == "GateLevel" })
        #expect(consumer.provider("test.provider")?.control("threshold")?.text == nil)
    }

    @Test func helloNeedsTheAnnouncedKey() async throws {
        let provider = makeProvider()
        provider.start()
        defer { provider.stop() }
        for hello in [#"{"type":"hello","app":"raw","name":"Raw"}"#, #"{"type":"hello","app":"raw","name":"Raw","key":"0123456789abcdef0123456789abcdef"}"#] {
            let raw = try await rawClient(provider)
            defer { raw.close() }
            raw.send(hello)
            #expect(await eventually { raw.isClosed })
            #expect(!raw.lines.contains { $0.contains(#""type":"controls""#) })
        }
        #expect(provider.consumers.isEmpty)
    }

    @Test func connectionsThatDontSayHelloAreLimitedAndTimedOut() async throws {
        let provider = makeProvider()
        provider.start()
        defer { provider.stop() }
        #expect(await eventually { provider.port != nil })
        let raws = (0..<20).map { _ in RawClient(port: provider.port!) }
        defer { raws.forEach { $0.close() } }
        // Only 16 may wait to say hello; the rest are turned away.
        #expect(await eventually { raws.filter(\.isClosed).count == 4 })
        // A real consumer still gets in once those time out (3 s).
        #expect(await eventually(timeout: 6) { raws.allSatisfy(\.isClosed) })
        let consumer = makeConsumer()
        consumer.start()
        defer { consumer.stop() }
        #expect(await eventually { consumer.provider("test.provider")?.isConnected == true })
    }

    @Test func longLinesBeforeHelloCloseTheConnection() async throws {
        let provider = makeProvider()
        provider.start()
        defer { provider.stop() }
        let raw = try await rawClient(provider)
        defer { raw.close() }
        raw.send(String(repeating: "x", count: 5000), newline: false)
        #expect(await eventually { raw.isClosed })
    }

    @Test func aProviderReleasedWithoutStopStopsListeningAndSaysGoodbye() async throws {
        var provider: ApplugProvider? = makeProvider()
        provider!.start()
        let consumer = makeConsumer()
        consumer.start()
        defer { consumer.stop() }
        #expect(await eventually { consumer.provider("test.provider")?.isConnected == true })
        let port = try #require(provider?.port)
        provider = nil
        #expect(await eventually { consumer.provider("test.provider")?.isConnected == false })
        let raw = RawClient(port: port)
        defer { raw.close() }
        #expect(await eventually { raw.isClosed })
    }

    @Test func severalConsumersShareOneProvider() async throws {
        let provider = makeProvider()
        provider.start()
        defer { provider.stop() }
        let first = makeConsumer("First")
        let second = makeConsumer("Second")
        first.start()
        second.start()
        defer { first.stop(); second.stop() }
        #expect(await eventually { provider.consumers.count == 2 })
        #expect(await eventually { first.provider("test.provider")?.isConnected == true && second.provider("test.provider")?.isConnected == true })

        provider.set("radio", text: "On", on: true)
        #expect(await eventually {
            first.provider("test.provider")?.control("radio")?.on == true && second.provider("test.provider")?.control("radio")?.on == true
        })

        // Meters go only to consumers watching them, and stop being watched when they leave.
        var firstLevels: [[Double]] = []
        var secondLevels: [[Double]] = []
        first.onMeter = { _, _, levels in firstLevels.append(levels) }
        second.onMeter = { _, _, levels in secondLevels.append(levels) }
        var watched: [Set<String>] = []
        provider.onWatchedMetersChange = { watched.append($0) }
        first.watchMeter(app: "test.provider", id: "input", true)
        #expect(await eventually { provider.watchedMeters == ["input"] })
        provider.sendMeter("input", levels: [-12.345, -160.5])
        #expect(await eventually { firstLevels == [[-12.3, -160]] })
        try await Task.sleep(for: .milliseconds(100))
        #expect(secondLevels.isEmpty)

        first.stop()
        #expect(await eventually { provider.watchedMeters.isEmpty && provider.consumers.map(\.name) == ["Second"] })
        #expect(watched == [["input"], []])
    }

    @Test func meterSubscriptionsAreRenewedAfterAReconnect() async throws {
        let provider = makeProvider()
        provider.start()
        let consumer = makeConsumer()
        consumer.start()
        defer { consumer.stop() }
        #expect(await eventually { consumer.provider("test.provider")?.isConnected == true })
        consumer.watchMeter(app: "test.provider", id: "input", true)
        #expect(await eventually { provider.watchedMeters == ["input"] })

        provider.stop()
        #expect(await eventually { consumer.provider("test.provider")?.isConnected == false })
        let again = makeProvider()
        again.start()
        defer { again.stop() }
        #expect(await eventually { again.watchedMeters == ["input"] })
    }

    @Test func aFakeGoodbyeDoesntDisconnect() async throws {
        let provider = makeProvider()
        provider.start()
        defer { provider.stop() }
        let consumer = makeConsumer()
        consumer.start()
        defer { consumer.stop() }
        #expect(await eventually { consumer.provider("test.provider")?.isConnected == true })
        let fake = Announcement(app: "test.provider", name: "Test Provider", port: provider.port!, key: Announcement.makeKey())
        discovery.post(discovery.goodbyeName, object: fake.json)
        try await Task.sleep(for: .milliseconds(300))
        #expect(consumer.provider("test.provider")?.isConnected == true)
    }

    @Test func anAnnouncementPointingAtAnotherAppIsRefused() async throws {
        let provider = makeProvider()
        provider.start()
        defer { provider.stop() }
        let other = ApplugProvider(app: "other.provider", name: "Other", version: nil, controls: [Control(id: "x", kind: .button)], discovery: discovery)
        other.start()
        defer { other.stop() }
        let consumer = makeConsumer()
        consumer.start()
        defer { consumer.stop() }
        #expect(await eventually { consumer.provider("test.provider")?.isConnected == true && consumer.provider("other.provider")?.isConnected == true })
        // "test.provider is now at other's port": other says hello as itself, so it's refused.
        let lie = Announcement(app: "test.provider", name: "Test Provider", port: other.port!, key: other.key)
        discovery.post(discovery.announceName, object: lie.json)
        try await Task.sleep(for: .milliseconds(500))
        #expect(consumer.provider("test.provider")?.control("radio") != nil)
        #expect(consumer.provider("test.provider")?.isConnected == true)
        #expect(provider.consumers.count == 1)
    }

    @Test func aRestartedProviderOnANewPortTakesOver() async throws {
        let first = makeProvider()
        first.start()
        defer { first.stop() }
        let consumer = makeConsumer()
        consumer.start()
        defer { consumer.stop() }
        #expect(await eventually { first.consumers.count == 1 })
        // A second instance of the same app announces a new port while the first still answers.
        let second = makeProvider([Control(id: "fresh", kind: .button)])
        second.start()
        defer { second.stop() }
        #expect(await eventually { second.consumers.count == 1 && first.consumers.isEmpty })
        #expect(consumer.provider("test.provider")?.controls.map(\.id) == ["fresh"])
    }

    @Test func goodbyeLeavesControlsWithoutState() async throws {
        let provider = makeProvider()
        provider.start()
        let consumer = makeConsumer()
        consumer.start()
        defer { consumer.stop() }
        #expect(await eventually { consumer.provider("test.provider")?.isConnected == true })
        provider.stop()
        #expect(await eventually { consumer.provider("test.provider")?.isConnected == false })
        let remembered = try #require(consumer.provider("test.provider"))
        #expect(remembered.controls.count == 5)
        #expect(remembered.controls.allSatisfy { $0.value == nil && $0.text == nil && $0.on == nil })
        consumer.forget("test.provider")
        #expect(consumer.providers.isEmpty)
    }

    @Test func newControlListsReachConsumers() async throws {
        let provider = makeProvider()
        provider.start()
        defer { provider.stop() }
        let consumer = makeConsumer()
        consumer.start()
        defer { consumer.stop() }
        #expect(await eventually { consumer.provider("test.provider")?.isConnected == true })
        provider.setControls([Control(id: "only", name: "Only One", kind: .button), Control(id: "pad", kind: .init(rawValue: "xy-pad"))])
        // Kinds the consumer doesn't know are skipped.
        #expect(await eventually { consumer.provider("test.provider")?.controls.map(\.id) == ["only"] })
    }

    @Test func consumersIgnoreThemselvesAndOlderProtocols() async throws {
        let provider = makeProvider()
        provider.start()
        defer { provider.stop() }
        #expect(await eventually { provider.port != nil })
        // A consumer that never queries, so only these announcements could make it connect.
        let consumer = makeConsumer()
        consumer.start()
        defer { consumer.stop() }
        try await Task.sleep(for: .milliseconds(300))
        consumer.forget("test.provider")
        provider.stop()
        provider.start()
        #expect(await eventually { provider.port != nil })
        let quiet = ApplugConsumer(app: "test.quiet", name: "Quiet", version: nil, discovery: Discovery(prefix: "test.unused.\(UUID().uuidString)"))
        quiet.start()
        defer { quiet.stop() }
        quiet.connect(Announcement(app: quiet.identity.app, name: "Me", port: provider.port!, key: provider.key))
        quiet.connect(Announcement(app: "test.provider", name: "Old", port: provider.port!, protocol: 2, key: provider.key))
        try await Task.sleep(for: .milliseconds(300))
        #expect(quiet.providers.isEmpty)
        #expect(!provider.consumers.contains { $0.name == "Quiet" })
        // The same provider announced properly is connected to.
        quiet.connect(Announcement(app: "test.provider", name: "Test Provider", port: provider.port!, key: provider.key))
        #expect(await eventually { quiet.provider("test.provider")?.isConnected == true })
    }

    /// A consumer's hello, with the provider's key.
    func rawHello(_ provider: ApplugProvider) -> String {
        #"{"type":"hello","app":"raw","name":"Raw","key":"\#(provider.key)"}"#
    }

    /// Connects a raw client to a running provider.
    func rawClient(_ provider: ApplugProvider) async throws -> RawClient {
        #expect(await eventually { provider.port != nil })
        return RawClient(port: try #require(provider.port))
    }

    @Test func anythingBeforeHelloClosesTheConnection() async throws {
        let provider = makeProvider()
        var turns = 0
        provider.onTurn = { _ in turns += 1 }
        provider.start()
        defer { provider.stop() }
        let raw = try await rawClient(provider)
        defer { raw.close() }
        raw.send(#"{"type":"turn","id":"threshold","value":1}"#)
        raw.send(rawHello(provider))
        #expect(await eventually { raw.isClosed })
        #expect(raw.lines.contains { $0.contains("Send hello first") }, "\(raw.lines)")
        #expect(!raw.lines.contains { $0.contains(#""type":"controls""#) })
        #expect(turns == 0)
    }

    @Test func aWebPagesRequestCantReachTheControls() async throws {
        // What a web page's form or fetch() to 127.0.0.1 sends: HTTP, with JSON lines in the body.
        let provider = makeProvider()
        var presses = 0
        provider.onPress = { _ in presses += 1 }
        provider.start()
        defer { provider.stop() }
        let raw = try await rawClient(provider)
        defer { raw.close() }
        let body = #"{"type":"hello","app":"web","name":"Web"}"# + "\n" + #"{"type":"press","id":"radio","down":true}"# + "\n"
        raw.send("POST / HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Type: text/plain\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)", newline: false)
        #expect(await eventually { raw.isClosed })
        try await Task.sleep(for: .milliseconds(100))
        #expect(presses == 0)
        #expect(provider.consumers.isEmpty)
    }

    @Test func unreadableLinesAndHugeNumbersCloseTheConnectionInsteadOfCrashing() async throws {
        let provider = makeProvider()
        provider.start()
        defer { provider.stop() }
        for bad in ["not json", #"{"no":"type"}"#, #"{"type":"turn","id":"scroll","steps":1e300}"#, #"{"type":"turn","id":"scroll","steps":-1e19}"#] {
            let raw = try await rawClient(provider)
            defer { raw.close() }
            raw.send(rawHello(provider))
            #expect(await eventually { raw.lines.contains { $0.contains(#""type":"controls""#) } })
            raw.send(bad)
            #expect(await eventually { raw.isClosed }, "\(bad)")
            #expect(raw.lines.last?.contains(#""type":"error""#) == true, "\(bad) \(raw.lines)")
        }
        #expect(provider.port != nil)
    }

    @Test func oversizedLinesCloseTheConnection() async throws {
        let provider = makeProvider()
        provider.start()
        defer { provider.stop() }
        let raw = try await rawClient(provider)
        defer { raw.close() }
        raw.send(rawHello(provider))
        raw.send(String(repeating: "x", count: Limits.maxLine + 10), newline: false)
        #expect(await eventually { raw.isClosed })
    }
}

// MARK: Helpers

/// Waits for `condition`, running the main run loop so notifications and connections get through.
@MainActor
func eventually(timeout: TimeInterval = 5, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        spinRunLoop()
        await Task.yield()
    }
    return condition()
}

/// Distributed notifications arrive through the main run loop, which Swift Testing doesn't run.
@MainActor
private func spinRunLoop() {
    RunLoop.main.run(until: Date().addingTimeInterval(0.02))
}

/// A plain TCP client that sends raw lines and collects what comes back.
@MainActor
final class RawClient {
    let connection: NWConnection
    private(set) var lines: [String] = []
    private(set) var isClosed = false

    init(port: UInt16) {
        connection = NWConnection(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        connection.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                switch state {
                case .cancelled, .failed, .waiting: self?.isClosed = true   // waiting: refused
                default: break
                }
            }
        }
        connection.start(queue: .main)
        receive()
    }

    func send(_ line: String, newline: Bool = true) {
        connection.send(content: Data((newline ? line + "\n" : line).utf8), completion: .idempotent)
    }

    func close() { connection.cancel() }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, complete, error in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let data, let text = String(data: data, encoding: .utf8) {
                    self.lines += text.split(separator: "\n").map(String.init)
                }
                if complete || error != nil { self.isClosed = true } else { self.receive() }
            }
        }
    }
}
