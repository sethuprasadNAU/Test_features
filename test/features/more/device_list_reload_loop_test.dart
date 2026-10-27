/// **Task 11.61 part 2 — the freeze, tested rather than reasoned about.**
///
/// ## What happened
///
/// Michael signed his iPhone out from his Mac on 2026-08-29. The revocation
/// worked; after a force-restart the iPhone was properly signed out. **But the
/// app had to be killed**, which is the most severe thing anybody has reported
/// on this project. He answered the three questions that narrow it: the phone
/// was **on the Server Connection screen**, he **touched nothing**, and
/// **nothing was spinning** — no loading indicator anywhere.
///
/// ## The candidate, and why it is only a candidate
///
/// `_SignedInDevices.build` watches the stored session and compares it to the
/// last one with **`identical`** — reference equality. When they differ it
/// schedules `_reload()` in a post-frame callback; `_reload()` fetches and
/// calls `setState`; `setState` runs `build` again. **If that provider ever
/// emits an object that is equal but not identical, the comparison is false
/// every pass and the screen reloads forever** — which saturates the interface
/// thread, is unresponsive, and shows nothing spinning, matching all three
/// facts where a merely hung request matches none of them.
///
/// The plan offered that as *a reading, not a finding*, and told this task to
/// **watch the loop fail before believing a fix addresses it.** This file is
/// that instruction carried out: the first test breaks the identity comparison
/// deliberately and proves the counter can see a loop; the rest put the screen
/// in the state Michael described and count.
///
/// ## The answer
///
/// **The mechanism is real and the app does not reach it.** The deliberate
/// break loops for as long as frames are produced — measured, 13 fetches across
/// 25 pumped frames — so the counter below can see a loop of exactly this
/// shape. Put in
/// the state Michael described, with the session revoked from another device
/// and nothing touched, the screen asks **once** and stops. So do a server that
/// answers nothing at all, and a healthy list.
///
/// **Why it does not reach it**, read off the code and consistent with the
/// measurement: `CurrentSession` is `keepAlive` and its `build` re-runs only
/// when `serverConfigProvider` changes — which happens when somebody saves an
/// address — or on an explicit invalidation, and **nothing in `lib/` invalidates
/// it.** Every other way its value changes is an assignment to a genuinely
/// different value: a completed sign-in, or `null` from a sign-out or a
/// revocation, and `null` converges on the next pass because `identical(null,
/// null)` is true.
///
/// **So this is reported as not reproduced, and the freeze stays open.** The
/// plan's own instruction is the reason: *a speculative fix to an unreproduced
/// freeze leaves everybody believing it is closed*, which is worse than an open
/// entry. What this file leaves behind is the instrument — if the freeze
/// happens again, the first question is whether the count rises, and there is
/// now something that answers it.
///
/// ## What the counter cannot do
///
/// It counts requests, so it can only see a loop that **reaches the network**.
/// A rebuild storm that never got as far as a fetch would be invisible to it —
/// but that is not the mechanism under test, because in this widget the reload
/// *is* what the rebuild schedules.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tritrack/core/providers/auth_provider.dart';
import 'package:tritrack/core/providers/database_provider.dart';
import 'package:tritrack/core/providers/device_id_provider.dart';
import 'package:tritrack/core/providers/server_config_provider.dart';
import 'package:tritrack/core/providers/server_http_client_provider.dart';
import 'package:tritrack/data/auth/session_store.dart';
import 'package:tritrack/data/db/app_database.dart';
import 'package:tritrack/features/more/screens/server_config_screen.dart';

import '../../support/app_shell_harness.dart';
import '../../support/fake_shared_preferences.dart';

const _thisDeviceId = 'laptop-device-id';

/// A session store that hands back an **equal but not identical** session on
/// every read.
///
/// This is the deliberate break. `FakeSessionStore` returns the same instance
/// every time, so `identical` holds and the screen behaves as it does in the
/// app; this one models a provider that re-reads and rebuilds its value, which
/// is the shape the candidate mechanism needs.
class _FreshEachReadSessionStore extends SessionStore {
  _FreshEachReadSessionStore(this._session);

  StoredSession? _session;
  int reads = 0;

  @override
  Future<void> ensureWritable() async {}

  @override
  Future<StoredSession?> read() async {
    reads++;
    final held = _session;
    if (held == null) return null;
    return StoredSession(
      token: held.token,
      userId: held.userId,
      email: held.email,
      expiresAt: held.expiresAt,
    );
  }

  @override
  Future<void> write(StoredSession session) async => _session = session;

  @override
  Future<void> clear() async => _session = null;
}

StoredSession _liveSession() => StoredSession(
  token: 'session-token',
  userId: 'user-1',
  email: 'sam@example.com',
  expiresAt: DateTime.now().toUtc().add(const Duration(days: 7)),
);

/// Two devices, as the server reports them.
String _sessionsBody() => jsonEncode({
  'sessions': [
    {
      'device_id': _thisDeviceId,
      'first_signed_in_at': DateTime.utc(2026, 8, 3).toIso8601String(),
      'last_seen_at': DateTime.utc(2026, 8, 14).toIso8601String(),
      'expires_at': DateTime.utc(2026, 9, 1).toIso8601String(),
      'is_current_device': true,
    },
  ],
});

void main() {
  setUp(installFakeSharedPreferences);

  /// Mounts the screen **inside the real tab shell at 6.1-inch phone
  /// geometry**, scrolls the device list into view, and then pumps [rounds]
  /// times touching nothing — the condition Michael described.
  ///
  /// **Not pumped bare, deliberately.** The device list lives near the bottom
  /// of a `ListView`, so on a phone it is not built until somebody scrolls to
  /// it — which means a test given a 2200-pixel surface would be measuring a
  /// screen that mounts the section immediately, and the freeze happened on a
  /// phone. Scrolling to it is also what Michael would have done.
  ///
  /// Each round gives any pending fetch time to land and any post-frame
  /// callback time to run, so a screen that reloads on every rebuild has every
  /// opportunity to do so.
  Future<void> pumpUntouched(
    WidgetTester tester,
    ProviderContainer container, {
    int rounds = 25,
  }) async {
    await pumpInAppShell(
      tester,
      container: container,
      screen: const ServerConfigScreen(),
      tabIndex: 4,
    );
    await tester.runAsync(() async {
      await tester.dragUntilVisible(
        find.text('Devices you are signed in on'),
        find.byType(Scrollable).first,
        const Offset(0, -120),
      );
      for (var i = 0; i < rounds; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
        await tester.pump(const Duration(milliseconds: 10));
      }
    });
  }

  Future<ProviderContainer> screenSignedIn({
    required SessionStore store,
    required http.Client client,
  }) async {
    final container = ProviderContainer(
      overrides: [
        appDatabaseProvider.overrideWith((ref) => AppDatabase.openInMemory()),
        sessionStoreProvider.overrideWithValue(store),
        serverHttpClientProvider.overrideWith((ref) async => client),
        deviceIdProvider.overrideWith((ref) async => _thisDeviceId),
      ],
    );
    await container
        .read(serverConfigProvider.notifier)
        .setUrl('http://test.local');
    return container;
  }

  testWidgets(
    'the instrument, watched failing: a session that is equal but not '
    'identical reloads without end',
    (tester) async {
      // **The deliberate break.** Two things together produce the candidate
      // mechanism: a store that returns a fresh object per read, and something
      // that makes the provider re-read. In the app the second would be
      // whatever re-runs `CurrentSession.build`; here the fetch itself does it,
      // which is the tightest possible version of the loop and exactly what the
      // counter has to be able to see.
      late ProviderContainer container;
      var listCalls = 0;

      final store = _FreshEachReadSessionStore(_liveSession());
      final client = MockClient((request) async {
        if (request.url.path == '/auth/sessions') {
          listCalls++;
          container.invalidate(currentSessionProvider);
          return http.Response(
            _sessionsBody(),
            200,
            headers: const {'content-type': 'application/json'},
          );
        }
        return http.Response('not found', 404);
      });

      container = await screenSignedIn(store: store, client: client);
      addTearDown(container.dispose);
      await pumpUntouched(tester, container);

      // **Measured on 2026-09-03: 13 fetches across 25 pumped frames**, inside
      // the real shell at phone geometry — a request every other frame, for as
      // long as frames are produced, which on a phone is what an unresponsive
      // app with nothing spinning looks like. The number is a property of the
      // pump loop rather than of a device; what matters is that it does not
      // stop.
      expect(
        listCalls,
        greaterThan(5),
        reason:
            'The counter cannot see a reload loop, so nothing else in this '
            'file means anything. Either the break stopped working or the '
            'pumping is not giving the post-frame callback a chance to run.',
      );
    },
  );

  testWidgets(
    'the state Michael described: revoked from another device, nothing '
    'touched — the screen asks once and stops',
    (tester) async {
      // The server has destroyed this device's session, so the device list
      // route answers 401. This is the exact moment the freeze happened.
      var listCalls = 0;
      final client = MockClient((request) async {
        if (request.url.path == '/auth/sessions') {
          listCalls++;
          return http.Response('unauthorized', 401);
        }
        return http.Response('not found', 404);
      });

      final container = await screenSignedIn(
        store: _StableSessionStore(_liveSession()),
        client: client,
      );
      addTearDown(container.dispose);
      await pumpUntouched(tester, container);

      expect(
        listCalls,
        1,
        reason:
            'The candidate mechanism would show as a rising count here. It '
            'does not: a 401 leaves the stored session untouched, so the '
            'identity comparison holds and nothing reschedules.',
      );
      expect(
        find.textContaining('Could not read your signed-in devices'),
        findsOneWidget,
        reason: 'and the screen says so, rather than sitting silent',
      );
    },
  );

  testWidgets('a server that answers nothing at all also asks once and stops', (
    tester,
  ) async {
    // The other half of what a revoked device meets in the field: not a
    // refusal, but silence. Counted separately because the code paths differ
    // — a thrown transport failure rather than a status.
    var listCalls = 0;
    final client = MockClient((request) async {
      listCalls++;
      throw const _NothingAnswered();
    });

    final container = await screenSignedIn(
      store: _StableSessionStore(_liveSession()),
      client: client,
    );
    addTearDown(container.dispose);
    await pumpUntouched(tester, container);

    expect(listCalls, 1);
  });

  testWidgets('a healthy list is fetched once, not repeatedly', (tester) async {
    var listCalls = 0;
    final client = MockClient((request) async {
      if (request.url.path == '/auth/sessions') {
        listCalls++;
        return http.Response(
          _sessionsBody(),
          200,
          headers: const {'content-type': 'application/json'},
        );
      }
      return http.Response('not found', 404);
    });

    final container = await screenSignedIn(
      store: _StableSessionStore(_liveSession()),
      client: client,
    );
    addTearDown(container.dispose);
    await pumpUntouched(tester, container);

    expect(listCalls, 1);
  });
}

/// The store the app actually behaves like: one session object, handed back by
/// reference.
class _StableSessionStore extends SessionStore {
  _StableSessionStore(this._session);

  StoredSession? _session;

  @override
  Future<void> ensureWritable() async {}

  @override
  Future<StoredSession?> read() async => _session;

  @override
  Future<void> write(StoredSession session) async => _session = session;

  @override
  Future<void> clear() async => _session = null;
}

class _NothingAnswered implements Exception {
  const _NothingAnswered();
}
