/// **Every request this app sends to a server has a deadline, and this is the
/// only place one is chosen** (task 11.61).
///
/// ## The defect this closes
///
/// Until this file, **nothing this app sent could ever give up.** Task 11.36
/// measured it: not one call in the sign-in client or the sync transport was
/// bounded, and neither HTTP client set a limit of its own. A request to a
/// server that accepted the connection and then went quiet left the control
/// that started it disabled **for sixty seconds on an iPhone** — Apple's
/// `timeoutIntervalForRequest` default, the only thing ending it — **and
/// forever on Android, Windows and Linux**, where `dart:io` has no such
/// default at all.
///
/// **The cost was not untidiness. It was that every honest failure message
/// three separate tasks had just written was unreachable.** Task 11.122's
/// honest default, task 11.135's tile band, task 11.142's four sentences on
/// the Members screen, every state the sync bar can show — each of them is
/// what a *failed* request produces, and a request that cannot fail never
/// produces one. On the one path a field user meets most often, the app said
/// nothing and went on saying nothing.
///
/// ## What is bounded, and what deliberately is not
///
/// **Two deadlines, and neither is a cap on how long a transfer may take.**
/// A first sync of a season's data at a trailhead is slow *and progressing*,
/// and a wall-clock cap is precisely the thing that kills the case this app
/// exists for. What must fail is **no bytes at all.**
///
/// 1. **[RequestDeadlines.firstResponse] — the server has said nothing yet.**
///    Measured from the moment the request is handed to the client until its
///    response *headers* arrive. This covers connecting, sending the request,
///    and the server's own work; it does **not** cover receiving the body.
/// 2. **[kQuietDeadline] — the exchange stopped mid-flight.** An inactivity
///    deadline on the response body: the clock is reset by every byte that
///    arrives, so a download that is slow but moving is never interrupted, and
///    one that stops dead is.
///
/// **A 500-row sync page is 617 KiB on the wire** — measured on 2026-09-03
/// from observation-shaped rows carrying every column of the `Observations`
/// table, not estimated. That is 79 seconds of upload at 64 kbit/s and 158 at
/// 32 kbit/s, which is why a push cannot share the small-request deadline and
/// why [kSyncPageDeadline] is five minutes rather than one.
///
/// ## What the clients can and cannot express
///
/// The plan asked for this to be stated rather than assumed, so:
///
/// - **iOS and macOS can express a true inactivity deadline natively.**
///   `URLSessionConfiguration.timeoutIntervalForRequest` is documented as the
///   interval to wait *for additional data*, reset whenever more arrives, and
///   it covers the upload half as well as the download half. Set explicitly in
///   `server_http_client_provider.dart` so that what an iPhone already did by
///   default is now a declared choice.
/// - **`dart:io` cannot.** `HttpClient` has `connectionTimeout`, which bounds
///   only opening the socket, and `idleTimeout`, which is about pooled
///   keep-alive sockets and not about this at all. There is no read or write
///   inactivity setting. The download half is therefore guarded here in Dart,
///   which works identically on every platform; **the upload half of a push is
///   covered by [RequestDeadlines.firstResponse] as a total**, because
///   `package:http`'s `Client` gives no portable hook into a request body as
///   it drains. That is the one place this policy falls back to a total, and
///   it is stated rather than pretended.
///
/// ## Cancel; do not abandon
///
/// A request given up on but left running can complete later and write state
/// behind a screen that has moved on. So both deadlines **cancel**:
///
/// - The inactivity deadline cancels its subscription to the response stream,
///   which tears down the underlying connection on both clients.
/// - The first-response deadline cannot cancel a future, so it does the next
///   best thing that is actually true: it throws immediately, and when the
///   abandoned send eventually resolves it drains and cancels whatever it
///   produced. No caller ever sees that response. Underneath it,
///   `HttpClient.connectionTimeout` on `dart:io` and
///   `timeoutIntervalForRequest` on Apple cancel at the transport layer.
///
/// ## What a person waits, end to end
///
/// **Written down here rather than discovered**, because bounding a request
/// hands it to the retry machinery and that is how task 11.107's 1.6 seconds
/// could quietly become 90:
///
/// | path | worst case |
/// |---|---|
/// | a small request from a screen (sign-in, the device list, join settings) | **30 s** — one attempt; see below |
/// | a sync page that times out | **5 min**, then the schedule's own wait |
/// | the next automatic attempt after that, at the default cadence | **15 min** (task 11.59 made the chosen frequency a floor on backoff) |
///
/// **The 30 seconds is one attempt, not three, and that is a deliberate change
/// to `appRetryPolicy`.** Riverpod retries a failed provider, so a screen
/// awaiting a provider that makes one request would have waited
/// 30 + 0.4 + 30 + 1.2 + 30 = **91.6 seconds** — worse than the 38 seconds
/// task 11.107 existed to remove, and directly against that policy's own
/// stated promise of "under two seconds before the person is told something".
/// A request that has already spent a deadline finding out is not retried; see
/// `retry_policy.dart`.
library;

import 'dart:async';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:http/http.dart' as http;

/// How long to wait for a socket to open. **`dart:io` only** — applied as
/// `HttpClient.connectionTimeout`, which is the one part of this policy the
/// platform enforces itself on Android, Windows and Linux.
///
/// Well inside [kSmallRequestDeadline], so a connection that never opens is
/// reported as a connection that never opened rather than as a silent server.
const Duration kConnectDeadline = Duration(seconds: 15);

/// **Thirty seconds for a small request. Michael's figure, approved
/// 2026-08-29.** Sign-in, the session list, revocation, the sync
/// acknowledgement, the join routes, the project directory, a map tile.
///
/// Nothing legitimate on any of those takes longer, and somebody is watching a
/// screen while it happens.
const Duration kSmallRequestDeadline = Duration(seconds: 30);

/// **Five minutes for one sync page**, which is a generous bound rather than a
/// budget.
///
/// A page is at most 500 rows — `defaultSyncBatchSize` — and a 500-row page of
/// observations measures **617 KiB**. Five minutes covers
/// uploading that at roughly 17 kbit/s, far below any link a person could
/// actually sync a season over; at 64 kbit/s the same page takes 79 seconds and
/// is nowhere near this. So it bites only when a transfer has genuinely stopped
/// getting anywhere, which is the whole intent.
///
/// **Chunking is what makes a per-request bound sufficient.** A season of data
/// is tens of pages, each separately bounded and separately acknowledged, so
/// nothing here caps how long a whole sync may take.
const Duration kSyncPageDeadline = Duration(minutes: 5);

/// **How long a response may go completely quiet**, reset by every byte.
///
/// Sixty seconds, which is deliberately the number an iPhone has always used
/// (`timeoutIntervalForRequest`'s default) — this makes it a declared choice on
/// every platform instead of one platform's default and two platforms' nothing.
///
/// Longer than [kSmallRequestDeadline] on purpose: a small request's bodies are
/// a few hundred bytes and its first-response deadline is what governs it. This
/// exists for the large ones, where the server has already begun answering and
/// the question is whether the answer is still coming.
const Duration kQuietDeadline = Duration(seconds: 60);

/// The two deadlines that apply to one request, and the words for which kind of
/// request it is.
class RequestDeadlines {
  const RequestDeadlines({
    required this.firstResponse,
    required this.quiet,
    required this.kind,
  });

  /// The server has produced no response headers at all within this.
  final Duration firstResponse;

  /// The response body has delivered no bytes at all within this.
  final Duration quiet;

  /// What this request is, in plain words, for [RequestGaveUp] to report.
  final String kind;
}

const RequestDeadlines _small = RequestDeadlines(
  firstResponse: kSmallRequestDeadline,
  quiet: kQuietDeadline,
  kind: 'a small request',
);

const RequestDeadlines _syncPage = RequestDeadlines(
  firstResponse: kSyncPageDeadline,
  quiet: kQuietDeadline,
  kind: 'a sync page',
);

/// The two paths that move a page of rows rather than a handful of fields.
///
/// **Matched by suffix, not equality**, because a server address may carry a
/// path prefix and the base URL is concatenated ahead of these.
const List<String> kSyncPagePathSuffixes = ['/sync/push', '/sync/pull'];

/// Which deadlines apply to [url].
///
/// **The rule is two prefixes and a default, and the default is the tight
/// one.** A path nobody has thought about gets [kSmallRequestDeadline], so a
/// route added later without a decision fails visibly in half a minute rather
/// than holding a screen for five. If that route turns out to move a page, the
/// fix is to say so here — which is a decision somebody makes, not one they
/// inherit by omission.
///
/// **`/sync/ack` is deliberately small.** It carries row keys, not rows.
RequestDeadlines deadlinesFor(Uri url) {
  for (final suffix in kSyncPagePathSuffixes) {
    if (url.path.endsWith(suffix)) return _syncPage;
  }
  return _small;
}

/// Which half of the exchange had stopped when a request was given up on.
enum RequestGaveUpAt {
  /// Nothing came back at all — the connection, the upload, or the server's
  /// own work. Bounded by [RequestDeadlines.firstResponse].
  waitingForTheServer,

  /// The server began answering and then went quiet. Bounded by
  /// [RequestDeadlines.quiet].
  partWayThroughTheAnswer,
}

/// **A request that reached its deadline and was given up on.**
///
/// Names which request and why, per the standing rule of 2026-08-27, and is
/// deliberately **not** any of the causes task 11.54's classification already
/// had: it becomes `SyncFailureCause.timedOut` on the sync surface and
/// `TransportFaultCause.timedOut` in the one classifier, rather than being
/// folded into "nothing answered".
///
/// **Carries the path, never the full URL.** This string travels toward the UI
/// and toward `debugPrint`, and the base URL is the one part of a request a
/// screen must not echo back — the same rule `SyncTransportException` and
/// `AuthServerError` already follow.
class RequestGaveUp implements Exception {
  const RequestGaveUp({
    required this.method,
    required this.path,
    required this.kind,
    required this.phase,
    required this.limit,
  });

  /// `GET`, `POST` — the HTTP method, which is not sensitive and is half of
  /// what identifies the request in a log line.
  final String method;

  /// The request path. **Not the base URL.** See the class note.
  final String path;

  /// Which class of deadline applied — see [RequestDeadlines.kind].
  final String kind;

  final RequestGaveUpAt phase;

  /// The deadline that was reached.
  final Duration limit;

  /// Plain English, and it says which request and why.
  ///
  /// This is what reaches `debugPrint` on the screens that log a failure, and
  /// it is the whole of "a request that gives up must name itself".
  @override
  String toString() {
    final where = switch (phase) {
      RequestGaveUpAt.waitingForTheServer =>
        'the server sent nothing back within',
      RequestGaveUpAt.partWayThroughTheAnswer =>
        'the answer stopped part way through and nothing more arrived within',
    };
    return 'RequestGaveUp: $method $path ($kind) — $where '
        '${limit.inSeconds}s, so this device stopped waiting and closed it.';
  }
}

/// Wraps [inner] so that every request through it carries [deadlinesFor]'s
/// deadlines.
///
/// **The whole app's traffic goes through one of these**, because
/// `createPlatformHttpClient` returns one and nothing else builds a client for
/// the server. See `server_http_client_provider.dart`.
///
/// [deadlines] exists so the behaviour can be exercised in milliseconds rather
/// than by a test suite that genuinely waits half a minute — the numbers
/// themselves are checked against [deadlinesFor] directly. **Nothing in `lib/`
/// passes it**, and a request in the running app is bounded by the policy or by
/// nothing.
http.Client withRequestDeadlines(
  http.Client inner, {
  @visibleForTesting RequestDeadlines Function(Uri)? deadlines,
}) => _DeadlineHttpClient(inner, deadlines ?? deadlinesFor);

class _DeadlineHttpClient extends http.BaseClient {
  _DeadlineHttpClient(this._inner, this._deadlinesFor);

  final http.Client _inner;
  final RequestDeadlines Function(Uri) _deadlinesFor;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final deadlines = _deadlinesFor(request.url);
    final method = request.method;
    final path = request.url.path;

    final pending = _inner.send(request);
    final http.StreamedResponse response;
    try {
      response = await pending.timeout(deadlines.firstResponse);
    } on TimeoutException {
      // **Cancel, do not abandon.** The future cannot be cancelled, so the
      // response it eventually produces is drained and dropped: no caller ever
      // sees it, and the socket is released rather than held open behind a
      // screen that has moved on.
      unawaited(pending.then(_discard, onError: (Object _) {}));
      throw RequestGaveUp(
        method: method,
        path: path,
        kind: deadlines.kind,
        phase: RequestGaveUpAt.waitingForTheServer,
        limit: deadlines.firstResponse,
      );
    }
    return http.StreamedResponse(
      _guardAgainstSilence(
        response.stream,
        deadlines.quiet,
        () => RequestGaveUp(
          method: method,
          path: path,
          kind: deadlines.kind,
          phase: RequestGaveUpAt.partWayThroughTheAnswer,
          limit: deadlines.quiet,
        ),
      ),
      response.statusCode,
      contentLength: response.contentLength,
      request: response.request,
      headers: response.headers,
      isRedirect: response.isRedirect,
      persistentConnection: response.persistentConnection,
      reasonPhrase: response.reasonPhrase,
    );
  }

  @override
  void close() => _inner.close();

  static Future<void> _discard(http.StreamedResponse response) async {
    try {
      await response.stream.listen(null).cancel();
    } catch (_) {
      // Discarding a response nobody is waiting for must not itself become a
      // failure somebody sees.
    }
  }
}

/// [source], but failing with [gaveUp] if it goes [quiet] without a byte.
///
/// **Written out rather than using `Stream.timeout`** for one reason: the
/// acceptance criterion is that a request is cancelled and not merely
/// abandoned, and this needs to hold the subscription in order to cancel it.
/// Cancelling the response subscription is what closes the connection on both
/// `IOClient` and `CupertinoClient`.
///
/// The clock is armed when the first listener arrives and re-armed on every
/// chunk, so a slow-but-moving transfer is never interrupted — the point of an
/// inactivity deadline rather than a total one.
Stream<List<int>> _guardAgainstSilence(
  Stream<List<int>> source,
  Duration quiet,
  RequestGaveUp Function() gaveUp,
) {
  final controller = StreamController<List<int>>();
  StreamSubscription<List<int>>? subscription;
  Timer? clock;

  void stopClock() {
    clock?.cancel();
    clock = null;
  }

  void armClock() {
    stopClock();
    clock = Timer(quiet, () async {
      final live = subscription;
      subscription = null;
      // Cancel first, so the connection is gone before anybody is told about
      // it — the order that makes "cancelled, not abandoned" true rather than
      // merely intended.
      await live?.cancel();
      if (controller.isClosed) return;
      controller.addError(gaveUp(), StackTrace.current);
      await controller.close();
    });
  }

  controller
    ..onListen = () {
      armClock();
      subscription = source.listen(
        (chunk) {
          armClock();
          controller.add(chunk);
        },
        onError: (Object error, StackTrace stackTrace) {
          stopClock();
          controller.addError(error, stackTrace);
        },
        onDone: () {
          stopClock();
          subscription = null;
          controller.close();
        },
        cancelOnError: false,
      );
    }
    ..onPause = () {
      subscription?.pause();
    }
    ..onResume = () {
      subscription?.resume();
    }
    ..onCancel = () async {
      stopClock();
      final live = subscription;
      subscription = null;
      await live?.cancel();
    };

  return controller.stream;
}
