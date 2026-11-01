#!/usr/bin/env python3
"""Interop harness: drive twomemo (reference OMEMO 2 implementation) against WardCrypto."""
import asyncio
import base64
import json
import os
import subprocess
import sys
from pathlib import Path

import x3dh
from omemo.storage import Storage, Just, Nothing
from twomemo.twomemo import (
    Twomemo, BundleImpl, ContentImpl, EncryptedKeyMaterialImpl,
    KeyExchangeImpl, PlainKeyMaterialImpl,
)

HERE = Path(__file__).parent
BIN = Path(os.environ.get("OMEMO_INTEROP_BIN", HERE / ".build/debug/omemo-interop"))
ENV = dict(os.environ)
# Linux needs the Swift runtime and libsodium in the loader path. Apple platforms bundle both.
if sys.platform.startswith("linux"):
    LD = os.environ.get("OMEMO_INTEROP_LD_LIBRARY_PATH", "")
    if LD:
        ENV["LD_LIBRARY_PATH"] = LD
        ENV["LIBRARY_PATH"] = LD

SWIFT_JID = "swift@example.org"
TWOMEMO_JID = "twomemo@example.org"
SWIFT_DEVICE = 0xA11CE
TWOMEMO_DEVICE = 0xB0B


class MemStorage(Storage):
    def __init__(self):
        super().__init__()
        self.data = {}

    async def _load(self, key):
        return Just(self.data[key]) if key in self.data else Nothing()

    async def _store(self, key, value):
        self.data[key] = value

    async def _delete(self, key):
        self.data.pop(key, None)


def run(*args):
    if not BIN.exists():
        raise SystemExit(f"build the interop helper first: swift build --package-path {HERE}")
    result = subprocess.run([str(BIN), *map(str, args)], env=ENV,
                            capture_output=True, text=True)
    if result.returncode != 0:
        raise SystemExit(f"swift command {args} failed:\n{result.stderr}\n{result.stdout}")
    return result.stdout.strip()


def b64(value):
    return base64.b64encode(value).decode()


def bundle_to_json(bundle_impl, jid):
    bundle = bundle_impl.bundle
    return {
        "deviceId": bundle_impl.device_id,
        "identityKey": b64(bundle.identity_key),
        "signedPreKeyId": bundle_impl.signed_pre_key_id,
        "signedPreKey": b64(bundle.signed_pre_key),
        "signedPreKeySignature": b64(bundle.signed_pre_key_sig),
        "preKeys": [
            {"id": bundle_impl.pre_key_ids[pub], "publicKey": b64(pub)}
            for pub in bundle.pre_keys
        ],
    }


def bundle_from_json(path, jid):
    data = json.loads(Path(path).read_text())
    pre_keys = {base64.b64decode(k["publicKey"]): k["id"] for k in data["preKeys"]}
    xk = x3dh.Bundle(
        identity_key=base64.b64decode(data["identityKey"]),
        signed_pre_key=base64.b64decode(data["signedPreKey"]),
        signed_pre_key_sig=base64.b64decode(data["signedPreKeySignature"]),
        pre_keys=frozenset(pre_keys),
    )
    return BundleImpl(jid, data["deviceId"], xk, data["signedPreKeyId"], pre_keys)


async def twomemo_encrypt_active(backend, swift_bundle, text, out):
    content, key_material = await backend.encrypt_plaintext(text.encode())
    session, encrypted_key_material = await backend.build_session_active(
        SWIFT_JID, SWIFT_DEVICE, swift_bundle, key_material)
    await backend.store_session(session)
    key = session.key_exchange.serialize(encrypted_key_material.serialize())
    Path(out).write_text(json.dumps({
        "senderJID": TWOMEMO_JID,
        "senderDevice": TWOMEMO_DEVICE,
        "keys": [{"data": b64(key), "kex": True}],
        "payload": b64(content.ciphertext),
    }))
    return session


async def twomemo_encrypt(backend, session, text):
    content, key_material = await backend.encrypt_plaintext(text.encode())
    encrypted_key_material = await backend.encrypt_key_material(session, key_material)
    await backend.store_session(session)
    return {
        "senderJID": TWOMEMO_JID,
        "senderDevice": TWOMEMO_DEVICE,
        "keys": [{"data": b64(encrypted_key_material.serialize()), "kex": False}],
        "payload": b64(content.ciphertext),
    }


async def twomemo_decrypt(backend, incoming):
    key = incoming["keys"][0]
    raw = base64.b64decode(key["data"])
    if key["kex"]:
        kex, authenticated = KeyExchangeImpl.parse(raw)
        material = EncryptedKeyMaterialImpl.parse(authenticated, SWIFT_JID, SWIFT_DEVICE)
        session, plain_key_material = await backend.build_session_passive(
            SWIFT_JID, SWIFT_DEVICE, kex, material)
    else:
        session = await backend.load_session(SWIFT_JID, SWIFT_DEVICE)
        material = EncryptedKeyMaterialImpl.parse(raw, SWIFT_JID, SWIFT_DEVICE)
        plain_key_material = await backend.decrypt_key_material(session, material)
    plaintext = await backend.decrypt_plaintext(
        ContentImpl(base64.b64decode(incoming["payload"])), plain_key_material)
    await backend.store_session(session)
    return plaintext.decode()


def swift_export(store, out):
    run("export", store, out)


def swift_encrypt(store, remote_bundle, text, out):
    run("encrypt", store, remote_bundle, text, out)


def swift_decrypt(store, incoming, out):
    run("decrypt", store, incoming, out)
    return Path(out).read_text()


def check(name, actual, expected):
    if expected not in actual:
        raise SystemExit(f"FAIL {name}: expected {expected!r} in {actual!r}")
    print(f"  ok  {name}")


async def main():
    work = HERE / "work"
    work.mkdir(exist_ok=True)
    for path in work.iterdir():
        path.unlink()
    store = work / "swift-omemo.json"

    print("1. Swift exports an identity bundle")
    swift_export(store, work / "swift_bundle.json")

    storage = MemStorage()
    backend = Twomemo(storage)
    await backend.generate_pre_keys(20)
    twomemo_bundle = await backend.get_bundle(TWOMEMO_JID, TWOMEMO_DEVICE)
    (work / "twomemo_bundle.json").write_text(json.dumps(bundle_to_json(twomemo_bundle, TWOMEMO_JID)))

    print("2. twomemo initiates a session and sends a key-exchange message to Swift")
    session = await twomemo_encrypt_active(
        backend, bundle_from_json(work / "swift_bundle.json", SWIFT_JID),
        "hello from twomemo", work / "in1.json")
    check("twomemo -> Swift initial", swift_decrypt(store, work / "in1.json", work / "out1.txt"),
          "hello from twomemo")

    print("3. twomemo sends a second message on the same chain")
    (work / "in2.json").write_text(json.dumps(await twomemo_encrypt(backend, session, "second from twomemo")))
    check("twomemo -> Swift follow-up", swift_decrypt(store, work / "in2.json", work / "out2.txt"),
          "second from twomemo")

    print("4. Swift replies without a new key exchange")
    swift_encrypt(store, work / "twomemo_bundle.json", "hello from swift", work / "out3.json")
    reply = json.loads((work / "out3.json").read_text())
    if reply["keys"][0]["kex"]:
        raise SystemExit("FAIL: Swift repeated the key exchange after receiving a reply")
    check("Swift -> twomemo reply", await twomemo_decrypt(backend, reply), "hello from swift")

    print("5. Swift sends a second message on its new chain")
    swift_encrypt(store, work / "twomemo_bundle.json", "more from swift", work / "out4.json")
    check("Swift -> twomemo follow-up",
          await twomemo_decrypt(backend, json.loads((work / "out4.json").read_text())), "more from swift")

    print("6. twomemo replies after the DH ratchet")
    session = await backend.load_session(SWIFT_JID, SWIFT_DEVICE)
    (work / "in5.json").write_text(json.dumps(await twomemo_encrypt(backend, session, "third from twomemo")))
    check("twomemo -> Swift after ratchet", swift_decrypt(store, work / "in5.json", work / "out5.txt"),
          "third from twomemo")

    print("7. out-of-order delivery within a chain")
    session = await backend.load_session(SWIFT_JID, SWIFT_DEVICE)
    sixth = await twomemo_encrypt(backend, session, "fourth from twomemo")
    seventh = await twomemo_encrypt(backend, session, "fifth from twomemo")
    (work / "in7.json").write_text(json.dumps(seventh))
    (work / "in6.json").write_text(json.dumps(sixth))
    check("out-of-order newer first", swift_decrypt(store, work / "in7.json", work / "out7.txt"),
          "fifth from twomemo")
    check("out-of-order older second", swift_decrypt(store, work / "in6.json", work / "out6.txt"),
          "fourth from twomemo")

    print("8. out-of-order delivery across a DH ratchet boundary")
    session = await backend.load_session(SWIFT_JID, SWIFT_DEVICE)
    stale = await twomemo_encrypt(backend, session, "stale from twomemo")
    # Deliver nothing yet: force twomemo through a ratchet by sending it a Swift message.
    swift_encrypt(store, work / "twomemo_bundle.json", "ping from swift", work / "out8.json")
    check("Swift -> twomemo before boundary",
          await twomemo_decrypt(backend, json.loads((work / "out8.json").read_text())), "ping from swift")
    session = await backend.load_session(SWIFT_JID, SWIFT_DEVICE)
    fresh = await twomemo_encrypt(backend, session, "fresh chain from twomemo")
    (work / "in9.json").write_text(json.dumps(fresh))
    (work / "in8.json").write_text(json.dumps(stale))
    check("new chain delivered first", swift_decrypt(store, work / "in9.json", work / "out9.txt"),
          "fresh chain from twomemo")
    check("stale key from previous chain", swift_decrypt(store, work / "in8.json", work / "out8.txt"),
          "stale from twomemo")

    print("\nAll twomemo <-> WardCrypto interop checks passed.")


if __name__ == "__main__":
    asyncio.run(main())
