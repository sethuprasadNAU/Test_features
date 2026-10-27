// Task 11.38 — the cheap half of the guard.
//
// **What this catches and what it does not.** Sign-in on macOS failed with
// keychain error `-34018` because the app was signed ad hoc and no
// entitlements file declared `keychain-access-groups`. These tests read the
// macOS build configuration and fail if any part of that fix is undone. They
// cost nothing: no device, no signing identity, no network, so they run in
// the default `flutter test` on any machine, including one with no Xcode at
// all.
//
// They prove the *configuration* is right. They cannot prove the keychain
// actually works, because that needs a signed app bundle and a real Security
// framework — `integration_test/session_store_keychain_test.dart` is the test
// that proves that, and it needs hardware and a signing identity. The two are
// complements: this one always runs and catches deletion and drift; that one
// runs on demand and catches everything else.
//
// **The shape being guarded is not the obvious one, and that is the point.**
// Putting `keychain-access-groups` in the base entitlements files makes the
// macOS app fail to *compile* for anyone without a development certificate —
// measured during 11.38, not assumed. So the entitlement lives in `-Signed`
// variants selected by `TRITRACK_ENTITLEMENTS_SUFFIX`, and there are four
// separate ways to silently undo that: delete the entitlement, let the two
// copies of a file drift apart, break the suffix indirection in
// `project.pbxproj`, or drop the optional include that supplies the team.
// One test each.
//
// Parsed with string matching rather than an XML or pbxproj parser on
// purpose — adding a dependency to assert the contents of four short plists
// is not a trade worth making, and the failure mode here (a reformatted file
// reads as wrong) errs toward failing loudly.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The entitlement macOS requires before it will let a sandboxed app touch the
/// data-protection keychain at all.
const _requiredKey = 'keychain-access-groups';

/// Base name of each build configuration's entitlements pair.
///
/// **Both pairs matter.** `DebugProfile` covers debug and profile builds;
/// `Release` covers release. README.md's two-device walkthrough uses a debug
/// build (a release build refuses the plain-`http://` LAN server), while
/// anything a person actually keeps is a release build. The original defect
/// was present in both.
const _configs = ['DebugProfile', 'Release'];

String _basePath(String c) => 'macos/Runner/$c.entitlements';
String _signedPath(String c) => 'macos/Runner/$c-Signed.entitlements';

/// Strips XML comments and blank lines so the two variants of a file can be
/// compared on their actual entitlement content. The `-Signed` files carry a
/// long explanatory comment the base files do not.
String _entitlementBody(String xml) => xml
    .replaceAll(RegExp(r'<!--.*?-->', dotAll: true), '')
    .split('\n')
    .where((l) => l.trim().isNotEmpty)
    .join('\n');

void main() {
  group('macOS keychain entitlement (task 11.38)', () {
    for (final config in _configs) {
      test('$config-Signed.entitlements declares $_requiredKey', () {
        final file = File(_signedPath(config));
        expect(
          file.existsSync(),
          isTrue,
          reason:
              '${_signedPath(config)} is missing. It is the only entitlements '
              'file that grants keychain access, so without it a signed macOS '
              'build cannot store a session and sign-in cannot work.',
        );

        final contents = file.readAsStringSync();
        expect(
          contents,
          contains('<key>$_requiredKey</key>'),
          reason:
              'Without <$_requiredKey> the macOS keychain refuses every write '
              'with -34018 ("a required entitlement isn\'t present"), and '
              'sign-in fails *after* the server has already spent the code. '
              'That is exactly the defect task 11.38 fixed.',
        );

        // The key alone is not enough: an empty array declares access to no
        // group at all, which fails identically while looking fine in a diff.
        final group = RegExp(
          '<key>$_requiredKey</key>\\s*<array>\\s*<string>([^<]+)</string>',
        ).firstMatch(contents);
        expect(
          group,
          isNotNull,
          reason:
              '$_requiredKey is present but declares no access group. An '
              'empty <array/> is refused exactly like a missing key.',
        );
        expect(
          group!.group(1),
          contains(r'$(AppIdentifierPrefix)'),
          reason:
              'The access group must carry the team identifier Xcode '
              r'substitutes for $(AppIdentifierPrefix). A hard-coded prefix '
              'belongs to one Apple Developer account and would break the '
              'build for everybody else.',
        );
      });

      test('$config.entitlements stays buildable without a certificate', () {
        // **The regression this exists to prevent is a well-meant tidy-up.**
        // Merging the two files "to remove duplication" reintroduces a defect
        // that is worse than the one 11.38 fixed: Xcode refuses to build any
        // entitlements file containing keychain-access-groups unless
        // development signing is configured, so the Mac app would stop
        // compiling for anyone who has not set up an Apple Developer account —
        // trading "runs but cannot sign in" for "does not build".
        expect(
          File(_basePath(config)).readAsStringSync(),
          isNot(contains(_requiredKey)),
          reason:
              '${_basePath(config)} must NOT declare $_requiredKey. It is the '
              'fallback used when no signing identity is configured, and '
              'Xcode will not build it if the entitlement is present. Put the '
              'entitlement in ${_signedPath(config)} instead.',
        );
      });

      test('$config-Signed.entitlements matches its base apart from the '
          'keychain block', () {
        // Two copies of a file drift. The signed variant is the one almost
        // nobody builds, so a sandbox or network entitlement added to the base
        // would silently not apply to the only configuration that can sign in
        // — and would surface as an unrelated bug on a signed Mac build much
        // later.
        final base = _entitlementBody(File(_basePath(config)).readAsStringSync());
        final signed = _entitlementBody(
          File(_signedPath(config)).readAsStringSync(),
        );

        final withoutKeychain = signed.replaceAll(
          RegExp(
            '\t<key>$_requiredKey</key>\n\t<array>\n\t\t<string>[^<]*</string>\n\t</array>\n',
          ),
          '',
        );
        expect(
          withoutKeychain,
          base,
          reason:
              '${_signedPath(config)} has drifted from ${_basePath(config)}. '
              'The two must differ only by the $_requiredKey block; anything '
              'else added to one needs adding to the other.',
        );
      });
    }

    test('project.pbxproj selects the entitlements file through '
        'TRITRACK_ENTITLEMENTS_SUFFIX', () {
      // The indirection is what lets the signed variant be chosen without
      // editing a tracked file. Hard-code either filename back into
      // project.pbxproj and one of the two configurations becomes
      // unreachable — either nobody can sign in, or nobody without a
      // certificate can build.
      final pbxproj = File(
        'macos/Runner.xcodeproj/project.pbxproj',
      ).readAsStringSync();
      for (final config in _configs) {
        expect(
          pbxproj,
          contains(
            'CODE_SIGN_ENTITLEMENTS = "Runner/$config'
            r'$(TRITRACK_ENTITLEMENTS_SUFFIX).entitlements"',
          ),
          reason:
              'The $config entitlements path in project.pbxproj must keep the '
              r'$(TRITRACK_ENTITLEMENTS_SUFFIX) indirection.',
        );
        expect(
          pbxproj,
          isNot(contains('CODE_SIGN_ENTITLEMENTS = Runner/$config.entitlements')),
          reason:
              'A hard-coded $config entitlements path has come back, pinning '
              'every build to the unsigned variant.',
        );
      }
    });

    test('the macOS target can be given a real signing identity without '
        'editing a tracked file', () {
      // The entitlement is inert unless the app is signed by a real team —
      // that combination is what task 11.38 actually required. A repository
      // cannot carry somebody's Team ID, so what it carries instead is an
      // optional include, and this asserts the mechanism still exists. Remove
      // the include and a person following README.md gets the original bug
      // back, with no error to explain it.
      final appInfo = File('macos/Runner/Configs/AppInfo.xcconfig');
      expect(appInfo.existsSync(), isTrue);
      final contents = appInfo.readAsStringSync();

      expect(
        contents,
        contains('#include? "Signing.xcconfig"'),
        reason:
            'AppInfo.xcconfig must optionally include Signing.xcconfig — that '
            'is how somebody supplies DEVELOPMENT_TEAM and selects the signed '
            'entitlements without modifying project.pbxproj. Without it the '
            'app always signs ad hoc and cannot reach the keychain.',
      );
      expect(
        contents,
        contains('TRITRACK_ENTITLEMENTS_SUFFIX ='),
        reason:
            'AppInfo.xcconfig must define TRITRACK_ENTITLEMENTS_SUFFIX so an '
            'unconfigured clone resolves to the unsigned entitlements rather '
            'than to a filename with a hole in it.',
      );

      final example = File('macos/Runner/Configs/Signing.xcconfig.example');
      expect(
        example.existsSync(),
        isTrue,
        reason:
            'The documented shape of Signing.xcconfig must stay tracked; the '
            'real file is gitignored on purpose.',
      );

      // **Task 11.37, item 5.** This file used to open with "Copy this file to
      // `Signing.xcconfig` and fill in your own Team ID" — the copy-and-edit
      // instruction README.md step 3 replaced with a command that writes the
      // file, after that instruction named the wrong field to copy and cost
      // task 11.38 a debugging round. The sweep found the repudiated version
      // still here, in the one place the README believed it had closed.
      expect(
        example.readAsStringSync(),
        isNot(contains('fill in your own Team ID')),
        reason:
            'This file must not tell anybody to copy it and hand-edit a Team '
            'ID. README.md step 3 generates the finished file; a value a '
            'person retypes into a config file is checkable by nothing, and '
            'the only symptom of getting it wrong is No Account for Team, '
            'much later.',
      );
    });
  });
}
