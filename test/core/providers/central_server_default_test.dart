import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tritrack/core/providers/auth_provider.dart';
import 'package:tritrack/core/providers/server_config_provider.dart';
import 'package:tritrack/features/more/screens/server_config_screen.dart';

import '../../support/app_shell_harness.dart';
import '../../support/dart_source.dart';
import '../../support/fake_session_store.dart';
import '../../support/fake_shared_preferences.dart';

/// Task 11.324, item 4 — **the app ships with the central server's address
/// filled in, and it can still be changed** (`CLAUDE.md`, standing decision 3:
/// "We are moving to a central server not a project specific server
/// deployment").
///
/// The address lives in one constant, `centralServerBaseUrl`, which is empty
/// until the central server's address is known. These tests override it
/// through [centralServerAddressProvider] so the mechanism is exercised with a
/// real-looking value today.
void main() {
  const central = 'https://central.tritrack.example';
  const storageKey = 'server_base_url_v1';

  setUp(installFakeSharedPreferences);

  ProviderContainer containerWith(String address) {
    final container = ProviderContainer(
      overrides: [
        centralServerAddressProvider.overrideWithValue(address),
        sessionStoreProvider.overrideWithValue(FakeSessionStore()),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  test('a phone that has never saved an address uses the central one', () async {
    final config = await containerWith(central).read(serverConfigProvider.future);
    expect(config.baseUrl, central);
  });

  test('with no central address known, nothing is filled in', () async {
    final config = await containerWith('').read(serverConfigProvider.future);
    expect(config.isConfigured, isFalse);
  });

  test('clearing the field means offline, and it stays that way after a '
      'restart — the central address does not come back by itself', () async {
    await containerWith(central).read(serverConfigProvider.notifier).setUrl('');
    final reopened = await containerWith(central).read(
      serverConfigProvider.future,
    );
    expect(reopened.isConfigured, isFalse);
  });

  test('a different address can still be saved (for testing)', () async {
    await containerWith(
      central,
    ).read(serverConfigProvider.notifier).setUrl('https://192.168.1.42:8443');
    final reopened = await containerWith(central).read(
      serverConfigProvider.future,
    );
    expect(reopened.baseUrl, 'https://192.168.1.42:8443');
  });

  test('saving the central address again follows the shipped value rather '
      'than freezing a copy of it', () async {
    final container = containerWith(central);
    await container
        .read(serverConfigProvider.notifier)
        .setUrl('https://192.168.1.42:8443');
    await container.read(serverConfigProvider.notifier).setUrl('$central/');
    expect(container.read(serverConfigProvider).value!.baseUrl, central);
    expect(await SharedPreferencesAsync().getString(storageKey), isNull);
  });

  testWidgets('the screen offers a way back to the central server, and only '
      'when there is one and it is not already in use', (tester) async {
    Future<void> pump(ProviderContainer container) async {
      await pumpInAppShell(
        tester,
        container: container,
        screen: const ServerConfigScreen(),
        tabIndex: 4, // More
      );
      await tester.pumpAndSettle();
    }

    final withCentral = containerWith(central);
    await withCentral.read(serverConfigProvider.notifier).setUrl('');
    await pump(withCentral);
    expect(find.text('Use the TriTrack server'), findsOneWidget);
    await tester.tap(find.text('Use the TriTrack server'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<TextFormField>(find.byType(TextFormField)).controller!.text,
      central,
    );

    final withoutCentral = containerWith('');
    await pump(withoutCentral);
    expect(find.text('Use the TriTrack server'), findsNothing);
  });

  test('the central address is written in one place in lib/', () {
    final declarations = [
      for (final f in dartFilesUnder('lib'))
        if (stripComments(
          f.readAsStringSync(),
        ).contains(RegExp(r'\bconst\s+String\s+centralServerBaseUrl\b')))
          f.path,
    ];
    expect(declarations, ['lib/core/net/central_server.dart']);
  });
}
