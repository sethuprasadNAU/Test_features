/// **Task 11.267: an interlock refusal reaches the device with a reason.**
///
/// Found on Michael's phone, 2026-09-16: the first time a real device pushed
/// a deployment the tightened interlock (task 11.263) refused, the held card
/// read *"it did not say which part of it was the problem"* — the honest
/// default `HeldRowDetails.rejectedWithoutADetail` — and the remedy sent him
/// looking for hidden characters in pasted text, which had nothing to do with
/// an overlapping deployment.
///
/// The cause: `sync_service.dart` refuses an overlapping deployment with no
/// `RowRefusal` code (deliberately — see that type's header), and the
/// sentence that argument leaned on — *"the device that sent this already
/// refuses the same row locally and owns the sentence"* — does not cover
/// this device's own history. A pair written under an earlier, looser
/// tolerance and never re-checked locally reaches the server without ever
/// having been refused on this device.
///
/// This file exercises the whole path end to end — `FakeSyncTransport` (the
/// server's answer), `SyncEngine.run` (what the device does with it),
/// `SyncHeldRowStore` (what it remembers) and `HeldRowDetails.resolve` (what
/// it tells a person) — rather than any one link in isolation, which the
/// other tests in this suite already cover.
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
  final now = DateTime.utc(2026, 9, 16, 12);
  final stamp = DbCodec.encodeUtc(now);

  DateTime day(int d) => DateTime(2026, 9, d);

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
    await appDb.raw.insert(Tables.individuals, {
      'individual_id': 'marie',
      'project_id': projectId,
      'lineage_id': 'marie',
      'name': 'Marie',
      'status': 'alive',
      'color_hex': '#123456',
      'created_at': stamp,
      'updated_at': stamp,
      'revision': 0,
      'last_modified_by': userId,
      'origin_device_id': deviceId,
    });
    for (final (id, name) in [('tag-a', 'Collar A'), ('tag-b', 'Collar B')]) {
      await appDb.raw.insert(Tables.tags, {
        'tag_id': id,
        'project_id': projectId,
        'lineage_id': id,
        'frequency_mhz': 150.1,
        'tag_name': name,
        'status': 'active',
        'created_at': stamp,
        'updated_at': stamp,
        'revision': 0,
        'last_modified_by': userId,
        'origin_device_id': deviceId,
      });
    }
    // **The legacy pair, planted exactly the way task 11.263's own history
    // did**: written under the one-day tolerance before it was withdrawn, so
    // this device never refused either row locally — both are ordinary,
    // unsynced rows waiting for their first push.
    await appDb.raw.insert(Tables.deployments, {
      'deployment_id': 'dep-old',
      'project_id': projectId,
      'tag_id': 'tag-a',
      'individual_id': 'marie',
      'attached_date': DbCodec.encodeUtc(day(1)),
      'removed_date': DbCodec.encodeUtc(day(10)),
      'notes': null,
      'created_at': stamp,
      'updated_at': stamp,
      'revision': 0,
      'last_modified_by': userId,
      'origin_device_id': deviceId,
    });
    await appDb.raw.insert(Tables.deployments, {
      'deployment_id': 'dep-new',
      'project_id': projectId,
      'tag_id': 'tag-b',
      'individual_id': 'marie',
      'attached_date': DbCodec.encodeUtc(day(10)),
      'removed_date': null,
      'notes': null,
      'created_at': stamp,
      'updated_at': DbCodec.encodeUtc(now.add(const Duration(minutes: 1))),
      'revision': 0,
      'last_modified_by': userId,
      'origin_device_id': deviceId,
    });

    // The server's answer: the second deployment overlaps the first.
    transport.interlockRefuseRows['${Tables.deployments}/dep-new/$projectId'] =
        DeploymentInterlock.ruleId;
  });

  tearDown(() => appDb.close());

  SyncEngine engine() => SyncEngine(
    db: appDb.raw,
    transport: transport,
    state: state,
    deviceId: deviceId,
    userId: userId,
  );

  test('RowRefusal gains no interlock code — the server sends the identity '
      'on its own channel', () {
    // The bound this task must not break, asserted directly against the
    // fake's contract: an interlock refusal is scripted through
    // `interlockRefuseRows`, never through `refuseRows`, because a
    // `RowRefusal` is never built for one.
    expect(transport.refuseRows, isEmpty);
    expect(
      transport.interlockRefuseRows['${Tables.deployments}/dep-new/$projectId'],
      DeploymentInterlock.ruleId,
    );
  });

  test('is reported as a rejection, held, and does not stop the rest of the '
      'push', () async {
    final report = await engine().run(projectId);

    expect(report.refused, hasLength(1));
    expect(report.refused.single.reason, HeldRowReason.rejected);
    expect(report.refused.single.tableName, Tables.deployments);
    expect(
      transport.serverRow(Tables.deployments, 'dep-old/$projectId'),
      isNotNull,
      reason: 'the refused row must not hold up the one that can go',
    );
    expect(
      transport.serverRow(Tables.deployments, 'dep-new/$projectId'),
      isNull,
      reason: 'the refused row must not be stored',
    );

    final held = await SyncHeldRowStore(appDb.raw).held(projectId);
    expect(held, hasLength(1));
    expect(held.single.interlockRule, DeploymentInterlock.ruleId);
    // The bound the task must respect, checked at the point the device
    // remembers the refusal: no `RowRefusal` detail rides beside it.
    expect(held.single.issueCode, isNull);
  });

  test(
    'the held card names the two deployments and their dates, reusing the '
    'local interlock sentence — not the pasted-text remedy',
    () async {
      await engine().run(projectId);

      final held = await SyncHeldRowStore(appDb.raw).held(projectId);
      final detail = (await HeldRowDetails.resolve(
        appDb.raw,
        projectId: projectId,
        currentUserId: userId,
        held: held,
      )).single;

      expect(detail.heldBy, isNot(HeldRowDetails.rejectedWithoutADetail));
      expect(detail.heldBy, contains('Collar A'));
      expect(detail.heldBy, contains('2026-09-01'));
      expect(detail.heldBy, contains('2026-09-10'));
      expect(
        detail.heldBy,
        contains('This animal would be wearing two tags at once'),
      );
      expect(detail.whatYouCanDo, isNot(HeldRowDetails.rejectedRemedy));
      expect(detail.whatYouCanDo, contains('set a time'));
      expect(
        detail.whatYouCanDo,
        isNot(contains('pasted')),
        reason: 'the remedy this device offers here must not be the one '
            'written for a different defect (task 11.84)',
      );
    },
  );
}
