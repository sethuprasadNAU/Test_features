import 'package:flutter_test/flutter_test.dart';
import 'package:tritrack/core/errors/failure_message.dart';
import 'package:tritrack/data/sync/sync_transport.dart';

/// **Task 11.105 follow-up — the seam that decides what a person is told.**
///
/// `describeFailure` exists so that no screen has to choose between showing a
/// raw exception and throwing away a sentence this app wrote on purpose. Both
/// halves are defects: the first is what Michael asked for a check about, and
/// the second is the wrong-cause class task 11.104 spent a whole task on.
///
/// So this file tests both directions, and holds the list of "types with a
/// message written for a person" to the three-point bar its own doc sets.
void main() {
  const fallback = 'Could not do the thing. Nothing was lost. Try again.';

  group('an exception this app did not author never reaches a person', () {
    test('a database error, with its SQL and its bound values, does not', () {
      // The literal shape from the CSV import defect. Not a real sqflite
      // object — the point is that an arbitrary `toString()` is discarded, and
      // a stand-in proves that better than a real one, because a real one
      // could pass by being recognised rather than by being ignored.
      final dbError = _Opaque(
        "DatabaseException(UNIQUE constraint failed: Tags.tag_id) sql "
        "'INSERT INTO Tags (tag_id, tag_name, frequency_mhz) VALUES (?, ?, ?)' "
        "args [f4a2-9c1, Collar 12, 150.520]",
      );

      final shown = describeFailure(dbError, fallback: fallback);

      expect(shown, fallback);
      expect(shown, isNot(contains('INSERT')));
      expect(shown, isNot(contains('Collar 12')));
      expect(shown, isNot(contains('150.520')));
    });

    test('a plain Exception, an Error, and null all get the fallback', () {
      expect(describeFailure(Exception('boom'), fallback: fallback), fallback);
      expect(describeFailure(StateError('boom'), fallback: fallback), fallback);
      expect(describeFailure(null, fallback: fallback), fallback);
    });

    test('an error a provider boundary destroyed gets the fallback', () {
      // Riverpod's stand-in for an error it threw away. There is nothing to
      // consult, so the only honest answer is the caller's own sentence —
      // naming a cause here is exactly the defect task 11.104 corrected.
      final destroyed = StateError(
        'The provider gpsPositionProvider was disposed during loading state, '
        'yet no value could be emitted.',
      );
      expect(describeFailure(destroyed, fallback: fallback), fallback);
    });
  });

  group('a sentence this app wrote for a person is not thrown away', () {
    test('SyncTransportException surfaces its userMessage', () {
      // `isSessionEnded` keys on the HTTP status, not the reason string — the
      // server deliberately keeps a 401's body uninformative (§4.13), so the
      // status is the only thing that identifies it.
      const ended = SyncTransportException('unauthorized', statusCode: 401);

      final shown = describeFailure(ended, fallback: fallback);

      expect(shown, isNot(fallback));
      expect(shown, ended.userMessage);
      expect(shown, contains('signed out'));
    });

    test('a refusal with nothing specific to say falls back rather than '
        'showing a reason code', () {
      // `userMessage` is null exactly when there is no useful sentence. The
      // failure mode being guarded is rendering `server_rejected` — a code,
      // naming nothing — which is what task 11.46 found on the publish path.
      const opaque = SyncTransportException('some_unknown_reason');

      expect(opaque.userMessage, isNull, reason: 'fixture assumption');
      expect(describeFailure(opaque, fallback: fallback), fallback);
    });

    test('a refused server address still reaches a person, by the value path',
        () {
      // `InvalidServerUrl` is deliberately **not** on the authored list — see
      // the note in `failure_message.dart`. It is thrown inside an autoDispose
      // provider and destroyed there, so an extractor for it would be dead
      // code, and task 11.105's guard rejects one.
      //
      // What matters is that the fact still arrives. It does, twice over: as a
      // value from `serverUrlRefusalProvider`, and — for anything that went
      // through sync — on the refusal below.
      const refused = SyncTransportException(
        SyncTransportException.serverAddressRefused,
      );

      final shown = describeFailure(refused, fallback: fallback);

      expect(shown, isNot(fallback));
      expect(shown, contains('Server Connection'));
      expect(shown, isNot(contains('InvalidServerUrl')));
    });
  });

  group('the authored-message list is held to its own bar', () {
    // `failure_message.dart` states three requirements for joining the list.
    // A list whose entries are only checked by the person who added them is a
    // hand-maintained list wearing a different hat.

    /// Every message the list can produce, from real exception objects.
    List<String> everyAuthoredMessage() {
      final candidates = <Object>[
        const SyncTransportException('unauthorized', statusCode: 401),
        const SyncTransportException(
          SyncTransportException.serverAddressRefused,
        ),
        // Task 11.307: a route the server does not offer.
        const SyncTransportException(
          SyncTransportException.routeNotOffered,
          statusCode: 404,
        ),
      ];
      final out = <String>[];
      for (final e in candidates) {
        for (final extractor in authoredMessageExtractorsForTest) {
          final m = extractor(e);
          if (m != null && m.isNotEmpty) out.add(m);
        }
      }
      return out;
    }

    test('the fixtures actually exercise every extractor', () {
      // Without this, a new extractor could be added and the three checks
      // below would keep passing while never touching it.
      expect(
        everyAuthoredMessage(),
        hasLength(greaterThanOrEqualTo(authoredMessageExtractorsForTest.length)),
        reason:
            'An extractor was added to _authoredMessages with no fixture here, '
            'so the bar below is not being applied to it. Add an exception of '
            'that type to `candidates`.',
      );
    });

    test('no authored message carries an identifier or a class name', () {
      final uuid = RegExp(
        r'[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-'
        r'[0-9a-fA-F]{4}-[0-9a-fA-F]{12}',
      );
      for (final message in everyAuthoredMessage()) {
        expect(
          uuid.hasMatch(message),
          isFalse,
          reason: 'contains a UUID: "$message"',
        );
        expect(
          RegExp(r'\b\w+Exception\b|\bSQL\b|\bINSERT\b|\bSELECT\b')
              .hasMatch(message),
          isFalse,
          reason: 'reads like a log line, not a sentence: "$message"',
        );
      }
    });

    test('every authored message is prose a person could read', () {
      // **Deliberately not a keyword search for "try again".** The first draft
      // of this test looked for a verb from a fixed list and failed the
      // `InvalidServerUrl` message, which says "Use an https:// address
      // instead" and then gives two ways to get one — a better next step than
      // anything on the list. A check keyed on a phrase somebody typed is a
      // hand-maintained list wearing a different hat, and it would have been
      // "fixed" by padding real sentences with the magic words.
      //
      // So this asserts only what a machine can honestly judge: finished
      // sentences, of a length that cannot be a bare reason code. **Whether a
      // message ends with something a person can act on needs a human reader**
      // — that judgement lives in the review of `failure_message.dart`'s bar,
      // and in the messages' own tests where they are authored.
      for (final message in everyAuthoredMessage()) {
        expect(
          message.trim(),
          endsWith('.'),
          reason: 'not a finished sentence: "$message"',
        );
        expect(
          message.trim().length,
          greaterThan(40),
          reason:
              'too short to be an explanation — this is the shape of a reason '
              'code leaking through: "$message"',
        );
        expect(
          message,
          contains(' '),
          reason: 'a single token is a code, not a message: "$message"',
        );
      }
    });
  });
}

/// An error whose `toString()` is arbitrary text, standing in for anything the
/// app did not author — sqflite, `dart:io`, a plugin.
class _Opaque implements Exception {
  const _Opaque(this.text);
  final String text;
  @override
  String toString() => text;
}
