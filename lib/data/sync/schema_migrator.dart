import '../db/migrations.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

/// Migrates a decoded backup's *row payload* forward from the schema version it
/// was written at to the schema version this app runs (technical doc:
/// "Validate `schema_version` and migrate forward if older").
///
/// This is deliberately separate from the DB [migrations] (which run DDL on the
/// live database). A backup carries rows, not a database, so migrating it means
/// reshaping the column-maps to match the current columns — adding the columns
/// newer schema versions introduced, with their documented defaults. A row that
/// already has a column (e.g. a v2 backup) is left untouched.
///
/// Each step mirrors exactly one entry in [migrations]; the additive
/// ALTER-with-DEFAULT columns are the ones that need a value supplied here.
abstract final class SchemaMigrator {
  /// Rewrites [backup]'s rows in place to the current [latestSchemaVersion].
  ///
  /// - Refuses a payload from a **newer** major ([SchemaTooNewException]) — this
  ///   build cannot know what a future major changed.
  /// - **Migrates an older major forward**, rather than refusing it. See below.
  /// - Applies each intermediate step for an older minor.
  /// - Leaves a *newer* minor's rows alone: their extra columns are not dropped
  ///   here and are held verbatim by `UnknownColumnStore` when the merger writes
  ///   them (task 10.18). Dropping them is precisely the data loss the exact-
  ///   equality policy used to exist to prevent.
  ///
  /// **Why an older major is accepted here when the wire refuses it outright**
  /// (task 10.35, the first major bump). This is deliberately asymmetric with
  /// `SyncEnvelope.fromJson`, which rejects any major mismatch in either
  /// direction, and the asymmetry is not a convenience:
  ///
  /// - The wire refusal exists because two *live peers* must agree on a shape
  ///   neither of them controls, and a disagreement mid-conversation has no
  ///   safe resolution. Reading an archive is one-way and settled: the reader
  ///   knows strictly more than the writer did, and nothing is negotiating.
  /// - Refusing would make every archive written before the bump unreadable —
  ///   including the cloud backups task 10.19 turns on by default. That is a
  ///   larger and more certain data loss than anything the refusal prevents.
  ///
  /// It is only safe because each crossing is lossless, which is a property
  /// of the particular bump and not a general licence. **All three bumps so
  /// far can say it.** Major 4 (task 11.242) is the easy one: it begins at
  /// schema v16, and the v15→v16 step below was written by task 11.240 as the
  /// archive's own path *before* the boundary was moved onto it — one
  /// individual per tag, keyed by the tag, colour carried across verbatim
  /// (`schema_migrator_test.dart`'s v16 group). The bump changed what the
  /// *wire* refuses and nothing about what an archive holds. The other two
  /// take more arguing. Major 2 re-keyed six tables to
  /// `(<id>, project_id)`, and `project_id` was already a `NOT NULL` column
  /// on every one of those rows. Major 3 (task 11.219) gave `Tags` and
  /// `Tag_Versions` a `project_id` they did not have — but **an archive is
  /// one project's data**: `ProjectExporter` collects every project-scoped
  /// table `WHERE scope = ?`, so an archive's `Project_Tags` rows name only
  /// the manifest project and every tag it carries is that project's. The
  /// new key is *derived from data the archive already carries*; nothing is
  /// invented or defaulted, and the fork §3.3 describes for a device
  /// **cannot arise in an archive on its own** — but **the importing device
  /// can supply one** (task 11.239, 2026-09-13). A device that forked a
  /// shared collar holds the archive's project's copy under a *new* id, and
  /// this step keys the archive's row under the *old* one; nothing here can
  /// know they are one collar, because the payload is this step's only
  /// witness. The match is made where the device's `lineage_id` can be
  /// read — `ProjectMerger._matchForkedTags` — and was measured putting the
  /// same animal in a project twice before it existed. So the crossing is
  /// lossless *and* it is not the whole story; the sentence used to stop at
  /// "cannot arise", which was true of the archive and false of the import.
  /// A future major that cannot say the same must add its own guard here
  /// rather than inherit this one — hence [_lowestMigratableMajor] being an
  /// explicit constant with this reasoning attached, instead of an unbounded
  /// `major <= current`.
  ///
  /// Returns the version it migrated *from* (for the merge report), or the
  /// current version if nothing was needed.
  static int migrateToCurrent(ProjectBackup backup) {
    final from = backup.manifest.schemaVersion;
    final to = latestSchemaVersion;
    final major = backup.manifest.schemaMajor;
    if (major > schemaMajorVersion) {
      throw SchemaTooNewException(backupVersion: from, appVersion: to);
    }
    if (major < _lowestMigratableMajor) {
      throw BackupFormatException(
        'Backup schema major v$major predates this app (v$schemaMajorVersion) '
        'and cannot be migrated forward.',
      );
    }
    // The minor is also the migration counter and never resets across a major
    // (see [latestSchemaVersion]), so one ascending loop crosses the major
    // boundary without needing to know where it is.
    for (var v = from + 1; v <= to; v++) {
      _applyStep(
        v,
        backup.tables,
        manifestProjectId: backup.manifest.projectId,
      );
    }
    return from;
  }

  /// The oldest schema major whose archives this build can still read.
  ///
  /// Every major from here to [schemaMajorVersion] must have a forward path
  /// expressible as row-payload steps in [_applyStep]. Raise this only when
  /// there is no such path at all — and when raising it, say so in the
  /// release notes, because it is the point at which someone's old backup
  /// stops opening.
  ///
  /// ## The word that used to be here was "lossless", and major 5 is not
  ///
  /// This contract said *lossless*, and majors 2, 3 and 4 could each say it
  /// (the argument is in [migrateToCurrent]). **Major 5 cannot, on purpose.**
  /// Task 11.243 deletes `Tags.date_put_on`, `date_removed`, `capture_date`
  /// and `individual_id` and writes no path that carries them into
  /// `Deployments` rows — design §9, because Michael is wiping every device
  /// and the beta server, all of which hold development data only.
  ///
  /// **So the rule is amended rather than quietly broken**, and the amendment
  /// has a bound: *this* crossing is lossy because the data it discards was
  /// being discarded everywhere else in the same change. **A future lossy
  /// crossing must argue its own case here rather than inherit this one** —
  /// and the honest alternative, if it cannot, is to raise this constant and
  /// refuse the archive outright, which is a refusal a person can act on
  /// where a silent partial import is not.
  static const int _lowestMigratableMajor = 1;

  /// Applies the row-shape changes introduced *at* schema version [version].
  static void _applyStep(
    int version,
    Map<String, List<Map<String, Object?>>> tables, {
    required String manifestProjectId,
  }) {
    switch (version) {
      case 2:
        // v2 added two Projects columns with defaults (see schemaV2Statements).
        for (final row in tables[Tables.projects] ?? const []) {
          row.putIfAbsent('coordinate_format', () => 'dd');
          row.putIfAbsent('triangulation_window_minutes', () => 15);
        }
      case 4:
        // v4 added Tags.color_hex; backfill distinct round-robin colors by
        // row order (mirrors the rowid-based backfill in schemaV4Statements).
        final tagRows = tables[Tables.tags] ?? const [];
        for (var i = 0; i < tagRows.length; i++) {
          tagRows[i].putIfAbsent(
              'color_hex', () => TagColorPalette.colorForIndex(i));
        }
      case 6:
        // Nothing to do, and that is the point rather than an omission.
        //
        // v6 (major 2) re-keyed six tables to `(<id>, project_id)`. A backup
        // carries rows, not a schema, and every one of those rows already had
        // `project_id` as a `NOT NULL` column — so the row payload at v5 is
        // byte-identical to a valid v6 payload. The merger derives the new key
        // from `SyncTable.primaryKey` when it upserts, and finds both halves
        // already present.
        //
        // Stated explicitly so the empty case reads as "checked, nothing
        // needed" rather than "the author forgot"; it is also what makes the
        // cross-major read in [migrateToCurrent] safe, so it should not be
        // deleted as dead code.
        break;
      case 14:
        // **v14 (major 3, task 11.219): tags become project-scoped.**
        //
        // The one place the design says the fork logic is definitely needed
        // regardless of what any database holds — because an archive written
        // last week is a v13 payload forever. What it turns out to need is
        // not a fork **here**. It needs a *match* later, on the device: a
        // device that has already forked holds this project's copy of the
        // collar under a fresh id, and the row this step keys under the old
        // id would sit beside it as a second tag for one animal. Task 11.239
        // measured exactly that (2026-09-13) and put the repair in
        // `ProjectMerger._matchForkedTags`, which is the only reader that
        // can see both the payload and the device's `lineage_id`.
        //
        // **An archive is one project's data.** `ProjectExporter` collects
        // every project-scoped table `WHERE scope = ?`, so a v13 archive's
        // `Project_Tags` rows all name the manifest project, and every
        // `Tags` row it carries is reachable from that project's rows. So
        // the scope of every tag in the payload is the manifest project, and
        // §3.3's "order the links by `created_at` and fork the later ones"
        // has nothing to order: there is only ever one.
        //
        // `lineage_id` is the tag's own id and `copied_at` is null, exactly
        // as the device migration sets them and for the same reasons: the id
        // is already unique and already unguessable, and a tag that was
        // always in one project was not copied.
        final projectId = manifestProjectId;
        for (final row in tables[Tables.tags] ?? const []) {
          row.putIfAbsent('project_id', () => projectId);
          row.putIfAbsent('lineage_id', () => row['tag_id']);
          row.putIfAbsent('copied_at', () => null);
        }
        for (final row in tables[Tables.tagVersions] ?? const []) {
          row.putIfAbsent('project_id', () => projectId);
        }
        // `Project_Tags` left the wire with this version. Its rows stay in
        // the *device's* database as the record of what the migration did
        // (§3.5) — but the merger walks `syncTables`, which no longer
        // contains it, so leaving them in the payload would be a table the
        // reader silently ignores. Dropped here so an archive read at v14
        // says what it holds.
        tables.remove(Tables.projectTags);
      case 15:
        relinkNonDetections(tables);
      case 16:
        backfillIndividuals(tables);
      case 17:
        dropDeploymentColumnsFromTags(tables);
      case 19:
        emptyZeroEllipses(tables);
      case 20:
        // Task 11.331: `Projects.time_zone` and `Deployments.time_zone`
        // arrive. **Nothing is filled in here, on purpose.** The device's
        // own v20 step decides each row's zone from the project's area and
        // this phone's clock; an archive is somebody else's rows from
        // somewhere else, and guessing where its days were typed would put a
        // claim into the record nobody made. Left null, every reader treats
        // them as a build before v20 did — in the reading phone's zone — and
        // the project's zone is derived from its area (`Project.timeZone`).
        break;
      // Future versions: add a case mirroring the new migration's defaults.
    }
  }

  /// **v19 (task 11.323, major 6): an estimate with no ellipse says so.**
  ///
  /// Mirrors the device's `schemaV19Statements`: a row whose axes are not
  /// both greater than zero — the 0 × 0 the app wrote for a two-bearing
  /// estimate before v19 — has all three ellipse columns emptied, and a real
  /// ellipse is left exactly as it was. **Lossless**: 0 × 0 never meant a
  /// measurement, and the row it replaces is one the sync rules refuse, so
  /// an imported archive would otherwise bring back a record that can never
  /// leave the phone.
  static void emptyZeroEllipses(
    Map<String, List<Map<String, Object?>>> tables,
  ) {
    for (final row in tables[Tables.estimatedPositions] ?? const []) {
      final major = row['semi_major_axis'];
      final minor = row['semi_minor_axis'];
      final present = major is num && minor is num && major > 0 && minor > 0;
      if (present) continue;
      row['semi_major_axis'] = null;
      row['semi_minor_axis'] = null;
      row['rotation_angle'] = null;
    }
  }

  /// **v17 (task 11.243, major 5): a tag is equipment, so four columns leave
  /// its rows — and nothing replaces them.**
  ///
  /// Mirrors the device's `schemaV17Statements`, which is what every step in
  /// this file does and what makes the two readers of an archive agree. The
  /// device's v17 migration drops these columns and creates no deployments;
  /// so does this. **An archive imported after the wipe therefore lands in
  /// exactly the state it would have been in had it been on the device
  /// through the migration**, which is the property that matters.
  ///
  /// ## It is lossy, and that is the decision rather than an accident
  ///
  /// Every earlier step adds a column and its default, or repairs a value.
  /// This one **throws information away**: when a collar went on, when it
  /// came off, and which animal wore it. Design §9 is that decision — Michael
  /// is wiping every device and the beta server, all of which hold
  /// development data only, so a path that carried the dates into
  /// `Deployments` rows would be machinery serving nothing and would then
  /// have to be kept correct forever.
  ///
  /// See [_lowestMigratableMajor], whose "lossless" contract this is the
  /// first exception to, and which now says so in its own words rather than
  /// leaving this to be discovered.
  ///
  /// **No `Deployments` rows are synthesised**, deliberately. A v16 archive
  /// carries a `date_put_on` and an `individual_id` on every tag, so one
  /// could be built for each — and it would then exist on the importing
  /// device and *not* on the device that wrote the archive, whose own
  /// migration deleted it. Two devices disagreeing about a project's history
  /// is worse than both of them forgetting it.
  ///
  /// Idempotent: a row with none of these columns is untouched. Returns how
  /// many rows it stripped, so a test can assert it.
  static int dropDeploymentColumnsFromTags(
    Map<String, List<Map<String, Object?>>> tables,
  ) {
    const dropped = [
      'date_put_on',
      'date_removed',
      'capture_date',
      'individual_id',
    ];
    var stripped = 0;
    for (final row in tables[Tables.tags] ?? const <Map<String, Object?>>[]) {
      var touched = false;
      for (final column in dropped) {
        if (row.remove(column) != null) touched = true;
      }
      if (touched) stripped++;
    }
    return stripped;
  }

  /// **v15 (task 11.225, carried here by task 10.87): re-point a "no signal"
  /// entry's listened-for ids that v14's fork left dangling.**
  ///
  /// **This is the first step in this migrator that repairs content rather
  /// than shape.** Every earlier case adds a column and its default; this one
  /// rewrites a value. The difference is worth a sentence because the
  /// reasoning that makes the shape steps safe — *the row payload is
  /// byte-identical to a valid newer payload* — does not apply, and a future
  /// step of this kind has to argue its own safety rather than inherit it.
  ///
  /// **What it repairs.** A device on v14 that held a collar in two projects
  /// forked it: one project kept the tag id, the other got a copy with a new
  /// id and the original's `lineage_id`. Its `Non_Detections` rows in the
  /// copy's project went on naming the original id — a row that project no
  /// longer holds. Task 11.225 repaired that in the *device's* database at
  /// v15; an archive written by that device at v14 still carries the
  /// dangling ids, and nothing on the way in re-derived them. This does.
  ///
  /// **Mirrors `NonDetectionRelinkMigration.relink` and keeps its scoping.**
  /// Per row, per listened-for id, filtered to the row's own `project_id`:
  /// *does this project's payload hold a `Tags` row with this id* — if not,
  /// *does this project's payload hold a `Tags` row with this `lineage_id`*.
  /// Never *which projects hold this lineage* — that is the query Security
  /// Model §5.9(b) forbids, and the same scoping is what discharges the
  /// sealed-column obligation there. An archive is one project's data, so the
  /// filter is nearly a tautology here; it is written anyway, so the two
  /// readers can be compared line for line and so a payload that somehow
  /// carried a second project's tags could not cross-link through this step.
  ///
  /// **The payload is the only witness, and that is enough for the case this
  /// exists for.** The copy's `lineage_id` is the original's `tag_id`, so a
  /// v14 archive of the copy's project resolves every dangling id against its
  /// own `Tags` rows. What it cannot see is the *importing* device's tags —
  /// and it does not need to: an id that resolves nowhere in the payload is
  /// left as it is, exactly as the device migration leaves one with no
  /// same-lineage row, and the merger then holds a row naming a tag this
  /// project does not have, which is the state it was in before this step and
  /// no worse.
  ///
  /// Idempotent: after one pass every id names a payload row in its own
  /// project, so a second pass rewrites nothing. Returns how many ids it
  /// rewrote, so a test can assert it and a caller can log it.
  /// **v16 (task 11.240): one individual per tag, keyed by the tag's id.**
  ///
  /// Mirrors `schemaV16Statements` line for line, and for the reason that
  /// migration gives for `individual_id = tag_id`: the device, the server
  /// and this step each backfill the same project, and deriving the id from
  /// the tag's is what makes the three agree without talking. An archive
  /// written at v15 of a project a v16 device already holds therefore lands
  /// its individuals on the rows the device already created, rather than
  /// beside them.
  ///
  /// Like v15 this repairs content, not only shape: it reads a tag's
  /// `color_hex`, moves it to the individual, and nulls it — the column is
  /// retired and a v16 payload must not carry a value in it that a reader
  /// could mistake for the colour. The status is the backfill's default
  /// (active collar → alive, anything else → unknown), a default and not a
  /// claim. **No name-matching**: two tags called "Marie" become two
  /// individuals, exactly as on the device.
  ///
  /// Idempotent: a tag that already names an individual is left alone, **and
  /// so is one whose individual is already in the payload.**
  ///
  /// **The second half was added by task 11.243 and is not belt-and-braces.**
  /// This step wrote `individual_id` onto the tag and read it back to decide
  /// whether it had run — which stopped working the moment v17 took that
  /// column off again: a payload migrated twice (the merger migrates what a
  /// caller may already have migrated) ran this step a second time, saw no
  /// link, and minted a second individual under the same key. The merge then
  /// failed on a UNIQUE violation, and the whole import with it.
  ///
  /// So the test is now *"is the row already there"*, which is the question
  /// that was always meant and does not depend on a column surviving a later
  /// migration. **A step that decides whether it has run by reading a value a
  /// later step deletes is a step that runs twice**, and the deletion is
  /// three schema versions away from the code that assumed it.
  ///
  /// Returns how many individuals it created.
  static int backfillIndividuals(
    Map<String, List<Map<String, Object?>>> tables,
  ) {
    final individuals = tables.putIfAbsent(
      Tables.individuals,
      () => <Map<String, Object?>>[],
    );
    final present = {
      for (final i in individuals) (i['individual_id'], i['project_id']),
    };
    var created = 0;
    for (final row in tables[Tables.tags] ?? const <Map<String, Object?>>[]) {
      if (row['individual_id'] != null) continue;
      final tagId = row['tag_id'];
      if (tagId is! String) continue;
      if (!present.add((tagId, row['project_id']))) continue;
      final colour = row['color_hex'];
      individuals.add({
        'individual_id': tagId,
        'project_id': row['project_id'],
        'name': row['tag_name'],
        'color_hex': colour is String && colour.isNotEmpty
            ? colour
            : TagColorPalette.colorForIndex(created),
        'status': row['status'] == TagStatus.active.db
            ? IndividualStatus.alive.db
            : IndividualStatus.unknown.db,
        'species': null,
        'sex': null,
        'notes': null,
        'lineage_id': tagId,
        'copied_at': null,
        'created_at': row['created_at'],
        'updated_at': row['updated_at'],
        'deleted_at': row['deleted_at'],
        'revision': 0,
        'last_modified_by': row['last_modified_by'],
        'origin_device_id': row['origin_device_id'],
      });
      row['individual_id'] = tagId;
      row['color_hex'] = null;
      created++;
    }
    return created;
  }

  static int relinkNonDetections(
    Map<String, List<Map<String, Object?>>> tables,
  ) {
    final column = unvalidatedIdListColumns[Tables.nonDetections];
    if (column == null) {
      throw StateError(
        'unvalidatedIdListColumns no longer names ${Tables.nonDetections}; '
        'this step repairs exactly that column and must be updated rather '
        'than silently repair nothing.',
      );
    }
    final tags = tables[Tables.tags] ?? const <Map<String, Object?>>[];
    var rewrittenIds = 0;
    for (final row in tables[Tables.nonDetections] ?? const []) {
      final projectId = row['project_id'];
      final Object? raw = row[column];
      final List<String> ids;
      try {
        ids = DbCodec.decodeStringList(raw);
      } on Object {
        // Malformed; RowValidator refuses the row later and says why. Not
        // this step's job to decide.
        continue;
      }
      if (ids.isEmpty) continue;
      var changed = false;
      final rewritten = <String>[];
      for (final id in ids) {
        // Scoped to the row's own project — see the doc comment.
        final resolves = tags.any(
          (t) => t['tag_id'] == id && t['project_id'] == projectId,
        );
        if (resolves) {
          rewritten.add(id);
          continue;
        }
        final ownCopy = tags.cast<Map<String, Object?>?>().firstWhere(
          (t) => t!['project_id'] == projectId && t['lineage_id'] == id,
          orElse: () => null,
        );
        final replacement = ownCopy?['tag_id'];
        if (replacement is String) {
          rewritten.add(replacement);
          changed = true;
          rewrittenIds++;
        } else {
          rewritten.add(id);
        }
      }
      if (changed) row[column] = DbCodec.encodeStringList(rewritten);
    }
    return rewrittenIds;
  }
}
