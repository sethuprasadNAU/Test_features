import 'dart:io';

import 'package:test/test.dart';

/// Task 11.65. `TRITRACK_TRUSTED_PROXIES` and `TRITRACK_PROXY_SOURCE_IDENTITY`
/// are an operator's own measured claim about their own network — the one
/// place in this repository where a human asserts a measurement rather than
/// this project asserting a fact about its own code. `CLAUDE_DOCS/
/// SECURITY_SCOPE_AND_EXIT.md`'s "What `TRITRACK_TRUSTED_PROXIES` /
/// `TRITRACK_PROXY_SOURCE_IDENTITY` mean" is the one file that owns the full
/// explanation; every other operator-facing site that mentions either
/// variable keeps a one-line warning next to it, because a person editing
/// `.env` who is sent elsewhere to learn what the value means is a person who
/// will set it without reading (task 11.40's finding, left deliberately
/// unfixed for exactly this file to fix in place).
///
/// **The site list below is derived, not hand-kept — the task this guard
/// exists for is a list of seven files becoming stale one level up.** It
/// walks the repository for files that play an operator-facing role (a
/// `README.md`, `.env.example`, `Caddyfile`, a `docker-compose*.yml`, or one
/// of the two named `CLAUDE_DOCS` files) and, among those, checks only the
/// ones that actually mention either variable. A new `README.md` or
/// `docker-compose*.yml` added later that happens to touch this feature is
/// swept in automatically; one that never mentions it is never required to
/// say anything.
const _varNames = [
  'TRITRACK_TRUSTED_PROXIES',
  'TRITRACK_PROXY_SOURCE_IDENTITY',
];

/// Directories that hold nothing this guard should read: dependency caches,
/// build output and version control internals, none of which is a site a
/// human reads while deciding how to answer these two variables.
const _skipDirs = {
  '.git',
  '.dart_tool',
  'build',
  'node_modules',
  'Pods',
  '.gradle',
  '.idea',
  'DerivedData',
  '.pub-cache',
};

bool _isOperatorSurface(File file) {
  final name = file.uri.pathSegments.last;
  if (name == 'README.md') return true;
  if (name == '.env.example') return true;
  if (name == 'Caddyfile') return true;
  if (name.startsWith('docker-compose') && name.endsWith('.yml')) return true;
  final path = file.path.replaceAll('\\', '/');
  return path.endsWith('CLAUDE_DOCS/SECURITY_SCOPE_AND_EXIT.md') ||
      path.endsWith('CLAUDE_DOCS/SERVER_DEPLOYMENT_PRIMER.md');
}

List<File> _walk(Directory dir) {
  final found = <File>[];
  for (final entity in dir.listSync(followLinks: false)) {
    final base = entity.uri.pathSegments.where((s) => s.isNotEmpty).last;
    if (entity is Directory) {
      if (_skipDirs.contains(base)) continue;
      found.addAll(_walk(entity));
    } else if (entity is File) {
      found.add(entity);
    }
  }
  return found;
}

/// A line that actually assigns one of the two variables a value — `NAME=x`
/// or the YAML `NAME: x` shorthand — as opposed to a prose sentence that
/// merely names the variable in passing (explaining a mechanism, pointing a
/// reader at the section that sets it, and so on). This is the decision
/// point: a prose mention does not ask an operator to type anything, and
/// requiring the same warning beside every prose reference to the name would
/// be exactly the verbosity this project's own standing rule on simplicity
/// warns against — the warning belongs where the hand is, which is at the
/// assignment, not at every sentence that says the variable's name out loud.
bool _isAssignmentLine(String line, String varName) =>
    RegExp('$varName\\s*[:=]\\s*\\S').hasMatch(line);

/// Whether the text around [lineIndex] in [lines] — a window wide enough to
/// span the explanatory paragraph or blockquote around one assignment, even
/// where a file's structure (YAML comments, a long `##` section) pushes the
/// nearest warning a couple of dozen lines away — reads as a warning that the
/// value is a claim about the operator's own network, not merely a mention of
/// the variable's name.
bool _hasNearbyWarning(List<String> lines, int lineIndex) {
  final start = (lineIndex - 30).clamp(0, lines.length);
  final end = (lineIndex + 30).clamp(0, lines.length);
  final window = lines.sublist(start, end).join('\n');
  return RegExp('claim', caseSensitive: false).hasMatch(window) &&
      RegExp('network', caseSensitive: false).hasMatch(window);
}

void main() {
  final repoRoot = Directory('..');
  final surfaceFiles = _walk(repoRoot).where(_isOperatorSurface).toList();

  test(
    'the walk reached the operator-facing surface, not an empty directory',
    () {
      expect(
        surfaceFiles.length,
        greaterThanOrEqualTo(5),
        reason:
            'expected at least README.md, server/README.md, .env.example and '
            'the two docker-compose files this walk is known to find; fewer '
            'means it is not starting from the repository root and every '
            'assertion below would pass on an empty set',
      );
    },
  );

  final mentioningFiles = <File>[
    for (final file in surfaceFiles)
      if (file.readAsLinesSync().any(
        (line) => _varNames.any((name) => _isAssignmentLine(line, name)),
      ))
        file,
  ];

  test('the derivation actually found sites that mention either variable', () {
    // **Print what was actually scanned, every run — task 11.212.** The plan
    // and `SETUP_OWNERSHIP.md` both carried a hand-written "seven places" that
    // was already wrong when this guard was written: it named neither
    // `docker-compose.yml` nor `proxy/Caddyfile`, and "seven" matched neither
    // the file count nor the mention count. **A total in prose has nobody
    // maintaining it; a total this run emits is re-derived every time.** Both
    // documents now point here instead of naming a number.
    print(
      'source-identity warning surface: '
      '${mentioningFiles.length} operator-facing files assign either '
      'variable — '
      '${mentioningFiles.map((f) => f.path.replaceFirst('../', '')).toList()..sort()}',
    );
    expect(
      mentioningFiles.length,
      greaterThanOrEqualTo(5),
      reason:
          'these two variables are known to be documented in README.md, '
          'server/README.md, .env.example, docker-compose.tls.yml and '
          'CLAUDE_DOCS/SECURITY_SCOPE_AND_EXIT.md; finding fewer means this '
          'derivation is missing files it should be reading, and every '
          'per-file assertion below would then be checking too little',
    );
  });

  group('every operator-facing site that mentions either variable warns '
      'that setting it is a claim about the operator\'s own network', () {
    for (final file in mentioningFiles) {
      final relativePath = file.path.replaceFirst('../', '');
      test(relativePath, () {
        final lines = file.readAsLinesSync();
        final mentionLines = [
          for (var i = 0; i < lines.length; i++)
            if (_varNames.any((name) => _isAssignmentLine(lines[i], name))) i,
        ];
        expect(mentionLines, isNotEmpty);

        final unwarned = mentionLines
            .where((i) => !_hasNearbyWarning(lines, i))
            .toList();

        expect(
          unwarned,
          isEmpty,
          reason:
              '$relativePath mentions TRITRACK_TRUSTED_PROXIES or '
              'TRITRACK_PROXY_SOURCE_IDENTITY at line(s) '
              '${unwarned.map((i) => i + 1).join(', ')} with no nearby '
              'sentence warning that setting either is a claim about the '
              "operator's own network — see CLAUDE_DOCS/"
              'SECURITY_SCOPE_AND_EXIT.md, "What TRITRACK_TRUSTED_PROXIES / '
              'TRITRACK_PROXY_SOURCE_IDENTITY mean"',
        );
      });
    }
  });

  test('the owning explanation exists in SECURITY_SCOPE_AND_EXIT.md', () {
    final owner = File('../CLAUDE_DOCS/SECURITY_SCOPE_AND_EXIT.md');
    expect(owner.existsSync(), isTrue);
    final content = owner.readAsStringSync();
    expect(
      content.contains(
        'What `TRITRACK_TRUSTED_PROXIES` / `TRITRACK_PROXY_SOURCE_IDENTITY` mean',
      ),
      isTrue,
      reason:
          'every other site points a reader here by this exact heading text; '
          'if the heading moves or is reworded, every pointer becomes a '
          'dangling reference and nothing else in this suite would notice',
    );
  });
}
