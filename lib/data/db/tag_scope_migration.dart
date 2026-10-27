import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:uuid/uuid.dart';

import 'schema.dart';

/// Schema v14's judgement half (task 11.219, fork added by task 11.224):
/// **which project each tag belongs to, how many there were, and what to do
/// when the answer is more than one.**
///
/// `schema.dart` holds v14's statements. Everything here is the part that
/// cannot be written as DDL — counting, printing, and forking.
///
/// ## Why a migration that forks rows has to say how many it forked
///
/// A migration that moves data and prints nothing cannot be told apart from
/// one that did nothing. That is this project's founding defect, met in the
/// worst possible place, so this one prints its census on every run —
/// including a run where every number is zero, because "nothing to do" is a
/// result and an absent line is not. The fork prints its own counts after
/// the rebuild, for the same reason and with the same zeroes.
///
/// ## The fork was a refusal, and then it fired
///
/// Task 11.219 wrote the shared-tag case as a loud stop rather than as
/// logic, on one measurement: Michael's Mac answered §3.1's query with
/// `1|5` — five tags, each in exactly one project. It said in the same
/// breath that *one Mac is not proof about a phone*, and it was not: on
/// 2026-09-10 the build reached his iPhone, the census counted **6 tags, 4 in
/// one project, 2 in two**, and the migration stopped without changing a row.
/// Both shared collars were made by the "link an existing tag to this
/// project" affordance that task 11.218 has since closed. The refusal was
/// right to exist and right to fire; task 11.224 replaced it with the fork
/// the design already specified — `CLAUDE_DOCS/TAG_COPY_ON_ADD_DESIGN.md`
/// §3.3, implemented in [fork] below as written, not re-derived.
///
/// ## Why the fork is mechanical, and what the refusal was actually guarding
///
/// The refusal's message said forking was *"a decision about the primary
/// scientific record"*. It is worth being precise about which part of it is.
///
/// **A bearing belongs to exactly one project.** So does a session, an
/// estimate and a truth point — `project_id` is `NOT NULL` and half the
/// primary key on every one of them. After the fork, each project's records
/// follow that project's own copy of the collar, and **nothing is mixed,
/// merged or averaged across projects**: project B's bearings name project
/// B's copy, which carries the same frequency, the same pulse rate and a
/// version chain copied row for row with the same `effective_from` dates, so
/// every bearing still resolves to a collar reading exactly what it read
/// before. `lineage_id` keeps the copies tied to one physical transmitter,
/// which is what it was added for.
///
/// **The one question the refusal would not answer — which project keeps the
/// original `tag_id` — decides a UUID, not a record.** Whichever project
/// keeps it, every bearing in every project still names a collar with the
/// same measurements and the same history. What *would* have had scientific
/// content is guessing whose bearings belong to which collar, and that is not
/// a guess: the row's own `project_id` answers it. That is the whole of why
/// this can run unattended on a phone.
///
/// ## Which project keeps the original id, and the tiebreak §3.3 left open
///
/// §3.3 orders a tag's projects by their `Project_Tags.created_at`, ascending,
/// and the first keeps the original id — it is the project that adopted the
/// collar first, and the one a server would have accepted first. That
/// ordering is the *only* thing deciding the id, so it must be total.
/// [TagAdoption.compare] makes it so: **an unknown adoption date sorts
/// last, and an equal date is broken by `project_id`, ascending.** The
/// tiebreak is meaningless — a UUID has no content — and that is the point:
/// it is stable, it is the same on every run, and it settles a question that
/// had no better answer.
///
/// A project can also hold a tag with no link at all — through a bearing, a
/// session, an estimate or a truth point naming it, which the census treats
/// as evidence just as good (see below). §3.3 has no `created_at` to order
/// such a project by, so this uses the earliest `created_at` among that
/// project's own records naming the tag: the first day the project is known
/// to have held it, which is a date somebody recorded rather than one
/// invented here. The report says which kind of date each project was ordered
/// by. **Michael's phone has a link for every one of its four (tag, project)
/// pairs, so this branch is not what runs on it.**
///
/// ## What counts as "in a project", and why it is wider than the design's
/// query
///
/// §3.1's query asks `Project_Tags` alone, and that is the number Michael
/// ran, so it is reported verbatim. **It is not the whole question.** A
/// `Project_Tags` link is the *usual* evidence that a tag belongs to a
/// project; a bearing, a session, an estimate or a truth point naming that
/// tag inside a project is evidence just as good, and the two can disagree
/// today:
///
/// - The pasted-share screen matches an incoming record against **every tag
///   on the device** and writes an observation in the current project naming
///   a tag that project may have no link to. That is §1.3(b) of the design —
///   a live defect, not a hypothetical.
/// - An imported archive merges rows scoped to its manifest project while
///   `Tags` merges globally.
///
/// So the scope is derived over the whole corpus. It matters in both
/// directions and neither is cosmetic: a tag whose only evidence is a bearing
/// would otherwise be dropped from `Tags` and take that bearing's foreign key
/// with it, and a tag whose evidence names **two** projects is the shared
/// case the fork exists for, wearing different clothes.
///
/// ## `Non_Detections` is left alone, and the reason was checked
///
/// `Non_Detections.tag_ids_listened_for` is a JSON list of tag ids in a text
/// column with no foreign key on either side. It is neither consulted to
/// decide scope nor re-pointed by the fork. §3.3(3) gives the reason and
/// task 11.224 checked it against the code rather than the document:
/// `Non_Detections` declares no `tagColumns`, the column is named in
/// `unvalidatedIdListColumns`, and `assertSealedColumnsFeedNoReachability`
/// fails the moment it is declared in any set that decides what a project
/// reaches. Everything that reads it today — the Log, the map, the CSV
/// export — looks each id up and shows nothing for one it cannot find.
/// Re-pointing it here would be the first code to treat the list as a
/// relationship that must resolve, which is the day that assertion exists
/// to notice.
///
/// **The consequence is real and it is printed rather than hidden:** in a
/// project that received a *copy*, a "no signal" entry that listened for the
/// shared collar keeps naming the original id, which now belongs to the
/// other project. The Log shows that entry without the collar's frequency
/// and the per-tag filter no longer finds it. The row itself is untouched
/// and exports intact. Security Model §5.9(b) records this as a dangling
/// reference the column was already permitted to hold; the fork report
/// counts how many rows are in that state.
abstract final class TagScopeMigration {
  /// The tag-bearing tables as of v14, **written out rather than derived from
  /// `syncTables`.**
  ///
  /// A shipped migration must describe the change as it was made. Deriving
  /// this list would silently make it a different migration the next time the
  /// declarations move, which is the rule `schemaV6Statements` and the
  /// server's `schemaV7Statements` both state at length.
  static const _tagEvidenceTables = <(String, String, bool)>[
    // (table, tag column, tag column is nullable)
    (Tables.projectTags, 'tag_id', false),
    (Tables.triangulationSessions, 'tag_id', false),
    (Tables.observations, 'tag_id', true),
    (Tables.estimatedPositions, 'tag_id', false),
    (Tables.actualTagLocations, 'tag_id', false),
  ];

  /// The four tables whose rows follow their project's copy of a forked tag
  /// (§3.3 step 2), in the order they are rebuilt — parent before child.
  static const rePointedTables = <String>[
    Tables.triangulationSessions,
    Tables.observations,
    Tables.estimatedPositions,
    Tables.actualTagLocations,
  ];

  /// The two of those that also name a `Tag_Versions` row, and so move to the
  /// forked version with the same `effective_from`.
  static const versionNamingTables = <String>[
    Tables.observations,
    Tables.actualTagLocations,
  ];

  static const _uuid = Uuid();

  // ignore: avoid_print
  static void _print(String line) => print(line);

  /// Applies schema v14. Called from the migration list; not for direct use.
  ///
  /// [log] is where the census goes, and it is **`print` by default because
  /// the alternatives were measured rather than assumed.** `debugPrint` would
  /// make this file — and therefore `migrations.dart` — depend on `dart:ui`,
  /// which is a real cost for a layer that has never needed Flutter.
  /// `dart:developer`'s `log` is pure Dart and looked right, and it emits
  /// **nothing at all under `flutter test`** — precisely the environment
  /// where a check would have to observe this. A census nobody can see is the
  /// defect the census exists to prevent, so it goes through the one channel
  /// that is visible in a device log, in CI, and to a `Zone` a test installs.
  /// [fromVersion] is the schema the database is coming from. **A fresh
  /// create (`0`) prints nothing**: there is no data to move, so a census of
  /// zeroes is noise, and the app's own test suite builds several hundred
  /// empty databases a run. An upgrade always prints, including one that
  /// finds nothing — there, "nothing to do" is a result and an absent line
  /// is not.
  static Future<void> apply(
    DatabaseExecutor db,
    int fromVersion, {
    void Function(String line) log = _print,
  }) async {
    final census = await takeCensus(db);
    if (fromVersion > 0) {
      for (final line in census.report()) {
        log(line);
      }
    }

    // The scope decision, materialised so every statement in
    // `schemaV14TableStatements` reads it instead of deciding anything. For
    // a shared tag this names the project that keeps the original id; the
    // rebuild therefore lands the original row and its version chain there,
    // and the other projects' rows go on naming the original id until the
    // fork below re-points them — which is why the fork runs after the
    // rebuild and before `_assertForeignKeysIntact`.
    await db.execute(
      'CREATE TABLE _tag_scope (tag_id TEXT PRIMARY KEY, '
      'project_id TEXT NOT NULL)',
    );
    for (final entry in census.scope.entries) {
      await db.insert('_tag_scope', {
        'tag_id': entry.key,
        'project_id': entry.value,
      });
    }
    for (final statement in schemaV14TableStatements()) {
      await db.execute(statement);
    }
    await db.execute('DROP TABLE _tag_scope');

    final forked = await fork(db, census.forks);
    if (fromVersion > 0) {
      for (final line in forked.report()) {
        log(line);
      }
    }
  }

  /// Counts what is about to be migrated, and works out which project each
  /// tag ends up in — and, for a tag two or more projects hold, which of them
  /// keeps the original id and which receive a copy.
  ///
  /// Public and separately callable on purpose: a number a migration reports
  /// only into a log is a number no test can assert, and this project has
  /// been bitten by instruments that measured nothing.
  static Future<TagScopeCensus> takeCensus(DatabaseExecutor db) async {
    // §3.1 verbatim — the query Michael ran, so the four numbers this prints
    // are comparable with the answer he already has.
    final byLinkCount = await db.rawQuery('''
SELECT n, COUNT(*) AS c FROM (
  SELECT t.tag_id, COUNT(pt.project_id) AS n
  FROM ${Tables.tags} t
  LEFT JOIN ${Tables.projectTags} pt ON pt.tag_id = t.tag_id
  GROUP BY t.tag_id
) GROUP BY n''');
    var linkedToOne = 0;
    var linkedToMany = 0;
    var linkedToNone = 0;
    for (final row in byLinkCount) {
      final n = (row['n'] as num).toInt();
      final c = (row['c'] as num).toInt();
      if (n == 0) {
        linkedToNone += c;
      } else if (n == 1) {
        linkedToOne += c;
      } else {
        linkedToMany += c;
      }
    }

    // Every (tag, project) pair the corpus names, with the evidence §3.3
    // orders by: a link's own `created_at` where there is a link, else the
    // earliest `created_at` among the project's records naming the tag.
    final adoptions = <String, Map<String, TagAdoption>>{};
    for (final (table, column, _) in _tagEvidenceTables) {
      final isLink = table == Tables.projectTags;
      final rows = await db.rawQuery(
        isLink
            ? 'SELECT tag_id, project_id, created_at AS at, '
                'last_modified_by, origin_device_id FROM $table'
            : 'SELECT $column AS tag_id, project_id, MIN(created_at) AS at '
                'FROM $table WHERE $column IS NOT NULL '
                'GROUP BY $column, project_id',
      );
      for (final row in rows) {
        final tagId = row['tag_id'];
        final projectId = row['project_id'];
        if (tagId is! String || tagId.isEmpty) continue;
        if (projectId is! String || projectId.isEmpty) continue;
        final at = row['at'];
        final seen = TagAdoption(
          projectId: projectId,
          adoptedAt: at is String && at.isNotEmpty ? at : null,
          viaLink: isLink,
          lastModifiedBy: isLink ? row['last_modified_by'] as String? : null,
          originDeviceId: isLink ? row['origin_device_id'] as String? : null,
        );
        final byProject = adoptions[tagId] ??= <String, TagAdoption>{};
        final existing = byProject[projectId];
        // A link is the adoption date §3.3 names; a record only stands in
        // for one. Between two records, the earlier wins.
        if (existing == null ||
            (!existing.viaLink &&
                (seen.viaLink || TagAdoption.compare(seen, existing) < 0))) {
          byProject[projectId] = seen;
        }
      }
    }

    final allTags = [
      for (final row in await db.rawQuery(
        'SELECT tag_id FROM ${Tables.tags}',
      ))
        row['tag_id'] as String,
    ];

    final scope = <String, String>{};
    final shared = <String, Set<String>>{};
    final forks = <TagFork>[];
    final libraryOnly = <String>[];
    for (final tagId in allTags) {
      final projects = adoptions[tagId] ?? const <String, TagAdoption>{};
      if (projects.isEmpty) {
        libraryOnly.add(tagId);
      } else if (projects.length == 1) {
        scope[tagId] = projects.keys.single;
      } else {
        final ordered = projects.values.toList()..sort(TagAdoption.compare);
        final fork = TagFork(
          tagId: tagId,
          keeper: ordered.first,
          copies: ordered.sublist(1),
        );
        forks.add(fork);
        scope[tagId] = fork.keeper.projectId;
        shared[tagId] = projects.keys.toSet();
      }
    }

    // Version rows that go with a tag nothing references. Counted because
    // they are the one thing this migration destroys, and a loss nobody
    // printed is a loss nobody knows about.
    var versionsDropped = 0;
    if (libraryOnly.isNotEmpty) {
      for (final tagId in libraryOnly) {
        final rows = await db.rawQuery(
          'SELECT COUNT(*) AS c FROM ${Tables.tagVersions} WHERE tag_id = ?',
          [tagId],
        );
        versionsDropped += (rows.first['c'] as num).toInt();
      }
    }

    return TagScopeCensus(
      total: allTags.length,
      linkedToExactlyOneProject: linkedToOne,
      linkedToTwoOrMoreProjects: linkedToMany,
      linkedToNoProject: linkedToNone,
      scope: scope,
      sharedTagIds: shared,
      forks: forks,
      libraryOnlyTagIds: libraryOnly,
      versionRowsDropped: versionsDropped,
    );
  }

  /// §3.3, on a database already in v14 shape: for every tag two or more
  /// projects hold, each project after the first gets its own copy, and its
  /// own records move to it.
  ///
  /// Runs after `schemaV14TableStatements` and before `runMigrations`'
  /// `PRAGMA foreign_key_check`, with enforcement off, as §3.5 requires.
  /// Public so a test can run it on a shape it built and assert the counts
  /// it returns, rather than trusting the lines it prints.
  ///
  /// Per forked project, in §3.3's order:
  ///
  /// 1. **The tag row.** A copy of the keeper's row with a fresh `tag_id`,
  ///    the same `lineage_id`, and `copied_at` set to the day that project
  ///    adopted the collar — the link's own `created_at`, already recorded.
  ///    Its sync columns are a new row's, exactly as `SyncMeta.initial` and
  ///    `TagRepository.copyFromLibrary` write a copy made in the app:
  ///    `created_at` and `updated_at` equal `copied_at`, `revision` is 0, and
  ///    the row has no receipt so it is offered on the next push. `deleted_at`
  ///    is copied, because a collar deactivated before the fork was
  ///    deactivated in both projects. The author and device are the link's —
  ///    the act of adopting is what this row records — falling back to the
  ///    original's for a project that held the tag through a record only.
  /// 2. **The version chain.** Every `Tag_Versions` row of the original,
  ///    copied with a fresh `tag_version_id`, the new `tag_id` and the new
  ///    `project_id`, and every other column verbatim — `effective_from`, the
  ///    measurements, and the sync columns, because a version is the record
  ///    of what the collar read on a day, and the copy is the same record.
  /// 3. **Re-pointing.** That project's rows in [rePointedTables] move to the
  ///    new `tag_id`, and each `tag_version_id` in [versionNamingTables] moves
  ///    to the copied version made from the one it named — which by
  ///    construction has the same `effective_from`. The re-pointed rows' sync
  ///    columns are left alone: `updated_at` is the push receipt's key, and a
  ///    bearing the server already holds under the *original* id would not be
  ///    re-offered — but no server has ever held a tag in two projects (the
  ///    server has refused the second project's link since task 11.3), so a
  ///    row this re-points was never accepted under the original id and has
  ///    no receipt to match. That is reasoning, not a measurement, and it is
  ///    recorded in Security Model §5.9(b) beside the `Non_Detections` note.
  ///
  /// The counts are returned rather than only printed, and a run with
  /// nothing to fork returns zeroes rather than nothing.
  static Future<TagForkReport> fork(
    DatabaseExecutor db,
    List<TagFork> forks,
  ) async {
    var newTagRows = 0;
    var versionRowsCopied = 0;
    final rePointed = <String, int>{for (final t in rePointedTables) t: 0};
    final versionRePointed = <String, int>{
      for (final t in versionNamingTables) t: 0,
    };
    var nonDetectionsNamingOriginal = 0;

    for (final f in forks) {
      final original = (await db.query(
        Tables.tags,
        where: 'tag_id = ? AND project_id = ?',
        whereArgs: [f.tagId, f.keeper.projectId],
      )).single;
      final versions = await db.query(
        Tables.tagVersions,
        where: 'tag_id = ? AND project_id = ?',
        whereArgs: [f.tagId, f.keeper.projectId],
      );

      for (final copy in f.copies) {
        final newTagId = _uuid.v4();
        // An adoption date is unknown only for a row that violated its own
        // column's intent (`created_at` is NOT NULL and the app never writes
        // it empty). The original's `created_at` is then the honest floor —
        // the project cannot have adopted the collar before it existed — and
        // the census report has already printed "adopted: unknown" beside
        // that project so the floor is visible rather than mistaken for a
        // recorded date.
        final adoptedAt = copy.adoptedAt ?? original['created_at'] as String;
        await db.insert(Tables.tags, {
          ...original,
          'tag_id': newTagId,
          'project_id': copy.projectId,
          'lineage_id': original['lineage_id'],
          'copied_at': adoptedAt,
          'created_at': adoptedAt,
          'updated_at': adoptedAt,
          'revision': 0,
          'last_modified_by':
              copy.lastModifiedBy ?? original['last_modified_by'],
          'origin_device_id':
              copy.originDeviceId ?? original['origin_device_id'],
        });
        newTagRows++;

        for (final v in versions) {
          final newVersionId = _uuid.v4();
          await db.insert(Tables.tagVersions, {
            ...v,
            'tag_version_id': newVersionId,
            'tag_id': newTagId,
            'project_id': copy.projectId,
          });
          versionRowsCopied++;
          for (final table in versionNamingTables) {
            versionRePointed[table] = versionRePointed[table]! +
                await db.update(
                  table,
                  {'tag_version_id': newVersionId},
                  where: 'project_id = ? AND tag_version_id = ?',
                  whereArgs: [copy.projectId, v['tag_version_id']],
                );
          }
        }

        for (final table in rePointedTables) {
          rePointed[table] = rePointed[table]! +
              await db.update(
                table,
                {'tag_id': newTagId},
                where: 'project_id = ? AND tag_id = ?',
                whereArgs: [copy.projectId, f.tagId],
              );
        }

        // Counted, not consulted and not changed — see the class comment.
        // `instr` on the JSON-quoted id rather than `LIKE`, so an id
        // containing an underscore is not a wildcard.
        final left = await db.rawQuery(
          'SELECT COUNT(*) AS c FROM ${Tables.nonDetections} '
          'WHERE project_id = ? AND instr(tag_ids_listened_for, ?) > 0',
          [copy.projectId, '"${f.tagId}"'],
        );
        nonDetectionsNamingOriginal += (left.first['c'] as num).toInt();
      }
    }

    return TagForkReport(
      tagsForked: forks.length,
      newTagRows: newTagRows,
      versionRowsCopied: versionRowsCopied,
      rePointedByTable: rePointed,
      versionRePointedByTable: versionRePointed,
      nonDetectionsNamingOriginal: nonDetectionsNamingOriginal,
    );
  }
}

/// One project's claim on a tag, and the date §3.3 orders those claims by.
class TagAdoption {
  const TagAdoption({
    required this.projectId,
    required this.adoptedAt,
    required this.viaLink,
    this.lastModifiedBy,
    this.originDeviceId,
  });

  final String projectId;

  /// The `Project_Tags` link's `created_at` when [viaLink], else the earliest
  /// `created_at` among this project's own records naming the tag. Null when
  /// the stored value was empty — which the schema forbids and the app never
  /// writes, and which sorts last so it can never win the original id over a
  /// date somebody actually recorded.
  final String? adoptedAt;

  /// Whether a `Project_Tags` row records the adoption, or only a bearing,
  /// session, estimate or truth point does.
  final bool viaLink;

  /// The link row's author and device, if there was a link.
  final String? lastModifiedBy;
  final String? originDeviceId;

  /// §3.3's ordering, made total.
  ///
  /// Earlier [adoptedAt] first; an unknown date after every known one; and
  /// an equal date — the tie §3.3 does not mention — broken by [projectId],
  /// ascending. Timestamps are compared as text, which is chronological for
  /// the UTC ISO-8601 strings every `SyncMeta` writes, and deterministic
  /// whatever the strings are. The tiebreak decides a UUID, not a record, and
  /// what it is chosen for is that it gives the same answer on every run.
  static int compare(TagAdoption a, TagAdoption b) {
    final ka = a.adoptedAt;
    final kb = b.adoptedAt;
    if (ka != null && kb != null) {
      final byDate = ka.compareTo(kb);
      if (byDate != 0) return byDate;
    } else if (ka != null) {
      return -1;
    } else if (kb != null) {
      return 1;
    }
    return a.projectId.compareTo(b.projectId);
  }

  String describe() =>
      '$projectId (adopted ${adoptedAt ?? 'unknown'}, '
      'by ${viaLink ? 'link' : 'record'})';
}

/// A tag two or more projects hold, and how §3.3 splits it.
class TagFork {
  const TagFork({
    required this.tagId,
    required this.keeper,
    required this.copies,
  });

  final String tagId;

  /// The project that keeps the original `tag_id` — first in
  /// [TagAdoption.compare]'s order.
  final TagAdoption keeper;

  /// Every other project, each of which receives its own copy.
  final List<TagAdoption> copies;
}

/// What schema v14 found before it moved anything.
class TagScopeCensus {
  const TagScopeCensus({
    required this.total,
    required this.linkedToExactlyOneProject,
    required this.linkedToTwoOrMoreProjects,
    required this.linkedToNoProject,
    required this.scope,
    required this.sharedTagIds,
    required this.forks,
    required this.libraryOnlyTagIds,
    required this.versionRowsDropped,
  });

  /// Tags in total.
  final int total;

  /// §3.1's four numbers, counted by `Project_Tags` links alone — the query
  /// Michael ran on 2026-09-10, so these are the ones comparable with `1|5`
  /// on his Mac and `4|1, 2|2` on his phone.
  final int linkedToExactlyOneProject;
  final int linkedToTwoOrMoreProjects;
  final int linkedToNoProject;

  /// The project each surviving original `tag_id` ends up in, derived over
  /// every table that names a tag rather than over links alone. For a
  /// forked tag this is the keeper.
  final Map<String, String> scope;

  /// Tags whose evidence names two or more projects, and which projects.
  final Map<String, Set<String>> sharedTagIds;

  /// The fork each entry of [sharedTagIds] gets — who keeps the id, who is
  /// copied, and the dates that decided it.
  final List<TagFork> forks;

  /// Tags no project's data names at all. They move to the personal library
  /// and leave `Tags`; nothing referenced them, which is what made them
  /// orphans.
  final List<String> libraryOnlyTagIds;

  /// `Tag_Versions` rows belonging to a [libraryOnlyTagIds] tag. These are
  /// deleted: a version is the drift record of a collar somebody recorded
  /// against, and the library holds no bearings for it to be the history of.
  final int versionRowsDropped;

  /// The lines the migration prints, in order.
  ///
  /// **Written as findings rather than as labels.** A five-line tail in CI, or
  /// a person scrolling a device log, has to be able to tell a clean run from
  /// a run that did nothing, and that means each line has to say what it
  /// found — including, for each fork, which project kept the id and on the
  /// strength of what date.
  List<String> report() => [
    'Schema v14 (tags become project-scoped) — census before anything moved:',
    '  tags in total: $total',
    '  linked to exactly one project: $linkedToExactlyOneProject',
    '  linked to two or more projects: $linkedToTwoOrMoreProjects',
    '  linked to no project: $linkedToNoProject',
    if (forks.isEmpty)
      '  → nothing to fork.'
    else ...[
      '  → ${forks.length} tag(s) are named by two or more projects; each is '
          'forked (design §3.3): the project that adopted it first keeps the '
          'original id, every later project gets its own copy.',
      for (final f in forks) ...[
        '      ${f.tagId}:',
        '        keeps the original id in ${f.keeper.describe()}',
        for (final c in f.copies) '        copied into ${c.describe()}',
      ],
    ],
    '  moving to the personal tag library only (no project names them): '
        '${libraryOnlyTagIds.length}',
    if (versionRowsDropped > 0)
      '  Tag_Versions rows deleted with those library-only tags: '
          '$versionRowsDropped',
    '  staying in a project: ${scope.length}',
  ];
}

/// What the fork did, counted from the statements' own return values.
class TagForkReport {
  const TagForkReport({
    required this.tagsForked,
    required this.newTagRows,
    required this.versionRowsCopied,
    required this.rePointedByTable,
    required this.versionRePointedByTable,
    required this.nonDetectionsNamingOriginal,
  });

  /// Tags that two or more projects held.
  final int tagsForked;

  /// New `Tags` rows — one per (forked tag, project after the first).
  final int newTagRows;

  /// `Tag_Versions` rows copied into those projects.
  final int versionRowsCopied;

  /// Rows whose `tag_id` moved to the copy, per table in
  /// [TagScopeMigration.rePointedTables].
  final Map<String, int> rePointedByTable;

  /// Rows whose `tag_version_id` moved to the copied version, per table in
  /// [TagScopeMigration.versionNamingTables].
  final Map<String, int> versionRePointedByTable;

  /// `Non_Detections` rows in a project that received a copy whose
  /// `tag_ids_listened_for` still names the original id. Left exactly as
  /// they were — see the class comment and Security Model §5.9(b).
  final int nonDetectionsNamingOriginal;

  static String _perTable(Map<String, int> counts) =>
      counts.entries.map((e) => '${e.key}: ${e.value}').join(', ');

  /// The lines the migration prints after the rebuild. Zeroes when there was
  /// nothing to fork: "nothing forked" is a result and an absent line is not.
  List<String> report() => [
    'Schema v14 — the fork (design §3.3), after the rebuild:',
    '  tags forked: $tagsForked',
    '  new tag rows created: $newTagRows',
    '  Tag_Versions rows copied: $versionRowsCopied',
    '  records re-pointed to the forked tag — ${_perTable(rePointedByTable)}',
    '  tag_version_id re-pointed to the copied version — '
        '${_perTable(versionRePointedByTable)}',
    '  Non_Detections rows in forked projects still naming the original tag '
        'id (left alone by design, Security Model §5.9(b)): '
        '$nonDetectionsNamingOriginal',
  ];
}
