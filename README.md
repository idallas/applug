# Applug

Let your Mac apps share their knobs and switches.

An app that **provides** controls (a radio-mode switch, a threshold, an input meter) offers them over Applug. Any app that **consumes** them (a MIDI controller app, a remote control on your phone) finds it, shows its controls with their live state, and turns or presses them. Everything stays on the Mac: providers listen on 127.0.0.1 and announce themselves with distributed notifications, so there's no setup and no Local Network prompt.

Applug grew out of [Twist Commando](https://twistcommando.com)'s App Link and keeps its messages. The protocol is in [SPEC.md](SPEC.md).

| | |
|---|---|
| Providers | ThUNER (planned) |
| Consumers | Twist Commando, Action Hero (planned) |

## Offering controls

```swift
import Applug

let provider = ApplugProvider(name: "ThUNER", controls: [
    Control(id: "radio", name: "Radio Mode", kind: .toggle, text: "Off", on: false),
    Control(id: "threshold", name: "Threshold", kind: .level, value: 0.4, text: "-24 dB"),
    Control(id: "input", name: "Input", kind: .meter, channels: 2),
])
provider.appLinkCompatibility = AppLinkCompatibility()   // also reach Twist Commando 0.13 and 0.14

provider.onPress = { press in
    if press.id == "radio", press.down { model.radioMode.toggle() }
}
provider.onTurn = { turn in
    if turn.id == "threshold", let value = turn.value { model.threshold = value }
}
provider.onWatchedMetersChange = { meters in model.measuring = meters }
provider.start()

// Whenever the state changes, and after every turn or press:
provider.set("radio", text: model.radioMode ? "On" : "Off", on: model.radioMode)
// About 20 times a second, while someone's watching:
provider.sendMeter("input", levels: [left, right])
```

`set` sends only what changed, except right after a turn or press, when it always goes out so consumers settle on the real value. `clearText(_:)` removes a control's text.

## Using controls

```swift
let consumer = ApplugConsumer(name: "Action Hero")
consumer.start()

// consumer.providers is @Observable: apps, their controls, and live state.
consumer.tap(app: "com.idallas.thuner", id: "radio")
consumer.turn(app: "com.idallas.thuner", id: "threshold", value: 0.5)
consumer.watchMeter(app: "com.idallas.thuner", id: "input", true)
consumer.onMeter = { app, id, levels in … }
```

To keep showing a provider's controls while it isn't running, save `providers.map(\.remembered)` (they're `Codable`) and pass them to `remember(_:)` at launch.

## Trying it

```bash
swift run applug demo            # a provider with made-up controls
swift run applug list            # every provider and its controls
swift run applug watch --meters  # every change as it happens
swift run applug press "Applug Demo" power
swift run applug turn "Applug Demo" volume 0.8
```

## Adding it to an app

Swift Package Manager, macOS 14 or later:

```swift
.package(url: "https://github.com/idallas/applug", from: "0.1.0")
```

Fixes arrive with new tags, so depend on a version, not a branch.

Sandboxed providers need `com.apple.security.network.server`; sandboxed consumers need `com.apple.security.network.client`.

## Trust

Providers listen on 127.0.0.1 only, so other computers can't reach them. Each provider makes a random key when it starts and announces it; consumers must send it back, and announcements only reach your own processes, so other accounts on the Mac and web pages can't connect either. Apps running as you can, though, like with App Link and MIDI. Offer only controls you'd be happy for any app you run to use. The details are in [SPEC.md › Trust](SPEC.md#trust).

## License

MIT. See [LICENSE](LICENSE).
