import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Task 11.297 — **the instrument that stops the container count going stale
/// a third time.**
///
/// The number of long-running containers is `docker-compose.yml` plus
/// `docker-compose.tls.yml`, minus anything behind a Compose profile. It has
/// been hand-carried into prose in at least five places and has been wrong in
/// all of them twice: task 11.79 made "four" into five and nobody carried it
/// back; task 11.290 made "five" into six on 2026-09-20, caught a day later
/// only because task 11.287 happened to be reading those documents for
/// another reason.
///
/// **This is task 11.52's class** — a fact copied by hand instead of pointed
/// at — but a count is not a step, so `setup_step_ownership_test.dart` never
/// looked for it. See `CLAUDE_DOCS/CONTAINER_COUNT.md` for the full design,
/// including the one distinction that makes this more than a grep: a
/// superseded document (`NAU_infosec_review_request.md`) is allowed to state
/// an old count on purpose, provided it also visibly says what is true today
/// — and that restatement is itself checked against the derivation, so a
/// declaration that stops being true fails exactly like a description that
/// drifts.
///
/// Nothing here is hand-listed beyond the two small tables in
/// `CLAUDE_DOCS/CONTAINER_COUNT.md`, which this test reads at run time. A
/// count-shaped phrase found anywhere else in the tracked tree is an
/// uncovered copy and fails on sight.
void main() {
  const docPath = 'CLAUDE_DOCS/CONTAINER_COUNT.md';

  /// Files excluded from the search entirely: append-only records of what was
  /// said at the time (the same two `SETUP_OWNERSHIP.md` excludes), this
  /// document and its own test (which must quote example numbers and the
  /// declaration phrase to describe them), and `.claude/commands/`, whose
  /// files narrate the task that wrote them and are deleted when that task
  /// closes (`command_file_staleness_test.dart`) — history, not something
  /// anyone reads today for a current fact.
  const excludedFiles = {
    'CLAUDE_DOCS/DEVELOPMENT_PLAN.md',
    'CLAUDE_DOCS/TASK_COMMS.md',
    docPath,
    'test/documentation/container_count_test.dart',
    // Not a Docker-container count at all — "those three containers" is the
    // sync response's Observations/Tags/Deployments row lists, in a security
    // probe about confusing one for another. A different sense of the same
    // English word, found by this test on its first run and confirmed by
    // reading the surrounding lines rather than assumed.
    'scripts/verify_round8_server_surface.py',
  };
  const excludedDirs = {'.claude/commands'};

  const wordForNumber = {
    3: 'three',
    4: 'four',
    5: 'five',
    6: 'six',
    7: 'seven',
    8: 'eight',
  };
  final numberForWord = {
    for (final e in wordForNumber.entries) e.value: e.key,
  };

  /// Matches "N container(s)", "N long-running containers", "N Docker
  /// containers" — with or without markdown emphasis around the number — and
  /// captures whether it is prefixed "the other", which is a subset claim
  /// ("the other five containers [besides the one just named]"), not a
  /// total. It is still checked below, against the derived total minus one
  /// — see CONTAINER_COUNT.md.
  final countPhrase = RegExp(
    r'\b(the\s+other\s+)?(three|four|five|six|seven|eight)\b'
    r'\**\s*(?:long[- ]running\s*)?(?:docker\s*)?containers?\b',
    caseSensitive: false,
  );

  /// The exact declaration a Record document must contain, today's true
  /// count spelled out. Deliberately a fixed literal, not a looser pattern —
  /// a declaration a human did not write in these words is not one this
  /// instrument can tell apart from an accidental match.
  String requiredRecordPhrase(int count) =>
      'the count is **${wordForNumber[count]}**';

  /// `docker compose config --services` on the merged base + TLS files,
  /// which resolves profiles, overrides and anchors the way a real `up`
  /// does — the only reading of "the count" worth enforcing. Required
  /// variables are extracted from the files themselves and given throwaway
  /// values, so a newly-added `${VAR:?...}` does not have to be hand-added
  /// here to keep this derivation running.
  int deriveLiveContainerCount() {
    const files = ['docker-compose.yml', 'docker-compose.tls.yml'];
    for (final f in files) {
      expect(
        File(f).existsSync(),
        isTrue,
        reason:
            '$f is missing. The container count has no derivation without '
            'both compose files.',
      );
    }
    final requiredVarPattern = RegExp(r'\$\{([A-Z_]+):\?[^}]*\}');
    final requiredVars = <String>{};
    for (final f in files) {
      requiredVarPattern
          .allMatches(File(f).readAsStringSync())
          .forEach((m) => requiredVars.add(m.group(1)!));
    }
    final env = {
      for (final v in requiredVars) v: '/dev/null',
      // Anything path-shaped works for a `?`-required var here — this
      // command only resolves service names, never starts a container.
    };

    final result = Process.runSync(
      'docker',
      [
        'compose',
        '-f', 'docker-compose.yml',
        '-f', 'docker-compose.tls.yml',
        'config',
        '--services',
      ],
      environment: env,
    );
    expect(
      result.exitCode,
      0,
      reason:
          '`docker compose config --services` failed, so this test has no '
          'derivation to check anything against and cannot silently pass. '
          'Docker is required to run this suite locally (the project already '
          'requires it for `docker compose up`).\n'
          'stdout: ${result.stdout}\nstderr: ${result.stderr}',
    );
    final services = (result.stdout as String)
        .split('\n')
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .toSet();
    expect(
      services.length,
      greaterThanOrEqualTo(3),
      reason:
          'Only ${services.length} services resolved (${services.join(', ')}). '
          'That is far fewer than this project ships, which means the '
          'derivation itself is broken rather than the count actually being '
          'that small — fix the parse, do not accept a small number as real.',
    );
    return services.length;
  }

  /// Reads the two tables in CONTAINER_COUNT.md: `| Document | Kind |` for
  /// Live documents, and `| Document | Kind | Required phrase ... |` for
  /// Record documents. Nothing here is a fallback hand-list — a document
  /// missing from both is an uncovered copy, which is exactly the failure
  /// this test exists to report.
  ({Set<String> live, Set<String> record}) readTables(List<String> lines) {
    final live = <String>{};
    final record = <String>{};
    final pathPattern = RegExp(r'`([A-Za-z0-9_./-]+\.[A-Za-z]+)`');

    var inLiveTable = false;
    var inRecordTable = false;
    for (final raw in lines) {
      final line = raw.trim();
      if (line == '| Document | Kind |') {
        inLiveTable = true;
        inRecordTable = false;
        continue;
      }
      if (line.startsWith('| Document | Kind | Required phrase')) {
        inRecordTable = true;
        inLiveTable = false;
        continue;
      }
      if (!line.startsWith('|')) {
        inLiveTable = false;
        inRecordTable = false;
        continue;
      }
      if (line.startsWith('| --- ')) continue;
      final path = pathPattern.firstMatch(line)?.group(1);
      if (path == null) continue;
      if (inLiveTable) live.add(path);
      if (inRecordTable) record.add(path);
    }
    return (live: live, record: record);
  }

  /// Every file the repository actually tracks, git-derived so this cannot
  /// wander into an untracked local file the way a directory walk once did
  /// for `setup_step_ownership_test.dart`.
  List<String> repositoryTextFiles() {
    final result = Process.runSync('git', [
      'ls-files',
      '-z',
      '--cached',
      '--others',
      '--exclude-standard',
    ]);
    expect(
      result.exitCode,
      0,
      reason: '`git ls-files` failed: ${result.stderr}',
    );
    return (result.stdout as String)
        .split('\u0000')
        .where((p) => p.isNotEmpty)
        .where((p) => !excludedFiles.contains(p))
        .where((p) => !excludedDirs.any((d) => p.startsWith('$d/')))
        .toList();
  }

  late int derivedCount;
  late Set<String> liveDocs;
  late Set<String> recordDocs;
  late List<String> files;

  setUpAll(() {
    derivedCount = deriveLiveContainerCount();
    expect(
      wordForNumber.containsKey(derivedCount),
      isTrue,
      reason:
          'Derived $derivedCount containers, which has no word form in this '
          'test. Add it to wordForNumber in container_count_test.dart — this '
          'is a real growth of the stack, not a bug in the derivation.',
    );

    final doc = File(docPath);
    expect(
      doc.existsSync(),
      isTrue,
      reason:
          '$docPath is missing. It is the only statement of which documents '
          'are allowed to hold this number and how, and without it this test '
          'enforces nothing.',
    );
    final tables = readTables(doc.readAsLinesSync());
    liveDocs = tables.live;
    recordDocs = tables.record;
    expect(
      liveDocs,
      isNotEmpty,
      reason:
          'Parsed zero Live documents from $docPath. A derivation that '
          'matches nothing enforces nothing — fix the parse, not the test.',
    );

    files = repositoryTextFiles();
    expect(
      files.length,
      greaterThan(200),
      reason:
          'Only ${files.length} files were found to search, far fewer than '
          'this repository holds. The walk is broken.',
    );
  });

  test('the derivation finds every Live and Record document from '
      'CONTAINER_COUNT.md', () {
    for (final path in {...liveDocs, ...recordDocs}) {
      expect(
        File(path).existsSync(),
        isTrue,
        reason:
            '$docPath lists $path, and that file does not exist. Either it '
            'moved and the table needs to follow it, or it was deleted and '
            'the row needs to go.',
      );
    }
  });

  test('every Live document states today\'s true container count, '
      'everywhere it states one', () {
    final failures = <String>[];
    for (final path in liveDocs) {
      final text = File(path).readAsStringSync();
      final matches = countPhrase.allMatches(text);
      var found = false;
      for (final m in matches) {
        found = true;
        final isOther = m.group(1) != null;
        final stated = numberForWord[m.group(2)!.toLowerCase()]!;
        // "The other N containers" is a subset claim — this deployment's
        // total minus the one row it is said of — not a total-container
        // claim, so it is checked against a different number.
        final expected = isOther ? derivedCount - 1 : derivedCount;
        if (stated != expected) {
          final around = text.substring(
            (m.start - 40).clamp(0, text.length),
            (m.end + 10).clamp(0, text.length),
          );
          failures.add(
            '$path says "$stated" but ${isOther ? 'the derivation minus one ($expected: the other containers besides the one this row is about)' : 'docker compose reports $expected services today'}: '
            '"...${around.replaceAll('\n', ' ')}..."',
          );
        }
      }
      if (!found) {
        failures.add(
          '$path is listed as Live in $docPath but states no container '
          'count that this test can find. Either the wording changed and the '
          'regex in container_count_test.dart needs to follow it, or this '
          'document no longer states the count and the row should move or be '
          'removed.',
        );
      }
    }
    expect(
      failures,
      isEmpty,
      reason:
          'These Live documents disagree with `docker compose config '
          '--services` (currently $derivedCount: services counted from the '
          'merged base + TLS files):\n'
          '${failures.map((f) => "  - $f").join("\n")}',
    );
  });

  test('every Record document still visibly says what is true today', () {
    final requiredPhrase = requiredRecordPhrase(derivedCount);
    final failures = <String>[];
    for (final path in recordDocs) {
      final text = File(path).readAsStringSync();
      if (!text.contains(requiredPhrase)) {
        failures.add(
          '$path does not contain "$requiredPhrase". A Record document is '
          'allowed to keep an old count as history, but only if it also says, '
          'in these exact words, what is true today — otherwise a reader has '
          'no way to tell the number they are looking at is history rather '
          'than fact, which is the failure this test exists to catch.',
        );
      }
    }
    expect(
      failures,
      isEmpty,
      reason:
          '${failures.join("\n")}\n\n'
          'Either the compose files changed and this declaration is now '
          'stale (update it to name today\'s count, currently $derivedCount), '
          'or the exact phrase drifted from what CONTAINER_COUNT.md '
          'documents.',
    );
  });

  test('nothing outside the two tables states a container count', () {
    final covered = {...liveDocs, ...recordDocs};
    final offenders = <String>[];
    for (final path in files) {
      if (covered.contains(path)) continue;
      String text;
      try {
        text = File(path).readAsStringSync();
      } on FileSystemException {
        continue; // binary, or unreadable — neither can spell a count
      } on FormatException {
        continue;
      }
      if (countPhrase.hasMatch(text)) {
        offenders.add(path);
      }
    }
    expect(
      offenders,
      isEmpty,
      reason:
          'These files state a container count and are neither Live nor '
          'Record in $docPath:\n'
          '${offenders.map((f) => "  - $f").join("\n")}\n\n'
          'This is the sixth place for the number to go stale that nobody '
          'decided to allow. Either add a row to $docPath (Live if it must '
          'always match today\'s count, Record if it is a deliberate history '
          'of what was said), or remove the count from the file.',
    );
  });
}
