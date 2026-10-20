# Applug protocol

Version 3 (2026-10-19). Draft.

Applug lets a Mac app offer its controls (levels, switches, buttons, meters) to other apps on the same Mac. ThUNER offers its radio switch and input meters; Twist Commando turns them with a knob; Action Hero shows them as actions on a phone.

It grew out of Twist Commando's App Link, whose messages it keeps. Applug's version numbers continue App Link's: App Link 1 was the first, App Link 2 added meters, and Applug is 3.

## Roles

- A **provider** offers controls. It listens on a local port and announces itself.
- A **consumer** uses them. It finds providers, connects to each, turns and presses their controls, and shows their state.

One app can be both. Any number of consumers can connect to a provider at once, and a consumer can connect to any number of providers.

## Finding providers

Discovery uses macOS distributed notifications. Each notification's `object` is a JSON string, because macOS drops `userInfo` from notifications that sandboxed apps post. Post them with `deliverImmediately: true`, so apps in the background get them straight away.

| Name | Posted by | When | `object` |
|---|---|---|---|
| `dev.applug.announce` | provider | when it starts listening, and in reply to queries (at most once a second) | an announcement |
| `dev.applug.query` | consumer | when it starts, and whenever it wants to check who's there | none, or `"{}"` |
| `dev.applug.goodbye` | provider | when it stops offering controls (quitting, or switched off) | an announcement |

An announcement:

```json
{"app": "com.idallas.thuner", "name": "ThUNER", "port": 51234, "protocol": 3, "key": "9f3c0e6a51d2b8471e0c4f9a2d6b3e85", "pid": 812}
```

- `app` (string, required): the provider's bundle identifier, or another stable name. Consumers use it to remember the provider's controls across launches. At most 256 characters, no control characters.
- `name` (string, required): the name to show people.
- `port` (integer, required): the TCP port it listens on, on 127.0.0.1. 1024 or higher.
- `protocol` (integer, required): 3.
- `key` (string, required): a random value, at least 16 characters, made fresh each time the provider starts listening. Consumers send it back in their `hello`. Distributed notifications only reach processes of the same user, so other accounts on the Mac, and web pages, never see it. (Applug's package uses 128 random bits as hex.)
- `pid` (integer): the provider's process id, so consumers can check the announcement comes from the app it names.

A consumer:

- Skips announcements with its own `app` (an app that's both provider and consumer), and ones with a `protocol` below 3. Higher numbers are fine: the `hello`s settle which version both sides use.
- Skips an announcement for an app that's running (by bundle identifier) when `pid` isn't one of that app's processes. That stops one app casually announcing itself as another.
- Connects to the announced port, and checks that the provider's `hello` has the announced `app`; if not, it closes.
- If an app it's already connected to announces a different port (it restarted, or someone's pretending), connects to the new port alongside the working connection, and switches only once the new one has said `hello` as the same app and sent its controls. If the old connection drops first, the new one simply takes over.
- Treats `goodbye` as a hint, since anyone can post one: it means "don't look for me when my connection drops", not "disconnect now".
- Keeps at most 64 providers, connected or remembered.

Announcements and goodbyes aren't proof of identity. See [Trust](#trust).

## Connecting

TCP to `127.0.0.1` on the announced port. Providers listen on 127.0.0.1 only, never on other interfaces. The port is the provider's choice; asking the system for any free port is fine. Loopback traffic doesn't trigger macOS's Local Network prompt. A sandboxed provider needs `com.apple.security.network.server`, and a sandboxed consumer `com.apple.security.network.client`.

Each message is one JSON object on one line, ending in `\n` (newline-delimited JSON), in both directions. Every message has a string `type`. Unknown fields are ignored, so either side can add fields later; so are unknown `type`s.

A line that isn't a JSON object with a string `type`, or a message that can't be used (a `turn` without an `id`), ends the connection: send `error` and close. This is stricter than App Link on purpose. Besides catching bugs early, it keeps out web pages: a page can't open a raw socket, but it can send an HTTP request to 127.0.0.1, and that request's body could hold JSON lines. Its first line (`POST / HTTP/1.1`) isn't JSON, so the connection closes before the body is read. Numbers are read as JSON numbers; a whole number outside ±1,000,000,000 (`steps`, `protocol`, `channels`) counts as missing, so a `turn` whose only movement is such a `steps` ends the connection.

### Handshake

1. The consumer connects and sends `hello`.
2. The provider replies with its own `hello`, then `controls` with every control and its current state.
3. From then on either side can send whenever it likes.

The consumer's `hello`, with the key from the announcement:

```json
{"type": "hello", "app": "com.twistcommando.TwistCommando", "name": "Twist Commando", "version": "0.15.0", "protocol": 3, "key": "9f3c0e6a51d2b8471e0c4f9a2d6b3e85"}
```

The provider's `hello`:

```json
{"type": "hello", "app": "com.idallas.thuner", "name": "ThUNER", "version": "1.3.4", "protocol": 3}
```

- `app` and `name` as in announcements. `version` (optional) is the app's own version, for diagnostics.
- `protocol`: 3. If the two sides send different numbers, both use the lower one's messages. (There's only 3 for now.)
- `key` (consumer's only, required): the announcement's key. A provider closes the connection, after an `error`, when it's missing or wrong.

The consumer's `hello` must be its first message: if anything else comes first, the provider sends `error` and closes. Until then lines can be at most 4 KB, and the provider closes connections that haven't said `hello` within 3 seconds. A second `hello` on the same connection is ignored. A consumer closes a connection whose provider hasn't sent its `controls` within 5 seconds.

## Controls

```json
{"type": "controls", "controls": [
  {"id": "radio", "name": "Radio Mode", "kind": "toggle", "on": false, "text": "Off"},
  {"id": "threshold", "name": "Threshold", "kind": "level", "value": 0.42, "text": "-24 dB"},
  {"id": "nowPlaying", "name": "Now Playing", "kind": "level", "value": 0.3, "text": "1:12 / 3:50", "readOnly": true},
  {"id": "inputLevel", "name": "Input", "kind": "meter", "channels": 2, "group": "Levels"}
]}
```

Sent by the provider after its `hello`, and again whenever its list changes. Each `controls` replaces the whole list. Up to 512 controls, in the order to show them.

| Field | Type | |
|---|---|---|
| `id` | string, required | Stable and unique within the provider. Consumers save it, so don't change it between versions. Up to 256 characters, no control characters. |
| `name` | string | What people see. Defaults to `id`. Up to 256 characters. |
| `kind` | string, required | See below. |
| `value` | number | A level's position, 0 to 1. |
| `text` | string | How the provider shows the current state ("-24 dB", "Playing", "Off"). Up to 1024 characters. |
| `on` | boolean | Whether it's on. Any kind can send it: a toggle's state, or a level that's muted. |
| `group` | string | A heading to list it under, for providers with many controls ("Deck A"). Up to 256 characters. |
| `channels` | integer | A meter's: 1 or 2. Defaults to 1. |
| `readOnly` | boolean | New in 3. A level the consumer can show but not turn (a progress bar, a reading). Defaults to false. |

Kinds:

| `kind` | What it is | Consumers send |
|---|---|---|
| `level` | Something with two ends: a volume, a threshold. | `turn` with `value` |
| `steps` | Something endless: scrolling a list, nudging. | `turn` with `steps` |
| `toggle` | A switch. The provider flips it on `press` and reports `on`. | `press` |
| `button` | Does something once. | `press` |
| `meter` | Live levels to watch. | `meterSubscribe` |

Every kind except `meter` can also be pressed: a level's press could reset it, a steps control's could choose the current item.

A consumer ignores controls whose `kind` it doesn't know, instead of guessing. (Twist Commando's App Link 1 listener treats them as levels.) A consumer drops controls without an `id`, and every control after the first with a repeated `id`.

## Messages from the provider

### `update`

```json
{"type": "update", "id": "radio", "on": true, "text": "On"}
```

A control's state changed. Send only the fields that changed: `value`, `text`, `on`, or `name`. `"text": null` clears the text. After a `turn` or `press`, send the resulting state, even when it didn't change, so the consumer's display settles on the real value.

`kind`, `group`, `channels` and `readOnly` can't change through `update`. Send a new `controls` instead.

### `meter`

```json
{"type": "meter", "id": "inputLevel", "levels": [-12.5, -14.0]}
```

The peak level of each channel since the last `meter`, in dBFS, from -160 (silence) to +24. One number per channel, so one or two. Send about 20 times a second, and only to consumers that subscribed to that meter.

### `error`

```json
{"type": "error", "message": "No control \"radoi\""}
```

Something the other side sent couldn't be used. For people reading logs; don't parse it. Either side can send it.

## Messages from the consumer

### `turn`

```json
{"type": "turn", "id": "threshold", "value": 0.5}
{"type": "turn", "id": "scroll", "steps": -3}
```

Move a level to `value` (0 to 1), or a steps control by `steps` (a whole number from -10,000 to 10,000, negative to go back). A provider ignores turns on read-only levels, meters, toggles and buttons, and replies with `update` for the rest. A `turn`, `press` or `meterSubscribe` for an `id` it doesn't have gets an `error`; the connection stays open, since the list may just have changed.

### `press`

```json
{"type": "press", "id": "radio", "down": true}
{"type": "press", "id": "radio", "down": false}
```

`down: true` when pressed, `down: false` when let go. Consumers without a physical press (a tap on a phone) send both, one after the other. Providers usually act on `down: true`; the release is there for controls that work while held.

### `meterSubscribe`

```json
{"type": "meterSubscribe", "id": "inputLevel", "on": true}
```

Start (`on: true`) or stop (`on: false`) receiving `meter` messages for one meter. Subscriptions belong to the connection: they end when it closes, and a consumer that reconnects subscribes again after the new `controls` arrive. A provider can stop measuring a meter nobody is subscribed to.

## Limits

- A line longer than 1 MB (4 KB before `hello`): send `error` and close the connection.
- A line that isn't a usable message, or anything before `hello`: send `error` and close (see [Connecting](#connecting)).
- Connections: a provider accepts at most 64 consumers, at most 16 of them still to say `hello`, and turns others away.
- More than 512 controls: use the first 512.
- Text from the other side (`app`, `name`, `id`, `group`, `text`, `version`, error messages): drop control characters and text-direction overrides, which could make a name read as something else or slip escape codes into a terminal, then cut `app`, `id`, `name`, `group` and `version` to 256 Unicode characters and `text` and error messages to 1024. (Characters means Unicode scalars, so a "character" can't hide a megabyte of combining marks.)
- `steps` outside ±10,000: use ±10,000. Meter levels outside -160 to +24: use the nearest. More levels than channels: use the first.
- Either side may close a connection that has more than 1000 messages, or 8 MB, waiting to be sent, rather than letting them pile up.
- Sending an `error` before closing: send it as the connection's last data and keep reading (and ignoring) for a moment before closing, so the other side gets to read it.

## Disconnecting

Either side closes the TCP connection. Consumers keep the provider's controls (minus state) to show while it's away, so a knob can stay set up while the app is closed. A consumer whose connection drops without a `goodbye` may post a `query` a few seconds later, to reconnect if the provider just restarted its listener, backing off (the package goes from 3 seconds to a minute) while nothing answers.

## Trust

What keeps who out:

- **Other computers:** providers listen on 127.0.0.1 only.
- **Other accounts on this Mac** (another person's login, Guest, system services): 127.0.0.1 is shared by every account, so they could reach a provider's port, but they can't get its key, because distributed notifications only reach the same user's processes.
- **Web pages:** they can only send HTTP to 127.0.0.1, and an HTTP request's first line closes the connection. They can't see the key either.
- **Apps running as you:** nothing. Like App Link and MIDI, anything running as you can receive announcements (key included), connect to a provider and turn its controls, or announce itself under another app's name. The pid check and the `hello` check make casual impersonation fail, but they aren't authentication; an app running as you can do far worse to your other apps anyway.

So providers should offer only controls they'd be happy for any app you run to use, and both sides should treat everything they receive as untrusted input: check ids, clamp values, clean text, honour the limits.

## App Link 1 and 2 (Twist Commando 0.13 and 0.14)

Twist Commando 0.14 and earlier don't know Applug. They listen on 127.0.0.1:9034 and wait for apps to connect in. A provider that wants to work with them too can also:

1. Connect to 127.0.0.1:9034 while Twist Commando is running (an app whose bundle identifier starts with `com.twistcommando.`), retrying every few seconds, backing off to a minute.
2. Send `hello` with its `app`, `name` and `"protocol": 3` (no key).
3. Wait up to 5 seconds for Twist Commando's `welcome` (no welcome: close, and retry later):
   ```json
   {"type": "welcome", "app": "Twist Commando", "version": "0.14.0", "protocol": 2, "meters": true}
   ```
   - `protocol` 3 or higher: this Twist Commando finds Applug providers itself. Close the connection, and don't connect to 9034 again until Twist Commando relaunches.
   - Otherwise: send `controls`, leaving out meters unless `meters` is true, and `readOnly` levels go as plain levels (Twist Commando ignores the field). Then carry on exactly as with an Applug consumer.

A Twist Commando that speaks Applug keeps listening on 9034 for apps that only know App Link, and should reply to their `hello` with `welcome` `"protocol": 3`. If the same `app` reaches it both ways, it prefers the Applug connection.

The Applug Swift package does all of this when you turn on `appLinkCompatibility`.

## Changes from App Link 2

- Providers listen and consumers connect, instead of everyone connecting to Twist Commando's port. Any number of consumers.
- Discovery with distributed notifications.
- Both sides send `hello`; there's no `welcome` (except on the App Link 1 port). The consumer's carries the provider's key.
- `readOnly` for levels.
- Unknown kinds are skipped, not treated as levels.
- A line over 1 MB, a line that isn't a usable message, or a message before `hello` closes the connection. (App Link answered with `error` and carried on.)
- Groups are cut at 256 characters, which is what Twist Commando does now (its docs say 1024).
