/// **A request is bounded by the policy, or it is not bounded** (task 11.61).
///
/// ## The defect this exists to keep closed
///
/// Until task 11.61 nothing this app sent to a server could give up. What it
/// had instead were four hand-written `.timeout()` calls that the plan believed
/// were request timeouts — and **three of the four were not requests at all.**
/// One bounded how long a queue could be held, one a GPS fix, one an isolate
/// computation, and the fourth was a doc comment saying no timeout existed.
/// That is the shape this check is for: **a deadline written at a call site
/// looks exactly like a policy from a distance, and nobody re-reads it.**
///
/// So `.timeout(` in `lib/` is now an answerable question rather than a habit.
/// Every occurrence is either the policy itself or **on the list below with a
/// reason somebody had to write** — the same shape as
/// `invitation_vocabulary_test.dart`, which this project already points the
/// next "we replaced X but X keeps turning up" task at.
///
/// ## What this catches, and what it does not
///
/// **It catches the regression that matters**: somebody bounding one request by
/// hand instead of at the seam, which is how a policy and four survivors
/// happened the first time.
///
/// **It catches an unbounded request too**, from the other side: the second
/// test below reads every way `lib/` can reach the network and requires each
/// one to go through the policy. A client that is not wrapped is the only way
/// a request escapes it, and *that* has syntax even though "has no deadline"
/// does not.
///
/// **It is textual and comment-stripped**, so the several doc comments that now
/// discuss `.timeout()` in prose — including this file's own subject — do not
/// trip it.
library;

import 'package:flutter_test/flutter_test.dart';

import '../support/dart_source.dart';

/// The file that owns request deadlines. `.timeout()` belongs here.
const String _thePolicy = 'lib/core/net/request_deadline.dart';

/// Deadlines in `lib/` that are **not** on a request, each with the reason it
/// is not the policy's business.
///
/// **An explicit, reasoned allowlist, not a list of known offenders.** Both of
/// these bound something happening on this device, where no server is involved
/// and the policy has nothing to say. Adding to it should feel like an argument
/// somebody makes, which is the whole mechanism.
const Map<String, String> _notARequest = {
  'lib/features/more/screens/project_setup_screen.dart':
      'A GPS fix. A satellite fix can legitimately never arrive, and the '
      'timeout is what turns "never" into a sentence on screen. No server '
      'is involved.',
  'lib/features/map/screens/map_screen.dart':
      'A viewshed computation running in an isolate on this device. Bounded '
      'so an underestimated cost cannot leave "Computing viewshed…" on '
      'screen forever. No server is involved.',
};

/// The one file allowed to build a platform HTTP client.
///
/// It is the seam `createPlatformHttpClient` lives at, and everything it
/// returns is already wrapped. See `server_http_client_provider.dart`.
const String _thePlatformSeam =
    'lib/core/providers/server_http_client_provider.dart';

/// Ways `lib/` can reach the network without a client of its own — every one of
/// these builds and closes a throwaway client internally, with no limit set.
///
/// **`http.get` is how every basemap tile was fetched until task 11.61**, on a
/// path where a host that accepted the connection and went quiet held the image
/// stream open forever *and* left the map's tile-health band silent, because
/// that band is only ever told about a failure.
const List<String> _topLevelHttpCalls = [
  'http.get(',
  'http.post(',
  'http.put(',
  'http.patch(',
  'http.delete(',
  'http.head(',
  'http.read(',
  'http.readBytes(',
];

void main() {
  test('every .timeout() in lib/ is the policy or is argued for', () {
    final unexplained = <String>[];

    for (final file in dartFilesUnder('lib')) {
      final path = file.path;
      if (path == _thePolicy) continue;
      final source = stripComments(file.readAsStringSync());
      final match = RegExp(r'\.timeout\s*\(').firstMatch(source);
      if (match == null) continue;
      if (_notARequest.containsKey(path)) continue;
      final line = '\n'.allMatches(source.substring(0, match.start)).length + 1;
      unexplained.add('$path:$line');
    }

    expect(
      unexplained,
      isEmpty,
      reason:
          'A deadline is being written at a call site instead of by the '
          'policy.\n\n'
          'If it is on a request to a server, delete it: every request the app '
          'sends is already bounded in $_thePolicy, at the one seam that '
          'builds the client. A second deadline beside it is the '
          'hand-maintained list this project names oftenest — and the last '
          'four of them turned out to bound a queue, a GPS fix, an isolate and '
          'nothing at all.\n\n'
          'If it is genuinely not a request, add it to _notARequest here with '
          'the reason, and say the same thing beside the code.\n\n'
          '${unexplained.join('\n')}',
    );
  });

  test('the policy this check protects still exists', () {
    // **A check that cannot distinguish success from its own failure is not a
    // check.** Deleting or moving the policy file would leave the test above
    // passing on a codebase with no request deadlines in it at all, reading as
    // "all clear" to the next person — the same trap
    // `one_transport_classifier_test.dart` guards against, for the same reason.
    final policy = dartFilesUnder('lib').where((f) => f.path == _thePolicy);
    expect(
      policy,
      isNotEmpty,
      reason:
          '$_thePolicy is gone. Either it moved — update _thePolicy here — or '
          'every request this app makes is unbounded again.',
    );
    final source = policy.single.readAsStringSync();
    expect(
      source,
      contains('http.Client withRequestDeadlines('),
      reason:
          'The one entry point is missing, so nothing is wrapping the client '
          'even if the file is still here.',
    );
  });

  test('every allowlisted file still has the deadline it was excused for', () {
    // A reason left behind for code that has gone is the stale-entry class this
    // project keeps finding: the allowlist would quietly grow permission for a
    // *future* `.timeout()` in that file that nobody argued for.
    for (final entry in _notARequest.entries) {
      final files = dartFilesUnder('lib').where((f) => f.path == entry.key);
      expect(
        files,
        isNotEmpty,
        reason:
            '${entry.key} is on the allowlist and does not exist. Remove the '
            'entry.',
      );
      expect(
        stripComments(files.single.readAsStringSync()),
        matches(RegExp(r'\.timeout\s*\(')),
        reason:
            '${entry.key} is excused from the request-deadline policy and no '
            'longer has a .timeout() at all. Remove the entry, so the excuse '
            'cannot silently cover something written later.',
      );
    }
  });

  test('no request in lib/ can escape the policy', () {
    // **The derivation, run across every file rather than the ones somebody
    // suspects.** There are exactly three ways to reach the network from Dart
    // here — build a client, build a platform client, or call one of
    // `package:http`'s top-level helpers — and each has an answer.
    final escapes = <String>[];

    for (final file in dartFilesUnder('lib')) {
      final path = file.path;
      final source = stripComments(file.readAsStringSync());

      // 1. A client built by hand must be wrapped where it is built, so the
      //    wrapping is visible in the same expression rather than trusted to
      //    happen somewhere else.
      for (final match in RegExp(r'http\.Client\(\)').allMatches(source)) {
        final before = source.substring(0, match.start);
        if (before.endsWith('withRequestDeadlines(')) continue;
        final line = '\n'.allMatches(before).length + 1;
        escapes.add('$path:$line — an http.Client() that nothing wraps');
      }

      // 2. A platform client (NSURLSession or dart:io) belongs to the one seam
      //    that configures its native deadlines and wraps the result.
      if (path != _thePlatformSeam) {
        for (final token in const ['IOClient(', 'CupertinoClient.']) {
          final at = source.indexOf(token);
          if (at < 0) continue;
          final line = '\n'.allMatches(source.substring(0, at)).length + 1;
          escapes.add('$path:$line — builds $token outside $_thePlatformSeam');
        }
      }

      // 3. The top-level helpers build a client internally and there is nothing
      //    to wrap, so they are simply out.
      for (final call in _topLevelHttpCalls) {
        final at = source.indexOf(call);
        if (at < 0) continue;
        final line = '\n'.allMatches(source.substring(0, at)).length + 1;
        escapes.add('$path:$line — calls $call, which builds its own client');
      }
    }

    expect(
      escapes,
      isEmpty,
      reason:
          'A request can be made that no deadline applies to.\n\n'
          'Before task 11.61 that was every request the app made: a server '
          'that accepted the connection and then went quiet held the control '
          'that started it for sixty seconds on an iPhone and forever on '
          'Android, Windows and Linux — and every honest failure message the '
          'app has is unreachable until a request can fail.\n\n'
          'Wrap it: withRequestDeadlines(http.Client()), or take the client '
          'from serverHttpClientProvider if it is talking to the server.\n\n'
          '${escapes.join('\n')}',
    );
  });
}
