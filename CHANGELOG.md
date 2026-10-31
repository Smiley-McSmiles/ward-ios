# Changelog

## 1.0.6 — unreleased

- Native SwiftUI app for iPhone and iPad running iOS 17+.
- XMPP core with STARTTLS, trust-on-first-use certificate pinning, PLAIN/SCRAM authentication,
  stream-management acknowledgements, keepalive and automatic reconnection.
- In-band account creation (XEP-0077) when the server offers it.
- One-to-one and group chats with carbons, MAM catch-up, replies, reactions, edits, retractions,
  receipts, read markers, typing indicators, drafts and mentions.
- PEP (XEP-0084) and vCard avatars, Open Graph link previews, HTML chat export, scheduled sending,
  global search, Tenor GIF search, contact and location sharing.
- File and image upload (XEP-0363), camera, Photos picker, Quick Look, video playback, voice
  messages and AES-GCM attachment decryption (XEP-0454).
- Group topics, members, roles, affiliations, moderation, invites and bookmarks.
- Server administration (XEP-0050), XML console and service discovery browser.
- App lock with Face ID/passcode, privacy shroud, Keychain passwords and optional link previews.
- Privacy manifest, App Store metadata, fastlane lanes and signed TestFlight/App Store workflow.

### Known gaps

- OMEMO 2, legacy OMEMO and OpenPGP message encryption are not wired yet.
- WebRTC audio/video media for calls is not wired yet.
- Encrypted uploads are gated on stanza encryption; receive/decrypt is implemented.
