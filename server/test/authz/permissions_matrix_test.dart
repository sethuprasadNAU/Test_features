@Tags(['postgres'])
library;

import 'dart:io';

import 'package:postgres/postgres.dart';
import 'package:test/test.dart';
import 'package:tritrack_server/tritrack_server.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

import '../support/database_test_config.dart';

/// **Task 11.25 — `CLAUDE_DOCS/PERMISSIONS_MATRIX.md` as a rendering of a
/// passing test suite, rather than a document maintained by hand.**
///
/// This file does not re-derive every one of the matrix's ~40 named
/// operations from scratch — most already have a dedicated test, cited by the
/// matrix itself, in `authorization_test.dart`, `member_authorization_test.dart`
/// and the app-side repository tests (`mutation_authorization_test.dart`,
/// `role_gradient_test.dart`, `observation_exclusion_repository_test.dart`).
/// Re-testing those here would be a second copy to drift, not a fix. What was
/// genuinely missing, and what this file exists to close, is three things the
/// matrix's own §3.1, §4.0 and §8 named by number:
///
/// 1. **A structural guard that the matrix's table coverage is derived from
///    the code, in both directions, rather than a list somebody maintains.**
///    Exactly the shape task 11.24 built for the row-naming sweep
///    (`authorization_test.dart`, "the affected set is derived from the rule,
///    not listed") — one layer up: every table [tableMutationRules] declares
///    must have a case in [_crossCuttingFixtures], and every case there must
///    name a real table. See the "structural completeness" group.
/// 2. **Section 4.0's cross-cutting rule, asserted once per table.** "The
///    column recording who last touched a row must always name the caller"
///    (`RowAuthorizer._authorizeNaming`'s `auditUserColumn` branch, task
///    11.24) is a property of every row of every table, not a cell in a
///    grid. Before this file the only table with a named test for it was
///    `Observation_Exclusions`, on one path (withdrawal). See the
///    "cross-cutting rule 4.0.1" group.
/// 3. **The shared tables' cross-author direction.** Task 11.23 found
///    `Triangulation_Sessions`, `Estimated_Positions` and
///    `Actual_Tag_Locations` have no author column, so a contributor may
///    alter or delete a colleague's row — deliberate, per Security Model
///    §4.21, and untested before this file except for `Observations`'
///    supersede path. See the "shared tables" group. **Task 11.254 made that
///    group derive its tables from [tableMutationRules]** after the three-name
///    list went stale (`Individuals` and `Deployments` arrived under the same
///    rule five weeks later, unlisted); the two anyUser tables a contributor
///    may *not* alter — `Tags` and `Tag_Versions`, held by
///    `RowAuthorizer._authorizeTagLifecycle` — are read out of that method's
///    source rather than named here, so the exception cannot outlive its
///    reason.
///
/// Both structural guards below take their "declared"/"covered" sets as
/// parameters, for the same reason `assertEveryGlobalTableDeclaresItsScope`
/// does (`sync_tables.dart`): a check that has never been made to fail is not
/// known to work. The `'the guard fires on ...'` tests call the real
/// assertion helper with a deliberately corrupted input and watch it throw —
/// a permanent, re-runnable proof rather than a one-off manual step.
void main() {
  late Connection connection;
  const testSchema = 'tritrack_permissions_matrix_test';

  const alice = 'user-alice'; // owner of projectA
  const bob = 'user-bob'; // contributor on projectA
  const projectA = 'proj-a';
  const at = '2026-08-01T12:00:00.000Z';

  setUpAll(() async {
    if (testDatabaseConfig == null) return;
    connection = await Connection.open(
      testDatabaseConfig!.endpoint,
      settings: const ConnectionSettings(sslMode: SslMode.disable),
    );
  });

  tearDownAll(() async {
    if (testDatabaseConfig == null) return;
    await connection.execute('DROP SCHEMA IF EXISTS $testSchema CASCADE');
    await connection.close();
  });

  setUp(() async {
    if (testDatabaseConfig == null) return;
    await connection.execute('DROP SCHEMA IF EXISTS $testSchema CASCADE');
    await connection.execute('CREATE SCHEMA $testSchema');
    await connection.execute('SET search_path TO $testSchema');
    await PostgresMigrations.run(connection);
    await connection.runTx((tx) async {
      for (final (id, email) in [
        (alice, 'alice@example.com'),
        (bob, 'bob@example.com'),
      ]) {
        await tx.execute(
          'INSERT INTO ${quoted(Tables.users)} '
          '(user_id, first_name, last_name, email, created_at, updated_at, '
          'revision) '
          r'VALUES ($1, $2, $3, $4, $5, $5, 0)',
          parameters: [id, id, 'Ranger', email, at],
        );
        await tx.execute(
          r'INSERT INTO auth_accounts (user_id, email, created_at) '
          r'VALUES ($1, $2, $3)',
          parameters: [id, email, at],
        );
      }
      await tx.execute(
        'INSERT INTO ${quoted(Tables.projects)} '
        '(project_id, project_name, owner_user_id, creation_date, datum, '
        'created_at, updated_at, revision, coordinate_format, '
        'triangulation_window_minutes) '
        r"VALUES ($1, 'Field', $2, $3, 'WGS84', $3, $3, 0, 'dd', 15)",
        parameters: [projectA, alice, at],
      );
      await tx.execute(
        'INSERT INTO ${quoted(Tables.projectMemberships)} '
        '(membership_id, project_id, user_id, role, join_date, created_at, '
        'updated_at, revision) '
        r'VALUES ($1, $2, $3, $4, $5, $5, $5, 0)',
        parameters: ['mem-$projectA-$bob', projectA, bob, 'contributor', at],
      );
      // A tag in projectA — the FK fixture every tag-referencing table below
      // needs. Inserted directly rather than pushed: it is scaffolding for
      // these tests, not itself under test.
      //
      // **Task 11.219: this used to be two inserts and a link row.** A tag was
      // global and a `Project_Tags` row made it readable inside a project, so
      // the fixture was "a tag, plus the link that reaches it", and a *second*
      // tag was seeded unlinked so that the `Project_Tags` cross-cutting case
      // had something to link. A tag belongs to one project now: `project_id`
      // on the row is the whole of what makes it reachable, `Project_Tags` is
      // gone from the schema, and the spare tag had no other purpose.
      await tx.execute(
        'INSERT INTO ${quoted(Tables.tags)} '
        '(tag_id, project_id, lineage_id, frequency_mhz, tag_name, '
        'status, color_hex, created_at, updated_at, revision, '
        'last_modified_by) '
        r"VALUES ('tag-1', $1, 'tag-1', 150.1, 'Collar', 'active', "
        r"'#FF0000', $2, $2, 1, $3)",
        parameters: [projectA, at, alice],
      );
      // **Task 11.243: an animal for the `Deployments` fixture to name.**
      // Its id is deliberately *not* `ind-cc` — that is the `Individuals`
      // cross-cutting fixture's own row, and seeding it here would turn that
      // fixture's insert into an update and quietly disarm its positive
      // control.
      await tx.execute(
        'INSERT INTO ${quoted(Tables.individuals)} '
        '(individual_id, project_id, name, color_hex, status, lineage_id, '
        'created_at, updated_at, revision, last_modified_by) '
        r"VALUES ('ind-1', $1, 'Marie', '#FF0000', 'alive', 'ind-1', "
        r'$2, $2, 1, $3)',
        parameters: [projectA, at, alice],
      );
    });
  });

  Future<PushResult> pushAs(String userId, {required SyncRows rows}) =>
      connection.runTx((tx) async {
        final access = await ProjectAuthorizer.resolve(
          tx,
          projectId: projectA,
          userId: userId,
        );
        return SyncService(session: tx).applyPush(
          projectId: projectA,
          rows: rows,
          authorizer: RowAuthorizer(
            session: tx,
            projectId: projectA,
            userId: userId,
            access: access,
          ),
        );
      });

  SyncRowOutcome? outcomeFor(PushResult result, String table, String id) {
    final exact = result.outcomes['$table/$id'];
    if (exact != null) return exact;
    final matches = result.outcomes.keys
        .where((key) => key.startsWith('$table/$id/'))
        .toList();
    if (matches.isEmpty) return null;
    if (matches.length > 1) {
      throw StateError('ambiguous outcome for $table/$id: $matches');
    }
    return result.outcomes[matches.single];
  }

  group(
    'structural completeness — the matrix enumerates every table the '
    'code declares',
    skip: databaseSkipReason,
    () {
      test('every table in tableMutationRules has a cross-cutting case, and '
          'vice versa', () {
        _assertSetsMatch(
          declared: tableMutationRules.keys.toSet(),
          covered: _crossCuttingFixtures.keys.toSet(),
          declaredLabel: 'tableMutationRules',
          coveredLabel: '_crossCuttingFixtures',
        );
      });

      test('every table in tableMutationRules has a mutation rule declared '
          '(assertEveryTableHasAMutationRule)', () {
        // The guard this file's own completeness check leans on: if the code
        // ever adds a table with no rule, this fails before anything else in
        // this file has a chance to measure it against a rule that doesn't
        // exist.
        expect(assertEveryTableHasAMutationRule, returnsNormally);
      });

      test('the guard fires on a table with no case — demonstrated, not '
          'assumed', () {
        expect(
          () => _assertSetsMatch(
            declared: {...tableMutationRules.keys, 'Fake_Table'},
            covered: _crossCuttingFixtures.keys.toSet(),
            declaredLabel: 'tableMutationRules',
            coveredLabel: '_crossCuttingFixtures',
          ),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              contains('Fake_Table'),
            ),
          ),
          reason:
              'a guard nobody has watched fail is not known to work — this '
              'proves the comparison actually fires, and names the table',
        );
      });

      test('the guard fires on a case with no declared table', () {
        expect(
          () => _assertSetsMatch(
            declared: tableMutationRules.keys.toSet(),
            covered: {..._crossCuttingFixtures.keys, 'Stale_Table'},
            declaredLabel: 'tableMutationRules',
            coveredLabel: '_crossCuttingFixtures',
          ),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              contains('Stale_Table'),
            ),
          ),
        );
      });
    },
  );

  group(
    'cross-cutting rule 4.0.1 — last_modified_by must always name the '
    'caller, asserted once per table',
    skip: databaseSkipReason,
    () {
      for (final table in _crossCuttingFixtures.keys) {
        final fixture = _crossCuttingFixtures[table]!;

        test(
          '$table: an honest update names the caller and is accepted',
          () async {
            final insertResult = await pushAs(
              alice,
              rows: {
                table: [fixture.insert],
              },
            );
            expect(
              outcomeFor(insertResult, table, fixture.id),
              fixture.insertOutcome,
              reason:
                  'positive control: if the insert itself is refused, a '
                  'refusal of the update below would measure nothing',
            );

            final honestResult = await pushAs(
              alice,
              rows: {
                table: [fixture.honestUpdate],
              },
            );
            expect(
              outcomeFor(honestResult, table, fixture.id),
              SyncRowOutcome.updated,
              reason:
                  'positive control: the same actor, honestly attributed, '
                  'must still be able to change this row',
            );
          },
        );

        test(
          '$table: an update leaving a colleague\'s name in last_modified_by '
          'is refused',
          () async {
            await pushAs(
              alice,
              rows: {
                table: [fixture.insert],
              },
            );
            final result = await pushAs(
              alice,
              rows: {
                table: [fixture.corruptedUpdate],
              },
            );
            expect(
              outcomeFor(result, table, fixture.id),
              SyncRowOutcome.unauthorized,
              reason:
                  '$table is one of every synced table\'s userColumns — '
                  'auditUserColumn — so an update whose last_modified_by '
                  'does not name the caller must be refused here exactly as '
                  'it is on Observation_Exclusions\' withdrawal path '
                  '(task 11.24)',
            );
          },
        );
      }
    },
  );

  group(
    'shared tables — the cross-author direction is deliberate (§4.21) and '
    'is now tested, over every anyUser table the rule table declares',
    skip: databaseSkipReason,
    () {
      // **Derived, not listed (task 11.254).** Task 11.25 wrote this group as
      // three hand-written fixtures — `Triangulation_Sessions`,
      // `Estimated_Positions`, `Actual_Tag_Locations` — and it was wrong
      // within five weeks: `Individuals` (task 11.240) and `Deployments`
      // (task 11.243) arrived under the identical rule and nobody widened it.
      // Task 11.246 found the gap while writing `PERMISSIONS_MATRIX.md` §4.7.
      //
      // The population is now every table `tableMutationRules` governs by
      // [MutationRule.anyUser], and each one's rows come from its own
      // `_crossCuttingFixtures` entry — which the "structural completeness"
      // group already forces to exist for every declared table. A sixth
      // anyUser table gets this test by declaring its rule, and nobody has
      // to remember.
      final shared = [
        for (final entry in tableMutationRules.entries)
          if (entry.value == MutationRule.anyUser) entry.key,
      ];

      // **The one exception, written as a coupling rather than a list.**
      // `Tags` and `Tag_Versions` are anyUser in the rule table and are
      // *not* alterable by a contributor: `RowAuthorizer._authorizeTagLifecycle`
      // holds any change to a stored row of either — rename, retune, retire,
      // tombstone — to the owner rung (`DenialReason.changeTagRequiresOwner`,
      // tasks 11.11 / 11.24 / 11.219). Naming those two tables here by hand
      // would be a second copy of that method's guard, free to drift. So the
      // set is read out of the method's own source: a table is expected to
      // refuse a contributor **only because that method names it**, and if
      // the method stops naming one, or starts naming a third, this group
      // changes its expectation in the same commit — or goes red explaining
      // why. Same shape as task 11.183's `_requireOwner` coupling.
      final ownerOnlyToChange = _tablesNamedByTagLifecycle();

      // **A second, narrower exception, task 11.255.** `Individuals` is
      // `anyUser` and a contributor may alter a colleague's row — editing an
      // animal carries no owner-only rung (§4.7 IN2). But
      // `RowAuthorizer._authorizeIndividualLifecycle` holds one write, and
      // one only, to the owner rung: tombstoning a live row. So this table's
      // *alter* case belongs with the ordinary `anyUser` tables and its
      // *remove* case belongs with `ownerOnlyToChange` — the loop below asks
      // the two questions separately rather than assuming one table has one
      // answer, which is what `ownerOnlyToChange` alone could not express.
      final ownerOnlyToDelete = _tablesNamedByIndividualLifecycle();

      test(
        'the population is derived from the rule table and is not empty',
        () {
          // A derivation that finds nothing and a subject that contains nothing
          // are indistinguishable from the inside; refuse the first.
          expect(shared, isNotEmpty, reason: 'no anyUser table declared?');
          expect(
            ownerOnlyToChange,
            isNotEmpty,
            reason:
                '_authorizeTagLifecycle names no table — either the method was '
                'renamed or its guard changed shape; fix '
                '_tablesNamedByTagLifecycle rather than hand-listing tables',
          );
          expect(
            ownerOnlyToDelete,
            isNotEmpty,
            reason:
                '_authorizeIndividualLifecycle names no table — either the '
                'method was renamed or its guard changed shape; fix '
                '_tablesNamedByIndividualLifecycle rather than hand-listing '
                'tables',
          );
          expect(
            shared,
            containsAll(ownerOnlyToChange),
            reason:
                'a table the tag lifecycle holds to the owner rung must be an '
                'anyUser table, or the exception here has no rule to except '
                'from',
          );
          expect(
            shared,
            containsAll(ownerOnlyToDelete),
            reason:
                'a table the individual lifecycle holds a delete to the '
                'owner rung must be an anyUser table too',
          );
        },
      );

      for (final table in shared) {
        final fixture = _crossCuttingFixtures[table]!;
        final changeRefused = ownerOnlyToChange.contains(table);
        // A table the tag lifecycle already holds owner-only for every
        // change is owner-only for a tombstone too — its refusal covers
        // both, and the individual lifecycle names no table it would
        // duplicate (the two sets are disjoint by construction: task 11.255
        // narrowed a write the tag lifecycle never touched).
        final deleteRefused =
            changeRefused || ownerOnlyToDelete.contains(table);
        final expectedAlter = changeRefused
            ? SyncRowOutcome.unauthorized
            : SyncRowOutcome.updated;
        final expectedRemove = deleteRefused
            ? SyncRowOutcome.unauthorized
            : SyncRowOutcome.updated;
        final later = '2026-08-02T12:00:00.000Z';
        final revision = fixture.honestUpdate['revision']! as int;

        Map<String, Object?> asBob({required bool remove}) => {
          ...fixture.honestUpdate,
          'updated_at': later,
          'deleted_at': remove ? later : null,
          'revision': remove ? revision + 1 : revision,
          'last_modified_by': _bob,
          'origin_device_id': 'device-B',
        };

        final label = changeRefused
            ? 'may NOT alter or remove'
            : deleteRefused
                ? 'may alter but may NOT remove'
                : 'may alter and remove';

        test("$table: a contributor $label a colleague's row", () async {
          final inserted = await pushAs(
            alice,
            rows: {
              table: [fixture.insert],
            },
          );
          expect(
            outcomeFor(inserted, table, fixture.id),
            fixture.insertOutcome,
            reason:
                'positive control: if the owner\'s own insert is refused, '
                'the outcome below measures nothing',
          );

          final altered = await pushAs(
            bob,
            rows: {
              table: [asBob(remove: false)],
            },
          );
          expect(
            outcomeFor(altered, table, fixture.id),
            expectedAlter,
            reason: changeRefused
                ? '$table is anyUser in the rule table but '
                      'RowAuthorizer._authorizeTagLifecycle holds any change '
                      'to a stored row to the owner rung '
                      '(changeTagRequiresOwner) — a contributor altering a '
                      'colleague\'s row must be refused'
                : '$table has no author column (MutationRule.anyUser) — '
                      'task 11.23 found this deliberate for shared project '
                      'vocabulary, and a contributor may alter a '
                      'colleague\'s row',
          );

          final removed = await pushAs(
            bob,
            rows: {
              table: [asBob(remove: true)],
            },
          );
          expect(
            outcomeFor(removed, table, fixture.id),
            expectedRemove,
            reason: changeRefused
                ? 'a tombstone is a change to a stored $table row, and the '
                      'same lifecycle rung refuses it — this is the T3 '
                      '(remove a tag from a project) route, owner-only on the '
                      'server since task 11.24'
                : deleteRefused
                    ? 'a tombstone is the one write '
                          'RowAuthorizer._authorizeIndividualLifecycle holds '
                          'to the owner rung (deleteIndividualRequiresOwner) '
                          '— deleting an animal is an owner\'s decision '
                          '(task 11.255), whatever the ordinary alter case '
                          'above just showed'
                    : 'a soft-delete is an ordinary update to deleted_at, '
                          'and the same absence of an author column permits '
                          'it too',
          );
        });
      }
    },
  );
}

/// One table's insert/honest-update/corrupted-update triple for the
/// cross-cutting `last_modified_by` sweep. [id] is the row's primary key
/// value, for reading back the outcome.
class _CrossCuttingFixture {
  const _CrossCuttingFixture({
    required this.id,
    required this.insert,
    required this.honestUpdate,
    required this.corruptedUpdate,
    this.insertOutcome = SyncRowOutcome.inserted,
  });

  final String id;
  final Map<String, Object?> insert;
  final Map<String, Object?> honestUpdate;
  final Map<String, Object?> corruptedUpdate;

  /// The outcome the first push (`insert`) should produce. [Projects] is the
  /// one exception: `projectA` is seeded directly by `setUp` (every other
  /// table in this push is scoped to it, so a second project cannot share
  /// this file's `pushAs` helper), so `insert` here is really the row's
  /// first revision bump over that seed, not a genuine insert.
  final SyncRowOutcome insertOutcome;
}

/// One fixture per table in [tableMutationRules] — every synced table,
/// because `auditUserColumn` (`last_modified_by`) is in every table's
/// `SyncTable.userColumns` regardless of which [MutationRule] governs it.
///
/// **Keyed by table so a table with no entry fails the "structural
/// completeness" group above, by name**, the same shape task 11.24 used for
/// the row-naming sweep. `alice` (`user-alice`) is the caller and the row's
/// own author/owner throughout, changing only in `last_modified_by`, so every
/// denial below is attributable to the audit column and nothing else —
/// `bob`'s identity never appears anywhere but that one column.
const String _alice = 'user-alice';
const String _bob = 'user-bob';
const String _projectA = 'proj-a';
const String _at = '2026-08-01T12:00:00.000Z';

final Map<String, _CrossCuttingFixture> _crossCuttingFixtures = {
  // Governed by MutationRule.author (governingColumn: user_id). Updating the
  // seeded user's own row rather than inserting a fresh one, because the
  // rule requires user_id == the pusher.
  Tables.users: _CrossCuttingFixture(
    id: _alice,
    insertOutcome: SyncRowOutcome.updated,
    insert: {
      'user_id': _alice,
      'first_name': 'Alicia',
      'last_name': 'Ranger',
      'email': 'alice@example.com',
      'created_at': _at,
      'updated_at': '2026-08-02T12:00:00.000Z',
      'revision': 1,
      'last_modified_by': _alice,
      'origin_device_id': 'device-A',
    },
    honestUpdate: {
      'user_id': _alice,
      'first_name': 'Alicia',
      'last_name': 'Field',
      'email': 'alice@example.com',
      'created_at': _at,
      'updated_at': '2026-08-03T12:00:00.000Z',
      'revision': 2,
      'last_modified_by': _alice,
      'origin_device_id': 'device-A',
    },
    corruptedUpdate: {
      'user_id': _alice,
      'first_name': 'Alicia',
      'last_name': 'Corrupted',
      'email': 'alice@example.com',
      'created_at': _at,
      'updated_at': '2026-08-04T12:00:00.000Z',
      'revision': 3,
      'last_modified_by': _bob,
      'origin_device_id': 'device-A',
    },
  ),

  // Governed by MutationRule.author. A fresh row, since User_Emails is
  // keyed by its own surrogate id — the identity column is `user_id`.
  Tables.userEmails: _CrossCuttingFixture(
    id: 'ue-cc',
    insert: {
      'user_email_id': 'ue-cc',
      'user_id': _alice,
      'email': 'alice@example.com',
      'is_current': 1,
      'recorded_at': _at,
      'created_at': _at,
      'updated_at': _at,
      'revision': 1,
      'last_modified_by': _alice,
      'origin_device_id': 'device-A',
    },
    honestUpdate: {
      'user_email_id': 'ue-cc',
      'user_id': _alice,
      'email': 'alice@example.com',
      'is_current': 0,
      'recorded_at': _at,
      'created_at': _at,
      'updated_at': '2026-08-02T12:00:00.000Z',
      'revision': 2,
      'last_modified_by': _alice,
      'origin_device_id': 'device-A',
    },
    corruptedUpdate: {
      'user_email_id': 'ue-cc',
      'user_id': _alice,
      'email': 'alice@example.com',
      'is_current': 1,
      'recorded_at': _at,
      'created_at': _at,
      'updated_at': '2026-08-03T12:00:00.000Z',
      'revision': 3,
      'last_modified_by': _bob,
      'origin_device_id': 'device-A',
    },
  ),

  // Governed by MutationRule.owner. Updates the seeded project row directly
  // — the identity column is owner_user_id, unchanged throughout.
  Tables.projects: _CrossCuttingFixture(
    id: _projectA,
    insertOutcome: SyncRowOutcome.updated,
    insert: {
      'project_id': _projectA,
      'project_name': 'Field',
      'owner_user_id': _alice,
      'creation_date': _at,
      'datum': 'WGS84',
      'created_at': _at,
      'updated_at': '2026-08-02T12:00:00.000Z',
      'revision': 1,
      'last_modified_by': _alice,
      'origin_device_id': 'device-A',
      'coordinate_format': 'dd',
      'triangulation_window_minutes': 15,
    },
    honestUpdate: {
      'project_id': _projectA,
      'project_name': 'Field Season Two',
      'owner_user_id': _alice,
      'creation_date': _at,
      'datum': 'WGS84',
      'created_at': _at,
      'updated_at': '2026-08-03T12:00:00.000Z',
      'revision': 2,
      'last_modified_by': _alice,
      'origin_device_id': 'device-A',
      'coordinate_format': 'dd',
      'triangulation_window_minutes': 15,
    },
    corruptedUpdate: {
      'project_id': _projectA,
      'project_name': 'Field Season Three',
      'owner_user_id': _alice,
      'creation_date': _at,
      'datum': 'WGS84',
      'created_at': _at,
      'updated_at': '2026-08-04T12:00:00.000Z',
      'revision': 3,
      'last_modified_by': _bob,
      'origin_device_id': 'device-A',
      'coordinate_format': 'dd',
      'triangulation_window_minutes': 15,
    },
  ),

  // Governed by MutationRule.projectOwner. `insert` names alice as the
  // subject too, mirroring "an owner may still record their own
  // membership" in authorization_test.dart.
  Tables.projectMemberships: _CrossCuttingFixture(
    id: 'mem-cc',
    insert: {
      'membership_id': 'mem-cc',
      'project_id': _projectA,
      'user_id': _alice,
      'role': 'owner',
      'join_date': _at,
      'end_date': null,
      'created_at': _at,
      'updated_at': _at,
      'revision': 1,
      'last_modified_by': _alice,
      'origin_device_id': 'device-A',
    },
    honestUpdate: {
      'membership_id': 'mem-cc',
      'project_id': _projectA,
      'user_id': _alice,
      'role': 'owner',
      'join_date': _at,
      'end_date': null,
      'created_at': _at,
      'updated_at': '2026-08-02T12:00:00.000Z',
      'revision': 2,
      'last_modified_by': _alice,
      'origin_device_id': 'device-A',
    },
    corruptedUpdate: {
      'membership_id': 'mem-cc',
      'project_id': _projectA,
      'user_id': _alice,
      'role': 'owner',
      'join_date': _at,
      'end_date': null,
      'created_at': _at,
      'updated_at': '2026-08-03T12:00:00.000Z',
      'revision': 3,
      'last_modified_by': _bob,
      'origin_device_id': 'device-A',
    },
  ),

  // Governed by MutationRule.anyUser — a fresh tag of projectA's own.
  //
  // **Task 11.219 changed what stands in front of this fixture, and the note
  // is worth keeping because the old one named a mechanism that is gone.** It
  // used to be a deliberately *unlinked* (orphan) global tag, and
  // `_authorizeTagReferences`'s orphan branch read `last_modified_by` as the
  // sole authority (Security Model §5.9(a)). That branch and that whole
  // method were deleted: a tag is project-scoped, so the ordinary project
  // scope check answers reachability. What now runs in front of every row
  // here is `RowAuthorizer._authorizeTagLifecycle` — a viewer may not create
  // a tag, and only an owner may change one — and **alice is projectA's
  // owner**, so all three pushes below clear it and rule 4.0.1 is still what
  // decides them. The corrupted update is refused by the naming check, as it
  // always was.
  Tables.tags: _CrossCuttingFixture(
    id: 'tag-cc',
    insert: {
      'tag_id': 'tag-cc',
      'project_id': _projectA,
      'lineage_id': 'tag-cc',
      'frequency_mhz': 151.2,
      'tag_name': 'Spare Collar',
      'status': 'active',
      'color_hex': '#00FF00',
      'created_at': _at,
      'updated_at': _at,
      'revision': 1,
      'last_modified_by': _alice,
      'origin_device_id': 'device-A',
    },
    honestUpdate: {
      'tag_id': 'tag-cc',
      'project_id': _projectA,
      'lineage_id': 'tag-cc',
      'frequency_mhz': 151.205,
      'tag_name': 'Spare Collar',
      'status': 'active',
      'color_hex': '#00FF00',
      'created_at': _at,
      'updated_at': '2026-08-02T12:00:00.000Z',
      'revision': 2,
      'last_modified_by': _alice,
      'origin_device_id': 'device-A',
    },
    corruptedUpdate: {
      'tag_id': 'tag-cc',
      'project_id': _projectA,
      'lineage_id': 'tag-cc',
      'frequency_mhz': 151.21,
      'tag_name': 'Spare Collar',
      'status': 'active',
      'color_hex': '#00FF00',
      'created_at': _at,
      'updated_at': '2026-08-03T12:00:00.000Z',
      'revision': 3,
      'last_modified_by': _bob,
      'origin_device_id': 'device-A',
    },
  ),

  // Governed by MutationRule.anyUser. References the 'tag-1' fixture, which
  // is in projectA, so it is reachable by the ordinary project scope check
  // (task 11.219 — it used to need a `Project_Tags` link, or to be
  // established in the same push).
  // Task 11.240: the animal. Project-scoped and `anyUser`, like the tag that
  // names it, so rule 4.0.1 is asked of it the same way — and its own
  // `last_modified_by` is the only person column it has.
  Tables.individuals: _CrossCuttingFixture(
    id: 'ind-cc',
    insert: {
      'individual_id': 'ind-cc',
      'project_id': _projectA,
      'name': 'Marie',
      'color_hex': '#FF0000',
      'status': 'alive',
      'species': null,
      'sex': null,
      'notes': null,
      'lineage_id': 'ind-cc',
      'copied_at': null,
      'created_at': _at,
      'updated_at': _at,
      'revision': 1,
      'last_modified_by': _alice,
      'origin_device_id': 'device-A',
    },
    honestUpdate: {
      'individual_id': 'ind-cc',
      'project_id': _projectA,
      'name': 'Marie',
      'color_hex': '#00FF00',
      'status': 'alive',
      'species': null,
      'sex': null,
      'notes': null,
      'lineage_id': 'ind-cc',
      'copied_at': null,
      'created_at': _at,
      'updated_at': '2026-08-02T12:00:00.000Z',
      'revision': 2,
      'last_modified_by': _alice,
      'origin_device_id': 'device-A',
    },
    corruptedUpdate: {
      'individual_id': 'ind-cc',
      'project_id': _projectA,
      'name': 'Marie',
      'color_hex': '#0000FF',
      'status': 'alive',
      'species': null,
      'sex': null,
      'notes': null,
      'lineage_id': 'ind-cc',
      'copied_at': null,
      'created_at': _at,
      'updated_at': '2026-08-03T12:00:00.000Z',
      'revision': 3,
      'last_modified_by': _bob,
      'origin_device_id': 'device-A',
    },
  ),

  // Task 11.243: the dated link. Project-scoped and `anyUser` like the two
  // rows it joins, so rule 4.0.1 is asked of it the same way, and
  // `last_modified_by` is its only person column. Both ends name rows the
  // `setUp` above seeds — `tag-1` and `ind-1` — so the reference check is
  // satisfied by the ordinary project scope. **Not `ind-cc`**: that is the
  // `Individuals` fixture's own row and it does not exist when this one is
  // pushed, which reads as `unauthorized` (a dangling reference) and would
  // have looked like an authorization finding.
  //
  // **The dates never move in these three rows.** An honest update that
  // changed one would run into `DeploymentInterlock` on the server, which is
  // a different refusal from the one this file is about; the notes move
  // instead, which exercises rule 4.0.1 and nothing else.
  Tables.deployments: _CrossCuttingFixture(
    id: 'dep-cc',
    insert: {
      'deployment_id': 'dep-cc',
      'project_id': _projectA,
      'tag_id': 'tag-1',
      'individual_id': 'ind-1',
      'attached_date': _at,
      'removed_date': null,
      'notes': 'fitted at the nest',
      'created_at': _at,
      'updated_at': _at,
      'revision': 1,
      'last_modified_by': _alice,
      'origin_device_id': 'device-A',
    },
    honestUpdate: {
      'deployment_id': 'dep-cc',
      'project_id': _projectA,
      'tag_id': 'tag-1',
      'individual_id': 'ind-1',
      'attached_date': _at,
      'removed_date': null,
      'notes': 'fitted at the nest, second attempt',
      'created_at': _at,
      'updated_at': '2026-08-02T12:00:00.000Z',
      'revision': 2,
      'last_modified_by': _alice,
      'origin_device_id': 'device-A',
    },
    corruptedUpdate: {
      'deployment_id': 'dep-cc',
      'project_id': _projectA,
      'tag_id': 'tag-1',
      'individual_id': 'ind-1',
      'attached_date': _at,
      'removed_date': null,
      'notes': 'fitted at the nest, third attempt',
      'created_at': _at,
      'updated_at': '2026-08-03T12:00:00.000Z',
      'revision': 3,
      'last_modified_by': _bob,
      'origin_device_id': 'device-A',
    },
  ),

  Tables.tagVersions: _CrossCuttingFixture(
    id: 'tv-cc',
    insert: {
      'tag_version_id': 'tv-cc',
      'project_id': _projectA,
      'tag_id': 'tag-1',
      'effective_from': _at,
      'frequency_mhz': 150.1,
      'pulse_rate': null,
      'pulse_pattern': null,
      'tag_name': 'Collar',
      'created_at': _at,
      'updated_at': _at,
      'revision': 1,
      'last_modified_by': _alice,
      'origin_device_id': 'device-A',
    },
    honestUpdate: {
      'tag_version_id': 'tv-cc',
      'project_id': _projectA,
      'tag_id': 'tag-1',
      'effective_from': _at,
      'frequency_mhz': 150.105,
      'pulse_rate': null,
      'pulse_pattern': null,
      'tag_name': 'Collar',
      'created_at': _at,
      'updated_at': '2026-08-02T12:00:00.000Z',
      'revision': 2,
      'last_modified_by': _alice,
      'origin_device_id': 'device-A',
    },
    corruptedUpdate: {
      'tag_version_id': 'tv-cc',
      'project_id': _projectA,
      'tag_id': 'tag-1',
      'effective_from': _at,
      'frequency_mhz': 150.11,
      'pulse_rate': null,
      'pulse_pattern': null,
      'tag_name': 'Collar',
      'created_at': _at,
      'updated_at': '2026-08-03T12:00:00.000Z',
      'revision': 3,
      'last_modified_by': _bob,
      'origin_device_id': 'device-A',
    },
  ),

  // **`Project_Tags` had a case here and it is deleted (task 11.219).** What
  // it proved: that rule 4.0.1 — an update must name its own caller in
  // `last_modified_by` — held on the junction row that linked a global tag
  // into a project, on the insert-is-a-grant path. **Nothing needs to prove
  // it now, because the table is gone from the schema**, and this deletion is
  // not a decision anybody has to remember: the "structural completeness"
  // group derives its expected set from `tableMutationRules`, so a case for a
  // table the code no longer declares fails the run, and a table with no case
  // fails it too. Both directions are watched failing in that same group.
  // Governed by MutationRule.anyUser.
  Tables.triangulationSessions: _CrossCuttingFixture(
    id: 'sess-cc',
    insert: {
      'session_id': 'sess-cc',
      'project_id': _projectA,
      'tag_id': 'tag-1',
      'started_at_local': _at,
      'started_at_utc': _at,
      'started_at_offset': '+00:00',
      'created_at': _at,
      'updated_at': _at,
      'revision': 1,
      'last_modified_by': _alice,
      'origin_device_id': 'device-A',
    },
    honestUpdate: {
      'session_id': 'sess-cc',
      'project_id': _projectA,
      'tag_id': 'tag-1',
      'started_at_local': _at,
      'started_at_utc': _at,
      'started_at_offset': '+00:00',
      'created_at': _at,
      'updated_at': '2026-08-02T12:00:00.000Z',
      'revision': 2,
      'last_modified_by': _alice,
      'origin_device_id': 'device-A',
    },
    corruptedUpdate: {
      'session_id': 'sess-cc',
      'project_id': _projectA,
      'tag_id': 'tag-1',
      'started_at_local': _at,
      'started_at_utc': _at,
      'started_at_offset': '+00:00',
      'created_at': _at,
      'updated_at': '2026-08-03T12:00:00.000Z',
      'revision': 3,
      'last_modified_by': _bob,
      'origin_device_id': 'device-A',
    },
  ),

  // Governed by MutationRule.author.
  Tables.observations: _CrossCuttingFixture(
    id: 'obs-cc',
    insert: {
      'observation_id': 'obs-cc',
      'project_id': _projectA,
      'user_id': _alice,
      'timestamp_local': _at,
      'timestamp_utc': _at,
      'timezone_offset': '+00:00',
      'latitude': 35.19,
      'longitude': -111.65,
      'position_source': 'gps_fix',
      'elevation': 2100.0,
      'altitude_agl': 0.0,
      'observation_type': 'directional',
      'signal_type': 'regular_pulse',
      'signal_strength': 'strong',
      'notes': null,
      'created_at': _at,
      'updated_at': _at,
      'revision': 1,
      'last_modified_by': _alice,
      'origin_device_id': 'device-A',
    },
    honestUpdate: {
      'observation_id': 'obs-cc',
      'project_id': _projectA,
      'user_id': _alice,
      'timestamp_local': _at,
      'timestamp_utc': _at,
      'timezone_offset': '+00:00',
      'latitude': 35.19,
      'longitude': -111.65,
      'position_source': 'gps_fix',
      'elevation': 2100.0,
      'altitude_agl': 0.0,
      'observation_type': 'directional',
      'signal_type': 'regular_pulse',
      'signal_strength': 'strong',
      'notes': 'clean signal',
      'created_at': _at,
      'updated_at': '2026-08-02T12:00:00.000Z',
      'revision': 2,
      'last_modified_by': _alice,
      'origin_device_id': 'device-A',
    },
    corruptedUpdate: {
      'observation_id': 'obs-cc',
      'project_id': _projectA,
      'user_id': _alice,
      'timestamp_local': _at,
      'timestamp_utc': _at,
      'timezone_offset': '+00:00',
      'latitude': 35.19,
      'longitude': -111.65,
      'position_source': 'gps_fix',
      'elevation': 2100.0,
      'altitude_agl': 0.0,
      'observation_type': 'directional',
      'signal_type': 'regular_pulse',
      'signal_strength': 'strong',
      'notes': 'bounced signal',
      'created_at': _at,
      'updated_at': '2026-08-03T12:00:00.000Z',
      'revision': 3,
      'last_modified_by': _bob,
      'origin_device_id': 'device-A',
    },
  ),

  // Governed by MutationRule.authorOrOwner. `kind` stays 'superseded'
  // throughout so `_authorizeExclusionKind`'s owner-only rung never fires —
  // this fixture is isolating the naming rule, not the exclusion rung
  // (which authorization_test.dart already covers by name).
  Tables.observationExclusions: _CrossCuttingFixture(
    id: 'excl-cc',
    insert: {
      'exclusion_id': 'excl-cc',
      'project_id': _projectA,
      'observation_id': 'obs-any',
      'user_id': _alice,
      'kind': 'superseded',
      'superseded_by_observation_id': null,
      'reason': 'better record follows',
      'created_at': _at,
      'updated_at': _at,
      'revision': 1,
      'last_modified_by': _alice,
      'origin_device_id': 'device-A',
    },
    honestUpdate: {
      'exclusion_id': 'excl-cc',
      'project_id': _projectA,
      'observation_id': 'obs-any',
      'user_id': _alice,
      'kind': 'superseded',
      'superseded_by_observation_id': null,
      'reason': 'better record follows, revised',
      'created_at': _at,
      'updated_at': '2026-08-02T12:00:00.000Z',
      'revision': 2,
      'last_modified_by': _alice,
      'origin_device_id': 'device-A',
    },
    corruptedUpdate: {
      'exclusion_id': 'excl-cc',
      'project_id': _projectA,
      'observation_id': 'obs-any',
      'user_id': _alice,
      'kind': 'superseded',
      'superseded_by_observation_id': null,
      'reason': 'better record follows, revised again',
      'created_at': _at,
      'updated_at': '2026-08-03T12:00:00.000Z',
      'revision': 3,
      'last_modified_by': _bob,
      'origin_device_id': 'device-A',
    },
  ),

  // Governed by MutationRule.author.
  Tables.nonDetections: _CrossCuttingFixture(
    id: 'nd-cc',
    insert: {
      'non_detection_id': 'nd-cc',
      'project_id': _projectA,
      'user_id': _alice,
      'tag_ids_listened_for': 'tag-1',
      'timestamp_local': _at,
      'timestamp_utc': _at,
      'timezone_offset': '+00:00',
      'latitude': 35.19,
      'longitude': -111.65,
      'position_source': 'gps_fix',
      'elevation': 2100.0,
      'altitude_agl': 0.0,
      'notes': null,
      'created_at': _at,
      'updated_at': _at,
      'revision': 1,
      'last_modified_by': _alice,
      'origin_device_id': 'device-A',
    },
    honestUpdate: {
      'non_detection_id': 'nd-cc',
      'project_id': _projectA,
      'user_id': _alice,
      'tag_ids_listened_for': 'tag-1',
      'timestamp_local': _at,
      'timestamp_utc': _at,
      'timezone_offset': '+00:00',
      'latitude': 35.19,
      'longitude': -111.65,
      'position_source': 'gps_fix',
      'elevation': 2100.0,
      'altitude_agl': 0.0,
      'notes': 'listened 10 minutes, nothing',
      'created_at': _at,
      'updated_at': '2026-08-02T12:00:00.000Z',
      'revision': 2,
      'last_modified_by': _alice,
      'origin_device_id': 'device-A',
    },
    corruptedUpdate: {
      'non_detection_id': 'nd-cc',
      'project_id': _projectA,
      'user_id': _alice,
      'tag_ids_listened_for': 'tag-1',
      'timestamp_local': _at,
      'timestamp_utc': _at,
      'timezone_offset': '+00:00',
      'latitude': 35.19,
      'longitude': -111.65,
      'position_source': 'gps_fix',
      'elevation': 2100.0,
      'altitude_agl': 0.0,
      'notes': 'listened 15 minutes, nothing',
      'created_at': _at,
      'updated_at': '2026-08-03T12:00:00.000Z',
      'revision': 3,
      'last_modified_by': _bob,
      'origin_device_id': 'device-A',
    },
  ),

  // Governed by MutationRule.anyUser.
  Tables.estimatedPositions: _CrossCuttingFixture(
    id: 'pos-cc',
    insert: {
      'position_id': 'pos-cc',
      'project_id': _projectA,
      'tag_id': 'tag-1',
      'timestamp_local': _at,
      'timestamp_utc': _at,
      'timezone_offset': '+00:00',
      'latitude': 35.19,
      'longitude': -111.65,
      'semi_major_axis': 120.0,
      'semi_minor_axis': 80.0,
      'rotation_angle': 30.0,
      'method': 'lenth_mle',
      'observation_ids_used': 'obs-1',
      'created_at': _at,
      'updated_at': _at,
      'revision': 1,
      'last_modified_by': _alice,
      'origin_device_id': 'device-A',
    },
    honestUpdate: {
      'position_id': 'pos-cc',
      'project_id': _projectA,
      'tag_id': 'tag-1',
      'timestamp_local': _at,
      'timestamp_utc': _at,
      'timezone_offset': '+00:00',
      'latitude': 35.19,
      'longitude': -111.65,
      'semi_major_axis': 121.0,
      'semi_minor_axis': 80.0,
      'rotation_angle': 30.0,
      'method': 'lenth_mle',
      'observation_ids_used': 'obs-1',
      'created_at': _at,
      'updated_at': '2026-08-02T12:00:00.000Z',
      'revision': 2,
      'last_modified_by': _alice,
      'origin_device_id': 'device-A',
    },
    corruptedUpdate: {
      'position_id': 'pos-cc',
      'project_id': _projectA,
      'tag_id': 'tag-1',
      'timestamp_local': _at,
      'timestamp_utc': _at,
      'timezone_offset': '+00:00',
      'latitude': 35.19,
      'longitude': -111.65,
      'semi_major_axis': 122.0,
      'semi_minor_axis': 80.0,
      'rotation_angle': 30.0,
      'method': 'lenth_mle',
      'observation_ids_used': 'obs-1',
      'created_at': _at,
      'updated_at': '2026-08-03T12:00:00.000Z',
      'revision': 3,
      'last_modified_by': _bob,
      'origin_device_id': 'device-A',
    },
  ),

  // Governed by MutationRule.anyUser.
  Tables.actualTagLocations: _CrossCuttingFixture(
    id: 'loc-cc',
    insert: {
      'location_id': 'loc-cc',
      'project_id': _projectA,
      'tag_id': 'tag-1',
      'timestamp_local': _at,
      'timestamp_utc': _at,
      'timezone_offset': '+00:00',
      'latitude': 35.19,
      'longitude': -111.65,
      'uncertainty_radius': 10.0,
      'created_at': _at,
      'updated_at': _at,
      'revision': 1,
      'last_modified_by': _alice,
      'origin_device_id': 'device-A',
    },
    honestUpdate: {
      'location_id': 'loc-cc',
      'project_id': _projectA,
      'tag_id': 'tag-1',
      'timestamp_local': _at,
      'timestamp_utc': _at,
      'timezone_offset': '+00:00',
      'latitude': 35.19,
      'longitude': -111.65,
      'uncertainty_radius': 12.0,
      'created_at': _at,
      'updated_at': '2026-08-02T12:00:00.000Z',
      'revision': 2,
      'last_modified_by': _alice,
      'origin_device_id': 'device-A',
    },
    corruptedUpdate: {
      'location_id': 'loc-cc',
      'project_id': _projectA,
      'tag_id': 'tag-1',
      'timestamp_local': _at,
      'timestamp_utc': _at,
      'timezone_offset': '+00:00',
      'latitude': 35.19,
      'longitude': -111.65,
      'uncertainty_radius': 14.0,
      'created_at': _at,
      'updated_at': '2026-08-03T12:00:00.000Z',
      'revision': 3,
      'last_modified_by': _bob,
      'origin_device_id': 'device-A',
    },
  ),
};

/// Throws naming the difference if [declared] and [covered] are not the same
/// set — in both directions. The structural half of this file: a table the
/// code declares and this file has no case for, or a case naming a table the
/// code does not declare, is a documentation gap of exactly the shape task
/// 11.24 found and this task exists to stop.
void _assertSetsMatch({
  required Set<String> declared,
  required Set<String> covered,
  required String declaredLabel,
  required String coveredLabel,
}) {
  final missing = declared.difference(covered);
  final extra = covered.difference(declared);
  if (missing.isEmpty && extra.isEmpty) return;
  final parts = <String>[
    if (missing.isNotEmpty)
      'in $declaredLabel but not $coveredLabel: ${missing.join(', ')}',
    if (extra.isNotEmpty)
      'in $coveredLabel but not $declaredLabel: ${extra.join(', ')}',
  ];
  throw StateError(
    'Table coverage does not match — ${parts.join('; ')}. Every table must '
    'appear on both sides, or this document is a hand-kept list again.',
  );
}

/// The tables `RowAuthorizer._authorizeTagLifecycle` names in its own guard —
/// the ones whose stored rows only an owner may change, whatever the rule
/// table says (task 11.254). See [_tablesNamedByGuard].
Set<String> _tablesNamedByTagLifecycle() => _tablesNamedByGuard(
  signature: 'AuthzVerdict? _authorizeTagLifecycle(',
  methodLabel: '_authorizeTagLifecycle',
  helperLabel: '_tablesNamedByTagLifecycle',
);

/// The tables `RowAuthorizer._authorizeIndividualLifecycle` names in its own
/// guard — the ones whose stored rows only an owner may **tombstone**, which
/// is narrower than [_tablesNamedByTagLifecycle]'s "only an owner may change
/// at all" (task 11.255). See [_tablesNamedByGuard].
Set<String> _tablesNamedByIndividualLifecycle() => _tablesNamedByGuard(
  signature: 'AuthzVerdict? _authorizeIndividualLifecycle(',
  methodLabel: '_authorizeIndividualLifecycle',
  helperLabel: '_tablesNamedByIndividualLifecycle',
);

/// The tables named in the `if (table.name != Tables.a && ...) return null;`
/// guard that opens the method at [signature] in `row_authorizer.dart` —
/// shared by [_tablesNamedByTagLifecycle] and
/// [_tablesNamedByIndividualLifecycle] (task 11.255).
///
/// Read from the source rather than written here so the "shared tables"
/// group's exceptions depend on the thing that justifies them. Every
/// `Tables.<identifier>` in the guard is resolved to its string through
/// `schema_constants.dart`, so neither file is hand-copied.
///
/// Throws, rather than returning empty, when the method or its guard cannot
/// be found — the group asserts non-emptiness too, but a parser that returns
/// nothing on a rename would otherwise flip an owner-only expectation to
/// "contributor may alter" and pass. That is the failure this project keeps
/// finding in derivations, and it is refused here at the source.
Set<String> _tablesNamedByGuard({
  required String signature,
  required String methodLabel,
  required String helperLabel,
}) {
  final authorizer = File(
    'lib/src/authz/row_authorizer.dart',
  ).readAsStringSync();
  final at = authorizer.indexOf(signature);
  if (at < 0) {
    throw StateError(
      'RowAuthorizer.$methodLabel not found in row_authorizer.dart — '
      'renamed? Update $helperLabel to match.',
    );
  }
  final body = authorizer.substring(at);
  final guard = RegExp(
    r'if\s*\(([^{]*?)\)\s*\{\s*return null;',
  ).firstMatch(body);
  if (guard == null) {
    throw StateError(
      '$methodLabel no longer opens with an `if (...) { return null; }` '
      'guard naming its tables — update $helperLabel.',
    );
  }
  final identifiers = RegExp(
    r'Tables\.(\w+)',
  ).allMatches(guard.group(1)!).map((m) => m.group(1)!).toSet();

  final constants = File(
    '../packages/tritrack_sync/lib/src/schema_constants.dart',
  ).readAsStringSync();
  final byIdentifier = {
    for (final m in RegExp(
      r"static const (\w+) = '([^']+)';",
    ).allMatches(constants))
      m.group(1)!: m.group(2)!,
  };
  return {
    for (final id in identifiers)
      byIdentifier[id] ??
          (throw StateError(
            'Tables.$id is not declared in schema_constants.dart',
          )),
  };
}
