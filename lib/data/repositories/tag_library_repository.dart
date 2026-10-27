import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

import '../db/schema.dart';
import '../models/tag_library_entry.dart';

/// The device's personal tag library — task 11.219.
///
/// ## Why this is not a [BaseRepository]
///
/// Every other repository extends it for three things: the soft-delete
/// convention, revision bookkeeping, and **a `MutationRule` plus the project
/// role gradient**. The first two apply here; the third has no meaning at
/// all. `Tag_Library` is device-local — it is in neither `syncTables` nor
/// `tableSpecs`, and no row of it is ever pushed, pulled or archived — so
/// there is no project to resolve a role against and no server to be
/// advisory towards.
///
/// Extending `BaseRepository` anyway would mean declaring a `MutationRule`
/// for a table no rule governs, and `syncTablesByName[table]` returning null
/// for the scope column. Both would work by accident: the gradient would
/// return early on a null project and the rule would never be consulted.
/// **A permission check that passes because its subject does not exist is
/// exactly the shape this project keeps finding in its own instruments**, so
/// the honest thing is not to claim one.
///
/// ## What is not here
///
/// No versions. A `Tag_Versions` row records what a collar read when a
/// bearing was taken against it, and nothing is ever recorded against a
/// library entry — the history lives beside the project copy that has the
/// bearings. See [TagLibraryEntry].
class TagLibraryRepository {
  TagLibraryRepository(this.db);

  /// Either the app's `Database` or a transaction running inside it — the
  /// same widening `BaseRepository` takes, so a copy-into-a-project that has
  /// to be atomic can compose this with the tag write.
  final DatabaseExecutor db;

  static const table = kTagLibraryTable;

  Future<void> insert(TagLibraryEntry entry) async {
    await db.insert(
      table,
      entry.toColumns(),
      conflictAlgorithm: ConflictAlgorithm.abort,
    );
  }

  Future<TagLibraryEntry?> findById(
    String tagId, {
    bool includeDeleted = false,
  }) async {
    final rows = await db.query(
      table,
      where: includeDeleted ? 'tag_id = ?' : 'tag_id = ? AND deleted_at IS NULL',
      whereArgs: [tagId],
      limit: 1,
    );
    return rows.isEmpty ? null : TagLibraryEntry.fromRow(rows.first);
  }

  /// The entry carrying [lineageId], or null.
  ///
  /// Used to keep the library from growing a second entry for a collar it
  /// already knows about — a tag created straight into a project records
  /// itself here, and so does the v14 migration, and the two must not both
  /// land for one transmitter.
  Future<TagLibraryEntry?> findByLineage(String lineageId) async {
    final rows = await db.query(
      table,
      where: 'lineage_id = ?',
      whereArgs: [lineageId],
      limit: 1,
    );
    return rows.isEmpty ? null : TagLibraryEntry.fromRow(rows.first);
  }

  Future<List<TagLibraryEntry>> findAll({bool includeDeleted = false}) async {
    final rows = await db.query(
      table,
      where: includeDeleted ? null : 'deleted_at IS NULL',
      orderBy: 'frequency_mhz, tag_name',
    );
    return rows.map(TagLibraryEntry.fromRow).toList();
  }

  /// Rewrites an entry, bumping `revision` and `updated_at` in SQL rather
  /// than read-modify-write, exactly as `BaseRepository.updateById` does.
  ///
  /// **Editing a library entry reaches no project**, by construction: a
  /// project holds its own row. That is the direction of copy-on-add most
  /// likely to surprise somebody, which is why the library screen says so —
  /// see [libraryCopyCount].
  Future<int> update(TagLibraryEntry entry, {DateTime? now}) async {
    final columns = Map<String, Object?>.of(entry.toColumns())
      ..removeWhere(
        (key, _) => const {
          'tag_id',
          'lineage_id',
          'created_at',
          'updated_at',
          'deleted_at',
          'revision',
          'origin_device_id',
        }.contains(key),
      );
    final assignments = columns.keys.map((c) => '$c = ?').join(', ');
    return db.rawUpdate(
      'UPDATE $table SET $assignments, updated_at = ?, '
      'revision = revision + 1 WHERE tag_id = ?',
      [...columns.values, DbCodec.encodeUtc(now ?? DateTime.now()), entry.tagId],
    );
  }

  /// How many of **this device's** projects, other than [excludingProjectId],
  /// hold a copy of the collar [lineageId] identifies.
  ///
  /// **This answers "how many *other* projects hold this collar"** — the
  /// question Project Setup asks about a tag that is itself one of the rows
  /// being counted. Excluding it is the method's job, not the caller's: a
  /// caller that subtracted one itself would be a second place holding the
  /// rule, and the next caller would have to know it too (task 11.234).
  ///
  /// For the question the Tag Database screen asks — "how many projects hold
  /// this *library* entry", where the entry is never itself a row in `Tags`
  /// — see [libraryCopyCount].
  ///
  /// ## Reading a lineage is permitted here, and the line is worth stating
  ///
  /// §2.3 of the design requires that nothing live read a lineage into a
  /// decision about which rows travel, and
  /// `assertSealedColumnsFeedNoReachability` enforces exactly that. This is a
  /// different thing: it is a **count**, on one device, of that device's own
  /// projects, shown to the person who holds them all.
  ///
  /// §2.5 draws the line explicitly and this is the safe side of it:
  /// **stating a count is safe; naming the projects is not.** A device can
  /// legitimately hold a project the person is only a viewer on, and
  /// "changes here will not reach *Kruger 2027*" would tell them a project
  /// exists — the disclosure cancelled task 11.29 left a standing rule
  /// against. "Two of your projects use this collar" tells them what they
  /// need in order not to lose an edit, and nothing else.
  ///
  /// ## Task 11.288: a soft-deleted project's copies do not count
  ///
  /// Deleting a project on this device sets `Projects.deleted_at` and never
  /// touches that project's `Tags` rows — there is no cascade. Left alone,
  /// this query kept counting those rows, so a library entry that had once
  /// been added to a project the person deleted months ago still claimed a
  /// copy was "in use."
  ///
  /// **A project soft-deleted here is not the same as a project that is
  /// gone.** This device's `deleted_at` says only that *this person* deleted
  /// it *on this device* — the project may still be live on the server and
  /// live for teammates who never deleted their own copy. Excluding it here
  /// is right anyway, because of what the count is **for**: it discloses
  /// what an edit or delete made on this device would reach, and an edit
  /// made here cannot reach a project this device no longer holds. The next
  /// reader who needs a count of projects that are actually gone, rather
  /// than projects this device has stopped syncing, needs a different query
  /// — this one is deliberately the narrower question.
  Future<int> otherProjectCopyCount(
    String lineageId,
    String excludingProjectId,
  ) async {
    final rows = await db.rawQuery(
      'SELECT COUNT(DISTINCT t.project_id) AS c FROM ${Tables.tags} t '
      'JOIN ${Tables.projects} p ON p.project_id = t.project_id '
      'WHERE t.lineage_id = ? AND t.deleted_at IS NULL '
      'AND t.project_id != ? AND p.deleted_at IS NULL',
      [lineageId, excludingProjectId],
    );
    return (rows.first['c'] as num).toInt();
  }

  /// How many of **this device's** projects hold a copy of the library entry
  /// [lineageId] identifies.
  ///
  /// **A library entry is never itself a row in `Tags`**, so unlike
  /// [otherProjectCopyCount] there is nothing here to exclude — every match
  /// is a genuine copy in a project. See [otherProjectCopyCount] for the
  /// disclosure rule this count is bound by; it applies here unchanged, and
  /// [otherProjectCopyCount]'s doc comment also carries the reason for the
  /// join below.
  Future<int> libraryCopyCount(String lineageId) async {
    final rows = await db.rawQuery(
      'SELECT COUNT(DISTINCT t.project_id) AS c FROM ${Tables.tags} t '
      'JOIN ${Tables.projects} p ON p.project_id = t.project_id '
      'WHERE t.lineage_id = ? AND t.deleted_at IS NULL AND p.deleted_at IS NULL',
      [lineageId],
    );
    return (rows.first['c'] as num).toInt();
  }

  /// **Which of this device's projects hold a copy of each collar** — task
  /// 11.321, for the library's grouping by project. Keyed by lineage; a
  /// lineage no project holds is simply absent.
  ///
  /// The same rows [libraryCopyCount] counts, with the same join and for the
  /// same reason (a project this device soft-deleted holds nothing an edit
  /// here could reach), read once for the whole library rather than once per
  /// entry.
  ///
  /// **The projects are named on the screen, and §2.5's "a count, never the
  /// names" does not forbid it here.** That rule is about a message *on a
  /// tag* revealing a project the reader may not know about. These are the
  /// projects this device already lists on More → Projects, to the same
  /// person, so grouping by them discloses nothing that screen does not.
  ///
  /// Returns lineage → project id → project name.
  Future<Map<String, Map<String, String>>> projectsHoldingEachLineage() async {
    final rows = await db.rawQuery(
      'SELECT DISTINCT t.lineage_id AS l, t.project_id AS p, '
      'p.project_name AS n '
      'FROM ${Tables.tags} t '
      'JOIN ${Tables.projects} p ON p.project_id = t.project_id '
      'WHERE t.deleted_at IS NULL AND p.deleted_at IS NULL',
    );
    final result = <String, Map<String, String>>{};
    for (final row in rows) {
      (result[row['l'] as String] ??= {})[row['p'] as String] =
          row['n'] as String;
    }
    return result;
  }

  /// **Every live project on this device, id → name** — task 11.321's
  /// drag-to-assign. A project with no tag in the library still needs a
  /// heading on the Tag Library, or there is nothing to drop a tag onto. The
  /// same set More → Projects lists (not soft-deleted), for the reason
  /// [projectsHoldingEachLineage] gives for naming them.
  Future<Map<String, String>> liveProjectNames() async {
    final rows = await db.rawQuery(
      'SELECT project_id, project_name FROM ${Tables.projects} '
      'WHERE deleted_at IS NULL',
    );
    return {
      for (final row in rows)
        row['project_id'] as String: row['project_name'] as String,
    };
  }

  /// Count of entries, including deactivated ones (a library entry is never
  /// hard-deleted) — the round-robin position a newly created library tag's
  /// auto-assigned colour continues from.
  ///
  /// **Task 11.288: this is why deleting a batch of entries and adding one
  /// new one does not repeat a colour still in play.** A soft-deleted row
  /// keeps its place in this count on purpose — it stops a colour a project
  /// still shows from being handed straight back out to a fresh entry. It
  /// looks, to somebody who deletes fifty test tags and adds one, like the
  /// palette "didn't reset" — it did not, and it is not supposed to.
  Future<int> entryCount() async {
    final rows = await db.rawQuery('SELECT COUNT(*) AS c FROM $table');
    return (rows.first['c'] as num).toInt();
  }

  /// Soft-deletes every entry in [tagIds] — one write, so a select-all on a
  /// fifty-row library and an undo of it are each one round trip rather than
  /// fifty.
  ///
  /// Mirrors `BaseRepository.softDeleteById`'s bookkeeping (bump `revision`
  /// and `updated_at`, set `deleted_at`) without its actor/authorization
  /// machinery — there is no [MutationRule] here to check against, for the
  /// same reason [update] above rewrites in raw SQL rather than extending
  /// `BaseRepository`. **This never reaches the server or a project**: see
  /// this class's own doc comment.
  Future<void> softDelete(List<String> tagIds, {DateTime? now}) async {
    if (tagIds.isEmpty) return;
    final ts = DbCodec.encodeUtc(now ?? DateTime.now());
    final placeholders = List.filled(tagIds.length, '?').join(', ');
    await db.rawUpdate(
      'UPDATE $table SET deleted_at = ?, updated_at = ?, revision = revision + 1 '
      'WHERE tag_id IN ($placeholders) AND deleted_at IS NULL',
      [ts, ts, ...tagIds],
    );
  }

  /// Clears the tombstone [softDelete] set — undo of the last delete. The
  /// rows were never removed, so this is a plain column write, not a
  /// reconstruction.
  Future<void> restore(List<String> tagIds, {DateTime? now}) async {
    if (tagIds.isEmpty) return;
    final ts = DbCodec.encodeUtc(now ?? DateTime.now());
    final placeholders = List.filled(tagIds.length, '?').join(', ');
    await db.rawUpdate(
      'UPDATE $table SET deleted_at = NULL, updated_at = ?, revision = revision + 1 '
      'WHERE tag_id IN ($placeholders) AND deleted_at IS NOT NULL',
      [ts, ...tagIds],
    );
  }

  /// The next auto-assigned palette colour for a new library entry.
  Future<String> nextColorHex() async =>
      TagColorPalette.nextColor(await entryCount());
}
