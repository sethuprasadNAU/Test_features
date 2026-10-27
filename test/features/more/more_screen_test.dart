import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tritrack/core/providers/active_selection_provider.dart';
import 'package:tritrack/core/providers/app_context_provider.dart';
import 'package:tritrack/core/providers/database_provider.dart';
import 'package:tritrack/core/providers/server_config_provider.dart';
import 'package:tritrack/core/providers/sync_provider.dart';
import 'package:tritrack/data/sync/sync_failure.dart';
import 'package:tritrack/data/sync/sync_schedule.dart';
import 'package:tritrack/data/db/app_database.dart';
import 'package:tritrack/data/db/schema.dart';
import 'package:tritrack/features/more/screens/more_screen.dart';
import 'package:tritrack/widgets/sync_status_icon.dart';
import 'package:tritrack/widgets/sync_status_presentation.dart';

import '../../data/fixtures.dart';
import '../../support/app_shell_harness.dart';
import '../../support/fake_shared_preferences.dart';

/// Task 7.5 acceptance criterion: the current user's name and email are
/// visible without leaving the app's normal navigation. `MoreScreen` is the
/// hub every user passes through, so the Profile tile's subtitle is where
/// this is surfaced.
void main() {
  setUp(installFakeSharedPreferences);

  Future<ProviderContainer> readyContainer(
    WidgetTester tester, {
    required String email,
    SyncStatus? syncStatus,
  }) async {
    final container = ProviderContainer(
      overrides: [
        appDatabaseProvider.overrideWith((ref) => AppDatabase.openInMemory()),
        if (syncStatus != null)
          syncControllerProvider.overrideWith(() => _FakeSync(syncStatus)),
      ],
    );
    addTearDown(container.dispose);
    await tester.runAsync(() async {
      final db = await container.read(appDatabaseProvider.future);
      await db.raw.insert(
        Tables.users,
        sampleUser(id: 'user-1', email: email).toColumns(),
      );
      await container.read(activeUserIdProvider.notifier).set('user-1');
      await container.read(currentUserProvider.future);
    });
    return container;
  }

  Future<void> pumpScreen(
    WidgetTester tester,
    ProviderContainer container,
  ) async {
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: MoreScreen()),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('shows the current user name and email under the Profile tile', (
    tester,
  ) async {
    final container = await readyContainer(tester, email: 'sam@example.com');
    await pumpScreen(tester, container);

    expect(find.text('Sam Ranger · sam@example.com'), findsOneWidget);
  });

  testWidgets('shows an unset-identity subtitle for a placeholder user', (
    tester,
  ) async {
    final container = await readyContainer(
      tester,
      email: 'field-user-abc@local.tritrack',
    );
    await pumpScreen(tester, container);

    expect(find.text('Identity not set'), findsOneWidget);
  });

  // Task 10.2: "not configured" is the default and a fully supported mode,
  // not an error state — the More hub states that plainly rather than
  // hiding the row or implying something is broken.
  testWidgets(
    'shows "not configured" under Server Connection with no server set',
    (tester) async {
      final container = await readyContainer(tester, email: 'sam@example.com');
      await pumpScreen(tester, container);
      await tester.scrollUntilVisible(find.text('Server Connection'), 200);

      expect(find.text('Not configured — working offline'), findsOneWidget);
    },
  );

  testWidgets(
    'shows the configured URL under Server Connection once one is set',
    (tester) async {
      final container = await readyContainer(tester, email: 'sam@example.com');
      await container
          .read(serverConfigProvider.notifier)
          .setUrl('http://192.168.1.42:8080');
      await pumpScreen(tester, container);
      await tester.scrollUntilVisible(find.text('Server Connection'), 200);

      expect(find.text('http://192.168.1.42:8080'), findsOneWidget);
    },
  );

  /// **The cloud-backup retirement notice's new home** (task 11.189).
  ///
  /// It was the second of the app shell's two banners, above every tab, where
  /// task 11.149 measured it taking **550 of a 6.1-inch phone's 852 logical
  /// pixels at AX5** — a one-time, dismissible notice about a feature that
  /// was removed, crowding out whatever screen somebody opened the app to
  /// use.
  ///
  /// Michael's answer of 2026-09-07 was to fold it into the new sync status
  /// icon. **Task 11.189 did not, and said so plainly so he can overrule it:
  /// it is not a status.** No state of the app is described by "retirement
  /// notice pending", and putting it behind a live status icon would make
  /// that icon lie about sync in order to carry an unrelated fact. So it came
  /// here, where it costs no other screen anything.
  group('the cloud-backup retirement notice (task 11.189)', () {
    testWidgets('appears at the top of More for a device that had a folder '
        'linked', (tester) async {
      final container = await readyContainer(tester, email: 'sam@example.com');
      await tester.runAsync(seedCloudBackupRetiredNotice);
      await pumpScreen(tester, container);

      final notice = find.byKey(const ValueKey('cloud-backup-retired-notice'));
      expect(notice, findsOneWidget);
      // First in the list, because it is the one thing here somebody has not
      // already seen — and because it leaves for good once they have.
      expect(
        tester.getTopLeft(notice).dy,
        lessThan(tester.getTopLeft(find.text('Profile')).dy),
      );
    });

    testWidgets('is absent for everybody else', (tester) async {
      // Most devices never linked a folder, and a notice about losing a
      // feature you never had is noise.
      final container = await readyContainer(tester, email: 'sam@example.com');
      await pumpScreen(tester, container);

      expect(
        find.byKey(const ValueKey('cloud-backup-retired-notice')),
        findsNothing,
      );
    });

    testWidgets('opens the explanation, and dismissing it is permanent',
        (tester) async {
      final container = await readyContainer(tester, email: 'sam@example.com');
      await tester.runAsync(seedCloudBackupRetiredNotice);
      await pumpScreen(tester, container);

      await tester.tap(
        find.byKey(const ValueKey('cloud-backup-retired-notice')),
      );
      await tester.pumpAndSettle();
      // The dialog is unchanged — it is where the explanation always was.
      expect(
        find.textContaining('TriTrack used to copy this project into a folder'),
        findsOneWidget,
      );

      await tester.tap(find.text('Got it'));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('cloud-backup-retired-notice')),
        findsNothing,
        reason: 'It describes something that already happened and cannot be '
            'un-happened. Repeating it after somebody has read it is just '
            'noise, which is why this one is dismissible and the banner it '
            'replaced was not.',
      );
    });
  });

  /// **The dot on the More tab has to point somewhere** (task 11.189).
  ///
  /// Michael, on 2026-09-07, after seeing the tab badge:
  ///
  /// > *"there should be a corresponding dot on the sync line in the more menu
  /// > so the user knows where to look in the more menu — ie what was causing
  /// > the original dot to be green, yellow or red."*
  ///
  /// A coloured dot on a navigation icon says *something* is wrong and leaves
  /// somebody opening menu entries to find out which. These assert the two
  /// properties that make it a signal rather than an alarm: **the same colour
  /// appears on the Sync Status row**, and **the row is never missing while
  /// the tab is badged**.
  group('the sync status dot on the Sync Status row (task 11.189)', () {
    Future<void> pumpWithServer(
      WidgetTester tester, {
      required SyncStatus status,
    }) async {
      final container = await readyContainer(
        tester,
        email: 'sam@example.com',
        syncStatus: status,
      );
      await container
          .read(serverConfigProvider.notifier)
          .setUrl('https://server.example.com');
      await pumpScreen(tester, container);
      await tester.scrollUntilVisible(find.text('Sync Status'), 200);
      await tester.pumpAndSettle();
    }

    /// The colour of the dot beside the words "Sync Status".
    Color dotColour(WidgetTester tester) => tester
        .widget<Icon>(find.byKey(const ValueKey('sync-status-row-dot')))
        .color!;

    for (final (name, status) in <(String, SyncStatus)>[
      (
        'a healthy device',
        SyncStatus(
          schedule: const SyncSchedule(),
          lastSuccessAt: DateTime.now().toUtc(),
        ),
      ),
      (
        'a device holding a record the server refused',
        SyncStatus(
          schedule: const SyncSchedule(),
          lastSuccessAt: DateTime.now().toUtc(),
          heldCount: 1,
        ),
      ),
      (
        'a device missing records the server sent',
        const SyncStatus(
          schedule: SyncSchedule(),
          droppedOnArrivalCount: 2,
        ),
      ),
      (
        'a device out of signal',
        SyncStatus(
          schedule: const SyncSchedule(),
          lastFailure: SyncFailureCause.unreachable,
          lastSuccessAt: DateTime.now().toUtc(),
        ),
      ),
    ]) {
      testWidgets('$name gets the same colour here as on the tab',
          (tester) async {
        await pumpWithServer(tester, status: status);

        expect(find.byType(SyncStatusDot), findsOneWidget);
        expect(
          dotColour(tester),
          SyncStatusPresentation.of(status).color,
          reason: 'The dot on the More tab and the dot on this row are the '
              'same widget reading the same provider, so they cannot show '
              'different colours. If this has failed, one of them has grown '
              'its own opinion about severity — which is exactly what the '
              'old sync bar and the sync status card had done to each other '
              'about `healthy` for as long as both existed.',
        );
      });
    }

    testWidgets('sits to the right of the words, and is big enough to find',
        (tester) async {
      // **Michael, 2026-09-07, on the first version:** *"you put it on the
      // icon on the left and it is hard to see."* It was an 8-pixel `Badge`
      // on the leading icon — the tab badge's size, which is right for an
      // annotation on a small tab and a speck on a full-width row.
      //
      // Both halves of his correction are asserted, because a dot that got
      // bigger and stayed on the left, or moved right and stayed 8 pixels,
      // would each satisfy half of it.
      await pumpWithServer(
        tester,
        status: SyncStatus(
          schedule: const SyncSchedule(),
          lastSuccessAt: DateTime.now().toUtc(),
        ),
      );

      final words = tester.getRect(find.text('Sync Status'));
      final dot = tester.getRect(
        find.byKey(const ValueKey('sync-status-row-dot')),
      );
      expect(
        dot.left,
        greaterThanOrEqualTo(words.right),
        reason: 'to the right of the words, not on the icon at the left',
      );
      expect(
        dot.center.dy,
        closeTo(words.center.dy, 2),
        reason: 'and on the same line as them, so it reads as part of the row',
      );
      expect(
        dot.width,
        greaterThan(SyncStatusBadge.dotSize),
        reason: 'and larger than the tab badge, which is what was hard to '
            'see. ${dot.width} against ${SyncStatusBadge.dotSize}.',
      );
    });

    testWidgets(
      'a device with no server has neither a dot nor a row to point at',
      (tester) async {
        // **The two gates are one fact.** `SyncController.build` returns
        // `notConfigured` from exactly the `serverConfigProvider` answer this
        // screen reads to decide whether to show the row at all, so a badged
        // tab can never point at a menu entry that is not there. Asserted
        // rather than argued, because they are written in two different files
        // and nothing else joins them.
        final container = await readyContainer(
          tester,
          email: 'sam@example.com',
        );
        await pumpScreen(tester, container);

        expect(find.text('Sync Status'), findsNothing);
        expect(find.byType(SyncStatusDot), findsNothing);
      },
    );
  });
}

class _FakeSync extends SyncController {
  _FakeSync(this._status);

  final SyncStatus _status;

  @override
  Future<SyncStatus> build() async => _status;
}
