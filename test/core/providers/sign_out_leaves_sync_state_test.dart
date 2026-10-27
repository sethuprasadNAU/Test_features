import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tritrack/core/providers/active_selection_provider.dart';
import 'package:tritrack/core/providers/auth_provider.dart';
import 'package:tritrack/core/providers/database_provider.dart';
import 'package:tritrack/core/providers/server_config_provider.dart';
import 'package:tritrack/core/providers/server_http_client_provider.dart';
import 'package:tritrack/core/providers/sync_provider.dart';
import 'package:tritrack/data/auth/session_store.dart';
import 'package:tritrack/data/db/app_database.dart';
import 'package:tritrack/data/sync/remembered_sync_failure.dart';
import 'package:tritrack/data/sync/sync_failure.dart';
import 'package:tritrack/data/sync/sync_state_store.dart';
import 'package:tritrack/widgets/sync_status_presentation.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

import '../../support/fake_session_store.dart';
import '../../support/fake_shared_preferences.dart';

/// **Signing out leaves every project's sync bookkeeping exactly where it
/// was** (task 11.304) — and this file is what makes that sentence checkable.
///
/// The brief counted three doc comments saying the opposite: that `signOut`
/// called `SyncStateStore.clear` for every project, so a later sign-in as
/// somebody else would not inherit a stranger's cursor. **No caller of `clear`
/// has ever run on sign-out**, and a census by subject found eight copies of
/// the claim, not three — six in `lib/`, two in test comments. Task 11.299
/// believed one of them and wrote down a route around a refusal that does not
/// exist, which is the cost a false comment charges: it is believed *because*
/// it is specific.
///
/// The comments now say what the code does, and the ones at the mechanism
/// name this file. The first group is the sentence they make, as an
/// assertion: sign out, and every per-project key is unchanged. **If sign-out
/// ever starts clearing, this goes red**, and this paragraph is the list of
/// what to rewrite with it: `CurrentSession.signOut`, `SyncStateStore.clear`,
/// `SyncStateStore.autoJoinedRequestIds`,
/// `SyncController._unlinkIfWeAlreadyLeft`, `MembershipController.leave`,
/// `ProjectDirectoryClient.listAvailableToJoin`, `JoinableProject`,
/// `JoinProjectScreen`, and the two test comments in
/// `sync_failure_survives_restart_test.dart` and `project_joiner_test.dart`.
///
/// The second group is the measurement that decided the task, kept as a test
/// so the answer stays measured rather than remembered: what a device does
/// when one person signs out and a **different** account signs in on it, with
/// the first person's cursors and linked flags still in place. Nothing is
/// offered and nothing is disclosed — and the measurement found a defect the
/// brief did not predict: the refused round is read as *"you have left this
/// project"* and unlinks the first person's project. The server-side half of
/// the same question — that a pull carrying a cursor another account earned
/// is refused identically to a fictional project and records nothing — is
/// `server/test/integration/member_authorization_test.dart`, the
/// "cross-project isolation" group, run against a real Postgres.
///
/// The third group is the cost the decision weighed: the same person signing
/// back in resumes from the cursor they left, which is the common case and
/// the one clearing would have made expensive.
void main() {
  setUp(installFakeSharedPreferences);

  late AppDatabase db;
  final stamp = DbCodec.encodeUtc(DateTime.utc(2026, 8, 1));

  setUp(() async {
    db = await AppDatabase.openInMemory();
  });
  tearDown(() => db.close());

  const alexId = 'alex-id';
  const samId = 'sam-id';
  const alexEmail = 'alex@example.com';
  const samEmail = 'sam@example.com';
  const alexToken = 'alex-token';
  final samToken = 'session-token-$samId';
  const projectP = 'proj-p';
  const projectQ = 'proj-q';

  /// Every request the mocked server has seen, in order: which route, which
  /// bearer token, and the decoded body. The measurement reads this list.
  final seen = <({String path, String? token, Map<String, Object?> body})>[];

  StoredSession session(String token, String userId, String email) =>
      StoredSession(
        token: token,
        userId: userId,
        email: email,
        expiresAt: DateTime.now().add(const Duration(days: 1)),
      );

  /// Who the next `/auth/redeem` mints a session for. [server] seeds it from
  /// its arguments; a test that signs two people in, in turn, reassigns it
  /// between them.
  var redeem = (userId: '', email: '');

  /// Stands in for the server, answering the way the real one does for each
  /// caller: sign-out and redemption succeed; every sync route answers Sam
  /// `403 forbidden` because Sam is not a member of anything on this device
  /// (the server's rule, pinned by `member_authorization_test.dart`); every
  /// sync route answers Alex `200` with nothing new.
  http.Client server({required String redeemAs, required String redeemEmail}) {
    redeem = (userId: redeemAs, email: redeemEmail);
    return MockClient((request) async {
      final path = request.url.path;
      final auth = request.headers['Authorization'];
      final token = auth?.replaceFirst(RegExp('^Bearer '), '');
      final body = request.body.isEmpty
          ? <String, Object?>{}
          : jsonDecode(request.body) as Map<String, Object?>;
      seen.add((path: path, token: token, body: body));
      // Alex holds whichever token their latest sign-in minted.
      final isAlex = token == alexToken || token == 'session-token-$alexId';

      http.Response json(Map<String, Object?> body, [int status = 200]) =>
          http.Response(
            jsonEncode(body),
            status,
            headers: const {'content-type': 'application/json'},
          );

      switch (path) {
        case '/auth/sign-out':
          return json({});
        case '/auth/redeem':
          return json({
            'session_token': 'session-token-${redeem.userId}',
            'user_id': redeem.userId,
            'email': redeem.email,
            'expires_at': DateTime.now()
                .toUtc()
                .add(const Duration(hours: 1))
                .toIso8601String(),
          });
        case '/sync/push':
          if (!isAlex) return json({'error': 'forbidden'}, 403);
          final rows = body['rows'] as Map<String, Object?>;
          final count = rows.values.whereType<List>().fold(
            0,
            (sum, list) => sum + list.length,
          );
          return json(
            SyncPushResponse(
              applied: count,
              outcomes: const {},
              highestServerSeq: 42,
            ).toJson(),
          );
        case '/sync/pull':
          if (!isAlex) return json({'error': 'forbidden'}, 403);
          return json(
            SyncPullResponse(
              rows: const {},
              nextCursor: body['cursor'] as int,
              remaining: 0,
            ).toJson(),
          );
        case '/sync/ack':
          if (!isAlex) return json({'error': 'forbidden'}, 403);
          return json(const SyncEnvelope().toJson());
      }
      return http.Response('not found', 404);
    });
  }

  /// Alex's phone: Alex owns two published projects and has a bearing on P
  /// the server has not yet been given.
  Future<void> seedAlexsPhone() async {
    await db.raw.insert(Tables.users, {
      'user_id': alexId,
      'first_name': 'Alex',
      'last_name': 'Ranger',
      'email': alexEmail,
      'created_at': stamp,
      'updated_at': stamp,
      'revision': 0,
      'last_modified_by': alexId,
      'origin_device_id': 'device-A',
    });
    for (final (id, name) in [(projectP, 'Elk'), (projectQ, 'Bighorn')]) {
      await db.raw.insert(Tables.projects, {
        'project_id': id,
        'project_name': name,
        'owner_user_id': alexId,
        'creation_date': stamp,
        'datum': 'WGS84',
        'created_at': stamp,
        'updated_at': stamp,
        'revision': 0,
        'last_modified_by': alexId,
        'origin_device_id': 'device-A',
        'coordinate_format': 'dd',
        'triangulation_window_minutes': 15,
      });
      await db.raw.insert(Tables.projectMemberships, {
        'membership_id': 'mem-$id',
        'project_id': id,
        'user_id': alexId,
        'join_date': stamp,
        'end_date': null,
        'role': 'owner',
        'created_at': stamp,
        'updated_at': stamp,
        'revision': 0,
        'last_modified_by': alexId,
        'origin_device_id': 'device-A',
      });
    }
    await db.raw.insert(Tables.observations, {
      'observation_id': 'obs-alex',
      'project_id': projectP,
      'user_id': alexId,
      'timestamp_local': stamp,
      'timestamp_utc': stamp,
      'timezone_offset': '+00:00',
      'latitude': 35.2,
      'longitude': -111.7,
      'position_source': 'gps_fix',
      'elevation': 2106.4,
      'altitude_agl': 1.5,
      'observation_type': 'directional',
      'signal_type': 'regular_pulse',
      'signal_strength': 'strong',
      'created_at': stamp,
      'updated_at': stamp,
      'revision': 0,
      'last_modified_by': alexId,
      'origin_device_id': 'device-A',
    });
  }

  final alexLastSuccess = DateTime.utc(2026, 8, 2, 7);
  final alexFailure = RememberedSyncFailure(
    cause: SyncFailureCause.unreachable,
    consecutiveFailures: 2,
    recordedAt: DateTime.utc(2026, 8, 2, 8),
  );

  /// What Alex's sessions left in `SyncStateStore`: both projects linked,
  /// each with a cursor, one with a last-success stamp and a remembered
  /// failure, plus the device-wide values.
  Future<void> seedAlexsSyncState(SyncStateStore store) async {
    await store.markProjectLinked(projectP);
    await store.setCursor(projectP, 42);
    await store.setLastSuccessAt(projectP, alexLastSuccess);
    await store.setRememberedFailure(projectP, alexFailure);
    await store.markProjectLinked(projectQ);
    await store.setCursor(projectQ, 7);
    await store.markRequestAutoJoined('req-1');
  }

  /// A snapshot of every per-project key `clear` removes, plus the one
  /// device-wide value the sign-out comments used to reason about.
  Future<Map<String, Object?>> snapshot(SyncStateStore store) async => {
    'P.linked': await store.isProjectLinked(projectP),
    'P.cursor': await store.cursor(projectP),
    'P.lastSuccessAt': await store.lastSuccessAt(projectP),
    'P.failure': (await store.rememberedFailure(projectP))?.encode(),
    'Q.linked': await store.isProjectLinked(projectQ),
    'Q.cursor': await store.cursor(projectQ),
    'Q.lastSuccessAt': await store.lastSuccessAt(projectQ),
    'Q.failure': (await store.rememberedFailure(projectQ))?.encode(),
    'autoJoined': await store.autoJoinedRequestIds(),
  };

  ProviderContainer container({
    required http.Client client,
    required FakeSessionStore sessions,
  }) {
    final c = ProviderContainer(
      overrides: [
        appDatabaseProvider.overrideWith((ref) async => db),
        serverHttpClientProvider.overrideWith((ref) async => client),
        sessionStoreProvider.overrideWithValue(sessions),
      ],
    );
    addTearDown(c.dispose);
    return c;
  }

  /// Alex's phone as Alex left it: signed in, P open, both projects syncing.
  Future<(ProviderContainer, FakeSessionStore)> alexsPhone(
    http.Client client,
  ) async {
    seen.clear();
    await seedAlexsPhone();
    final sessions = FakeSessionStore(session(alexToken, alexId, alexEmail));
    final c = container(client: client, sessions: sessions);
    await c.read(serverConfigProvider.notifier).setUrl('http://test.local');
    await c.read(activeUserIdProvider.notifier).set(alexId);
    await c.read(activeProjectIdProvider.notifier).set(projectP);
    await seedAlexsSyncState(c.read(syncStateStoreProvider));
    // Alex's own view, before anything happens: P is syncing, one bearing
    // waiting. This is the state the comments claimed sign-out would erase.
    final status = await c.read(syncControllerProvider.future);
    expect(status.isAvailable, isTrue);
    expect(status.pendingCount, isPositive);
    return (c, sessions);
  }

  group('sign-out leaves every project\'s sync bookkeeping where it was', () {
    test(
      'the cursor, the linked flag, the last-success stamp and the remembered '
      'failure of every project survive signOut unchanged',
      () async {
        final (c, sessions) = await alexsPhone(
          server(redeemAs: samId, redeemEmail: samEmail),
        );
        final store = c.read(syncStateStoreProvider);
        final before = await snapshot(store);

        await c.read(currentSessionProvider.notifier).signOut();

        // The one thing sign-out removes is the session.
        expect(await sessions.read(), isNull);
        expect(c.read(currentSessionProvider).value, isNull);
        expect(
          seen.map((r) => r.path),
          ['/auth/sign-out'],
          reason: 'the server was told, and nothing else was asked of it',
        );

        // And the one thing it does not remove is everything else. **This is
        // the assertion the three comments are now written against.** If
        // `signOut` ever starts calling `SyncStateStore.clear`, rewrite the
        // comments this file's header lists in the same change, and say in
        // the plan what every project re-pulling from zero on the next
        // sign-in costs on a phone in the field.
        expect(await snapshot(store), before);
        expect(await store.isProjectLinked(projectP), isTrue);
        expect(await store.cursor(projectP), 42);
        expect(await store.isProjectLinked(projectQ), isTrue);
        expect(await store.cursor(projectQ), 7);
      },
    );

    test(
      'and the app is left fully usable offline, as the dialog says',
      () async {
        // The sign-out dialog promises "Everything already on this device
        // stays" — every row, not only the bookkeeping.
        final (c, _) = await alexsPhone(
          server(redeemAs: samId, redeemEmail: samEmail),
        );
        await c.read(currentSessionProvider.notifier).signOut();
        final rows = await db.raw.query(Tables.observations);
        expect(rows.map((r) => r['observation_id']), ['obs-alex']);
        expect((await db.raw.query(Tables.projects)).length, 2);
        final status = await c.read(syncControllerProvider.future);
        expect(status.unavailable, SyncUnavailable.signedOut);
      },
    );
  });

  group(
    'and then a different account signs in on the same device — measured',
    () {
      test(
        'the device offers nothing of the first person\'s, asks for their '
        'project from their cursor under the new token, and is refused',
        () async {
          final (c, sessions) = await alexsPhone(
            server(redeemAs: samId, redeemEmail: samEmail),
          );
          await c.read(currentSessionProvider.notifier).signOut();

          // Sam signs in. The adopter gives Sam a `Users` row of their own and
          // leaves Alex's records exactly as they were — a real, different
          // email is the one case it deliberately never folds in.
          await c
              .read(currentSessionProvider.notifier)
              .completeSignIn('a'.padRight(32, 'a'), expectedEmail: samEmail);
          expect(sessions.writes.last.userId, samId);
          expect(await c.read(activeUserIdProvider.future), samId);
          final alexsRow = await db.raw.query(
            Tables.observations,
            where: 'observation_id = ?',
            whereArgs: ['obs-alex'],
          );
          expect(alexsRow.single['user_id'], alexId);
          expect(
            (await db.raw.query(Tables.users)).map((r) => r['user_id']),
            unorderedEquals([alexId, samId]),
          );

          // **Finding 1.** P is still the open project and still linked, so
          // the sync bar is live for Sam. It counts **nothing** as waiting:
          // task 11.237's gate (`SyncEngine.offersNothingFor`) reads the local
          // membership rows, finds none for Sam, and withholds every row of P
          // — Alex's bearing included. Nothing Alex recorded is offered under
          // Sam's name, and nothing is shown to Sam as Sam's to send.
          final before = await c.read(syncControllerProvider.future);
          expect(before.isAvailable, isTrue);
          expect(before.pendingCount, 0);
          // What Sam *is* shown, until Sam's own first round replaces it: the
          // failure Alex's last round left behind — the "stranger telling them
          // their own sync is broken" the old `clear` comment worried about,
          // for exactly one round.
          expect(before.remembered?.cause, SyncFailureCause.unreachable);

          seen.clear();
          await c.read(syncControllerProvider.notifier).syncNow();

          // **Finding 2.** No push at all — a device with nothing to offer
          // makes none. The round is one request: a pull for Alex's project,
          // under Sam's token, from the position Alex's sessions reached.
          expect(seen.map((r) => r.path), ['/sync/pull']);
          final pull = seen.single;
          expect(pull.token, samToken);
          expect(pull.body['project_id'], projectP);
          expect(
            pull.body['cursor'],
            42,
            reason: 'the cursor is inherited; the server decides what it earns',
          );

          // **Finding 3 — the defect this measurement found, and its fix.**
          //
          // Measured on 2026-09-21 (task 11.304): the refusal was read as
          // *"you are no longer on this project"*. `classifySyncFailure`
          // turned a `403` into `membershipEnded` whenever the signed-in
          // person held no **open** membership row, and Sam holds no row at
          // all; `build` asked the narrower question (`_weHaveLeft`: a row
          // exists and is closed), and `_run`'s wider answer was the one that
          // acted. Sam's first round — automatic, on the first foreground
          // after sign-in — unlinked P, erased the cursor Alex earned, and
          // told Sam *"You're no longer on this project, so it has stopped
          // syncing."* Alex, signing back in, found P silently not syncing.
          //
          // **Since task 11.305 both paths ask one question** —
          // `ProjectMembershipRepository.hasDeparted`: a closed stint and no
          // open one — and a `403` on a project this device has no record of
          // the signed-in person on is what it is: **access refused**, not a
          // departure. Alex's bookkeeping is untouched by Sam's session, and
          // Sam is told the server refused, which is true.
          final after = c.read(syncControllerProvider).value!;
          expect(
            after.unavailable,
            isNull,
            reason:
                "P is still linked: nothing about Alex's project was "
                "undone by Sam's round",
          );
          expect(after.lastFailure, SyncFailureCause.accessRefused);
          expect(after.health, SyncHealth.accessRefused);
          expect(after.health, isNot(SyncHealth.membershipEnded));
          // Read as a person, not as a code: this is the sentence on Sam's
          // status icon. It says the server refused, and it does not say Sam
          // left anything.
          final sentence = SyncStatusPresentation.of(after).message;
          expect(
            sentence,
            'The server is refusing access to this project. Tap to check.',
          );
          expect(sentence, isNot(contains('no longer on this project')));
          final store = c.read(syncStateStoreProvider);
          expect(
            await store.isProjectLinked(projectP),
            isTrue,
            reason: "Alex's project stays linked through Sam's refusal",
          );
          expect(
            await store.cursor(projectP),
            42,
            reason: 'and the cursor Alex earned is kept',
          );
          // The refusal is written down as what it was, replacing the
          // "unreachable" Alex's last round left, so a restart reports the
          // refusal rather than a stale dead zone (task 11.116).
          expect(
            (await store.rememberedFailure(projectP))?.cause,
            SyncFailureCause.accessRefused,
          );
          // Q, which Sam's round never touched, is exactly as Alex left it.
          expect(await store.isProjectLinked(projectQ), isTrue);
          expect(await store.cursor(projectQ), 7);

          // **What did not cross.** Nothing of Alex's reached the server as
          // Sam's: no row was offered, and the one request was answered 403.
          // Nothing of Alex's was hidden from Sam either — but that was
          // already true while the device was signed out, and it is the
          // sign-out dialog's promise ("everything already on this device
          // stays"), not a sync question.
          expect(
            (await db.raw.query(Tables.observations)).single['user_id'],
            alexId,
          );
        },
      );

      test('and when the first person signs back in after that, their project '
          'is exactly where they left it', () async {
        // The claim task 11.305 makes, checked end to end: Alex's
        // bookkeeping survives Sam's refused round, so Alex signs back in
        // to a project that resumes from its cursor rather than one that
        // is silently unlinked. Before the fix this was the person who
        // found P not syncing and had to re-join it from zero.
        final (c, _) = await alexsPhone(
          server(redeemAs: samId, redeemEmail: samEmail),
        );
        await c.read(currentSessionProvider.notifier).signOut();
        await c
            .read(currentSessionProvider.notifier)
            .completeSignIn('a'.padRight(32, 'a'), expectedEmail: samEmail);
        await c.read(syncControllerProvider.future);
        await c.read(syncControllerProvider.notifier).syncNow();
        expect(
          c.read(syncControllerProvider).value!.lastFailure,
          SyncFailureCause.accessRefused,
        );

        // Sam signs out; Alex signs back in.
        await c.read(currentSessionProvider.notifier).signOut();
        redeem = (userId: alexId, email: alexEmail);
        await c
            .read(currentSessionProvider.notifier)
            .completeSignIn('c'.padRight(32, 'c'), expectedEmail: alexEmail);
        expect(await c.read(activeUserIdProvider.future), alexId);

        // What Alex sees before their own first round: P is still linked
        // (the bar is live, not hidden), and the one thing left over from
        // Sam's session is the refusal it wrote down — the mirror of
        // Finding 1, and for the same one round, because sign-in makes a
        // round due at once.
        final before = await c.read(syncControllerProvider.future);
        expect(before.isAvailable, isTrue);
        expect(before.remembered?.cause, SyncFailureCause.accessRefused);

        seen.clear();
        await c.read(syncControllerProvider.notifier).syncNow();

        // Alex's round is the incremental one: Q from 7, P from 42, all
        // under Alex's token — the same shape as the third group below,
        // now with somebody else's session in between.
        final pulls = seen.where((r) => r.path == '/sync/pull').toList();
        expect(pulls.map((r) => r.body['project_id']), [projectQ, projectP]);
        expect(
          pulls.map((r) => r.token),
          everyElement('session-token-$alexId'),
        );
        expect(pulls.first.body['cursor'], 7);
        expect(
          pulls.last.body['cursor'],
          42,
          reason:
              'before task 11.305 P had been unlinked by Sam\'s round and '
              'this pull would not have happened at all',
        );
        // And the round that got through outranks the refusal Sam left.
        // (Not asserted as `SyncHealth.healthy`: this file's mock answers a
        // push with no per-row outcomes, so the engine holds the pushed rows
        // and the status reads `rowsRefused` on every leg here, including
        // the Alex-only one below. That is the fixture, not the question this
        // test asks.)
        final status = c.read(syncControllerProvider).value!;
        expect(status.lastFailure, isNull);
        expect(status.remembered, isNull);
        expect(status.health, isNot(SyncHealth.accessRefused));
      });
    },
  );

  group('and when the same person signs back in — the cost clearing would '
      'charge', () {
    test('the next round resumes from the kept cursor rather than re-pulling '
        'the project from zero', () async {
      final (c, _) = await alexsPhone(
        server(redeemAs: alexId, redeemEmail: alexEmail),
      );
      await c.read(currentSessionProvider.notifier).signOut();
      // Same person, same address: the adopter finds its own row and
      // rewrites nothing.
      await c
          .read(currentSessionProvider.notifier)
          .completeSignIn('b'.padRight(32, 'b'), expectedEmail: alexEmail);
      expect(await c.read(activeUserIdProvider.future), alexId);
      expect((await db.raw.query(Tables.users)).map((r) => r['user_id']), [
        alexId,
      ]);

      seen.clear();
      await c.read(syncControllerProvider.notifier).syncNow();

      // The round delivers Q's stranded project row first (task 11.289),
      // pulling Q from its kept cursor too; P's own round follows.
      final pulls = seen.where((r) => r.path == '/sync/pull').toList();
      expect(pulls.map((r) => r.body['project_id']), [projectQ, projectP]);
      expect(pulls.map((r) => r.token), everyElement('session-token-$alexId'));
      expect(pulls.first.body['cursor'], 7);
      final pull = pulls.last;
      expect(
        pull.body['cursor'],
        42,
        reason:
            'had sign-out cleared the cursor this would be 0: the whole '
            'project over the air again, on a phone in the field',
      );
      final status = c.read(syncControllerProvider).value!;
      expect(status.lastFailure, isNull);
      expect(status.remembered, isNull);
    });
  });
}
