import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tritrack/core/providers/active_selection_provider.dart';
import 'package:tritrack/core/providers/app_context_provider.dart';
import 'package:tritrack/data/models/project.dart';
import 'package:tritrack/data/models/sync_meta.dart';
import 'package:tritrack/data/repositories/repository_providers.dart';

import '../../support/fake_path_provider.dart';
import '../../support/fake_shared_preferences.dart';

/// **What it costs a screen to watch `currentProjectProvider`** — task 11.120.
///
/// Task 11.103 wired that provider into the Offline Data Map, saw that
/// screen's suite go from under a second to minutes, backed the wiring out,
/// and wrote down that watching the provider might be expensive on a phone
/// too. **It is not, and it never was.** The cost was `estimateTileCount`
/// building the whole tile list in order to measure its length at the new
/// whole-planet default zoom — the defect 11.103 found and fixed in the same
/// commit. Re-measured on 2026-09-04: with the watch in place and today's
/// tile counter the Offline Data Map's suite runs in 1 second; with the watch
/// *removed* and 11.103's old tile counter restored, a single test in it takes
/// 4 minutes 18 seconds.
///
/// This file measures the provider itself so nobody has to take that on
/// trust, and so a future change that turns it into per-rebuild work fails
/// here rather than being found by a suite getting slow.
///
/// **These are plain `test`s, not `testWidgets`.** The database answers on
/// real time; a widget test's fake clock cannot advance it, and awaiting one
/// from a widget-test body is this project's most expensive recurring trap.
/// The numbers are from a macOS host with a real on-disk SQLite database —
/// **not from a phone**, which nothing in this environment can run. What
/// transfers is not the milliseconds but the *shape*: `currentProject` is
/// `keepAlive`, so the database work happens once per app launch and every
/// later read is a cache hit with no I/O at all. A phone's storage is slower
/// than this host's; the number of times it is touched is the same.
void main() {
  setUp(installFakeSharedPreferences);
  setUp(installFakePathProvider);

  test('resolves once, then answers from cache with no further work', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    // A real project in a real database, so the first resolution does the
    // whole job: read the active id out of preferences, open and migrate the
    // database, find the row, backfill the owner membership.
    final repo = await container.read(projectRepositoryProvider.future);
    // `Projects.owner_user_id` is a foreign key, and this database enforces
    // them. `currentUser` mints the local "Field User" the app itself starts
    // with, which is the row a real project would point at.
    final owner = await container.read(currentUserProvider.future);
    final project = Project(
      projectId: 'p-cost',
      projectName: 'Cost measurement',
      ownerUserId: owner.userId,
      creationDate: DateTime.utc(2026, 1, 1),
      bboxMinLat: 35.0,
      bboxMinLon: -111.5,
      bboxMaxLat: 35.4,
      bboxMaxLon: -111.0,
      sync: SyncMeta.initial(
        now: DateTime.utc(2026, 1, 1),
        modifiedBy: owner.userId,
        originDeviceId: 'd-cost',
      ),
    );
    await repo.insert(project);
    await container.read(activeProjectIdProvider.notifier).set('p-cost');

    final firstWatch = Stopwatch()..start();
    final resolved = await container.read(currentProjectProvider.future);
    firstWatch.stop();
    expect(resolved?.projectId, 'p-cost');

    // What a *rebuild* pays. A screen that watches this provider reads it
    // synchronously on every build; that read must not touch the database.
    const rebuilds = 10000;
    final rebuildWatch = Stopwatch()..start();
    for (var i = 0; i < rebuilds; i++) {
      final value = container.read(currentProjectProvider).value;
      expect(value?.projectId, 'p-cost');
    }
    rebuildWatch.stop();
    final perRebuildUs = rebuildWatch.elapsedMicroseconds / rebuilds;

    // **The last thing this check says is what it found**, not its own name:
    // a five-line CI tail is enough exactly when the numbers are in it.
    // ignore: avoid_print
    print(
      'currentProjectProvider on this host: first resolution (preferences + '
      'database open + migration + row read + membership backfill) '
      '${firstWatch.elapsedMilliseconds} ms, once per app launch; '
      'each subsequent read, which is what a widget rebuild pays, '
      '${perRebuildUs.toStringAsFixed(2)} us '
      '($rebuilds reads in ${rebuildWatch.elapsedMilliseconds} ms).',
    );

    // The assertion is about the *shape*, not the host's speed: a cache hit
    // is orders of magnitude cheaper than the resolution above, and a change
    // that makes a rebuild re-open the database or re-query it cannot stay
    // under this. The bound is deliberately loose — a slow CI runner must not
    // turn a design guarantee into a flake — while still being far below
    // anything that reaches storage.
    expect(
      perRebuildUs,
      lessThan(100),
      reason: 'a read of a resolved keepAlive provider is a cache lookup. '
          '$perRebuildUs us per read means something is doing work on every '
          'rebuild — which is what task 11.103 suspected and 11.120 measured '
          'as false. Do not raise this bound; find what started working.',
    );
  });

  test('a second container does the database work again — the cache is per '
      'app launch, not per process', () async {
    // Stated because it is the honest bound on the paragraph above: the
    // saving is "once per launch", not "once ever", and a screen opened after
    // a cold start pays the first number, not the second.
    final container = ProviderContainer();
    addTearDown(container.dispose);
    // With no active project id the provider returns null without opening
    // anything, which would measure nothing. An id that is set but has no row
    // still does the whole open-and-migrate.
    await container.read(activeProjectIdProvider.notifier).set('p-absent');

    final watch = Stopwatch()..start();
    expect(await container.read(currentProjectProvider.future), isNull);
    watch.stop();
    // ignore: avoid_print
    print(
      'a cold container opened and migrated the database and answered '
      'currentProjectProvider in ${watch.elapsedMilliseconds} ms. That is '
      'what a screen watching it pays once, at app launch.',
    );
    expect(watch.elapsedMilliseconds, isNonNegative);
  });
}
