/// The "which server projects belong to me" contract (task 10.9).
///
/// Separate from the sync protocol proper (`sync_protocol.dart`): this answers
/// "what can I join/keep syncing", not "give me rows for a project I already
/// know the id of". Phase 10 scopes it to the caller's own projects —
/// same-user-only, per the plan; Phase 11 widens the underlying query to real
/// team membership without changing this shape at all.
library;

import 'project_destruction.dart';
import 'sync_protocol.dart';

/// One project the caller can see, as returned by `GET /projects/mine`.
class ProjectSummary {
  const ProjectSummary({
    required this.projectId,
    required this.projectName,
    required this.ownerUserId,
    required this.role,
    this.destroyAt,
  });

  final String projectId;
  final String projectName;
  final String ownerUserId;

  /// When the server will destroy this project, UTC, or null when no
  /// deletion is scheduled (task 11.290).
  ///
  /// **The fifth field of `GET /projects/mine`, and Security Model §4.28
  /// records the decision to carry it.** It is a fact about the project
  /// rather than about any member: an owner scheduled its destruction, and
  /// every member's bearings are about to go with it. The rows are projects
  /// the caller holds an open membership in, so the caller is exactly the
  /// person this date is addressed to — a contributor cannot cancel it, and
  /// the only thing they can do about it is export before it arrives, which
  /// needs the date. It is set by the server's clock from the server's grace
  /// period; no device ever writes it.
  final DateTime? destroyAt;

  /// The caller's role, e.g. `'owner'` (`ProjectRole.db`, from `enums.dart`).
  /// Phase 10 is same-user-only, so this is always `'owner'` today; carried
  /// as a string rather than an enum reference here so Phase 11 can widen the
  /// set of roles without this shape changing.
  final String role;

  Map<String, Object?> toJson() => {
    'project_id': projectId,
    'project_name': projectName,
    'owner_user_id': ownerUserId,
    'role': role,
    'destroy_at': destroyAt?.toUtc().toIso8601String(),
  };

  /// Task 10.67: was four naked `json[key]! as String` casts — a
  /// wrong-typed entry in `GET /projects/mine`'s `projects` array (including
  /// `owner_user_id`, the identity field the audit specifically asked about)
  /// threw an uncaught `TypeError` instead of the typed
  /// [SyncProtocolException] every other field on this wire already draws.
  /// Not a permissive-fallback case — the old cast crashed rather than
  /// defaulting — but the same present-but-wrong-typed distinction
  /// [requireSyncString] exists to enforce elsewhere on this wire.
  static ProjectSummary fromJson(Map<String, Object?> json) => ProjectSummary(
    projectId: requireSyncString(json, 'project_id'),
    projectName: requireSyncString(json, 'project_name'),
    ownerUserId: requireSyncString(json, 'owner_user_id'),
    role: requireSyncString(json, 'role'),
    // Absent on a server older than task 11.290, which the app has to survive
    // rather than crash on: no date means no deletion is scheduled, which is
    // the truth on such a server.
    destroyAt: optionalSyncTimestamp(json, 'destroy_at'),
  );
}

/// Response envelope for `GET /projects/mine`.
class ProjectDirectoryResponse {
  const ProjectDirectoryResponse({
    required this.projects,
    this.envelope = const SyncEnvelope(),
  });

  final List<ProjectSummary> projects;
  final SyncEnvelope envelope;

  Map<String, Object?> toJson() => {
    ...envelope.toJson(),
    'projects': [for (final p in projects) p.toJson()],
  };

  static ProjectDirectoryResponse fromJson(Map<String, Object?> json) {
    final envelope = SyncEnvelope.fromJson(json);
    final raw = json['projects'];
    final projects = <ProjectSummary>[
      if (raw is List)
        for (final entry in raw)
          if (entry is Map<String, Object?>) ProjectSummary.fromJson(entry),
    ];
    return ProjectDirectoryResponse(projects: projects, envelope: envelope);
  }
}

/// One project the caller deleted from a device and the server still holds
/// as a tombstone — a row of `GET /projects/deleted/mine` (task 11.292).
///
/// ## Why this is a second route and not a sixth field
///
/// `GET /projects/mine` lists the projects the caller has an open membership
/// in and leaves a tombstoned project out for everybody, so a project an
/// owner deleted in the app (task 11.289 carries that deletion to the server
/// as a `deleted_at` on the `Projects` row, records intact) is on no screen of
/// any device — including the owner's — and the only way to destroy it was an
/// operator `INSERT` over `psql`. Carrying such rows on `/projects/mine` would
/// have changed what every existing reader of that route receives, on a
/// row-level condition (owner, and the tombstone's author) that its field
/// table has no column for. A route of its own carries exactly one kind of
/// row, so every consumer is new and every field is defended once.
///
/// ## What a row may carry, and Security Model §4.28 is where that is decided
///
/// Four fields. `project_id` and `project_name` are what an owner holding an
/// open membership already receives from a pull of the project (its
/// `Projects` row travels, tombstone included). `deleted_at` is the caller's
/// own act: the route lists only tombstones whose `last_modified_by` the
/// server verified to be the caller (§4.17 refuses an audit name that is not
/// the caller's on an update), so the sentence *"you deleted this on"* is one
/// the server can stand behind. `destroy_at` is the same fact `/projects/mine`
/// carries, for the same reason. **No `owner_user_id` and no `role`**: the
/// route is owner-only by construction, so both would be the caller's own id
/// and the word `owner`, and a field that can only ever say one thing is a
/// field to leave off.
///
/// `test/documentation/project_directory_field_set_test.dart` diffs this
/// class's `toJson` against §4.28's second table, so a fifth field cannot
/// appear without that section being amended.
class DeletedProjectSummary {
  const DeletedProjectSummary({
    required this.projectId,
    required this.projectName,
    required this.deletedAt,
    this.destroyAt,
  });

  final String projectId;
  final String projectName;

  /// When the caller's device deleted it, UTC — the device's own stamp on the
  /// `Projects` row, which the row validator bounds to a timestamp. Null only
  /// if a stored value could not be read back as one, which nothing that
  /// passed the validator can produce; carried as nullable so a server never
  /// has to refuse the whole list over one unreadable stamp.
  final DateTime? deletedAt;

  /// When the server will destroy it, or null when no destruction is
  /// scheduled — the same field, on the same footing, as
  /// [ProjectSummary.destroyAt].
  final DateTime? destroyAt;

  Map<String, Object?> toJson() => {
    'project_id': projectId,
    'project_name': projectName,
    'deleted_at': deletedAt?.toUtc().toIso8601String(),
    'destroy_at': destroyAt?.toUtc().toIso8601String(),
  };

  static DeletedProjectSummary fromJson(Map<String, Object?> json) =>
      DeletedProjectSummary(
        projectId: requireSyncString(json, 'project_id'),
        projectName: requireSyncString(json, 'project_name'),
        deletedAt: optionalSyncTimestamp(json, 'deleted_at'),
        destroyAt: optionalSyncTimestamp(json, 'destroy_at'),
      );
}

/// Response envelope for `GET /projects/deleted/mine` (task 11.292).
class DeletedProjectDirectoryResponse {
  const DeletedProjectDirectoryResponse({
    required this.projects,
    this.envelope = const SyncEnvelope(),
  });

  final List<DeletedProjectSummary> projects;
  final SyncEnvelope envelope;

  Map<String, Object?> toJson() => {
    ...envelope.toJson(),
    'projects': [for (final p in projects) p.toJson()],
  };

  static DeletedProjectDirectoryResponse fromJson(Map<String, Object?> json) {
    final envelope = SyncEnvelope.fromJson(json);
    final raw = json['projects'];
    final projects = <DeletedProjectSummary>[
      if (raw is List)
        for (final entry in raw)
          if (entry is Map<String, Object?>)
            DeletedProjectSummary.fromJson(entry),
    ];
    return DeletedProjectDirectoryResponse(
      projects: projects,
      envelope: envelope,
    );
  }
}
