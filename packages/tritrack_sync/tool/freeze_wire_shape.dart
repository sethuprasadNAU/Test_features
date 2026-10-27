import 'dart:io';

import 'package:tritrack_sync/tritrack_sync.dart';

/// Freezes the wire's current shape under the current `schemaMajorVersion`
/// and rewrites `lib/src/wire_shape_freezes.dart` with every freeze so far.
///
/// Run from `packages/tritrack_sync` **once per major bump**, after
/// `schemaMajorVersion` and `schemaMajorFirstMinor` have been updated, and
/// commit the result. Running it at any other time is harmless when the shape
/// is compatible and wrong when it is not: it would overwrite the record of
/// what devices on this major store with whatever the tree says today, which
/// is exactly the drift `assertWireShapeCompatibleWithMajor` exists to refuse.
/// So it refuses to run unless the current major has no freeze yet, or
/// `--refreeze` is passed.
void main(List<String> args) {
  final target = File('lib/src/wire_shape_freezes.dart');
  if (!target.parent.existsSync()) {
    stderr.writeln('Run from packages/tritrack_sync (lib/src/ not found).');
    exit(2);
  }
  final existing = frozenWireShapes[schemaMajorVersion];
  if (existing != null && !args.contains('--refreeze')) {
    stderr.writeln(
      'Major $schemaMajorVersion is already frozen (at schema '
      'v${existing.schemaVersion}). Re-freezing would replace the record of '
      'what devices on this major store with today\'s declaration, which '
      'defeats the check. If that is really intended, pass --refreeze.',
    );
    exit(1);
  }
  final all = {...frozenWireShapes, schemaMajorVersion: freezeWireShape()};
  target.writeAsStringSync(renderFrozenWireShapes(all));
  // Formatted like every other Dart file in the tree, so a diff of the freeze
  // at the next bump shows the columns that changed and nothing else.
  final format = Process.runSync('dart', ['format', target.path]);
  if (format.exitCode != 0) {
    stderr.writeln(format.stderr);
    exit(format.exitCode);
  }
  final tables = all[schemaMajorVersion]!.tables;
  final columns = tables.fold<int>(0, (n, t) => n + t.columns.length);
  stdout.writeln(
    'Froze major $schemaMajorVersion at schema v$latestSchemaVersion: '
    '${tables.length} tables, $columns columns → ${target.path}',
  );
}
