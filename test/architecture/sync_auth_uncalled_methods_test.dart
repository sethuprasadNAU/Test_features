import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../support/dart_source.dart';

/// **Task 11.62 — the class, not the three instances.**
///
/// Three tasks in three days each found a public method in the sync or auth
/// seams that is documented as doing something useful and has no caller
/// anywhere in `lib/` — `SyncController.syncIfDue` (task 11.57/11.59, and the
/// expensive one: it was the whole reason the app never synced by itself),
/// `SyncSchedule.resumed()` (task 11.59, deleted by this task once its actual
/// job moved to `SyncStateStore.clearLastAttemptAt`), and
/// `ProjectMembershipRepository.grantOwner` (task 11.57, deleted by this task:
/// its insert-a-stranger branch named somebody other than the caller, which
/// the server's `_authorizeNaming` refuses unconditionally, so it failed at
/// both ends and nothing had ever hit it). Each was found by somebody
/// happening to look. This is what looks instead.
///
/// ## Scope, and why it stops here
///
/// "The sync and auth seams" was read as: everything under `lib/data/sync/`
/// and `lib/data/auth/`, the two provider files that expose them
/// (`sync_provider.dart`, `auth_provider.dart`), and
/// `project_membership_repository.dart` — the membership/authorization seam
/// `grantOwner` lived in.
///
/// **Task 11.212 widened it to the whole of `lib/data/repositories/`**, which
/// task 11.62 had left as a separate decision to be taken on a count rather
/// than a guess. The count came back a handful, so the decision fired as it
/// had been written in advance: widen.
///
/// **95 distinct public candidates in that directory and three genuinely
/// uncalled** — `historyFor` and `findByUserId`, both deleted (each had
/// callers only in the tests asserting on it, which proves nothing about the
/// app), and `findBySession`, which is retired code kept on purpose and is now
/// the argued exemption below rather than a sentence in this doc.
///
/// **Task 11.65 measured 109 and four, and both figures were the broken
/// parser's.** A fourth "uncalled method", `resolveProjectRole`, was never a
/// declaration at all, and thirteen more phantoms were being invented and
/// silently cleared — see [_statementKeywords], which is the half of this that
/// outlives the count.
///
/// ## How a candidate is found, and how it is cleared
///
/// 1. Every public instance or static method declared in a scope file —
///    `returnType name(` at class-member indentation, skipping constructors
///    (no return type precedes the name), `get`/`set` accessors (the token
///    before the name would be literally `get` or `set`), anything
///    immediately preceded by `@override` (reached through an interface or a
///    framework callback — exactly the trap this guard must not chase), and
///    the handful of `Object` methods every class carries for free.
/// 2. Cleared if the name appears anywhere else in `lib/` (excluding
///    generated files, matching this project's existing convention — see
///    `dart_source.dart`) either as a call (`name(`) beyond its own
///    declaration, or as a tear-off (`.name` used as a value, e.g. handed to
///    a callback with no parens) — which is what a naive "no caller" search
///    misses and turns into a wall of false positives on the sync engine's
///    listener-registered methods.
/// 3. A survivor is failed unless [_deliberatelyUnused] names it with a
///    reason.
///
/// ## What this cannot see, stated rather than implied
///
/// Textual, like every other guard in this style (`dart_source.dart`'s own
/// doc). A method reached only from a `.g.dart` file, or invoked through
/// `Function.apply`/`noSuchMethod`/reflection, would read as uncalled here
/// and is not — none of the current seam files do that. And a name reused by
/// coincidence elsewhere in `lib/` clears a genuinely dead method; that is
/// the safe direction to be wrong in, not the dangerous one.
void main() {
  final candidates = _publicMethodCandidates();

  test('found candidate methods to check — if this is small or empty, the '
      'declaration parser is broken and every test below passes vacuously', () {
    expect(
      candidates.length,
      greaterThanOrEqualTo(30),
      reason:
          'Found only ${candidates.length} candidate methods across the '
          'sync/auth seams: $candidates. That is far fewer than these files '
          'actually declare — the declaration regex most likely stopped '
          'matching this codebase\'s shape.',
    );
  });

  test('the declaration parser reads declarations and not statements', () {
    // Task 11.212. `return resolveProjectRole(` sat at exactly the indentation
    // a class member sits at, and was read as a declaration for as long as
    // this guard existed. This fixture is what says so without needing the
    // codebase to contain an example that happens to fail.
    // The statements sit at **two** spaces, which is the whole point: that is
    // a top-level function's body, and it is exactly where a class member's
    // declaration sits too. `project_role_lookup.dart` is such a file.
    const source = '''
Future<int> topLevelFunction(String a) async {
  return helperCall(a);
}

class Example {
  Future<int> realMethod(String a) async {
    return deeperCall(a);
  }
}

int another(String a) {
  throw StateError(a);
}
''';
    expect(
      _candidatesInSource('fixture.dart', source).map((c) => c.name).toList()
        ..sort(),
      ['realMethod'],
      reason:
          'Only realMethod is a class-member declaration. helperCall and '
          'StateError sit at the same two-space column and are statements — a '
          'parser that invents them reports "no caller in lib/" about a name '
          'that was never declared in this file at all. deeperCall is '
          'indented past that column and was never at risk, and the two '
          'top-level functions are outside this guard\'s scope by design.',
    );
  });

  final corpus = {
    for (final file in dartFilesUnder('lib'))
      _relative(file.path): stripComments(file.readAsStringSync()),
  };

  group('every public sync/auth method has a caller in lib/', () {
    for (final candidate in candidates) {
      final key = '${candidate.file}:${candidate.name}';
      test(key, () {
        final reason = _deliberatelyUnused[key];
        if (reason != null) {
          expect(
            reason,
            isNotEmpty,
            reason:
                '$key is registered as deliberately unused but with an '
                'empty reason — say why it stays.',
          );
          return;
        }
        final called = _hasCallerOutsideDeclaration(
          corpus: corpus,
          declaringFile: candidate.file,
          methodName: candidate.name,
        );
        expect(
          called,
          isTrue,
          reason:
              '${candidate.name} (declared in ${candidate.file}) has no '
              'caller anywhere in lib/ — the shape task 11.62 exists to catch: '
              'SyncController.syncIfDue was, for months, the whole reason the '
              'app never synced by itself, and nothing noticed until somebody '
              'happened to look. If it is genuinely dead, delete it. If it is '
              'reached in a way this guard cannot see (a callback, a '
              'generated file, an interface dispatch), add it to '
              '_deliberatelyUnused in this file with the reason.',
        );
      });
    }
  });

  test('every _deliberatelyUnused entry still names a real candidate', () {
    for (final key in _deliberatelyUnused.keys) {
      expect(
        candidates.any((c) => '${c.file}:${c.name}' == key),
        isTrue,
        reason:
            '$key is registered as deliberately unused but is not a '
            'candidate the parser finds any more — it was renamed, deleted, '
            'or the parser changed shape. A stale exemption is cover for '
            'whatever moves into that name next; delete the entry.',
      );
    }
  });
}

/// A public method declaration found in one of the scope files.
class _MethodCandidate {
  const _MethodCandidate(this.file, this.name);
  final String file;
  final String name;

  @override
  String toString() => '$file:$name';
}

/// Names every class carries for free, and Riverpod's generated override —
/// none of these are ever found by a caller searching for their name; they
/// are dispatched by the language or the framework.
const _frameworkMethods = {
  'toString',
  'hashCode',
  'noSuchMethod',
  'build',
  'call',
};

const _modifierKeywords = {
  'const',
  'final',
  'factory',
  'required',
  'covariant',
  'late',
  'abstract',
  'this',
  'super',
};

/// Keywords that can open a *statement* and be followed by `identifier(` at
/// the same two-space indentation a class member sits at — so the declaration
/// regex's `returnType name(` shape matches them and invents a method.
///
/// **Found by task 11.212, and only because one of them failed.** Widening the
/// scope to `lib/data/repositories/` put `return resolveProjectRole(` — a
/// *call*, at the top level of `project_role_lookup.dart`, to a function that
/// lives in `packages/tritrack_sync/` — in front of this parser, which read it
/// as a declaration of a method named `resolveProjectRole` and then correctly
/// reported that `lib/` holds no caller for it. **Fourteen of these were being
/// invented across the widened scope and thirteen passed silently**, because
/// `return ObservationRepository(` and its twelve siblings in
/// `repository_providers.dart` name classes that are constructed all over
/// `lib/`, so the caller search cleared them. **A false candidate that clears
/// itself is the dangerous half**: it costs nothing today and it is the reason
/// the parser's shape was never questioned.
const _statementKeywords = {'return', 'throw', 'await', 'yield', 'new', 'case'};

const _scopeDirectories = [
  'lib/data/sync',
  'lib/data/auth',
  'lib/data/repositories',
];
const _scopeFiles = [
  'lib/core/providers/sync_provider.dart',
  'lib/core/providers/auth_provider.dart',
];

/// `returnType name(` at class-member indentation (two spaces), across the
/// flattened (comment-stripped) source — so a multi-line parameter list is no
/// obstacle, matching `dart_source.dart`'s existing convention.
final _declaration = RegExp(
  r'\n  (static\s+)?([A-Za-z_]\w*(?:<[^()]*>)?\??)\s+([a-zA-Z_]\w*)\s*\(',
);

List<_MethodCandidate> _publicMethodCandidates() {
  // Keyed by path rather than by `File`, which has identity equality — two
  // `File` objects for one path are two set members, and would have produced
  // two identically-named tests for every method in an overlapping scope.
  final files = <String, File>{
    for (final dir in _scopeDirectories)
      for (final file in dartFilesUnder(dir)) _relative(file.path): file,
    for (final path in _scopeFiles) path: File(path),
  };
  final candidates = <_MethodCandidate>[];
  for (final entry in files.entries) {
    final path = entry.key;
    final file = entry.value;
    candidates.addAll(
      _candidatesInSource(path, stripComments(file.readAsStringSync())),
    );
  }
  candidates.sort((a, b) => '$a'.compareTo('$b'));
  return candidates;
}

/// The declaration parser itself, over already-comment-stripped [source].
///
/// Split out of [_publicMethodCandidates] by task 11.212 so its own rules can
/// be exercised against a fixture rather than only against whatever the
/// codebase happens to contain today — the shape that let a statement read as
/// a declaration for as long as no invented name happened to fail.
List<_MethodCandidate> _candidatesInSource(String path, String source) {
  final candidates = <_MethodCandidate>[];
  for (final m in _declaration.allMatches(source)) {
    final returnTypeToken = m.group(2)!;
    final name = m.group(3)!;
    if (returnTypeToken == 'get' || returnTypeToken == 'set') continue;
    // A modifier keyword in the return-type slot means this is not a
    // method declaration at all — it is a constructor with a keyword in
    // front of it (`const Foo(...)`, `const factory Foo.bar(...)`), which
    // this regex's two-token shape otherwise mistakes for `returnType
    // name(`. Measured: without this, every enum's and every sealed
    // class's own `const EnumName(...)` constructor showed up as a
    // "method" named after its class.
    if (_modifierKeywords.contains(returnTypeToken)) continue;
    // A statement keyword in the return-type slot means this is a statement,
    // not a declaration — see [_statementKeywords] for the measurement.
    if (_statementKeywords.contains(returnTypeToken)) continue;
    if (name.startsWith('_')) continue;
    if (_frameworkMethods.contains(name)) continue;
    if (name == '==' || name == 'operator') continue;
    // `@override` sits on its own line directly above the declaration —
    // reached through an interface or a framework callback, which is
    // exactly the trap this guard must not chase (CLAUDE.md's "a naive
    // search returns a wall of false positives" warning).
    final beforeNewline = source.lastIndexOf('\n', m.start - 1);
    final lineBefore = beforeNewline == -1
        ? ''
        : source
              .substring(
                source.lastIndexOf('\n', beforeNewline - 1) + 1,
                beforeNewline,
              )
              .trim();
    if (lineBefore == '@override') continue;
    candidates.add(_MethodCandidate(path, name));
  }
  return candidates;
}

/// Whether [methodName] appears anywhere in [corpus] other than as its own
/// declaration in [declaringFile] — as a call (`name(`) or a bare tear-off
/// (`.name` with nothing else attached).
bool _hasCallerOutsideDeclaration({
  required Map<String, String> corpus,
  required String declaringFile,
  required String methodName,
}) {
  final call = RegExp('\\b${RegExp.escape(methodName)}\\s*\\(');
  final tearOff = RegExp('\\.${RegExp.escape(methodName)}\\b(?!\\s*\\()');
  for (final entry in corpus.entries) {
    var calls = call.allMatches(entry.value).length;
    if (entry.key == declaringFile) {
      // One of these calls is the declaration itself; every other is a real
      // (possibly recursive) invocation.
      calls -= 1;
    }
    if (calls > 0) return true;
    if (tearOff.hasMatch(entry.value)) return true;
  }
  return false;
}

String _relative(String path) =>
    path.startsWith('./') ? path.substring(2) : path;

/// Methods this guard would otherwise fail, kept anyway — each entry is a
/// claim that has to hold, not a way of getting to green. See the file-level
/// doc for what "reached in a way this guard cannot see" means in practice.
const _deliberatelyUnused = <String, String>{
  // **Found by this guard's own first run (task 11.62), not one of the three
  // named instances.** `SyncRowReceiptStore.forgetProject` forgets every
  // synced-row receipt for a project, so the next push re-offers all of it —
  // the escape hatch `SyncStateStore.resetPushWatermark` used to be, kept for
  // "this device and the server disagree and I cannot tell why". It is
  // exercised by `sync_engine_test.dart` and does what its doc says. Nothing
  // in the app calls it: there is no "force a full resync" affordance
  // anywhere in the UI to wire it to.
  //
  // **Decided by the planning session, 2026-09-10 (task 11.65):** left
  // deliberately unwired. A resync-from-scratch button re-offers every record
  // on a link that may be slow, and nobody has yet hit a situation where it
  // would have helped — building a control for a problem that has not
  // happened is how a screen gets crowded. **It earns a control the first
  // time a beta device has records stuck with nothing else able to recover
  // them.** Not a reason to re-open this entry on its own; re-open it when
  // that beta situation actually occurs.
  // **Task 11.212, when the scope reached it.** `Triangulation_Sessions` has
  // been a write-nothing table since task 11.197 removed the Record screen's
  // *Attach to triangulation session* checkbox — the only thing in the app
  // that ever inserted a row. `ObservationRepository.findBySession` is the
  // only way to read back the rows devices already made, and those rows are
  // real data that still syncs.
  //
  // **This is the argued exemption the guard asks for, not a way to green.**
  // The two methods beside it in the same widened scope were deleted; this one
  // stays because deleting it would leave a populated, syncing column with no
  // read path at all, which is a different and worse thing than an unused
  // method. **Re-open it the day `Observations.session_id` stops carrying
  // data** — if a migration ever drops the column, this method goes with it.
  'lib/data/repositories/observation_repository.dart:findBySession':
      'the only read path for Triangulation_Sessions rows devices already '
      'wrote — a write-nothing table since task 11.197, whose existing rows '
      'still sync and are real data; dated 2026-09-09 by task 11.212, and '
      'to be deleted with Observations.session_id if that column is ever '
      'dropped',
  'lib/data/sync/sync_row_receipts.dart:forgetProject':
      'an intentional recovery primitive with no UI trigger yet — left '
      'deliberately on 2026-09-10 (task 11.65); it earns a control the '
      'first time a beta device has records stuck with nothing else able '
      'to recover them — see task 11.62\'s comms entry',
  // **Task 11.243's two entries are gone, and the trigger firing is what
  // removed them** (task 11.244, 2026-09-14).
  //
  // Both were declared with 11.244 named as the condition to re-open them,
  // and both now have real callers: `unlink` is the *Remove record* button
  // on the animal's screen, and the derivation is the Log's animal filter.
  //
  // **The derivation changed shape on the way**, which is the part worth
  // keeping. It was `animalForObservation`, an `async` method with its own
  // query, and the honest answer to *"find it a caller"* turned out to be
  // that **every real caller asks it about a screenful of records at once** —
  // one SQLite round trip per row on the UI path. It is
  // `animalForObservationIn` now, a pure function over deployments the
  // caller already has. The exemption list asked the question; the answer
  // was not the one the entry predicted.
};
