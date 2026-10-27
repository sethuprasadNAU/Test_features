import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tritrack/app.dart';
import 'package:tritrack/core/providers/app_context_provider.dart';
import 'package:tritrack/core/providers/database_provider.dart';
import 'package:tritrack/core/providers/retry_policy.dart';
import 'package:tritrack/data/db/app_database.dart';
import 'package:tritrack/features/splash/splash_screen.dart';

/// Boots the real [TriTrackApp] against a fresh in-memory database for a
/// full-app widget test, pre-resolving `currentUserProvider` inside
/// `tester.runAsync` before the widget tree is built.
///
/// Splash screen reads that provider on its very first frame (Phase 7's
/// non-skippable identity gate) and awaits it before navigating away, so the
/// whole pump also runs inside `tester.runAsync`: pumping/settling outside
/// `runAsync` never observes the real Future's completion (nothing
/// schedules a new frame until a `setState` fires, and a plain awaited
/// Future — even an already-resolved one — doesn't complete synchronously
/// under the fake-async pump clock). A short real-time delay before
/// `pumpAndSettle` gives that continuation a chance to actually run before
/// `pumpAndSettle` starts checking whether anything is pending; same
/// technique as the tap-triggered async writes in
/// `tag_database_screen_test.dart`.
///
/// Returns the [ProviderContainer] so the caller can read providers directly
/// afterward; caller must `addTearDown(container.dispose)`.
Future<ProviderContainer> pumpAppForTest(
  WidgetTester tester, {
  List<dynamic> overrides = const [],
  List<ProviderObserver> observers = const [],
}) async {
  // The same retry policy `main.dart` installs, so a full-app widget test
  // measures what ships rather than Riverpod's 38-second default (task 11.107).
  final container = ProviderContainer(retry: appRetryPolicy, observers: observers, overrides: [
    splashDurationProvider.overrideWithValue(Duration.zero),
    appDatabaseProvider.overrideWith((ref) => AppDatabase.openInMemory()),
    ...overrides,
  ]);

  await tester.runAsync(() async {
    await container.read(currentUserProvider.future);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const TriTrackApp(),
    ));
    await Future<void>.delayed(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
  });

  return container;
}
