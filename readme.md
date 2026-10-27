# TriTrack

TriTrack is a Flutter field application for wildlife biologists conducting VHF
radio-telemetry on collared animals. It supports taking directional and
omnidirectional compass bearings, triangulating an animal's position from
multiple bearings using Lenth's (1981) maximum-likelihood estimator, predicting
line-of-sight viewshed from downloaded elevation data, and managing offline
maps and elevation coverage for use without connectivity in the field. iOS is
the primary field device; the project also builds for Android and macOS.

## Key features

- **Observation logging** — directional and omnidirectional bearing
  observations, non-detections, bearing quality flags (good / fair / suspected
  bounce), antenna type and signal strength.
- **Compass bearing capture** — sensor-fused compass with magnetometer
  interference detection, dual magnetic/true-north needle, calibration, and a
  range-sweep capture flow.
- **Triangulation / position estimation** — Lenth (1981) MLE solver over
  multiple bearings with an uncertainty (confidence) ellipse and GDOP-based
  quality flagging.
- **Offline maps** — street (OpenStreetMap), terrain (OpenTopoMap), and
  satellite (Esri World Imagery) basemap tiles, downloadable and cached for
  offline use, with per-region coverage tracking.
- **Offline elevation / viewshed** — tiled terrain-RGB elevation download
  (AWS terrarium tiles) and viewshed prediction with adjustable observer
  height (e.g. for drone-mounted receivers).
- **Data export & sharing** — CSV export/import, plain-text observation
  sharing, tag database management.
- **Backup & merge** — project backup/restore archives and a last-write-wins
  merge engine for reconciling data collected on multiple devices.
- **Project setup & pre-trip checklist** — project/extent configuration and a
  pre-trip checklist screen.

## Tech stack

- **Flutter / Dart** — SDK constraint `^3.12.2`
- **State management**: `flutter_riverpod` (with `riverpod_generator` codegen)
- **Routing**: `go_router` — bottom-tab `StatefulShellRoute` plus a splash route
- **Maps**: `flutter_map`, `latlong2`
- **Local database**: `sqflite` (`sqflite_common_ffi` for desktop/test)
- **Models**: `freezed` / `freezed_annotation`, `json_serializable`
- **Sensors/location**: `geolocator`, `flutter_compass`, `sensors_plus`,
  `permission_handler`
- **Data/export**: `csv`, `archive`, `file_picker`, `image`, `http`
- **App presentation**: `flutter_launcher_icons`, `flutter_native_splash`
- **Testing**: `flutter_test`, `mocktail`

See `pubspec.yaml` for the full, versioned dependency list.

## Project structure

```
lib/
  main.dart, app.dart
  compass/            Sensor fusion, bearing capture, magnetometer interference detection
  core/                Shared constants, error types, formatting, providers, theme
  data/
    db/                SQLite database, migrations, schema
    models/            Freezed data models (Observation, Project, Tag, EstimatedPosition, ...)
    repositories/       Repository pattern over the models, Riverpod providers
    csv/                CSV import/export for tags and observations
    sharing/            Plain-text observation sharing
    sync/                Backup archive format, last-write-wins merge engine,
                         schema migration, row validation
  features/
    compass/            Compass Calibration screen + widgets
    map/                 Main Map screen; tile sources, tile caching, offline
                         region download/store, geo math
    observations/        Observation Logging screen + bearing entry widgets
    position_estimation/ Position Estimation screen (triangulation results)
    more/                Projects, project setup/extent, pre-trip checklist,
                         manage offline maps, tag database, observation log,
                         sharing, data export
    splash/              Splash screen
  localization/          Coordinate projection, circular/bearing statistics,
                         Lenth MLE triangulation solver
    declination/          WMM (World Magnetic Model) declination lookup
  viewshed/               Tiled DEM store/fetcher, terrain tile source,
                         elevation grid, viewshed computation and overlay
  routing/                go_router configuration (StatefulShellRoute + splash)
  widgets/                Shared widgets (wheel picker, segmented toggle, placeholder)
```

Each folder under `lib/features/` corresponds to one of the app's screens; the
bottom navigation bar has five tabs — Map, Record, Compass, Position, and
More — with the remaining screens (Projects, Project Setup, Checklist, Manage
Offline Maps, Tag Database, Sharing, Data Export) nested under "More."

## Getting started

### Prerequisites

Install these before building:

- **Flutter SDK** compatible with Dart `^3.12.2` — install from
  <https://docs.flutter.dev/get-started/install>, then verify with
  `flutter --version` and `flutter doctor` (resolve anything `flutter doctor`
  flags before continuing).
- **For iOS:** a Mac with **Xcode** (from the App Store) plus the command-line
  tools (`xcode-select --install`), and **CocoaPods**
  (`sudo gem install cocoapods`). To install on a physical iPhone you also need
  a **free Apple ID** (or a paid Apple Developer account) for code signing.
- **For Android:** **Android Studio** (or the Android SDK + platform tools),
  and USB debugging enabled on the device.

### Setup

```bash
flutter pub get
dart run build_runner build --delete-conflicting-outputs
```

The `build_runner` step is required — the project uses `freezed`,
`json_serializable`, and `riverpod_generator` codegen, so generated
`*.freezed.dart`, `*.g.dart` files must exist before the app will build.
Re-run it whenever you change a `@freezed` model, a `@riverpod` provider, or
any `@JsonSerializable` class.

For iOS, also install the native pods (first checkout and after any dependency
change):

```bash
cd ios && pod install && cd ..
```

### Upgrading Flutter (and the Dart that comes with it)

The one place that says how. Last done 2026-10-07, 3.44.6 → 3.47.6 (Dart
3.12 → 3.13.5, task 11.333, with its fallout in task 11.335). Do these in
order, in one sitting, and commit once the night is green.

1. **Upgrade and note both versions.** `flutter --version` before, then
   `flutter upgrade`, then `flutter --version` again. Xcode must be a version
   the new Flutter supports (`flutter doctor`).
2. **Re-resolve and read what moved.** `flutter pub get`, then
   `git diff pubspec.lock`. The Flutter SDK pins a few packages exactly
   (`flutter_test` pins `test_api` and `matcher`; `test` pins `test_api` and
   `test_core`; `flutter` sets minimums for `meta` and `vector_math`), so the
   lock file moves with the SDK and nothing in `pubspec.yaml` has to change.
   **Write each package and its old and new version into the commit message,
   and say which SDK pin moved it** (Security Model §3.8 asks this of any
   dependency change). `packages/*/pubspec.lock` is not tracked;
   `server/pubspec.lock` should not change.
3. **Re-install the iOS pods.** `cd ios && pod install && cd ..` — the
   `Flutter` line in `ios/Podfile.lock` changes with the engine.
4. **Run `flutter analyze` once and commit what it rewrites.** A new Flutter
   can edit `analysis_options.yaml` by itself (3.47 added the four
   `exclude:` entries, and adds them back on every run if they are missing).
   `test/documentation/analyzed_packages_test.dart` allows exactly those four
   and fails on any other, so a *new* edit by the tool shows up red there: decide
   it the way task 11.335 did — check what the new exclusion hides, then either
   allow it in that test with the reason or revert it and find out how to stop
   the tool redoing it. Also expect new lints and changed SDK signatures (3.47:
   `unawaited_return_in_try_block`, and `NetworkInterface.addresses` returning
   `InterfaceAddress`); the analyzer covers `server/` too.
5. **Give the VM the same Dart.** `scripts/nightly_check.sh --vm-install-dart`
   (the night's preflight warns when the two differ).
6. **Run one whole night** — `scripts/nightly_check.sh` — and require it
   green **with the working tree unchanged at the end**; its last step fails
   if a build or check rewrote a tracked file, which is how an unapplied
   tool edit (steps 2–4) shows up.
7. Only then raise `sdk:` in `pubspec.yaml`, if you want the new minimum
   enforced for everyone; nothing requires it.

### Running on the simulator / emulator

```bash
flutter run          # runs on a booted simulator/emulator or attached device
flutter devices      # list available targets
flutter run -d <id>  # target a specific device from the list
```

### Deploying to a physical iPhone

1. Connect the iPhone via USB and tap **Trust** on the device when prompted.
2. On the phone, enable **Developer Mode** (iOS 16+):
   *Settings → Privacy & Security → Developer Mode → On*, then restart.
3. Set up signing in Xcode: open the **workspace** (not the project) —
   `open ios/Runner.xcworkspace` — select the **Runner** target →
   **Signing & Capabilities** → check *Automatically manage signing* and pick
   your **Team** (your free Apple ID works; add it via *Xcode → Settings →
   Accounts*). If the bundle identifier is already taken, change it to a unique
   one (e.g. `com.<yourname>.tritrack`).
4. Build and install from the CLI:
   ```bash
   flutter devices                       # confirm the iPhone is listed
   flutter run --release -d <device-id>  # --release avoids the debugger and is
                                         # what you want for field/battery use
   ```
   (First run: if you see repeated *"codesign wants to access key…"* keychain
   prompts, click **Always Allow**. If the build stalls at "installing", make
   sure the device is unlocked and trusted.)
5. First launch on the phone: go to *Settings → General → VPN & Device
   Management*, tap your developer certificate, and **Trust** it — otherwise
   iOS blocks the app from opening.
6. On first launch grant the **location** permission when prompted (the app
   needs it for GPS positioning and correct map centering).

> **Free Apple ID signing** installs apps that expire after ~7 days and must be
> re-installed with `flutter run` again. A paid Apple Developer account removes
> that limit and enables TestFlight distribution via `flutter build ipa`.

### Deploying to an Android device

1. Enable *Developer options* and **USB debugging** on the phone, connect via
   USB, and authorize the computer when prompted.
2. ```bash
   flutter devices
   flutter run --release -d <device-id>
   ```
   To produce a shareable build, use `flutter build apk --release` (output in
   `build/app/outputs/flutter-apk/`).

### Walking the whole app on Android — the procedure, and what it found (task 11.66)

**Nobody had ever run this app on Android until 2026-08-31.** That is how it
shipped with no location permission declared at all (task 11.40): the app's
single most important action could not work, and the app told the user *they*
had refused. One declaration was fixed; the reason it survived — that no part
of the Android build had been exercised by a person — was not.

This section is the walk. It is written the way §4 below is written: **steps
somebody else can repeat**, because a step that is not written down is a step
nobody can run twice. What the first run found is in
`CLAUDE_DOCS/DEVELOPMENT_PLAN.md` under Phase 11's Discovered Scope; what it
could *not* run is at the end of this section, and that half is the part worth
reading.

#### 0. What Android actually grants this app

**Derived from the built artifact, not from the manifests somebody wrote.**
This distinction is the point: `android/app/src/main/AndroidManifest.xml` is
what a person chose, and the *merged* manifest is what Android enforces —
plugins add components to it that nobody in this repository typed.

```bash
flutter build apk --debug
AAPT=$(ls ~/Library/Android/sdk/build-tools/*/aapt2 | tail -1)
$AAPT dump badging build/app/outputs/flutter-apk/app-debug.apk \
  | grep -E "uses-permission|uses-feature|sdkVersion|native-code"
cat build/app/intermediates/merged_manifest/debug/processDebugMainManifest/AndroidManifest.xml
```

Measured on 2026-08-31 against Flutter 3.44.6 (`minSdk 24`, `targetSdk 36`,
`compileSdk 36`):

| What | Where it comes from | Verdict |
| --- | --- | --- |
| `INTERNET` | hand-written, all three build types | Used. Map tiles, terrain, sync. |
| `ACCESS_FINE_LOCATION`, `ACCESS_COARSE_LOCATION` | hand-written (task 11.40) | **Used, and now verified on a device** — see step 3. |
| `android.hardware.location` as a **required** feature | **implied by aapt from the two permissions above** — nobody declared it | Correct for this app, but it was never a decision. On Google Play it filters out devices with no location hardware. |
| `edu.nau.tritrack.DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION` | added by AndroidX at merge | Signature-level, standard, harmless. |
| `<queries>` for `GET_CONTENT` `*/*` | added by **file_picker** at merge | Needed for the CSV/backup pickers to see other apps' documents. |
| `com.baseflow.geolocator.GeolocatorLocationService` with `foregroundServiceType="location"` | added by **geolocator_android** at merge | **Declared and never started.** The app has no background location and declares neither `FOREGROUND_SERVICE` nor `FOREGROUND_SERVICE_LOCATION`, so if anything ever did start it, Android 14+ would refuse. Leave it; know it is there. |
| `GoogleApiActivity` + `com.google.android.gms.version` | added by **geolocator_android** at merge | Google Play services, for the fused location provider. On a device without Play services geolocator falls back to `LocationManager`. **Untested on such a device.** |
| `networkSecurityConfig` (cleartext) | `src/debug/` only | **Verified in the built artifact**: present in the debug merged manifest, absent from the release one. |
| `android:debuggable` | build type | Present in debug, absent in release, as it must be. |
| Magnetometer / accelerometer | nothing declared, nothing needed | Working — see step 4. |
| Notifications, camera, storage, Bluetooth, background modes | nothing declared | Still nothing. |

`test/platform/capability_matrix_test.dart` reads **only the three
hand-written manifests**, so every row above marked "added at merge" is
invisible to it. That gap is now a Discovered Scope item.

#### 1. Build and install

The Android toolchain needs **JDK 17 or later**. This machine's default `java`
is 11, which is enough for `flutter build` (Gradle finds Android Studio's
bundled JDK on its own) but **not** for `sdkmanager` or `avdmanager`, which
refuse outright. For those:

```bash
export JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home"
export ANDROID_HOME="$HOME/Library/Android/sdk"
export PATH="$JAVA_HOME/bin:$ANDROID_HOME/cmdline-tools/latest/bin:$ANDROID_HOME/platform-tools:$ANDROID_HOME/emulator:$PATH"
```

On a real phone: enable *Developer options* and **USB debugging**, connect,
authorize the computer, then `flutter run -d <device-id>`.

**The first walk was done on an emulator**, because no Android phone was
attached to this machine. What that means for every result below is stated in
"What was not run" at the end — read it before treating any of this as
covering a real device.

```bash
sdkmanager --install "system-images;android-36;google_apis;arm64-v8a"
avdmanager create avd -n tritrack_a16 -k "system-images;android-36;google_apis;arm64-v8a" -d pixel_8
# then edit ~/.android/avd/tritrack_a16.avd/config.ini:
#   hw.gpu.enabled=yes ; hw.gpu.mode=swiftshader_indirect ; hw.ramSize=4096
emulator -avd tritrack_a16 -no-window -gpu swiftshader_indirect \
  -no-audio -no-boot-anim -dns-server 8.8.8.8,1.1.1.1
```

**`-dns-server` is not optional here.** Without it the emulator inherited a DNS
setup it could not use, every hostname failed to resolve, and the symptom was a
blank map — which looks exactly like a tile-layer defect and is not one.

Drive it with `adb shell input tap X Y` and read it with
`adb exec-out screencap -p`. Device coordinates are the full 1080×2400; a
screenshot scaled to 900 px tall multiplies by about 2.67.

#### 2. First run and identity

Launch with no permissions granted (`adb shell dumpsys package edu.nau.tritrack`
shows both location permissions `granted=false`).

- The identity gate appears, and **the Android back gesture does not dismiss
  it** — `PopScope(canPop: false)` in `identity_setup_screen.dart` holds. Good.
- Name, surname and email accept text; the keyboard resizes the layout rather
  than covering the button (`windowSoftInputMode="adjustResize"`).
- After Continue the five-tab shell appears with "No active project".
- **Identity survives a device reboot and a `force-stop`.**

#### 3. Location — the permission dialog, and the message when you say no

This is release-checklist item **H2**, and it is the reason the task exists.

1. From *More → Project Setup / Extent → New Project*, tap **Use current
   location**.
2. **The Android permission dialog appears**, with the Precise / Approximate
   choice — which is what the `FINE` + `COARSE` pair in the manifest is for.
   Task 11.40's declaration is correct and now observed.
3. Set a position first, or nothing will arrive:
   ```bash
   adb emu geo fix -111.6513 35.1983 2100
   ```
4. Granting it works: the record screen shows `35.198, -111.651 · ±5m`, the
   compass resolves declination against that fix, and a saved observation
   carries a DEM elevation.

**Then say no, because that is the path nobody had walked.** Tap *Don't allow*
twice (Android 11+ makes the second denial permanent — confirm with
`dumpsys package`, the flags become `USER_FIXED`). The app says:

> Could not get a GPS fix. Try again outdoors or with a clear sky view.

That names the wrong cause, and it is the one message in the app that exists
to name the right one. See Discovered Scope; the mechanism is a Riverpod 3
behaviour, not an Android one, so **it is wrong on every platform** and only
became visible because somebody denied a permission and read the screen.

#### 4. Compass, map, terrain

- *Compass* tab: heading, magnetic vs true north, and declination from the
  WMM all render and update. The emulator has a synthetic magnetometer; a real
  phone is still item H5.
- *Map* tab: OpenTopoMap tiles load, the position marker follows the injected
  fix, the live viewshed paints, and "Downloading terrain… 1/6" completes.
- Attribution wraps to two lines and is fully readable (task 11.95's clipping
  does not reproduce here).
- **The basemap switcher's unselected options are unreadable over a map** —
  see Discovered Scope.

#### 5. Recording a bearing

*Record* tab → **+ Quick-add tag** (name and frequency; the frequency field
correctly brings up the numeric keypad) → **POINT** to capture the heading →
**SAVE OBSERVATION**. The row appears in *More → Log* with the true-north
bearing, and the CSV export below carries the whole provenance chain:
magnetic bearing, true-north bearing, declination, `WMM-2025`, DEM elevation.

#### 6. Files — export, backup, restore

All four paths use Android's Storage Access Framework and **all four work**:

| Path | Result |
| --- | --- |
| *Data Export / Backup* → **Export CSV** | SAF "Save as" opens pre-filled `observations_<date>.csv`; the file lands with a full header and real rows. Verify with `adb shell cat /sdcard/Download/<name>.csv`. |
| → **Export project backup (.zip)** | Same, `<Project>_backup_<date>.zip`. |
| → **Import backup** | The picker correctly greys out the `.csv` and allows the `.zip` — the `FileType.custom` extension filter maps to MIME types properly. The zip is parsed, and the dialog names project, date, schema version and row count before anything is written. |
| Merge / Overwrite | Merge reported `Inserted: 0, Updated: 0, Unchanged (local was newer): 7` — correct. |

**The app never says where a file went.** Every receipt is a count —
"Backup saved (2 KB)", "Exported N observations". On macOS the save panel
showed the folder; on Android the SAF destination can be Downloads, Drive, or
any provider, and nothing in the app can find it again. Discovered Scope.

#### 7. Server, sign-in, publish, sync

From the emulator, **`10.0.2.2` is the host's loopback**, so a stack published
only on `127.0.0.1` is reachable without touching `SERVER_PUBLISH_ADDRESS`.
**A real phone cannot do this** — that is what §4 below is for.

```bash
. scripts/lib/host_user.sh
docker compose -f docker-compose.yml -f docker-compose.dev-lan.yml up -d
```

The `dev-lan` overlay is required even on the emulator: the base stack's mail
sender discards the link silently, so without it there is no way to sign in.

1. *More → Server Connection*, enter `http://10.0.2.2:8080`, **Save**. The app
   accepts cleartext because `10.0.2.2` is RFC 1918 and this is a debug build —
   which is the first exercise of the Android half of that rule.
2. **EMAIL ME A SIGN-IN CODE** → `./scripts/dev_magic_link.sh <address>
   --url-only`, paste the token, **SIGN IN THIS DEVICE**.
3. **Sign-in works.** This is the Android counterpart of task 11.38's macOS
   keychain failure: `flutter_secure_storage`'s write-read-back pre-flight
   passes against the Android Keystore, and the session **survives a
   `force-stop` and cold start**.
4. *More → Projects → ⋮ → Publish to server*. Everything reaches the server —
   `Projects`, `Tags`, `Project_Tags`, `Observations`, `Users`,
   `Project_Memberships`.

> **This walk predates schema v14 and two of the sentences around it are now
> about a schema that does not exist** (noted by task 11.220, 2026-09-10;
> **the record itself is left as written, because it is what somebody
> observed**). Task 11.219 retired `Project_Tags`, so step 4's list is one
> table shorter today. And the refusal below was the `Tag_Versions` row that
> `Project_Tags` had to vouch for; the ordering rule that caused it is gone
> with the table, and `server/test/integration/publish_request_sequence_test.dart`
> replays a first publish table by table and asserts it refuses nothing.
> **Neither has been re-walked on a device**, so this stays here as a record
> rather than being deleted or rewritten into a claim nobody has checked.

**One row is refused on the first publish and the app raises a false alarm
about it.** See Discovered Scope; check it yourself with:

```bash
U=$(grep '^POSTGRES_USER=' .env | cut -d= -f2); D=$(grep '^POSTGRES_DB=' .env | cut -d= -f2)
docker compose exec -T postgres psql -U "$U" -d "$D" \
  -c 'select id, kind, rows_pushed, rows_applied, rows_rejected from sync_traffic_log order by id;'
```

#### 8. Android's own controls

- **Back never leaves the app.** Pressed three times from the root Map tab, the
  activity stays resumed. On Android that is how you leave an app; here nothing
  happens, which reads as a freeze. Discovered Scope.
- Back correctly dismisses the keyboard without popping the route, and
  correctly pops a pushed screen.
- Rotation to landscape works; the map, nav bar and sync bar all re-lay out.
- The *More* tab keeps its nested route across tab switches, so coming back to
  *More* returns you to the screen you left rather than the menu — worth
  knowing when following these steps by tapping.

#### What was **not** run, and why

**Read this before treating anything above as coverage.**

- **No physical Android device was attached to this machine**, so every result
  above is from an `android-36` `google_apis` `arm64-v8a` emulator on a Pixel 8
  profile. That is enough for permissions, layout, files, database, network and
  sign-in — all of which are the OS's behaviour, not the hardware's. It is
  **not** enough for: a real magnetometer (H5), real GPS acquisition and drift,
  battery cost (F1), a device without Google Play services, a phone that is not
  a Pixel, or any manufacturer's own permission or battery-optimisation layer.
  Every one of those is still open.
- **Nothing needing two devices was run** — a teammate joining by code, an
  owner approving, a record made on one device appearing on another, or a
  membership being ended. Michael has one Android phone; a second device is his
  to schedule.
- **The bulk offline-map download was not exercised.** It is the one path with
  no `User-Agent` header (`offline_tile_downloader.dart`), and OSM's tile policy
  is the kind of thing that refuses a default Dart agent.
- **`flutter_secure_storage` was not tested against a changed device
  passcode.** On Android that can invalidate the Keystore key; the code sets no
  `resetOnError`, so the failure mode is unknown.
- **The release build was checked for what it declares, not for how it
  behaves.** It signs with the debug keystore — see Discovered Scope.

### iOS project notes

The iOS runner uses CocoaPods (`ios/Podfile`, targeting iOS 15.0+; the Xcode
project's deployment target is currently set to 15.6). Signing is configured
per-developer in Xcode (`ios/Runner.xcodeproj`) and is not checked into version
control beyond the shared project settings — each developer sets their own Team
as described above.

**Minimum OS versions follow the newest Xcode's accepted range** (Xcode 27 refuses
anything lower as an error, not a warning, task 11.333): the macOS app targets
macOS 12.0 (`MACOSX_DEPLOYMENT_TARGET` in `macos/Runner.xcodeproj`, three places),
and `ios/Podfile`'s `post_install` raises any pod that still declares an iOS target
below 15.0 to 15.0. The night's report header records the Xcode and Flutter versions,
so a toolchain change shows as a changed line.

## Testing

```bash
flutter analyze
flutter test
```

The repository has 290 test files under `test/`, covering the compass,
core, data (including sync/merge and CSV), map/compass/more features,
localization (including the Lenth MLE solver), and viewshed layers.

If `flutter test` gives a different answer on two consecutive runs — one file
fails, then a re-run fails somewhere else, with both passing standalone —
that is a claim about shared state between test files, not about either
failing test. Reproduce it with a stated denominator before theorising:

```bash
scripts/repeat_suite.sh 10
```

Runs the full suite N times (default 10) and reports, for each run, pass or
fail and which test failed by file and name — not just a count. Raw JSON
streams from every run are kept so a failure can be re-read without
re-running. See task 11.253 in `CLAUDE_DOCS/DEVELOPMENT_PLAN.md`.

**Repetition samples load and ordering. It does not sample the clock.** Ten
runs in one evening are ten runs at roughly the same wall-clock hour, so a
test that only fails within an hour of local midnight passes every one of
them. Two such defects (tasks 11.269, 11.273) sat in
`test/features/more/animals_screen_test.dart` and
`lib/features/more/screens/animal_detail_screen.dart` this way — correct
most of the day, wrong near a calendar-day boundary, and only ever found by
whoever happened to be running the suite in the evening. For that:

```bash
scripts/clock_matrix_test.sh
```

Runs a small, scoped set of tests — this file's "clock matrix" group — under
a stated set of fixed clocks instead of the real one: just before and just
after local midnight in the zone every incident to date was found in
(America/Phoenix, UTC-7, no DST), and once more in a UTC-positive zone
(Asia/Tokyo, UTC+9, no DST) to flip the sign of the offset
`deploymentDateFor`'s local/UTC conversion applies. See that group's own
comment in `animals_screen_test.dart` for why each clock is in the set, and
task 11.271 in `CLAUDE_DOCS/DEVELOPMENT_PLAN.md` for what this harness can
and cannot reach — most `DateTime.now()` calls in this repository still read
the real clock and are not exercised by it.

**The clock matrix samples one file's date logic. Neither instrument asks
whether the *whole suite* is green somewhere other than the zone somebody
happened to run it in.** For that:

```bash
scripts/tz_matrix_suite.sh
```

Runs the entire suite, unchanged, once under each of three zones — Michael's
own (America/Phoenix, UTC-7), UTC (the zone CI and most silent runs use), and
a UTC-positive zone (Australia/Brisbane, UTC+10) — printing the local time
each run started at. Three full suites, so budget the wall-clock time: about
5-6 minutes total. See task 11.275 in `CLAUDE_DOCS/DEVELOPMENT_PLAN.md`: its
first run found two real, TZ-dependent test-fixture defects that were green
on every machine this project has ever run the suite on, because every one of
them happens to sit in America/Phoenix.

### Seeing what a screen looks like — `flutter test` cannot, and does not try

There are **no goldens under `test/`, on purpose** (task 11.186). `flutter
test` renders in a fallback font about twice Roboto's width, so a picture
taken there is a picture of a phone nobody owns, and the `TileLayer`'s image
futures never resolve under it — the map screen renders, but no picture of it
can be produced. The reasoning, and a check that keeps it from being re-opened
by accident, are in `test/documentation/rendering_verification_policy_test.dart`.

**The picture machine is `integration_test/screenshots/`.** It boots the real
app on a real iOS simulator at App Store device geometry, walks 33 states
across two device profiles, and compares each new image against the committed
one — naming what moved and writing a diff, then stopping, because `--accept`
is a separate command somebody types after looking:

```bash
integration_test/screenshots/regenerate.sh              # every profile
integration_test/screenshots/regenerate.sh iphone-6.9   # just one
```

**What it can claim is "this did not change", never "this looks right."** No
test suite in this repository closes a rendering question; that still needs a
person and a device.

The server (below) is a separate Dart package with its own test suite
(`cd server && dart test`) and is never touched by the commands above —
running the app's tests never starts, builds, or requires the server.

## Server (optional — Phase 10)

TriTrack is **offline-first and fully functional with no server at all.**
Everything above this section works identically whether or not you ever run
what's described here. The server exists so a project owner can sync a
project across their own devices (and, in a later phase, with teammates) —
see `CLAUDE_DOCS/DEVELOPMENT_PLAN.md`'s Phase 10 and
`CLAUDE_DOCS/TriTrack_Security_Model.md` for the design and the reasoning
behind the choices below.

This is a **local development harness**, not a hosting guide — it's meant
for a laptop on your own Wi-Fi network. Don't expose it beyond your LAN; see
the security model's Gate C for what has to be true before that's ever safe.

### Prerequisites

- **Docker** and **Docker Compose ≥ 2.24** (Docker Desktop on macOS/Windows
  bundles both, and any reasonably current install clears this; on Linux
  install `docker` and the `docker-compose-plugin` package). Verify with
  `docker compose version`. The floor matters: `docker-compose.e2e.yml` and
  `docker-compose.server-test.yml` both rely on the `!override` tag (added in
  2.24) to force a sequence-typed key like `ports:` to *replace* the base
  file's value rather than concatenate with it — an older Compose fails to
  parse those files outright rather than silently merging them wrong, which
  is the safe direction to fail in, but only if you know the floor exists.

### 1. Configure secrets

```bash
cp .env.example .env
```

Open `.env` and fill in a Postgres username, password, and database name.
**`.env` is gitignored — never commit it.** There is no working default
baked into `docker-compose.yml` for any of these; if you skip this step,
`docker compose up` refuses to start and tells you which variable is
missing, rather than silently running with a guessable credential. The one
exception is `SERVER_PORT` — not a secret, so it's fine to leave blank and
let the default (`8080`) apply; set it only if that port is already taken.

### 2. Start the stack

```bash
scripts/server_up.sh
```

(`docker compose up` still works and is what this runs. The wrapper exists
because the stack now includes a container that takes encrypted backups on a
schedule, writing into a directory you own and reading a key only you can read
— see `server/README.md`, "Database backups". Compose has no way to spell "the
user who typed this", so on Linux a raw `docker compose up` gets a scheduler
that cannot write anything. It says so loudly rather than failing silently, but
this script means it does not come up at all.)

This builds the server image (from `server/Dockerfile`, using
`packages/tritrack_sync` by path — the same merge/schema code the app uses)
and starts it alongside a Postgres container. First build takes a minute or
two; subsequent starts are fast. Stop with `Ctrl-C`, or `docker compose down`
to also remove the containers (add `-v` to also delete the Postgres data
volume).

**Postgres itself is not reachable from your host or your network** — only
the `server` container can reach it, over Docker's internal network. This is
a deliberate security requirement (an exposed database port is exactly what
an opportunistic scanner looks for), not an oversight if you go looking for
`psql -h localhost` and it doesn't work. To inspect the database directly,
let the command read your own `.env` rather than retyping two values out of
it:

```bash
set -a; . ./.env; set +a
docker compose exec postgres psql -U "$POSTGRES_USER" "$POSTGRES_DB"
```

### 3. Verify it's up

```bash
curl http://localhost:8080/health
# {"status":"ok"}

curl -i http://localhost:8080/ready
# HTTP/1.1 200 OK
# {"status":"ready"}
```

**Check the second one, not the first.** `/health` says only that the process
is running: it answers `200` even on a server that never reached its database,
which is a server where nobody can sign in. `/ready` is the one that knows the
difference — it answers `503 {"status":"not_ready","degraded":["database"]}`
in that state. See `server/README.md`, "Is the server working?", for why they
are two routes rather than one (task 11.128).

### 4. Letting a phone reach it — not from this Mac, and here is where instead

**The server is published on `127.0.0.1` and nothing else can reach it** — not
your phone, not anyone else on the Wi-Fi. That is deliberate: this harness
serves plain HTTP, so the default has to be the one that is safe when somebody
forgets about it (`TriTrack_Security_Model.md` §4.1, task 10.22).

Until task 10.62 this section told you to add `SERVER_PUBLISH_ADDRESS=0.0.0.0`
to `.env`, restart, and point a phone at your laptop's LAN address. **That
instruction is withdrawn, and the server now refuses to start in that shape.**

Here is why, because it is more interesting than a removed paragraph.
§4.4's per-source rate limit is what stops one stranger on the network from
denying magic-link sign-in to everybody: ten requests from one address, and
only that address is refused. It keys on the address the connection arrives
from. On Docker Desktop — macOS and Windows — the connection does not arrive
from the caller. The VM boundary rewrites every inbound connection's source to
one gateway address before any container sees it, so two genuinely distinct
callers arrive as one, the "per-source" limit becomes one bucket shared by
everyone, and `auth_audit_log.source_address` records a gateway instead of a
person. Measured, on this exact walkthrough: twelve requests from one caller
returned `429` to an unrelated one (Security Model §12.4, finding J-2).

Putting a reverse proxy in front does not fix it. The proxy forwards the
address it sees, and the address it sees is already collapsed — so
`docker-compose.tls.yml` has the same problem for any caller arriving over a
published host port, and only the on-network case it was tested with survives.

So the server now asks a question it never used to and refuses to guess at the
answer. Set a non-loopback `SERVER_PUBLISH_ADDRESS` and you get:

```
TriTrack server: REFUSING TO START — source identity
```

**If you need a phone to reach a server, there are two supported ways.**

- **Deploy on a host whose publish path preserves source addresses.** Linux
  with `iptables` DNAT normally does. Prove it rather than assume it:

  ```bash
  ./scripts/verify_source_identity.sh --assisted
  ```

  It stands up a throwaway origin and proxy, prints one URL per device, and
  waits for you to open them **from two devices that are not this machine** —
  a phone and a laptop on the same network. Then it reads its own access log
  and reports `PRESERVED`, `COLLAPSED` or `NO VERDICT` per deployment shape.

  **You supply the traffic; it supplies the verdict.** There is no flag by
  which you can tell it the answer, and an address it can produce on its own
  — loopback, one of this host's interfaces, a container here, or the gateway
  the publish path rewrites callers to — will not fill a device slot. Without
  `--assisted` it can only screen: it will report `COLLAPSED` or `NO VERDICT`
  and never `PRESERVED`, because two containers on this host are not two
  callers, and a probe that pretended otherwise is what this flag replaced
  (Security Model §4.4.4). Only if it says `PRESERVED` may you answer the
  server's question:

  ```bash
  TRITRACK_TRUSTED_PROXIES=peer-verified   # in .env
  ```

  That value means "nothing is in front of this server, the TCP peer really is
  the client, and I measured it." It is spelled awkwardly on purpose — this is
  an operator's own claim about their own network, not a fact this repository
  can generate on their behalf. `none` used to be accepted here and is not any
  more, because `none` was a claim about the network path that this project
  shipped as a default and never checked. Full reasoning:
  `CLAUDE_DOCS/SECURITY_SCOPE_AND_EXIT.md`, "What `TRITRACK_TRUSTED_PROXIES` /
  `TRITRACK_PROXY_SOURCE_IDENTITY` mean".

- **Run the TLS deployment** — `docker-compose.tls.yml`, which sets
  `TRITRACK_TRUSTED_PROXIES` to the proxy's address itself. **That is not
  enough on its own, and assuming it was is the finding this paragraph
  exists for.** Caddy forwards the address *it* sees, so if the host's publish
  path rewrote the caller before Caddy, the allowlist works perfectly and every
  caller is still one bucket. Run the same probe and read the `proxied` line:

  ```bash
  ./scripts/verify_source_identity.sh --assisted   # proxied: PRESERVED?
  TRITRACK_PROXY_SOURCE_IDENTITY=probe-verified    # in .env, only then
  ```

  The server refuses to start until that variable says either
  `probe-verified` or `on-network-only` (nothing off this host reaches the
  proxy at all). It is the one value `docker-compose.tls.yml` does not fill in
  for you, deliberately: it is your own measured claim about your own
  network, and this repository cannot make it on your behalf. Full reasoning:
  `CLAUDE_DOCS/SECURITY_SCOPE_AND_EXIT.md`, "What `TRITRACK_TRUSTED_PROXIES` /
  `TRITRACK_PROXY_SOURCE_IDENTITY` mean".

**Neither way is available on Docker Desktop** — macOS and Windows both rewrite
every inbound connection at the VM boundary, before any container sees it, and
both shapes come back `COLLAPSED`. No configuration fixes that. A Linux host
with `iptables` DNAT normally preserves addresses, but no Linux host has been
measured for this project, so the qualification is the probe's verdict on your
machine rather than a claim about your kernel. Without a `PRESERVED` run there
is no exposable deployment, and the server is a loopback development harness on
this machine, which is what it was already doing well.

#### The walkthrough that does work: two devices against one LAN server

Everything above says why your Mac cannot host this. Here is what to do
instead, because "no route at all" was the state this section left you in, and
**two devices is not an exotic requirement** — a person leaving a project on
their second device, two accounts on one project, a phone and a laptop
disagreeing and converging, none of it can be exercised on one machine.

**You need the licensed host.** Ubuntu 24.04 ARM64 running under Parallels
Desktop on an Apple Silicon Mac, **bridged** networking, with Docker installed
natively from `get.docker.com` — not Docker Desktop, which is a different
product with the defect described above. That exact configuration is the one
that has been measured, in assisted mode with two real off-host callers, as
preserving the caller's address in both deployment shapes (13 checks,
2026-08-17; `CLAUDE_DOCS/SERVER_DEPLOYMENT_PRIMER.md` §C). The measurement is
recorded for that named configuration and not for "Linux" in general, so on any
other host, run the probe first.

**Docker Desktop on the Mac cannot host this and no setting changes that.** Its
VM boundary rewrites every inbound connection's source address before any
container sees it, so a phone and a laptop arrive as the same caller. The
per-source rate limit becomes one shared bucket — one stranger can lock
everybody out of sign-in — and the audit log records a gateway where a person
should be. The server refuses to start rather than run in that shape.

1. **On the VM**, clone the repository and create `.env` from `.env.example` as
   in step 1 above. Then add the two lines that turn a loopback harness into a
   LAN one:

   ```bash
   SERVER_PUBLISH_ADDRESS=0.0.0.0
   TRITRACK_TRUSTED_PROXIES=peer-verified   # only after your own PRESERVED run
   ```

   `peer-verified` is you asserting "nothing is in front of this server and I
   measured it" — a claim about your own network, not this VM's. Do not copy
   it from here without running
   `./scripts/verify_source_identity.sh --assisted` on that host and reading
   `PRESERVED`. It is spelled awkwardly on purpose.

2. **Bring the stack up with the LAN development overlay**, which is what makes
   sign-in possible at all:

   ```bash
   . scripts/lib/host_user.sh
   docker compose -f docker-compose.yml -f docker-compose.dev-lan.yml up --build -d
   ```

   **The first line is not optional on Linux** (task 11.69). It sets the
   user the server container runs as and creates `.dev_magic_links/`
   owned by you. Without it Docker creates that directory as root, the
   server cannot write your sign-in link into it, and **nothing tells
   you** — `/auth/magic-link` answers the same `202` whether the link
   was written or not, because it must (§4.5). You would see a sign-in
   that never arrives and no error anywhere. On macOS with Docker
   Desktop it makes no difference, which is why it went unnoticed for
   months.

   **Why an overlay.** The base stack has no way to retrieve a magic link — the
   mail sender falls back to one that discards it silently, so on a LAN stack
   nobody could sign in and every multi-device test was blocked. The end-to-end
   overlay does turn on a readable sender, and pins the published port back to
   loopback, which makes it useless from a phone. `docker-compose.dev-lan.yml`
   turns the sender on and says nothing at all about ports or publish
   addresses, so the exposure decision stays in the one `.env` line above where
   you made it deliberately. It is development-only: the server refuses to
   start if this overlay is layered onto a stack that declares
   `TRITRACK_ENV=production`.

3. **Get the address to type into the app.** On the VM:

   ```bash
   ./scripts/dev_lan_address.sh
   ```

   It finds every non-loopback address on the host, asks the server for
   `/health` on each one, and prints the addresses that answered. **The address
   that answers is the answer** — you do not have to tell a `192.168.x.x` on
   your home network apart from a `10.211.55.x` Parallels-internal one by eye,
   which is what this step used to ask of you (`ip addr show`, then pick).
   If none answer it says so, and says what usually causes that.

4. **On each device, point the app at that address**: More → Server Connection,
   type what step 3 printed, save. See the trap below before you do this on a
   phone.

   A trailing slash is harmless as of task 11.37 — the app normalises the
   address when it saves it. Before that, `http://192.168.0.42:8080/` produced
   a `404` on every request and the app reported it as **"Could not reach the
   server"**, which is the one message that sends you to check a network that
   is working. If you see that message now, it means what it says: nothing
   answered.

5. **Sign in on device one.** Enter the first email address, tap **EMAIL ME A
   SIGN-IN CODE**, then on the VM:

   ```bash
   ./scripts/dev_magic_link.sh sam@example.com
   ```

   The link is never actually emailed; it is written to one file per address on
   the VM, named after the address. That file is mode 600 and owned by root
   because it is a live credential, so the script uses `sudo` when it has to.

   **It prints the URL and how old the link is**, and the age is the part that
   matters. The file is overwritten in place, so if your request was refused by
   the rate limit below, what is sitting there is the *previous* link — which
   then fails as already used, and reads exactly like a broken sign-in. The
   script says "this link is N minutes old" rather than leaving you to work
   that out.

   Paste the URL into the app on that device. **The device that completes the
   exchange is the device that gets signed in** — opening the link in a browser
   on the VM will not sign the phone in, by design, and the page it shows says
   so.

6. **Sign in on device two with a different email address**, the same way. Each
   address gets its own `.link` file, so there is nothing to clean up between
   sign-ins. The two devices now hold two different people's sessions against
   one server, which is what a membership, permission, or convergence test
   needs.

#### Sign-in requests are capped, and the cap is silent by design

**Three sign-in requests per email address per fifteen minutes.** Anybody
debugging this walkthrough will exceed that — it is three taps of a button —
and **when it trips, nothing tells you.** The server returns the *identical*
`202` it returns for a link it really sent, and writes no file. `curl` sees the
same bytes. The app says "Check your email, then paste the code below."

**That silence is correct and must not be changed.** A distinguishable response
would tell whoever sent the request that somebody recently asked for a sign-in
link for that address — and the caller does not have to own the address. That
is an oracle about a third party's account, which is the thing
`TriTrack_Security_Model.md` §4.5's byte-identical response exists to close.
The defect this section fixes is that the *walkthrough* sent you into the cap
with no explanation available anywhere, not that the cap is quiet.

What you can actually observe, and what to do:

- **The symptom** is `scripts/dev_magic_link.sh` showing a link several minutes
  old, or no file at all for an address you have never used. Both mean the
  request was refused. A stale link will fail redemption as already used, which
  is not what it looks like.
- **Each address has its own bucket.** Signing in as a second person is
  unaffected by the first person's attempts, so a second address is the
  cheapest way to keep going.
- **There is a per-*source* cap too** — ten requests per fifteen minutes from
  one caller — and that one is reported honestly, as a `429`, because it is a
  fact about you rather than about somebody else's address. The app says the
  server is turning away attempts from this device and to wait.
- **The limiter is in-process, so restarting the server clears it:**

  ```bash
  docker compose -f docker-compose.yml -f docker-compose.dev-lan.yml restart server
  ```

  Losing the counters on restart is a real property of a single-process
  in-memory limiter, not a workaround someone found — it is written down in
  `RateLimiter`'s own doc comment. It is fine for a development harness and is
  named in the security model as a limitation of the current deployment.
- **An operator can see the trip**, in the audit log: rows with event
  `rate_limit_tripped` and outcome `email_limited`. That is the intended way to
  observe it, and it needs access to the server rather than to the client.

Reproduced by hand on 2026-08-26. It cost a working session, because the two
symptoms — a silent refusal, and a stale link that fails as already used — look
together exactly like a token that has been spent.

#### Check 1 — the red bar must go away (task 11.41)

**Run this every time you do the walkthrough, and run it on the device that
owns the project.** It takes two minutes and it is the check that would have
caught the defect this section now exists because of.

On 2026-08-27 this walkthrough produced a Mac showing a red bar reading *"2
records aren't on the server. Tap to see why"* under **Tags** and **Users**,
which never went away, no matter how many times the app synced. Nothing
appeared in the server log and nothing printed on the client, because a record
the server has refused once is deliberately not offered again — so a permanent
refusal is completely silent from the outside. There were two separate causes
and both are fixed; this is how you find out if either comes back.

1. On device two (the phone), record a bearing and let it sync. Wait for its
   status to read **Synced**.
2. On device one (the Mac, which owns the project), sync. **More → Sync
   Status.**
3. **What must be true:** the "Waiting to sync" section is empty, or every card
   in it explains itself. Each card names the record — the tag by name and
   frequency, the person by name, the bearing by tag and time — says *why it is
   waiting* in a sentence about that record, and says *what you can do*,
   including "Nothing" where that is the honest answer.
4. **Sync twice more and look again.** A card that is still there after the
   teammate's device has synced is the failure this check exists for. Note
   which record it names and what its "Why it is waiting" line says — that
   sentence is the diagnosis, and it is what was missing the first time.
5. **If a card says a table name with no record name** — the literal words
   "Tags" or "Users" — that is a table with no entry in
   `HeldRowDetails.recordLabelBuilders`, and a test should have caught it.
   Report both the card and the failing check.

**A card that stays is not necessarily data loss** — nothing is deleted, and
the record is safe on the device — but it is always worth reporting, because
the only two states it can mean are "correctly waiting on somebody else" and
"stuck", and the card has to say which.

The automated half of this check is
`test/data/sync/stuck_global_rows_test.dart` (runs anywhere, no server) and
`test/e2e/two_people_one_project_e2e_test.dart` (needs this LAN stack, and
**has never been executed** — see that file's header).

#### Check 2 — leaving a project, and coming back (task 11.54)

**§4 had no leave step at all until 2026-08-29**, which is why every one of the
defects below survived until Michael ran the cycle by hand. The walkthrough's
own criterion is *no step that is not written down*, and leaving and rejoining
is one round trip that a field season contains in both directions.

Run this with **device two** as the departing member (a contributor) and
**device one** as an owner. Three of these checks passed the first time they
were run and are here so they stay passing, not because they are suspected.

1. **Record a bearing on device two and let it sync.** Wait for its status to
   read **Synced**. This is what makes checks 6 and 8 mean anything — without a
   record that reached the server, "what survives leaving" has no subject.

2. **Leave the project on device two.** More → Projects → the **Leave** arrow
   on the project's row → confirm.

   **What must be true:** a white bar says you have left. **No red bar appears
   afterwards.** Until task 11.54, a red *"Sync isn't working. Tap to check"*
   arrived within a second — the app had synced the project on the way out,
   been refused because the person was no longer a member, and reported the
   expected consequence of the action as breakage.

3. **Open More → Sync Status on device two.** The card must say **"You've left
   this project"** and explain that this is expected, that everything on the
   device stays, that the records already recorded stay in the project
   attributed to you, and how to get back on — by asking to join again with
   the project's code, or by the owner putting you back.

   **What must not be there:** *"Sync has failed repeatedly. If this continues,
   contact whoever manages your project server."* That was the message this
   check exists because of. It pointed a departed member at the one person who
   could not help.

4. **Delete the project on device two.** The **Delete** control on its row must
   be *enabled* — a project you have left used to be a dead end, with the leave
   control correctly gone and delete greyed out, so it stayed in the list
   forever.

   Read the warning before confirming. It has to distinguish two things: what
   already reached the server is safe there and on teammates' devices, and
   anything on this device that never reached it **never will**, because every
   further attempt is refused. If records are stranded it says how many; if
   none are, it says so rather than warning as though there were. It also says
   that deleting *hides* rather than erases, and that getting back onto the
   project brings the project and its records with it.

   Then **undo it** from the bar that follows, so the rest of these checks have
   a project to run against. The undo bar times out on its own (task 11.42).

5. **On device one, open the project's Members screen.** The departed member
   must appear under **Past members**, with their role and the dates of their
   stint. A closed stint is the record that somebody collected data on this
   project between two dates, which is what a permit report needs.

6. **On device one, find the bearing device two recorded in step 1.** It must
   still be there, still attributed to them by name. Leaving does not withdraw
   contributions.

7. **Put them back from their own row.** The **person-add** icon on the past
   member's row opens the admission sheet with the role they last held, editable
   before confirming.

   **Rewritten by task 11.81, and the change is an improvement worth knowing
   about.** This used to open an invite sheet and send them a code they then had
   to redeem — for somebody the owner already trusts and removed themselves.
   Now the owner puts them back with one tap and their next sync picks it up.

   **The removal disclosure still gates it**, so the button starts disabled
   until it is acknowledged. That is the rule: nothing puts a person onto a
   project without an owner having read what removal cannot reach.

   **It cannot add a stranger.** The server refuses anybody who does not already
   hold a closed membership row on this project and no open one, so this route
   can only reverse a removal.

8. **Sync device two.** What must be true: they are a current member again; on
   device one the members list shows them under **Current members** *and* still
   shows the old closed stint under **Past members** — coming back makes a
   **new** membership row and never re-opens the old one
   (`server/test/projects/join_service_test.dart`, "it reverses a removal, with
   no code and no request").

9. **Check what came back — and do this having deleted the project in step 4,
   not only having left it.** The project must be **visible** in the list.

   Michael found on 2026-08-29 that it was not: leave, delete, get back onto
   the project, and it returned **invisible**, with no error and a
   sync that reported success. Deleting writes a tombstone on the local project
   row and bumps its `revision`, and the merge reads revision before timestamp
   — so that tombstone outranked the server's copy and survived the rejoin.
   `ProjectJoiner` now withdraws it, because joining is this device's later,
   explicit statement that it wants the project here.

   Records the server holds arrive. Anything device two recorded *after*
   leaving and before rejoining is not on the server and does not become so —
   that is what step 4's warning was about, and this is where you can see it is
   true.

**The known limitation, working as accepted:** after step 2 the project and its
data are still on device two, and nothing an owner does can take them away. That
is stated to every owner before they add anybody (the removal disclosure) and it
is why step 4 exists at all — a departed member may remove their own copy, and
nobody else can.

**Automated coverage, and what it does not reach.**
`test/core/providers/sync_provider_test.dart` covers the classification behind
steps 2 and 3, `test/data/repositories/departed_member_delete_test.dart` covers
step 4's authorization, and `test/features/more/project_members_screen_test.dart`
covers step 7, and `test/data/sync/rejoin_after_delete_test.dart` covers step
9's tombstone. **Steps 8 and 9 were run by hand against a real server on
2026-08-29** — that run is what found step 9's defect. They have no automated
end-to-end coverage.

#### Signing the macOS build — do this before step 5, or sign-in will fail

**If you are running the app on a Mac, read this first.** Until you do it, the
Mac build cannot sign in at all, and the way it fails costs you a sign-in code
each time.

**What goes wrong.** macOS will not let an app use the keychain unless the app
is signed by a real Apple developer team. The app stores your sign-in session
in the keychain. So on an unsigned Mac build, signing in gets all the way
through — the server accepts your code and marks it used — and then fails at
the last step, when the session is stored. Before task 11.38 the app then said
"could not reach the server", which was false in every particular and sent
people to check their network. It now says plainly that this device cannot
store a sign-in, and (because it checks the keychain *before* redeeming) your
code is no longer spent when it happens. But it still cannot sign in.

**This affects the Mac only.** iOS builds are signed with a real team already,
and Android does not work this way.

**What you have to do, once per machine.** The repository cannot do it for
you: a Team ID belongs to one Apple developer account, and committing one
would break the build for everyone else.

1. **Sign in to Xcode with an Apple ID.** Xcode → Settings → Accounts → **+** →
   Apple ID. **A free Apple ID is enough** — you do not need the paid
   Developer Program. This step is what lets Xcode issue the "Mac App
   Development" provisioning profile the entitlement requires; without an
   account here, every later step fails with *"No Account for Team ..."*.

2. **Find your Team ID:**

   ```bash
   security find-certificate -c "Apple Development" -p \
     | openssl x509 -noout -subject -nameopt multiline \
     | grep organizationalUnitName
   # -> organizationalUnitName = TT5775B757
   #                             ^^^^^^^^^^ your Team ID
   ```

   **Do not use the value in parentheses in the certificate's name.**
   `security find-identity -v -p codesigning` prints something like
   `Apple Development: you@example.com (KYKW9L6G57)`, and that parenthesised
   value is Apple's per-developer *user* identifier, **not** your Team ID.
   Using it produces `No Account for Team "..."` — an error that reads like a
   missing Apple ID account and is in fact a wrong ten-character string. It
   cost a debugging round the first time this section was written. The Team ID
   is the certificate's organizational-unit field, which is what the command
   above prints. Xcode → Settings → Accounts → your Apple ID also shows it in
   the Team column.

3. **Create your local signing config.** This writes the finished file with
   your Team ID already in it — there is nothing to hand-edit afterwards. Run
   it from the repository root; the file it creates is gitignored on purpose:

   ```bash
   printf '%s\n' \
     "DEVELOPMENT_TEAM = $(security find-certificate -c 'Apple Development' -p \
        | openssl x509 -noout -subject -nameopt multiline \
        | awk -F' = ' '/organizationalUnitName/ {print $2}')" \
     "CODE_SIGN_STYLE = Automatic" \
     "CODE_SIGN_IDENTITY = Apple Development" \
     "TRITRACK_ENTITLEMENTS_SUFFIX = -Signed" \
     > macos/Runner/Configs/Signing.xcconfig

   cat macos/Runner/Configs/Signing.xcconfig   # check the Team ID is not blank
   ```

   **The command generates the value rather than asking you to copy one on
   purpose.** An earlier version of this section said "copy the template, then
   edit the Team ID", and gave the wrong field to copy from — which fails much
   later with `No Account for Team "..."`, an error that reads like a missing
   Apple ID rather than a wrong ten-character string. If `DEVELOPMENT_TEAM`
   comes out blank above, you have no `Apple Development` certificate yet;
   do step 4 in Xcode's GUI, which creates one, and then re-run this.

4. **Let Xcode create the provisioning profile once.** Open
   `macos/Runner.xcworkspace` in Xcode, select the **Runner** target →
   **Signing & Capabilities**, and make sure your team is selected. Xcode
   registers the app and downloads a profile. Equivalently, from the terminal:

   ```bash
   xcodebuild -workspace macos/Runner.xcworkspace -scheme Runner \
     -configuration Debug -destination 'platform=macOS' \
     -allowProvisioningUpdates build
   ```

   `-allowProvisioningUpdates` is needed only this once; `flutter run` and
   `flutter build` cannot pass it themselves, which is why the first build has
   to be done this way.

5. **Check it worked**, with a test that writes a session to the real keychain
   and reads it back on the real app bundle:

   ```bash
   ./scripts/verify_session_store_keychain.sh
   ```

   A pass means sign-in will survive a restart on this Mac. A failure
   mentioning **`-34018`** means the app is still signing ad hoc — go back to
   step 1, since that error is nearly always a missing Xcode account rather
   than a wrong Team ID.

**If you skip all this, the Mac app still builds and runs** — it just signs ad
hoc, cannot use the keychain, and cannot sign in or sync. That is deliberate:
the entitlement lives in a separate `-Signed` entitlements file selected only
when you have configured a team, because an entitlements file that asks for
keychain access will not *compile* without a development certificate. So
somebody who only wants to look at the app is not forced through any of the
above. See `macos/Runner/Configs/Signing.xcconfig.example`.

**`Signing.xcconfig` never travels with the repository, so redo step 3 on every
checkout.** It is deliberately gitignored — it names one Apple developer team,
and committing it would break the build for everybody else — which means a
fresh clone, a second Mac, or a new worktree starts unsigned again, and this is
not something `git pull` can hand you. **The symptom is quiet**: the app builds
and runs normally and only refuses at sign-in, saying it cannot store a sign-in
securely and pointing back at this section. If a Mac that used to sync suddenly
will not sign in, check whether this file exists before looking anywhere else:

```bash
cat macos/Runner/Configs/Signing.xcconfig   # no such file -> redo step 3
```

**The trap, named rather than left for you to find.** The app accepts a plain
`http://` address **only in a debug build**, and even then **only for a private
or loopback host**. A release or profile build installed on the phone will
refuse `http://192.168.0.42:8080` with a message about needing `https://`, and
nothing about that message will suggest the build mode is the reason. If the
address is rejected on the phone but works on a debug desktop build, that is
this and not a typo. Run a debug build on the device (`flutter run` with the
device attached), or terminate TLS with `docker-compose.tls.yml`, which is a
larger job needing a real hostname and certificate.

**When you are done, take the exposure back down** — remove
`SERVER_PUBLISH_ADDRESS=0.0.0.0` from `.env` and restart. This is a plain-HTTP
development stack on a network you do not control; it is not something to leave
running.

### 5. Point the app at it

In the app: **More → Server Connection**, enter `http://127.0.0.1:8080` (or
your server's real address if you completed step 4's supported path), and save.
Task 10.2's server-optional seam means this field is the only place a server
URL is ever configured — never a compile-time constant, so switching between a
laptop, a staging box, and a future production server is retyping this field,
not rebuilding the app.

A `http://` URL is accepted only in a debug build, and only for a loopback or
private-network host (`validateServerUrl` in
`lib/core/providers/server_config_provider.dart`) — see
`TriTrack_Security_Model.md` §4.1 and task 10.4 for the platform-level
cleartext exemptions that make this work at all on iOS/Android, and tasks
10.48/10.50/10.57 for what makes it structurally impossible to ship a release
or profile build with cleartext enabled.

### Steps that stay manual, and why (task 11.37)

**The rule this section records.** A documented step where you run a command,
read a value out of its output, and type that value somewhere else **cannot be
checked by anything**, because it is prose. Task 11.38 hit one: a line here
named the wrong field of a certificate to copy, and the only symptom was an
unrelated-sounding build failure much later. Nothing in the test suite could
have caught it. The fix pattern is to **have the command write the file, or at
least produce the finished line** — which is what step 3 of "Signing the macOS
build" does.

Every such step in `README.md`, `server/README.md` and `.env.example` was swept
on 2026-08-28. Here is what happened to each, **including the ones deliberately
left alone**, because "we looked at it and decided no" and "we never looked" are
indistinguishable a year later.

**Converted — the command now produces the value:**

| Step | Was | Now |
| --- | --- | --- |
| The magic-link file (§4 walkthrough step 5) | `cat` it, "copy the URL (the third line)" | `./scripts/dev_magic_link.sh <address>` prints the URL and how old it is |
| The VM's LAN address (§4 walkthrough step 3) | `ip addr show`, then pick the one that is not Parallels-internal | `./scripts/dev_lan_address.sh` prints the addresses the server actually answered on |
| The macOS Team ID | copy the template, edit in your Team ID | one command writes `Signing.xcconfig` (converted by task 11.38; task 11.37 removed the copy-and-edit instruction still left in `Signing.xcconfig.example`) |
| Postgres credentials for `psql` | retype `POSTGRES_USER`/`POSTGRES_DB` out of `.env` | source `.env` in the command |
| The diagnostics token | paste it into a `curl` header | read it from `.env` in the command |
| The `age` backup public key | "paste its `# public key: age1...` line" | a command that prints the finished `TRITRACK_BACKUP_RECIPIENTS=` line |
| The `minisign` verifying key | "the `RW...` line of `backup-verify.pub`" | a command that prints both finished `.env` lines |
| The backup signing key path | written `/home/you/...`, which is not a macOS home directory | the same command substitutes `$HOME` |

**"The third line" is the one worth dwelling on**, because it shows how this
class fails. Task 11.37 added an `Issued:` timestamp to the magic-link file for
an unrelated reason — and that moved the URL to the fourth line. The
instruction would have been silently wrong from that moment, and the only
symptom would have been a sign-in that did not work. Nothing could have failed.

**Left manual on purpose:**

- **The source-identity probe's verdict** →
  `TRITRACK_TRUSTED_PROXIES=peer-verified`, and the same for
  `TRITRACK_PROXY_SOURCE_IDENTITY=probe-verified`. **Automating this would undo
  the control.** That value is not a fact the probe possesses; it is *you*
  asserting that you ran the probe from two real off-host devices on this
  deployment and read `PRESERVED`. A tool that wrote it on its own would be
  making a claim about the operator's network on the operator's behalf, which
  is precisely what `none` used to do before task 10.62 withdrew it. The
  awkward spelling is part of the control. This is the highest-value thing in
  this section and the reason the sweep needed judgement rather than a script.
  Full reasoning: `CLAUDE_DOCS/SECURITY_SCOPE_AND_EXIT.md`, "What
  `TRITRACK_TRUSTED_PROXIES` / `TRITRACK_PROXY_SOURCE_IDENTITY` mean".
- **The `AGE-SECRET-KEY-...` line onto paper.** The offline copy exists because
  it is *not* on any machine. A command that wrote it somewhere would be
  writing it somewhere.
- **The verifying key transcribed into the drill log** at the bottom of
  `server/README.md`. The point of that entry is a **second, independent** copy
  to check the first against. One command writing both makes it one copy in two
  places, which is what it exists not to be.
- **`ALTER DATABASE` to rename a restore into place, and `DROP DATABASE` on a
  `_replaced_` copy.** Both destructive, both deliberately withheld from the
  restore script (task 10.37): the `_replaced_` database may be the only copy of
  what a bad restore needs recovering from. Typing it out is the pause.
- **Revoking another person's sessions in `psql`.** There is deliberately no
  endpoint for it (§4.3). Adding a convenience here would be adding the
  endpoint.
- **`dart pub outdated` → version pins in `pubspec.yaml`.** The manual step *is*
  the review gate (§3.8).
- **The app's Server Connection field**, and pasting the sign-in link into it.
  No script can reach a text field on a phone, and the device that completes
  the exchange being the device that gets signed in is the design, not a
  limitation. What the two scripts above remove is everything up to that point.
- **`flutter devices` → `flutter run -d <id>`.** Choosing which device to run
  on is a choice, not a transcription, and a wrong one fails immediately and
  says so.
- **Inventing `.env` secrets** (`POSTGRES_PASSWORD`, the diagnostics token).
  Nothing is being read out of any output; there is no source to automate from.
- **The drill's own check count.** Already solved the right way and worth
  copying: `scripts/backup_restore_drill.sh` prints its count on its last line
  rather than trusting the number written in the log, *because the written one
  had already drifted twice*.

### Beyond this machine: real TLS (task 10.49)

Everything above is the loopback prototype workflow — plain HTTP, on purpose,
reaching nothing but this host. A real deployment needs actual TLS
termination, which is `docker-compose.tls.yml` — see `server/README.md`'s "TLS
termination" section for setup, what a local self-signed run verifies, and the
DNS/port step that only a human running it against a real host can complete.
Read `server/README.md`'s "Source identity" section alongside it: TLS decides
who can read the traffic, and source identity decides whether the rate limit
and the audit log mean anything, and 10.49 shipped the first without the
second.

### Diagnostics console (task 10.13, optional)

A read-only debugging view over the same database — project row counts,
recent rows with their sync columns, the identity/membership map, the device
registry, every sign-in event, and (most usefully) the sync traffic log,
including which rows lost last-write-wins and why. Off by default.

**`server/README.md`, "The diagnostics console", owns the procedure** — which
variables to set, what a good token looks like, the nine routes and what each
answers, the SSH tunnel that reaches it from another machine, and the five
configurations it refuses to start in (task 10.80). It is not repeated here,
because a second copy of a setup step is one that goes stale without anything
noticing.

One property to know before you read that section rather than after: **the
console has no per-user login.** The token is its whole authentication, so
anyone holding it reads every project on the server.

### Encrypted database backups (task 10.24)

```bash
scripts/backup_db.sh                # take one
scripts/restore_db.sh <archive> <target-db> <identity-file>
scripts/backup_restore_drill.sh     # prove the restore, on a throwaway stack
```

Archives are `age`-encrypted to public keys whose private halves never touch
the server, so a compromised host yields the live database but not every
historical snapshot of it. The job refuses to run until
`TRITRACK_BACKUP_RECIPIENTS` is set — there is no unencrypted path.

**Read `TriTrack_Security_Model.md` §4.9.1 before backing up real data.** It
is the key custody arrangement, and it is the one decision here with no undo:
an archive's recipients are fixed when it is written, so a lost key means
permanently unreadable archives and a missing second holder is only noticed
during a recovery. `server/README.md` has the operational detail and the
restore-drill log.

### Test suite guarantees (task 10.15)

Two scripts pin down the phase's acceptance criteria as runnable checks
rather than assumptions:

- **`scripts/run_offline_suite.sh`** — the headline test. Brings the server
  stack down first, then runs the full `flutter test` suite, so "the app is
  fully functional with the server down and the network disabled" is an
  explicit, named run, not an inference from "the tests happened to pass."
  **It also states how much of `test/` that run reached** (task 11.156): a
  `flutter test` narrowed to one directory passes and exits 0, so the exit code
  alone cannot tell a full suite from a seventh of one. The script writes a JSON
  report and hands it to `scripts/assert_suite_scope.py`, which fails unless
  every `*_test.dart` on disk was loaded and every skipped test is declared,
  with a reason, in `test/declared_skips.json`. The counts print on every run,
  green or red.
- **`scripts/run_server_tests_docker.sh`** — "server suite green in Docker
  from a clean checkout." Brings up a throwaway, loopback-only Postgres via
  `docker-compose.server-test.yml` (never the base compose file's port-less
  one — see that file's own comment), points `dart test` at it, and tears
  everything down afterward regardless of the result. Needs `.env` filled in
  as in step 1 above.

### End-to-end integration suite (task 10.17)

The app's default `flutter test` run never touches a network (Phase 10
invariant 5) — everything under `test/` runs against a fake transport or an
in-memory database. `test/e2e/` is the one deliberate exception: it drives
the *real* client sync/auth code (`HttpSyncTransport`, `SyncEngine`,
`AuthClient`, `ServerIdentityAdopter`, `ProjectPublisher`/`ProjectJoiner`)
against a *real* running server, because that seam — the wire between the
two halves of the system — is otherwise never exercised at all. It is
opt-in and skips cleanly when unconfigured, the same way the server's own
`@Tags(['postgres'])` suite does.

**Run it with one command:**

```bash
scripts/run_e2e_tests.sh
```

That brings the stack up, waits for `/health`, runs the suite with both
environment variables set, and tears the stack down afterwards. Set
`TRITRACK_E2E_KEEP_STACK=1` to leave it running for a second pass.

**Use the script rather than assembling the steps below by hand.** They are
kept because they say *why* each piece is there, and because a failure is
easier to diagnose when you can run one step at a time — but on 2026-08-27
the four-line invocation was typed without its two environment variables
twice in a row, the second time from an error message that printed the
correct command, and both runs produced thirty-odd failures that had nothing
to do with the code. The server suite has had `run_server_tests_docker.sh`
since task 10.15; this suite went without one for six weeks and this is what
it cost.

**The trap the script removes**, since it is worth understanding once:
`--run-skipped` is required, because `dart_test.yaml` skips the `e2e` tag by
default so that a bare `flutter test` stays green offline. It is also exactly
the flag that overrides `e2eSkipReason`, the opt-out that keeps an
unconfigured run from executing anything at all. So the only way to run this
suite is also the only way to run it against nothing, and the sole difference
is two environment variables.

---

**1. Bring up the server with magic-link capture enabled.** The base
`docker-compose.yml` has no way to retrieve a sign-in token (see its own
"Configure secrets" section above) — layer the e2e override on top, which
adds `TRITRACK_DEV_MAGIC_LINK_DIR` and bind-mounts `.e2e_magic_links/` so the
suite can read a real token off the host filesystem. Named explicitly with
`-p tritrack-e2e`, mirroring the gate script's own `-p tritrack-gate`
discipline (task 10.90) — two compose projects that can never resolve to the
same name is what lets the suite tell its own stack apart from another one
answering the same port (finding M-12, Security Model §16.3):

```bash
. scripts/lib/host_user.sh
docker compose -p tritrack-e2e -f docker-compose.yml -f docker-compose.e2e.yml up --build -d
```

The first line is task 11.69's, and on Linux the suite does not work
without it: it sets the user the server runs as and creates
`.e2e_magic_links/` owned by you. `scripts/run_e2e_tests.sh` and
`scripts/gate_smoke_test.sh` both source it already — this raw form is
the one place it has to be typed.

**2. Run the suite:**

```bash
TRITRACK_E2E_BASE_URL=http://localhost:8080 \
TRITRACK_E2E_MAGIC_LINK_DIR=.e2e_magic_links \
  flutter test test/e2e --tags e2e --run-skipped
```

Both environment variables are required — `test/e2e/support/e2e_env.dart`
treats their *absence* as the opt-out signal, exactly like the server's
`DatabaseConfig.fromEnvironment` treats missing `POSTGRES_*` variables.
`dart_test.yaml` skips every `e2e`-tagged test by default, so `--run-skipped`
is required to actually run this suite — without it, `--tags e2e` alone just
reports "all tests skipped" with exit 0. Running plain `flutter test` (no
flags) loads no test that needs a server — the default suite stays green with
no server and no network — verify this yourself if you touch anything under
`test/e2e/support/`.

One file in `test/e2e/` is deliberately **not** tagged `e2e` and so does run
on every plain `flutter test`: `suite_coverage_test.dart` (task 11.45). It
asks what this suite covers by reading source rather than by talking to
anything — every method on `SyncTransport` and `AuthClient` must be called by
some test here, and some test must sign **two different people** in. Both
questions used to be answered by counting the files in this directory, which
could not tell a suite that had lost its only two-person test from one that
had not. Because it needs no server, the coverage of the e2e suite is now
checked on every run rather than only on the runs where a stack is up.

`e2e_coverage_guard_test.dart` asserts, before anything else runs, that the
container publishing that port belongs to compose project `tritrack-e2e` —
not just that *something* answers `/health`. If a stack from an earlier run
(a stray `tritrack-e2e`, or a `tritrack-gate` left up from a gate run) is
squatting the port, this fails by naming the stack that answered instead of
running the suite against it. Set `TRITRACK_E2E_EXPECTED_PROJECT` if you
brought the stack up under a different `-p`.

**Each test run mints its own throwaway emails, project ids, and device
ids** (`randomEmail()`/`randomId()` in `test/e2e/support/e2e_harness.dart`) —
unlike the server's own Postgres suite, which drops and recreates its schema
per test, this suite runs against the *same* persistent database across
runs, so nothing it creates collides with a previous run's data.

Tear down when done: `docker compose -p tritrack-e2e -f docker-compose.yml -f
docker-compose.e2e.yml down -v` (the `-v` also removes the Postgres data
volume). `.e2e_magic_links/` is gitignored, same as `server/.dev_magic_links/`
— a magic-link file is a live credential for as long as it hasn't expired,
never something to commit.

### Continuous integration, and what it cannot check (task 11.40)

Four GitHub Actions workflows in `.github/workflows/` — see that directory's
`README.md` for the table. The offline suite and the server suite run on every
commit; the eighteen gate instruments run on any change that touches what they
measure, plus nightly — **except that the nightly is switched off until
1 October 2026** (task 11.221, to save GitHub Actions minutes; the schedule
is commented out in the workflow file, not deleted).

**Read `CLAUDE_DOCS/RELEASE_CHECKLIST.md` before trusting a green tick.** It is
the written division: what CI covers, what it deliberately does not, and the
list a person must work through before a release. Nothing the *operating
system* grants is in CI — the keychain, App Transport Security, location,
background modes, the cloud-folder bookmark — and
`CLAUDE_DOCS/CAPABILITY_MATRIX.md` enumerates all of it from the platform
manifests, with a stated verdict on hardware testing for each.

`CLAUDE_DOCS/SETUP_OWNERSHIP.md` records which file owns each setup step, and
is enforced by a test: a setup instruction copied into a second file fails the
suite.

### Tests that need real hardware (`integration_test/`)

Two things about this app cannot be tested by `flutter test` at all, for the
same underlying reason: the plain test harness is not an app. It ships no
`Info.plist`, no entitlements, no code signature, and no platform channels, so
anything the *operating system* enforces is invisible to it. Tests under
`integration_test/` run as the genuine compiled app bundle instead, which is
why they live in their own directory — Flutter's test runner never discovers
it, so the default `flutter test` stays green offline with no skip tags.

- **`ats_transport_security_test.dart`** (task 10.50) — proves App Transport
  Security actually refuses cleartext to a public host, rather than the app's
  own URL check refusing it first. Run with
  `./scripts/verify_ats_transport_security.sh`.
- **`session_store_keychain_test.dart`** (task 11.38) — proves the platform
  keychain will store a sign-in session and give it back. Run with
  `./scripts/verify_session_store_keychain.sh`.

**The second one exists because its absence cost a working session.** Sign-in
had never worked on macOS in any build — the keychain refused every write —
and nothing could have caught it: every test that touches sign-in substitutes
an in-memory store (`test/support/fake_session_store.dart`), because the real
one cannot work under `flutter test`. The workaround for the untestability was
also what guaranteed the bug stayed invisible. If you add a feature that
depends on something the OS grants — a keychain, a camera, a location
permission, a background mode — assume the same blind spot applies to it and
put a test here.

`test/platform/macos_keychain_entitlement_test.dart` is the cheap companion to
the keychain test: it needs no hardware and runs in the default suite, and it
fails if the macOS signing configuration is undone. It checks the
configuration; only the hardware test checks the behaviour.

## App icon & splash

The app icon and native splash screen are generated from source assets in
`CLAUDE_DOCS/design_handoff_tritrack/assets/icon/`, copied into
`assets/icon/` and referenced from `pubspec.yaml` (`flutter_launcher_icons`
and `flutter_native_splash` configuration blocks). The native splash frame is
shown momentarily before the app's own `SplashScreen`
(`lib/features/splash/splash_screen.dart`) takes over.

To regenerate after changing the source images:

```bash
dart run flutter_launcher_icons
dart run flutter_native_splash:create
```

## Reference documents / data files

Design and technical background documents live under `CLAUDE_DOCS/`:

- `CLAUDE_DOCS/design_handoff_tritrack/README.md` — brand, design tokens, and
  per-screen design handoff.
- `CLAUDE_DOCS/TriTrack_Design_Document.md` — UI/UX design decisions
  (accessibility, touch targets, redundant non-color cues, etc.).
- `CLAUDE_DOCS/TriTrack_Technical_Context.md` — product scope, data model,
  and sync conventions.
- `CLAUDE_DOCS/WMM2025/` — NOAA World Magnetic Model 2025 coefficient files.
  The app reads the small runtime coefficient file bundled at
  `assets/wmm/WMM2025.COF`; it does not read anything from `CLAUDE_DOCS/` at
  runtime.

**Note:** the large NOAA WMM technical report PDF,
`CLAUDE_DOCS/WMM2025/noaa_71569_DS1.pdf` (~21.5 MB), is intentionally **not**
tracked in git (see `.gitignore`) to keep the repository small. It is
reference-only documentation and is not used by the app at runtime. If you
want the full report, download it from NOAA's World Magnetic Model page
(https://www.ncei.noaa.gov/products/world-magnetic-model) and place it at
that same path.

## License / attribution

No license file is currently included in this repository; treat the code as
all-rights-reserved pending a decision on licensing.

- Triangulation uses the maximum-likelihood bearing-intersection method of
  Lenth, R.V. (1981), "On Finding the Source of a Signal," *Technometrics*,
  23(2), 149–154.
- Magnetic declination uses the NOAA/NCEI/BGS World Magnetic Model (WMM2025).
- Basemap tiles are provided by OpenStreetMap (street), OpenTopoMap
  (terrain), and Esri World Imagery / Maxar / Earthstar Geographics
  (satellite); see `lib/features/map/services/tile_sources.dart` for the
  exact endpoints and required attribution strings.
- Elevation data for viewshed prediction is sourced from the AWS Open Data
  "elevation-tiles-prod" terrarium terrain tiles; see
  `lib/viewshed/terrain_tile_source.dart`.
