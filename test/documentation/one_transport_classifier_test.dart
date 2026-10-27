import 'package:flutter_test/flutter_test.dart';

import '../support/dart_source.dart';

/// **Only one place in `lib/` may decide why a request failed** (task 11.113).
///
/// ## The defect
///
/// Michael pointed the app at a server presenting a self-signed certificate.
/// Safari, on the same phone, said *"this connection is not private — this
/// website may be impersonating…"*, so the server was reachable and the
/// certificate was genuinely rejected. Tapping **Sync now** produced
/// **"Offline"** — while the app's own Server Connection screen, two taps
/// away, named the certificate correctly.
///
/// Two classifiers, one question, and only one of them had ever been taught
/// anything.
///
/// ## Why a check and not a fourth fix
///
/// This was **the fourth instance of one class in a week.** Task 11.104 fixed
/// a refusal reported as a network fault on the server screen; 11.108 found a
/// second exception reaching the same catch-all; 11.112 found a third route on
/// a different HTTP client. Each fix was correct. None of them fixed the
/// class, because the class is that *a cause is decided in more than one
/// place*, and every one of those fixes made the second place a little
/// better-informed than the first.
///
/// ## The rule
///
/// A transport exception type — the exception an HTTP client raises when a
/// request never produced a response — may be **named in exactly one file**:
/// [_theClassifier]. Everything else consumes [_theClassifier]'s answer.
///
/// ## What this would have caught, and what it would not
///
/// **It would have caught this one.** Not on the day Michael found it, but
/// earlier and better: it goes red the moment a *second* file names one of
/// these types, which is task 11.108, when `HandshakeException` was added to
/// `server_config_screen.dart`. The forced fix then is the fix now — put the
/// classification somewhere both surfaces can reach — and the sync bar would
/// have inherited certificates without anybody thinking about sync at all.
///
/// **It would have caught 11.112 the same way**, which is the same shape one
/// platform over.
///
/// **It would not have caught the original absence.** If the app had had one
/// classifier from the start and simply never learned about certificates,
/// every file would still name zero transport types and this check would be
/// green. No check catches "nobody thought of TLS"; what it catches is the
/// divergence *after* somebody does.
///
/// **It does not catch a surface classifying by other means.** A screen that
/// branched on `error.toString().contains('certificate')`, or on a status
/// code, or on the text of a message, would pass. Those are different shapes
/// and none of them has occurred here yet; this closes the one that has
/// occurred four times.
///
/// **It is textual.** It reads the same source a person would, with comments
/// stripped, so a type named only in prose does not trip it.
const String _theClassifier = 'lib/core/errors/transport_failure.dart';

/// The exception types that mean "this request never produced a response".
///
/// Each has already been the subject of its own task on this project, which is
/// why the list is these and not a guess: `HandshakeException` (11.108),
/// `NSErrorClientException` (11.112), `SocketException` and
/// `http.ClientException` (11.37, 11.104).
const List<String> _transportExceptionTypes = [
  'HandshakeException',
  'CertificateException',
  'NSErrorClientException',
  'SocketException',
  'ClientException',
];

void main() {
  test('only one file in lib/ names a transport exception type', () {
    final offenders = <String>[];

    for (final file in dartFilesUnder('lib')) {
      final path = file.path;
      if (path == _theClassifier) continue;
      final source = stripComments(file.readAsStringSync());
      for (final type in _transportExceptionTypes) {
        // A word boundary on both sides, so `ClientException` does not match
        // inside `NSErrorClientException` and produce two reports of one line.
        final named = RegExp(r'(?<![\w$])' + type + r'(?![\w$])');
        if (!named.hasMatch(source)) continue;
        final line =
            '\n'
                .allMatches(
                  source.substring(0, named.firstMatch(source)!.start),
                )
                .length +
            1;
        offenders.add('$path:$line — names $type');
      }
    }

    expect(
      offenders,
      isEmpty,
      reason:
          'A second place in lib/ is deciding why a request failed.\n\n'
          'That is the defect task 11.113 exists to close: the app had two '
          'classifiers for one question, the sync bar said "Offline" about a '
          'server whose certificate this device had refused, and the server '
          'screen — correct, and taught by three consecutive tasks — said so '
          'by name at the same moment.\n\n'
          'Call classifyTransportFailure() from $_theClassifier instead, and '
          'add the cause there if it does not have one yet. Every surface '
          'consumes that answer, so teaching it once teaches all of them.\n\n'
          '${offenders.join('\n')}',
    );
  });

  test('the classifier this check protects still exists', () {
    // **A check that cannot distinguish success from its own failure is not a
    // check.** Renaming or deleting `transport_failure.dart` would leave the
    // test above passing on a codebase with no classifier in it at all —
    // silently, and reading as "all clear" to the next person.
    final classifier = dartFilesUnder(
      'lib',
    ).where((f) => f.path == _theClassifier);
    expect(
      classifier,
      isNotEmpty,
      reason:
          '$_theClassifier is gone. Either it moved — update _theClassifier '
          'here — or the single classifier this check exists to protect has '
          'been dismantled.',
    );
    final source = classifier.single.readAsStringSync();
    expect(
      source,
      contains('TransportFailure? classifyTransportFailure('),
      reason:
          'The one exported entry point is missing. Surfaces that used to call '
          'it will have grown their own classification back.',
    );
    for (final type in _transportExceptionTypes.where(
      (t) => t != 'CertificateException',
    )) {
      expect(
        stripComments(source),
        contains(type),
        reason:
            'The classifier no longer handles $type, so some surface is '
            'either failing to name that cause or naming it somewhere else.',
      );
    }
  });
}
