import 'dart:async';
import 'dart:io';

import 'package:test/test.dart';
import 'package:tritrack_server/tritrack_server.dart';

/// `resolveEmailSender`'s production refusal (task 10.6, and the M-11 sweep,
/// Security Model §16.3) had no dedicated coverage until this file — the
/// TRITRACK_ENV normalisation fix below is the reason it exists.
void main() {
  group('resolveEmailSender', () {
    test('nothing configured returns the silent sender', () {
      expect(resolveEmailSender({}), isA<NullEmailSender>());
    });

    test('a dev directory outside production returns the file sender', () {
      expect(
        resolveEmailSender({'TRITRACK_DEV_MAGIC_LINK_DIR': '/tmp/links'}),
        isA<FileEmailSender>(),
      );
    });

    test('a dev directory in production REFUSES', () {
      expect(
        () => resolveEmailSender({
          'TRITRACK_DEV_MAGIC_LINK_DIR': '/tmp/links',
          'TRITRACK_ENV': 'production',
        }),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            allOf(
              contains('TRITRACK_DEV_MAGIC_LINK_DIR'),
              contains('TRITRACK_ENV=production'),
            ),
          ),
        ),
      );
    });

    test('the production refusal survives case and whitespace in TRITRACK_ENV', () {
      // Security Model §16.3's M-11 sweep: an exact `==` comparison let
      // "Production" or "production " silently ship the dev sender.
      for (final value in [
        'Production',
        'PRODUCTION',
        ' production',
        'production ',
      ]) {
        expect(
          () => resolveEmailSender({
            'TRITRACK_DEV_MAGIC_LINK_DIR': '/tmp/links',
            'TRITRACK_ENV': value,
          }),
          throwsStateError,
          reason: 'TRITRACK_ENV="$value" must still be recognised as production',
        );
      }
    });
  });

  group('FileEmailSender writes when the link was issued (task 11.37)', () {
    late Directory dir;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('tritrack-links-');
    });
    tearDown(() => dir.deleteSync(recursive: true));

    File linkFileFor(String email) =>
        File('${dir.path}/${email.replaceAll(RegExp(r'[^a-zA-Z0-9._@-]'), '_')}.link');

    test('the file records the issue time, not only the expiry', () {
      // **Why this line exists.** The file is named after the address and
      // overwritten, so a request the per-address rate limit silently refused
      // (§4.4 answers the same 202 and sends nothing) leaves the *previous*
      // link in place, looking exactly like a fresh one. Reading it and being
      // told the code did not work reads as a spent token; the real cause is
      // one step earlier. That cost a working session on 2026-08-26.
      final issued = DateTime.utc(2026, 8, 26, 14, 30);
      FileEmailSender(directory: dir, now: () => issued).sendMagicLink(
        email: 'sam@example.com',
        url: 'http://192.168.0.42:8080/auth/redeem?token=abc',
        expiresAt: issued.add(const Duration(minutes: 15)),
      );

      final lines = linkFileFor('sam@example.com').readAsLinesSync();
      expect(lines, contains('Issued: ${issued.toIso8601String()}'));
      expect(
        lines,
        contains('Expires: ${issued.add(const Duration(minutes: 15)).toIso8601String()}'),
      );
    });

    test('the expiry alone cannot tell a stale link from a fresh one', () {
      // The property, not the format. Two links written 20 minutes apart both
      // carry a future-looking expiry for most of their lives; only the issue
      // time separates them.
      final first = DateTime.utc(2026, 8, 26, 14, 00);
      final second = DateTime.utc(2026, 8, 26, 14, 20);
      String issuedLineAfterWriting(DateTime at) {
        FileEmailSender(directory: dir, now: () => at).sendMagicLink(
          email: 'sam@example.com',
          url: 'http://host:8080/auth/redeem?token=t',
          expiresAt: at.add(const Duration(minutes: 15)),
        );
        return linkFileFor('sam@example.com')
            .readAsLinesSync()
            .firstWhere((l) => l.startsWith('Issued: '));
      }

      expect(issuedLineAfterWriting(first), isNot(issuedLineAfterWriting(second)));
    });

    test('the URL is still findable by prefix, not by line number', () {
      // Every reader of this file — the e2e harness, `scripts/dev_magic_link.sh`
      // — matches `http`, because "the third line" is the shape of defect
      // task 11.37 item 5 is about, and adding `Issued:` moved it.
      FileEmailSender(directory: dir, now: () => DateTime.utc(2026, 8, 26))
          .sendMagicLink(
        email: 'sam@example.com',
        url: 'http://host:8080/auth/redeem?token=abc',
        expiresAt: DateTime.utc(2026, 8, 26, 0, 15),
      );

      final urls = linkFileFor('sam@example.com')
          .readAsLinesSync()
          .where((l) => l.startsWith('http'))
          .toList();
      expect(urls, ['http://host:8080/auth/redeem?token=abc']);
    });

    test('the documented command finds the URL in what this class writes', () {
      // **The check the prose version could never have.** README.md §4 used to
      // say "copy the URL (the third line)", and adding `Issued:` above made
      // that instruction wrong with no way for anything to notice — which is
      // the whole of task 11.37 item 5. The instruction is now
      // `scripts/dev_magic_link.sh`, so the agreement between the writer and
      // the reader is a thing a test can actually assert. If either side
      // changes shape, this fails here rather than on somebody's VM.
      FileEmailSender(directory: dir, now: () => DateTime.utc(2026, 8, 26))
          .sendMagicLink(
        email: 'sam@example.com',
        url: 'http://192.168.0.42:8080/auth/redeem?token=abc123',
        expiresAt: DateTime.utc(2026, 8, 26, 0, 15),
      );

      final script = File('../scripts/dev_magic_link.sh');
      if (!script.existsSync()) {
        fail(
          'scripts/dev_magic_link.sh is missing. README.md §4 tells the '
          'reader to run it instead of picking a line out of this file by '
          'hand; without it that instruction is broken.',
        );
      }

      final result = Process.runSync(
        'bash',
        [script.path, 'sam@example.com', '--url-only'],
        environment: {'TRITRACK_DEV_MAGIC_LINK_DIR': dir.path},
      );

      expect(
        result.exitCode,
        0,
        reason: 'stdout: ${result.stdout}\nstderr: ${result.stderr}',
      );
      expect(
        (result.stdout as String).trim(),
        'http://192.168.0.42:8080/auth/redeem?token=abc123',
      );
    });

    test('and it reports a missing file rather than printing nothing', () {
      // A silent empty result is how the rate limit used to present itself.
      final script = File('../scripts/dev_magic_link.sh');
      final result = Process.runSync(
        'bash',
        [script.path, 'nobody@example.com'],
        environment: {'TRITRACK_DEV_MAGIC_LINK_DIR': dir.path},
      );
      expect(result.exitCode, isNot(0));
      expect(result.stderr as String, contains('rate limit'));
    });

    test('the token is never written to stdout, only the path', () {
      // §4.7's never-log list, re-asserted here because this task edited the
      // one method that could break it.
      final printed = <String>[];
      runZoned(
        () => FileEmailSender(directory: dir).sendMagicLink(
          email: 'sam@example.com',
          url: 'http://host:8080/auth/redeem?token=SECRETTOKEN',
          expiresAt: DateTime.now().toUtc().add(const Duration(minutes: 15)),
        ),
        zoneSpecification: ZoneSpecification(
          print: (_, _, _, line) => printed.add(line),
        ),
      );
      expect(printed, isNotEmpty);
      expect(printed.join('\n'), isNot(contains('SECRETTOKEN')));
    });

    // Task 11.69. A failure to write the link is invisible everywhere else:
    // `AuthService` calls this fire-and-forget, and `auth_routes.dart`
    // swallows what it throws so that `/auth/magic-link` answers an identical
    // 202 whether or not delivery worked — §4.5, and correct, because a
    // response that varied would tell a caller which addresses are real.
    //
    // The cost of that showed up on the 2026-08-30 CI run: the link directory
    // was root-owned, no link was written, eleven gate instruments went red,
    // and neither the response nor the server's own log said anything. The
    // diagnosis has to go somewhere a caller cannot see and an operator can,
    // which is this container's stderr.
    group('when the write fails', () {
      late Directory locked;

      setUp(() {
        locked = Directory.systemTemp.createTempSync('tritrack-locked-');
        Process.runSync('chmod', ['500', locked.path]);
      });

      tearDown(() {
        Process.runSync('chmod', ['700', locked.path]);
        locked.deleteSync(recursive: true);
      });

      test('it says so, names the directory, and does not go quiet', () {
        final printed = <String>[];
        expect(
          () => runZoned(
            () => FileEmailSender(directory: locked).sendMagicLink(
              email: 'sam@example.com',
              url: 'http://host:8080/auth/redeem?token=SECRETTOKEN',
              expiresAt: DateTime.now().toUtc().add(
                const Duration(minutes: 15),
              ),
            ),
            zoneSpecification: ZoneSpecification(
              print: (_, _, _, line) => printed.add(line),
            ),
          ),
          throwsA(isA<FileSystemException>()),
          reason:
              'It must still throw. auth_routes.dart records outcome='
              '"internal_error" in the audit log on the strength of that, and '
              'a swallowed exception here would make the audit log say the '
              'link was sent.',
        );
        final output = printed.join('\n');
        expect(
          output,
          contains(locked.path),
          reason:
              'The one actionable fact is WHICH directory could not be written '
              'to — that is what tells an operator to look at its owner.',
        );
        expect(
          output.toLowerCase(),
          contains('not delivered'),
          reason: 'It has to be findable in a container log by reading it.',
        );
      });

      test('and it still never prints the token (§4.7)', () {
        final printed = <String>[];
        try {
          runZoned(
            () => FileEmailSender(directory: locked).sendMagicLink(
              email: 'sam@example.com',
              url: 'http://host:8080/auth/redeem?token=SECRETTOKEN',
              expiresAt: DateTime.now().toUtc().add(
                const Duration(minutes: 15),
              ),
            ),
            zoneSpecification: ZoneSpecification(
              print: (_, _, _, line) => printed.add(line),
            ),
          );
        } on FileSystemException {
          // expected
        }
        expect(printed, isNotEmpty, reason: 'silence is the defect');
        expect(printed.join('\n'), isNot(contains('SECRETTOKEN')));
        // The address is not in the diagnosis either. The success path prints
        // the full path, which contains it; the failure path deliberately
        // prints only the directory, so a run that fails for every address in
        // turn does not accumulate a list of addresses in the log.
        expect(printed.join('\n'), isNot(contains('sam@example.com')));
      });
    });
  });
}
