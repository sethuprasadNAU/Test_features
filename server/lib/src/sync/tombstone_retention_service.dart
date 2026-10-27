/// Tombstone purging and the stale-device guard (task 10.11), and the sweep's
/// measurement (task 11.291).
///
/// ## Who runs the purge, and what the first run does (task 11.291)
///
/// `bin/tombstone_retention.dart` calls [TombstoneRetentionService.purge] on
/// a timer, as the `tombstone-retention` compose service. Until 2026-09-21
/// nothing called it at all: the guard below was real and tested, and the
/// sweep it guards had never run once, so every server's purge floor was
/// zero and `StaleCursorException` had never fired in production.
///
/// **The first-run policy, decided here: a tombstone's age is measured on the
/// server's own clock — `received_at`, when this server accepted the delete —
/// never on `deleted_at`, the device's stamp.** So the first sweep on any
/// server purges only deletes that server has itself held for the whole
/// window, and refuses only devices that have not synced that project in the
/// whole window. On a server younger than the window the first sweep purges
/// nothing and refuses nobody; the first real purge lands when the oldest
/// delete the server has seen turns [tombstoneRetention] old.
///
/// What that costs: a record deleted on a phone years before the server
/// existed, uploaded when the project was published, is kept for the window
/// counted from its upload rather than from its deletion — kilobytes, on a
/// schedule the server can defend. What the alternative cost: measured by the
/// device stamp, that same upload was purgeable on the first sweep, and so
/// was any fresh deletion from a phone whose clock was set years back. The
/// window's whole justification is "a device away this long may have missed
/// the delete", and a device can only have missed a delete since the server
/// had it to give. The device stamp is not the age of anything the window is
/// about.
library;

import 'package:postgres/postgres.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

import '../schema/postgres_schema.dart' show quoted;

/// Per-project record of how far tombstone purging has advanced.
///
/// **Per project, not global.** `server_seq` comes from one counter shared by
/// every project, so a single global floor would be set by whichever project is
/// busiest and would refuse devices on quiet projects that are perfectly
/// current — their cursors are legitimately low simply because their project
/// generates few rows. The floor has to mean "how far purging has advanced *in
/// this project*", which is what makes comparing it to a per-project cursor
/// sound.
const String createTombstonePurgeFloor = '''
CREATE TABLE IF NOT EXISTS tombstone_purge_floor (
  project_id TEXT PRIMARY KEY,
  purged_through_seq BIGINT NOT NULL DEFAULT 0,
  last_purged_at TIMESTAMPTZ NOT NULL DEFAULT now()
)''';

List<String> tombstonePurgeFloorStatements() => [createTombstonePurgeFloor];

/// Thrown when a device's position predates what the server can still describe.
///
/// The device is not merely behind — it is behind *a purge*, so the server no
/// longer holds the tombstones that would tell it what was deleted. Accepting
/// its push would resurrect those records; serving it an incremental pull would
/// imply it is up to date when it is missing deletes it can never learn about.
class StaleCursorException implements Exception {
  const StaleCursorException({
    required this.projectId,
    required this.cursor,
    required this.purgedThroughSeq,
  });

  final String projectId;

  /// Where the device believes it is.
  final int cursor;

  /// Everything at or below this has been purged in this project.
  final int purgedThroughSeq;

  @override
  String toString() =>
      'StaleCursorException: device cursor $cursor is below project '
      '$projectId\'s purge floor $purgedThroughSeq';
}

/// What one purge run did, for the diagnostics console (10.13) and tests.
class TombstonePurgeReport {
  const TombstonePurgeReport({
    required this.rowsPurged,
    required this.floorsAdvanced,
  });

  final int rowsPurged;
  final Map<String, int> floorsAdvanced;

  bool get purgedAnything => rowsPurged > 0;
}

/// What `--check` reads (task 11.291): the rows, never the loop.
///
/// The fault it exists to name is **a tombstone the sweep should have deleted
/// and has not** — past the window and not held back by any active device —
/// so [mostOverdueBy] is the age of the oldest such row beyond the window,
/// and the healthcheck compares it to a grace period. The rest is what an
/// operator needs beside that number, and what the first run on a real
/// server has to be able to say before anybody switches it on: how many rows
/// the next sweep would delete, and **how many devices it would refuse**.
class TombstoneRetentionReading {
  const TombstoneRetentionReading({
    required this.measuredAt,
    required this.window,
    required this.heldTombstones,
    required this.oldestHeldReceivedAt,
    required this.eligibleTombstones,
    required this.eligibleProjectIds,
    required this.oldestEligibleReceivedAt,
    required this.heldBackByActiveDevices,
    required this.devicesNextSweepWouldRefuse,
    required this.projectsNextSweepWouldRefuseOn,
    required this.devicesAlreadyRefused,
  });

  final DateTime measuredAt;
  final Duration window;

  /// Every tombstone on every project-scoped table, inside the window or not.
  final int heldTombstones;

  /// When the server accepted the oldest of them; null when there are none.
  final DateTime? oldestHeldReceivedAt;

  /// Tombstones the next sweep will delete: past the window and at or below
  /// their project's active-device holdback.
  final int eligibleTombstones;
  final Set<String> eligibleProjectIds;
  final DateTime? oldestEligibleReceivedAt;

  /// Tombstones past the window that a device syncing inside the window has
  /// not yet received. Kept on purpose; not a fault.
  final int heldBackByActiveDevices;

  /// Recorded device positions that sit below what the next sweep would
  /// purge in their project — refused from the sweep onward.
  final int devicesNextSweepWouldRefuse;
  final Set<String> projectsNextSweepWouldRefuseOn;

  /// Recorded device positions already below a floor an earlier sweep set.
  final int devicesAlreadyRefused;

  /// How long the oldest surviving eligible tombstone has been past the
  /// window; null when nothing is eligible.
  Duration? get mostOverdueBy {
    final oldest = oldestEligibleReceivedAt;
    if (oldest == null) return null;
    return measuredAt.difference(oldest) - window;
  }

  /// How far the oldest tombstone this server holds is from turning
  /// [window] old; null when it holds none. Negative once one is past it.
  Duration? get untilFirstPurge {
    final oldest = oldestHeldReceivedAt;
    if (oldest == null) return null;
    return window - measuredAt.difference(oldest);
  }
}

/// Purges expired tombstones and answers "is this device too far behind".
///
/// See `tombstoneRetention` in the shared package for why the window is what it
/// is. The short version: a too-short window corrupts data silently, a too-long
/// one wastes kilobytes, so the window is generous and the *guard* below is
/// what actually provides the safety.
class TombstoneRetentionService {
  const TombstoneRetentionService(this.session);

  final Session session;

  /// Project-scoped tables, children first — the order rows must be deleted in
  /// so a parent never goes while a child still references it. [syncTables] is
  /// declared parents-first for insertion, so purging walks it backwards.
  ///
  /// Public since task 11.290: `ProjectDestructionService.destroy` walks the
  /// same list to delete a whole project, because the foreign keys that fix
  /// this order are the same ones, and a second declaration of it would be a
  /// second answer to the same question.
  static List<SyncTable> get purgeableTables => [
    for (final table in syncTables.reversed)
      if (table.projectScopeColumn != null) table,
  ];

  /// How far purging has advanced in [projectId]. Zero when nothing has ever
  /// been purged there, which is the state every new project starts in and the
  /// reason a freshly published project never trips the guard.
  Future<int> floorFor(String projectId) async {
    final result = await session.execute(
      r'SELECT purged_through_seq FROM tombstone_purge_floor '
      r'WHERE project_id = $1',
      parameters: [projectId],
    );
    if (result.isEmpty) return 0;
    return result.first.first! as int;
  }

  /// Throws [StaleCursorException] if [cursor] sits below [projectId]'s floor.
  ///
  /// **[cursor] of zero is deliberately never stale.** Zero means "send me
  /// everything", which is the full re-pull a joining device performs — it is
  /// asking for the current state rather than claiming to already hold it, so
  /// there is nothing for a missing tombstone to contradict. Refusing it would
  /// break `ProjectJoiner` on any project old enough to have been purged, which
  /// is precisely the project a new device most needs to be able to join.
  Future<void> assertCursorIsFresh({
    required String projectId,
    required int cursor,
  }) async {
    if (cursor == 0) return;
    final floor = await floorFor(projectId);
    if (cursor < floor) {
      throw StaleCursorException(
        projectId: projectId,
        cursor: cursor,
        purgedThroughSeq: floor,
      );
    }
  }

  /// Guards a **push** using the server's own record of where the device is.
  ///
  /// A push carries no cursor — it is a bag of rows — so the position has to
  /// come from `sync_cursors`, written when the device last pulled or
  /// acknowledged (task 11.291 added the pull; before it, a device that only
  /// ever pulled a quiet project had no row here and read as zero on a
  /// purged project). A device with no record at all reads as zero, which only matters on
  /// a project that has actually been purged: publishing a new project leaves
  /// the floor at zero, so the publisher is never refused, while a device that
  /// has never demonstrated it is current cannot push into a project whose
  /// deletes it may have missed.
  ///
  /// **This guard has to exist on push, not only on pull.** Push is where
  /// resurrection actually happens: the row arrives, the server finds nothing
  /// stored (the tombstone was purged), and treats it as a fresh insert. A
  /// retention check that only covered pull would leave the exact hole this
  /// task exists to close.
  Future<void> assertDeviceMayPush({
    required String userId,
    required String deviceId,
    required String projectId,
  }) async {
    final floor = await floorFor(projectId);
    if (floor == 0) return;
    final result = await session.execute(
      r'SELECT acknowledged_seq FROM sync_cursors '
      r'WHERE user_id = $1 AND device_id = $2 AND project_id = $3',
      parameters: [userId, deviceId, projectId],
    );
    final acknowledged = result.isEmpty ? 0 : result.first.first! as int;
    if (acknowledged < floor) {
      throw StaleCursorException(
        projectId: projectId,
        cursor: acknowledged,
        purgedThroughSeq: floor,
      );
    }
  }

  /// Deletes tombstones that are both older than [tombstoneRetention] and below
  /// every still-active device's position, advancing each project's floor.
  ///
  /// **"Older" is measured on `received_at` — the server's clock reading when
  /// it accepted the delete — and not on `deleted_at`, the device's stamp.**
  /// Task 11.291's first-run policy; the library comment above says why. The
  /// device stamp is stored `TEXT` and written by whatever clock the phone
  /// had; `received_at` is the one `TIMESTAMPTZ` on a synced row that is
  /// genuinely the server's own, and it is refreshed on every accepted write,
  /// so a tombstone that was re-written after its deletion is aged from the
  /// later write — the conservative direction.
  ///
  /// **Each project's deletes and its floor advance together, so run this
  /// inside a transaction.** A floor that failed to advance after its
  /// tombstones were deleted would leave a stale device unrefused on a
  /// project that can no longer describe what it missed — which is the
  /// resurrection this whole file exists to prevent. `bin/tombstone_retention
  /// .dart` opens one transaction per call; the tests do the same.
  ///
  /// **Age alone is not sufficient, and this is the part that makes refusing
  /// hard rather than auto-recovering defensible.** "Old" says nothing about
  /// whether anyone still needs it: a device that syncs every week is entirely
  /// current and may still sit below a three-year-old tombstone if it joined
  /// the project recently. Holding the purge at the lowest position among
  /// devices that have synced inside the window means a device that keeps
  /// syncing can never be stranded — so the devices that *do* trip the guard
  /// are exactly those that have been gone longer than the window, which is the
  /// population the policy intends to refuse.
  ///
  /// Global tables (`Users`, `User_Emails`, `Tags`) are deliberately not
  /// purged: they have no `project_id`, so neither a per-project floor nor a
  /// per-project cursor applies to them, and their tombstone volume is
  /// negligible — tens of tags, not thousands of observations. Purging them
  /// safely needs a different scheme; see the plan's Discovered Scope.
  Future<TombstonePurgeReport> purge({DateTime? now}) async {
    final at = (now ?? DateTime.now()).toUtc();
    final cutoff = at.subtract(tombstoneRetention);

    final projectIds = await _projectIds();
    var rowsPurged = 0;
    final floorsAdvanced = <String, int>{};

    for (final projectId in projectIds) {
      final holdback = await _activeDeviceFloor(projectId: projectId, at: at);
      var highestPurged = 0;

      for (final table in purgeableTables) {
        final scope = table.projectScopeColumn!;
        // `server_seq <= holdback` is the active-device holdback; a null
        // holdback (no device has synced this project inside the window) means
        // nothing is holding it back, so the clause is dropped entirely.
        final result = await session.execute(
          'DELETE FROM ${quoted(table.name)} '
          'WHERE ${_expiredTombstone(scope: scope, holdback: holdback)} '
          'RETURNING server_seq',
          parameters: [projectId, cutoff, if (holdback != null) holdback],
        );
        for (final row in result) {
          rowsPurged++;
          final seq = row.first;
          if (seq is int && seq > highestPurged) highestPurged = seq;
        }
      }

      if (highestPurged > 0) {
        await _advanceFloor(
          projectId: projectId,
          throughSeq: highestPurged,
          at: at,
        );
        floorsAdvanced[projectId] = highestPurged;
      }
    }

    return TombstonePurgeReport(
      rowsPurged: rowsPurged,
      floorsAdvanced: floorsAdvanced,
    );
  }

  /// The one definition of "this tombstone may go": scoped to `$1`'s project,
  /// deleted, received before `$2`, and — when an active device bounds the
  /// purge — at or below `$3`. [purge] deletes by it and [measure] counts by
  /// it, so the healthcheck can never call a row overdue that the sweep would
  /// keep, or the reverse.
  static String _expiredTombstone({
    required String scope,
    required int? holdback,
  }) =>
      '${quoted(scope)} = \$1 '
      'AND deleted_at IS NOT NULL '
      r'AND received_at < $2'
      // `server_seq <= holdback` is the active-device holdback; a null
      // holdback (no device has synced this project inside the window) means
      // nothing is holding it back, so the clause is dropped entirely.
      '${holdback == null ? '' : r' AND server_seq <= $3'}';

  /// What the healthcheck reads — see [TombstoneRetentionReading]. Deletes
  /// nothing, advances nothing.
  ///
  /// It walks the same projects, the same tables and the same predicate as
  /// [purge], and additionally counts the tombstones past the window that
  /// the holdback is keeping, and the devices the next sweep would refuse.
  /// The per-project loop is the same shape as the purge's on purpose: an
  /// aggregate written separately would be a second answer to "what is
  /// eligible", and this project has been caught by that before.
  Future<TombstoneRetentionReading> measure({DateTime? now}) async {
    final at = (now ?? DateTime.now()).toUtc();
    final cutoff = at.subtract(tombstoneRetention);

    var held = 0;
    DateTime? oldestHeldReceivedAt;
    var eligible = 0;
    final eligibleProjects = <String>{};
    DateTime? oldestEligibleReceivedAt;
    var heldBack = 0;
    var wouldRefuse = 0;
    final wouldRefuseProjects = <String>{};

    for (final projectId in await _projectIds()) {
      final holdback = await _activeDeviceFloor(projectId: projectId, at: at);
      var highestEligible = 0;

      for (final table in purgeableTables) {
        final scope = table.projectScopeColumn!;
        final all = await session.execute(
          'SELECT count(*), min(received_at) FROM ${quoted(table.name)} '
          'WHERE ${quoted(scope)} = \$1 AND deleted_at IS NOT NULL',
          parameters: [projectId],
        );
        held += all.first[0]! as int;
        oldestHeldReceivedAt = _earlier(
          oldestHeldReceivedAt,
          all.first[1] as DateTime?,
        );

        final past = await session.execute(
          'SELECT count(*) FROM ${quoted(table.name)} '
          'WHERE ${_expiredTombstone(scope: scope, holdback: null)}',
          parameters: [projectId, cutoff],
        );
        final pastWindow = past.first[0]! as int;

        final due = await session.execute(
          'SELECT count(*), min(received_at), max(server_seq) '
          'FROM ${quoted(table.name)} '
          'WHERE ${_expiredTombstone(scope: scope, holdback: holdback)}',
          parameters: [projectId, cutoff, if (holdback != null) holdback],
        );
        final n = due.first[0]! as int;
        eligible += n;
        heldBack += pastWindow - n;
        if (n > 0) {
          eligibleProjects.add(projectId);
          oldestEligibleReceivedAt = _earlier(
            oldestEligibleReceivedAt,
            due.first[1] as DateTime?,
          );
          final seq = due.first[2];
          if (seq is int && seq > highestEligible) highestEligible = seq;
        }
      }

      if (highestEligible > 0) {
        // After the next sweep this project's floor is at least
        // [highestEligible]; every recorded position below it is refused
        // from then on. The active-device holdback bounds [highestEligible]
        // by every position recorded inside the window, so the rows counted
        // here are, by construction, devices that have not synced this
        // project in [tombstoneRetention] — plus any whose ack never landed.
        final refused = await session.execute(
          r'SELECT count(*) FROM sync_cursors '
          r'WHERE project_id = $1 AND acknowledged_seq < $2',
          parameters: [projectId, highestEligible],
        );
        final n = refused.first[0]! as int;
        wouldRefuse += n;
        if (n > 0) wouldRefuseProjects.add(projectId);
      }
    }

    // Devices already refused: positions below a floor an earlier sweep set.
    final alreadyRefused = await session.execute(
      r'SELECT count(*) FROM sync_cursors c '
      r'JOIN tombstone_purge_floor f ON f.project_id = c.project_id '
      r'WHERE c.acknowledged_seq < f.purged_through_seq',
    );

    return TombstoneRetentionReading(
      measuredAt: at,
      window: tombstoneRetention,
      heldTombstones: held,
      oldestHeldReceivedAt: oldestHeldReceivedAt,
      eligibleTombstones: eligible,
      eligibleProjectIds: eligibleProjects,
      oldestEligibleReceivedAt: oldestEligibleReceivedAt,
      heldBackByActiveDevices: heldBack,
      devicesNextSweepWouldRefuse: wouldRefuse,
      projectsNextSweepWouldRefuseOn: wouldRefuseProjects,
      devicesAlreadyRefused: alreadyRefused.first[0]! as int,
    );
  }

  static DateTime? _earlier(DateTime? a, DateTime? b) {
    if (a == null) return b?.toUtc();
    if (b == null) return a;
    return b.isBefore(a) ? b.toUtc() : a;
  }

  Future<List<String>> _projectIds() async {
    final result = await session.execute(
      'SELECT project_id FROM ${quoted(Tables.projects)}',
    );
    return [for (final row in result) row.first! as String];
  }

  /// The lowest acknowledged position among devices that have synced this
  /// project within the retention window, or null if none have.
  Future<int?> _activeDeviceFloor({
    required String projectId,
    required DateTime at,
  }) async {
    final activeSince = at.subtract(tombstoneRetention);
    final result = await session.execute(
      r'SELECT min(acknowledged_seq) FROM sync_cursors '
      r'WHERE project_id = $1 AND last_synced_at >= $2',
      parameters: [projectId, activeSince],
    );
    if (result.isEmpty) return null;
    return result.first.first as int?;
  }

  /// Monotonic, for the same reason `CursorStore.acknowledge` is: a floor that
  /// could regress would let the server claim it can still describe deletes it
  /// has already destroyed.
  Future<void> _advanceFloor({
    required String projectId,
    required int throughSeq,
    required DateTime at,
  }) async {
    await session.execute(
      r'INSERT INTO tombstone_purge_floor '
      r'(project_id, purged_through_seq, last_purged_at) '
      r'VALUES ($1, $2, $3) '
      r'ON CONFLICT (project_id) DO UPDATE SET '
      r'purged_through_seq = GREATEST('
      r'tombstone_purge_floor.purged_through_seq, EXCLUDED.purged_through_seq), '
      r'last_purged_at = EXCLUDED.last_purged_at',
      parameters: [projectId, throughSeq, at],
    );
  }
}
