import Foundation
import Testing
@testable import Applug

struct MessageTests {
    func decode(_ line: String) throws -> Message { try Message.decode(Data(line.utf8)) }

    @Test func roundTripsEveryMessage() throws {
        let messages: [Message] = [
            .hello(Hello(app: "com.example.Mixer", name: "Mixer", version: "1.2", key: "0123456789abcdef")),
            .welcome(Welcome(app: "Twist Commando", version: "0.14.0", protocolVersion: 2, meters: true)),
            .controls([
                Control(id: "volume", name: "Volume", kind: .level, value: 0.5, text: "-6 dB"),
                Control(id: "mute", name: "Mute", kind: .toggle, on: true, group: "Main"),
                Control(id: "input", name: "Input", kind: .meter, channels: 2),
                Control(id: "progress", kind: .level, value: 0.25, readOnly: true),
            ]),
            .update(Update(id: "volume", value: 0.4, text: "-8 dB", on: false, name: "Master")),
            .update(Update(id: "volume", text: .some(nil))),
            .meter(id: "input", levels: [-12.5, -160]),
            .turn(id: "volume", value: 0.75, steps: nil),
            .turn(id: "scroll", value: nil, steps: -3),
            .press(id: "mute", down: true),
            .meterSubscribe(id: "input", on: false),
            .error("No control \"x\""),
        ]
        for message in messages {
            var line = message.encoded()
            #expect(line.last == 0x0A)
            line.removeLast()
            #expect(try Message.decode(line) == message)
        }
    }

    @Test func readsAppLinkStyleLines() throws {
        // Integers where decimals are expected, and fields this package doesn't know.
        #expect(try decode(#"{"type":"turn","id":"v","value":1,"extra":true}"#) == .turn(id: "v", value: 1, steps: nil))
        #expect(try decode(#"{"type":"welcome","app":"Twist Commando","version":"0.14.0","protocol":2,"meters":true}"#)
            == .welcome(Welcome(app: "Twist Commando", version: "0.14.0", protocolVersion: 2, meters: true)))
        // A hello without a name uses the app; one without a protocol is App Link 1.
        #expect(try decode(#"{"type":"hello","app":" com.example.X "}"#) == .hello(Hello(app: "com.example.X", name: "com.example.X", protocolVersion: nil)))
    }

    @Test func textNullClearsAndMissingTextLeavesAlone() throws {
        guard case .update(let cleared) = try decode(#"{"type":"update","id":"a","text":null}"#),
              case .update(let untouched) = try decode(#"{"type":"update","id":"a","on":true}"#)
        else { Issue.record("not updates"); return }
        #expect(cleared.text == .some(nil))
        #expect(untouched.text == nil)
        #expect(untouched.on == true)
    }

    @Test func booleansAndNumbersDontMix() throws {
        guard case .update(let update) = try decode(#"{"type":"update","id":"a","value":true,"on":1}"#) else {
            Issue.record("not an update"); return
        }
        #expect(update.value == nil)
        #expect(update.on == nil)
    }

    @Test func numbersTooBigForIntDontCrash() throws {
        #expect(throws: Message.DecodeError.self) { try decode(#"{"type":"turn","id":"s","steps":1e300}"#) }
        #expect(throws: Message.DecodeError.self) { try decode(#"{"type":"turn","id":"s","steps":-9223372036854775809}"#) }
        #expect(try decode(#"{"type":"turn","id":"s","steps":1e300,"value":0.5}"#) == .turn(id: "s", value: 0.5, steps: nil))
        #expect(try decode(#"{"type":"hello","app":"a","protocol":1e300}"#) == .hello(Hello(app: "a", name: "a", protocolVersion: nil)))
        #expect(try decode(#"{"type":"welcome","protocol":-1e300}"#) == .welcome(Welcome(app: nil, version: nil, protocolVersion: nil, meters: false)))
        guard case .controls(let controls) = try decode(#"{"type":"controls","controls":[{"id":"m","kind":"meter","channels":1e300}]}"#) else {
            Issue.record("not controls"); return
        }
        #expect(controls[0].channels == nil)
    }

    @Test func peerTextIsCleaned() throws {
        guard case .hello(let hello) = try decode(#"{"type":"hello","app":"a","name":"Evil\u001b]0;title\u0007\u202Eman","version":"\u0000x"}"#) else {
            Issue.record("not a hello"); return
        }
        #expect(hello.name == "Evil]0;titleman")
        #expect(hello.version == "x")
        // Limits count Unicode scalars, so one character can't be huge.
        let huge = "e" + String(repeating: "\u{301}", count: 10_000)
        #expect(Limits.name(huge).unicodeScalars.count == Limits.maxName)
        guard case .meter(_, let levels) = try decode(#"{"type":"meter","id":"m","levels":[-500,99,true,-3,-4]}"#) else {
            Issue.record("not a meter"); return
        }
        #expect(levels == [-160, 24])
    }

    @Test func rememberedControlsLoadEvenWithFieldsMissing() throws {
        let saved = Data(#"[{"id":"a","name":"A","kind":"level"},{"id":"b"}]"#.utf8)
        let controls = try JSONDecoder().decode([Control].self, from: saved)
        #expect(controls.map(\.readOnly) == [false, false])
        #expect(controls[1].kind == .button)
    }

    @Test func unknownTypesAreKeptNotRejected() throws {
        #expect(try decode(#"{"type":"ping"}"#) == .unknown(type: "ping"))
    }

    @Test func rejectsWhatItCantUse() {
        #expect(throws: Message.DecodeError.self) { try decode("not json") }
        #expect(throws: Message.DecodeError.self) { try decode(#"["type"]"#) }
        #expect(throws: Message.DecodeError.self) { try decode(#"{"type":"hello"}"#) }
        #expect(throws: Message.DecodeError.self) { try decode(#"{"type":"turn","id":"a"}"#) }
        #expect(throws: Message.DecodeError.self) { try decode(#"{"type":"meter","id":"a","levels":[]}"#) }
        #expect(throws: Message.DecodeError.self) { try decode(#"{"type":"controls"}"#) }
    }

    @Test func controlsWithUnknownKindsArePassedOnForTheConsumerToSkip() throws {
        guard case .controls(let controls) = try decode(#"{"type":"controls","controls":[{"id":"a","kind":"xy-pad"},{"id":"b","kind":"button"},{"kind":"level"}]}"#) else {
            Issue.record("not controls"); return
        }
        #expect(controls.map(\.id) == ["a", "b"])
        #expect(controls[0].kind.isKnown == false)
    }

    @Test func announcementsRoundTripAsJSONStrings() {
        let key = "0123456789abcdef0123456789abcdef"
        let announcement = Announcement(app: "com.idallas.thuner", name: "ThUNER", port: 51234, key: key, pid: 812)
        #expect(announcement.json == #"{"app":"com.idallas.thuner","key":"0123456789abcdef0123456789abcdef","name":"ThUNER","pid":812,"port":51234,"protocol":3}"#)
        #expect(Announcement(json: announcement.json) == announcement)
        // Extra fields and a pid that isn't a process id don't spoil an otherwise good announcement.
        #expect(Announcement(json: #"{"app":"a","name":"A","port":50000,"protocol":3,"key":"\#(key)","pid":"x","extra":1}"#)?.pid == nil)
        for bad in [
            #"{"app":"","name":"x","port":50000,"protocol":3,"key":"\#(key)"}"#,
            #"{"app":"a","name":"x","port":0,"protocol":3,"key":"\#(key)"}"#,
            #"{"app":"a","name":"x","port":80,"protocol":3,"key":"\#(key)"}"#,
            #"{"app":"a","name":"x","port":50000,"protocol":3}"#,
            #"{"app":"a","name":"x","port":50000,"protocol":3,"key":"short"}"#,
            #"{"app":"a\nb","name":"x","port":50000,"protocol":3,"key":"\#(key)"}"#,
        ] {
            #expect(Announcement(json: bad) == nil, "\(bad)")
        }
        #expect(Announcement.makeKey().count == 32)
        #expect(Announcement.makeKey() != Announcement.makeKey())
    }
}

struct LimitsTests {
    @Test func tidyDropsMissingAndRepeatedIDs() {
        let tidy = Limits.tidy([
            Control(id: "", kind: .button),
            Control(id: "a", name: "First", kind: .button),
            Control(id: "a", name: "Second", kind: .toggle),
            Control(id: "b", name: "", kind: .level, value: 4),
        ])
        #expect(tidy.map(\.id) == ["a", "b"])
        #expect(tidy[0].name == "First")
        #expect(tidy[1].name == "b")
        #expect(tidy[1].value == 1)
    }

    @Test func tidyCapsCountsAndLengths() {
        let many = (0..<600).map { Control(id: "c\($0)", kind: .button) }
        #expect(Limits.tidy(many).count == 512)
        let long = Limits.tidy([Control(id: String(repeating: "x", count: 300), kind: .button, text: String(repeating: "y", count: 2000))])
        #expect(long[0].id.count == 256)
        #expect(long[0].text?.count == 1024)
    }

    @Test func metersAreMonoOrStereoAndOthersHaveNoChannels() {
        let tidy = Limits.tidy([
            Control(id: "m1", kind: .meter, channels: 7),
            Control(id: "m2", kind: .meter, channels: 2),
            Control(id: "l", kind: .level, channels: 2),
        ])
        #expect(tidy.map(\.channels) == [1, 2, nil])
    }
}
