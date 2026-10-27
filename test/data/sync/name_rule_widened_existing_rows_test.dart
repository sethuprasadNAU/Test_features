/// **Task 11.89 — what happens to a `Users` row that was legal when it was
/// written and is not legal now.**
///
/// Task 11.89 replaced the person-name rule with an allowlist, closing finding
/// R-1: a stranger asking to join could put a hard line break in the name they
/// claimed, and so choose what the second line of the owner's approval tile
/// said. Two Unicode line separators did it, and the denylist that was supposed
/// to stop them had been written three days earlier by somebody thinking about
/// exactly that attack.
///
/// **The regex was the easy part.** That rule is the *shared* declaration
/// `Users.first_name` and `Users.last_name` are checked against on every sync
/// path, so widening it makes rows that are already sitting on devices in the
/// field start failing validation — rows that were legal when they were
/// written. The task's own brief says that consequence must be **stated and
/// tested rather than discovered**, before the rule changes.
///
/// This file is that measurement. It is the sibling of
/// `refused_name_is_not_a_loop_test.dart`, which task 11.84 wrote to answer the
/// prior question — *does a refused push retry forever?* (it does not; it is a
/// reported rejection). That file measures the **outgoing** direction with a
/// bidirectional override. This one measures the outgoing direction with the
/// character 11.89 newly refuses, and then measures the direction nothing had
/// looked at: **a colleague's row, coming in.**
///
/// The two answers are different, and the difference is the thing worth
/// knowing:
///
/// * **Your own name, going out** — refused once, held, shown, and fixable by
///   you. The screen you fix it on refuses the bad value where you type it, so
///   you cannot retype the same mistake.
/// * **A colleague's name, coming in** — refused, recorded and reported, and
///   **not fixable by you, because it is not your name.** Their name is absent
///   on your device until they correct it on theirs, at which point it arrives
///   on its own. Nothing else about them is affected: their observations are in
///   a different table and are untouched.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tritrack/data/db/app_database.dart';
import 'package:tritrack/data/sync/dropped_row_details.dart';
import 'package:tritrack/data/sync/sync_dropped_rows.dart';
import 'package:tritrack/data/sync/sync_engine.dart';
import 'package:tritrack/data/sync/sync_held_rows.dart';
import 'package:tritrack/data/sync/sync_state_store.dart';
import 'package:tritrack/features/identity/identity_validation.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

import '../fixtures.dart';
import '../../support/fake_shared_preferences.dart';
import 'fake_sync_transport.dart';

void main() {
  late AppDatabase appDb;
  late FakeSyncTransport transport;
  late SyncStateStore state;

  const projectId = 'proj-1';
  const userId = 'user-1';
  const colleagueId = 'user-2';
  const deviceId = 'device-A';
  final now = DateTime.utc(2026, 9, 1, 12);
  final stamp = DbCodec.encodeUtc(now);

  /// U+2028 LINE SEPARATOR — finding R-1's character, written as an escape.
  ///
  /// A literal one in a source file is invisible in a diff and in a review,
  /// which is precisely the property that let it through a denylist written by
  /// somebody looking for it.
  const lineSeparator = ' ';

  /// The name as somebody could have stored it before this task.
  ///
  /// **Deliberately the sympathetic case and not the attack.** R-1's payload
  /// was an address on the second line, and this file could have used it — but
  /// the question here is not "does the rule stop an attacker", which
  /// `text_bounds_test.dart` answers. It is "what does this cost somebody who
  /// did nothing wrong", and the honest version of that is a stray separator
  /// arriving in a paste, inside a name that is otherwise entirely ordinary.
  /// A row that looks like an attack makes the answer feel deserved.
  const nameLegalBefore = 'Sam${lineSeparator}Ranger';

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

  /// Rewrites a row straight through SQLite, which is how a row written under
  /// the old rule got there: no validator ran, because none refused it then.
  Future<void> storeNameDirectly(String who, String first) => appDb.raw.update(
    Tables.users,
    {
      'first_name': first,
      'updated_at': DbCodec.encodeUtc(now.add(const Duration(minutes: 1))),
      'revision': 1,
    },
    where: 'user_id = ?',
    whereArgs: [who],
  );

  test('the premise: this name was legal before task 11.89 and is not now', () {
    // Asserted first and on its own. If the rule ever stops refusing this
    // string, every measurement in this file is measuring nothing — and the
    // failure would look like success, which is the shape of defect this
    // project keeps finding.
    expect(
      RowValidator.isWellFormedPersonName(nameLegalBefore),
      isFalse,
      reason: 'R-1 is closed, so this name is refused',
    );
    expect(
      RowValidator.isWellFormedPersonName('Sam Ranger'),
      isTrue,
      reason:
          'the control: the identical name with an ordinary space is accepted, '
          'so what every case below measures is the separator and not the '
          'string around it',
    );
    // And the payload R-1 actually described, for the record: an address on
    // the second line of the owner's approval tile. Refused twice over now —
    // by the separator, and by the address, which is one line of forgery even
    // with the break taken out.
    expect(
      RowValidator.isWellFormedPersonName(
        'Sam${lineSeparator}michael.w.shafer@nau.edu',
      ),
      isFalse,
    );
    expect(
      RowValidator.isWellFormedPersonName('Sam michael.w.shafer@nau.edu'),
      isFalse,
    );
  });

  group('your own row, going out', () {
    setUp(() => storeNameDirectly(userId, nameLegalBefore));

    test('is refused, survives locally, and does not hold up anything else', () async {
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
            'a field device with one newly-illegal name must still be able to '
            "send its bearings — this is finding D-3's shape",
      );
      final local = await appDb.raw.query(
        Tables.users,
        where: 'user_id = ?',
        whereArgs: [userId],
      );
      expect(
        local.single['first_name'],
        nameLegalBefore,
        reason:
            'widening a rule must never delete the data the old rule allowed. '
            'The row stays exactly as written until a person changes it',
      );
    });

    test('is reported, not swallowed, and no surface may say "Synced"', () async {
      final report = await engine().run(projectId);

      expect(report.refused, hasLength(1));
      expect(report.refused.single.reason, HeldRowReason.rejected);
      expect(report.everythingReachedTheServer, isFalse);

      final held = await SyncHeldRowStore(appDb.raw).held(projectId);
      expect(held.single.tableName, Tables.users);
      expect(held.single.reason, HeldRowReason.rejected);
    });

    test('is not re-offered while it is unchanged', () async {
      await engine().run(projectId);
      expect(transport.pushes.last.rows[Tables.users], hasLength(1));

      for (var i = 0; i < 4; i++) {
        await engine().run(projectId);
      }
      expect(
        transport.pushes
            .skip(1)
            .expand((push) => push.rows[Tables.users] ?? const [])
            .toList(),
        isEmpty,
        reason:
            'a refusal a device retries forever is worse than the row it '
            'refused — battery and data on a field device, for a rejection '
            'that cannot change until a person edits the name',
      );
    });

    test('and correcting the name sends it, with no other action needed', () async {
      await engine().run(projectId);
      expect(transport.serverRow(Tables.users, userId), isNull);

      // What a person actually does: open the profile screen and fix it.
      await appDb.raw.update(
        Tables.users,
        {
          'first_name': 'Sam',
          'updated_at': DbCodec.encodeUtc(now.add(const Duration(minutes: 5))),
          'revision': 2,
        },
        where: 'user_id = ?',
        whereArgs: [userId],
      );

      final report = await engine().run(projectId);
      expect(
        transport.serverRow(Tables.users, userId)?['first_name'],
        'Sam',
        reason:
            'the corrected row goes on the next ordinary sync. There is no '
            '"retry" button to find, and nothing for the person to know about '
            'held rows',
      );
      expect(report.everythingReachedTheServer, isTrue);
      expect(await SyncHeldRowStore(appDb.raw).held(projectId), isEmpty);
    });

    test('and the screen it is fixed on refuses it where it is typed', () {
      // Task 11.122 wired the identity screens to this same predicate, which
      // is what makes the correction above possible to get right first time:
      // a person cannot retype the bad value and be told nothing until the
      // next sync.
      //
      // Named rather than assumed: this is why widening the rule was safe to
      // do at all, and if it ever stops being true the correction loop above
      // becomes guesswork for the person doing it.
      expect(
        validateRequiredName(nameLegalBefore, 'First name'),
        isNotNull,
        reason: 'the field must refuse it before the sync path has to',
      );
      expect(validateRequiredName('Sam', 'First name'), isNull);
    });
  });

  group("a colleague's row, coming in", () {
    setUp(() {
      // Seeded straight onto the fake server, which is how such a row really
      // got there: it was pushed by a device running the old rule, and the
      // server accepted it because the server ran the old rule too.
      transport.seedServerRow(Tables.users, {
        'user_id': colleagueId,
        'first_name': nameLegalBefore,
        'last_name': 'Fox',
        'email': 'colleague@example.com',
        'created_at': stamp,
        'updated_at': stamp,
        'revision': 0,
        'last_modified_by': colleagueId,
        'origin_device_id': 'device-B',
      });
    });

    test('is refused on arrival and reported, not silently dropped', () async {
      final report = await engine().run(projectId);

      expect(
        report.droppedOnArrival.map((issue) => issue.table),
        contains(Tables.users),
        reason:
            'the pull must not count a row it refused as pulled — that is '
            "finding D-3 reached from the inbound direction",
      );
      final stored = await appDb.raw.query(
        Tables.users,
        where: 'user_id = ?',
        whereArgs: [colleagueId],
      );
      expect(
        stored,
        isEmpty,
        reason: 'a row this build will not validate is not written',
      );
    });

    test('is recorded durably, so a restart does not lose the news', () async {
      await engine().run(projectId);

      final dropped = await SyncDroppedRowStore(appDb.raw).dropped(projectId);
      final theirs = dropped.where((d) => d.rowKey == colleagueId).toList();
      expect(theirs, hasLength(1));
      expect(theirs.single.tableName, Tables.users);
      expect(theirs.single.field, 'first_name');

      // And what a person is told about it. The honest answer here includes
      // "there is nothing you can force," because there genuinely is not —
      // it is somebody else's name on somebody else's device. What the copy
      // must not do is imply the record is lost, or that the person reading
      // it did something wrong.
      final what = DroppedRowDetails.whatYouCanDo(theirs.single);
      expect(what, contains('nothing has been lost'));
      expect(what, contains('comes back automatically'));
    });

    test('does not wedge the pull — everything else still arrives', () async {
      // The real fixture rather than a hand-written column map: a partial
      // map fails on a NOT NULL column and says nothing about the property
      // under test.
      transport.seedServerRow(
        Tables.tags,
        sampleTag(id: 'tag-1', projectId: projectId).toColumns(),
      );

      await engine().run(projectId);

      expect(
        await appDb.raw.query(Tables.tags, where: 'tag_id = ?', whereArgs: ['tag-1']),
        hasLength(1),
        reason:
            'one unreadable name must not cost a colleague their tags or '
            'their bearings. Refusing the row is right; wedging the cursor on '
            'it would stop every later page too',
      );
    });

    test('and arrives on its own once they fix it — nothing for you to do', () async {
      await engine().run(projectId);
      expect(
        await appDb.raw.query(
          Tables.users,
          where: 'user_id = ?',
          whereArgs: [colleagueId],
        ),
        isEmpty,
      );

      // Their device, running the new rule, refuses the old name where it is
      // typed and they correct it. That is the only way out of this state, and
      // it is worth being explicit that it belongs to them: **you cannot fix a
      // colleague's name, and the app should not pretend otherwise.**
      transport.seedServerRow(Tables.users, {
        'user_id': colleagueId,
        'first_name': 'Robin',
        'last_name': 'Fox',
        'email': 'colleague@example.com',
        'created_at': stamp,
        'updated_at': DbCodec.encodeUtc(now.add(const Duration(hours: 1))),
        'revision': 1,
        'last_modified_by': colleagueId,
        'origin_device_id': 'device-B',
      });

      await engine().run(projectId);

      final stored = await appDb.raw.query(
        Tables.users,
        where: 'user_id = ?',
        whereArgs: [colleagueId],
      );
      expect(
        stored.single['first_name'],
        'Robin',
        reason:
            'the drop is not permanent and needs no repair step: the next '
            'change to that row on the device that owns it brings it through',
      );
    });
  });
}
