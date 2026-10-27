import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../support/dart_source.dart';

/// **Nothing may write data the screens display without telling the screens.**
///
/// ## What went wrong, and what went wrong with the first guard
///
/// A Mac synced on 2026-08-27, said "sync successful", and the teammate's
/// bearings were not on the map. They were in SQLite. Nothing told the map.
/// `_mapDataProvider` and `historyDataProvider` are plain (non-`autoDispose`)
/// family providers on tabs that live as long as the process, so their cached
/// result survived until the app was quit.
///
/// The guard written the same day held **a hand-written list of five files**
/// and checked each still contained a bump. A sixth inbound path in a file not
/// on the list was silently exempt — and there already was one:
/// `ServerIdentityAdopter`, which rewrites `user_id` across every table at
/// sign-in and hard-deletes the superseded `Users` rows, so the log could go on
/// naming the wrong author. The list did not know about it, so the guard was
/// green. That is task 11.45: the list read as coverage and was not.
///
/// ## What this asserts now, and how the set is derived
///
/// Nothing here is written down by hand. Every step reads the code:
///
/// 1. **Which providers display recordings** — every provider in `lib/` whose
///    body calls `ref.watch(recordingsRevisionProvider)`.
/// 2. **Which repositories those providers read** — the
///    `<name>RepositoryProvider` reads inside those provider bodies.
/// 3. **Which tables those repositories own** — each repository's
///    `table: Tables.x` in its own constructor, resolved through
///    `schema_constants.dart` to the real table name. This is the
///    *display table* set.
/// 4. **Which methods write** — a fixpoint over `lib/data/repositories/`,
///    seeded from the calls that reach SQLite directly (`db.insert`,
///    `db.rawUpdate`, …) and closed over every repository method that calls
///    one. This is the *write method* set.
/// 5. **Which files write a display table** — a file writes one if it names it
///    in a direct `insert`/`update`/`delete`, or if it holds a repository whose
///    table is a display table and calls a write method on it.
/// 6. **Every such file must announce**, by calling `DataArrival.announce()`
///    or bumping `recordingsRevisionProvider` itself.
///
/// Add a sixth inbound path anywhere in `lib/` and this goes red without
/// anybody adding a line. That is the difference from the list it replaces.
///
/// ## What it still cannot see, stated rather than implied
///
/// - **Raw SQL built by string interpolation**, e.g. `'UPDATE $table SET …'`
///   where `table` is a variable. `ProjectMerger` and `RowKeyMigration` both do
///   this. The merger is caught anyway because it names `Tables.*` elsewhere;
///   a *new* file that only ever interpolates its table names would not be.
/// - **A screen that displays recordings without watching the revision
///   provider.** This guard derives the display set *from* that watch, so a
///   screen that never watches it is outside the question rather than exempt
///   from it — it was already broken before anything was written.
/// - It reads text, not a resolved element model. A repository reached through
///   an unusual expression (a function return, a collection) would be missed.
///
/// The [_exemptions] below fail closed in both directions: a file that starts
/// writing display data with no announcement goes red, and an exemption whose
/// file no longer writes display data also goes red, so the list cannot rot
/// into cover for something it was never about.
void main() {
  final tableNames = _tableNameConstants();
  final repositoryTables = _repositoryTables(tableNames);
  final providerToRepository = _repositoryProviders();
  final displayRepositories =
      _displayRepositories(providerToRepository, repositoryTables);
  final displayTables = {
    for (final repo in displayRepositories) repositoryTables[repo]!,
  };
  final writeMethods = _repositoryWriteMethods();
  final repositoryDefinitions = repositoryTables.keys.toSet();

  final constants = _stringConstants();
  final migrationBodies = _migrationBodyFiles();
  final writeSites = <String, _WriteSite>{};
  for (final file in dartFilesUnder('lib')) {
    final source = stripComments(file.readAsStringSync());
    if (_definesRepositoryClass(source, repositoryDefinitions)) continue;
    final site = _analyseWrites(
      source,
      constants: constants,
      displayTables: displayTables,
      displayRepositories: displayRepositories,
      providerToRepository: providerToRepository,
      repositoryTables: repositoryTables,
      writeMethods: writeMethods,
    );
    if (site.writesAnything) writeSites[_relative(file.path)] = site;
  }

  group('the derivation itself', () {
    test('found the files that run as a schema migration', () {
      // **Refuses an empty result.** A search that finds nothing and a
      // migration list with no run-bodied entry are indistinguishable from
      // the inside, and only one of them is true today: schema v14 is
      // registered as `Migration.run(14, TagScopeMigration.apply)`. The day
      // that stops being so, this says so rather than quietly deriving zero
      // files and treating the fork as an ordinary writer.
      expect(
        migrationBodies,
        isNotEmpty,
        reason:
            'No `Migration.run(N, Class.method)` entry was found in '
            '$_migrationsPath, or none resolved to a file under lib/. Either '
            'every migration is a statement list again — then delete this '
            'derivation — or the registration moved and this is reading the '
            'wrong thing.',
      );
      // ignore: avoid_print
      print('files that run as a schema migration (exempt from announcing, '
          'because they run inside AppDatabase.open before any provider '
          'exists): ${migrationBodies.keys.join(', ')}');
    });

    test('found the tables the screens display', () {
      expect(
        displayTables,
        contains('Observations'),
        reason:
            'The display-table set was derived as $displayTables, which does '
            'not include Observations. Either no provider watches '
            'recordingsRevisionProvider any more, or the way providers read '
            'repositories changed shape and _displayRepositories can no '
            'longer see it. Everything below is measuring nothing until this '
            'passes.',
      );
      expect(displayTables.length, greaterThanOrEqualTo(5));
    });

    test('found the methods that write', () {
      expect(
        writeMethods,
        containsAll(<String>['insert', 'insertRow', 'update', 'updateById']),
        reason:
            'The write-method fixpoint returned $writeMethods. If it no longer '
            'contains the basics, no repository call site can be recognised '
            'and every screen below passes vacuously.',
      );
    });

    test('found the files that write display data', () {
      expect(
        writeSites.keys,
        containsAll(<String>[
          'lib/data/sync/project_merger.dart',
          'lib/data/sharing/shared_observation_importer.dart',
        ]),
        reason:
            'The two writers every inbound path funnels through were not '
            'recognised as writing display data. Derived set: '
            '${writeSites.keys.toList()}',
      );
      expect(writeSites.length, greaterThanOrEqualTo(8));
    });
  });

  /// **The self-check for the idiom [_announces] added for task 11.151.**
  ///
  /// Three screens now announce by calling `refreshTagViews`, whose bump lives
  /// in another file. A rename, or a helper quietly stripped of its bump,
  /// would make those three screens silently exempt while this guard stayed
  /// green — the failure mode CLAUDE.md records twice (a harness patching a
  /// line it does not own, and a compose healthcheck naming a flag another
  /// file provides). **So the dependency is asserted rather than assumed.**
  test('the tag-view refresh helper really does announce', () {
    final file = File(_tagViewRefreshPath);
    expect(
      file.existsSync(),
      isTrue,
      reason:
          '$_tagViewRefreshPath is gone, but _announces still treats a call to '
          'refreshTagViews as an announcement. Either restore it or drop that '
          'clause — leaving both is how three screens stop being checked '
          'without anything going red.',
    );
    final source = stripComments(file.readAsStringSync());
    expect(
      RegExp(r'void refreshTagViews\b').hasMatch(source),
      isTrue,
      reason:
          'refreshTagViews has been renamed. _announces matches it by name, so '
          'every screen relying on it is now unchecked. Update both together.',
    );
    // **Per entry point, not per file.** A whole-file `contains` passes while
    // one of the two functions has been gutted — measured: removing the bump
    // from `refreshTagViews` alone left this test green, because
    // `refreshTagViewsIn` still had one. A check that cannot tell that apart
    // is not a check.
    for (final name in const ['refreshTagViews', 'refreshTagViewsIn']) {
      final at = source.indexOf('void $name(');
      expect(
        at,
        isNot(-1),
        reason:
            '$name is gone or renamed. _announces matches it by name, so every '
            'screen relying on it is now unchecked. Update both together.',
      );
      // Bounded by the closing brace at column 0 — the end of this function,
      // not "up to the next one", which is the delimiter that loses the last
      // element (task 11.84).
      final close = source.indexOf('\n}', at);
      expect(
        close,
        isNot(-1),
        reason: 'could not find the end of $name; this check is not reading '
            'what it thinks it is reading',
      );
      expect(
        source.substring(at, close),
        contains('recordingsRevisionProvider.notifier).bump()'),
        reason:
            '$name no longer bumps the revision counter, so screens announcing '
            'through it are announcing nothing — and without this check the '
            'guard above would go on passing them. Task 11.151 built this '
            'helper to carry exactly that.',
      );
    }
  });

  group('everything that writes display data announces it', () {
    writeSites.forEach((path, site) {
      test('$path announces', () {
        // **A schema migration is the one writer that may name a displayed
        // table and tell nobody**, and it is exempt by derivation rather than
        // by being listed: `migrations.dart` registers it, it runs inside
        // `AppDatabase.open`, and no provider container exists yet to be
        // told — the first read any screen ever makes is of the migrated
        // rows. Task 11.224's fork inserts into `Tags` and `Tag_Versions` and
        // re-points four displayed tables, which is exactly the shape this
        // guard exists to catch everywhere else. Remove the registration and
        // the exemption goes with it.
        if (migrationBodies.containsKey(path)) return;
        final exemption = _exemptions[path];
        // An exemption covers only the writes nobody can resolve. A write that
        // plainly names a displayed table is never exempt, so a file cannot
        // acquire one under cover of an exemption written about something else.
        if (exemption != null && site.named.isEmpty) return;
        final source = stripComments(File(path).readAsStringSync());
        expect(
          _announces(source),
          isTrue,
          reason:
              '$path writes data the screens display and never tells them.'
              '\n\n${site.explain()}\n\n'
              'The symptom is not an error: the write succeeds, the app '
              'reports success, and the record is invisible on the map and in '
              'the log until the app is restarted — which is what was found on '
              'real hardware on 2026-08-27.\n\n'
              'Fix it by calling DataArrival.announce() at the end of the '
              'operation (once per operation, not once per row), or — if this '
              'file is a screen that already holds a ref — '
              'ref.read(recordingsRevisionProvider.notifier).bump().\n\n'
              'If it genuinely must not announce, add it to _exemptions in '
              'this file with the reason, and expect to justify it. An '
              'exemption cannot cover a write that names a displayed table.',
        );
      });
    });

    test('every exemption is still about a file that writes', () {
      for (final path in _exemptions.keys) {
        expect(
          writeSites.keys,
          contains(path),
          reason:
              '$path is exempted here ("${_exemptions[path]}") but no longer '
              'writes to the database at all. Delete the exemption — a stale '
              'one is cover for whatever moves into that file next.',
        );
      }
    });
  });
}

/// What one file's database writes look like to this guard.
class _WriteSite {
  _WriteSite();

  /// Writes that name a table the screens display, or call a repository that
  /// owns one. Never exempt.
  final List<String> named = [];

  /// Writes whose table is decided at run time — `db.insert(table, …)`,
  /// `'UPDATE \$store …'`. Treated as writing everything, because nothing here
  /// can tell what they wrote. Exemptible, with a reason.
  final List<String> dynamic_ = [];

  bool get writesAnything => named.isNotEmpty || dynamic_.isNotEmpty;

  String explain() => [
        if (named.isNotEmpty) 'Writes displayed data: ${named.join('; ')}.',
        if (dynamic_.isNotEmpty)
          'Writes a table chosen at run time, so it may be any of them: '
              '${dynamic_.join('; ')}.',
      ].join(' ');
}

/// Files that write display data and deliberately do not announce.
///
/// Each entry is a claim that has to hold, not a way of getting to green.
const _exemptions = <String, String>{
  'lib/data/repositories/base_repository.dart':
      'It is the write, not an operation. Which table it writes is its '
      'caller\'s choice, and every one of those callers is itself checked '
      'here. Announcing from inside it would also announce once per row, so a '
      'CSV import of two hundred tags would re-run the map\'s whole query two '
      'hundred times.',
  'lib/data/repositories/tag_library_repository.dart':
      'The personal tag library is device-local: it is in neither syncTables '
      'nor tableSpecs, so no push, pull, merge or archive can change it, and '
      'nothing else on this device writes it either. **Every write to it '
      'comes from a screen that already calls refreshTagViews**, which is '
      'what tells the Tag Database screen and every project tag view about '
      'it — announcing again from in here would be a second announcement for '
      'one edit. Task 11.219.',
  'lib/data/sync/row_key_migration.dart':
      'Rewrites stored row keys in this device\'s own sync bookkeeping stores '
      '(Sync_Held_Rows, Sync_Row_Receipts, Sync_Conflicts, Unknown_Columns), '
      'which no screen displays. It runs inside AppDatabase.open, before a '
      'screen or a provider container exists to be told anything.',
};

/// The file that [_tagViewRefreshHelper] names, and which [_announces] treats
/// as an announcement in its own right.
const _tagViewRefreshPath = 'lib/core/providers/tag_view_refresh.dart';

/// **Task 11.151 added a third way to announce, and it is a function call.**
/// `refreshTagViews` invalidates every provider holding a project's tag set
/// and bumps the revision counter, so a screen calling it has announced — but
/// the literal bump now lives one file away, where a `source.contains` on the
/// screen cannot see it.
///
/// **This is the "harness coupled to a string another file implements" trap
/// (CLAUDE.md, task 11.125/11.128), so it is not left to trust:**
/// [_tagViewRefreshAnnounces] re-reads that file and fails if the helper has
/// stopped announcing or been renamed. Without that, gutting the helper would
/// leave three screens silently exempt and this guard still green.
bool _announces(String source) =>
    source.contains('DataArrival.announce()') ||
    source.contains('recordingsRevisionProvider.notifier).bump()') ||
    source.contains('refreshTagViews(') ||
    source.contains('refreshTagViewsIn(');

const _migrationsPath = 'lib/data/db/migrations.dart';

/// The files whose code runs *as* a schema migration — every class named in
/// a `Migration.run(N, Class.method)` entry of [_migrationsPath], resolved to
/// the file under `lib/` that declares that class.
///
/// Derived, not listed, because the fact that justifies the exemption is the
/// registration line: a file registered there runs inside `AppDatabase.open`
/// before any provider exists to announce to. A class that stops being
/// registered stops being exempt without anybody editing this file.
///
/// Keyed by repository-relative path; the value is the registered class.
Map<String, String> _migrationBodyFiles() {
  final registrations = RegExp(r'Migration\.run\(\s*\d+\s*,\s*(\w+)\.\w+')
      .allMatches(stripComments(File(_migrationsPath).readAsStringSync()))
      .map((m) => m.group(1)!)
      .toSet();
  final result = <String, String>{};
  for (final className in registrations) {
    final declaration = RegExp('\\bclass $className\\b');
    for (final file in dartFilesUnder('lib')) {
      if (declaration.hasMatch(stripComments(file.readAsStringSync()))) {
        result[_relative(file.path)] = className;
      }
    }
  }
  return result;
}

String _relative(String path) =>
    path.startsWith('./') ? path.substring(2) : path;

/// `Tables.observations` -> `Observations`, read from the shared constants.
Map<String, String> _tableNameConstants() {
  final source = stripComments(
    File('packages/tritrack_sync/lib/src/schema_constants.dart')
        .readAsStringSync(),
  );
  final start = source.indexOf('abstract final class Tables');
  final block = source.substring(start, source.indexOf('\n}', start));
  final result = <String, String>{};
  for (final m
      in RegExp(r"static const (\w+) = '([\w_]+)';").allMatches(block)) {
    result[m.group(1)!] = m.group(2)!;
  }
  if (result.isEmpty) {
    throw StateError(
      'No table constants parsed out of schema_constants.dart. Its shape '
      'changed; this guard is blind until the parse is updated.',
    );
  }
  return result;
}

/// `ObservationRepository` -> `Observations`, read from each constructor.
Map<String, String> _repositoryTables(Map<String, String> tableNames) {
  final result = <String, String>{};
  for (final file in dartFilesUnder('lib/data/repositories')) {
    final source = stripComments(file.readAsStringSync());
    for (final m in RegExp(r'class (\w+) extends BaseRepository')
        .allMatches(source)) {
      final table = RegExp(r'table: Tables\.(\w+)')
          .firstMatch(source.substring(m.end));
      if (table == null) continue;
      final name = tableNames[table.group(1)!];
      if (name != null) result[m.group(1)!] = name;
    }
  }
  return result;
}

/// `observationRepositoryProvider` -> `ObservationRepository`.
Map<String, String> _repositoryProviders() {
  final source = stripComments(
    File('lib/data/repositories/repository_providers.dart').readAsStringSync(),
  );
  return {
    for (final m
        in RegExp(r'Future<(\w+)> (\w+)\(\s*Ref ref,?\s*\)').allMatches(source))
      '${m.group(2)!}Provider': m.group(1)!,
  };
}

/// The repositories read by providers that watch `recordingsRevisionProvider`.
Set<String> _displayRepositories(
  Map<String, String> providerToRepository,
  Map<String, String> repositoryTables,
) {
  final found = <String>{};
  for (final file in dartFilesUnder('lib')) {
    var source = stripComments(file.readAsStringSync());
    const watch = 'ref.watch(recordingsRevisionProvider)';
    while (source.contains(watch)) {
      final block = enclosingTopLevelDeclaration(source, watch);
      if (block == null) break;
      for (final m in RegExp(r'(\w+RepositoryProvider)').allMatches(block)) {
        final repo = providerToRepository[m.group(1)!];
        if (repo != null && repositoryTables.containsKey(repo)) found.add(repo);
      }
      source = source.replaceFirst(watch, '');
    }
  }
  return found;
}

/// Every repository method that eventually reaches a SQLite write.
///
/// Seeded from the four calls that touch the database directly and closed
/// under "calls something already known to write". A method added to a
/// repository that wraps `updateById` therefore enters this set by itself.
Set<String> _repositoryWriteMethods() {
  final bodies = <String, String>{};
  for (final file in dartFilesUnder('lib/data/repositories')) {
    final source = stripComments(file.readAsStringSync());
    final declarations = RegExp(
      r'\n  (?:static\s+)?(?:Future<[^>]*>|void|int|bool)\s+(\w+)\s*\(',
    ).allMatches(source).toList();
    for (var i = 0; i < declarations.length; i++) {
      final end = i + 1 < declarations.length
          ? declarations[i + 1].start
          : source.length;
      final name = declarations[i].group(1)!;
      bodies[name] =
          (bodies[name] ?? '') + source.substring(declarations[i].end, end);
    }
  }
  final known = <String>{
    'insert',
    'update',
    'delete',
    'rawInsert',
    'rawUpdate',
    'rawDelete',
  };
  var changed = true;
  while (changed) {
    changed = false;
    bodies.forEach((name, body) {
      if (known.contains(name)) return;
      for (final write in known) {
        if (RegExp('\\b$write\\s*\\(').hasMatch(body)) {
          known.add(name);
          changed = true;
          return;
        }
      }
    });
  }
  return known;
}

bool _definesRepositoryClass(String source, Set<String> repositoryClasses) =>
    repositoryClasses.any((c) => source.contains('class $c extends'));

/// Every `static const NAME = 'Literal';` in `lib/`, by both its bare and its
/// class-qualified name, so a write against `UnknownColumnStore.table` can be
/// resolved to the table it really names instead of being treated as unknown.
Map<String, String> _stringConstants() {
  final result = <String, String>{};
  for (final file in dartFilesUnder('lib')) {
    final source = stripComments(file.readAsStringSync());
    String? currentClass;
    for (final line in source.split('\n')) {
      final declaration = RegExp(r'^(?:abstract\s+)?(?:final\s+)?class (\w+)')
          .firstMatch(line);
      if (declaration != null) currentClass = declaration.group(1);
      final constant =
          RegExp(r"\bconst (?:String )?(\w+) = '([\w_]+)';").firstMatch(line);
      if (constant == null) continue;
      result[constant.group(1)!] = constant.group(2)!;
      if (currentClass != null) {
        result['$currentClass.${constant.group(1)!}'] = constant.group(2)!;
      }
    }
  }
  return result;
}

/// The positional first argument of a call starting at [from] (the index of
/// its `(`), or null when the call takes none.
String? _firstArgument(String source, int from) {
  var depth = 0;
  final buffer = StringBuffer();
  for (var i = from; i < source.length && i < from + 4000; i++) {
    final c = source[i];
    if (c == '(' || c == '[' || c == '{') depth++;
    if (c == ')' || c == ']' || c == '}') {
      depth--;
      if (depth == 0) break;
    }
    if (c == ',' && depth == 1) break;
    if (depth >= 1 && !(depth == 1 && i == from)) buffer.write(c);
  }
  final argument = buffer.toString().trim();
  return argument.isEmpty ? null : argument;
}

/// Classifies every database write in one file.
_WriteSite _analyseWrites(
  String source, {
  required Map<String, String> constants,
  required Set<String> displayTables,
  required Set<String> displayRepositories,
  required Map<String, String> providerToRepository,
  required Map<String, String> repositoryTables,
  required Set<String> writeMethods,
}) {
  final site = _WriteSite();
  final allTables = repositoryTables.values.toSet()..addAll(constants.values);

  final variables = _repositoryVariables(source, providerToRepository);
  for (final m in RegExp(
    r'(\w+)[!?]?\.(insert|update|delete|rawInsert|rawUpdate|rawDelete)\s*\(',
  ).allMatches(source)) {
    // A write made *through a repository* is classified by that repository's
    // own table further down, not by whatever object it was handed.
    if (variables.containsKey(m.group(1))) continue;
    final method = m.group(2)!;
    final argument = _firstArgument(source, m.end - 1);
    if (argument == null) continue; // `file.delete()` and friends.
    final isSql = method.startsWith('raw');
    final isTableExpression =
        RegExp(r'^[A-Za-z_]\w*(\.\w+)*$').hasMatch(argument);
    final isStringLiteral = argument.startsWith("'") || argument.startsWith('"');
    if (!isTableExpression && !isStringLiteral) {
      // `_polygon.insert(index + 1, point)` — a list, not a database.
      continue;
    }
    if (isSql && !isStringLiteral) continue;

    if (isSql) {
      final named = <String>{};
      for (final table in allTables) {
        if (RegExp('(?:UPDATE|INSERT INTO|DELETE FROM)\\s+$table\\b')
            .hasMatch(argument)) {
          named.add(table);
        }
      }
      for (final ref in RegExp(r'\$\{?(\w+(?:\.\w+)*)\}?').allMatches(argument)) {
        final resolved = constants[ref.group(1)!];
        if (resolved != null) {
          named.add(resolved);
        } else {
          site.dynamic_.add(
            '$method SQL whose table is `${ref.group(1)}`',
          );
        }
      }
      for (final table in named) {
        if (displayTables.contains(table)) {
          site.named.add('$method into $table');
        }
      }
      continue;
    }

    final constantName = RegExp(r'^Tables\.(\w+)$').firstMatch(argument);
    final resolved = constantName != null
        ? _tableNamesCache[constantName.group(1)!]
        : (isStringLiteral
            ? argument.replaceAll(RegExp("['\"]"), '')
            : constants[argument]);
    if (resolved == null) {
      site.dynamic_.add('$method into `$argument`');
    } else if (displayTables.contains(resolved)) {
      site.named.add('$method into $resolved');
    }
  }

  // Writes made through a repository that owns a displayed table.
  variables.forEach((variable, repositories) {
    for (final repository in repositories) {
      if (!displayRepositories.contains(repository)) continue;
      for (final method in writeMethods) {
        if (RegExp('\\b$variable[!?]?\\.$method\\s*\\(').hasMatch(source)) {
          site.named.add(
            '$repository.$method via `$variable`, which writes '
            '${repositoryTables[repository]}',
          );
        }
      }
    }
  });
  for (final repository in displayRepositories) {
    for (final method in writeMethods) {
      if (RegExp('$repository\\([^;]*?\\)\\.$method\\s*\\(').hasMatch(source)) {
        site.named.add('$repository.$method on a freshly built repository');
      }
    }
  }
  return site;
}

/// Local names in this file that hold a repository, and which ones.
///
/// A name may hold more than one over a file's length — `app_context_provider`
/// calls three different repositories `repo` — so this maps to a set. Keeping
/// only the last would have hidden the `Users` insert behind a later
/// `Projects` read.
Map<String, Set<String>> _repositoryVariables(
  String source,
  Map<String, String> providerToRepository,
) {
  final result = <String, Set<String>>{};
  void record(String variable, String repository) =>
      result.putIfAbsent(variable, () => {}).add(repository);

  for (final m
      in RegExp(r'\b([A-Z]\w*Repository)\s+(\w+)\s*[;=,)]').allMatches(source)) {
    record(m.group(2)!, m.group(1)!);
  }
  for (final statement in source.split(';')) {
    final assignment =
        RegExp(r'\b(?:final|var|late)\s+(\w+)\s*=').firstMatch(statement);
    if (assignment == null) continue;
    final rhs = statement.substring(assignment.end);
    final provider = RegExp(r'(\w+RepositoryProvider)').firstMatch(rhs);
    if (provider != null) {
      final repository = providerToRepository[provider.group(1)!];
      if (repository != null) record(assignment.group(1)!, repository);
      continue;
    }
    final constructed = RegExp(r'\b([A-Z]\w*Repository)\(').firstMatch(rhs);
    if (constructed != null) record(assignment.group(1)!, constructed.group(1)!);
  }
  return result;
}

final _tableNamesCache = _tableNameConstants();
