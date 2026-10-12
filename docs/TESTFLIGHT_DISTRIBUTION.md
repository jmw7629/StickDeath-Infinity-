# Getting the native app onto a phone

Status: owner-gated. Nothing here is automated until the owner provides the
Apple credentials described below. This repository holds no signing identity,
provisioning profile, API key or password, and never will (AGENTS.md).

## What exists today

| Path | What it produces | Who can install it |
| --- | --- | --- |
| CI job `native-ios-shards` → artifact `native-simulator-app-<sha>-<attempt>` | An unsigned Debug build for the iOS Simulator | Only a Mac with Xcode, via `simctl` (docs/NATIVE_SIMULATOR_REVIEW.md "Owner install route"). It cannot run on a physical iPhone. |
| CI job `android-debug-build` → artifact `sdi-android-debug-<sha>` (`android-build-evidence/`) | The Android debug APK's hashes and build log; the APK itself is at `android/app/build/outputs/apk/debug/app-debug.apk` on the runner | An Android phone with "Install unknown apps" enabled, once the APK is added to the artifact (see below). Not the iOS app. |
| `docs/ci-candidates/ios-testflight.yml` | A TestFlight upload pipeline, inactive until moved into `.github/workflows/` | iPhones invited through TestFlight. |

A physical iPhone can only run a build signed with an Apple Developer
Program identity. There is no way to "send" the current CI build to a phone
without that identity.

## iPhone route (TestFlight)

One-time owner setup, all outside this repository:

1. Apple Developer Program membership for the team that owns bundle id
   `com.willisnmb.stickdeathinfinity`.
2. App Store Connect → Apps → create the app record for that bundle id
   (name "StickDeath Infinity", primary language, SKU).
3. Certificates, Identifiers & Profiles:
   - an **Apple Distribution** certificate, exported as a `.p12` with a password;
   - an **App Store** provisioning profile for the bundle id using that certificate.
4. App Store Connect → Users and Access → Integrations → App Store Connect
   API → Team key with the **App Manager** role. Download the `.p8` once;
   note the Key ID and Issuer ID.
5. GitHub → repository Settings → Secrets and variables → Actions, add:

| Secret | Value |
| --- | --- |
| `APPLE_DISTRIBUTION_CERT_P12_BASE64` | `base64 < distribution.p12` (single line) |
| `APPLE_DISTRIBUTION_CERT_PASSWORD` | the `.p12` export password |
| `APPLE_APPSTORE_PROFILE_BASE64` | `base64 < StickDeathInfinity_AppStore.mobileprovision` |
| `APPLE_TEAM_ID` | the 10-character team id |
| `APP_STORE_CONNECT_KEY_ID` | the API key id |
| `APP_STORE_CONNECT_ISSUER_ID` | the issuer id |
| `APP_STORE_CONNECT_KEY_P8_BASE64` | `base64 < AuthKey_XXXXXXXXXX.p8` |

6. Move `docs/ci-candidates/ios-testflight.yml` to
   `.github/workflows/ios-testflight.yml` in a reviewed commit (it is kept out
   of `.github/workflows` deliberately so an upload can never start by
   accident). Trigger it from the Actions tab on the branch to test.
7. After the upload processes (usually 5–30 minutes), App Store Connect →
   TestFlight → add the owner's Apple ID as an internal tester, or create an
   external group; install the TestFlight app on the iPhone and accept the
   invitation. Each later run uploads a new build number (`github.run_number`)
   and TestFlight offers the update.

What the pipeline does: checks that all seven secrets exist, imports the
certificate into a temporary keychain, installs the profile, stamps
`CFBundleVersion` with the run number, archives the Release configuration with
manual signing, exports an App Store package, uploads it with the API key,
deletes the keychain, key and package, and keeps only a receipt (commit, build
number, logs with keys redacted, IPA hash) as an artifact. It never prints a
secret and never touches the App Store release state.

Before the first external TestFlight group: export compliance answer
(`ITSAppUsesNonExemptEncryption`), the privacy manifest
(`StickDeathInfinity/PrivacyInfo.xcprivacy`), App Privacy answers and the
review notes in docs/RELEASE_CHECKLIST.md are the owner's.

## Android phone route (debug APK)

`android-build-evidence/` currently records the APK's SHA-256 but does not
contain the APK. To hand the APK to an Android phone, add
`android/app/build/outputs/apk/debug/app-debug.apk` to the artifact paths in
`.github/workflows/android-build.yml`, download the artifact from the run
page on the phone, enable installation from unknown sources for the browser
and open the file. Debug APKs are signed with the shared Android debug key
and are for the owner's own device testing only, never for distribution.

## Known limits

- No build has been installed on any physical device by this project yet;
  every native verification remains CI-only and deferred.
- Push notifications, Sign in with Apple and StoreKit sandbox behaviour on a
  real device depend on the owner's App ID capabilities and App Store Connect
  configuration (docs/BILLING_CONTRACT.md, docs/AUTH_PROVIDER_CONFIGURATION.md).
