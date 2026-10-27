import 'package:flutter_test/flutter_test.dart';
import 'package:tritrack/data/db/app_database.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

import 'support/e2e_harness.dart';

/// **How far a test project is from a field project, measured (task 11.118).**
///
/// ## The finding this exists for
///
/// Task 11.43 found that **every publish fixture in this repository published
/// a project with no tag.** That is why the whole end-to-end suite stayed
/// green for a month while every real first publish refused a `Tag_Versions`
/// row and showed the person a red banner saying this "is not a case the app
/// expects" — on the first thing they ever did with a server. 11.43 closed
/// its own instance by adding one case that opted in. Task 11.118 counted the
/// rest: **seventeen of nineteen publish fixtures had no tag, none had a
/// truth point, none had a second member, and seventeen sent a payload whose
/// timestamps spanned zero seconds.**
///
/// > **The instrument was honest and the input was not.** Nothing was wrong
/// > with any assertion in that suite. Every one of them was true of the
/// > project it was given, and the project it was given was one nobody has.
///
/// ## What this file asserts, and what it deliberately does not
///
/// It is a **shape** check on the shared builder, not a count of fixtures.
/// A count of fixtures is the guard `suite_coverage_test.dart` replaced for
/// exactly this reason: a number says nothing about what the files do.
///
/// 1. **[seedLocalProject] produces the ordinary field project by default** —
///    a tag and its `Tag_Versions` row, not just a
///    `Projects` row. This is the one that would have failed for the month
///    11.43 describes. It runs the real builder against a real database
///    rather than reading its source, so a builder that stopped inserting one
///    of the three fails here whatever its signature still says.
/// 2. **Every synced table is either reachable through a publish fixture or
///    named in [_neverPublished] with a reason.** Derived from `syncTables`,
///    so a fourteenth table is red until somebody decides which list it is
///    on. This is the half that makes the gap a statement rather than a
///    silence.
///
/// **Not tagged `e2e`, deliberately** — same reasoning as
/// `suite_coverage_test.dart`. Both questions are answered locally, so
/// tagging this `e2e` would mean the shape of the publish corpus was only
/// ever checked on the runs where a server happened to be up, which is the
/// shape of measuring a control in a configuration that disables it
/// (task 10.54). It runs on every plain `flutter test`.
///
/// ## What this does not close, stated rather than left to be found
///
/// A **deliberately minimal fixture is a fine thing** and this does not
/// forbid one: [seedLocalProject]'s `withTag: false` is a supported opt-out,
/// and a unit test of one rule does not need a season of data. The defect was
/// a *systematically* simple population, not any individual simple case.
///
/// Three gaps task 11.118 measured and did **not** close, so that nobody
/// reads this file as saying the corpus is now realistic:
///
/// - **Time span.** Every row a publish fixture sends still carries one
///   identical instant. The project's 15-minute triangulation window and the
///   server's staleness classifiers therefore see a payload no device
///   produces. A field payload spans hours at least and a season at most.
/// - **Batch boundaries.** `ProjectPublisher` slices at
///   `defaultSyncBatchSize` (500) because "a season of field data" does not
///   fit one request — and no fixture puts 500 rows in any one table, so the
///   inner slice loop has never run more than once per table except in one
///   unit test that passes `batchSize: 2`. The cross-request reachability
///   rule `offer_order.dart` exists for is exercised *between* tables and
///   never *within* one.
/// - **Members.** No publish fixture has ever published a project a co-owner,
///   contributor and viewer already share.
void main() {
  late AppDatabase db;

  setUp(() async {
    db = await AppDatabase.openInMemory();
    // Projects.owner_user_id is a real foreign key; the owner has to exist
    // before the project does, on a device as much as here.
    final stamp = DbCodec.encodeUtc(DateTime.utc(2026, 8, 2, 12));
    await db.raw.insert(Tables.users, {
      'user_id': 'u1',
      'first_name': 'Dana',
      'last_name': 'Okonkwo',
      'email': 'dana@example.invalid',
      'created_at': stamp,
      'updated_at': stamp,
      'revision': 0,
      'last_modified_by': 'u1',
      'origin_device_id': 'd1',
    });
  });
  tearDown(() => db.close());

  Future<int> count(String table) async =>
      (await db.raw.query(table)).length;

  group('the default e2e project fixture is the ordinary field project', () {
    test('it carries a tag, its project link, and its version row', () async {
      await seedLocalProject(
        db.raw,
        projectId: 'p1',
        ownerId: 'u1',
        deviceId: 'd1',
        now: DateTime.utc(2026, 8, 2, 12),
      );

      expect(await count(Tables.projects), 1);
      expect(await count(Tables.projectMemberships), 1);
      expect(
        await count(Tables.tags),
        1,
        reason:
            'a project with no tag is one nobody has started using; making it '
            'the default fixture is what hid task 11.43 for a month',
      );
      // **The `Project_Tags` count that used to be here is gone with the
      // table (task 11.219).** "A tag with no link row is not in the
      // project" was the reason for it; a tag carries its own `project_id`
      // now, so the `Tags` count above already says the tag is in the
      // project and a second row could not disagree with it.
      expect(
        await count(Tables.tagVersions),
        1,
        reason:
            'task 11.32 gives every tag a version the moment it is created, '
            'so a Tags row without one is a state no device is ever in — and '
            'it is the row a first publish used to refuse',
      );
      expect(
        await count(Tables.individuals),
        1,
        reason:
            'task 11.240 names an animal for every tag created in the app, '
            'and the tag\'s foreign key wants it on the server first',
      );
    });

    test('withTag: false is a supported opt-out, not a second default',
        () async {
      await seedLocalProject(
        db.raw,
        projectId: 'p1',
        ownerId: 'u1',
        deviceId: 'd1',
        now: DateTime.utc(2026, 8, 2, 12),
        withTag: false,
      );

      expect(await count(Tables.projects), 1);
      expect(await count(Tables.tags), 0);
      expect(await count(Tables.tagVersions), 0);
      expect(await count(Tables.individuals), 0);
    });
  });

  test(
    'every synced table is either published by a fixture or declared unpublished',
    () {
      final declared = {..._publishedByAFixture, ..._neverPublished.keys};
      final actual = syncTables.map((t) => t.name).toSet();

      expect(
        declared.difference(actual),
        isEmpty,
        reason:
            'a table named in one of these lists no longer exists in '
            'syncTables — the list is stale, not the schema',
      );
      expect(
        actual.difference(declared),
        isEmpty,
        reason:
            'a new synced table has landed and nothing says whether any '
            'publish fixture carries a row of it. Add it to one of the two '
            'lists in this file. That is the whole point: task 11.118 found '
            'six tables that had never been through a publish in any test, '
            'and the reason nobody knew is that nothing asked.',
      );
    },
  );
}

/// Tables some publish fixture actually carries a row of, verified by task
/// 11.118 against `test/e2e/publish_and_join_e2e_test.dart` and the builders
/// in `support/e2e_harness.dart`.
const _publishedByAFixture = <String>{
  Tables.users,
  Tables.projects,
  Tables.projectMemberships,
  // Task 11.240: `seedLocalTag` writes the animal the tag names, so every
  // fixture with a tag publishes one.
  Tables.individuals,
  Tables.tags,
  // Task 11.243: and the dated link between them, written by the same
  // builder — a project whose tag and animal travel but whose *join* does
  // not would publish two lists with nothing connecting them, which is the
  // systematically-simple corpus this file exists to catch.
  Tables.deployments,
  Tables.tagVersions,
  Tables.observations,
  // Added by task 11.118 — the only row in syncTables that is `anyUser`,
  // carries an identity column, and carries a tag reference at once.
  Tables.actualTagLocations,
};

/// Tables no publish fixture carries, each with why — **a statement of what
/// is not covered, which is the opposite of a coverage list.** An entry
/// cannot make anything pass that would otherwise fail.
const _neverPublished = <String, String>{
  Tables.userEmails:
      'Written only by the server when a person signs in with a second '
      'address (task 7.3). A device does not author one before its first '
      'publish, so a fixture carrying one would be modelling a state the '
      'client cannot reach. Deliberately absent.',
  Tables.triangulationSessions:
      'Reachable and untested. A session groups bearings taken on one animal '
      'in one sitting; it is `anyUser` and carries a tag reference, so it '
      'sits under the same ordering constraint the truth point does. Worth a '
      'case; task 11.118 added the truth point instead because that table '
      'also carries an identity column and this one does not.',
  Tables.observationExclusions:
      'Reachable and untested. An exclusion is `authorOrOwner` — the only '
      'table with that rule — so a publish carrying one exercises a branch '
      'no other publish fixture reaches.',
  Tables.nonDetections:
      'Reachable and untested. `author`, like Observations, so a publish '
      'carrying one adds little beyond what a bearing already covers. The '
      'lowest-value of the four.',
  Tables.estimatedPositions:
      'Reachable and untested. `anyUser` with a tag reference and no identity '
      'column — the same shape as Triangulation_Sessions.',
};
