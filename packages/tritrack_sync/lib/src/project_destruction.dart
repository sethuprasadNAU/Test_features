/// Destroying a project on the server, on a schedule every member can see
/// (task 11.290).
///
/// ## What this is for
///
/// Governance, not disk space. A bearing is a few numbers; what a researcher
/// needs is to say *"that project is gone"* and have it be true — a permit
/// condition, a landowner agreement, a collaborator who withdraws consent.
/// *"It is flagged deleted and hidden"* does not answer that, and the ordinary
/// delete (a `deleted_at` tombstone on the `Projects` row) is exactly that.
///
/// ## The shape, as Michael specified it on 2026-09-20
///
/// 1. An owner **schedules** the project for deletion. The server stamps the
///    date the project will be destroyed — its own clock, its own grace
///    period — and every member's device learns it from `GET /projects/mine`.
/// 2. The project stays in every member's list, marked, with the days left.
///    A contributor cannot cancel; they can export.
/// 3. The owner can **cancel** any time before the clock runs out.
/// 4. *Delete immediately* is offered behind a second confirmation.
/// 5. When the clock runs out **the server** destroys the project and every
///    row in it — on its own timer, with no device involved.
///
/// ## Why the server owns the clock
///
/// An owner who schedules a deletion and leaves for a field season must not
/// end up with a project that quietly never dies because no device came back
/// to sync it; and a device with a wrong clock must not be able to move
/// somebody else's deadline. So the destroy date is set by the server, in
/// UTC, from a grace period the server is configured with, and a device only
/// ever *reads* it.
///
/// ## What is on this wire
///
/// The file holds the two things both sides have to agree on: the JSON shape
/// of a deletion's standing, and the refusal code a destroyed project draws.
/// The mechanism — the table, the sweep, the routes — is the server's, in
/// `server/lib/src/projects/project_destruction_service.dart`.
library;

import 'sync_protocol.dart';

/// The refusal a request about a **destroyed** project draws: `403` with this
/// code, on `/sync/push`, `/sync/pull` and `/sync/ack`.
///
/// **This is a deliberate, narrow exception to §4.13's rule that a forbidden
/// project and a fabricated one must be indistinguishable**, and it exists
/// because the alternative resurrects the project. Once a project's rows are
/// gone the server holds nothing for `ProjectAuthorizer` to resolve, so the
/// project reads as *absent* — and an absent project is exactly the one a
/// publish may establish. An owner's device that was offline across the
/// deletion holding a pending rename would re-create the project on its next
/// round, with no person deciding to. So the server keeps a record that the
/// id was destroyed and refuses it, and a refusal that must exist anyway
/// might as well say why: without a name, the device that never saw the
/// countdown would tell its owner *"an owner may have removed you"*, which is
/// the wrong-cause class this project spends most of its effort on. What the
/// exception discloses is that an identifier once named a project here and no
/// longer does — to a signed-in caller who already holds that identifier.
const String syncRefusalProjectDestroyed = 'project_destroyed';

/// What the owner may ask the server to do about a project's deletion, on
/// `POST /projects/<id>/deletion`.
enum ProjectDeletionAction {
  /// Schedule the destruction for the end of the server's grace period. On a
  /// project already scheduled this changes nothing and answers the existing
  /// standing — a second tap never moves the date.
  schedule('schedule'),

  /// Destroy now, inside this request. **Not "permanently"** — the backups
  /// keep archives for about a month, and the copy on every member's device
  /// is theirs. The wording the app uses is the server's promise, and it says
  /// exactly that.
  immediate('immediate'),

  /// Withdraw a scheduled destruction. Nothing to withdraw is not an error:
  /// the standing comes back unscheduled either way.
  cancel('cancel'),

  /// **Undo the in-app delete** (task 11.302): clear the project's tombstone
  /// on the server, so it comes back for every member with every record
  /// still in it, and withdraw any destruction scheduled for it in the same
  /// act. Only for the owner who deleted it — exactly the people
  /// `GET /projects/deleted/mine` lists it for, and the server derives the
  /// one from the other. On a project that is not deleted it changes nothing
  /// and answers the standing, so a retry after a lost answer is not an
  /// error. A destroyed project cannot be restored: there is nothing left.
  restore('restore');

  const ProjectDeletionAction(this.wire);

  /// The string on the wire.
  final String wire;

  static ProjectDeletionAction? fromWire(Object? value) {
    if (value is! String) return null;
    for (final action in values) {
      if (action.wire == value) return action;
    }
    return null;
  }
}

/// Where a project's deletion stands, as the server reports it.
///
/// Carried by `GET /projects/<id>/deletion` and by every `POST` to the same
/// path, so the screen that just scheduled or canceled draws what the server
/// now holds rather than what it assumes.
class ProjectDeletionStanding {
  const ProjectDeletionStanding({
    required this.graceDays,
    required this.backupRetentionDays,
    this.scheduledAt,
    this.destroyAt,
    this.executedAt,
  });

  /// The grace period this server applies to a newly scheduled deletion, in
  /// whole days. **The app shows this number before the owner commits**, so
  /// the dialog says what the server will actually do rather than what a
  /// default somewhere might be.
  final int graceDays;

  /// How many days the server's backups keep an archive — the number the
  /// *delete now* sentence has to carry. "Removed from the server now" is
  /// true the moment the request returns; "gone" is only true once the last
  /// archive holding the project has been pruned, and that is this many days
  /// away whatever the live server does. Sent by the server rather than
  /// assumed by the app, because an institution that keeps ninety archives
  /// must not be told thirty.
  final int backupRetentionDays;

  /// When the deletion was scheduled, UTC, or null when it is not scheduled.
  final DateTime? scheduledAt;

  /// When the server will destroy the project, UTC — the server's clock, the
  /// server's grace period. Null when nothing is scheduled.
  final DateTime? destroyAt;

  /// When the server destroyed it, UTC, or null while it still exists. Only
  /// ever set on the answer to an `immediate` request: after that the project
  /// has no members, so nobody can ask about it again.
  final DateTime? executedAt;

  bool get isScheduled => destroyAt != null && executedAt == null;

  Map<String, Object?> toJson() => {
    'grace_days': graceDays,
    'backup_retention_days': backupRetentionDays,
    'scheduled_at': scheduledAt?.toUtc().toIso8601String(),
    'destroy_at': destroyAt?.toUtc().toIso8601String(),
    'executed_at': executedAt?.toUtc().toIso8601String(),
  };

  static ProjectDeletionStanding fromJson(Map<String, Object?> json) =>
      ProjectDeletionStanding(
        graceDays: optionalSyncInt(json, 'grace_days') ?? 0,
        backupRetentionDays:
            optionalSyncInt(json, 'backup_retention_days') ?? 0,
        scheduledAt: optionalSyncTimestamp(json, 'scheduled_at'),
        destroyAt: optionalSyncTimestamp(json, 'destroy_at'),
        executedAt: optionalSyncTimestamp(json, 'executed_at'),
      );
}

/// `json[key]` parsed as a UTC instant when present; null when absent or
/// explicitly null; [SyncProtocolException] when present and not a parseable
/// timestamp string. The same absent-versus-wrong distinction
/// [optionalSyncInt] draws, for the same reason.
DateTime? optionalSyncTimestamp(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value == null) return null;
  if (value is! String) {
    throw SyncProtocolException('"$key" must be a timestamp string.');
  }
  final parsed = DateTime.tryParse(value);
  if (parsed == null) {
    throw SyncProtocolException('"$key" must be a timestamp string.');
  }
  return parsed.toUtc();
}
