import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tritrack/data/sync/backup_archive.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

import 'backup_builders.dart';

/// **Task 11.105 — the same shape as this task's subject, found at a different
/// boundary.**
///
/// Task 11.105 asked whether "a typed `catch` is a guess about a wrapper"
/// occurs anywhere but Riverpod. It does, once, here — and unlike the Riverpod
/// instances, this one is not about a wrapper at all but about *when* the work
/// happens.
///
/// `ZipDecoder.decodeBytes` defaults to `verify: false` and does not
/// decompress: `package:archive` inflates an entry lazily, on the first read
/// of `ArchiveFile.content`. Those two reads used to sit outside every `try` in
/// `BackupArchive.decode` — they were the *arguments* to the function that had
/// the `try` — so a zip whose central directory survived but whose payload did
/// not raised a raw `FormatException: Filter error, bad data`, sailed past the
/// `on BackupFormatException` branch in `data_export_screen.dart`, and reached
/// a person as "Could not read backup" plus a Dart exception string.
///
/// **A `.zip` arriving short is the failure this transport makes likely.**
/// `BackupArchive`'s own doc names WhatsApp as the intended way these move
/// between phones, and its promise — *"any malformed/truncated/foreign archive
/// throws `BackupFormatException` before any database is touched"* — was false
/// for exactly that case.
void main() {
  /// A real archive with enough rows that `data.json` is worth deflating, so
  /// corrupting its middle corrupts a compressed stream rather than a header.
  Uint8List realArchive() => BackupArchive.encode(
    makeBackup({
      'Tags': [
        for (var i = 0; i < 40; i++)
          {'tag_id': 'tag-$i', 'tag_name': 'Collar $i', 'frequency_mhz': 150.0},
      ],
    }),
  );

  Uint8List corruptedAt(Uint8List bytes, double fraction) {
    final out = Uint8List.fromList(bytes);
    final at = (bytes.length * fraction).toInt();
    for (var i = at; i < at + 16 && i < out.length; i++) {
      out[i] = out[i] ^ 0xFF;
    }
    return out;
  }

  test('a damaged compressed payload is refused as a backup problem, not as a '
      'raw Dart error', () {
    // 0.4 lands inside the deflate stream early enough that inflation fails
    // outright rather than producing rubbish that happens to be invalid JSON.
    // Measured against this fixture on 2026-08-31; the two assertions below
    // are what matter, and both hold for any offset that breaks inflation.
    expect(
      () => BackupArchive.decode(corruptedAt(realArchive(), 0.4)),
      throwsA(isA<BackupFormatException>()),
      reason:
          'Before task 11.105 this was a bare FormatException, which the '
          'import screen has no branch for.',
    );
  });

  test('corruption anywhere in the file either reads or is refused as a '
      'backup problem — never anything else', () {
    // **The property, stated as it actually is.** Not "every corruption
    // fails": some bytes are padding or trailing metadata the decoder does not
    // consult, and demanding a failure there would be asserting something
    // untrue to make the test look thorough. What must hold is that no
    // corruption anywhere produces a *third* outcome — an exception the import
    // screen has no branch for. That is the defect, and it is the whole
    // defect.
    //
    // Not one hand-picked offset, either: a guard covering only the byte
    // somebody happened to corrupt while writing it is the "fixed where it
    // reproduced" shape Phase 10 found six times.
    final bytes = realArchive();
    var refusals = 0;
    for (var step = 0; step <= 16; step++) {
      final fraction = 0.20 + step * 0.05;
      try {
        BackupArchive.decode(corruptedAt(bytes, fraction));
      } on BackupFormatException {
        refusals++;
      } catch (e) {
        fail(
          'corruption at ${(fraction * 100).round()}% of the file escaped as '
          '${e.runtimeType}: $e — the import screen has no branch for this, '
          'so a person is shown a raw Dart error.',
        );
      }
    }

    // And the check that stops the loop above passing because nothing was ever
    // corrupted at all: several of those offsets must genuinely be refused.
    expect(
      refusals,
      greaterThan(4),
      reason:
          'Almost nothing was refused, so this fixture is no longer being '
          'damaged in a way the decoder notices, and the loop above proves '
          'nothing.',
    );
  });

  test('a truncated file is refused too', () {
    final bytes = realArchive();
    expect(
      () => BackupArchive.decode(
        Uint8List.sublistView(bytes, 0, bytes.length - 40),
      ),
      throwsA(isA<BackupFormatException>()),
    );
  });

  test('an intact archive still round-trips', () {
    // The other half of the bar: a guard that refuses everything is not a
    // guard. If this ever fails, the checks above are passing for the wrong
    // reason.
    final decoded = BackupArchive.decode(realArchive());

    expect(decoded.rowsFor('Tags'), hasLength(40));
    expect(decoded.manifest.projectId, 'project-1');
  });
}
