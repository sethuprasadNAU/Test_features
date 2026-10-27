import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart' show FontLoader;

/// Loads the real Roboto Regular the Flutter SDK ships in its own cache and
/// registers it under the 'Roboto' family — the family this app's theme
/// resolves to by default (`AppTheme` sets no `fontFamily`, so Material's
/// default typography supplies 'Roboto' on the platforms this test suite
/// runs as).
///
/// **Why this exists at all (task 11.232, task 11.233).** Without a real
/// font loaded, `flutter_test` renders every `Text` in its own built-in
/// fallback — measured at roughly **1.6x Roboto's width** — because nothing
/// under test ever registered a font asset named 'Roboto' for the engine to
/// find. A clip measured in that font is not evidence about a phone: task
/// 11.229 called two clips "live on every device today" from test-font
/// numbers, and on a real phone one of them didn't clip until AX3. Loading
/// this before a sweep is what makes its numbers about Roboto rather than
/// about the test harness.
///
/// The `.ttf` lives in the Flutter SDK's own artifact cache, not in this
/// repository — `<FLUTTER_ROOT>/bin/cache/artifacts/material_fonts/`, the
/// same file the SDK bundles into every release build. `FLUTTER_ROOT` is
/// read first if the environment sets it; otherwise it is derived from
/// `Platform.resolvedExecutable`, which `flutter test` runs as
/// `<FLUTTER_ROOT>/bin/cache/dart-sdk/bin/dart` — reliable because that dart
/// binary is *inside* the SDK cache whose sibling holds the font.
Future<void> loadRobotoFromSdkCache() async {
  final root = _flutterRoot();
  final fontFile = File(
    '$root${Platform.pathSeparator}bin${Platform.pathSeparator}cache'
    '${Platform.pathSeparator}artifacts${Platform.pathSeparator}material_fonts'
    '${Platform.pathSeparator}Roboto-Regular.ttf',
  );
  if (!fontFile.existsSync()) {
    throw StateError(
      'loadRobotoFromSdkCache: no Roboto-Regular.ttf at ${fontFile.path}. '
      'Derived FLUTTER_ROOT as $root — is this actually the Flutter SDK '
      "this test is running under, and does its cache hold the SDK's own "
      'material fonts (run `flutter precache` if not)?',
    );
  }
  final bytes = await fontFile.readAsBytes();
  final loader = FontLoader('Roboto')
    ..addFont(
      Future.value(
        ByteData.view(bytes.buffer, bytes.offsetInBytes, bytes.lengthInBytes),
      ),
    );
  await loader.load();
}

String _flutterRoot() {
  final envRoot = Platform.environment['FLUTTER_ROOT'];
  if (envRoot != null && envRoot.isNotEmpty) return envRoot;
  final exe = Platform.resolvedExecutable;
  final marker =
      '${Platform.pathSeparator}bin${Platform.pathSeparator}cache'
      '${Platform.pathSeparator}dart-sdk';
  final idx = exe.indexOf(marker);
  if (idx == -1) {
    throw StateError(
      'loadRobotoFromSdkCache: could not derive FLUTTER_ROOT from the '
      'running dart executable ($exe) — set the FLUTTER_ROOT environment '
      'variable explicitly.',
    );
  }
  return exe.substring(0, idx);
}
