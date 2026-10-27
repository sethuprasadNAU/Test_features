# Every capability the operating system has to grant

**Task 11.40, 2026-08-29.** One row per capability the OS must hand this app
before it works, enumerated **from the platform manifests and entitlement
files themselves** rather than from anybody's memory of what the app does.
Each row states whether the capability needs a test on real hardware, and — the
part that matters — **what covers it today.**

## Why this file exists

**Both hardware tests in this repository exist because somebody hit the bug by
hand first.**

- `integration_test/ats_transport_security_test.dart` (task 10.50) was written
  after a review noticed the app's own URL check might be the only thing
  refusing cleartext.
- `integration_test/session_store_keychain_test.dart` (task 11.38) was written
  after **sign-in turned out never to have worked on macOS in any build.** The
  keychain refused every write with error `-34018`, and it had been that way
  since Phase 5 added desktop support in June. Nothing could have caught it:
  every test that touches sign-in substitutes an in-memory store, because the
  real one cannot work under `flutter test`. **The workaround for the
  untestability was also what guaranteed the bug stayed invisible.**

That is a *class*, not two incidents. `flutter test` ships no `Info.plist`, no
entitlements, no code signature and no platform channels, so **everything the
operating system enforces is invisible to it** — and the substitute the tests
use is exactly the thing that hides the failure. Nobody should have to
reproduce a `-34018` to discover the next one, so this file enumerates the
whole surface up front.

## How to keep this file honest

`test/platform/capability_matrix_test.dart` reads this file and fails if a
capability is declared in a platform file that has no row here. It cannot check
the *verdicts* — those are judgement — but it can stop the enumeration going
quietly stale, which is how the last one would have failed.

That test only ever sees the three hand-written Android manifests, so it is
blind to everything Gradle merges in from a plugin — the whole second pass
below. **Task 11.76** closed that with
`scripts/verify_merged_manifest_capabilities.sh`, run in `build-check.yml`'s
Android job right after `flutter build apk --debug` produces the merged
manifest, on every push. It cannot run under `flutter test` because it needs
a build artifact that plain `flutter test` never produces.

---

## The matrix

**"Hardware test?"** means: can this capability fail on a real device in a way
that no `flutter test` run could ever see?

### Confirmed live, and covered

| Capability | Declared in | Used by | Hardware test? | Covered by |
| --- | --- | --- | --- | --- |
| **Keychain / secure storage** (the sign-in session) | `macos/Runner/DebugProfile-Signed.entitlements`, `Release-Signed.entitlements` → `keychain-access-groups`. iOS needs none (no entitlements file exists). Android needs none (Keystore). | `lib/data/auth/session_store.dart` | **Yes — and it already caught a total failure.** | `integration_test/session_store_keychain_test.dart` (behavior, needs signing) + `test/platform/macos_keychain_entitlement_test.dart` (configuration, runs everywhere) |
| **Cleartext to a LAN server** (App Transport Security / Android network security config) | iOS `Info.plist` `NSAppTransportSecurity` → `NSAllowsLocalNetworking`; macOS `Info.plist` same; Android `src/debug/res/xml/network_security_config.xml`, referenced only from `src/debug/AndroidManifest.xml` | `lib/core/providers/server_http_client_provider.dart` | **Yes.** The app's own URL check would refuse a cleartext public host first, so only a real device can show whether *ATS* refuses it. | `integration_test/ats_transport_security_test.dart` (behavior) + `test/security/platform_cleartext_test.dart` (configuration) |
| **The macOS sandbox itself** | `com.apple.security.app-sandbox` — true in all four macOS entitlement files | nothing in `lib/`; it is the container everything else runs inside | **No.** Its absence would not fail — it would *silently widen* what the app can reach, which is why it is worth a row. Every other macOS entitlement here only means something because this one is true. | `test/platform/capability_matrix_test.dart` fails if it is removed |
| **Local network** (reaching a laptop server on the Wi-Fi) | iOS `Info.plist` `NSLocalNetworkUsageDescription`; macOS `Info.plist` same. Android needs no equivalent. | the same client seam | **Yes, and it has never been checked.** On iOS 14+ the first connection to a LAN address triggers a system prompt; refusing it makes the server unreachable with no error the app can distinguish from the server being down. Task 11.51 asked specifically whether a `.local` hostname works from the app on iOS and nobody knows. | Nothing. Release checklist, item H1. |
| **Outbound network** | Android `INTERNET` (main, debug, profile); macOS `com.apple.security.network.client` (all four entitlement files); iOS needs none | the single client seam, `lib/core/providers/server_http_client_provider.dart` | **No.** A missing declaration fails immediately, loudly, and on the first request — there is no silent-substitute path to hide it. | the e2e suite, and every manual run |

### Confirmed live, and NOT covered — found by this sweep

| Capability | Declared in | Used by | Hardware test? | State |
| --- | --- | --- | --- | --- |
| **Location / GPS** | iOS `Info.plist` `NSLocationWhenInUseUsageDescription`; macOS `com.apple.security.personal-information.location` (all four) + `Info.plist`; **Android: `ACCESS_FINE_LOCATION` / `ACCESS_COARSE_LOCATION` added by task 11.40 — they were missing entirely** | `lib/core/providers/gps_provider.dart` | **Yes.** Exactly the `-34018` shape: on Android an undeclared runtime permission is denied with no dialog, so `Geolocator.requestPermission()` returns `denied` and the app shows its own tidy "location was denied" message. **A person would read that as having said no.** | Declaration guarded by `test/platform/location_permission_declared_test.dart`. **The behavior has never been run on Android.** Release checklist, item H2. |
| **User-selected files** — CSV export, CSV import, backup save, backup restore | Android: none needed (SAF). iOS: none needed. **macOS: `com.apple.security.files.user-selected.read-write` added by task 11.40 — it was missing from all four entitlement files while `com.apple.security.app-sandbox` was true in all four** | `lib/features/more/screens/data_export_screen.dart` (4 sites), `tag_database_screen.dart` (2 sites) | **Yes.** A sandboxed macOS app gets a file panel either way; what it does *not* get without the entitlement is permission to read or write the file the person picked. | Declaration guarded by `test/platform/file_access_entitlement_test.dart`. **The behavior has never been run on macOS.** Release checklist, item H3. |
| **The linked cloud-backup folder** — a security-scoped bookmark (iOS) / persistable tree URI (Android) | Custom method channel `edu.nau.tritrack/cloud_backup`. iOS: `UIDocumentPickerViewController` + `bookmarkData`, needs no entitlement. Android: `ACTION_OPEN_DOCUMENT_TREE` + `takePersistableUriPermission`, needs no manifest permission. **macOS: not implemented at all** — `macos/Runner/AppDelegate.swift` registers no channel. | `lib/core/platform/cloud_folder_channel.dart` → `lib/core/services/cloud_backup_service.dart` | **Yes, and it is the least-tested thing in this table.** A bookmark that resolves today and goes stale after a reboot, an OS upgrade, or the folder being moved is invisible to every offline test — and the failure surfaces as backups silently stopping. | Nothing. Release checklist, item H4. |
| **Compass / magnetometer / accelerometer** | Nothing to declare on any platform — these sensors need no permission. | `lib/core/providers/compass_provider.dart`, `lib/compass/compass_controller.dart` | **Yes, but for a different reason:** not permission, *presence*. A Mac has no magnetometer, and task 5.2 built a capability-based "compass unavailable" state for exactly that. Whether the real sensor stream behaves as that state expects has only ever been checked by hand. | `test/compass/` covers the logic against a fake stream. Release checklist, item H5. |
| **Device lock / biometric presence check** (task 10.79, Security Model §4.8 control 2 — never actual authentication) | iOS `Info.plist` `NSFaceIDUsageDescription` (required for `LAContext` to be touched at all, even for the passive `canEvaluatePolicy` check `isDeviceSupported()` makes — no biometric prompt is ever shown). Android: **`android.permission.USE_BIOMETRIC` and `android.permission.USE_FINGERPRINT`** — two, not one; the second arrives from `androidx.biometric:biometric:1.1.0` behind `local_auth_android` and was missing from this sentence until task 11.220 read a real merged manifest. See the `local_auth_android` row in the second-pass table below for both permissions' measured attributes and why one plugin brings two. **Neither is present in any hand-written manifest, so `capability_matrix_test.dart`'s Android loop cannot see either of them** — `scripts/verify_merged_manifest_capabilities.sh`, which reads the merged manifest, is what does. macOS needs nothing (no entitlement gates `LAContext` in the sandbox). | `lib/core/providers/device_lock_provider.dart` → `DeviceLockWarningTile` on the More screen | **Yes.** `isDeviceSupported()` is meant to report whether a passcode/PIN/pattern **or** biometric-with-fallback is configured; whether it actually reflects that state (rather than, say, biometric hardware presence alone) on a real device with no lock set has only been checked against the plugin's own documented contract, never a device. | Widget-level behavior covered by `test/widgets/device_lock_warning_notice_test.dart` (mocked `LocalAuthentication`, all three branches watched failing before the fix). **The platform check itself has never been run on real hardware.** Release checklist — new item, see Discovered Scope under task 10.79. |

### Declared but not used

| Capability | Declared in | State |
| --- | --- | --- |
| **Incoming network connections** | `macos/Runner/DebugProfile.entitlements` + `DebugProfile-Signed.entitlements` → `com.apple.security.network.server`. **Not in either Release file.** | Correct as it stands: nothing in `lib/` listens. This is Flutter's own VM service, which only a debug or profile build runs. Leave it. |
| **JIT** | `com.apple.security.cs.allow-jit`, DebugProfile pair only | The Dart VM in debug/profile. Correctly absent from Release. Leave it. |
| **`permission_handler`** | `pubspec.yaml` only | **A dead dependency with zero references in `lib/`, `packages/` or `test/`.** At the locked version its own library manifest declares no permissions and `ios/Podfile` sets no `PERMISSION_*` macros, so today it adds nothing. It is worth removing rather than watching: the moment somebody adds those macros it contributes a large permission surface that nobody chose. Discovered Scope. |

### Explicitly declined — checked, and the answer is no

Recorded because *"we looked at it and decided no"* and *"we never looked"* are
indistinguishable a year later.

| Capability | Why not, and where the refusal is written down |
| --- | --- |
| **Deep links / custom URL schemes** | **Disabled on all three platforms on purpose** (task 10.77, finding K-3): `FlutterDeepLinkingEnabled=false` in both plists, `flutter_deeplinking_enabled=false` in `AndroidManifest.xml`, no `CFBundleURLTypes`, no `VIEW`/`BROWSABLE` intent filter. A sign-in link is pasted into the app by hand, which is the design. |
| **Background modes / background fetch** | No `UIBackgroundModes`, no `WorkManager`, no foreground service. Task 11.59's automatic sync runs **on foreground only**, which is why. Anything that syncs while the app is closed is a new capability and a new row here. |
| **Notifications** (local or push) | Nothing declared, no dependency, no `POST_NOTIFICATIONS`. Nothing in the app has ever needed to tell you something while you were not looking. **This is the one most likely to change:** task 11.60's "the server must tell a removed member" is the kind of thing that reaches for a notification. |
| **Camera, microphone, photo library, contacts, calendar, Bluetooth, NFC, external storage** | None declared, no dependency, no call site. Nothing in the app wants them. |
| **Web, Windows, Linux** | Those platform directories do not exist. The app builds for iOS, Android and macOS only. |
| **Automatic device backup (Android Auto Backup)** | **Disabled on purpose** (task 10.79, finding L-10): `android:allowBackup="false"` in `android/app/src/main/AndroidManifest.xml`. With no `allowBackup` attribute this defaulted to `true`, so the whole app sandbox — `tri_track.db` and every coordinate in it — was copied to the user's Google account on Android's own schedule, bypassing the OS full-disk-encryption assumption Security Model §4.8 rests its "no SQLCipher" decision on. **iOS and macOS have the equivalent exposure through the device's own iCloud/Finder backup and it is unaddressed** — filed as Discovered Scope under Phase 10 rather than fixed here; see `DEVELOPMENT_PLAN.md`. |

---

---

## Android, second pass: what the **merged** manifest grants (task 11.66, 2026-08-31)

**Everything above this line was derived from the manifests and entitlement
files a person wrote.** On Android that is only half the answer. Gradle merges
every plugin's own library manifest into the app's before packaging, so the
manifest Android actually enforces contains components nobody in this
repository typed — and `test/platform/capability_matrix_test.dart` reads only
the three hand-written files, so none of the rows below were visible to it.

**Now checked on every push (task 11.76)** by
`scripts/verify_merged_manifest_capabilities.sh`, which reads exactly the
merged manifest this section was derived from by hand. **Task 11.121
extended it again:** the original check only covered `<uses-permission>` and
`<uses-feature>`, the two shapes 11.66's worked example happened to use, so a
plugin adding one of the other four shapes recorded below by hand — an
exported component, or a `<queries>` entry — merged into the built APK with
nothing in CI saying so. The fix does not enumerate element names; it checks
`android:exported="true"` on every element that can carry it, because that
one attribute is what makes a component reachable from outside this app —
that is the actual attack surface, and a `<uses-library>` or a non-exported
service is not. `<queries>` is checked separately: it is not
reachable-from-outside surface, but it is a disclosure of what other apps
this one can see, and it is worth its own row for that reason. See the
"Exported components" and "The `<queries>` decision" notes below the table.

**Derive it from the built artifact, not from the source:**

```bash
flutter build apk --debug
$(ls ~/Library/Android/sdk/build-tools/*/aapt2 | tail -1) dump badging \
  build/app/outputs/flutter-apk/app-debug.apk | grep -E "uses-permission|uses-feature"
cat build/app/intermediates/merged_manifest/debug/processDebugMainManifest/AndroidManifest.xml
```

Measured 2026-08-31 on Flutter 3.44.6 — `minSdk 24`, `targetSdk 36`,
`compileSdk 36`, ABIs `arm64-v8a armeabi-v7a x86_64`.

| Added at merge by | What it adds | Verdict |
| --- | --- | --- |
| **aapt, from the two location permissions** | `uses-feature android.hardware.location`, **required** | Correct for this app — it cannot work without a position — but it was implied, not chosen. On Google Play it filters the app off any device with no location hardware. Recorded here so the next person knows it is a consequence rather than a decision. |
| **AndroidX** | permission + `uses-permission` `edu.nau.tritrack.DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION`, `protectionLevel="signature"` | Standard AndroidX plumbing for non-exported dynamic receivers. Signature-level, so only this app can hold it. Nothing to do. |
| **file_picker** | a second `<queries>` entry: `GET_CONTENT` with `*/*` | Package visibility, so the export and import pickers can see document providers. Required for the four `FilePicker` paths to work at all. Verified working on a device 2026-08-31. |
| **geolocator_android** | `<service com.baseflow.geolocator.GeolocatorLocationService android:foregroundServiceType="location" android:exported="false">` | **Declared and never started.** Nothing in `lib/` requests background location. The app declares neither `FOREGROUND_SERVICE` nor `FOREGROUND_SERVICE_LOCATION`, so if anything ever did start it, Android 14+ would refuse — which is the safe direction. **Leave it, but know it is there**: adding background location later is not a code change alone, it is two more permissions and a row here. |
| **geolocator_android** | `<activity com.google.android.gms.common.api.GoogleApiActivity>` and `<meta-data com.google.android.gms.version>` | Google Play services, for the fused location provider. `gps_provider.dart` passes plain `LocationSettings` with no `AndroidSettings`, so it takes the fused path when Play services are present and falls back to `LocationManager` when they are not. **The fallback has never been run** — a Play-services-free device (a de-Googled phone, some tablets) is untested. |
| **androidx.profileinstaller** | an exported `ProfileInstallReceiver` guarded by `android.permission.DUMP` | Baseline-profile installation. Exported but permission-guarded to a signature/privileged permission. Standard; nothing to do. |
| **androidx.window** | optional `uses-library` for `androidx.window.extensions` / `sidecar` | Foldable/window metadata, `required="false"`. Nothing to do. |
| **url_launcher_android** (added by task 11.133, 2026-09-02) | `<queries>` entries for `ACTION_VIEW` with the `https` scheme, and (depending on the plugin version's own library manifest) `tel`, `mailto` and `sms` | **Package visibility, added so the map credit's "ⓘ" and App Info can open a provider's license page in the browser.** Under Android 11+ an app cannot see, and therefore cannot start, an activity for a scheme it has not declared here — the call returns false rather than failing loudly, which is why `AttributionLink` tells the person the address instead of doing nothing. **Nothing is exported by this plugin** and no permission is added; the disclosure is that the app can detect whether a browser, dialer or mail client is installed, which is the same category as the `GET_CONTENT` entry above. **Not optional:** *"there needs to be a way to access more information, including origin and license of the data"* is a condition of the OpenStreetMap tile license. **Not yet verified against a built APK** — the rows in this table were derived from a real merged manifest and this one was not; `scripts/verify_merged_manifest_capabilities.sh` will confirm or correct it on the next Android build, and the exact set of schemes should be read off that rather than trusted from here. |
| **package_info_plus** (added by task 11.133, 2026-09-02) | Nothing. | Recorded as a row precisely **because it adds nothing** — it reads `PackageManager`'s `versionName`/`versionCode` through the existing application context, declares no permission, no component and no `<queries>` entry. A plugin was added and the honest answer to "what did the OS have to grant" is "nothing," which is worth writing down once rather than re-deriving. Same caveat as above: **derived from the plugin's documented behavior, not from a built APK.** |
| **Flutter engine, `ProcessTextPlugin`** | a `<queries>` entry: `PROCESS_TEXT` for `text/plain` | Hand-written (`android/app/src/main/AndroidManifest.xml`), part of the stock Flutter template, not merged in by a plugin. Package visibility so the OS text-selection menu can find apps that handle `ACTION_PROCESS_TEXT`. Nothing to do. |
| **share_plus** (added by task 11.209, 2026-09-09) | a non-exported `ShareFileProvider` (`FileProvider`, `grantUriPermissions`), a non-exported `SharePlusPendingIntent` broadcast receiver, no `<queries>` entry | Backs the map selection card's "Share…" entry (coordinates plus, where the selection has one, a GPX file). **Both components are declared `exported="false"` in the plugin's own manifest**, so neither is reachable from another app; the provider only grants the receiving share target read access to the specific cache file for the duration of the share. No permission added, no `<queries>` entry needed — Android's `ACTION_SEND`/`ACTION_SEND_MULTIPLE` implicit intents work without package-visibility declarations. **Not yet verified against a built APK.** |
| **local_auth_android** (added by task 10.79, 2026-09-09; **corrected against a real merged manifest by task 11.220, 2026-09-10**) | **Two permissions, not one:** `<uses-permission android:name="android.permission.USE_BIOMETRIC" />` and `<uses-permission android:name="android.permission.USE_FINGERPRINT" />`. **Neither carries any attribute beyond `android:name`** — in particular **no `android:maxSdkVersion`**, read off the merged manifest and the merge-blame report, not off anybody's documentation. | Lets `LocalAuthentication.isDeviceSupported()` (Security Model §4.8 control 2) query whether a screen lock is configured. **No prompt is ever shown and no biometric is ever read** — `authenticate()` is never called anywhere in this app, only the passive capability check. Both are install-time permissions of `normal` protection level, so neither produces a runtime dialog; that last fact is the platform's definition of the two permissions and is the one thing in this row a manifest cannot state. **Why one plugin brings two permissions, and why that is still one row.** The merge-blame report names two different origins: `USE_BIOMETRIC` comes from `local_auth_android`'s own library manifest, and `USE_FINGERPRINT` comes from **`androidx.biometric:biometric:1.1.0`**, which `local_auth_android` depends on. `USE_FINGERPRINT` is the pre-API-28 spelling of the same capability, deprecated when `USE_BIOMETRIC` replaced it in Android 9. One plugin was added and both arrived because of it, so it is one row. **The measured surprise, recorded because it is the thing the documentation would have got wrong.** A legacy permission is normally capped with `android:maxSdkVersion="27"` so it is requested only on the versions that need it. `androidx.biometric:biometric:1.1.0`'s library manifest declares both **unconditionally**, so this app requests `USE_FINGERPRINT` on every Android version it supports, `minSdk 24` through `targetSdk 36`, including the ones where it is dead. Harmless — a `normal` permission nobody asks for and nothing reads — but it is what the APK declares and it is not what the plugin's docs imply. **What the 2026-09-10 build did and did not prove.** Task 10.79 wrote this row from the plugin's documentation and said so: *“Not yet verified against a built APK.”* It named `USE_BIOMETRIC` alone, `scripts/verify_merged_manifest_capabilities.sh` failed the first real Android build on the permission it had missed, and that caveat is now discharged — **for this row only.** The guard reads the manifest and asks whether the matrix mentions each thing it finds; **it never asks the reverse.** So the build proves this manifest declares nothing unrecorded; it proves nothing about whether the `share_plus`, `url_launcher_android` or `package_info_plus` rows describe their plugins correctly, and those three keep their own caveats until something checks that direction. |

### Exported components (task 11.121, 2026-09-01)

**Every element in the merged manifest that can carry `android:exported`,
checked for `="true"`, regardless of its tag name.** Two are true today:

| Component | Why it is exported | Verdict |
| --- | --- | --- |
| **`MainActivity`** (`edu.nau.tritrack.MainActivity`) | Required: an activity with a `LAUNCHER`/`MAIN` intent-filter must be exported to launch at all. | **Already a recorded trust boundary, not a new one.** Task 10.77 (finding K-3) found that an exported activity is startable by any app with an explicit component intent regardless of intent-filters, and that Flutter's embedding would hand a `route` extra from such an intent straight to `go_router`, bypassing `splash_screen.dart`'s identity gate. `flutter_deeplinking_enabled=false` in the manifest and `app_router.dart`'s `overridePlatformDefaultLocation` are the two independent controls that close it; both are still present in the merged manifest as of 2026-09-01. Correct as shipped; nothing new to do. |
| **`ProfileInstallReceiver`** (`androidx.profileinstaller.ProfileInstallReceiver`) | AndroidX baseline-profile installation. | Already recorded above: exported but permission-guarded to `android.permission.DUMP`, a signature/privileged-level permission. Standard; nothing to do. |

**No component was found exported in the built APK that was not already
recorded above** — this is the sweep task 11.121's stop condition asked for,
run before any code changed. If a future push adds one, the guard fails on
it directly, by the `exported` attribute, not by name.

### The `<queries>` decision (task 11.121, 2026-09-01)

**`<queries>` stays in the guard, but on its own footing from exported
components.** A `<queries>` entry cannot be invoked by another app the way an
exported component can — it is a read, not a door. What it does do is
declare, to the OS and therefore implicitly to this project's future
maintainers, which other apps or content this one is allowed to detect.
That is small but real: `GET_CONTENT`/`*/*` and `PROCESS_TEXT`/`text/plain`
both amount to "this app can see whether apps matching this shape are
installed," which is the same category of information Android's package-
visibility rules were introduced to restrict. So: **`<queries>` entries are
checked, and a new one fails the guard**, but the failure message and this
document treat it as a disclosure to record, not an attack surface to close.

### Verdicts that changed on 2026-08-31

- **Location / GPS on Android — the behavior is now verified.** Release
  checklist item **H2** was run: the Android permission dialog appears, with
  the Precise/Approximate choice the `ACCESS_FINE_LOCATION` +
  `ACCESS_COARSE_LOCATION` pair exists to produce; granting it yields a fix
  the record screen, compass declination and DEM elevation all consume. **On
  an emulator, not on a phone** — real acquisition, drift and battery are
  still open.
- **The Android cleartext exemption is verified in the built artifact**, not
  just in the source: `android:networkSecurityConfig` appears in the debug
  merged manifest and is absent from the release one, and `android:debuggable`
  likewise. The `NSAllowsLocalNetworking` row above still describes iOS/macOS
  only.
- **Keystore / secure storage on Android is verified.** Sign-in completes,
  `SessionStore.ensureWritable`'s write-read-back pre-flight passes against the
  Android Keystore, and the session survives a `force-stop` and cold start.
  This is the Android counterpart of the macOS `-34018` failure in task 11.38
  and it does **not** reproduce. Not covered: a Keystore key invalidated by a
  device-passcode change or a restore-from-backup — `session_store.dart` sets
  no `resetOnError`, so that path is unknown.
- **The "linked cloud-backup folder" row above is stale.** Cloud backup was
  retired (task 11.31). There is no `lib/core/platform/` directory, no
  `edu.nau.tritrack/cloud_backup` channel — **the app registers no custom
  platform channel on any platform.** Release-checklist item **H4** is
  obsolete with it.
  **Update, task 10.79 (2026-09-09):** `MainActivity.kt` is no longer the bare
  `FlutterActivity` this note originally described — it now extends
  `FlutterFragmentActivity`, which `local_auth` requires. Still no custom
  platform channel; this is a base-class change for a plugin's benefit, not a
  new channel.

---

## What this file is not

It is not a verdict on whether each capability *works*. Five rows above say the
behavior has never been run on the platform in question. **That list is the
release checklist's hardware section** (`CLAUDE_DOCS/RELEASE_CHECKLIST.md`,
items H1–H5), and it is the honest answer to "what can CI not check."
