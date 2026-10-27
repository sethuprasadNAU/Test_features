// Host-side driver for the screenshot harness. See README.md in this folder.
import 'dart:io';

import 'package:integration_test/integration_test_driver_extended.dart';

Future<void> main() async {
  final outDir = Platform.environment['TRITRACK_SHOT_DIR'];
  if (outDir == null || outDir.isEmpty) {
    stderr.writeln('TRITRACK_SHOT_DIR is not set; refusing to guess an output '
        'directory. Run this through regenerate.sh.');
    exit(2);
  }
  Directory(outDir).createSync(recursive: true);
  await integrationDriver(
    onScreenshot: (String name, List<int> bytes, [Map<String, Object?>? args]) async {
      final file = File('$outDir/$name.png');
      file.writeAsBytesSync(bytes);
      stdout.writeln('wrote ${file.path} (${bytes.length} bytes)');
      return true;
    },
  );
}
