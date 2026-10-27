/// What each project role may do — the gradient, stated once (task 11.3).
///
/// Task 11.1 moved *ownership* into this package for a reason that applies
/// verbatim to the rest of the gradient: a client and a server that disagree
/// about who may write a row disagree about whether a field record exists. The
/// owner half of the answer is [resolveProjectOwners]; this file is the other
/// two rungs.
///
/// **The server is the authority and the client agrees.** Both sides call the
/// same two predicates below, but they are not equal partners: the app's
/// repository layer uses them so a screen cannot offer a write that will be
/// refused, while the server uses them as the boundary a hostile device meets.
/// A `viewer` who can write because only the UI stopped them is not a viewer.
library;

import 'enums.dart';
import 'project_owners.dart';

/// The rights each rung of the gradient carries.
///
/// Decided 2026-08-17 and recorded in the plan's Phase 11 preamble:
///
/// | Role | Can |
/// | --- | --- |
/// | `viewer` | read the project; record nothing, change nothing |
/// | `contributor` | record observations, edit and delete **their own** |
/// | `owner` | everything, plus manage membership, roles, and data quality |
extension ProjectRoleRights on ProjectRole {
  /// Whether this role may create or change any of the project's own data.
  ///
  /// This is the gradient's **write gate**, and it is deliberately coarser than
  /// the [MutationRule] table rather than a replacement for it. Two questions
  /// are being asked of every write, and they compose:
  ///
  /// 1. *May this person write in this project at all?* — this predicate.
  /// 2. *May they write **this row**?* — the rule table, unchanged, which is
  ///    what keeps a contributor off a colleague's observation.
  ///
  /// A `contributor` answers yes here and is still held to "their own" by (2).
  /// Collapsing the two would break the app: recording one observation also
  /// writes a `Triangulation_Sessions` row and may add a `Tags` row,
  /// and those tables have no author column to be "their own" by — they are
  /// [MutationRule.anyUser], shared project vocabulary. Reading the plan's
  /// "contributor writes its own and nothing else" as *no shared row either*
  /// would leave a contributor unable to record anything at all, which is the
  /// one thing the role is for.
  bool get mayWriteProjectData => this != ProjectRole.viewer;

  /// Whether this role may manage membership, roles, and project settings.
  ///
  /// Owners only. Distinct from [mayWriteProjectData] because the two are not
  /// the same kind of permission: writing project data adds to the record,
  /// while managing membership changes *who else may*. The rule table already
  /// enforces this for the two tables that carry it ([MutationRule.owner] and
  /// [MutationRule.projectOwner]); this is the same answer spelled for callers
  /// that need it before they have a row in hand — a screen deciding whether to
  /// render a control, or a route deciding whether to issue an invitation.
  bool get mayManageProject => this == ProjectRole.owner;
}

/// The role [userId] currently holds in a project, or null if they hold none.
///
/// [membershipRows] must be **every** `Project_Memberships` row for that one
/// project — ended and tombstoned ones included — for the same reason
/// [resolveProjectOwners] requires it: filtering here rather than in each
/// caller's `WHERE` clause is what makes the app's answer and the server's
/// provably the same one. [creatorUserId] is the project's
/// `Projects.owner_user_id`.
///
/// **Ownership is resolved first, through [resolveProjectOwners], and that is
/// load-bearing.** It carries the creator fallback for a project whose
/// membership table names no open owner at all — a project created before task
/// 8.4 adopted the membership table, or the window inside a first publish where
/// the `Projects` row is not yet stored. Answering "no role" there would lock
/// the creator out of their own project.
///
/// Returns null in two cases the caller must tell apart for itself:
///
/// - **Not a member.** No open row, and not the fallback creator.
/// - **A role string this build does not recognise.** A membership row whose
///   `role` is not one of [ProjectRole.values] resolves to null rather than to
///   a guess. Every caller here treats null as *no rights*, which is the only
///   safe reading: a value this build cannot interpret must not be assumed to
///   be the permissive one. (The database `CHECK` constraint and
///   `RowValidator`'s `enumField` both refuse an unknown role on the way in, so
///   this is a backstop rather than an expected path.)
///
/// When two open rows exist for the same (project, user) pair — which task
/// 11.10's partial unique index is being added to make impossible — the
/// **least** permissive of them wins. That is a deliberate change from
/// `findForUser`'s "take the first row", whose arbitrariness is the whole
/// reason the pair invariant exists: an arbitrary answer to a permission
/// question should fail toward less access, not toward more.
ProjectRole? resolveProjectRole({
  required Iterable<Map<String, Object?>> membershipRows,
  required String? creatorUserId,
  required String? userId,
}) {
  if (userId == null || userId.isEmpty) return null;
  final owners = resolveProjectOwners(
    membershipRows: membershipRows,
    creatorUserId: creatorUserId,
  );
  if (owners.contains(userId)) return ProjectRole.owner;

  ProjectRole? held;
  for (final row in membershipRows) {
    if (row['user_id'] != userId) continue;
    if (row['end_date'] != null || row['deleted_at'] != null) continue;
    final role = _roleOf(row['role']);
    if (role == null) continue;
    if (held == null || _rank(role) < _rank(held)) held = role;
  }
  return held;
}

/// [ProjectRole.fromDb] without the throw — an unrecognised value is null.
ProjectRole? _roleOf(Object? value) {
  if (value is! String) return null;
  for (final role in ProjectRole.values) {
    if (role.db == value) return role;
  }
  return null;
}

/// Least permissive first, so `min` over the rank picks the safer answer.
int _rank(ProjectRole role) => switch (role) {
  ProjectRole.viewer => 0,
  ProjectRole.contributor => 1,
  ProjectRole.owner => 2,
};
