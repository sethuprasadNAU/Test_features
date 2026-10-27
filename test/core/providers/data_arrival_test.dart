import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:tritrack/core/providers/recordings_revision_provider.dart';
import 'package:tritrack/data/db/app_database.dart';
import 'package:tritrack/data/db/data_arrival.dart';
import 'package:tritrack/data/db/schema.dart';
import 'package:tritrack/data/sync/project_merger.dart';

import '../../data/fixtures.dart';
import '../../data/sync/backup_builders.dart';

/// The behaviour behind task 11.45's guard: **a writer announcing is enough**.
///
/// `data_arrival_announced_test.dart` proves that every writer says something.
/// This proves that what it says arrives — that `recordingsRevisionProvider`
/// moves when a merge lands, with no screen, provider or caller doing anything
/// to make that happen. Without this, the guard could be green over a wire
/// that was never connected.
void main() {
  late AppDatabase database;
  late Database db;

  setUp(() async {
    database = await AppDatabase.openInMemory();
    db = database.raw;
  });
  tearDown(() async => database.close());

  test('a merge moves the revision with no caller involved', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final before = container.read(recordingsRevisionProvider);

    await ProjectMerger(db).merge(
      makeBackup({
        Tables.users: [sampleUser(id: 'user-1', email: 'a@x.com').toColumns()],
        Tables.projects: [
          sampleProject(id: 'project-1', ownerUserId: 'user-1').toColumns(),
        ],
      }),
    );

    expect(
      container.read(recordingsRevisionProvider),
      greaterThan(before),
      reason:
          'ProjectMerger wrote rows and the revision did not move, so the map '
          'and the log will keep showing what they cached. Every inbound path '
          '— a sync pull, a join, an approved join request, a restored backup — '
          'goes through this merger, so this is all of them at once.',
    );
  });

  test('a merge that writes nothing says nothing', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final before = container.read(recordingsRevisionProvider);

    await ProjectMerger(db).merge(makeBackup({Tables.users: []}));

    expect(
      container.read(recordingsRevisionProvider),
      before,
      reason:
          'An idle sync poll merges an empty page every few minutes. If that '
          'announced, the map would re-run its whole query for nothing on a '
          'timer, on a device in the field on a battery.',
    );
  });

  test('a disposed listener is not called again', () {
    final container = ProviderContainer();
    container.read(recordingsRevisionProvider);
    final attached = DataArrival.listenerCount;
    container.dispose();
    expect(
      DataArrival.listenerCount,
      attached - 1,
      reason:
          'The provider did not detach on dispose. A stale listener bumps a '
          'disposed notifier, which throws — and it would throw from inside '
          'whichever writer happened to announce, turning a stale screen into '
          'a failed sync.',
    );
    // Nothing to catch: this would throw if the listener were still attached.
    DataArrival.announce();
  });
}
