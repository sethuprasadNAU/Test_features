// Task 11.40 — the guard that keeps `CLAUDE_DOCS/CAPABILITY_MATRIX.md` from
// going quietly stale.
//
// **What this exists to stop.** Two capabilities were found on 2026-08-29 that
// the app *uses* and no platform file *declared*:
//
//   - Android location. `lib/core/providers/gps_provider.dart` calls
//     `Geolocator.requestPermission()` and no Android manifest declared
//     `ACCESS_FINE_LOCATION`, so Android denied it without ever showing a
//     dialog and the app displayed its own graceful "location was denied"
//     message. Live since Phase 3.
//   - macOS user-selected files. Six `FilePicker` call sites against an app
//     with `com.apple.security.app-sandbox` true and no
//     `com.apple.security.files.user-selected.read-write`.
//
// Both are the shape task 11.38 paid for in the macOS keychain: **the OS
// refuses, the app has a tidy path for the refusal, and the tidy path is
// exactly what hides that nobody was ever asked.** `flutter test` ships no
// `Info.plist`, no entitlements and no platform channels, so it cannot see any
// of it — which is why the guard here is about the *declarations* and the
// matrix, and the behaviour is on the release checklist for a person.
//
// **What it can and cannot check.** It checks, by derivation, that every
// capability declared in a platform file has a row in the matrix — the
// direction where a new capability arrives silently. It cannot derive the
// other direction (Dart code that needs a declaration nobody wrote), because
// that needs a mapping from an API call to a platform key and there is no
// such thing to read. For that direction it pins the three declarations whose
// absence has actually cost something, by name. When a fourth is found, it
// gets a line here and a row there.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const _matrixPath = 'CLAUDE_DOCS/CAPABILITY_MATRIX.md';

/// Every file that can grant this app something the OS controls.
const _androidManifests = [
  'android/app/src/main/AndroidManifest.xml',
  'android/app/src/debug/AndroidManifest.xml',
  'android/app/src/profile/AndroidManifest.xml',
];

const _macosEntitlements = [
  'macos/Runner/DebugProfile.entitlements',
  'macos/Runner/Release.entitlements',
  'macos/Runner/DebugProfile-Signed.entitlements',
  'macos/Runner/Release-Signed.entitlements',
];

const _plists = ['ios/Runner/Info.plist', 'macos/Runner/Info.plist'];

/// The `Info.plist` keys that grant or govern something, as opposed to the
/// bundle bookkeeping (`CFBundleName`, `UILaunchStoryboardName`, …) that makes
/// up most of both files.
///
/// Matched by shape rather than by name so a key nobody here anticipated is
/// still caught: anything ending in `UsageDescription` is a permission prompt
/// by construction, and the rest are the small set of plist keys that decide
/// what the OS will let through.
bool _isCapabilityPlistKey(String key) =>
    key.endsWith('UsageDescription') ||
    const {
      'NSAppTransportSecurity',
      'NSBonjourServices',
      'UIBackgroundModes',
      'CFBundleURLTypes',
      'LSApplicationQueriesSchemes',
      'UIFileSharingEnabled',
      'LSSupportsOpeningDocumentsInPlace',
      'FlutterDeepLinkingEnabled',
    }.contains(key);

Iterable<String> _plistKeys(String xml) => RegExp(
  r'<key>([^<]+)</key>',
).allMatches(xml).map((m) => m.group(1)!);

void main() {
  final matrix = File(_matrixPath);

  group('every declared capability has a row in the capability matrix', () {
    late String matrixText;

    setUpAll(() {
      expect(
        matrix.existsSync(),
        isTrue,
        reason:
            '$_matrixPath is missing. It is the enumeration of everything the '
            'operating system has to grant this app, and without it the only '
            'record of which capabilities have been checked on hardware is '
            "whatever the last person happened to remember. Task 11.40's "
            'whole first half is that file.',
      );
      matrixText = matrix.readAsStringSync();
    });

    /// Shared failure text — every branch below is the same defect wearing a
    /// different declaration, and saying so once is better than five near-copies.
    String missing(String declaration, String where) =>
        '$where declares `$declaration` and $_matrixPath has no row '
        'mentioning it.\n\n'
        'A capability that the operating system grants and nobody wrote down '
        'is the exact shape that cost task 11.38 a working session and this '
        'task two more findings: nothing under `test/` can see whether the OS '
        'actually granted it, so the enumeration is the only place the '
        'question gets asked at all.\n\n'
        'Add a row for it, and state whether it needs a test on real hardware '
        '— including if the answer is no. "We looked at it and decided no" and '
        '"we never looked" are indistinguishable a year later, which is why '
        'the matrix records both.';

    for (final path in _androidManifests) {
      test('$path — every uses-permission', () {
        final file = File(path);
        if (!file.existsSync()) return;
        final declared = RegExp(r'android:name="(android\.permission\.[^"]+)"')
            .allMatches(file.readAsStringSync())
            .map((m) => m.group(1)!)
            .toSet();
        expect(
          declared,
          isNotEmpty,
          reason:
              'No `uses-permission` was parsed out of $path at all. Either the '
              'manifest genuinely declares none — in which case `INTERNET` has '
              'been removed and the app has no network — or this pattern no '
              'longer matches the file. A derivation that silently matches '
              'nothing reports full coverage of nothing.',
        );
        for (final permission in declared) {
          // The matrix names the short form (`ACCESS_FINE_LOCATION`), which is
          // what a person reads; the manifest carries the fully-qualified one.
          final shortName = permission.split('.').last;
          expect(
            matrixText.contains(shortName),
            isTrue,
            reason: missing(permission, path),
          );
        }
      });
    }

    for (final path in _macosEntitlements) {
      test('$path — every entitlement key', () {
        final file = File(path);
        expect(
          file.existsSync(),
          isTrue,
          reason:
              '$path is missing. All four macOS entitlement files are '
              'referenced from `project.pbxproj` through '
              r'`TRITRACK_ENTITLEMENTS_SUFFIX`, so a missing one is a build '
              'that silently falls back to a different capability set.',
        );
        final keys = _plistKeys(file.readAsStringSync()).toSet();
        expect(keys, isNotEmpty, reason: 'No entitlement key parsed from $path.');
        for (final key in keys) {
          expect(
            matrixText.contains(key),
            isTrue,
            reason: missing(key, path),
          );
        }
      });
    }

    for (final path in _plists) {
      test('$path — every capability-granting key', () {
        final file = File(path);
        expect(file.existsSync(), isTrue, reason: '$path is missing.');
        final keys = _plistKeys(
          file.readAsStringSync(),
        ).where(_isCapabilityPlistKey).toSet();
        expect(
          keys,
          isNotEmpty,
          reason:
              'No capability-granting key was found in $path. Both plists '
              'carry at least a location usage description and an App '
              'Transport Security block; finding none means this filter has '
              'stopped matching rather than that the app stopped asking.',
        );
        for (final key in keys) {
          expect(
            matrixText.contains(key),
            isTrue,
            reason: missing(key, path),
          );
        }
      });
    }
  });

  // The other direction, which cannot be derived. Each of these is a
  // declaration whose *absence* was a live defect, and each one failed
  // invisibly: the app kept working, showed a reasonable message, and did the
  // wrong thing. One test per instance, named after what breaks for a person.
  group('declarations whose absence has already cost something', () {
    test('Android asks for location, so Android must declare it', () {
      final manifest = File(
        'android/app/src/main/AndroidManifest.xml',
      ).readAsStringSync();
      for (final permission in const [
        'android.permission.ACCESS_FINE_LOCATION',
        'android.permission.ACCESS_COARSE_LOCATION',
      ]) {
        expect(
          manifest.contains(permission),
          isTrue,
          reason:
              'android/app/src/main/AndroidManifest.xml does not declare '
              '$permission, but `lib/core/providers/gps_provider.dart` calls '
              '`Geolocator.requestPermission()`.\n\n'
              'Android denies an undeclared runtime permission WITHOUT '
              'showing a dialog. `requestPermission()` returns `denied` '
              'immediately, the provider throws '
              '`LocationPermissionDeniedException`, and the app shows its own '
              '"location was denied" message — so a person sees a tidy screen '
              'saying they refused, having never been asked. Recording a '
              'bearing at your own position, which is the app, does not work '
              'at all.\n\n'
              'This was live from Phase 3 until task 11.40 found it. Do not '
              'remove it without running the app on an Android device.',
        );
      }
    });

    test('macOS opens file panels, so macOS must declare file access', () {
      for (final path in _macosEntitlements) {
        final text = File(path).readAsStringSync();
        expect(
          text.contains('com.apple.security.app-sandbox'),
          isTrue,
          reason:
              '$path no longer declares the sandbox. If that is deliberate, '
              'the file-access reasoning below changes and the capability '
              'matrix needs rewriting; if it is not, the app has quietly '
              'gained reach over the whole filesystem.',
        );
        expect(
          text.contains('com.apple.security.files.user-selected.read-write'),
          isTrue,
          reason:
              '$path declares the sandbox but not '
              '`com.apple.security.files.user-selected.read-write`, and six '
              'places in the app open a file panel: CSV export, CSV import, '
              'backup save and backup restore.\n\n'
              'A sandboxed macOS app gets the panel either way. What it does '
              'not get without this entitlement is permission to read or '
              'write the file the person picked — so exporting your data '
              'appears to work and produces nothing.\n\n'
              'Found by task 11.40. Do not remove it without running an '
              'export on macOS.',
        );
      }
    });

    test('the signed macOS pair still declares keychain access', () {
      // Task 11.38's own guard lives in `macos_keychain_entitlement_test.dart`
      // and checks far more than this. The one line here is so that the three
      // capabilities whose absence has actually broken this app fail in one
      // place, which is the list a person reads when adding the fourth.
      for (final path in const [
        'macos/Runner/DebugProfile-Signed.entitlements',
        'macos/Runner/Release-Signed.entitlements',
      ]) {
        expect(
          File(path).readAsStringSync().contains('keychain-access-groups'),
          isTrue,
          reason:
              '$path no longer declares `keychain-access-groups`. Sign-in on '
              'macOS fails with keychain error -34018 without it, which is '
              'what task 11.38 spent a session discovering. See '
              '`test/platform/macos_keychain_entitlement_test.dart` for the '
              'full guard.',
        );
      }
    });
  });
}
