import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../support/dart_source.dart';

/// Task 11.103 — **the guard for the coordinate nobody supplied.**
///
/// The defect: with no position estimate, the Main Map centred on
/// `LatLng(0, 0)` at street zoom. That is a real place — open water in the
/// Gulf of Guinea — so nothing threw, nothing logged and nothing warned.
/// "I do not know where you are" was drawn as "you are here". Two other map
/// screens ended their chains the same way, and one of them (the offline data
/// map) had written the fallback as `if (centre is 0,0 and there is no GPS)
/// set the centre to 0,0` — a no-op standing exactly where the fallback
/// should have been.
///
/// **This is not "special-case 0,0", and neither was the fix.** The fix is
/// `MapCameraTarget`, whose `center` is null exactly when nothing was
/// supplied, so a caller has to write down what it does about that. This test
/// exists because the *shape* is easy to reintroduce: the next map screen
/// somebody writes will need a value for `initialCenter` before it has one,
/// and `const LatLng(0, 0)` is what a person types.
///
/// **What it does.** Every `.dart` file under `lib/` has its comments blanked
/// out — [stripComments], so the paragraphs above and their equivalents in
/// `lib/` do not trip it — and the remaining source is scanned for a
/// zero-valued `LatLng` literal. Any hit not on [_knownZeroLiterals] fails.
///
/// **What it would and would not have caught.**
/// - It would have caught all four of this task's sites: `map_screen.dart`,
///   `offline_data_map_screen.dart`, `project_extent_picker_screen.dart` and
///   `position_estimation_screen.dart`.
/// - It would **not** catch a map that invents some *other* coordinate — a
///   hard-coded office, a country centroid. That needs a reader. What it
///   closes is the one literal that has actually shipped, three times, in
///   three files.
/// - It says nothing about `server/` or `website/`, which have no maps.
const List<_Allowed> _knownZeroLiterals = [];

class _Allowed {
  const _Allowed({required this.file, required this.reason});

  final String file;
  final String reason;
}

/// `LatLng(0, 0)`, `LatLng(0.0, 0.0)`, `LatLng(0,0)` — and the named-argument
/// spelling `LatLng(latitude: 0, longitude: 0)` that `latlong2` also accepts.
final _zeroLatLng = RegExp(
  r'LatLng\(\s*(?:latitude:\s*)?-?0(?:\.0+)?\s*,\s*(?:longitude:\s*)?-?0(?:\.0+)?\s*\)',
);

void main() {
  test('no map in lib/ falls back to a coordinate nobody supplied', () {
    for (final allowed in _knownZeroLiterals) {
      expect(
        File(allowed.file).existsSync(),
        isTrue,
        reason:
            '${allowed.file} no longer exists. Remove its entry from '
            '_knownZeroLiterals in this test, or restore the file.',
      );
    }

    final offenders = <String>[];
    for (final source in dartFilesUnder('lib')) {
      final stripped = stripComments(source.readAsStringSync());
      if (!_zeroLatLng.hasMatch(stripped)) continue;
      final relative = _relative(source.path);
      if (_knownZeroLiterals.any((a) => a.file == relative)) continue;
      offenders.add(relative);
    }

    expect(
      offenders,
      isEmpty,
      reason:
          'These files construct a zero-valued LatLng outside a comment:\n'
          '${offenders.map((f) => '  - $f').join('\n')}\n\n'
          'Latitude 0, longitude 0 is a valid coordinate in the Gulf of '
          'Guinea, which is why this shipped silently three times (task '
          '11.103): a map handed it centres on open water and reports it as '
          'confidently as it would report a real fix. If this is a map '
          'opening with nothing to go on, use `chooseMapCameraTarget` in '
          '`lib/features/map/map_camera_target.dart` and substitute '
          '`MapCameraTarget.worldViewCenter` at '
          '`MapCameraTarget.worldViewZoom` for its null centre — a framing '
          'of the whole planet, which claims nothing. If the zero really is '
          'the intended value for some other reason, add the file to '
          '_knownZeroLiterals in this test with a one-line reason.',
    );
  });

  test('the guard can actually fail', () {
    // A check that cannot tell success from its own silence is not a check.
    expect(_zeroLatLng.hasMatch('const ll.LatLng(0, 0)'), isTrue);
    expect(_zeroLatLng.hasMatch('LatLng(0.0,0.0)'), isTrue);
    expect(_zeroLatLng.hasMatch('LatLng(latitude: 0, longitude: 0)'), isTrue);
    expect(_zeroLatLng.hasMatch('LatLng(20, 0)'), isFalse);
    expect(_zeroLatLng.hasMatch('LatLng(0, 10)'), isFalse);
  });
}

String _relative(String path) =>
    path.startsWith('./') ? path.substring(2) : path;
