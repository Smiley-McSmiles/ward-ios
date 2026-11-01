# Parity with Ward for Android

Ward for iOS is a native translation of the Android front end. This file tracks the Android
feature set and what this build does today. The interface is deliberately honest about gaps
instead of pretending a feature works.

## Implemented

| Android feature | iOS |
| --- | --- |
| Sign in, several accounts, custom host/port/TLS, invites | Yes. Same `host`, `port` and TLS options; invite links and `xmpp:` URLs prefill sign-in. XEP-0077 account creation is available when the server offers it |
| Self-signed certificate handling | Trust on first use with a pinned leaf fingerprint; changed certificates are refused |
| Roster, presence, subscriptions, blocking | Yes, including manual subscription requests and contact requests |
| Contacts, contact requests, rename, groups | Yes; rename is stored locally and pushed to the roster |
| Profile photos: PEP and vCard fallback | Yes: XEP-0084 PEP metadata/data fetch and publishing, with vCard fallback |
| One-to-one chats, carbons, MAM catch-up, history | Yes, with deduplication between carbons, echoes and MAM pages |
| Markdown, code blocks, quotes, lists, tables, links | Yes, with horizontal code blocks, syntax colouring and copy |
| Replies, reactions, edits, retractions, receipts, read markers | Yes |
| Typing notifications, drafts, mentions, `/me`, message search | Yes, per-chat search; global search is not exposed |
| Message layout, text scale, accent colours, light/dark | Yes: bubbles/cozy/compact, 80–200% type, nine accents |
| File/image upload, previews | Yes: XEP-0363 slots, photo/file pickers, camera, image viewer, video player, Quick Look; incoming XEP-0454 files are decrypted |
| Voice messages | Yes: AAC recording, waveform, playback progress |
| Groups and channels, private/public presets, members, roles, moderation | Yes: join, leave, topic, nickname, members, roles, affiliations, kick, ban, invite |
| Topics, nicknames, invites, bookmarks with autojoin, group search | Yes for topics, nicknames, invites and bookmarks; group search is address based |
| Server administration (XEP-0050), every advertised command, forms, notes | Yes, including previous/next/complete/cancel and media fields |
| User counts, online/registered lists, uptime, invites | Exposed through whatever ad-hoc commands the server publishes |
| XML console, service discovery browser, debug log | Yes: live log, filtering, copy, raw send, recursive discovery |
| Notifications, background connection, boot autostart | Local notifications and foreground connection; iOS has no boot autostart and restricts background sockets |
| Stream management and resumption (XEP-0198) | Stream management acks and reconnection; resumption tokens are not persisted across launches |
| Block screenshots and recent-apps preview | A privacy shroud and screen-capture warning; iOS cannot hard-block screenshots |
| Preferences generated from a typed schema | Yes, same groups and defaults (desktop-only switches omitted) |
| OMEMO device fingerprints, trust, BTBV | Device lists with trust/distrust/forget and OMEMO 2 fingerprints. Forgetting a device also removes its ratchet session so a reinstalled identity must be verified again |
| Encrypted files (XEP-0454 aesgcm) | Receiving and decryption yes. Files in explicitly encrypted chats are AES-GCM encrypted before upload; the key travels inside the OMEMO payload |
| OMEMO 2 / SCE, legacy OMEMO 0.3 | OMEMO 2 for one-to-one chats: X3DH, Double Ratchet, SCE envelopes, bundles, prekeys, reactions, edits and encrypted attachments. Group OMEMO sending and legacy 0.3 are not implemented. Explicit encryption refuses to downgrade silently |
| OpenPGP (XEP-0373/0374) | Not yet |
| Audio/video calls (Jingle, WebRTC, XEP-0353) | JMI propose/accept/reject/finish signalling exists, but audio/video media is not wired; the call entry point is disabled and incoming proposals show a notice |
| Scheduled send, Tenor GIFs, location and contact sharing | Yes: scheduled messages survive relaunch, Tenor search, vCard text and OpenStreetMap location links |
| Chat export, global search, link previews | Yes: global search from the chat list, HTML export from chat details, optional Open Graph previews |

## Deliberate differences

- The visual language is iOS: large titles, sheets with detents, SF Symbols, spring motion,
  swipe actions, context menus and a split view on iPad. It is not a pixel copy of Material 3.
- The chat list has a greeting and filter chips instead of Android's top app bar.
- The settings page is a native grouped form with the same schema, defaults and copy.
- iOS has no boot receiver, no always-on foreground service and no true screenshot block.
- The app does not include a WebView or a hidden browser. All rendering is native.

## Next steps for full parity

1. Add group OMEMO 2 sending (encrypt the payload key for every member device, including this
   account's other devices) and legacy OMEMO 0.3 only when the contact has no OMEMO 2 device.
2. Add WebRTC media: Jingle session negotiation, ICE/DTLS-SRTP, CallKit, audio routing and
   video preview.
3. Add OpenPGP with a Swift/Objective-C PGP implementation.
4. Keep expanding interoperability coverage beyond the current two-way `twomemo` harness and
   add guided fingerprint verification.
