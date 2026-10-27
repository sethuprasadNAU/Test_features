import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

/// A [PathProviderPlatform] backed by a fresh system temp directory — there's
/// no real platform channel under `flutter test`, so anything that calls
/// `path_provider` (the tile cache, DEM repository) needs this installed
/// first. Returns a NEW temp dir each call, matching [installFakePathProvider]
/// being invoked once per test in `setUp`.
class FakePathProviderPlatform extends PathProviderPlatform {
  FakePathProviderPlatform() : _dir = Directory.systemTemp.createTempSync('tri_track_test_');

  final Directory _dir;

  /// The backing temp directory's path — exposed for
  /// `fake_path_provider_test.dart` to assert existence/deletion against,
  /// not needed by any real caller (they go through the three getters
  /// below).
  String get path => _dir.path;

  @override
  Future<String?> getApplicationSupportPath() async => _dir.path;

  @override
  Future<String?> getTemporaryPath() async => _dir.path;

  @override
  Future<String?> getApplicationDocumentsPath() async => _dir.path;

  /// Removes the backing temp directory. Task 11.296: every call to
  /// [installFakePathProvider] created one of these and nothing ever
  /// deleted it — 199,261 counted, all empty, in Michael's system temp
  /// folder after a few weeks of running this suite, enough that `ls`
  /// there stopped returning within two minutes.
  void dispose() {
    if (_dir.existsSync()) _dir.deleteSync(recursive: true);
  }
}

/// Installs [FakePathProviderPlatform] and deletes its temp directory when
/// the current test ends. Call once per test, e.g. in `setUp` — `addTearDown`
/// runs inside the test's own zone, which is what `setUp` provides.
void installFakePathProvider() {
  final platform = FakePathProviderPlatform();
  PathProviderPlatform.instance = platform;
  addTearDown(platform.dispose);
}
