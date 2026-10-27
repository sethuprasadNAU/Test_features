import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:tritrack/data/db/app_database.dart';
import 'package:tritrack/data/models/observation.dart';
import 'package:tritrack/data/repositories/mutation_authorization.dart';
import 'package:tritrack/data/repositories/observation_repository.dart';
import 'package:tritrack/data/sharing/observation_share.dart';
import 'package:tritrack/data/sharing/shared_observation_importer.dart';
import 'package:tritrack/data/sync/merge_report.dart';
import 'package:tritrack/data/sync/project_exporter.dart';
import 'package:tritrack/data/sync/project_merger.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

import '../data/fixtures.dart';
import '../data/sync/backup_builders.dart';

/// Finding **L-2** (security model §14.3) and the class it belongs to.
///
/// §4.19 clause 3 bounds `revision`; clause 4 exempts it from the consent diff
/// because it moves on every honest edit. Both were individually right and
/// jointly a hole: an archive whose rows are byte-identical to the victim's
/// except for `revision`, set to exactly clause 3's legal ceiling, applied with
/// `changes=0 destructive=0 issues=0` and **no dialog** — and one honest edit
/// later the row exceeded the ceiling and the user's own export would not
/// restore on a replacement device.
///
/// The gate's lesson is the shape of the fix: *the exemption criterion is sound
/// for a column whose value the merge **ignores** and unsound for one the merge
/// **reads**.* So the tests below are not one reproduction — they are the
/// criterion, applied:
///
/// - the ceiling arm (a value admitted today becomes unrestorable tomorrow),
/// - the freeze arm (a legal-but-large clock outranks every future correction),
/// - the noise arm, which is what the exemption existed for and must survive:
///   an ordinary correction still shows no clock at all,
/// - the same three on the `TT1:` share path, because both paths read the same
///   rule and a rule only one path enforces is the rule the next path
///   re-derives wrongly (§4.19.2),
/// - **L-12**, the second exemption in the same clause: a deactivation column
///   the destructive predicate had never been told about,
/// - **L-6**, the count that reads zero on exactly the import it is owed for,
///   whose root cause is a plan pass that mutates its own input.
void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  const victim = 'user-victim';
  const localProject = 'project-local';
  const localTag = 'tag-local';

  /// This device's clock during every import here — passed in rather than read
  /// so no bound drifts with the wall clock.
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

  Observation fieldRecord({int revision = 4, String? notes = 'clear signal'}) =>
      sampleObservation(
        id: 'obs-1',
        projectId: localProject,
        userId: victim,
        tagId: localTag,
        sessionId: null,
        latitude: 35.1983,
        longitude: -111.6513,
      ).copyWith(
        notes: notes,
        sync: sampleSync().copyWith(
          revision: revision,
          updatedAt: DateTime.utc(2026, 7, 20, 9),
          lastModifiedBy: victim,
          originDeviceId: 'device-victim-phone',
        ),
      );

  /// The victim's own genuine observation, on their own device.
  Future<Map<String, Object?>> seedFieldRecord({int revision = 4}) async {
    final columns = fieldRecord(revision: revision).toColumns();
    await db.insert(Tables.observations, columns);
    return columns;
  }

  Future<Map<String, Object?>> observationRow([String id = 'obs-1']) async {
    final rows = await db
        .query(Tables.observations, where: 'observation_id = ?', whereArgs: [id]);
    return rows.single;
  }

  Future<MergeReport> import(
    ProjectBackup backup, {
    bool confirmChanges = false,
  }) =>
      ProjectMerger(db).merge(
        backup,
        confirmChanges: confirmChanges,
        importingUserId: victim,
        now: now,
      );

  /// An archive carrying the victim's own row back at them, changed only where
  /// the caller says. This is the whole of L-2's payload: nothing is forged,
  /// nothing is out of range by clause 3's original reading, and the file is a
  /// legitimate export of the victim's own project with one integer edited.
  ProjectBackup archiveOf(Map<String, Object?> row) => makeBackup(
        {
          Tables.observations: [row],
        },
        projectId: localProject,
      );

  group('L-2 — the ceiling arm: a clock the device would later refuse', () {
    test('an archive changing nothing but the revision, to exactly the legal '
        'ceiling, is refused rather than applied silently', () async {
      final local = await seedFieldRecord();

      final report = await import(archiveOf({
        ...local,
        'revision': UntrustedImportRules.maxRevision,
      }));

      // §14.3's transcript read
      // `outcome=applied updated=1 destructiveChanges=0 changes=0 issues=0`.
      expect(report.totalUpdated, 0, reason: 'the transcript reported 1');
      expect(report.totalRefused, 1);
      expect(report.issues, isNotEmpty,
          reason: 'the transcript reported issues=0');
      expect((await observationRow())['revision'], 4);
    });

    test('the refusal names the reason — a row dropped from a disaster '
        'recovery gets a name, not just a number', () async {
      await seedFieldRecord();
      final report = await import(archiveOf({
        ...fieldRecord().toColumns(),
        'revision': UntrustedImportRules.maxRevision,
      }));

      final issue = report.issues.single;
      expect(issue.field, 'revision');
      expect(issue.primaryKeyValue, contains('obs-1'));
      expect(issue.message, contains('room'));
    });

    test('the bound admits only what this device could still edit and export: '
        'the record survives an honest edit and restores onto a replacement '
        'device', () async {
      await seedFieldRecord();
      await import(archiveOf({
        ...fieldRecord().toColumns(),
        'revision': UntrustedImportRules.maxRevision,
      }));

      // The honest edit §14.3 used: `revision = revision + 1`.
      await ObservationRepository(db).updateByKey(
        {'observation_id': 'obs-1', 'project_id': localProject},
        {'notes': 'corrected in the field'},
        actor: MutationActor.user(victim),
        now: now,
      );
      expect((await observationRow())['revision'], 5);

      final exported =
          await ProjectExporter.collect(db, localProject, now: now);

      final replacement = await AppDatabase.openInMemory();
      addTearDown(replacement.close);
      final restore = await ProjectMerger(replacement.raw).merge(
        exported,
        importingUserId: victim,
        now: now,
      );

      // §14.3: `inserted=3 refused=1 rows present=0`.
      expect(restore.totalRefused, 0,
          reason: 'the transcript reported 1; issues: ${restore.issues}');
      final restored = await replacement.raw.query(
        Tables.observations,
        where: 'observation_id = ?',
        whereArgs: ['obs-1'],
      );
      expect(restored, hasLength(1),
          reason: 'the transcript reported "rows present=0"');
      expect(restored.single['notes'], 'corrected in the field');
    });

    test('a device never writes a row it would itself refuse to import — the '
        'import bound leaves headroom below the storage bound', () {
      expect(
        UntrustedImportRules.maxImportedRevision,
        lessThan(UntrustedImportRules.maxRevision),
        reason: 'a bound that admits a value it will later refuse is not a '
            'bound; the gap is the device\'s own edit budget',
      );
    });
  });

  group('L-2 — the freeze arm: a clock nothing the file does explains', () {
    test('an archive whose only effect is to move the clock needs consent, and '
        'names the clock in the diff', () async {
      final local = await seedFieldRecord();

      final report = await import(archiveOf({...local, 'revision': 500}));

      expect(report.outcome, MergeOutcome.needsConfirmation);
      expect(report.wrote, isFalse);
      expect(
        report.destructiveChanges.map((c) => c.column),
        contains('revision'),
      );
      expect((await observationRow())['revision'], 4);
    });

    test('a jump no honest edit history explains needs consent even when the '
        'file also carries a real change', () async {
      final local = await seedFieldRecord();

      final report = await import(archiveOf({
        ...local,
        'revision': 4 + UntrustedImportRules.maxUnexplainedRevisionAdvance + 1,
        'notes': 'rewritten by the file',
      }));

      expect(report.outcome, MergeOutcome.needsConfirmation);
      expect(
        report.destructiveChanges.map((c) => c.column),
        containsAll(['revision', 'notes']),
      );
    });

    test('a refused poisoning leaves a teammate\'s genuine correction able to '
        'win', () async {
      final local = await seedFieldRecord();

      // The poisoning, declined at the gate.
      await import(archiveOf({...local, 'revision': 500}));

      // §14.3's second harm: after poisoning, every honest correction was
      // discarded as "local was newer" for the life of the project — the row
      // frozen against every teammate for the life of the project, reported as
      // *"Unchanged (local was newer)."*
      final correction = await import(
        archiveOf({
          ...local,
          'revision': 7,
          'updated_at': DateTime.utc(2026, 8, 1).toIso8601String(),
          'magnetic_bearing': 151.0,
        }),
        confirmChanges: true,
      );

      expect(correction.totalSkipped, 0,
          reason: 'the transcript reported `updated=0 skipped=1`');
      expect(correction.totalUpdated, 1);
      expect((await observationRow())['magnetic_bearing'], 151.0);
    });
  });

  group('L-2 — the noise arm: the exemption existed for a reason', () {
    test('an ordinary correction does not mention the clock', () async {
      final local = await seedFieldRecord();

      final report = await import(archiveOf({
        ...local,
        'revision': 7,
        'updated_at': DateTime.utc(2026, 8, 1).toIso8601String(),
        'last_modified_by': 'user-colleague',
        'notes': 'signal re-checked',
      }));

      expect(report.outcome, MergeOutcome.needsConfirmation,
          reason: 'replacing the notes is destructive and needs consent');
      expect(
        report.destructiveChanges.map((c) => c.column),
        ['notes'],
        reason: 'a one-word note correction must not render as a four-field '
            'overwrite — that is the prompt the user learns to dismiss',
      );
    });

    test('filling an empty column alongside an ordinary clock advance needs no '
        'consent at all', () async {
      final local = await seedFieldRecord();
      await db.update(Tables.observations, {'notes': null},
          where: 'observation_id = ?', whereArgs: ['obs-1']);

      final report = await import(archiveOf({
        ...local,
        'revision': 5,
        'updated_at': DateTime.utc(2026, 8, 1).toIso8601String(),
        'notes': 'added by a colleague',
      }));

      expect(report.outcome, MergeOutcome.applied);
      expect(report.destructiveChanges, isEmpty);
      expect((await observationRow())['notes'], 'added by a colleague');
    });
  });

  /// Finding **M-17** (§16.3), and the class rather than the number.
  ///
  /// L-2's freeze arm bounded the advance with a *flat* 1000, so the arm was
  /// closed above it and open below it: an archive filling one empty column —
  /// an addition, so no consent is owed for it — while advancing `revision` by
  /// exactly 1000 applied with **no dialog and no mention of the clock**, and
  /// the row was then 1000 versions ahead of every other device's copy, so a
  /// teammate's genuine correction afterwards lost the comparison and was
  /// reported as skipped.
  ///
  /// **The exemption is not the defect and is deliberately still here.**
  /// `revision` moves on every honest edit; listing it column-by-column would
  /// make the dialog fire on every legitimate import, and a dialog people learn
  /// to dismiss protects nobody. The exemption reasoned about the field's
  /// *visibility*; the harm lives in its *magnitude*. So the allowance is now
  /// proportional to what the user is being shown, capped by the old flat bound.
  ///
  /// Both halves are proved here, because a fix that makes every import prompt
  /// has traded a rare harm for a habit of dismissing warnings.
  group('M-17 — the advance must be explained by what the user is shown', () {
    /// The measurement transcript §16.3 recorded, re-run against the fix.
    /// Printed rather than only asserted so the next reader can compare it to
    /// the one in the record without reconstructing the harness.
    Future<MergeReport> advanceBy(int advance, {required String label}) async {
      final local = await seedFieldRecord();
      await db.update(Tables.observations, {'notes': null},
          where: 'observation_id = ?', whereArgs: ['obs-1']);

      final report = await import(archiveOf({
        ...local,
        'revision': 4 + advance,
        'updated_at': DateTime.utc(2026, 8, 1).toIso8601String(),
        'notes': 'filled in by the file',
      }));

      // ignore: avoid_print
      print('advance=+$advance with one addition ($label): '
          'outcome=${report.outcome.name} '
          'changes=${report.changes.length} '
          'destructive=${report.destructiveChanges.length} '
          'stored revision=${(await observationRow())['revision']}');
      return report;
    }

    test('+1000 alongside one filled column is surfaced, not applied silently',
        () async {
      final report = await advanceBy(1000, label: 'M-17\'s payload');

      expect(report.outcome, MergeOutcome.needsConfirmation,
          reason: '§16.3 measured `outcome=applied` with the clock unshown');
      expect(report.destructiveChanges.map((c) => c.column),
          contains('revision'));
      expect((await observationRow())['revision'], 4,
          reason: 'nothing is written until the user says yes');
    });

    test('+5 alongside one filled column is still silent — the exemption\'s '
        'own purpose survives', () async {
      final report = await advanceBy(5, label: 'an ordinary honest import');

      expect(report.outcome, MergeOutcome.applied);
      expect(report.destructiveChanges, isEmpty,
          reason: 'a prompt that always fires is one the user learns to '
              'dismiss, which is what the exemption existed to prevent');
      expect((await observationRow())['notes'], 'filled in by the file');
    });

    test('the allowance scales with the diff: the same advance is explained by '
        'a large honest change set and not by a single addition', () {
      bool unexplained(int advance, int otherChanges) =>
          UntrustedImportRules.isUnexplainedRevisionAdvance(
            was: 4,
            becomes: 4 + advance,
            otherChanges: otherChanges,
          );

      expect(unexplained(200, 1), isTrue, reason: 'one change cannot buy 200');
      expect(unexplained(200, 8), isFalse,
          reason: 'eight columns of genuine divergence can');
      expect(unexplained(0, 0), isFalse,
          reason: 'a clock that does not advance destroys nothing');
      expect(unexplained(1, 0), isTrue,
          reason: 'arm (1) is unchanged: nothing else changed, so nothing '
              'explains the clock');
      expect(
        unexplained(UntrustedImportRules.maxUnexplainedRevisionAdvance + 1, 500),
        isTrue,
        reason: 'the old flat bound survives as an absolute cap — no quantity '
            'of visible changes explains an advance past it',
      );
    });

    test('a teammate\'s later correction to that row still applies', () async {
      final local = await seedFieldRecord();

      // The poisoning, now stopped at the gate rather than applied.
      await import(archiveOf({
        ...local,
        'notes': null,
        'revision': 1004,
      }));

      final correction = await import(
        archiveOf({
          ...local,
          'revision': 5,
          'updated_at': DateTime.utc(2026, 8, 1).toIso8601String(),
          'magnetic_bearing': 151.0,
        }),
        confirmChanges: true,
      );

      expect(correction.totalSkipped, 0,
          reason: '§16.3: `teammate correction at revision 5 -> skipped=1`');
      expect(correction.totalUpdated, 1);
      expect((await observationRow())['magnetic_bearing'], 151.0);
    });

    test('the sweep\'s own find: a payload moving only updated_at, the merge\'s '
        'tiebreak, is judged too', () async {
      final local = await seedFieldRecord();

      final report = await import(archiveOf({
        ...local,
        'updated_at': now.add(const Duration(minutes: 4)).toIso8601String(),
      }));

      // ignore: avoid_print
      print('updated_at +4min alone: outcome=${report.outcome.name} '
          'changes=${report.changes.length} '
          'stored updated_at=${(await observationRow())['updated_at']}');

      expect(report.outcome, MergeOutcome.needsConfirmation,
          reason: 'measured before the fix: `outcome=applied changes=0` and a '
              'falsified timestamp on disk, with no dialog');
      expect(report.changes.map((c) => c.column), contains('updated_at'));
      expect((await observationRow())['updated_at'],
          DateTime.utc(2026, 7, 20, 9).toIso8601String());
    });

    test('an honest whole-project restore of 30 diverged rows adds no clock '
        'line anywhere — run, not asserted', () async {
      // Every row is what an ordinary season of fieldwork leaves behind: a
      // handful of edits since this device's copy, one or two columns actually
      // different, and one column that was empty here and is filled there.
      final rows = <Map<String, Object?>>[];
      for (var i = 0; i < 30; i++) {
        final row = fieldRecord().toColumns()
          ..['observation_id'] = 'obs-honest-$i'
          ..['notes'] = null;
        await db.insert(Tables.observations, row);
        rows.add({
          ...row,
          'revision': 4 + (i % 9) + 1,
          'updated_at': DateTime.utc(2026, 8, 1).toIso8601String(),
          'notes': 'field note $i',
        });
      }

      final report = await import(makeBackup(
        {Tables.observations: rows},
        projectId: localProject,
      ));

      // ignore: avoid_print
      print('honest 30-row restore: outcome=${report.outcome.name} '
          'updated=${report.totalUpdated} '
          'changes=${report.changes.length} '
          'destructive=${report.destructiveChanges.length}');

      expect(report.outcome, MergeOutcome.applied,
          reason: 'no dialog is owed: every change is an addition');
      expect(report.totalUpdated, 30);
      expect(
        report.changes.map((c) => c.column).toSet(),
        {'notes'},
        reason: 'not one clock column appears in 30 honestly diverged rows',
      );
    });
  });

  group('the exemption sweep — clause 4\'s list, re-derived', () {
    test('a column is exempt only if it moves on every honest edit AND the '
        'merge does not read it', () {
      for (final column in UntrustedImportRules.columnsMovedByEveryEdit) {
        final read = UntrustedImportRules.columnsTheMergeReads.contains(column);
        expect(
          UntrustedImportRules.consentDiffExempt.contains(column),
          !read,
          reason: '$column: exemption must follow from the criterion, not '
              'from a hand-maintained list',
        );
      }
    });

    test('the merge clock is not exempt, and last_modified_by still is', () {
      expect(UntrustedImportRules.consentDiffExempt, {'last_modified_by'});
      expect(UntrustedImportRules.mergeClockColumns,
          containsAll(['revision', 'updated_at']));
    });

    test('every column the merge reads is either bounded or restated — none is '
        'both attacker-chosen and invisible', () {
      // `origin_device_id` is the documented final tiebreak, so it is read;
      // K-8 already removed it from the exemption. This asserts the two lists
      // cannot drift back together.
      expect(
        UntrustedImportRules.columnsTheMergeReads
            .intersection(UntrustedImportRules.consentDiffExempt),
        isEmpty,
      );
    });
  });

  group('the same rule on the TT1: share path', () {
    final observer = sampleUser(id: victim, email: 'victim@example.org');

    Future<SharedObservationImportResult> paste(String payload) =>
        SharedObservationImporter(db).save(
          ObservationShare.decode(payload, now: now),
          projectId: localProject,
          tagId: localTag,
          receivingUserId: victim,
          receivingDeviceId: 'device-receiver',
          newId: () => 'minted-id',
          now: now,
        );

    test('a payload at the legal ceiling is refused by the decoder', () {
      final payload = ObservationShare.encode(
        fieldRecord(revision: UntrustedImportRules.maxRevision),
        tag: sampleTag(id: localTag),
        observer: observer,
      );

      expect(
        () => ObservationShare.decode(payload, now: now),
        throwsA(isA<ObservationShareFormatException>()),
      );
    });

    test('a payload whose only effect is to move the clock needs consent',
        () async {
      await seedFieldRecord();
      final payload = ObservationShare.encode(
        fieldRecord(revision: 500),
        tag: sampleTag(id: localTag),
        observer: observer,
      );

      final result = await paste(payload);

      expect(result.outcome,
          SharedObservationImportOutcome.changeNeedsConfirmation);
      expect(result.changes.map((c) => c.column), contains('revision'));
      expect((await observationRow())['revision'], 4);
    });

    test('an ordinary re-share does not mention the clock', () async {
      await seedFieldRecord();
      final payload = ObservationShare.encode(
        fieldRecord(revision: 7, notes: 'signal re-checked'),
        tag: sampleTag(id: localTag),
        observer: observer,
      );

      final result = await paste(payload);

      expect(
        result.changes.where((c) => c.isDestructive).map((c) => c.column),
        ['notes'],
      );
    });
  });

  group('L-12 — the deactivation column the predicate did not know', () {
    setUp(() async {
      await db.insert(
        Tables.projectMemberships,
        sampleMembership(projectId: localProject, userId: victim).toColumns(),
      );
    });

    test('an archive setting Project_Memberships.end_date needs consent',
        () async {
      final local = (await db.query(Tables.projectMemberships)).single;

      final report = await import(makeBackup(
        {
          Tables.projectMemberships: [
            {
              ...local,
              'end_date': DateTime.utc(2026, 8, 1).toIso8601String(),
              'revision': 5,
            },
          ],
        },
        projectId: localProject,
      ));

      expect(report.outcome, MergeOutcome.needsConfirmation);
      expect(
        report.destructiveChanges.map((c) => c.column),
        contains('end_date'),
      );
      expect((await db.query(Tables.projectMemberships)).single['end_date'],
          isNull);
    });

    test('the predicate derives from a declared set, not a hand-written name',
        () {
      // The shape clause 2 already has: `SyncTable.identityUserColumns` is the
      // declared complete set, so a table that gains a column inherits the
      // clause rather than needing someone to remember it.
      for (final table in syncTables) {
        expect(table.deactivationColumns, contains('deleted_at'),
            reason: '${table.name}: every table soft-deletes');
      }
      expect(
        syncTablesByName[Tables.projectMemberships]!.deactivationColumns,
        containsAll(['deleted_at', 'end_date']),
      );
      expect(assertEveryDeactivationColumnExists, returnsNormally);
    });

    test('a tombstone on a live row is still destructive on every table', () {
      for (final table in syncTables) {
        expect(
          UntrustedImportRules.isDestructiveChange(
            table: table.name,
            column: 'deleted_at',
            was: null,
            becomes: '2026-08-01T00:00:00.000Z',
          ),
          isTrue,
          reason: table.name,
        );
      }
    });
  });

  group('L-6 — a plan pass that mutates its own input', () {
    /// A `Users` row claiming the victim's address under an id of the file's
    /// choosing, with a row attributed to that id — §13.2's fact (d), which
    /// §4.19.2 says is owed a count.
    ProjectBackup reattributingArchive() => makeBackup(
          {
            Tables.users: [
              sampleUser(id: 'user-from-file', email: 'victim@example.org')
                  .toColumns(),
            ],
            Tables.observations: [
              {
                ...fieldRecord().toColumns(),
                'user_id': 'user-from-file',
                'last_modified_by': 'user-from-file',
                'revision': 9,
                'updated_at': DateTime.utc(2026, 8, 1).toIso8601String(),
                'magnetic_bearing': 151.0,
              },
            ],
          },
          projectId: localProject,
        );

    test('the dedup count is not zero on the second, confirming pass', () async {
      await seedFieldRecord();
      final backup = reattributingArchive();

      final first = await import(backup);
      expect(first.outcome, MergeOutcome.needsConfirmation);
      expect(first.usersDeduped, 1);
      expect(first.rowsReattributed, greaterThan(0));

      final second = await import(backup, confirmChanges: true);
      expect(second.outcome, MergeOutcome.applied);
      expect(second.usersDeduped, 1,
          reason: '§14.9: the count reads 0 on exactly the import §4.19.2 says '
              'it is owed for');
      expect(second.rowsReattributed, first.rowsReattributed);
    });

    test('merge does not mutate the payload it was given', () async {
      await seedFieldRecord();
      final backup = reattributingArchive();
      final before = [
        for (final row in backup.rowsFor(Tables.observations))
          Map<String, Object?>.of(row),
      ];

      await import(backup);

      expect(backup.rowsFor(Tables.observations), before);
    });
  });
}
