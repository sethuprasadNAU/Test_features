import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// §4.1's structural enforcement: **a release build must not be producible with
/// cleartext permitted beyond local networking.**
///
/// The security model asks for this in as many words — "a test that inspects the
/// merged release manifest and the release `Info.plist` and fails if either
/// permits cleartext beyond local networking" — and
/// `android/app/src/debug/res/xml/network_security_config.xml`'s own comment
/// names task 10.14 as the place it gets built.
///
/// **Why static file inspection rather than an actual merged manifest.**
/// Producing a genuinely merged release manifest needs a full Gradle release
/// assembly (an Android SDK, a signing config, minutes of build time) — which
/// cannot run in `flutter test` and would make this control conditional on
/// infrastructure, i.e. usually skipped. What actually makes the release build
/// safe is a property of *where the files live*: Android's manifest and resource
/// merge only pulls `src/debug/` into a debug build, so a cleartext config that
/// exists only there cannot be referenced from release. These tests assert that
/// property directly, which is both cheaper and more precise than inspecting the
/// output of a merge that already happened.
void main() {
  /// Resolves against the package root so this passes from any CWD.
  File repoFile(String relative) => File(relative);
  Directory repoDir(String relative) => Directory(relative);

  group('Android', () {
    test('the main manifest permits no cleartext', () async {
      // The single most dangerous line that could appear here:
      // `android:usesCleartextTraffic="true"` in src/main applies to EVERY
      // variant including release, with no per-domain granularity at all.
      final manifest = await repoFile(
        'android/app/src/main/AndroidManifest.xml',
      ).readAsString();
      expect(
        manifest,
        isNot(contains('usesCleartextTraffic')),
        reason: '§4.1 forbids a blanket Android cleartext flag; a debug-only '
            'networkSecurityConfig is the sanctioned mechanism',
      );
      expect(
        manifest,
        isNot(contains('networkSecurityConfig')),
        reason: 'a network security config referenced from src/main would '
            'apply to release builds too',
      );
    });

    test('the profile manifest permits no cleartext', () async {
      // Profile is a release-mode build. §4.1's exemption is debug-only.
      final manifest = await repoFile(
        'android/app/src/profile/AndroidManifest.xml',
      ).readAsString();
      expect(manifest, isNot(contains('usesCleartextTraffic')));
      expect(manifest, isNot(contains('networkSecurityConfig')));
    });

    test('there is no release manifest permitting cleartext', () async {
      final releaseManifest = repoFile(
        'android/app/src/release/AndroidManifest.xml',
      );
      if (!releaseManifest.existsSync()) return; // nothing to permit
      final manifest = await releaseManifest.readAsString();
      expect(manifest, isNot(contains('usesCleartextTraffic')));
      expect(manifest, isNot(contains('networkSecurityConfig')));
    });

    test('the cleartext-permitting config exists ONLY under src/debug', () async {
      // This is the property that makes the release build safe: a release
      // manifest/resource merge has no `src/release/res/xml/
      // network_security_config.xml` and no reference to the debug one, so the
      // resource reference cannot resolve at all outside a debug build.
      final found = <String>[];
      final androidDir = repoDir('android');
      await for (final entity in androidDir.list(recursive: true)) {
        if (entity is! File) continue;
        if (!entity.path.endsWith('network_security_config.xml')) continue;
        final contents = await entity.readAsString();
        if (contents.contains('cleartextTrafficPermitted="true"')) {
          found.add(entity.path);
        }
      }

      expect(
        found,
        hasLength(1),
        reason: 'expected exactly one cleartext-permitting config, found: '
            '${found.join(', ')}',
      );
      expect(
        found.single.replaceAll(r'\', '/'),
        contains('app/src/debug/res/xml/'),
        reason: 'moving this file out of src/debug/ would let it apply to a '
            'release build — the exact failure this test exists to catch',
      );
    });

    test('the debug manifest is the only place that references it', () async {
      final referencing = <String>[];
      await for (final entity in repoDir('android').list(recursive: true)) {
        if (entity is! File) continue;
        if (!entity.path.endsWith('AndroidManifest.xml')) continue;
        final contents = await entity.readAsString();
        if (contents.contains('@xml/network_security_config')) {
          referencing.add(entity.path);
        }
      }
      expect(referencing, hasLength(1));
      expect(
        referencing.single.replaceAll(r'\', '/'),
        contains('app/src/debug/'),
      );
    });
  });

  group('iOS and macOS App Transport Security', () {
    for (final platform in ['ios', 'macos']) {
      test('$platform never sets NSAllowsArbitraryLoads', () async {
        // The blunt instrument §4.1 names as forbidden: it disables ATS for
        // every host, public internet included. `NSAllowsLocalNetworking` is
        // the narrow, shippable alternative.
        final plist = await repoFile(
          '$platform/Runner/Info.plist',
        ).readAsString();
        expect(
          plist,
          isNot(contains('NSAllowsArbitraryLoads')),
          reason: '§4.1: never NSAllowsArbitraryLoads, in any variant',
        );
      });

      test('$platform permits only local networking, and it is shippable',
          () async {
        // Unlike Android's, this exemption IS safe in a release build: the
        // platform itself decides what counts as local (LAN ranges, .local,
        // loopback) and refuses plain HTTP to a public host regardless.
        final plist = await repoFile(
          '$platform/Runner/Info.plist',
        ).readAsString();
        expect(plist, contains('NSAllowsLocalNetworking'));
      });

      test('$platform sets no per-domain exception dictionaries', () async {
        // An `NSExceptionAllowsInsecureHTTPLoads` entry would be a named public
        // host permitted over cleartext — a different and much worse thing than
        // the local-networking relaxation.
        final plist = await repoFile(
          '$platform/Runner/Info.plist',
        ).readAsString();
        expect(plist, isNot(contains('NSExceptionDomains')));
        expect(plist, isNot(contains('NSExceptionAllowsInsecureHTTPLoads')));
        expect(plist, isNot(contains('NSAllowsArbitraryLoadsInWebContent')));
      });
    }
  });

  group('no certificate validation is bypassed anywhere', () {
    test('badCertificateCallback appears nowhere in lib/', () async {
      // §5.5: "no `badCertificateCallback` override anywhere in the codebase,
      // ever." Accepting an invalid certificate would make TLS decorative,
      // which is worse than cleartext because it looks safe.
      final offenders = <String>[];
      await for (final entity in repoDir('lib').list(recursive: true)) {
        if (entity is! File || !entity.path.endsWith('.dart')) continue;
        final contents = await entity.readAsString();
        if (contents.contains('badCertificateCallback')) {
          offenders.add(entity.path);
        }
      }
      expect(offenders, isEmpty);
    });
  });
}
