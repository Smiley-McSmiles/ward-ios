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
- OMEMO 2 (XEP-0384) for one-to-one chats through the new MIT-licensed `WardCrypto` package:
  X3DH, Double Ratchet, SCE envelopes, bundles, prekeys, per-device sessions, trust filtering,
  encrypted reactions/edits/retractions, own-other-device inclusion and encrypted attachments.
- OMEMO interoperability tests against the independent `twomemo` Python backend in both
  directions, including DH ratchets and out-of-order delivery.
- Group topics, members, roles, affiliations, moderation, invites and bookmarks.
- Server administration (XEP-0050), XML console and service discovery browser.
- App lock with Face ID/passcode, privacy shroud, Keychain passwords and optional link previews.
- Privacy manifest, App Store metadata, fastlane lanes and signed TestFlight/App Store workflow.

### Known gaps

- Group OMEMO sending, legacy OMEMO 0.3 and OpenPGP message encryption are not implemented.
- WebRTC audio/video media for calls is not wired yet.
- OMEMO is verified against one independent backend; reports from Gajim, Conversations,
  Dino, Monal and other clients are still welcome.
