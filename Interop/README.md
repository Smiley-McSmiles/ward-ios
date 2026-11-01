# OMEMO 2 interoperability harness

This harness exercises `WardCrypto` against [twomemo](https://pypi.org/project/twomemo/), an
independent Python implementation of OMEMO 2. It is not part of the app target.

It checks:

- twomemo initiates X3DH and Swift decrypts the key exchange;
- both directions on an established chain;
- DH ratchet steps in both directions;
- out-of-order delivery within a chain and across a ratchet boundary;
- the SCE payload produced by Swift is decryptable by twomemo.

## Run

```sh
python3 -m pip install twomemo
swift build --package-path Interop
python3 Interop/harness.py
```

On Linux, point `OMEMO_INTEROP_LD_LIBRARY_PATH` at the Swift runtime and libsodium directories
before running. On macOS the binary dependencies are bundled.

The GitHub Actions workflow `.github/workflows/omemo-interop.yml` runs the same steps.
