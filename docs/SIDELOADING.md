# Testing Ward on an iPhone without the App Store

“Flashing” an iPhone is not like flashing an Android phone. iOS only runs apps signed by Apple
for a provisioning profile that includes the device. You do not need to publish to the App
Store, but you do need either a free Apple ID or a paid Apple Developer account.

## First: check the iPhone's iOS version

This project targets **iOS 17.0 or newer**. An “old iPhone” will only work if it is an
**iPhone XS, XS Max, XR or newer** (these support iOS 17/18). iPhone 8, 8 Plus and X do not.
If your friend's phone is older, the app can still be tested in the Simulator, or the deployment
target can be lowered after checking every API used.

## Option 1 — Xcode with a free Apple ID (7-day builds)

Best for a quick test with no money. Requires a Mac (or cloud Mac) and Xcode.

1. In Xcode → **Settings → Accounts**, add the Apple ID and create a **Personal Team**.
2. Open `Ward.xcodeproj` → target **Ward** → **Signing & Capabilities**.
3. Select the Personal Team and change the bundle identifier to something unique, for example
   `org.ward.ios.yourname`.
4. Connect the iPhone by USB, unlock it, and trust the computer.
5. Select the phone as the run destination and press **Run**.
6. On the phone, enable **Settings → General → VPN & Device Management → Developer App** and
   trust your Apple ID if prompted.

Limitations: the app expires after **7 days**, you can sign at most 3 apps and 10 devices per
week, and you must reconnect to Xcode to re-sign. This is fine for a trial, not for ongoing use.

## Option 2 — Xcode with a paid Apple Developer account

The same steps as above, but select your paid team. The provisioning profile lasts a year instead
of seven days, and you can install on up to 100 registered devices per device type per year.
You still do not need to submit to the App Store.

## Option 3 — TestFlight (recommended)

TestFlight is Apple's beta distribution service. The app is uploaded to App Store Connect, but it
is not published on the App Store.

1. Enrol in the Apple Developer Program (US$99/year).
2. Upload a build with Xcode, `fastlane beta`, or the `Release` GitHub Actions workflow.
3. In App Store Connect → TestFlight, add your friend as an **internal tester** (up to 100 people
   on your team) or create an **external testing group** (up to 10,000; the first external build
   needs a short beta review).
4. Your friend installs the **TestFlight** app from the App Store, accepts the invite, and taps
   Install. Builds expire after 90 days.

This is the least fiddly path for an old-but-supported iPhone and gives you crash feedback.

## Option 4 — Ad Hoc IPA (no TestFlight, no App Store)

Requires the paid Apple Developer Program.

1. Register the iPhone's UDID in the developer portal (Xcode → Devices can copy it).
2. Create an **Ad Hoc** provisioning profile that includes that device.
3. Archive in Xcode and export with the **Ad Hoc** method (or use `xcodebuild -exportArchive`
   with an Ad Hoc `ExportOptions.plist`).
4. Install the `.ipa` by dragging it onto the phone in **Apple Configurator**, using Xcode's
   **Devices and Simulators** window, or an OTA service such as Diawi or InstallOnAir.

Ad Hoc builds are not reviewed by Apple and do not appear in the App Store. The profile expires
after a year.

## Option 5 — AltStore / Sideloadly (not recommended for this project)

These tools re-sign an IPA with a free Apple ID and install it over USB or Wi-Fi. They still hit
the same 7-day expiry and 3-app limit. They are useful when you have no Mac, but they are brittle
for a 37-file SwiftUI app and not a good release path. They do not bypass Apple's signing rules.

## What not to do

- There is no supported way to install an unsigned iOS app on a non-jailbroken phone.
- Do not use enterprise certificates for personal distribution; Apple revokes them.
- TrollStore and similar tools depend on specific iOS vulnerabilities and are not a dependable
  test path.
- Do not put your Apple ID password or App Store Connect API key in the repository, screenshots
  or chat messages.

## Which should you choose?

- **Just want to show a friend:** TestFlight, if you have the paid developer account.
- **No paid account yet:** free Apple ID + Xcode, accepting the 7-day expiry.
- **No Mac at all:** a cloud Mac for one day (see `BUILD-SERVICES.md`) plus TestFlight or a
  free-ID Xcode install.
