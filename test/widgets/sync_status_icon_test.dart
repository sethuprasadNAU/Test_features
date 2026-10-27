import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:tritrack/core/providers/sync_provider.dart';
import 'package:tritrack/data/sync/sync_failure.dart';
import 'package:tritrack/data/sync/sync_schedule.dart';
import 'package:tritrack/widgets/sync_status_icon.dart';
import 'package:tritrack/widgets/sync_status_presentation.dart';

import '../support/fake_shared_preferences.dart';

/// **The surface that replaced the sync bar** (task 11.189): one 28-pixel
/// icon over the Main Map, above the "+", and a dot on the More tab's icon.
///
/// The sentences themselves are asserted in
/// `sync_status_presentation_test.dart`, which needs no widget at all. This
/// file asserts the three things that are properties of the *icon*:
///
/// 1. **Task 10.2's invariant** — a person who never configured a server sees
///    nothing here, not a green tick. This is the one a redesign is most
///    likely to break, because "no status, so show the calm one" is the
///    tempting simplification and it is a lie: a tick claims a sync
///    succeeded when nothing ever tried.
/// 2. The colour and the shape follow the severity, so a glance is enough and
///    a person who cannot tell this amber from this red still can.
/// 3. It taps through, because a colour is a summary and the answer is on
///    `SyncStatusScreen`.
void main() {
  setUp(installFakeSharedPreferences);

  const destinationKey = Key('sync-status-screen-stand-in');

  Future<GoRouter> pumpIcon(
    WidgetTester tester,
    SyncStatus? status, {
    Widget Function() build = SyncStatusIcon.new,
  }) async {
    final container = ProviderContainer(
      overrides: [
        syncControllerProvider.overrideWith(() => _FakeSync(status)),
      ],
    );
    addTearDown(container.dispose);
    final router = GoRouter(
      initialLocation: '/',
      routes: [
        GoRoute(
          path: '/',
          builder: (c, s) => Scaffold(body: Center(child: build())),
          routes: [
            GoRoute(
              path: 'more/sync-status',
              builder: (c, s) =>
                  const Scaffold(body: SizedBox(key: destinationKey)),
            ),
          ],
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();
    return router;
  }

  Color glyphColour(WidgetTester tester) =>
      tester.widget<Icon>(find.byType(Icon)).color!;
  IconData glyph(WidgetTester tester) =>
      tester.widget<Icon>(find.byType(Icon)).icon!;

  group("task 10.2's invariant: no server, no icon", () {
    testWidgets('a device that never configured a server shows nothing',
        (tester) async {
      await pumpIcon(
        tester,
        const SyncStatus(
          schedule: SyncSchedule(),
          unavailable: SyncUnavailable.notConfigured,
        ),
      );

      expect(
        find.byKey(const ValueKey('sync-status-icon')),
        findsNothing,
        reason: 'Task 10.2: a person who never configured a server sees no '
            'sync surface at all. **A green tick here would be claiming a '
            'sync succeeded when nothing has ever tried**, which is the exact '
            'class of lie tasks 10.28, 11.41, 11.54 and 11.114 each removed '
            'from this surface one state at a time.',
      );
      expect(find.byType(Icon), findsNothing);
    });

    testWidgets('and neither does the tab badge', (tester) async {
      await pumpIcon(
        tester,
        const SyncStatus(
          schedule: SyncSchedule(),
          unavailable: SyncUnavailable.notConfigured,
        ),
        build: () =>
            const SyncStatusBadge(child: Icon(Icons.more_horiz)),
      );

      expect(find.byKey(const ValueKey('sync-status-tab-badge')), findsNothing);
      // The tab keeps its own icon — the badge is absent, not the tab.
      expect(find.byIcon(Icons.more_horiz), findsOneWidget);
    });

    testWidgets('nor while the status has not loaded yet', (tester) async {
      // A provider that has not resolved is not evidence of health either.
      await pumpIcon(tester, null);

      expect(find.byKey(const ValueKey('sync-status-icon')), findsNothing);
    });

    testWidgets(
      'but a project the person has left does show, because that is an answer',
      (tester) async {
        // `isWorthShowing`, not `isAvailable`. Every other reason sync is
        // unavailable is a reason there is nothing to say; this one is the
        // answer to a question somebody has just asked by leaving (task
        // 11.54), and a blank space would be a control that works and says
        // nothing.
        await pumpIcon(
          tester,
          const SyncStatus(
            schedule: SyncSchedule(),
            unavailable: SyncUnavailable.leftProject,
          ),
        );

        expect(
          find.byKey(const ValueKey('sync-status-icon')),
          findsOneWidget,
        );
        expect(glyph(tester), Icons.logout);
      },
    );
  });

  group('the colour and the shape say the severity', () {
    testWidgets('a healthy device is a green check', (tester) async {
      await pumpIcon(
        tester,
        SyncStatus(
          schedule: const SyncSchedule(),
          lastSuccessAt: DateTime.now().toUtc(),
        ),
      );

      expect(glyph(tester), Icons.check_circle);
      expect(glyphColour(tester), SyncSeverity.healthy.color);
    });

    testWidgets('a held record is a red exclamation, not a warning',
        (tester) async {
      // The state that means a primary record is on this device and nowhere
      // else. Nothing here may read as "a bit behind."
      await pumpIcon(
        tester,
        SyncStatus(
          schedule: const SyncSchedule(),
          lastSuccessAt: DateTime.now().toUtc(),
          heldCount: 2,
        ),
      );

      expect(glyph(tester), Icons.error);
      expect(glyphColour(tester), SyncSeverity.fault.color);
    });

    testWidgets('records the server sent that could not be read are amber',
        (tester) async {
      await pumpIcon(
        tester,
        const SyncStatus(
          schedule: SyncSchedule(),
          droppedOnArrivalCount: 2,
        ),
      );

      expect(glyph(tester), Icons.warning_amber_rounded);
      expect(glyphColour(tester), SyncSeverity.warning.color);
    });

    testWidgets('being offline is neither, and it is not green either',
        (tester) async {
      // **The field condition, not a fault.** An amber icon here would cry
      // wolf on every field day, and a green one would be false.
      await pumpIcon(
        tester,
        SyncStatus(
          schedule: const SyncSchedule(),
          lastFailure: SyncFailureCause.unreachable,
          lastSuccessAt: DateTime.now().toUtc(),
        ),
      );

      expect(glyph(tester), Icons.cloud_off);
      expect(glyphColour(tester), SyncSeverity.quiet.color);
      expect(glyphColour(tester), isNot(SyncSeverity.healthy.color));
      expect(glyphColour(tester), isNot(SyncSeverity.warning.color));
    });
  });

  testWidgets('it is the size MapNorthArrow is, and does not grow with text',
      (tester) async {
    // Michael named the north arrow as the model — "small and selectable and
    // out of the way, still clickable" — and two floating map controls of
    // different sizes at the same corner would read as two kinds of thing.
    tester.platformDispatcher.textScaleFactorTestValue = 3.12; // AX5
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await pumpIcon(
      tester,
      SyncStatus(
        schedule: const SyncSchedule(),
        lastSuccessAt: DateTime.now().toUtc(),
      ),
    );

    expect(
      tester.getSize(find.byKey(const ValueKey('sync-status-icon'))),
      const Size(SyncStatusIcon.diameter, SyncStatusIcon.diameter),
      reason: 'An icon is an icon, not a character. If this grows with the '
          'text size it starts covering the map at exactly the sizes task '
          '11.189 gave the map back.',
    );
  });

  testWidgets('the sentence reaches a screen reader', (tester) async {
    // The whole point of the change is that the map keeps its pixels, so the
    // sentence cannot be drawn on the map. An icon-only status control that
    // announced itself as "warning icon" would be worse than the bar it
    // replaced.
    final handle = tester.ensureSemantics();
    await pumpIcon(
      tester,
      SyncStatus(
        schedule: const SyncSchedule(),
        lastSuccessAt: DateTime.now().toUtc(),
        heldCount: 1,
      ),
    );

    expect(
      find.bySemanticsLabel(
        RegExp(r"Sync status\. 1 record isn't on the server"),
      ),
      findsOneWidget,
    );
    handle.dispose();
  });

  testWidgets('tapping it opens the screen that holds the whole story',
      (tester) async {
    // **A colour is a summary; the tap-through is the answer.** Michael:
    // "the map screen just needs to indicate to the user if everything is
    // okay or not and can click in if they need to review what's wrong."
    await pumpIcon(
      tester,
      SyncStatus(
        schedule: const SyncSchedule(),
        lastSuccessAt: DateTime.now().toUtc(),
        heldCount: 1,
      ),
    );

    await tester.tap(find.byKey(const ValueKey('sync-status-icon')));
    await tester.pumpAndSettle();

    expect(find.byKey(destinationKey), findsOneWidget);
  });
}

class _FakeSync extends SyncController {
  _FakeSync(this._status);

  final SyncStatus? _status;

  @override
  Future<SyncStatus> build() async {
    final status = _status;
    // A null fixture means "the provider has not produced a status yet",
    // which is a real state on launch and must not read as health.
    if (status == null) return Completer<SyncStatus>().future;
    return status;
  }
}
