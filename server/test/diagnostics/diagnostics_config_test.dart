import 'package:test/test.dart';
import 'package:tritrack_server/tritrack_server.dart';

/// Task 10.13's "off by default" requirement and task 10.80's four refusals,
/// at the config layer: nothing here talks to Postgres, so these run
/// unconditionally.
///
/// Every refusal below is checked for the *sentence*, not only for the throw.
/// Michael meets these while setting the console up; a `StateError` with the
/// wrong words in it is the failure this task exists to prevent, and a test
/// that only asserts `throwsA(isA<StateError>())` cannot see it.
void main() {
  DiagnosticsConfig read(Map<String, String> env, {bool tlsEnabled = false}) =>
      DiagnosticsConfig.fromEnvironment(env, tlsEnabled: tlsEnabled);

  Matcher refusesSaying(List<String> fragments) => throwsA(
    isA<StateError>().having(
      (e) => e.message,
      'message',
      allOf([for (final f in fragments) contains(f)]),
    ),
  );

  group('DiagnosticsConfig.fromEnvironment', () {
    test('defaults to fully disabled with no environment set', () {
      final config = read(const {});
      expect(config.enabled, isFalse);
      expect(config.allowRemote, isFalse);
      expect(config.token, isNull);
    });

    test('enabling without a token refuses, and names the fix', () {
      // The console has no per-user login — a token is the only thing
      // standing between "reachable" and "readable," so starting without one
      // must fail loudly rather than silently serve unauthenticated.
      expect(
        () => read({'TRITRACK_DIAGNOSTICS_ENABLED': 'true'}),
        refusesSaying([
          'TRITRACK_DIAGNOSTICS_TOKEN',
          'openssl rand -hex 32',
        ]),
      );
    });

    test('enabling with an empty token still refuses', () {
      expect(
        () => read({
          'TRITRACK_DIAGNOSTICS_ENABLED': 'true',
          'TRITRACK_DIAGNOSTICS_TOKEN': '',
        }),
        refusesSaying(['TRITRACK_DIAGNOSTICS_TOKEN']),
      );
    });

    test('enabled with a real token succeeds, and defaults to localhost-only', () {
      final config = read({
        'TRITRACK_DIAGNOSTICS_ENABLED': 'true',
        'TRITRACK_DIAGNOSTICS_TOKEN': _goodToken,
      });
      expect(config.enabled, isTrue);
      expect(config.allowRemote, isFalse);
      expect(config.token, _goodToken);
    });

    test('allow-remote requires its own explicit opt-in', () {
      final config = read({
        'TRITRACK_DIAGNOSTICS_ENABLED': 'true',
        'TRITRACK_DIAGNOSTICS_TOKEN': _goodToken,
        'TRITRACK_DIAGNOSTICS_ALLOW_REMOTE': 'true',
      }, tlsEnabled: true);
      expect(config.allowRemote, isTrue);
    });

    test('a token is tolerated (and ignored) when disabled', () {
      // Setting TOKEN without ENABLED must not be an error — that would make
      // it impossible to stage a token ahead of flipping the feature on.
      final config = read({'TRITRACK_DIAGNOSTICS_TOKEN': _goodToken});
      expect(config.enabled, isFalse);
    });
  });

  group('task 10.80: the dangerous configurations refuse themselves', () {
    test('§4.6: a placeholder token is refused, and the value is not echoed', () {
      expect(
        () => read({
          'TRITRACK_DIAGNOSTICS_ENABLED': 'true',
          'TRITRACK_DIAGNOSTICS_TOKEN': 'changeme',
        }),
        refusesSaying([
          'TRITRACK_DIAGNOSTICS_TOKEN',
          'placeholder',
          'openssl rand -hex 32',
        ]),
      );
      // §4.7's never-log rule: the message names the variable, never the
      // value. A refusal that quotes the secret puts it in every log that
      // captured the startup output.
      try {
        read({
          'TRITRACK_DIAGNOSTICS_ENABLED': 'true',
          'TRITRACK_DIAGNOSTICS_TOKEN': 'changeme',
        });
        fail('expected a refusal');
      } on StateError catch (error) {
        expect(error.message, isNot(contains('changeme')));
      }
    });

    test('a token below the floor is refused, and the floor is a real one', () {
      // 31 characters: one short. Also proves the floor is not doing its work
      // by accident through the placeholder list, since this is not a
      // placeholder by any rule in `placeholder_secrets.dart`.
      const nearMiss = 'f3a91b7c2d8e40561a9b3c7d2e8f01a';
      expect(nearMiss.length, DiagnosticsConfig.minimumTokenLength - 1);
      expect(
        () => read({
          'TRITRACK_DIAGNOSTICS_ENABLED': 'true',
          'TRITRACK_DIAGNOSTICS_TOKEN': nearMiss,
        }),
        refusesSaying([
          'TRITRACK_DIAGNOSTICS_TOKEN',
          '31 characters',
          'at least 32',
        ]),
      );
    });

    test('the floor rejects nothing the README tells Michael to generate', () {
      // `openssl rand -hex 32` is 64 characters; `Tokens.generate()` is 43.
      for (final token in [Tokens.generate(), 'a' * 64]) {
        expect(
          token.length,
          greaterThanOrEqualTo(DiagnosticsConfig.minimumTokenLength),
          reason: 'the documented generator must clear the documented floor',
        );
      }
    });

    test('§4.10: production refuses the console outright', () {
      expect(
        () => read({
          'TRITRACK_DIAGNOSTICS_ENABLED': 'true',
          'TRITRACK_DIAGNOSTICS_TOKEN': _goodToken,
          'TRITRACK_ENV': 'production',
        }),
        refusesSaying(['TRITRACK_ENV=production', 'psql', '§4.10']),
      );
    });

    test('the production refusal survives the spellings people type', () {
      // `isProductionEnvironment` trims and case-folds (§16.3's M-11 sweep).
      // Checked here as well as there because the whole point of this refusal
      // is catching somebody who meant to lock the deployment down, and a
      // capital P taking the *less* safe branch is that failure exactly.
      for (final spelling in ['Production', ' production ', 'PRODUCTION']) {
        expect(
          () => read({
            'TRITRACK_DIAGNOSTICS_ENABLED': 'true',
            'TRITRACK_DIAGNOSTICS_TOKEN': _goodToken,
            'TRITRACK_ENV': spelling,
          }),
          refusesSaying(['TRITRACK_ENV=production']),
          reason: 'TRITRACK_ENV="$spelling" must refuse like "production"',
        );
      }
    });

    test('§4.1: allow-remote without TLS is refused', () {
      expect(
        () => read({
          'TRITRACK_DIAGNOSTICS_ENABLED': 'true',
          'TRITRACK_DIAGNOSTICS_TOKEN': _goodToken,
          'TRITRACK_DIAGNOSTICS_ALLOW_REMOTE': 'true',
        }, tlsEnabled: false),
        refusesSaying([
          'TRITRACK_DIAGNOSTICS_ALLOW_REMOTE',
          'TRITRACK_TLS_CERT_PATH',
          'SSH tunnel',
        ]),
      );
    });

    test('none of these refusals can fire on a server that never asked', () {
      // The cost of turning the degrade into a refusal (`bin/server.dart`) is
      // paid only by a deployment that set ENABLED=true. A server that did
      // not is unaffected by every rule above, whatever else is in its
      // environment — including production, a placeholder token and a remote
      // allowance all at once.
      final config = read({
        'TRITRACK_ENV': 'production',
        'TRITRACK_DIAGNOSTICS_TOKEN': 'changeme',
        'TRITRACK_DIAGNOSTICS_ALLOW_REMOTE': 'true',
      });
      expect(config.enabled, isFalse);
    });
  });
}

/// A stand-in for a real generated token: 64 hex characters, the shape
/// `openssl rand -hex 32` produces. Not a secret — it is a literal in a
/// committed test file, which is why it is not in `.env.example` either.
const String _goodToken =
    '9f2c1d84b0e75a36c8f41d29b7e0a53c6d8f2b41903e7c5a1f8d2b6e04c9a37f';
