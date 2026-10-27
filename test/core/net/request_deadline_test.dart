import 'dart:async';
import 'dart:convert';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:tritrack/core/errors/transport_failure.dart';
import 'package:tritrack/core/net/request_deadline.dart';
import 'package:tritrack/core/providers/retry_policy.dart';
import 'package:tritrack/data/sync/sync_failure.dart';
import 'package:tritrack/data/sync/sync_transport.dart';

/// A client that does exactly what the thing this policy exists for does:
/// accepts the request and then answers, or goes quiet before answering, or
/// answers and then stops part way through.
class _StallingClient extends http.BaseClient {
  _StallingClient(this._behaviour);

  final Future<http.StreamedResponse> Function(http.BaseRequest) _behaviour;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      _behaviour(request);
}

/// A response whose body delivers [firstChunk] (if any) and then nothing ever
/// again, recording whether anybody cancelled it.
({http.StreamedResponse response, bool Function() wasCancelled})
_bodyThatStops({List<int>? firstChunk}) {
  var cancelled = false;
  late StreamController<List<int>> controller;
  controller = StreamController<List<int>>(
    onListen: () {
      if (firstChunk != null) controller.add(firstChunk);
    },
    onCancel: () => cancelled = true,
  );
  return (
    response: http.StreamedResponse(controller.stream, 200),
    wasCancelled: () => cancelled,
  );
}

/// The same two deadlines the app uses, in milliseconds.
///
/// **The numbers themselves are checked against [deadlinesFor] above.** What
/// this is for is the *behaviour* — which is identical at 40 ms and at 30 s,
/// and a suite that genuinely waited half a minute per case would be one nobody
/// runs.
const _fast = RequestDeadlines(
  firstResponse: Duration(milliseconds: 40),
  quiet: Duration(milliseconds: 40),
  kind: 'a small request',
);

http.Client _bounded(_StallingClient inner) =>
    withRequestDeadlines(inner, deadlines: (_) => _fast);

void main() {
  group('which deadlines apply', () {
    test('a sync page gets the generous one, on either route', () {
      for (final path in ['/sync/push', '/sync/pull']) {
        final deadlines = deadlinesFor(
          Uri.parse('https://server.example$path'),
        );
        expect(deadlines.firstResponse, kSyncPageDeadline);
        expect(deadlines.kind, 'a sync page');
      }
    });

    test('a base URL with a path prefix still resolves to a sync page', () {
      // The base URL is concatenated ahead of the route, and nothing stops a
      // server living under a prefix. Matched by suffix for exactly this.
      expect(
        deadlinesFor(
          Uri.parse('https://host.example/tritrack/sync/pull'),
        ).firstResponse,
        kSyncPageDeadline,
      );
    });

    test('everything else gets the small one, including a route nobody has '
        'thought about', () {
      const small = [
        '/auth/magic-link',
        '/auth/redeem',
        '/auth/sessions',
        '/auth/sessions/revoke-device',
        '/sync/ack',
        '/projects/mine',
        '/projects/join-requests',
        '/a/route/added/next/year',
      ];
      for (final path in small) {
        final deadlines = deadlinesFor(
          Uri.parse('https://server.example$path'),
        );
        expect(
          deadlines.firstResponse,
          kSmallRequestDeadline,
          reason: '$path should be bounded at 30 seconds',
        );
        expect(deadlines.kind, 'a small request');
      }
    });

    test('every request is bounded — there is no unbounded answer', () {
      // The default is the tight one, deliberately: a route added without a
      // decision fails visibly in half a minute rather than holding a screen
      // for five.
      expect(kSmallRequestDeadline, lessThan(kSyncPageDeadline));
      expect(kConnectDeadline, lessThan(kSmallRequestDeadline));
    });

    test('the sync page bound covers a real 500-row page on a slow link', () {
      // 617 KiB, measured on 2026-09-03 from observation-shaped rows carrying
      // every column of the Observations table. Pinned so that a change to the
      // batch size or the row shape has to re-examine the number rather than
      // quietly outgrow it.
      const pageBytes = 617 * 1024;
      final bitsPerSecond = pageBytes * 8 / kSyncPageDeadline.inSeconds;
      expect(
        bitsPerSecond,
        lessThan(20000),
        reason:
            'The sync-page deadline should not bite above roughly 20 kbit/s, '
            'which is below any link somebody could actually sync a season '
            'over. At 64 kbit/s the same page takes 79 seconds.',
      );
    });
  });

  group('a request that is given up on', () {
    test('a server that never answers: says which request and which half', () {
      final bounded = _bounded(
        _StallingClient((_) => Completer<http.StreamedResponse>().future),
      );

      expect(
        bounded.get(Uri.parse('https://server.example/auth/sessions')),
        throwsA(
          isA<RequestGaveUp>()
              .having((e) => e.method, 'method', 'GET')
              .having((e) => e.path, 'path', '/auth/sessions')
              .having((e) => e.kind, 'kind', 'a small request')
              .having(
                (e) => e.phase,
                'phase',
                RequestGaveUpAt.waitingForTheServer,
              )
              .having((e) => e.limit, 'limit', _fast.firstResponse),
        ),
      );
    });

    test('an answer that begins and then stops is given up on too', () {
      // **The case a total-duration cap would have got wrong in both
      // directions.** Bytes arrived, so this is not "nothing answered"; then
      // they stopped, and no wall-clock budget distinguishes that from a
      // transfer still making progress.
      final stopped = _bodyThatStops(firstChunk: utf8.encode('{"partial"'));
      final bounded = _bounded(_StallingClient((_) async => stopped.response));

      expect(
        bounded.get(Uri.parse('https://server.example/sync/pull')),
        throwsA(
          isA<RequestGaveUp>().having(
            (e) => e.phase,
            'phase',
            RequestGaveUpAt.partWayThroughTheAnswer,
          ),
        ),
      );
    });

    test('a slow but moving answer is never interrupted', () {
      // The whole reason this is an inactivity deadline and not a total one: a
      // first sync at a trailhead is slow *and progressing*, and that is the
      // case this app exists for.
      //
      // **Run on a fake clock, not real wall-clock time (task 11.208).** The
      // previous version fed a chunk every 30 ms against the 40 ms quiet
      // deadline in `_fast` — 75% of the budget consumed by test scheduling
      // alone — so a machine busy running the other 283 files in this suite
      // could genuinely fall behind and trip the deadline it was proving
      // never fires. `fakeAsync` makes every `Timer` and `Future.delayed` in
      // this zone advance on virtual time that this test controls directly,
      // so there is no longer a race with the host machine at any ratio: the
      // chunk interval below is now exactly what `async.elapse` says it is,
      // always. It is kept at 25% of the deadline (10 ms against 40 ms)
      // purely for readability — a comfortable margin for a human reading the
      // numbers, not a margin against flakiness, which the fake clock has
      // already removed.
      fakeAsync((async) {
        final chunks = StreamController<List<int>>();
        final bounded = _bounded(
          _StallingClient(
            (_) async => http.StreamedResponse(chunks.stream, 200),
          ),
        );

        final call = bounded.get(Uri.parse('https://server.example/sync/pull'));
        String? body;
        var failed = false;
        unawaited(
          call.then((r) => r.body).then((b) => body = b).catchError((_) {
            failed = true;
            return '';
          }),
        );

        // Ten chunks, each arriving at one-quarter of the quiet deadline —
        // ten times longer in total than any total-duration cap would allow.
        for (var i = 0; i < 10; i++) {
          async.elapse(const Duration(milliseconds: 10));
          chunks.add(utf8.encode('.'));
        }
        unawaited(chunks.close());
        async.elapse(const Duration(milliseconds: 10));
        async.flushMicrotasks();

        expect(failed, isFalse);
        expect(body, '..........');
      });
    });

    test('never carries the base URL toward the UI', () {
      // The same rule `SyncTransportException` and `AuthServerError` follow:
      // the path identifies the request, the host is the part a screen must
      // not echo back.
      const gaveUp = RequestGaveUp(
        method: 'POST',
        path: '/sync/push',
        kind: 'a sync page',
        phase: RequestGaveUpAt.waitingForTheServer,
        limit: kSyncPageDeadline,
      );
      expect(gaveUp.toString(), contains('/sync/push'));
      expect(gaveUp.toString(), contains('a sync page'));
      expect(gaveUp.toString(), contains('300s'));
      expect(gaveUp.toString(), isNot(contains('http')));
    });

    test('an answer that stops part way through is a different phase', () {
      const gaveUp = RequestGaveUp(
        method: 'POST',
        path: '/sync/pull',
        kind: 'a sync page',
        phase: RequestGaveUpAt.partWayThroughTheAnswer,
        limit: kQuietDeadline,
      );
      expect(gaveUp.toString(), contains('stopped part way through'));
    });
  });

  group('cancel, do not abandon', () {
    test('a body that goes quiet has its subscription cancelled', () async {
      // Cancelling the response subscription is what tears down the connection
      // on both `IOClient` and `CupertinoClient`. Without it the deadline would
      // only be a report.
      final stopped = _bodyThatStops(firstChunk: const [1, 2, 3]);
      final bounded = _bounded(_StallingClient((_) async => stopped.response));

      await expectLater(
        bounded.get(Uri.parse('https://server.example/sync/pull')),
        throwsA(isA<RequestGaveUp>()),
      );
      expect(
        stopped.wasCancelled(),
        isTrue,
        reason:
            'The response stream was abandoned rather than cancelled, so the '
            'connection under it is still open behind a caller that has given '
            'up.',
      );
    });

    test(
      'a response that lands after the deadline is drained and dropped',
      () async {
        // The send future cannot be cancelled, so this is the next best thing
        // that is actually true: nobody ever sees the response, and the socket it
        // is holding is released rather than kept alive behind a screen that has
        // moved on.
        final arrivesLate = Completer<http.StreamedResponse>();
        final bounded = _bounded(_StallingClient((_) => arrivesLate.future));

        await expectLater(
          bounded.get(Uri.parse('https://server.example/auth/sessions')),
          throwsA(isA<RequestGaveUp>()),
        );

        final stopped = _bodyThatStops(firstChunk: const [1]);
        arrivesLate.complete(stopped.response);
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(
          stopped.wasCancelled(),
          isTrue,
          reason:
              'The response the abandoned send eventually produced was left '
              'holding a socket behind a caller that had already given up.',
        );
      },
    );

    test('an answer that arrives in time is delivered untouched', () async {
      // The guard must be invisible when nothing goes wrong — a wrapper that
      // truncates or reorders a body would be a far worse defect than the one
      // it fixes.
      final bounded = _bounded(
        _StallingClient(
          (_) async => http.StreamedResponse(
            Stream.value(utf8.encode('{"sessions":[]}')),
            200,
            headers: const {'content-type': 'application/json'},
            reasonPhrase: 'OK',
          ),
        ),
      );

      final response = await bounded.get(
        Uri.parse('https://server.example/auth/sessions'),
      );
      expect(response.statusCode, 200);
      expect(response.body, '{"sessions":[]}');
      expect(response.headers['content-type'], 'application/json');
    });
  });

  group('a reached deadline is its own cause, everywhere it travels', () {
    test('the one classifier names it, and does not call it a certificate', () {
      const gaveUp = RequestGaveUp(
        method: 'GET',
        path: '/projects/mine',
        kind: 'a small request',
        phase: RequestGaveUpAt.waitingForTheServer,
        limit: kSmallRequestDeadline,
      );
      final failure = classifyTransportFailure(gaveUp);
      expect(failure, isNotNull);
      expect(failure!.cause, TransportFaultCause.timedOut);
      expect(
        failure.isCertificate,
        isFalse,
        reason:
            'isCertificate used to be "anything but unreachable", which would '
            'have made a timeout a certificate problem the day it was added.',
      );
    });

    test('it says the same thing to a person as nothing-answered does', () {
      // Deliberate: the remedy is the same three things, and task 11.61's whole
      // argument was that the honest states already written become reachable,
      // not that the app needs new ones.
      final timedOut = classifyTransportFailure(
        const RequestGaveUp(
          method: 'GET',
          path: '/projects/mine',
          kind: 'a small request',
          phase: RequestGaveUpAt.waitingForTheServer,
          limit: kSmallRequestDeadline,
        ),
      )!;
      expect(timedOut.explanation, unreachableExplanation);
    });

    test('the sync surface classifies it apart from unreachable', () {
      final refusal = SyncTransportException(
        SyncTransportException.requestTimedOut,
        transportFailure: classifyTransportFailure(
          const RequestGaveUp(
            method: 'POST',
            path: '/sync/push',
            kind: 'a sync page',
            phase: RequestGaveUpAt.waitingForTheServer,
            limit: kSyncPageDeadline,
          ),
        ),
      );
      expect(
        classifySyncFailure(refusal, departed: false),
        SyncFailureCause.timedOut,
      );
      expect(
        refusal.userMessage,
        isNull,
        reason:
            'No new user-visible copy. A null message renders exactly as an '
            'unreachable server does.',
      );
      expect(
        refusal.isTerminal,
        isFalse,
        reason: 'A server too slow once may not be next time.',
      );
    });

    test('its stored id survives a restart and is not any other cause', () {
      expect(SyncFailureCause.fromId('timed_out'), SyncFailureCause.timedOut);
      final ids = SyncFailureCause.values.map((c) => c.id).toList();
      expect(ids.toSet(), hasLength(ids.length));
    });
  });

  group('this does not undo task 11.107', () {
    test('a request that already spent its deadline is not retried', () {
      const gaveUp = RequestGaveUp(
        method: 'GET',
        path: '/auth/sessions',
        kind: 'a small request',
        phase: RequestGaveUpAt.waitingForTheServer,
        limit: kSmallRequestDeadline,
      );
      expect(
        appRetryPolicy(0, gaveUp),
        isNull,
        reason:
            'Retrying would have made a screen wait 30 + 0.4 + 30 + 1.2 + 30 = '
            '91.6 seconds before saying anything — worse than the 38 seconds '
            'task 11.107 existed to remove.',
      );
    });

    test('the same is true once it is wrapped by the sync transport', () {
      final wrapped = SyncTransportException(
        SyncTransportException.requestTimedOut,
        transportFailure: classifyTransportFailure(
          const RequestGaveUp(
            method: 'POST',
            path: '/sync/pull',
            kind: 'a sync page',
            phase: RequestGaveUpAt.partWayThroughTheAnswer,
            limit: kQuietDeadline,
          ),
        ),
      );
      expect(appRetryPolicy(0, wrapped), isNull);
    });

    test('everything else is still retried exactly as before', () {
      // The exclusion is one shape, not a growing list of types not worth
      // retrying — the list this policy's own note refuses to keep.
      expect(appRetryPolicy(0, Exception('a blip')), isNotNull);
      expect(
        appRetryPolicy(
          0,
          const SyncTransportException(SyncTransportException.unreachable),
        ),
        isNotNull,
      );
    });

    test(
      'the combined wait a person experiences is one attempt, not three',
      () {
        // The number written down in `request_deadline.dart`. If either half
        // changes, the total in that table has to be rewritten too.
        expect(kMaxAutomaticRetries, 2);
        expect(kSmallRequestDeadline, const Duration(seconds: 30));
        expect(kSyncPageDeadline, const Duration(minutes: 5));
      },
    );
  });
}
