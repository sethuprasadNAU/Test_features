/// **Task 11.84 item 3: what a device does when the new name rule refuses its
/// push.**
///
/// Task 11.81 centralised person-name validation into `TextShape.personName`
/// and applied it to `Users.first_name` and `Users.last_name`. A `Users` row
/// carrying a control character or a bidirectional override is therefore
/// **refused on the sync path where it was previously accepted**. The rule is
/// right and is not in question here.
///
/// What was unverified is the thing that matters more than the rule: **a
/// refusal a device retries forever is worse than the row it refused.** A loop
/// would push, be refused, and push again on every sync — burning battery and
/// data on a field device, and filling the server's log with the same rejection
/// until somebody notices.
///
/// **This measures it rather than reasoning about it.** The fake server runs the
/// real shared `RowValidator`, so the refusal below comes from the rule task
/// 11.81 wrote and not from a scripted outcome — until this task, nothing in the
/// suite could push a row and have the real rule turn it away
/// (`fake_sync_transport.dart`, `validateRows`). The existing end-to-end
/// refusal coverage in `sync_engine_test.dart` is real, but every case in it
/// uses `unauthorized`; the `invalid` outcome this rule produces was covered
/// only at the point where an outcome is classified, never through a push.
///
/// The measured answer, in one sentence: **it is a reported rejection, held once
/// and durably, and the identical row is never offered again — not a loop.**
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tritrack/data/db/app_database.dart';
import 'package:tritrack/data/sync/held_row_details.dart';
import 'package:tritrack/data/sync/sync_engine.dart';
import 'package:tritrack/data/sync/sync_held_rows.dart';
import 'package:tritrack/data/sync/sync_state_store.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

import '../../support/fake_shared_preferences.dart';
import 'fake_sync_transport.dart';

void main() {
  late AppDatabase appDb;
  late FakeSyncTransport transport;
  late SyncStateStore state;

  const projectId = 'proj-1';
  const userId = 'user-1';
  const deviceId = 'device-A';
  final now = DateTime.utc(2026, 9, 1, 12);
  final stamp = DbCodec.encodeUtc(now);

  /// U+202E, the right-to-left override. The reason this character is refused
  /// rather than merely odd: on the one screen where a person decides whether
  /// to trust somebody by reading a string, it lets a stranger's name render as
  /// a colleague's.
  const bidiOverride = '\u202E';

  setUp(() async {
    installFakeSharedPreferences();
    appDb = await AppDatabase.openInMemory();
    transport = FakeSyncTransport();
    state = SyncStateStore(prefs: SharedPreferencesAsync());

    await appDb.raw.insert(Tables.users, {
      'user_id': userId,
      'first_name': 'Sam',
      'last_name': 'Ranger',
      'email': 'sam@example.com',
      'created_at': stamp,
      'updated_at': stamp,
      'revision': 0,
      'last_modified_by': userId,
      'origin_device_id': deviceId,
    });
    await appDb.raw.insert(Tables.projects, {
      'project_id': projectId,
      'project_name': 'Elk',
      'owner_user_id': userId,
      'creation_date': stamp,
      'datum': 'WGS84',
      'created_at': stamp,
      'updated_at': stamp,
      'revision': 0,
      'last_modified_by': userId,
      'origin_device_id': deviceId,
      'coordinate_format': 'dd',
      'triangulation_window_minutes': 15,
    });
  });

  tearDown(() => appDb.close());

  SyncEngine engine() => SyncEngine(
    db: appDb.raw,
    transport: transport,
    state: state,
    deviceId: deviceId,
    userId: userId,
  );

  /// Rewrites the local user's name to something the rule refuses, the way
  /// editing a profile does: a new `updated_at` and a bumped revision.
  Future<void> giveTheUserARefusableName() async {
    await appDb.raw.update(
      Tables.users,
      {
        'first_name': 'Sam$bidiOverride',
        'updated_at': DbCodec.encodeUtc(now.add(const Duration(minutes: 1))),
        'revision': 1,
      },
      where: 'user_id = ?',
      whereArgs: [userId],
    );
  }

  Future<void> giveTheUserAnAcceptableName() async {
    await appDb.raw.update(
      Tables.users,
      {
        'first_name': 'Samantha',
        'updated_at': DbCodec.encodeUtc(now.add(const Duration(minutes: 2))),
        'revision': 2,
      },
      where: 'user_id = ?',
      whereArgs: [userId],
    );
  }

  group('a name the server refuses', () {
    test('is refused by the real rule, not by a scripted outcome', () {
      // If this ever stops being true, every measurement below is measuring
      // nothing — so it is asserted first and on its own.
      expect(
        RowValidator.validate(Tables.users, {
          'user_id': userId,
          'first_name': 'Sam$bidiOverride',
          'last_name': 'Ranger',
          'email': 'sam@example.com',
          'created_at': stamp,
          'updated_at': stamp,
          'revision': 1,
          'last_modified_by': userId,
          'origin_device_id': deviceId,
        }),
        isNotEmpty,
      );
    });

    test(
      'does not reach the server, and does not stop the rest of the push',
      () async {
        await giveTheUserARefusableName();
        await engine().run(projectId);

        expect(
          transport.serverRow(Tables.users, userId),
          isNull,
          reason: 'the refused row must not be stored',
        );
        expect(
          transport.serverRow(Tables.projects, projectId),
          isNotNull,
          reason:
              'a refused row must not hold up the data that can go — this is '
              'finding D-3\'s shape, and a field device with one bad name must '
              'still be able to send its bearings',
        );
        final local = await appDb.raw.query(
          Tables.users,
          where: 'user_id = ?',
          whereArgs: [userId],
        );
        expect(
          local.single['first_name'],
          'Sam$bidiOverride',
          reason: 'and it must survive locally rather than being dropped',
        );
      },
    );

    test('is reported as a rejection the person can be shown', () async {
      await giveTheUserARefusableName();
      final report = await engine().run(projectId);

      expect(report.refused, hasLength(1));
      expect(report.refused.single.reason, HeldRowReason.rejected);
      expect(
        report.everythingReachedTheServer,
        isFalse,
        reason:
            'no surface may say "Synced" while a row is sitting refused — that '
            'is the whole of finding D-3',
      );

      final held = await SyncHeldRowStore(appDb.raw).held(projectId);
      expect(held, hasLength(1));
      expect(held.single.tableName, Tables.users);
      expect(held.single.reason, HeldRowReason.rejected);
    });

    test(
      'is not offered again while it is unchanged — this is the measurement',
      () async {
        await giveTheUserARefusableName();

        await engine().run(projectId);
        final offeredOnFirstRun = transport.pushes.last.rows[Tables.users];
        expect(offeredOnFirstRun, hasLength(1));

        // Four more syncs, as a device left on a bench would do.
        for (var i = 0; i < 4; i++) {
          await engine().run(projectId);
        }

        final everOfferedAgain = transport.pushes
            .skip(1)
            .expand((push) => push.rows[Tables.users] ?? const [])
            .toList();
        expect(
          everOfferedAgain,
          isEmpty,
          reason:
              'The device re-offered a row it had already been told is '
              'invalid. That is a loop: every sync for the life of the device '
              'would push the same row and be refused the same way. The row is '
              'suppressed by the held-row join in SyncEngine._pendingClause — '
              'if that join changed, this is the failure it produces.',
        );

        final held = await SyncHeldRowStore(appDb.raw).held(projectId);
        expect(
          held.single.refusalCount,
          1,
          reason:
              'refused once, not once per sync — a rising count here is the '
              'same loop counted a different way',
        );
      },
    );

    test('is offered again once the name is corrected', () async {
      await giveTheUserARefusableName();
      await engine().run(projectId);
      expect(transport.serverRow(Tables.users, userId), isNull);

      // The remedy has to actually work, or "not a loop" just means "never
      // sent again", which would be the silent-loss defect instead.
      await giveTheUserAnAcceptableName();
      await engine().run(projectId);

      expect(
        transport.serverRow(Tables.users, userId)?['first_name'],
        'Samantha',
      );
      final held = await SyncHeldRowStore(appDb.raw).held(projectId);
      expect(
        held,
        isEmpty,
        reason: 'and the warning must clear, or it warns forever about nothing',
      );
    });
  });

  /// **Task 11.124 — and now the device can say which part was refused.**
  ///
  /// The same refusal as above, on the same path, with the same real rule
  /// doing the refusing. What is new is that the outcome no longer arrives
  /// bare: the server names the bound the value failed, the device stores it,
  /// and the screen turns it into a sentence about the record.
  ///
  /// **This is the end-to-end assertion the rest of the task's tests stand
  /// in for.** Every other test of this feature holds one seam still and
  /// checks the next; this one pushes a real row through a real validator and
  /// reads what a person would see at the far end.
  group('and which part of it was refused (task 11.124)', () {
    test(
      'the refusal arrives with the code the column\'s own bound declares',
      () async {
        await giveTheUserARefusableName();
        final report = await engine().run(projectId);

        final refused = report.refused.single;
        expect(refused.tableName, Tables.users);
        expect(refused.issueCode, RowIssueCode.textNotAName);
        expect(refused.issueField, 'first_name');
        // Not typed anywhere on the way: this is the value `Users.first_name`
        // declares, reached from the schema rather than from this expectation.
        expect(
          refused.issueCode,
          tableSpecsByName[Tables.users]!.columns
              .firstWhere((c) => c.name == 'first_name')
              .bound!
              .shape
              .violationCode,
        );
      },
    );

    test('and it is still there after the app is restarted', () async {
      await giveTheUserARefusableName();
      await engine().run(projectId);

      // Read back through a fresh store, which is what a restart amounts to
      // for this table — the hold is durable or it is decoration.
      final held = await SyncHeldRowStore(appDb.raw).held(projectId);
      expect(held.single.issueCode, RowIssueCode.textNotAName);
      expect(held.single.issueField, 'first_name');
    });

    test('and the screen names the field rather than shrugging', () async {
      await giveTheUserARefusableName();
      await engine().run(projectId);

      final held = await SyncHeldRowStore(appDb.raw).held(projectId);
      final detail = (await HeldRowDetails.resolve(
        appDb.raw,
        projectId: projectId,
        currentUserId: userId,
        held: held,
      )).single;

      expect(detail.heldBy, contains('the first name'));
      expect(detail.heldBy, isNot(HeldRowDetails.rejectedWithoutADetail));
      expect(detail.whatYouCanDo, contains('retype the first name'));
    });

    test('correcting the name clears the detail along with the hold', () async {
      await giveTheUserARefusableName();
      await engine().run(projectId);
      await giveTheUserAnAcceptableName();
      await engine().run(projectId);

      expect(await SyncHeldRowStore(appDb.raw).held(projectId), isEmpty);
    });
  });
}
