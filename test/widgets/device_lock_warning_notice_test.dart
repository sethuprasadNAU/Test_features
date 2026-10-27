import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_auth/local_auth.dart';
import 'package:mocktail/mocktail.dart';
import 'package:tritrack/core/providers/device_lock_provider.dart';
import 'package:tritrack/widgets/device_lock_warning_notice.dart';

import '../support/fake_shared_preferences.dart';

class _MockLocalAuthentication extends Mock implements LocalAuthentication {}

/// Security Model §4.8 control 2, task 10.79.
///
/// Asserts the three properties that matter about this notice: it renders
/// nothing on a device that already has a lock, it renders and can be
/// dismissed on a device that does not, and a platform check that fails
/// outright is treated as "say nothing" rather than "assume the worst" — see
/// [DeviceLockWarningNotice.build]'s reasoning for why a failed check is not
/// evidence of an unlocked device.
void main() {
  setUp(installFakeSharedPreferences);
  tearDown(() {
    DeviceLockWarningNotice.authFactory = LocalAuthentication.new;
  });

  Future<void> pump(WidgetTester tester) => tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        home: Scaffold(body: DeviceLockWarningTile()),
      ),
    ),
  );

  testWidgets('renders nothing when the device has a lock configured', (
    tester,
  ) async {
    final auth = _MockLocalAuthentication();
    when(auth.isDeviceSupported).thenAnswer((_) async => true);
    DeviceLockWarningNotice.authFactory = () => auth;

    await pump(tester);
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('device-lock-warning-notice')), findsNothing);
  });

  testWidgets('warns, and dismissing hides it for good', (tester) async {
    final auth = _MockLocalAuthentication();
    when(auth.isDeviceSupported).thenAnswer((_) async => false);
    DeviceLockWarningNotice.authFactory = () => auth;

    await pump(tester);
    await tester.pumpAndSettle();

    final tile = find.byKey(const ValueKey('device-lock-warning-notice'));
    expect(tile, findsOneWidget);

    await tester.tap(tile);
    await tester.pumpAndSettle();
    expect(find.text('Got it'), findsOneWidget);

    await tester.tap(find.text('Got it'));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('device-lock-warning-notice')), findsNothing);
  });

  testWidgets('a failed platform check says nothing rather than warning', (
    tester,
  ) async {
    final auth = _MockLocalAuthentication();
    when(
      auth.isDeviceSupported,
    ).thenThrow(StateError('platform channel unavailable'));
    DeviceLockWarningNotice.authFactory = () => auth;

    await pump(tester);
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('device-lock-warning-notice')), findsNothing);
  });
}
