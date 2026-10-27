import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:tritrack/data/db/app_database.dart';
import 'package:tritrack/data/sync/backup_archive.dart';
import 'package:tritrack/data/sync/merge_report.dart';
import 'package:tritrack/data/sync/project_exporter.dart';
import 'package:tritrack/data/sync/project_merger.dart';
import 'package:tritrack/data/sync/sync_conflicts.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

import '../data/fixtures.dart';
import '../data/sync/backup_builders.dart';

/// Finding **K-1** (security model §13.2) and the rules that close it (§4.19,
/// extended to this path by task 10.73).
///
/// A `.zip` the user picks reaches `BackupArchive.decode` → `ProjectMerger` and,
/// as shipped, took `user_id`, `owner_user_id`, `last_modified_by`, `revision`,
/// `created_at`, `updated_at`, `origin_device_id` and `deleted_at` verbatim from
/// the file across all eleven synced tables, with no prior-version capture and
/// no field-by-field diff. §13.2 reproduced the whole of J-1's damage profile
/// through it — under the **default** `lastWriteWins` strategy, with validation
/// on — and reported it as *"Inserted: 1, Updated: 3"* over an empty
/// `Sync_Conflicts` table.
///
/// The reproduction is kept verbatim as the first group, transcript line by
/// transcript line. The rest assert each clause independently, because §4.19's
/// own note is that fixing any one alone leaves the finding open — and because
/// the gate measured **four separate wrong fixes**, each of which would pass a
/// test suite that only ran the reproduction. Those get a group of their own.
/// `a genuine restore` exists so the fix cannot quietly become "refuse
/// everything", which on a *backup restore* path would be its own data-loss
/// finding.
void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  const victim = 'user-victim';
  const attacker = 'user-evil';
  const localProject = 'project-local';
  const localTag = 'tag-local';

  /// This device's clock during the import. Every bound is measured against
  /// one reading of it, passed in rather than read, so the tests do not drift
  /// with the wall clock.
  final now = DateTime.utc(2026, 8, 16, 12);

  late AppDatabase database;
  late Database db;

  setUp(() async {
    database = await AppDatabase.openInMemory();
    db = database.raw;
    await db.insert(Tables.users,
        sampleUser(id: victim, email: 'victim@example.org').toColumns());
    await db.insert(Tables.projects,
        sampleProject(id: localProject, ownerUserId: victim).toColumns());
    await db.insert(
      Tables.tags,
      sampleTag(id: localTag, projectId: localProject).toColumns(),
    );
  });
  tearDown(() async => database.close());

  /// One genuine field record, authored by the victim on this device: a fully
  /// populated directional observation carrying its whole bearing audit trail.
  /// Matches §13.2's `BEFORE` state field for field.
  Future<Map<String, Object?>> seedFieldRecord({
    String id = 'obs-1',
    int revision = 4,
  }) async {
    final observation = sampleObservation(
      id: id,
      projectId: localProject,
      userId: victim,
      tagId: localTag,
      sessionId: null,
      latitude: 35.1983,
      longitude: -111.6513,
    ).copyWith(
      sync: sampleSync().copyWith(
        revision: revision,
        updatedAt: DateTime.utc(2026, 7, 20, 9),
        lastModifiedBy: victim,
        originDeviceId: 'device-victim-phone',
      ),
    );
    final columns = observation.toColumns();
    await db.insert(Tables.observations, columns);
    return columns;
  }

  Future<Map<String, Object?>?> fetch(
    String table,
    String column,
    String value,
  ) async {
    final rows = await db.query(table, where: '$column = ?', whereArgs: [value]);
    return rows.isEmpty ? null : rows.first;
  }

  Future<List<SyncConflict>> conflicts() async {
    await SyncConflictStore.ensureTable(db);
    return SyncConflictStore(db).unreviewed(localProject);
  }

  /// The import as the screen performs it: the user's own id is what
  /// `last_modified_by` is restated to.
  Future<MergeReport> import(
    ProjectBackup backup, {
    MergeStrategy strategy = MergeStrategy.lastWriteWins,
    bool confirmChanges = false,
  }) =>
      ProjectMerger(db).merge(
        backup,
        strategy: strategy,
        confirmChanges: confirmChanges,
        importingUserId: victim,
        now: now,
      );

  /// The hostile archive of §13.2, rebuilt. Everything an attacker needs is in
  /// a backup they legitimately received: every `project_id`, `observation_id`
  /// and `user_id` on the team.
  ///
  /// [clockRevision] and [clockUpdatedAt] default to the transcript's
  /// `9223372036854775807` / `2999-01-01`; the clause-by-clause groups below
  /// pass *legal* values instead, because §4.19 rule 3 says in as many words
  /// that the bound defends nothing on its own and a test suite that only ever
  /// sends the out-of-range value would be measuring one clause four times.
  ProjectBackup hostileArchive({
    int clockRevision = 9223372036854775807,
    String clockUpdatedAt = '2999-01-01T00:00:00.000Z',
    String projectId = localProject,
    String manifestProjectId = localProject,
  }) {
    Map<String, Object?> withClock(Map<String, Object?> row) => {
          ...row,
          'revision': clockRevision,
          'updated_at': clockUpdatedAt,
          'last_modified_by': victim, // forged to name the victim
          'origin_device_id': 'zzzz-attacker-wins-every-tie',
        };

    return makeBackup(
      {
        // A `Users` row of the attacker's choosing, planted alongside.
        Tables.users: [
          withClock(
              sampleUser(id: attacker, email: 'mallory@evil.test').toColumns()),
        ],
        // The project's owner, reassigned.
        Tables.projects: [
          withClock(
              sampleProject(id: projectId, ownerUserId: attacker).toColumns()),
        ],
        Tables.observations: [
          // obs-1: moved to (0,0), author reassigned, and the bearing audit
          // trail — declination and WMM model version — erased.
          withClock({
            ...sampleObservation(
              id: 'obs-1',
              projectId: projectId,
              userId: attacker,
              tagId: localTag,
              sessionId: null,
              latitude: 0.0,
              longitude: 0.0,
            ).toColumns(),
            'magnetic_declination': null,
            'wmm_model_version': null,
          }),
          // obs-2: tombstoned.
          withClock({
            ...sampleObservation(
              id: 'obs-2',
              projectId: projectId,
              userId: victim,
              tagId: localTag,
              sessionId: null,
            ).toColumns(),
            'deleted_at': clockUpdatedAt,
          }),
        ],
      },
      projectId: manifestProjectId,
    );
  }

  group('the K-1 reproduction (§13.2)', () {
    setUp(() async {
      await seedFieldRecord(id: 'obs-1');
      await seedFieldRecord(id: 'obs-2');
    });

    test('the whole transcript is refused, under the default strategy with '
        'validation on', () async {
      final report = await import(hostileArchive());

      // §13.2's report line was
      // `inserted=1 updated=3 skipped=0 invalid=0 issues=[]`. Every one of
      // those four numbers is now different, and the issues list is not empty.
      expect(report.totalInserted, 0, reason: 'the transcript reported 1');
      expect(report.totalUpdated, 0, reason: 'the transcript reported 3');
      expect(report.totalRefused, greaterThan(0));
      expect(report.issues, isNotEmpty,
          reason: 'the transcript reported issues=[]');

      // Line by line against the transcript's AFTER state.
      final project = (await fetch(Tables.projects, 'project_id', localProject))!;
      expect(project['owner_user_id'], victim);
      expect(project['revision'], isNot(9223372036854775807));

      final obs1 = (await fetch(Tables.observations, 'observation_id', 'obs-1'))!;
      expect(obs1['latitude'], 35.1983);
      expect(obs1['longitude'], -111.6513);
      expect(obs1['user_id'], victim);
      expect(obs1['last_modified_by'], victim);
      expect(obs1['magnetic_declination'], isNotNull,
          reason: 'the bearing must stay re-derivable, not merely believed');
      expect(obs1['wmm_model_version'], isNotNull);
      expect(obs1['origin_device_id'], 'device-victim-phone');

      final obs2 = (await fetch(Tables.observations, 'observation_id', 'obs-2'))!;
      expect(obs2['deleted_at'], isNull);

      // "Users rows now: [user-victim/..., user-evil/mallory@evil.test]"
      expect(await db.query(Tables.users), hasLength(1));
    });

    test('a refused row is reported with a reason, never silently dropped',
        () async {
      final report = await import(hostileArchive());

      expect(report.totalRefused, greaterThan(0));
      expect(
        report.issues.map((i) => i.toString()).join('\n'),
        contains('out of range'),
      );
      // Refusals are not folded into `invalid`: an out-of-range clock is not a
      // malformed record, and a single "rejected" number would read like a
      // formatting complaint about a file that was well-formed throughout.
      expect(report.totalInvalid, 0);
    });
  });

  group('the four wrong fixes the gate measured', () {
    setUp(() async => seedFieldRecord(id: 'obs-1'));

    test('(a) removing "Overwrite with backup" fixes nothing — the damage '
        'lands under the default strategy', () async {
      // The gate's own words: an unbounded `revision` wins `MergeResolver`
      // outright, so `preferIncoming` was never required. The default strategy
      // is what this whole file runs under; this test states the negative
      // explicitly so nobody re-derives the wrong conclusion from the fact
      // that the button still exists.
      final report = await import(
        hostileArchive(),
        strategy: MergeStrategy.lastWriteWins,
      );
      expect(report.totalUpdated, 0);
      expect(
        (await fetch(Tables.observations, 'observation_id', 'obs-1'))!['latitude'],
        35.1983,
      );
    });

    test('(b) RowValidator runs here and stops none of it on its own',
        () async {
      // Every row of the hostile archive passes `RowValidator` — it is a
      // domain-bounds and enum check and has never inspected `revision`,
      // `updated_at`, `deleted_at` or authorship. Asserted directly, because
      // "validation is on" was the reassurance §4.19.1 recorded and it was
      // true and worthless in the same breath.
      final archive = hostileArchive();
      for (final table in syncTables) {
        for (final row in archive.rowsFor(table.name)) {
          expect(RowValidator.validate(table.name, row), isEmpty,
              reason: '${table.name} row passes RowValidator unaided');
        }
      }
    });

    test('(c) the merge is scoped to the manifest project — one file cannot '
        'rewrite an unrelated local project', () async {
      // §13.2: "a file whose manifest names project A rewrote the owner of an
      // unrelated local project B." `manifest.projectId` was read only for the
      // "Switch to this project" button.
      final report = await import(
        hostileArchive(
          clockRevision: 9,
          clockUpdatedAt: '2026-08-01T00:00:00.000Z',
          projectId: localProject,
          manifestProjectId: 'project-somewhere-else',
        ),
        confirmChanges: true,
      );

      expect(
        (await fetch(Tables.projects, 'project_id', localProject))!['owner_user_id'],
        victim,
      );
      expect(report.totalRefused, greaterThan(0));
      expect(
        report.issues.map((i) => i.toString()).join('\n'),
        contains('project-somewhere-else'),
      );
    });

    test('(d) the email dedup still fires, and is reported instead of silent',
        () async {
      // `IdentityTrust.emailMatchesPerson` is load-bearing on this path and
      // stays (see [IdentityTrust]) — it is the only thing between "merged my
      // own phone's export" and two of me. What it owed was a count. A file
      // whose `Users` row claims the victim's address re-attributes the file's
      // own rows to the victim, and the user is now told how many.
      final report = await import(
        makeBackup(
          {
            Tables.users: [
              sampleUser(id: attacker, email: 'victim@example.org').toColumns(),
            ],
            Tables.observations: [
              sampleObservation(
                id: 'obs-planted',
                projectId: localProject,
                userId: attacker,
                tagId: localTag,
                sessionId: null,
              ).toColumns(),
            ],
          },
          projectId: localProject,
        ),
      );

      expect(report.usersDeduped, 1);
      expect(report.rowsReattributed, greaterThan(0),
          reason: 'the re-attribution must be counted, not silent');
      expect(
        (await fetch(Tables.observations, 'observation_id', 'obs-planted'))!['user_id'],
        victim,
      );
    });
  });

  group('clause 2 — authorship never comes from a file', () {
    setUp(() async => seedFieldRecord(id: 'obs-1'));

    /// A legal clock that still wins: revision 9 beats the local 4. §4.19
    /// rule 3 says outright that a bounded clock defends nothing alone, and
    /// this is what that sentence means in practice.
    Map<String, Object?> winning(Map<String, Object?> row) => {
          ...row,
          'revision': 9,
          'updated_at': '2026-08-01T00:00:00.000Z',
        };

    test('user_id is never written to a row that already exists', () async {
      await import(
        makeBackup(
          {
            Tables.users: [
              sampleUser(id: attacker, email: 'mallory@evil.test').toColumns(),
            ],
            Tables.observations: [
              winning(sampleObservation(
                id: 'obs-1',
                projectId: localProject,
                userId: attacker,
                tagId: localTag,
                sessionId: null,
              ).toColumns()),
            ],
          },
          projectId: localProject,
        ),
        confirmChanges: true,
      );

      // Phase 8's author-only rule keys on `user_id`; letting a file move it is
      // how J-1 locked a biologist out of their own record.
      expect(
        (await fetch(Tables.observations, 'observation_id', 'obs-1'))!['user_id'],
        victim,
      );
    });

    test('owner_user_id is never written to a project that already exists',
        () async {
      await import(
        makeBackup(
          {
            Tables.users: [
              sampleUser(id: attacker, email: 'mallory@evil.test').toColumns(),
            ],
            Tables.projects: [
              winning(sampleProject(id: localProject, ownerUserId: attacker)
                  .toColumns()),
            ],
          },
          projectId: localProject,
        ),
        confirmChanges: true,
      );

      expect(
        (await fetch(Tables.projects, 'project_id', localProject))!['owner_user_id'],
        victim,
      );
    });

    test('the rule iterates the declared identity columns, not two column '
        'names someone remembered', () async {
      // Task 10.66's rule: fix the class. `identityUserColumns` is the declared
      // complete set of the ways a row can name a person — the same list the
      // server's row-naming invariant iterates — so a table that gains a user
      // column inherits clause 2 rather than needing an edit here. If this ever
      // fails, a table has a way of naming somebody that clause 2 does not
      // cover.
      for (final table in syncTables) {
        for (final column in table.userColumns) {
          expect(
            column == auditUserColumn ||
                table.identityUserColumns.contains(column),
            isTrue,
            reason: '${table.name}.$column is neither audit nor identity',
          );
        }
      }
    });

    test('last_modified_by is restated as the importer, never the file\'s '
        'claim', () async {
      await import(
        makeBackup(
          {
            Tables.observations: [
              {
                ...winning(sampleObservation(
                  id: 'obs-1',
                  projectId: localProject,
                  userId: victim,
                  tagId: localTag,
                  sessionId: null,
                ).toColumns()),
                'last_modified_by': attacker,
              },
            ],
          },
          projectId: localProject,
        ),
        confirmChanges: true,
      );

      final obs = (await fetch(Tables.observations, 'observation_id', 'obs-1'))!;
      expect(obs['last_modified_by'], victim,
          reason: 'the person who chose the file is who caused the change');
    });
  });

  group('clause 3 — the merge clock is bounded, and refused not clamped', () {
    // Every payload here is a byte-for-byte copy of the row this device
    // already holds, differing only in the clock under test. That isolation is
    // the point: a fixture that also moved the latitude would pass these tests
    // on the strength of clause 4 and tell us nothing about clause 3.
    late Map<String, Object?> seeded;
    setUp(() async => seeded = await seedFieldRecord(id: 'obs-1'));

    Future<MergeReport> withSync(Map<String, Object?> sync) => import(
          makeBackup(
            {
              Tables.observations: [
                {...seeded, ...sync},
              ],
            },
            projectId: localProject,
          ),
          confirmChanges: true,
        );

    test('an implausibly large revision is refused', () async {
      final report = await withSync({'revision': 9223372036854775807});
      expect(report.totalRefused, 1);
      expect(
        (await fetch(Tables.observations, 'observation_id', 'obs-1'))!['revision'],
        4,
      );
    });

    test('a future updated_at is refused', () async {
      final report = await withSync({
        'revision': 9,
        'updated_at': '2999-01-01T00:00:00.000Z',
      });
      expect(report.totalRefused, 1);
    });

    test('a created_at predating TriTrack is refused', () async {
      final report = await withSync({
        'revision': 9,
        'created_at': '1999-01-01T00:00:00.000Z',
      });
      expect(report.totalRefused, 1);
    });

    test('a deleted_at outside the bound is refused too', () async {
      // The share format carries `deleted_at` as a fixed null, so §4.19's
      // original enforcement never had to look at it — an exemption the
      // *format* creates, not the rule. An archive carries it verbatim, and
      // K-1 used `deleted_at = 2999-01-01` to tombstone a live observation.
      final report = await withSync({
        'revision': 9,
        'deleted_at': '2999-01-01T00:00:00.000Z',
      });
      expect(report.totalRefused, 1);
      expect(
        (await fetch(Tables.observations, 'observation_id', 'obs-1'))!['deleted_at'],
        isNull,
      );
    });

    test('refused, not clamped — the row does not land with a corrected clock',
        () async {
      // Clamping a hostile clock to "now" would leave it winning
      // last-write-wins against every honest local edit: the attack succeeds
      // and the bound reports that it worked.
      await withSync({
        'revision': 9223372036854775807,
        'notes': 'attacker text',
      });
      final obs = (await fetch(Tables.observations, 'observation_id', 'obs-1'))!;
      expect(obs['notes'], 'clear signal');
      expect(obs['revision'], 4);
    });

    test('a legal clock is not refused — the bound is a bound, not a wall',
        () async {
      final report = await withSync({
        'revision': 9,
        'updated_at': '2026-08-01T00:00:00.000Z',
        'notes': 'a colleague corrected the note',
      });
      expect(report.totalRefused, 0);
      expect(
        (await fetch(Tables.observations, 'observation_id', 'obs-1'))!['notes'],
        'a colleague corrected the note',
      );
    });
  });

  group('clause 4 — nothing replaces a held value unseen, and the prior '
      'version survives', () {
    // The incoming row is the held row with a newer clock and nothing else
    // changed, so each test's `overrides` are the *only* difference and the
    // diff it produces is exactly what is under test.
    late Map<String, Object?> seeded;
    setUp(() async => seeded = await seedFieldRecord(id: 'obs-1'));

    ProjectBackup edit(Map<String, Object?> overrides) => makeBackup(
          {
            Tables.observations: [
              {
                ...seeded,
                'revision': 9,
                'updated_at': '2026-08-01T00:00:00.000Z',
                ...overrides,
              },
            ],
          },
          projectId: localProject,
        );

    test('without consent the import writes nothing at all, and says what it '
        'would change', () async {
      final report = await import(edit({'latitude': 0.0, 'longitude': 0.0}));

      expect(report.outcome, MergeOutcome.needsConfirmation);
      expect(report.wrote, isFalse);
      final columns = report.destructiveChanges.map((c) => c.column).toSet();
      expect(columns, containsAll(['latitude', 'longitude']));
      final latitude =
          report.destructiveChanges.firstWhere((c) => c.column == 'latitude');
      expect(latitude.was, 35.1983);
      expect(latitude.becomes, 0.0);
      expect(latitude.table, Tables.observations);
      expect(latitude.rowKey, contains('obs-1'));

      expect(
        (await fetch(Tables.observations, 'observation_id', 'obs-1'))!['latitude'],
        35.1983,
      );
    });

    test('consent is all-or-nothing across the archive — one destructive row '
        'holds the whole import', () async {
      // A per-row prompt over eleven tables is a prompt the user clicks
      // through, which puts the record back where J-1 found it with extra
      // clicks. The insert below is harmless and still does not land.
      final report = await import(makeBackup(
        {
          Tables.observations: [
            {
              ...sampleObservation(
                id: 'obs-1',
                projectId: localProject,
                userId: victim,
                tagId: localTag,
                sessionId: null,
              ).toColumns(),
              'revision': 9,
              'updated_at': '2026-08-01T00:00:00.000Z',
              'latitude': 0.0,
            },
            sampleObservation(
              id: 'obs-new',
              projectId: localProject,
              userId: victim,
              tagId: localTag,
              sessionId: null,
            ).toColumns(),
          ],
        },
        projectId: localProject,
      ));

      expect(report.outcome, MergeOutcome.needsConfirmation);
      expect(await fetch(Tables.observations, 'observation_id', 'obs-new'), isNull);
    });

    test('filling an empty column is an addition and needs no prompt',
        () async {
      // A prompt that always fires is one the user learns to dismiss.
      await db.update(Tables.observations, {'notes': null},
          where: 'observation_id = ?', whereArgs: ['obs-1']);
      seeded = {...seeded, 'notes': null};

      final report = await import(edit({'notes': 'added by a colleague'}));

      expect(report.outcome, MergeOutcome.applied);
      expect(report.destructiveChanges, isEmpty);
      expect(
        (await fetch(Tables.observations, 'observation_id', 'obs-1'))!['notes'],
        'added by a colleague',
      );
    });

    test('a tombstone landing on a live row is destructive, though `was` is '
        'null', () async {
      // The K-8 criterion read correctly: `was == null` reads as "nothing was
      // there", and what a tombstone actually does is remove the whole record
      // from every screen the holder looks at.
      final report = await import(edit({'deleted_at': '2026-08-01T00:00:00.000Z'}));

      expect(report.outcome, MergeOutcome.needsConfirmation);
      expect(
        report.destructiveChanges.map((c) => c.column),
        contains('deleted_at'),
      );
      expect(
        (await fetch(Tables.observations, 'observation_id', 'obs-1'))!['deleted_at'],
        isNull,
      );
    });

    test('created_at and origin_device_id are shown, not exempt (K-8)',
        () async {
      // Neither moves on an honest edit, both are taken verbatim from the
      // payload, and both were exempt from the diff until task 10.73.
      // `origin_device_id` is the documented final last-write-wins tiebreaker,
      // so a lexically-high forged value wins every future tie against the
      // holder's genuine edits; `created_at` is falsified provenance.
      final report = await import(edit({
        'created_at': '2026-07-01T00:00:00.000Z',
        'origin_device_id': 'zzzz-attacker-wins-every-tie',
      }));

      expect(report.outcome, MergeOutcome.needsConfirmation);
      expect(
        report.destructiveChanges.map((c) => c.column),
        containsAll(['created_at', 'origin_device_id']),
      );
    });

    test('an ordinary correction still mentions no clock at all', () async {
      // The other half of the K-8 criterion, and the property that must
      // survive L-2's re-derivation: listing the clock on every update would
      // make a one-word note correction render as a three-field overwrite, and
      // a prompt that is always alarming is one the user learns to dismiss.
      //
      // **This test used to assert `revision` and `updated_at` are exempt, and
      // that assertion was finding L-2.** The criterion is sound for a column
      // the merge *ignores* and unsound for one it *reads*, so the clock is no
      // longer exempt — it is judged as one thing and shown only when the
      // change the file carries cannot account for it. Here it can: the file
      // replaces the notes, and moves the clock by five on the way past.
      final report = await import(edit({'notes': 'signal re-checked'}));

      expect(report.outcome, MergeOutcome.needsConfirmation,
          reason: 'replacing the notes is destructive');
      expect(report.destructiveChanges.map((c) => c.column), ['notes']);
      expect(report.changes.map((c) => c.column), isNot(contains('revision')));
      expect(report.changes.map((c) => c.column), isNot(contains('updated_at')));
    });

    test('an archive whose only effect is to move the clock is not exempt — '
        'it is L-2', () async {
      // `edit({})` is a file byte-identical to the victim's own row except for
      // the merge clock. Until task 10.93 it applied with
      // `changes=0 destructive=0` and no dialog; the reproduction and the whole
      // class live in `untrusted_import_exemption_test.dart`. Asserted here too
      // because this file is where the wrong answer was written down.
      final report = await import(edit({}));

      expect(report.outcome, MergeOutcome.needsConfirmation);
      expect(report.destructiveChanges.map((c) => c.column),
          contains('revision'));
    });

    test('the prior version is written to Sync_Conflicts before the overwrite '
        'lands', () async {
      // §13.2's transcript: "Sync_Conflicts rows: 0". On a *backup restore*
      // path, "you should have taken a backup" is circular reasoning, so
      // recoverability has to be a property of the write.
      await import(edit({'latitude': 0.0}), confirmChanges: true);

      final recorded = await conflicts();
      final match = recorded.singleWhere((c) => c.tableName == Tables.observations);
      expect(match.rowKey, contains('obs-1'));
      expect(match.localSnapshot['latitude'], 35.1983);
      expect(match.incomingSnapshot?['latitude'], 0.0);
      expect(
        match.changedFields.any((f) => f.field == 'latitude'),
        isTrue,
      );
    });

    test('the offer and the receipt are the same list', () async {
      // The consent the user gave and the change they got cannot disagree.
      final offered = await import(edit({'latitude': 0.0, 'elevation': 1.0}));
      final applied = await import(
        edit({'latitude': 0.0, 'elevation': 1.0}),
        confirmChanges: true,
      );

      String key(MergeFieldChange c) => '${c.table}/${c.rowKey}/${c.column}';
      expect(
        applied.destructiveChanges.map(key).toSet(),
        offered.destructiveChanges.map(key).toSet(),
      );
    });
  });

  group('clause 5 — validation is an invariant here, not an option', () {
    test('an invalid row is rejected and reported, not written', () async {
      final report = await import(makeBackup(
        {
          Tables.observations: [
            {
              ...sampleObservation(
                id: 'obs-bad',
                projectId: localProject,
                userId: victim,
                tagId: localTag,
                sessionId: null,
              ).toColumns(),
              'true_north_bearing': 999.0,
            },
          ],
        },
        projectId: localProject,
      ));

      expect(report.totalInvalid, 1);
      expect(await fetch(Tables.observations, 'observation_id', 'obs-bad'), isNull);
    });

    test('validate: false cannot turn it off on an untrusted archive',
        () async {
      // §4.19.1's own words about this path were "validation is an opt-out
      // parameter rather than an invariant." Enforced in release builds too —
      // the value is forced, not merely asserted, because an assert is stripped
      // exactly where it would matter.
      final backup = makeBackup(
        {
          Tables.observations: [
            {
              ...sampleObservation(
                id: 'obs-bad',
                projectId: localProject,
                userId: victim,
                tagId: localTag,
                sessionId: null,
              ).toColumns(),
              'true_north_bearing': 999.0,
            },
          ],
        },
        projectId: localProject,
      );

      // The assert fires in a debug test run, which is itself the guarantee;
      // what is asserted here is that the *forcing* holds regardless of it.
      await expectLater(
        () => ProjectMerger(db).merge(backup, validate: false, now: now),
        throwsA(isA<AssertionError>()),
      );
      expect(await fetch(Tables.observations, 'observation_id', 'obs-bad'), isNull);
    });
  });

  group('a genuine restore', () {
    // The other half of the guarantee, and on a *restore* path it is not a
    // courtesy: a fix that quietly became "refuse everything" would be its own
    // data-loss finding, on the feature whose entire job is getting a field
    // season back.
    test('a whole project round-trips into a fresh device untouched', () async {
      await seedFieldRecord(id: 'obs-1');
      await seedFieldRecord(id: 'obs-2');
      final backup =
          await ProjectExporter.collect(db, localProject, now: DateTime.utc(2026, 8, 2));
      final bytes = BackupArchive.encode(backup);

      final fresh = await AppDatabase.openInMemory();
      addTearDown(fresh.close);
      final report = await ProjectMerger(fresh.raw).merge(
        BackupArchive.decode(bytes),
        importingUserId: victim,
        now: now,
      );

      expect(report.wrote, isTrue);
      expect(report.destructiveChanges, isEmpty,
          reason: 'a restore into an empty device destroys nothing');
      expect(report.totalRefused, 0);
      expect(report.totalInvalid, 0);

      final observations = await fresh.raw.query(Tables.observations);
      expect(observations, hasLength(2));
      final restored = observations.first;
      expect(restored['user_id'], victim);
      expect(restored['magnetic_declination'], 10.2);
      expect(restored['wmm_model_version'], 'WMM2025');
      // An insert destroys nothing, so the file's own provenance survives it —
      // clause 2 narrows the *update* path, not the create path.
      expect(restored['last_modified_by'], victim);
      expect(restored['origin_device_id'], 'device-victim-phone');
    });

    test('a colleague\'s newer edit still applies once the diff is accepted',
        () async {
      await seedFieldRecord(id: 'obs-1');
      final backup = makeBackup(
        {
          Tables.observations: [
            {
              ...sampleObservation(
                id: 'obs-1',
                projectId: localProject,
                userId: victim,
                tagId: localTag,
                sessionId: null,
              ).toColumns(),
              'revision': 9,
              'updated_at': '2026-08-01T00:00:00.000Z',
              'notes': 'corrected in the field',
            },
          ],
        },
        projectId: localProject,
      );

      expect((await import(backup)).outcome, MergeOutcome.needsConfirmation);
      final applied = await import(backup, confirmChanges: true);

      expect(applied.wrote, isTrue);
      expect(
        (await fetch(Tables.observations, 'observation_id', 'obs-1'))!['notes'],
        'corrected in the field',
      );
    });

    test('a stale file never wins, with or without consent', () async {
      await seedFieldRecord(id: 'obs-1', revision: 9);
      final report = await import(
        makeBackup(
          {
            Tables.observations: [
              {
                ...sampleObservation(
                  id: 'obs-1',
                  projectId: localProject,
                  userId: victim,
                  tagId: localTag,
                  sessionId: null,
                ).toColumns(),
                'revision': 2,
                'notes': 'stale',
              },
            ],
          },
          projectId: localProject,
        ),
        confirmChanges: true,
      );

      expect(report.statsFor(Tables.observations).skipped, 1);
      expect(
        (await fetch(Tables.observations, 'observation_id', 'obs-1'))!['notes'],
        'clear signal',
      );
    });
  });
}
