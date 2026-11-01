# Third-party notices

Ward for iOS is MIT-licensed. The app and its OMEMO implementation do not link libsignal or any
GPL cryptography library.

## WardCrypto

`Packages/WardCrypto` is part of this repository and is MIT-licensed. It implements the OMEMO 2
key agreement, Double Ratchet, protobuf wire messages and SCE envelopes. The minimal protobuf
encoder/decoder is local code, not a bundled protobuf runtime.

## Swift Sodium and libsodium

- [swift-sodium](https://github.com/jedisct1/swift-sodium), ISC License.
- [libsodium](https://libsodium.org), ISC License.

Used for Ed25519 signatures, X25519 key agreement, secure randomness, HKDF-SHA-256, HMAC-SHA-256
and SHA-256. On Apple platforms swift-sodium ships a libsodium XCFramework.

## CryptoSwift

- [CryptoSwift](https://github.com/krzyzanowskim/CryptoSwift), zlib License.

Used for AES-256-CBC with PKCS#7 padding, as required by the OMEMO 2 message format.

## Apple frameworks

SwiftUI, Foundation, Security, CryptoKit, AVFoundation and the other Apple SDK frameworks are
used under the terms of the Apple Developer Program and the iOS SDK agreements. CryptoKit is used
for AES-GCM attachment encryption, not for the OMEMO ratchet.

## Android notices

Ward for Android is a separate repository and links its own dependencies, including
GPL-licensed libsignal-derived code. Those components are not part of this iOS app or its
distributed binary.
