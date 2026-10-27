import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../support/dart_source.dart';

/// **Task 11.245 item 2 — a tag with no animal is the normal starting state
/// (design §1), and no path that creates equipment invents one.**
///
/// ## Why derived rather than read once and trusted
///
/// `CLAUDE.md` on this project's own history: *"Derive the paths from the
/// code; a list of five written here is exactly the shape this project keeps
/// being wrong about."* Task 11.243 already removed `TagRepository.insert`'s
/// `createIndividual` default; this file is what keeps that removal true —
/// every call site that writes a new `Tags` row, and every call site that
/// writes a new `Individuals` row, derived from the source rather than
/// remembered.
///
/// ## The two signals
///
/// - **A new tag row**: `insert` or `copyFromLibrary` called on a
///   `TagRepository` — however the repository was obtained and whatever the
///   argument is called (task 11.322; before it, only `.insert(tag…` was seen,
///   and Quick add's first draft walked past). `createsATag` is the detector.
/// - **A new animal row**: `Individual(` constructed for insertion, or
///   `insert` called on an `IndividualRepository`. The model's own file and
///   the generated `.freezed.dart` are excluded, since neither is a call site.
///
/// ## The one exception, and why it is not a relapse
///
/// `ANIMALS_AND_DEPLOYMENTS_DESIGN.md` §1a: the Record screen's quick-add
/// writes a tag, an animal and a deployment in one transaction, because by
/// the time that dialog is open the person is already about to record a
/// bearing on the collar — an assertion that something is wearing it, already
/// made. **The scope is exactly that one dialog** — Project Setup (now
/// `More → Tags`), the Tag Library, the CSV import and `copyFromLibrary` all
/// still create equipment and nothing else. So the two derived sets may
/// overlap in exactly one file, and nowhere else.
/// **Whether [body] (already comment-stripped) contains a call that creates a
/// `Tags` row** — task 11.322 item 3.
///
/// Until this task the guard matched `.insert(tag` and nothing else, so it saw
/// a tag being created only when the variable happened to be *named* `tag`.
/// Quick add's first draft wrote `.insert(QuickAddPlanner.newTagFor(…))` and
/// walked straight past it (defect vocabulary entry 75: a guard that greps a
/// literal cannot see through a function call). **What identifies the call is
/// the receiver, not the argument:** anything that is a `TagRepository`
/// calling `insert` or `copyFromLibrary`.
///
/// A receiver is a `TagRepository` when it is built inline
/// (`TagRepository(txn).insert(…)`), when a name is bound to one
/// (`final tags = TagRepository(txn)`, `await ref.read(tagRepositoryProvider
/// .future)`), or when a parameter or field is declared with that type.
/// A name reused for a different repository elsewhere in the same file makes
/// the file *listed* when it need not be — which costs one read, and errs the
/// way a guard should.
bool createsATag(String body) {
  if (RegExp(r'\.insert\(\s*tag\b').hasMatch(body)) return true;
  return _callsOn(
    body,
    type: 'TagRepository',
    provider: 'tagRepositoryProvider',
    verbs: 'insert|copyFromLibrary',
  );
}

/// **The same receiver test for animals** — found while widening the tag side.
/// `season_clone.dart` copies every animal of the old season with
/// `individuals.insert(copy)`, which `Individual(` never matched, so the
/// overlap test below was passing for a file it could not see on one of its
/// two sides.
bool createsAnAnimal(String body) {
  if (RegExp(r'[=(,]\s*Individual\(').hasMatch(body)) return true;
  return _callsOn(
    body,
    type: 'IndividualRepository',
    provider: 'individualRepositoryProvider',
    verbs: 'insert',
  );
}

/// Whether [body] calls one of [verbs] on a [type]: built inline, bound to a
/// name (directly or from [provider]), or declared as a parameter or field.
bool _callsOn(
  String body, {
  required String type,
  required String provider,
  required String verbs,
}) {
  if (RegExp(type + r'\([^)]*\)\s*\.(?:' + verbs + r')\(').hasMatch(body)) {
    return true;
  }
  final names = <String>{
    for (final m in RegExp(
      r'\b(\w+)\s*=\s*(?:await\s+)?(?:' +
          type +
          r'\(|ref\.(?:read|watch)\(\s*' +
          '$provider)',
    ).allMatches(body))
      m.group(1)!,
    for (final m in RegExp(r'\b' + type + r'\??\s+(\w+)').allMatches(body))
      m.group(1)!,
  };
  for (final name in names) {
    if (RegExp(r'\b' + name + r'\s*\.\s*(?:' + verbs + r')\(').hasMatch(body)) {
      return true;
    }
  }
  return false;
}

void main() {
  /// Files that insert a brand-new `Tags` row via `TagRepository.insert`.
  List<String> tagCreationSites() {
    final out = <String>[];
    for (final file in dartFilesUnder('lib')) {
      final relative = file.path.substring('lib/'.length);
      if (relative == 'data/repositories/tag_repository.dart') continue;
      final body = stripComments(file.readAsStringSync());
      if (createsATag(body)) out.add(relative);
    }
    return out..sort();
  }

  /// Files that construct a brand-new `Individual` row for insertion.
  List<String> animalCreationSites() {
    final out = <String>[];
    for (final file in dartFilesUnder('lib')) {
      final relative = file.path.substring('lib/'.length);
      if (relative == 'data/models/individual.dart') continue;
      final body = stripComments(file.readAsStringSync());
      if (createsAnAnimal(body)) out.add(relative);
    }
    return out..sort();
  }

  /// **The detector itself, tested on the shapes it must see and the ones it
  /// must not** — task 11.322 item 3. Watched red against the old
  /// `.insert(tag` pattern: the first three cases below failed on it.
  group('createsATag', () {
    test("Quick add's first draft — a function call as the argument", () {
      expect(
        createsATag(
          'final tags = TagRepository(txn);\n'
          'await tags.insert(QuickAddPlanner.newTagFor(row, mhz, defaults));',
        ),
        isTrue,
        reason: 'This is the shape that got past the guard on 2026-09-30.',
      );
    });

    test('built inline, with any argument', () {
      expect(
        createsATag('await TagRepository(txn).insert(made);'),
        isTrue,
      );
      expect(
        createsATag('await TagRepository(db)\n    .insert(build(row));'),
        isTrue,
      );
    });

    test('a repository read from the provider, then used by another name', () {
      expect(
        createsATag(
          'final repo = await ref.read(tagRepositoryProvider.future);\n'
          'await repo.insert(draft.newTag(id));',
        ),
        isTrue,
      );
    });

    test('a library copy creates a tag too', () {
      expect(
        createsATag(
          'final tags = TagRepository(txn);\n'
          'await tags.copyFromLibrary(entry, projectId: p);',
        ),
        isTrue,
      );
    });

    test('a parameter or field declared as a TagRepository', () {
      expect(
        createsATag(
          'Future<void> go(TagRepository repo) async {\n'
          '  await repo.insert(something());\n}',
        ),
        isTrue,
      );
    });

    test('still sees the old shape', () {
      expect(createsATag('await anything.insert(tag);'), isTrue);
    });

    test('animals: a repository insert of a copy is seen, a literal is too', () {
      expect(
        createsAnAnimal(
          'final individuals = IndividualRepository(txn);\n'
          'await individuals.insert(copy);',
        ),
        isTrue,
      );
      expect(createsAnAnimal('x = Individual(name: n)'), isTrue);
      expect(
        createsAnAnimal('final t = TagRepository(txn); await t.insert(x);'),
        isFalse,
      );
    });

    test('does not flag another repository, or a tag only being read', () {
      expect(
        createsATag(
          'final observations = ObservationRepository(txn);\n'
          'await observations.insert(observation);',
        ),
        isFalse,
      );
      expect(
        createsATag(
          'final tags = TagRepository(txn);\n'
          'final found = await tags.findById(id, projectId: p);',
        ),
        isFalse,
      );
    });
  });

  test('a search that finds nothing is not this app', () {
    expect(
      tagCreationSites(),
      isNotEmpty,
      reason: 'No file under lib/ creates a Tags row at all — the scan is '
          'reading the wrong tree, or TagRepository.insert has been renamed.',
    );
    expect(
      animalCreationSites(),
      isNotEmpty,
      reason: 'No file under lib/ creates an Individuals row at all — the '
          'scan is reading the wrong tree, or the construction pattern this '
          'test looks for has changed shape.',
    );
  });

  test('every place a new tag row is written, derived', () {
    expect(
      tagCreationSites(),
      equals([
        'features/observations/screens/observation_logging_screen.dart',
        'features/more/screens/observation_sharing_screen.dart',
        // Task 11.321: an animal's "Link a tag → New tag…" creates the tag
        // inside the link's own transaction. Read 2026-09-30: it invents no
        // animal — the animal is the one whose screen the person is on, and
        // already exists.
        'data/repositories/deployment_linking.dart',
        // Task 11.321: More → Animals → Quick add. Creates tags and animals
        // together — see the overlap test below for why that is allowed.
        'data/repositories/quick_add.dart',
        // Task 11.322, read 2026-09-30 — the four below were invisible to the
        // old `.insert(tag` pattern and are declared here from reading them.
        // None invents an animal.
        //
        // Starting a new season copies the old season's tags AND its animals
        // (`individuals.insert(copy)`). Every animal is one the person already
        // had; no tag makes one. See the overlap test below.
        'data/repositories/season_clone.dart',
        // More → Tag Library: the drag-onto-a-project drop and "save with a
        // project chosen" both call `copyFromLibrary`, which builds a Tags row
        // from a library entry and never an Individual (the last test below).
        'features/more/screens/tag_database_screen.dart',
        // More → Tags → Copy from library: the same `copyFromLibrary`.
        'features/more/screens/tags_screen.dart',
      ]..sort()),
      reason:
          'The set of files that call TagRepository.insert(tag: …) has '
          'changed. A new call site is a new place a tag can be created — '
          'read it and say here whether it invents an animal (it must not, '
          'design §1), then update this list.',
    );
  });

  test('every place a new animal row is written, derived', () {
    expect(
      animalCreationSites(),
      equals([
        'features/more/screens/animals_screen.dart',
        'features/observations/screens/observation_logging_screen.dart',
        // Task 11.321's Quick add: every animal is one the person named in
        // the table — user-directed, not a side effect of a tag.
        'data/repositories/quick_add.dart',
        // Task 11.322: found once the animal side looked at receivers rather
        // than at the literal `Individual(`. Season clone copies animals that
        // already exist in the old season.
        'data/repositories/season_clone.dart',
      ]..sort()),
      reason:
          'The set of files that construct Individual(...) for insertion has '
          'changed. A new call site is a new place an animal can be created — '
          'read it and say here whether it is user-directed (fine) or a side '
          'effect of something else, like a tag being created (design §1 '
          'forbids it, except the one exception this file names).',
    );
  });

  test('tag creation and animal creation overlap only in the declared '
      'places', () {
    final overlap = tagCreationSites().toSet().intersection(
          animalCreationSites().toSet(),
        );
    expect(
      overlap,
      equals({
        'features/observations/screens/observation_logging_screen.dart',
        // Task 11.321, read 2026-09-30: Quick add is the same shape as the
        // Record screen's quick-add, for many rows. The person types each
        // animal's name and its frequency; `QuickAddCommit.commit` writes
        // the animal, the tag and the link in one transaction, and only
        // after the person confirms a preview naming every row. No tag
        // invents an animal: a row with no name is refused.
        'data/repositories/quick_add.dart',
        // Task 11.322, read 2026-09-30. Starting a new season copies the old
        // season's animals and its tags in one transaction
        // (`SeasonClone.clone`), the person having chosen the project to
        // copy. Neither is invented: each tag and each animal is a copy of one
        // that already existed, and the links come across only where both
        // ends did. This overlap was always real; the animal side could not
        // see it until it looked at `individuals.insert(copy)`.
        'data/repositories/season_clone.dart',
      }),
      reason:
          'A file that both creates a tag and creates an animal is a '
          'candidate for the defect design §1 forbids: equipment that '
          'invents its own study subject. The one allowed exception is the '
          'Record screen\'s quick-add (design §1a) — if this set contains '
          'anything else, open it and check whether the two writes are '
          'really one transaction responding to one person\'s deliberate '
          'act, the way the quick-add is. If this set is missing the quick-'
          'add, either the exception was removed (update this test) or the '
          'two writes were pulled apart (update the design note too).',
    );
  });

  /// **`copyFromLibrary`'s own body is checked separately** — the call sites
  /// above are where a tag gets created; this is the one place that builds
  /// the row itself, from a `TagLibraryEntry`. CSV import lands in the tag
  /// *library*
  /// (`TagLibraryRepository`), never a project, so it is out of scope for
  /// this rule entirely (`tag_csv_import.dart`'s own doc comment: "a
  /// spreadsheet lands in the tag library").
  test('copyFromLibrary never constructs an Individual', () {
    final source = stripComments(
      File('lib/data/repositories/tag_repository.dart').readAsStringSync(),
    );
    expect(
      RegExp(r'[=(,]\s*Individual\(').hasMatch(source),
      isFalse,
      reason: 'tag_repository.dart now constructs an Individual somewhere — '
          'find where and check whether it is inside copyFromLibrary or '
          'insert, both of which design §1 requires to create equipment '
          'only.',
    );
  });
}
