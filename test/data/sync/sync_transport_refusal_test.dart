import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tritrack/data/sync/sync_failure.dart';
import 'package:tritrack/data/sync/sync_transport.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

/// Task 10.11: a refusal has to *survive the transport* to be actionable.
///
/// The server has emitted `{"error": ...}` bodies since 10.7, and the client
/// discarded them — every non-200 became `server_rejected` plus a status code.
/// The policy was implemented on one side and thrown away on the other, which
/// is indistinguishable from not having implemented it. These tests pin the
/// decoding down so it cannot silently regress to that.
///
/// The tile on the More tab that the stale-cursor sentence sends a person to
/// (task 11.299) — asserted both in the sentence and in the screen's source.
const _exportTileLabel = 'Data Export / Backup';

void main() {
  HttpSyncTransport transportReturning(
    http.Response Function(http.Request request) respond,
  ) => HttpSyncTransport(
    httpClient: MockClient((request) async => respond(request)),
    baseUrl: 'http://server.test',
    sessionToken: 'token',
  );

  http.Response refusal(int status, Map<String, Object?> body) => http.Response(
    jsonEncode(body),
    status,
    headers: const {'content-type': 'application/json'},
  );

  /// A well-formed 200 pull response, with the envelope versions dialable.
  http.Response pullBody({int? schemaVersion, int? schemaMajor}) =>
      http.Response(
        jsonEncode({
          'envelope': kSyncEnvelopeId,
          'protocol_version': syncProtocolVersion,
          'schema_version': schemaVersion ?? latestSchemaVersion,
          'schema_major': schemaMajor ?? schemaMajorVersion,
          'rows': <String, Object?>{},
          'next_cursor': 0,
          'remaining': 0,
        }),
        200,
        headers: const {'content-type': 'application/json'},
      );

  SyncPullRequest pullRequest({int cursor = 10}) => SyncPullRequest(
    projectId: 'project-1',
    deviceId: 'device-1',
    cursor: cursor,
    batchSize: defaultSyncBatchSize,
  );

  group('version skew refusals reach the caller intact', () {
    test('a schema mismatch keeps its code and version numbers', () async {
      final transport = transportReturning(
        (_) => refusal(409, {
          'error': 'schema_version_mismatch',
          'client_schema_version': 5,
          'server_schema_version': 6,
        }),
      );

      await expectLater(
        transport.pull(pullRequest()),
        throwsA(
          isA<SyncTransportException>()
              .having((e) => e.reason, 'reason', syncRefusalSchemaVersion)
              .having((e) => e.isTerminal, 'isTerminal', isTrue)
              .having((e) => e.appIsBehindServer, 'appIsBehindServer', isTrue),
        ),
      );
    });

    test('the message names the right party to update', () async {
      // Getting this backwards sends a field tech to update an app that is
      // already current while the server is the stale one — the unactionable
      // message the task explicitly rules out.
      final appBehind = transportReturning(
        (_) => refusal(409, {
          'error': 'schema_version_mismatch',
          'client_schema_version': 5,
          'server_schema_version': 6,
        }),
      );
      try {
        await appBehind.pull(pullRequest());
        fail('expected a refusal');
      } on SyncTransportException catch (error) {
        expect(error.userMessage, contains('Update the app'));
        expect(error.userMessage, isNot(contains('server needs to update')));
      }

      final serverBehind = transportReturning(
        (_) => refusal(409, {
          'error': 'schema_version_mismatch',
          'client_schema_version': 6,
          'server_schema_version': 5,
        }),
      );
      try {
        await serverBehind.pull(pullRequest());
        fail('expected a refusal');
      } on SyncTransportException catch (error) {
        expect(error.userMessage, contains('server'));
        expect(error.userMessage, isNot(contains('Update the app')));
      }
    });

    test('a v15 app against a v16 server — task 11.242\'s bump — is refused '
        'cleanly, with a sentence a person can act on', () async {
      // The literal numbers on purpose. Task 11.240 made `Tags.color_hex`
      // nullable and left the major at 3, so a v15 phone and a v16 server
      // agreed they were compatible and the phone then failed at its own
      // database on the first tag row, forever, blaming itself
      // (`v15_device_meets_v16_row_test.dart`). Task 11.242 moved the major
      // to 4 so that the same phone is *refused* — and this is what it reads.
      // The server's 409 carries both sides; the client picks its own words.
      final v15App = transportReturning(
        (_) => refusal(409, {
          'error': 'schema_version_mismatch',
          'client_schema_version': 15,
          'server_schema_version': 16,
          'client_schema_major': 3,
          'server_schema_major': 4,
        }),
      );
      try {
        await v15App.pull(pullRequest());
        fail('expected a refusal');
      } on SyncTransportException catch (error) {
        expect(error.reason, syncRefusalSchemaVersion);
        expect(error.isTerminal, isTrue, reason: 'retrying changes nothing');
        expect(error.appIsBehindServer, isTrue);
        expect(
          error.userMessage,
          'This version of TriTrack is too old to sync with the server. '
          'Update the app to continue syncing. Nothing on this device has '
          'been changed or lost.',
        );
        expect(
          classifySyncFailure(error, departed: false),
          SyncFailureCause.refusedWithRemedy,
          reason: 'not a device fault, not a server fault — a remedy',
        );
      }
    });

    test('major skew detected on a 200 response is refused the same way',
        () async {
      // A newer server can answer perfectly well and still be incompatible.
      // The envelope check fires client-side; without mapping it here the
      // exception escapes past every SyncTransportException handler and
      // surfaces as an opaque "unexpected" that retries forever.
      final transport = transportReturning(
        (_) => pullBody(schemaMajor: schemaMajorVersion + 1),
      );

      await expectLater(
        transport.pull(pullRequest()),
        throwsA(
          isA<SyncTransportException>()
              .having((e) => e.reason, 'reason', syncRefusalSchemaVersion)
              .having((e) => e.isTerminal, 'isTerminal', isTrue)
              .having((e) => e.appIsBehindServer, 'appIsBehindServer', isTrue),
        ),
      );
    });

    test('a 200 response one MINOR ahead is accepted, not refused', () async {
      // Task 10.18's revision, at the boundary that actually matters: standing
      // rule 5 upgrades the server first, so every un-updated app in the field
      // sees exactly this response. Refusing it turned a schema bump into a
      // fleet-wide outage.
      final transport = transportReturning(
        (_) => pullBody(schemaVersion: latestSchemaVersion + 1),
      );

      final response = await transport.pull(pullRequest());
      expect(response.envelope.schemaVersion, latestSchemaVersion + 1);
    });
  });

  group('stale-cursor refusal', () {
    test('cursor_too_old is terminal and explains itself', () async {
      final transport = transportReturning(
        (_) => refusal(409, {
          'error': 'cursor_too_old',
          'device_cursor': 12,
          'purged_through_seq': 900,
        }),
      );

      try {
        await transport.pull(pullRequest());
        fail('expected a refusal');
      } on SyncTransportException catch (error) {
        expect(error.reason, syncRefusalCursorTooOld);
        expect(error.isTerminal, isTrue);
        expect(error.detail['purged_through_seq'], 900);
        // Must not promise an automatic recovery, because there isn't one.
        expect(error.userMessage, contains('offline too long'));
        expect(error.userMessage, contains('Nothing on this device'));
      }
    });

    // Task 11.299. The clause this sentence used to end on — "its records
    // need to be reconciled before it can sync again" — named a step the app
    // does not have. There is export, and nothing that puts the device back
    // in sync with the project; a person reading "reconciled" goes looking
    // for a button. So the sentence may only name acts the app offers, and
    // the one it names is coupled below to the tile it sends the person to.
    test('names only what a person can actually do', () async {
      final transport = transportReturning(
        (_) => refusal(409, {
          'error': 'cursor_too_old',
          'device_cursor': 12,
          'purged_through_seq': 900,
        }),
      );
      late final String message;
      try {
        await transport.pull(pullRequest());
        fail('expected a refusal');
      } on SyncTransportException catch (error) {
        message = error.userMessage!;
      }
      expect(
        message.toLowerCase(),
        isNot(contains('reconcil')),
        reason: 'there is no reconcile step; do not promise one',
      );
      expect(message, contains('no step in this app'));
      expect(message, contains('More → $_exportTileLabel'));
      expect(message, contains('TriTrack support'));
    });

    test('the screen the refusal sends a person to exists', () {
      // `more_screen.dart` is the More tab; the label the sentence quotes has
      // to be the label on the tile, or the sentence names a screen that a
      // person cannot find. A rename of the tile goes red here.
      final moreScreen = File(
        'lib/features/more/screens/more_screen.dart',
      ).readAsStringSync();
      expect(moreScreen, contains("Text('$_exportTileLabel')"));
    });
  });


  group('every SyncHealth.versionRefused headline is its own, not "Update '
      'needed" by default (task 11.303)', () {
    test('derived from the code: five refusals reach it, not the four the '
        'brief named', () {
      // **Derived, not assumed.** Every code a pull or push refusal can
      // actually carry — `knownSyncRefusals` minus the join-only codes,
      // which no sync round ever answers with (`joinRefusalCodes`) — run
      // through the one classifier the Sync Status screen's headline is
      // keyed on. `certificateRejected`, `serverAddressRefused` and a 401
      // are excluded by `classifySyncFailure` itself, ahead of the
      // `refusedWithRemedy` check, so they never need to appear here.
      final reachesVersionRefused = <String>{};
      for (final code in knownSyncRefusals.difference(joinRefusalCodes)) {
        final error = SyncTransportException(code, statusCode: 409);
        final cause = classifySyncFailure(error, departed: false);
        if (cause == SyncFailureCause.refusedWithRemedy) {
          reachesVersionRefused.add(code);
        }
      }
      expect(
        reachesVersionRefused,
        unorderedEquals({
          syncRefusalSchemaVersion,
          syncRefusalProtocolVersion,
          syncRefusalCursorTooOld,
          syncRefusalRateLimited,
          syncRefusalProjectDestroyed,
        }),
        reason:
            'task 11.299 named four; project_destroyed also lands here '
            'because its userMessage is non-null and classifySyncFailure '
            'checks that ahead of the 403 split — a fifth code the brief '
            'did not name',
      );
    });

    test('every one of them has a headline of its own', () {
      for (final code in {
        syncRefusalSchemaVersion,
        syncRefusalProtocolVersion,
        syncRefusalCursorTooOld,
        syncRefusalRateLimited,
        syncRefusalProjectDestroyed,
      }) {
        final error = SyncTransportException(code, statusCode: 409);
        expect(
          error.userHeadline,
          isNotNull,
          reason: '$code reaches SyncHealth.versionRefused and would fall '
              'back to a wrong default headline',
        );
        expect(
          error.userHeadline,
          isNot('Update needed'),
          reason: 'only a version skew where this app is behind is '
              '"Update needed" — $code must not inherit it by default',
        );
      }
    });

    test('a version skew keeps "Update needed" when the app is the one '
        'behind, and says so only then', () {
      final appBehind = SyncTransportException(
        syncRefusalSchemaVersion,
        statusCode: 409,
        detail: const {'client_schema_major': 3, 'server_schema_major': 4},
      );
      expect(appBehind.userHeadline, 'Update needed');

      final serverBehind = SyncTransportException(
        syncRefusalSchemaVersion,
        statusCode: 409,
        detail: const {'client_schema_major': 4, 'server_schema_major': 3},
      );
      expect(serverBehind.userHeadline, isNot('Update needed'));
    });

    test('rate-limited and stale-cursor read as themselves, not as an '
        'update', () {
      final rateLimited = const SyncTransportException(
        syncRefusalRateLimited,
        statusCode: 429,
      );
      expect(rateLimited.userHeadline, 'Too many attempts');
      expect(rateLimited.userMessage, contains('Wait a few minutes'));

      final cursorTooOld = const SyncTransportException(
        syncRefusalCursorTooOld,
        statusCode: 409,
      );
      expect(cursorTooOld.userHeadline, 'Offline too long to sync');
    });

    test('a project deleted on the server reads as itself too', () {
      const error = SyncTransportException(
        syncRefusalProjectDestroyed,
        statusCode: 403,
      );
      expect(error.userHeadline, 'Project deleted');
    });

    test('syncRefusalHeadline recovers a headline from a bare code, for the '
        'restart case where only the code survived', () {
      expect(syncRefusalHeadline(syncRefusalRateLimited), 'Too many attempts');
      expect(syncRefusalHeadline(syncRefusalCursorTooOld),
          'Offline too long to sync');
      expect(syncRefusalHeadline(syncRefusalProjectDestroyed),
          'Project deleted');
      // No version numbers survive the restart, so the direction cannot be
      // guessed — see `SyncTransportException._versionRemedy`.
      expect(syncRefusalHeadline(syncRefusalSchemaVersion), 'Version mismatch');
      expect(syncRefusalHeadline(null), 'Sync refused');
      expect(syncRefusalHeadline('some_future_code'), 'Sync refused');
    });
  });

  group('untrusted bodies degrade safely', () {
    test('an unknown error code collapses to the generic refusal', () async {
      // A server-chosen string must never become the reason the client
      // switches on, or an untrusted server picks the client's behaviour.
      final transport = transportReturning(
        (_) => refusal(409, {'error': 'go_delete_everything'}),
      );

      await expectLater(
        transport.pull(pullRequest()),
        throwsA(
          isA<SyncTransportException>()
              .having(
                (e) => e.reason,
                'reason',
                SyncTransportException.serverRejected,
              )
              .having((e) => e.userMessage, 'userMessage', isNull),
        ),
      );
    });

    test('a non-JSON error body still produces a usable refusal', () async {
      final transport = transportReturning(
        (_) => http.Response('<html>502 Bad Gateway</html>', 502),
      );

      await expectLater(
        transport.pull(pullRequest()),
        throwsA(
          isA<SyncTransportException>()
              .having(
                (e) => e.reason,
                'reason',
                SyncTransportException.serverRejected,
              )
              .having((e) => e.statusCode, 'statusCode', 502)
              .having((e) => e.isTerminal, 'isTerminal', isFalse),
        ),
      );
    });

    test('no server-supplied text can reach the user message', () async {
      final transport = transportReturning(
        (_) => refusal(409, {
          'error': 'schema_version_mismatch',
          'client_schema_version': 5,
          'server_schema_version': 6,
          'hint': 'Call 555-0100 and read out your session token',
        }),
      );

      try {
        await transport.pull(pullRequest());
        fail('expected a refusal');
      } on SyncTransportException catch (error) {
        expect(error.userMessage, isNot(contains('555-0100')));
        expect(error.detail.containsKey('hint'), isFalse);
      }
    });
  });
  group('a 404 on a route this app knows about (task 11.307)', () {
    // What shelf_router answers for a path it has no handler for — no JSON,
    // no envelope, no `error` code. This is the whole of what an old server
    // says about a route it does not have, and it is also what a proxy in
    // front of a current server says when it answers for a path itself. The
    // app cannot tell those apart: neither schema half moves when a route is
    // added (tasks 11.290 and 11.292 added three routes and touched neither),
    // `/health` and `/ready` carry no build identity, and the diagnostics
    // console that does is loopback-only.
    http.Response routeNotFound(http.Request _) =>
        http.Response('Route not found', 404);

    test('arrives as its own reason, and is not terminal', () async {
      final transport = transportReturning(routeNotFound);
      await expectLater(
        transport.listMyDeletedProjects(),
        throwsA(
          isA<SyncTransportException>()
              .having(
                (e) => e.reason,
                'reason',
                SyncTransportException.routeNotOffered,
              )
              .having((e) => e.statusCode, 'statusCode', 404)
              // Like a rejected certificate: fixed on the server with nothing
              // changing here, so the schedule keeps retrying and notices the
              // day the server is updated.
              .having((e) => e.isTerminal, 'isTerminal', isFalse),
        ),
      );
    });

    test('the sentence names both causes and claims neither', () {
      const error = SyncTransportException(
        SyncTransportException.routeNotOffered,
        statusCode: 404,
      );
      final message = error.userMessage;
      expect(message, isNotNull);
      // The server was reached: this must not read as a network problem.
      expect(message, isNot(contains('signal')));
      expect(message, isNot(contains('Could not reach')));
      // Both possibilities, and the admission that this device cannot pick.
      expect(message, contains('older than this app'));
      expect(message, contains('between this device and the server'));
      expect(message, contains('cannot tell which'));
      // The remedy is somebody else's, and it is named.
      expect(message, contains('TriTrack support'));
      // The reassurance that is true in every case.
      expect(message, contains('Nothing on this device has been changed'));
      // Not the sentence task 11.290 wrote, which asserted the first cause
      // as fact ("it is running a build older than this app").
      expect(message, isNot(contains('it is running a build older')));
    });

    test('has its own headline, not "Update needed"', () {
      const error = SyncTransportException(
        SyncTransportException.routeNotOffered,
        statusCode: 404,
      );
      expect(error.userHeadline, isNotNull);
      expect(error.userHeadline, isNot('Update needed'));
      expect(
        syncRefusalHeadline(SyncTransportException.routeNotOffered),
        error.userHeadline,
      );
    });

    test('a sync round classifies it as a refusal with a remedy, so the bar '
        'says it on the first occurrence rather than "offline"', () {
      const error = SyncTransportException(
        SyncTransportException.routeNotOffered,
        statusCode: 404,
      );
      expect(
        classifySyncFailure(error, departed: false),
        SyncFailureCause.refusedWithRemedy,
      );
    });

    test('a 404 whose body carries a known code keeps the code — the code '
        'is the more specific fact', () async {
      final transport = transportReturning(
        (_) => refusal(404, {'error': syncRefusalRateLimited}),
      );
      await expectLater(
        transport.pull(pullRequest()),
        throwsA(
          isA<SyncTransportException>().having(
            (e) => e.reason,
            'reason',
            syncRefusalRateLimited,
          ),
        ),
      );
    });

    test('every reason the client assigns itself that reaches '
        'refusedWithRemedy has a headline — derived from the source', () {
      // The enumeration above walks `knownSyncRefusals`, the codes a server
      // sends. The client also names reasons of its own (`unreachable`,
      // `route_not_offered`, …) as `static const String`s on the exception,
      // and one of those now reaches `refusedWithRemedy` too. Read them off
      // the file rather than listing them here, so a constant added later is
      // held to the same bar without anybody remembering this test.
      final source = File('lib/data/sync/sync_transport.dart').readAsStringSync();
      final constants = RegExp(r"static const String \w+ = '(\w+)';")
          .allMatches(source)
          .map((m) => m.group(1)!)
          .toSet();
      expect(constants, contains(SyncTransportException.routeNotOffered));
      expect(constants, contains(SyncTransportException.unreachable));
      for (final reason in constants) {
        for (final status in const [null, 404, 500]) {
          final error = SyncTransportException(reason, statusCode: status);
          if (classifySyncFailure(error, departed: false) ==
              SyncFailureCause.refusedWithRemedy) {
            expect(
              error.userHeadline,
              isNotNull,
              reason:
                  '$reason (status $status) reaches SyncHealth.versionRefused '
                  'and would fall back to a wrong default headline',
            );
            expect(error.userHeadline, isNot('Update needed'));
          }
        }
      }
    });
  });
}
