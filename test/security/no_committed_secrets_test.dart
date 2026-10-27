import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

/// §4.6's committed-secret check, as a test that runs on every change.
///
/// **A hook or a CI step would be easy to skip; a test in the default suite is
/// not.** §4.6 asks for the check "in CI or a pre-commit hook"; this is the
/// cheapest form that is always on.
///
/// **Two scopes, one set of detectors (task 10.58, finding I-7).** The gate
/// criterion has always been "the whole history, not just the working tree" —
/// a secret committed and later removed is still published to every clone —
/// but every check below `setUpAll` used to run only over `git ls-files`,
/// which sees the tip and nothing else. The gate covered the gap by hand each
/// round instead (`git log --all -p`, §7.4), which is worse than it looks: an
/// automated check that reads as though it covers something it does not is
/// the failure mode `git ls-files` produced here, restated. The detectors
/// (the PEM check, the age-key pattern, `_secretAssignmentOffenders`) are
/// unchanged and shared; what is new is a second pass that runs them over
/// **every blob ever reachable from any ref**, not the files on disk today.
///
/// Scoped to **tracked** files on purpose: an untracked `.env` holding a real
/// password is the intended workflow, not a finding.
///
/// **Task 11.150, 2026-09-04 — this check was green for weeks without looking
/// at anything.** `offline-suite.yml` checked out with a bare
/// `actions/checkout@v4`, whose default is `fetch-depth: 1`, so in CI "every
/// blob ever reachable from any ref" was **one commit**: 1,047 blobs against
/// the 4,744 a full clone holds. The guard written for exactly that failure
/// — `expect(historicalBlobs.length, greaterThan(100))` — passed, because a
/// single tip tree clears 100 easily. **The threshold ruled out *zero*; the
/// failure was *vacuity*.** The workflow now sets `fetch-depth: 0` and the
/// guard is a group of assertions about the **scope** rather than a number.
///
/// **And it had become unrunnable where it did have the history.** Reading
/// all 789 MB of blob content into one buffer and copying every blob back out
/// of it took the `setUpAll` past twelve minutes locally. It now asks git only
/// for blobs at or under [_maxScannedBlobBytes] — the bound every content
/// detector here has always applied, so nothing that was scanned stopped
/// being scanned — and reads them in bounded chunks, scanning and discarding
/// each. About five seconds, over the whole history.
/// The files that necessarily contain the patterns these scans look for.
///
/// **A scanner contains the patterns it hunts for**, and so does the
/// placeholder-rejection list it exists alongside: between them they hold the
/// PEM header, the secret variable names, and `POSTGRES_PASSWORD=changeme` as a
/// worked example. Scanning them reports them, every time.
///
/// Excluding two named paths is honest. The alternatives are worse: obfuscating
/// the patterns until the scanner is unreadable, or leaving two permanent
/// failures that teach everyone to ignore this file. Note what is *not*
/// excluded — every other tracked file, which is the whole point.
const List<String> _selfDocumentingPaths = [
  'test/security/no_committed_secrets_test.dart',
  'server/lib/src/security/placeholder_secrets.dart',
];

/// One blob's content, plus every path it was ever found at across the whole
/// history (`git rev-list --objects --all` reaches it more than once when a
/// rename or a duplicate-content commit landed it at more than one path — a
/// blob is content-addressed, so identical bytes at two paths are one object).
class _HistoricalBlob {
  const _HistoricalBlob({
    required this.sha,
    required this.content,
    required this.paths,
  });

  final String sha;
  final Uint8List content;
  final Set<String> paths;

  /// True only when *every* path this content ever lived at is one of
  /// [_selfDocumentingPaths] — mirroring the working-tree exclusion, but
  /// applied per-path rather than per-blob: a blob whose content happens to
  /// also have lived at a real path must still be scanned for that path.
  bool get isSelfDocumenting => paths.every(_selfDocumentingPaths.contains);

  /// A path to report an offense against — any path not in the exclusion
  /// list, since [isSelfDocumenting] already ruled out "all excluded".
  String get reportPath =>
      paths.firstWhere((p) => !_selfDocumentingPaths.contains(p));
}

/// The size above which no content detector in this file has ever looked at a
/// blob — key material and secret assignments are small and textual. Shared by
/// the working-tree checks and the history pass so the two cannot drift, and
/// used to decide which blobs are worth asking git for at all.
const int _maxScannedBlobBytes = 512 * 1024;

/// How many bytes of blob content one `git cat-file --batch` call is asked for
/// before the results are scanned and dropped. Bounds peak memory; the exact
/// value is not load-bearing.
const int _batchChunkBytes = 16 * 1024 * 1024;

/// What one pass over the whole history found — and, just as important, how
/// much of the history it actually reached.
///
/// **The counts are not bookkeeping.** Task 11.150's finding was a scan that
/// reported clean over one commit out of 652, so "what did you look at" is
/// part of the answer rather than a detail about it.
class _HistoryScan {
  /// Commits the object walk named.
  int commitsWalked = 0;

  /// Distinct blob objects the walk named, at any size.
  int blobsNamed = 0;

  /// Distinct blobs whose content was requested — [blobsNamed] less the ones
  /// over [_maxScannedBlobBytes], which no detector here reads.
  int blobsRequested = 0;

  /// Distinct blobs whose content came back and was scanned. A shortfall
  /// against [blobsRequested] means the batch parser stopped early.
  int blobsScanned = 0;

  final List<String> pemOffenders = [];
  final List<String> ageKeyOffenders = [];
  final List<String> secretAssignmentOffenders = [];
}

/// Runs all three content detectors over one historical blob, keeping only
/// what they find. Content is not retained: the whole history does not fit
/// comfortably in memory, and holding it is what made this check unrunnable.
void _scanHistoricalBlob(_HistoricalBlob blob, _HistoryScan into) {
  if (blob.isSelfDocumenting) return;
  final contents = _decodeUtf8OrNull(blob.content);
  if (contents == null) return; // binary; not a PEM file or an assignment
  final where = '${blob.reportPath}@${blob.sha.substring(0, 12)}';
  if (contents.contains('-----BEGIN') && contents.contains('PRIVATE KEY')) {
    into.pemOffenders.add(where);
  }
  if (_agePrivateKeyPattern.hasMatch(contents)) {
    into.ageKeyOffenders.add(where);
  }
  into.secretAssignmentOffenders.addAll(
    _secretAssignmentOffenders(where, contents),
  );
}

/// Reads a whole stream to bytes without assuming a text encoding — history
/// content can be binary, and decoding has to happen per-blob, not per-stream.
Future<Uint8List> _readAllBytes(Stream<List<int>> stream) async {
  final builder = BytesBuilder(copy: false);
  await for (final chunk in stream) {
    builder.add(chunk);
  }
  return builder.toBytes();
}

/// `bytes` as text, or null if it isn't valid UTF-8 — the byte-stream
/// equivalent of the working-tree checks' `catch (FileSystemException)`
/// around `readAsStringSync()`. Binary blob, not a secret-shaped text file.
String? _decodeUtf8OrNull(List<int> bytes) {
  try {
    return utf8.decode(bytes);
  } on FormatException {
    return null;
  }
}

/// Parses `git cat-file --batch`'s default wire format: repeated
/// `<sha> <type> <size>\n<size bytes of content>\n` records, one per
/// requested object, in request order. Byte-level rather than line-based
/// because content can itself contain `\n` — reading this as text first,
/// the way the header line is read here, is exactly the bug that a
/// line-oriented parser would reintroduce.
List<_HistoricalBlob> _parseCatFileBatch(
  Uint8List bytes,
  Map<String, Set<String>> pathsBySha,
) {
  final blobs = <_HistoricalBlob>[];
  var offset = 0;
  while (offset < bytes.length) {
    final headerEnd = bytes.indexOf(0x0A, offset); // '\n'
    if (headerEnd == -1) break;
    final header = ascii.decode(bytes.sublist(offset, headerEnd));
    final parts = header.split(' ');
    // `git cat-file --batch` never reports "missing" here: every sha it was
    // given came from `git rev-list`, which only names objects git itself
    // knows exist.
    if (parts.length != 3) {
      throw StateError('unexpected git cat-file --batch header: "$header"');
    }
    final sha = parts[0];
    final size = int.parse(parts[2]);
    final contentStart = headerEnd + 1;
    final content = bytes.sublist(contentStart, contentStart + size);
    offset = contentStart + size + 1; // content, then its trailing '\n'
    blobs.add(
      _HistoricalBlob(
        sha: sha,
        content: content,
        paths: pathsBySha[sha] ?? const {},
      ),
    );
  }
  return blobs;
}

/// Runs `command`, writes `input` to its stdin, and returns stdout as raw
/// bytes. `Process.run`/`runSync` have no way to supply stdin at all, which
/// is why every call in this file that needs to (both below) goes through
/// `Process.start` instead.
Future<Uint8List> _runWithStdin(
  String executable,
  List<String> args,
  String input,
) async {
  final process = await Process.start(executable, args);
  process.stdin.add(utf8.encode(input));
  final stdoutFuture = _readAllBytes(process.stdout);
  // Drained rather than ignored: an unread stderr pipe can fill its OS buffer
  // and deadlock the child on a repository this size.
  final stderrFuture = _readAllBytes(process.stderr);
  await process.stdin.close();
  final results = await Future.wait([stdoutFuture, stderrFuture]);
  final exitCode = await process.exitCode;
  if (exitCode != 0) {
    throw StateError(
      '$executable ${args.join(' ')} exited $exitCode: '
      '${utf8.decode(results[1], allowMalformed: true)}',
    );
  }
  return results[0];
}

void main() {
  late List<String> trackedFiles;
  late Set<String> everyHistoricalPath;
  late _HistoryScan history;

  setUpAll(() async {
    final result = Process.runSync('git', ['ls-files', '-z']);
    expect(
      result.exitCode,
      0,
      reason: 'this check needs git to enumerate tracked files',
    );
    trackedFiles = (result.stdout as String)
        .split('\x00')
        .where((path) => path.isNotEmpty)
        .toList();

    // Task 10.58: every object reachable from any ref, not the tip of the
    // current branch — `--all` is what makes this "the whole history" rather
    // than "the working tree plus this branch's own log", the same scope
    // §7.4's manual `git log --all -p` review already used.
    final revList = Process.runSync('git', ['rev-list', '--objects', '--all']);
    expect(
      revList.exitCode,
      0,
      reason: 'this check needs git to enumerate every historical object',
    );

    // `rev-list --objects` names every commit, tree, and blob it walks, with
    // a path for trees/blobs and none for commits — but no type marker, so a
    // second pass through `cat-file --batch-check` is what tells a blob
    // (a file's content) apart from a tree (a directory listing) here.
    // `%(rest)` recovers the path `rev-list` already put after the sha on
    // each input line, and `%(objectsize)` is what lets the content pass
    // below skip what it was never going to look at.
    final checkOutput = await _runWithStdin('git', [
      'cat-file',
      '--batch-check=%(objectname) %(objecttype) %(objectsize) %(rest)',
    ], revList.stdout as String);

    history = _HistoryScan();
    final pathsBySha = <String, Set<String>>{};
    final sizeBySha = <String, int>{};
    for (final line in const LineSplitter().convert(utf8.decode(checkOutput))) {
      if (line.isEmpty) continue;
      final parts = line.split(' ');
      if (parts.length < 3) continue;
      if (parts[1] == 'commit') {
        history.commitsWalked++;
        continue;
      }
      if (parts[1] != 'blob') continue;
      final sha = parts[0];
      sizeBySha[sha] = int.parse(parts[2]);
      pathsBySha.putIfAbsent(sha, () => {}).add(parts.sublist(3).join(' '));
    }
    everyHistoricalPath = {for (final paths in pathsBySha.values) ...paths};
    history.blobsNamed = pathsBySha.length;

    // **Only the blobs a content detector would actually read.** Every
    // content check in this file — here and over the working tree — has
    // always skipped anything larger than [_maxScannedBlobBytes], because
    // key material and secret assignments are small and textual. Filtering
    // on the size `--batch-check` has already reported changes what is
    // *transferred*, never what is *scanned*: on this repository, 789 MB of
    // blob content down to 167 MB (measured 2026-09-04).
    final toScan = pathsBySha.keys
        .where((sha) => (sizeBySha[sha] ?? 0) <= _maxScannedBlobBytes)
        .toList();
    history.blobsRequested = toScan.length;

    // Fetched in byte-bounded chunks, each scanned and then dropped, so peak
    // memory is one chunk instead of the whole history. Reading all of it
    // into a single buffer — and then copying every blob back out of it with
    // `sublist` — is what made this `setUpAll` run for over twelve minutes
    // locally on 2026-09-04, which is how task 11.150 started.
    var chunk = <String>[];
    var chunkBytes = 0;
    Future<void> scanChunk() async {
      if (chunk.isEmpty) return;
      final batchOutput = await _runWithStdin('git', [
        'cat-file',
        '--batch',
      ], '${chunk.join('\n')}\n');
      for (final blob in _parseCatFileBatch(batchOutput, pathsBySha)) {
        history.blobsScanned++;
        _scanHistoricalBlob(blob, history);
      }
      chunk = <String>[];
      chunkBytes = 0;
    }

    for (final sha in toScan) {
      chunk.add(sha);
      chunkBytes += sizeBySha[sha] ?? 0;
      if (chunkBytes >= _batchChunkBytes) await scanChunk();
    }
    await scanChunk();
  });

  test('git is enumerating a plausible number of files', () {
    // Guards against the whole suite silently passing because `git ls-files`
    // returned nothing — a check that scans zero files always passes.
    expect(trackedFiles.length, greaterThan(100));
  });

  group('the history scan reached the whole history (task 11.150)', () {
    // **The guard these replace ruled out zero and nothing else.** It was
    // `expect(historicalBlobs.length, greaterThan(100))`, written for exactly
    // the failure it then let through: `offline-suite.yml` checked out with a
    // bare `actions/checkout@v4`, whose default is `fetch-depth: 1`, so CI's
    // "whole history" was a single tip tree. Measured 2026-09-04 — locally
    // 652 commits and 4,744 distinct blobs; in a faithful reproduction of
    // that checkout, **1 commit and 1,047 blobs.** 1,047 is comfortably more
    // than 100, so the guard passed and the suite was green in five minutes
    // having never looked at 651 of 652 commits.
    //
    // The threshold ruled out *zero*; the failure was *vacuity*, and those
    // are not the same. **Picking a bigger number is the same mistake with
    // more digits**, so these assert the scope itself: that the clone holds
    // the whole history, that the walk reached all of it, and that every
    // blob asked for came back.

    test('the repository is not a shallow clone', () {
      final shallow = Process.runSync('git', [
        'rev-parse',
        '--is-shallow-repository',
      ]);
      expect(shallow.exitCode, 0);
      expect(
        (shallow.stdout as String).trim(),
        'false',
        reason:
            'this is a shallow clone, so "every object reachable from any '
            'ref" is only the few commits it was given, and every history '
            'check below is vacuous. A CI checkout step needs '
            '`fetch-depth: 0` — §4.6 asks about the whole history, not the '
            'tip.',
      );
    });

    test('the object walk reached every commit this clone holds', () {
      final counted = Process.runSync('git', ['rev-list', '--count', '--all']);
      expect(counted.exitCode, 0);
      final expected = int.parse((counted.stdout as String).trim());
      expect(
        history.commitsWalked,
        expected,
        reason:
            'git reports $expected commits reachable from some ref and the '
            'object walk named ${history.commitsWalked}',
      );
    });

    test('the walk reached a commit with no parents', () {
      // A true root. On its own this proves little — a shallow clone's
      // grafted boundary also reports no parents — but paired with the
      // not-shallow check above it says the history goes back to its
      // beginning rather than stopping somewhere in the middle.
      final roots = Process.runSync('git', [
        'rev-list',
        '--max-parents=0',
        '--all',
      ]);
      expect(roots.exitCode, 0);
      expect(
        (roots.stdout as String).trim().split('\n').where((l) => l.isNotEmpty),
        isNotEmpty,
        reason: 'no parentless commit is reachable, so this is not a whole '
            'history',
      );
    });

    test('every blob whose content was asked for came back', () {
      // `_parseCatFileBatch` stops at a truncated header rather than
      // throwing, so a short read would quietly scan a prefix of the history
      // and report clean. Nothing else in this file would notice.
      expect(
        history.blobsScanned,
        history.blobsRequested,
        reason:
            'asked git for ${history.blobsRequested} blob contents and '
            'parsed ${history.blobsScanned} back',
      );
    });

    test('reports what it covered', () {
      // Not an assertion — a finding. CI keeps only the last few lines of a
      // run, and this file's entire failure mode was a green tick that never
      // said what it had looked at.
      final unread = history.blobsNamed - history.blobsRequested;
      // ignore: avoid_print
      print(
        'no_committed_secrets scanned ${history.commitsWalked} commits and '
        '${history.blobsScanned} of ${history.blobsNamed} distinct blobs '
        'for content ($unread were over '
        '${_maxScannedBlobBytes ~/ 1024} KB, which no detector in this file '
        'has ever read).',
      );
    });
  });

  test(
    'every excluded path is real, so the list excludes only what it claims',
    () {
      // A stale entry is the dangerous direction: a path that no longer exists
      // excludes nothing (harmless), but one left pointing at a file that has
      // since become something else would exclude that instead, silently. Pinning
      // each to an actually-tracked file makes a rename fail here rather than
      // quietly widen the exclusion.
      for (final path in _selfDocumentingPaths) {
        expect(trackedFiles, contains(path), reason: '$path no longer exists');
      }
    },
  );

  test('no .env file is tracked', () {
    // The single most likely way a real credential gets committed.
    final tracked = trackedFiles.where(
      (path) =>
          path == '.env' || (path.contains('.env') && path != '.env.example'),
    );
    expect(
      tracked,
      isEmpty,
      reason: 'only .env.example may be committed (§4.6)',
    );
  });

  test('.env.example is committed and has no filled-in values', () {
    // §4.6: "every required key present and every value empty. The required set
    // must be discoverable without possessing a secret."
    final example = File('.env.example');
    expect(example.existsSync(), isTrue);

    final offenders = <String>[];
    for (final line in example.readAsLinesSync()) {
      final trimmed = line.trim();
      if (trimmed.isEmpty || trimmed.startsWith('#')) continue;
      final separator = trimmed.indexOf('=');
      if (separator < 0) continue;
      final value = trimmed.substring(separator + 1).trim();
      if (value.isNotEmpty) offenders.add(trimmed);
    }
    expect(
      offenders,
      isEmpty,
      reason:
          '.env.example must ship empty values, found: '
          '${offenders.join(', ')}',
    );
  });

  test('.gitignore carries the secret patterns §4.6 requires', () {
    final gitignore = File('.gitignore').readAsStringSync();
    for (final pattern in [
      '.env',
      '.env.*',
      '!.env.example',
      '*.key',
      '*.pem',
    ]) {
      expect(
        gitignore,
        contains(pattern),
        reason: '§4.6 requires $pattern in .gitignore',
      );
    }
  });

  test('no tracked key or certificate material', () {
    final offenders = trackedFiles.where((path) {
      final lower = path.toLowerCase();
      return lower.endsWith('.key') ||
          lower.endsWith('.pem') ||
          lower.endsWith('.p12') ||
          lower.endsWith('.pfx') ||
          lower.endsWith('.jks') ||
          lower.endsWith('.keystore');
    });
    expect(offenders, isEmpty);
  });

  test('no tracked file contains a PEM private key block', () {
    // Catches key material committed under an innocuous filename, which is the
    // case an extension-based check misses entirely.
    final offenders = <String>[];
    for (final path in trackedFiles) {
      if (_selfDocumentingPaths.contains(path)) continue;
      final file = File(path);
      if (!file.existsSync()) continue;
      // Skip anything large or binary — key material is small and textual.
      if (file.lengthSync() > _maxScannedBlobBytes) continue;
      final String contents;
      try {
        contents = file.readAsStringSync();
      } on FileSystemException {
        continue; // not UTF-8; not a PEM file either
      }
      if (contents.contains('-----BEGIN') && contents.contains('PRIVATE KEY')) {
        offenders.add(path);
      }
    }
    expect(offenders, isEmpty);
  });

  test('no tracked file contains an age private key', () {
    // Added by task 10.24, because that task created a class of key material
    // this repository did not previously have: §4.9's backup identities. An
    // age identity is one line of text with no PEM armour, so the check above
    // does not see it, and it is small enough to paste into a README while
    // writing documentation about where it must never go.
    //
    // The whole of §4.9 rests on the private half not being here: a committed
    // backup key is not one leak, it is every archive ever written under it,
    // in every clone, forever.
    //
    // Matched on the prefix *plus* enough following key material to rule out
    // prose, rather than on the bare prefix. Task 10.24 recorded this trap
    // when the bare-prefix form flagged its own paragraph in the plan doc, and
    // task 10.26 fixed the same class in the assignment regex below but not
    // here — so it flagged §8.7 of the Security Model, which exists to say
    // this check is clean. **A scanner that cannot tell prose from a value
    // will keep finding the documentation that describes it**, and a
    // permanently-red security test is one people stop reading; that is task
    // 10.26's whole subject.
    //
    // Still deliberately short of the full 74-character bech32 string, so a
    // truncated or line-wrapped paste is caught: 20 body characters is far
    // more than any sentence puts after the prefix and far less than a usable
    // key. `.gitignore` covers the expected filenames; this covers the
    // innocuous ones.
    final agePrivateKey = _agePrivateKeyPattern;
    final offenders = <String>[];
    for (final path in trackedFiles) {
      if (_selfDocumentingPaths.contains(path)) continue;
      final file = File(path);
      if (!file.existsSync() || file.lengthSync() > _maxScannedBlobBytes) continue;
      final String contents;
      try {
        contents = file.readAsStringSync();
      } on FileSystemException {
        continue;
      }
      if (agePrivateKey.hasMatch(contents)) offenders.add(path);
    }
    expect(
      offenders,
      isEmpty,
      reason:
          'an age private key appears in a tracked file. Per Security '
          'Model §4.9.1 backup identities live on a holder machine and on '
          'paper, never in the repository — and every archive encrypted to '
          'this key must now be treated as readable: ${offenders.join(', ')}',
    );
  });

  test(
    'no tracked file assigns a non-empty value to a known secret variable',
    () {
      final offenders = <String>[];
      for (final path in trackedFiles) {
        if (_selfDocumentingPaths.contains(path)) continue;
        final file = File(path);
        if (!file.existsSync() || file.lengthSync() > _maxScannedBlobBytes) continue;
        final String contents;
        try {
          contents = file.readAsStringSync();
        } on FileSystemException {
          continue;
        }
        offenders.addAll(_secretAssignmentOffenders(path, contents));
      }
      expect(
        offenders,
        isEmpty,
        reason:
            'a secret appears to be assigned a literal value in a tracked '
            'file: ${offenders.join('; ')}',
      );
    },
  );

  group(
    'the same checks, across the whole history (task 10.58, finding I-7)',
    () {
      // §4.6/§7.4's actual criterion, run automatically instead of by hand:
      // every blob ever reachable from any ref, not the files `git ls-files`
      // reports today. A secret pushed and reverted three commits later would
      // pass every test above and fail every test here — that gap is the
      // finding.
      test('no .env file has ever been tracked, at any point in history', () {
        final offenders = everyHistoricalPath.where(
          (path) =>
              path == '.env' ||
              (path.contains('.env') && path != '.env.example'),
        );
        expect(
          offenders,
          isEmpty,
          reason:
              'only .env.example may ever have been committed (§4.6): '
              '${offenders.join(', ')}',
        );
      });

      test('no key or certificate file has ever been tracked', () {
        final offenders = everyHistoricalPath.where((path) {
          final lower = path.toLowerCase();
          return lower.endsWith('.key') ||
              lower.endsWith('.pem') ||
              lower.endsWith('.p12') ||
              lower.endsWith('.pfx') ||
              lower.endsWith('.jks') ||
              lower.endsWith('.keystore');
        });
        expect(offenders, isEmpty, reason: offenders.join(', '));
      });

      test('no historical blob contains a PEM private key block', () {
        expect(
          history.pemOffenders,
          isEmpty,
          reason:
              'a PEM private key block was committed and later removed, '
              'which still means every clone of this repository has it: '
              '${history.pemOffenders.join(', ')}',
        );
      });

      test('no historical blob contains an age private key', () {
        expect(
          history.ageKeyOffenders,
          isEmpty,
          reason:
              'an age private key was committed and later removed. Per '
              'Security Model §4.9.1 every archive ever encrypted to it must '
              'now be treated as readable, in every clone: '
              '${history.ageKeyOffenders.join(', ')}',
        );
      });

      test('no historical blob assigns a non-empty value to a known secret '
          'variable', () {
        expect(
          history.secretAssignmentOffenders,
          isEmpty,
          reason:
              'a secret was assigned a literal value in a commit that is '
              'no longer the tip — removing it later does not unpublish it: '
              '${history.secretAssignmentOffenders.join('; ')}',
        );
      });
    },
  );

  group('secret-assignment detector (§4.6)', () {
    // The detector's own logic, exercised directly against fabricated
    // strings rather than the real tree — so "the detector still catches a
    // real secret" can be proven without ever committing one.
    test('still flags a genuinely assigned secret value', () {
      expect(
        _secretAssignmentOffenders('synthetic', 'POSTGRES_PASSWORD=hunter2'),
        isNotEmpty,
        reason: 'a literal secret assignment must still be caught',
      );
    });

    test('still flags a YAML-style literal assignment', () {
      expect(
        _secretAssignmentOffenders('synthetic', 'POSTGRES_PASSWORD: hunter2'),
        isNotEmpty,
      );
    });

    test('does not flag the bash required-variable operator quoted in prose '
        '(the regression that made this test permanently red on main)', () {
      // This is exactly what two CLAUDE_DOCS/*.md files and both backup
      // scripts contain: `${POSTGRES_PASSWORD:?POSTGRES_PASSWORD is not set}`
      // — bash's "error if unset" operator, not an assignment. `:?` reuses the
      // same `:` the detector treats as a YAML separator elsewhere.
      expect(
        _secretAssignmentOffenders(
          'synthetic',
          r'Every compose file uses ${POSTGRES_PASSWORD:?...}',
        ),
        isEmpty,
      );
      expect(
        _secretAssignmentOffenders(
          'synthetic',
          r': "${POSTGRES_PASSWORD:?POSTGRES_PASSWORD is not set}"',
        ),
        isEmpty,
      );
    });

    test('the age-key detector still flags a key-shaped value', () {
      // Assembled at runtime rather than written as a literal. This file is in
      // _selfDocumentingPaths so a literal would not fail *this* suite — but
      // it would sit in the repository looking exactly like a committed
      // backup identity to GitHub's secret scanning, to the next person
      // grepping, and to any tool that does not know about that exemption.
      // §4.9's cost for a real one is every archive ever written under it, so
      // "it's only a fixture" is not a thing to make a reader verify.
      final keyShaped = '${'AGE-SECRET'}-KEY-1${'Q7X2M9K4WRJ8LS0PZV6HN'}';
      expect(
        _agePrivateKeyPattern.hasMatch(keyShaped),
        isTrue,
        reason: 'if this stops matching, §4.9.1 goes unguarded',
      );
    });

    test('the age-key detector does not flag prose naming the prefix', () {
      // §7.4 and §8.7 of the Security Model both write the prefix out while
      // reporting that no key is committed. Task 10.24 hit this and reworded;
      // task 10.26 fixed the same class in the assignment regex but not here.
      expect(
        _agePrivateKeyPattern.hasMatch(
          'The single AGE-SECRET-KEY-1 match in the entire history is the '
          'detector constant in this file.',
        ),
        isFalse,
      );
    });

    test('does not flag other bash parameter-expansion operators', () {
      // `${VAR:-default}`, `${VAR:=default}`, `${VAR:+alt}` share the same
      // `:`-reuse trap as `:?` above.
      expect(
        _secretAssignmentOffenders(
          'synthetic',
          r'TRITRACK_DIAGNOSTICS_TOKEN: ${TRITRACK_DIAGNOSTICS_TOKEN:-}',
        ),
        isEmpty,
      );
    });

    test('does not flag an ellipsis placeholder in a worked example '
        '(task 10.58\'s own live find, in six historical revisions of '
        'DEVELOPMENT_PLAN.md)', () {
      expect(
        _secretAssignmentOffenders(
          'synthetic',
          'POSTGRES_USER=... POSTGRES_PASSWORD=... dart test --tags postgres',
        ),
        isEmpty,
      );
    });

    test('does not flag the task 11.68 placeholder, bare or backtick-quoted '
        'in prose', () {
      expect(
        _secretAssignmentOffenders(
          'synthetic',
          'POSTGRES_PASSWORD=ci-not-a-real-password',
        ),
        isEmpty,
      );
      expect(
        _secretAssignmentOffenders(
          'synthetic',
          'it fails on `POSTGRES_PASSWORD=ci-not-a-real-password` in the '
          'workflow.',
        ),
        isEmpty,
      );
    });

    test('the task 11.68 allowlist is exact, not a prefix — a real secret '
        'that merely starts with the placeholder is still flagged', () {
      expect(
        _secretAssignmentOffenders(
          'synthetic',
          'POSTGRES_PASSWORD=ci-not-a-real-password-actually-it-is',
        ),
        isNotEmpty,
        reason:
            'the allowlist must match the exact placeholder value, not '
            'anything it prefixes — otherwise appending to it hides a '
            'real secret',
      );
    });
  });
}

// An `age` private key: the fixed prefix plus enough bech32 body to be a value
// rather than a mention. See the long note at the call site for why the bare
// prefix was not enough — and **if you touch this, re-run the prose test
// below**, which is the regression that flagged the Security Model's own
// "no age key is committed" paragraph.
final _agePrivateKeyPattern = RegExp(r'AGE-SECRET-KEY-1[A-Z0-9]{20}');

// Deliberately narrow: the *specific* variables §4.6 inventories, assigned a
// literal value. A broad entropy scan over a repository this size would flag
// base64 test fixtures, WMM coefficients, and generated code — and a check
// that cries wolf is a check people delete.
const _secretVariables = [
  'POSTGRES_PASSWORD',
  'SMTP_PASSWORD',
  'TRITRACK_DIAGNOSTICS_TOKEN',
];

// `NAME=value` or `NAME: value`, with a non-empty value.
//
// `[ \t]*` rather than `\s*` around the separator, deliberately: `\s` matches
// a newline, so `POSTGRES_PASSWORD=\nPOSTGRES_DB=` would parse the *next
// line's variable name* as this line's value and report `.env.example` — a
// false positive that would get this whole check deleted as noisy.
final _secretAssignmentPattern = RegExp(
  '(${_secretVariables.join('|')})[ \\t]*([:=])[ \\t]*(\\S+)',
);

// Bash parameter-expansion operators (`:-`, `:=`, `:+`, `:?`) all start with
// the same `:` the regex above reads as a YAML-style separator. A scanner
// that can't tell `POSTGRES_PASSWORD: hunter2` (an assignment) from
// `${POSTGRES_PASSWORD:?message}` (bash's "required" check, often quoted in
// prose describing that very check) will flag the documentation forever.
// **If you touch this regex, re-run the bash-operator tests above** — that
// is the trap that made this file red on `main` from before task 10.22.
final _bashExpansionOperator = RegExp(r'^[-=+?]');

// Task 11.68: known-safe placeholder values, allowlisted by their exact
// literal rather than by path or pattern. Narrower than excluding a whole
// file — a real secret landing in the same file is still caught.
//
// `ci-not-a-real-password`: the throwaway Postgres password task 11.30
// found committed as a literal in `.github/workflows/offline-suite.yml`
// (commit `5245e9a`). Task 11.68 moved the live workflow to a password
// generated at runtime, but that does not touch the commit that already
// carries the old literal, or the documentation (including
// `CLAUDE_DOCS/TASK_COMMS.md`'s append-only "Resolved" section, which this
// project's own rules forbid editing) that has since quoted it verbatim to
// describe the finding. Both are permanently reachable in history — the
// only way to stop matching them is to rewrite history, which is a far
// more destructive fix than allowlisting one string is a cost.
const _allowlistedSecretValues = {'ci-not-a-real-password'};

// Trailing punctuation from prose quoting the value — a closing backtick, a
// sentence's final period — is not part of the value itself, only part of
// how a doc quotes it. Stripped before comparing against the allowlist so
// "`...ci-not-a-real-password`" matches the same literal a real assignment
// would.
final _trailingQuotePunctuation = RegExp(r'''[`'".,;:!?)\]}]+$''');

List<String> _secretAssignmentOffenders(String path, String contents) {
  final offenders = <String>[];
  for (final match in _secretAssignmentPattern.allMatches(contents)) {
    final separator = match.group(2)!;
    final value = match.group(3)!;
    if (separator == ':' && _bashExpansionOperator.hasMatch(value)) {
      continue;
    }
    if (_allowlistedSecretValues.contains(
      value.replaceAll(_trailingQuotePunctuation, ''),
    )) {
      continue;
    }
    // A compose `$VAR` / `${VAR}` interpolation, an env passthrough, a Dart
    // string literal naming the key, or a doc mention are all references
    // rather than values.
    if (value.startsWith(r'$') ||
        value.startsWith("'") ||
        value.startsWith('"') ||
        value.startsWith('<') ||
        value.startsWith('#')) {
      continue;
    }
    // An ellipsis: "fill in your own value" in a worked shell example, not a
    // value. Task 10.58's history scan found this exact shape —
    // `POSTGRES_USER=... POSTGRES_PASSWORD=... dart test --tags postgres` —
    // in six historical revisions of `CLAUDE_DOCS/DEVELOPMENT_PLAN.md`; the
    // working-tree scan never saw it because the line has since been
    // reworded, which is precisely the gap the history scan exists to close.
    if (value == '...') continue;
    offenders.add('$path: ${match.group(0)}');
  }
  return offenders;
}
