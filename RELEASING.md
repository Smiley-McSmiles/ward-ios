# Releasing Ward for iOS

This is the end-to-end checklist for TestFlight and the App Store. The project already contains
the build configuration, privacy manifest, metadata, fastlane lanes, a signed release workflow
and a simulator screenshot generator. The remaining pieces require an Apple Developer account
and App Store Connect access.

## 1. Accounts and identifiers

1. Join the **Apple Developer Program** (US$99/year). A free Apple ID cannot upload to TestFlight
   or the App Store.
2. In [Certificates, Identifiers & Profiles](https://developer.apple.com/account), create an
   explicit App ID:
   - Bundle ID: `org.ward.ios`
   - Capabilities: none are required for the current feature set. Do not enable Push
     Notifications until a server-side push implementation exists.
3. In [App Store Connect](https://appstoreconnect.apple.com), create a new app:
   - Platform: iOS
   - Name: `Ward — XMPP Messenger`
   - Primary language: English (U.S.)
   - Bundle ID: `org.ward.ios`
   - SKU: `ward-ios`
   - User access: full access for the release team
4. Complete **Agreements, Tax, and Banking** before the first upload.
5. Set the app's **Privacy Policy URL** to
   `https://smiley-mcsmiles.github.io/ward-ios/privacy.html`. The Pages workflow publishes
   `docs/`; enable GitHub Pages → Source: GitHub Actions once.
6. Set the **Support URL** to `https://github.com/Smiley-McSmiles/ward-ios/issues`.

## 2. Signing

### Option A — Xcode automatic signing (simplest)

1. Open `Ward.xcodeproj` in Xcode 16+ on a Mac (or a cloud Mac).
2. Select the **Ward** target → **Signing & Capabilities**.
3. Choose your team and let Xcode create the App Store distribution certificate and profile.
4. Archive with **Product → Archive** and use **Distribute App → App Store Connect → Upload**.

### Option B — CI with App Store Connect API key

Create an API key in App Store Connect → **Users and Access → Integrations → App Store Connect
API**. Use the **App Manager** or **Admin** role and download the `.p8` file once.

Add these GitHub repository secrets:

| Secret | Value |
| --- | --- |
| `DEVELOPMENT_TEAM` | Your 10-character Apple team ID |
| `APPSTORE_KEY_ID` | The API key ID |
| `APPSTORE_ISSUER_ID` | The API issuer ID |
| `APPSTORE_API_PRIVATE_KEY` | The entire `.p8` file, base64-encoded |

Then run **Actions → Release → Run workflow**. The workflow:

- archives with `DEVELOPMENT_TEAM` and a UTC timestamp build number
- exports an App Store IPA using `ExportOptions.plist`
- validates it with `altool`
- uploads it to App Store Connect
- keeps the IPA and `.xcarchive` as artifacts

The first run may need automatic signing to create a distribution certificate in the runner
keychain. If your team requires manual certificates, use fastlane match or import a `.p12` and
profile in a private step. Do not commit certificates or profiles.

### Option C — fastlane

```sh
bundle install
export DEVELOPMENT_TEAM=XXXXXXXXXX
export APPSTORE_KEY_ID=XXXXXXXXXX
export APPSTORE_ISSUER_ID=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
export APPSTORE_KEY_PATH="$HOME/.appstoreconnect/private_keys/AuthKey_XXXXXXXXXX.p8"
bundle exec fastlane beta       # TestFlight
bundle exec fastlane release    # upload binary + metadata, do not auto-submit
```

`fastlane beta` is the quickest way to get a build to internal testers. `fastlane release`
uploads the binary and metadata; final submission is still a deliberate action in App Store
Connect.

## 3. Build number and version

- Marketing version: `MARKETING_VERSION` = `1.0.6` in the Xcode project.
- Build number: `CURRENT_PROJECT_VERSION`, overridden by the release workflow or `BUILD_NUMBER`.
- Every upload to App Store Connect must have a unique, increasing build number for that
  marketing version.
- Update `fastlane/metadata/en-US/release_notes.txt` before a release.

## 4. App Store Connect metadata

The files in `fastlane/metadata/en-US/` are ready to sync:

- name, subtitle, promotional text, description, keywords
- support URL, marketing URL, privacy URL
- copyright and release notes
- review notes and contact fields

Before submission:

1. Replace `fastlane/metadata/review_information/demo_user.txt` and
   `demo_password.txt` with a working test account on a server you control. Apps that require
   an account need a reviewer account.
2. Replace the placeholder phone number and support email with real details.
3. Review the description for claims that are not shipped. OMEMO/OpenPGP and call media are
   explicitly marked as unfinished in `PARITY.md`; do not claim end-to-end encryption in the
   listing until those land.

Upload metadata with:

```sh
bundle exec fastlane release
```

or with `fastlane deliver --skip_binary_upload` after setting the API key.

## 5. Screenshots

`scripts/screenshots.sh` launches the app with demo data and captures:

- `6.9-inch-chats.png`
- `6.9-inch-conversation.png`
- `6.9-inch-settings.png`
- `13-inch-ipad-chats.png`
- `13-inch-ipad-conversation.png`
- `13-inch-ipad-settings.png`

The `iOS` GitHub Actions workflow runs the script after every successful build and uploads the
`Ward-app-store-screenshots` artifact. Download the PNGs and upload them in App Store Connect
under the 6.9-inch iPhone and 13-inch iPad slots. The demo data never connects to a server.

## 6. App privacy and age rating

- **Privacy manifest:** `WardiOS/Resources/PrivacyInfo.xcprivacy` declares UserDefaults and file
  timestamp access, no tracking, and no collected data.
- **App Privacy questionnaire:** Ward does not collect data on a developer-operated server. The
  XMPP provider processes data independently; select “Data Not Collected” for Ward itself and
  explain the provider relationship in the privacy policy.
- **Tracking:** No.
- **Age rating:** Ward contains user-generated content and public group chats. A 12+/13+ rating
  is appropriate. Complete the current questionnaire in App Store Connect.
- **Export compliance:** The app uses standard TLS and AES-GCM. `ITSAppUsesNonExemptEncryption`
  is currently `false`. If you add OMEMO/OpenPGP or other non-exempt cryptography, review the
  export classification with counsel and update this key and the App Store Connect answers.

## 7. User-generated content requirements

App Store guideline 1.2 applies to group chats and messages from strangers. Ward already has:

- blocking and contact-request controls
- message requests instead of unsolicited chat
- server-side moderation tools in the admin console
- a **Report abuse** action in chat details that opens a prefilled support issue

The review notes explain that moderation is performed by the XMPP server operator and that users
can block and report. Add published contact details before submission.

## 8. TestFlight

1. Upload a build (Xcode, Release workflow or `fastlane beta`).
2. In App Store Connect → TestFlight, answer export compliance and provide test information.
3. **Internal testers** (up to 100 App Store Connect users) can install immediately after
   processing; no beta review.
4. **External testers** (up to 10,000) require a beta app review. Add a test account and notes.
5. Distribute the public link if you want friends to test without adding them individually.

TestFlight is the recommended way to test on a friend's iPhone without shipping to the App
Store.

## 9. Submission

1. Select the build in the version page.
2. Upload screenshots, metadata and review information.
3. Answer privacy, age rating, content rights and encryption questions.
4. Add review notes and a demo account.
5. Submit for review; after approval, release manually or enable phased release.
6. Keep the previous build available for rollback.

## 10. Post-release

- Tag the released commit: `git tag v1.0.6 && git push --tags`.
- The `Release` workflow runs on tags, but it only uploads to App Store Connect; submission is
  still manual.
- Update `CHANGELOG.md` and `fastlane/metadata/en-US/release_notes.txt`.
- Monitor crash reports and XMPP interoperability reports.

## Common problems

| Problem | Fix |
| --- | --- |
| `No profiles for org.ward.ios were found` | Set `DEVELOPMENT_TEAM`, run once in Xcode with automatic signing, or use fastlane match |
| Upload rejected for a duplicate build | Increment `CURRENT_PROJECT_VERSION` |
| Missing privacy manifest | Ensure `PrivacyInfo.xcprivacy` is in Copy Bundle Resources |
| App Review asks for a demo account | Fill `fastlane/metadata/review_information/demo_user.txt` and `demo_password.txt` |
| Screenshot upload wrong size | Use the 6.9-inch and 13-inch artifacts from the iOS workflow |
| App Store says “Invalid binary” | Check the archive log; verify `ExportOptions.plist` and the App Store distribution profile |
