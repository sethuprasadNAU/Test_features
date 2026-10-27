import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tritrack/core/providers/server_config_provider.dart';
import 'package:tritrack/core/providers/project_link_provider.dart';
import 'package:tritrack/core/providers/sync_provider.dart';
import 'package:tritrack/core/providers/auth_provider.dart';
import 'package:tritrack/data/sync/sync_failure.dart';
import 'package:tritrack/data/sync/sync_schedule.dart';
import 'package:tritrack/data/sync/sync_transport.dart';
import 'package:tritrack/features/more/screens/server_config_screen.dart';
import 'package:tritrack/widgets/sync_status_presentation.dart';

import '../../support/fake_session_store.dart';
import '../../support/fake_shared_preferences.dart';

/// **Task 11.104 — a release build refuses the address, and then blames the
/// network.**
///
/// ## Why none of this tests the throw
///
/// `requireValidServerUrl` has thrown `InvalidServerUrl` with exactly the right
/// sentence since task 10.48, and a test asserting that it throws has passed
/// throughout. Task 11.66 then measured, on a real Android release build, the
/// sync bar saying *"Offline — last synced 5 min ago"*, the Server Connection
/// screen saying *"nothing answered at that address"*, and the header saying
/// *"Server configured"* — while the network was fine, the server answered
/// `/health` throughout, and map tiles kept loading.
///
/// **The defect was never that the exception was not thrown. It was that
/// nothing caught it** — and, as measured on 2026-08-31 and recorded in
/// `InvalidServerUrl`'s doc, nothing *could*: awaiting
/// `serverHttpClientProvider.future` hands the caller a `StateError` about the
/// provider being disposed mid-load, not the exception, so the sentence is
/// destroyed rather than wrapped. So every test below starts from **a stored
/// address and a non-debug build** and asserts **what a person reads**.
///
/// The bar for "covered" is the one the task set: a test here has to fail if
/// the refusal is ever silently turned back into "Offline".
void main() {
  setUp(installFakeSharedPreferences);

  /// The state task 11.66 was in: a plain-`http://` LAN address saved, on a
  /// build that is not a debug build.
  ///
  /// `nonDebugBuildProvider` is the seam that makes this reachable at all — a
  /// test binary is neither release nor profile, so without it every check
  /// this file makes would be permanently unexercised, which is §4.1's
  /// definition of decoration.
  Future<ProviderContainer> refusedLanServer({
    String url = 'http://192.168.0.136:8080',
    bool nonDebug = true,
  }) async {
    final container = ProviderContainer(
      overrides: [
        nonDebugBuildProvider.overrideWithValue(nonDebug),
        sessionStoreProvider.overrideWithValue(FakeSessionStore()),
      ],
    );
    addTearDown(container.dispose);
    await container.read(serverConfigProvider.notifier).setUrl(url);
    return container;
  }

  group('the sync surface stops saying Offline', () {
    // **Read off `SyncStatusPresentation` rather than off a pumped widget**
    // (task 11.189). This used to pump `SyncStatusBanner` — the strip above
    // every tab — which no longer exists; the sentence and the severity it
    // asserted moved into a class that owns nothing but them, and the icon
    // that replaced the strip reads the same class. Nothing about what is
    // being checked changed, and it can no longer fail for a reason to do
    // with layout.
    test('a refused address is not reported as being offline', () async {
      final container = await refusedLanServer();
      final status = await container.read(syncControllerProvider.future);
      final presentation = SyncStatusPresentation.of(status);

      // **The assertion the task asked for**, stated as the thing that must
      // never come back rather than as the thing that should be there.
      expect(presentation.message, isNot(contains('Offline')));
      expect(presentation.icon, isNot(Icons.cloud_off));

      expect(presentation.message, contains('Not a network problem'));
      expect(presentation.icon, Icons.link_off);
      // And it is the severity that means "nothing is getting through and
      // will not until somebody changes something", not a warning about
      // being a bit behind.
      expect(presentation.severity, SyncSeverity.fault);
    });

    testWidgets('the same address on a debug build is not refused at all', (
      tester,
    ) async {
      // The control: the LAN development workflow §4.1 deliberately keeps.
      // Without this, a bar that said "refused" unconditionally would pass
      // every other test in this file.
      final container = await refusedLanServer(nonDebug: false);
      final status = await container.read(syncControllerProvider.future);

      expect(status.health, isNot(SyncHealth.serverAddressRefused));
      expect(status.unavailable, isNot(SyncUnavailable.serverAddressRefused));
    });

    test('the state is reached without a request ever being attempted', () async {
      // No session, no database, no project — nothing that a round would need.
      // If this resolves, the refusal was decided from the stored address
      // alone, which is what lets the bar be right on the first frame after a
      // cold launch instead of after a round has failed.
      final container = await refusedLanServer();
      final status = await container.read(syncControllerProvider.future);

      expect(status.unavailable, SyncUnavailable.serverAddressRefused);
      expect(status.health, SyncHealth.serverAddressRefused);
      expect(status.lastErrorMessage, contains('https://'));
    });

    test('"unavailable" here still renders — it does not vanish', () async {
      final container = await refusedLanServer();
      final status = await container.read(syncControllerProvider.future);

      // A silent bar would be the same defect one step quieter: the person
      // still cannot find out why nothing has synced.
      expect(status.isWorthShowing, isTrue);
      // ...but there is nothing to offer, so "Sync now" is not shown.
      expect(status.isAvailable, isFalse);
    });
  });

  group('the sync-status classification', () {
    test('a refused address is never classified as unreachable', () {
      // The two are identical from outside — nothing gets through — and their
      // remedies have nothing in common. One is fixed by walking somewhere
      // with signal; the other never resolves however far you walk.
      final cause = classifySyncFailure(
        const SyncTransportException(
          SyncTransportException.serverAddressRefused,
        ),
        departed: false,
      );

      expect(cause, SyncFailureCause.serverAddressRefused);
      expect(cause, isNot(SyncFailureCause.unreachable));
    });

    test('and it outranks the remedy check, so it is not "Update needed"', () {
      // This refusal carries a `userMessage`, and `refusedWithRemedy` is
      // checked on exactly that. Classified one line later, the screens would
      // head it "Update needed" — the wrong cause again, one enum member on.
      final status = SyncStatus(
        schedule: const SyncSchedule(),
        lastFailure: classifySyncFailure(
          const SyncTransportException(
            SyncTransportException.serverAddressRefused,
          ),
          departed: false,
        ),
      );

      expect(status.health, SyncHealth.serverAddressRefused);
      expect(status.health, isNot(SyncHealth.versionRefused));
      expect(status.health, isNot(SyncHealth.offline));
    });

    test('a failed round with this cause never degrades to offline', () {
      // `SyncHealth.offline` is what a `deviceFault` produced before this task,
      // and it is the state the whole task exists to keep this out of.
      for (final broken in [true, false]) {
        final status = SyncStatus(
          schedule: SyncSchedule(consecutiveFailures: broken ? 5 : 1),
          lastFailure: SyncFailureCause.serverAddressRefused,
        );
        expect(status.health, SyncHealth.serverAddressRefused);
      }
    });

    test('the words for it deny the network and name a next step', () {
      const error = SyncTransportException(
        SyncTransportException.serverAddressRefused,
      );
      final message = error.userMessage!;

      expect(message, contains('not your network'));
      expect(message, contains('Server Connection'));
    });
  });

  group('the Server Connection screen', () {
    Future<void> pumpServerScreen(
      WidgetTester tester,
      ProviderContainer container,
    ) async {
      await tester.binding.setSurfaceSize(const Size(800, 2000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: ServerConfigScreen()),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('the header stops saying "Server configured"', (tester) async {
      final container = await refusedLanServer();
      await pumpServerScreen(tester, container);

      // The surface that read as reassurance while the other two reported
      // faults, all three about the same address.
      expect(find.textContaining('Server configured'), findsNothing);
      expect(
        find.text('Saved, but this app will not use it: '
            'http://192.168.0.136:8080'),
        findsOneWidget,
      );
    });

    testWidgets('the header carries the reason and a next step', (tester) async {
      final container = await refusedLanServer();
      await pumpServerScreen(tester, container);

      expect(
        find.textContaining('will not connect over plain http://'),
        findsWidgets,
      );
      expect(find.textContaining('Use an https:// address'), findsWidgets);
    });

    testWidgets('sign-in is disabled, and says why', (tester) async {
      final container = await refusedLanServer();
      await pumpServerScreen(tester, container);

      expect(
        find.textContaining('Signing in is unavailable until the server '
            'address above is changed'),
        findsOneWidget,
      );
      final emailButton = tester.widget<OutlinedButton>(
        find.ancestor(
          of: find.text('REQUEST A SIGN-IN CODE'),
          matching: find.byType(OutlinedButton),
        ),
      );
      expect(emailButton.onPressed, isNull);
    });

    testWidgets('a usable address leaves the screen exactly as it was', (
      tester,
    ) async {
      // The other half of the control: nothing above fires for an address this
      // build accepts, so a green run of this file is evidence about the
      // refused case rather than about the screen always shouting.
      final container = await refusedLanServer(
        url: 'https://tracker.example.edu',
      );
      await pumpServerScreen(tester, container);

      expect(
        find.text('Server configured: https://tracker.example.edu'),
        findsOneWidget,
      );
      expect(find.textContaining('will not use it'), findsNothing);
      final emailButton = tester.widget<OutlinedButton>(
        find.ancestor(
          of: find.text('REQUEST A SIGN-IN CODE'),
          matching: find.byType(OutlinedButton),
        ),
      );
      expect(emailButton.onPressed, isNotNull);
    });
  });

  group('the seams beyond the sync bar', () {
    // **Fixing the class, not the instance** (the standing criterion). The
    // sync bar was the surface task 11.66 measured, but four call sites read
    // the http client and none of them could receive the refusal. Publish,
    // join and the members screen all render
    // `SyncTransportException.userMessage`, so a named reason reaching them is
    // a sentence reaching a person.
    test('publishing a project refuses with a named reason, not a StateError',
        () async {
      final container = await refusedLanServer();

      await expectLater(
        container.read(projectLinkControllerProvider.notifier).publish('p1'),
        throwsA(
          isA<SyncTransportException>().having(
            (e) => e.reason,
            'reason',
            SyncTransportException.serverAddressRefused,
          ),
        ),
      );
    });

    test('and the sentence it carries is one a person can act on', () async {
      final container = await refusedLanServer();
      try {
        await container.read(projectLinkControllerProvider.notifier).publish(
              'p1',
            );
        fail('publish should have been refused');
      } on SyncTransportException catch (e) {
        // What `projects_screen.dart` puts on screen.
        expect(e.userMessage, isNotNull);
        expect(e.userMessage, contains('not your network'));
      }
    });
  });

  group('the three faults the URL field used to share one sentence for', () {
    // Each of these produced *"Enter a full URL starting with http:// or
    // https://"* before this task — a sentence that is the right instruction
    // for exactly one of them.
    test('a bare host and port is told to add a scheme', () {
      final problem = describeServerUrlProblem('192.168.1.42:8080');

      expect(problem!.fault, ServerUrlFault.noScheme);
      expect(problem.message, contains('Put https:// in front of it'));
    });

    test('a mistyped scheme is told to check the scheme', () {
      final problem = describeServerUrlProblem('htp://192.168.1.42:8080');

      expect(problem!.fault, ServerUrlFault.unsupportedScheme);
      expect(problem.message, contains('before ://'));
    });

    test('text that cannot be read at all says so, and shows the shape', () {
      final problem = describeServerUrlProblem('http://[bad');

      expect(problem!.fault, ServerUrlFault.unreadable);
      expect(problem.message, contains('cannot read that as a server address'));
    });

    test('the three sentences are actually three sentences', () {
      final messages = {
        describeServerUrlProblem('192.168.1.42:8080')!.message,
        describeServerUrlProblem('htp://192.168.1.42:8080')!.message,
        describeServerUrlProblem('http://[bad')!.message,
      };

      expect(messages, hasLength(3));
    });

    test('the insecure-address case is one of them', () {
      // The task's own wording: "make sure the insecure-address case is one of
      // them." It is a fault of the field, not only of the transport.
      final problem = describeServerUrlProblem(
        'http://192.168.1.42:8080',
        releaseMode: true,
      );

      expect(problem!.fault, ServerUrlFault.cleartextInThisBuild);
    });

    test('a fragment no longer makes a good address unreadable', () {
      // `Uri.isAbsolute` is false whenever a fragment is present, so the field
      // used to refuse an address `ServerConfig` would have accepted and
      // flattened. A validator stricter than the thing it guards refuses work
      // that would have succeeded.
      expect(
        describeServerUrlProblem(
          'http://192.168.1.42:8080/#top',
          releaseMode: false,
        ),
        isNull,
      );
    });
  });

  group('every refusal ends with something to try', () {
    // The task's first requirement: a diagnosis is not help. Each of these
    // must leave somebody able to act, which for an address means naming the
    // shape to type or the route to getting one.
    for (final probe in <(String, String, bool)>[
      ('192.168.1.42:8080', 'noScheme', false),
      ('htp://192.168.1.42:8080', 'unsupportedScheme', false),
      ('http://[bad', 'unreadable', false),
      ('http://192.168.1.42:8080', 'cleartextInThisBuild', true),
      ('http://tracker.example.edu', 'cleartextToPublicHost', false),
    ]) {
      test('${probe.$2} names https:// as the thing to type', () {
        final problem = describeServerUrlProblem(
          probe.$1,
          releaseMode: probe.$3,
        );

        expect(problem, isNotNull, reason: '${probe.$1} should be refused');
        expect(problem!.fault.name, probe.$2);
        expect(problem.message, contains('https://'));
      });
    }

    test('the cleartext refusal names both ways to get an https:// address',
        () {
      // "This server is plain http, which release builds refuse" is a
      // diagnosis. The two routes below are the only two that exist, and both
      // are the ones README.md §4 names.
      final message = describeServerUrlProblem(
        'http://192.168.0.136:8080',
        releaseMode: true,
      )!.message;

      expect(message, contains('docker-compose.tls.yml'));
      expect(message, contains('debug build'));
      // And it says, in so many words, that this is not the network — because
      // that is the belief it exists to correct.
      expect(message, contains('Your network is fine'));
    });
  });
}
