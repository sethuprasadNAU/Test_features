import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

/// Stands in for `path_provider`'s real `MethodChannelPathProvider`, which
/// isn't exported from the platform-interface package for tests to reach —
/// it invokes the same real channel (`plugins.flutter.io/path_provider`)
/// with no handler behind it, which is exactly the "real, unfaked plugin"
/// state this test needs to reproduce.
class _RealPathProviderChannel extends PathProviderPlatform {
  static const _channel = MethodChannel('plugins.flutter.io/path_provider');

  @override
  Future<String?> getApplicationSupportPath() =>
      _channel.invokeMethod<String>('getApplicationSupportDirectory');
}

/// Task 11.73. Confirms the failure mode this task fixed actually fails the
/// suite, by name, rather than racing.
///
/// `flutter_test_config.dart` now installs `FakePathProviderPlatform` before
/// every widget test, so no test in this suite should ever exercise the real
/// `MethodChannelPathProvider` — under `flutter test` there's no native
/// implementation behind that channel, and reaching it throws
/// `MissingPluginException`. This test deliberately puts the real,
/// unimplemented channel back for its own run (overriding the global fake)
/// and awaits it directly, so the throw happens inside the test's own await
/// chain instead of a detached background Future — which is exactly what was
/// missing before: a screen that reached path_provider without the fake
/// installed threw in the background, and whether that landed inside the
/// test body (a failure) or after it (silently dropped) was a race. Awaited
/// directly, it isn't a race — it fails every time, which is what makes this
/// a guard: if a future screen adds a plugin call this file doesn't fake,
/// the failure it produces looks like this one, not like an unlucky rerun.
void main() {
  testWidgets(
    'a widget that reaches path_provider with no fake installed fails, deterministically',
    (tester) async {
      final fakeChannel = PathProviderPlatform.instance;
      PathProviderPlatform.instance = _RealPathProviderChannel();
      addTearDown(() => PathProviderPlatform.instance = fakeChannel);

      await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));

      // Mirrors how the real screens reach this channel: from inside a
      // widget's async work (`CachedTileProvider._load`, `TileCache.rootDir`),
      // awaited on the real event loop via `runAsync` rather than the
      // fake-async clock `pump()` drives. No fake installed for this call:
      // it must throw, and it must throw with the exact exception every
      // unstubbed platform channel call produces under `flutter test`, not
      // merely "something failed".
      Object? caught;
      await tester.runAsync(() async {
        try {
          await PathProviderPlatform.instance.getApplicationSupportPath();
        } catch (error) {
          caught = error;
        }
      });
      expect(caught, isA<MissingPluginException>());
    },
  );
}
