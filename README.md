# Ward for iOS

A native SwiftUI translation of [Ward for Android](../Ward-Android). Ward is a private
messenger for the open XMPP network, with one-to-one and group chats, files, voice messages,
reactions, server administration and an interface built around Apple's design language.

<p align="center">
  <img src="WardiOS/Resources/Assets.xcassets/WardLogo.imageset/ward-512.png" width="128" alt="Ward icon">
</p>

> **Status:** this is a complete native app scaffold with a working XMPP core, local history,
> chat UI, group chats, media, settings, app lock and server tools. OMEMO/OpenPGP ratchets and
> WebRTC call media are the two large pieces that are not finished; see [PARITY.md](PARITY.md).
> The app is deliberately honest in the UI instead of silently downgrading an encrypted chat.

## Highlights

- **Native SwiftUI, no web wrapper.** iOS 17+, iPhone and iPad, light and dark, nine accent
  colours, dynamic type and a responsive split-view layout on iPad.
- **Modern iOS motion.** Spring message insertion, morphing send button, symbol effects,
  animated presence, pulsing call rings, matched transitions for sheets and a custom splash.
- **A real XMPP client.** TCP/TLS with STARTTLS and trust-on-first-use certificate pinning,
  SASL PLAIN/SCRAM-SHA-1/SCRAM-SHA-256, roster and presence, resource binding, stream
  management acknowledgements, keepalive and automatic reconnection with exponential backoff.
- **Conversations.** One-to-one and group chats, carbons, MAM catch-up, replies, reactions,
  edits, retractions, delivery/read receipts, typing indicators, drafts, mentions, per-chat
  and global search, pins, mutes, archives and message requests.
- **Groups.** Join and leave, nicknames, topics, member lists, roles, affiliation changes,
  kicks, bans, invites and bookmarks with autojoin.
- **Media.** HTTP file upload (XEP-0363), photo/file pickers, camera, image previews, video
  playback, file Quick Look, voice recording and playback, and the same image/audio/file
  metadata as the Android app. Media is cached locally and can be cleared.
- **Server tools.** Every ad-hoc command the server advertises (XEP-0050) with native forms,
  notes and previous/next/complete/cancel, a live XML console with raw sending, and a service
  discovery browser.
- **Privacy.** Keychain-backed passwords, an app passcode with Face ID/Touch ID, a screen
  privacy shroud, ephemeral notification previews and no analytics.
- **Same icon.** The iOS app icon and in-app logo are generated from Ward's original shield
  artwork.

## Requirements

- macOS 14 or newer
- Xcode 15.4 or newer (Xcode 16 is recommended; the project uses iOS 17 APIs)
- An iPhone or iPad running iOS 17+, or the iOS Simulator
- No CocoaPods, no Swift Package dependencies, no network build step

The project is intentionally self-contained: SQLite is accessed through the system `libsqlite3`,
and XMPP is implemented with `Network.framework`, `FoundationXML` and `CryptoKit`.

## Build

```sh
open Ward.xcodeproj
```

Choose the **Ward** scheme and run. For a physical device, set your development team in
**Signing & Capabilities** and change the bundle identifier from `org.ward.ios` if needed.

You can also regenerate the Xcode project with [XcodeGen](https://github.com/yonaskolb/XcodeGen):

```sh
xcodegen generate
open Ward.xcodeproj
```

### Trying it with a local Prosody

From the Ward GTK checkout:

```sh
tools/run-prosody
```

It prints a port and test users (`alice`, `bob`, `admin`, password `password`). In the iOS
Simulator use `127.0.0.1` and that port. On a device, use your Mac's LAN address. Add the port
under **Sign in → Advanced**. The simulator needs **Require STARTTLS** for most local setups.

## Architecture

```text
WardiOS/
  App/         App entry point, observable model, root navigation, splash
  Design/      Palette, typography, reusable SwiftUI components and formatting
  Models/      Account, Contact, Chat, Message, Device, settings schema
  Storage/     SQLite store and Keychain secrets
  XMPP/        XML stream, TLS transport, SASL, connection state machine, session,
               message/group/roster/upload/MAM/admin/discovery logic
  Services/    Notifications, app lock, media cache, voice recording, audio playback
  UI/          Welcome, chat list, contacts, conversation, settings, server, calls,
               XML console, discovery, sheets and viewers
  Resources/   Asset catalogue, app icon and call sounds
```

The local SQLite database is the source of truth for the interface. Entities are stored as JSON
next to indexed columns (`chatId`, `jid`, `timestamp`, `body`), which keeps migrations simple
and preserves full-text search without exposing a second schema to every screen. One
`XMPPSession` owns the wire connection for each account and emits events to the observable
`AppModel`.

## Security notes

- Passwords are stored in the iOS Keychain with `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`.
- TLS uses trust on first use. The leaf certificate fingerprint is pinned per server. Public CA
  certificates are validated normally; self-signed certificates are accepted on first use and
  pinned. A changed certificate fails the connection rather than silently trusting it.
- Ward will not send a password over a plaintext stream. STARTTLS is required unless the account
  explicitly uses the `none` transport (not exposed in the UI).
- OMEMO/OpenPGP are not wired yet. Encrypted chats are marked, the UI explains the gap, and
  sending is blocked when a chat explicitly asks for OMEMO or OpenPGP. New chats send
  unencrypted after a visible one-time warning. Do not use this build where confidentiality
  against the server is required.
- App lock uses Face ID/Touch ID and a four-digit passcode. The passcode is salted and hashed
  before being stored in the Keychain. The app shroud hides content in the app switcher.
- iOS restricts long-lived background sockets. Ward keeps the connection while it is running and
  reconnects when it returns to the foreground; it cannot promise Android-style always-on
  delivery. Use a server with push (XEP-0357) or keep the app open for time-sensitive messaging.

## License

MIT, matching Ward. The Ward icon is Ward's icon. See [LICENSE](LICENSE).

## Verification

This project was authored on a Linux workstation, where Xcode and the iOS SDK are not
available. The Swift sources were parsed with the Swift 6 toolchain, and the Foundation-only
core (models, XML stream, transport, connection state machine, XMPP session, SQLite store and
app model) was type-checked against small API stubs. The SwiftUI layer needs a real Xcode build
on macOS to compile and run. `scripts/build.sh` runs that build; `scripts/check-swift.sh`
performs the Linux syntax pass.
