import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'support/fake_path_provider.dart';

/// Task 11.73. Every screen that renders a live map (`MapScreen`,
/// `PositionEstimationScreen`, `RecordPositionPreviewScreen`,
/// `OfflineDataMapScreen`, `ProjectExtentPickerScreen`) routes tile loading
/// through `CachedTileProvider`, which reaches `path_provider`'s
/// `getApplicationSupportDirectory` the moment `flutter_map` asks it to draw
/// a tile — there's no way to build one of those screens in a widget test
/// without touching that channel. Before this task, each test file had to
/// remember to call `installFakePathProvider()` itself, and two didn't
/// (`position_estimation_screen_test.dart`, `record_position_preview_screen_test.dart`)
/// — the real bug 11.72 tripped over. A per-file opt-in fails open: the
/// default for a screen test that doesn't ask for this is a background
/// `MissingPluginException` that fails the test only if it happens to land
/// before the test's last pump, which is a coin flip, not a bug in that
/// specific screen.
///
/// Installing the fake here, once, for every widget test in this directory,
/// closes the channel at its source instead of patching call sites as they
/// get found: there is no longer a real path_provider channel for any widget
/// test to reach, so the exception this task chased can't happen again on a
/// screen nobody's added the import to yet. Test files that need a *fresh*
/// temp directory per call for their own isolation (`tile_cache_test.dart`,
/// `pre_migration_backup_test.dart`, and others) still call
/// `installFakePathProvider()` themselves — that's unaffected: it just
/// installs a newer fake over this one.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  setUp(installFakePathProvider);
  await testMain();
}
