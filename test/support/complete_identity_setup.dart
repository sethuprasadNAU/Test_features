import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Fills out and submits Phase 7's non-skippable first-run identity screen,
/// which every fresh install (or placeholder-email device) now lands on
/// before reaching the tab shell. Call this right after pumping the app (and
/// `pumpAndSettle`) in any full-app widget test that needs to reach the Main
/// Map/tab shell — a fresh install always starts with the auto-created
/// placeholder identity, so the splash screen always redirects here first.
///
/// Submitting calls `UserRepository.update` (real DB I/O), so — same as any
/// other tap-triggered async DB write in this app's widget tests — the tap
/// and the settle that waits for it must run inside the same
/// `tester.runAsync` block.
Future<void> completeIdentitySetup(WidgetTester tester) async {
  expect(find.text('Set up your identity'), findsOneWidget);

  await tester.enterText(find.widgetWithText(TextFormField, 'First name'), 'Test');
  await tester.enterText(find.widgetWithText(TextFormField, 'Last name'), 'User');
  await tester.enterText(find.widgetWithText(TextFormField, 'Email'), 'test.user@example.com');
  await tester.pump();

  await tester.runAsync(() async {
    await tester.tap(find.text('CONTINUE'));
    // Real delay before pumping: nothing schedules a new frame until the
    // save's real DB write + provider invalidation actually completes, so
    // pumping immediately would see nothing pending and "settle" too early.
    await Future<void>.delayed(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
  });
}
