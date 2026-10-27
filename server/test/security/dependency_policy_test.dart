import 'dart:io';

import 'package:test/test.dart';

/// §3.8's dependency policy, as an enforceable check.
///
/// **The control:** exact pins in `pubspec.yaml`, with `pubspec.lock`
/// committed. A caret range means a fresh `dart pub get` can pull a version
/// nobody reviewed into a process that holds the Postgres credentials and every
/// magic-link token — the most complete compromise available against this
/// project and the one requiring the least skill against us specifically.
///
/// The lockfile alone is not the control: it can be regenerated, and
/// `dart pub upgrade` will move a caret range without anyone deciding to. This
/// test is what makes loosening a pin a deliberate, visible act.
void main() {
  /// Located relative to the package root rather than the CWD, so this passes
  /// whether the runner is invoked from `server/` or the repository root.
  File packageFile(String relative) {
    final here = Directory.current.path;
    final root = here.endsWith('server') ? here : '$here/server';
    return File('$root/$relative');
  }

  test('every hosted dependency is pinned to an exact version', () {
    final lines = packageFile('pubspec.yaml').readAsLinesSync();
    final offenders = <String>[];
    var inDeps = false;

    for (final line in lines) {
      if (line.startsWith('dependencies:') ||
          line.startsWith('dev_dependencies:')) {
        inDeps = true;
        continue;
      }
      // A new top-level key ends the dependency blocks.
      if (inDeps && line.isNotEmpty && !line.startsWith(' ') &&
          !line.startsWith('#')) {
        inDeps = false;
      }
      if (!inDeps) continue;

      final match = RegExp(r'^  ([a-z_0-9]+):\s*(\S.*)$').firstMatch(line);
      if (match == null) continue; // a path dep's nested key, or a comment
      final name = match.group(1)!;
      final constraint = match.group(2)!.trim();
      // `environment:`/`sdk:` constraints are not package pins; the SDK is not
      // a dependency fetched from pub.
      if (name == 'sdk') continue;
      if (constraint.startsWith('^') ||
          constraint.startsWith('>') ||
          constraint.startsWith('<') ||
          constraint == 'any') {
        offenders.add('$name: $constraint');
      }
    }

    expect(
      offenders,
      isEmpty,
      reason:
          'Security Model §3.8 requires exact pins for the server. Found '
          'range constraints: ${offenders.join(', ')}. Pin to the version '
          'pubspec.lock resolved, and note the upgrade in the task summary.',
    );
  });

  test(
    'the shared package\'s runtime dependencies are pinned exactly too — they '
    'are compiled into this process (task 11.331)',
    () {
      // `tritrack_sync` is a path dependency, so its own `dependencies:` are
      // resolved into the server's lockfile and run in the server process —
      // the same trust as a dependency named above. Its `dev_dependencies:`
      // never reach the server and keep their ranges.
      final here = Directory.current.path;
      final repo = here.endsWith('server')
          ? Directory(here).parent.path
          : here;
      final lines = File(
        '$repo/packages/tritrack_sync/pubspec.yaml',
      ).readAsLinesSync();
      final offenders = <String>[];
      var inDeps = false;
      for (final line in lines) {
        if (line.startsWith('dependencies:')) {
          inDeps = true;
          continue;
        }
        if (inDeps && line.isNotEmpty && !line.startsWith(' ') &&
            !line.startsWith('#')) {
          inDeps = false;
        }
        if (!inDeps) continue;
        final match = RegExp(r'^  ([a-z_0-9]+):\s*(\S.*)$').firstMatch(line);
        if (match == null) continue;
        final constraint = match.group(2)!.trim();
        if (constraint.startsWith('^') ||
            constraint.startsWith('>') ||
            constraint.startsWith('<') ||
            constraint == 'any') {
          offenders.add('${match.group(1)}: $constraint');
        }
      }
      expect(
        offenders,
        isEmpty,
        reason: 'Security Model §3.8: tritrack_sync runs inside the server, '
            'so its runtime dependencies are pinned exactly. Found: '
            '${offenders.join(', ')}.',
      );
    },
  );

  test('the lockfile is present so Docker builds what was reviewed', () {
    expect(
      packageFile('pubspec.lock').existsSync(),
      isTrue,
      reason: '§3.8 requires pubspec.lock committed for the server',
    );
  });

  test('the pubspec documents how to audit for advisories', () {
    // §3.8 requires "a documented `dart pub outdated`/advisory audit command
    // run at each review gate". Documented next to the pins themselves, since
    // that is where someone stands when they are about to change one.
    final pubspec = packageFile('pubspec.yaml').readAsStringSync();
    expect(pubspec, contains('dart pub outdated'));
  });

  test('the SDK constraint is still a range, deliberately', () {
    // Pinning the SDK to one patch release would make the repo unbuildable on
    // any other Dart install for no supply-chain benefit — the SDK is not
    // fetched from pub.dev and is not part of the dependency attack surface
    // §3.8 is about.
    final pubspec = packageFile('pubspec.yaml').readAsStringSync();
    expect(pubspec, contains('sdk: ^'));
  });
}
