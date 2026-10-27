import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app_context_provider.dart';
import 'membership_provider.dart';

/// **Task 11.153. Every view of who is on a project — and of what the project
/// is called — refreshed together.**
///
/// This is `refreshTagViews`'s counterpart for memberships, and it is the list
/// that `membership_provider.dart`'s `_afterMembershipChange` used to hold
/// inline. It was moved here for one reason: **the sync merger has to invalidate
/// exactly the same set, and a second copy of the list is a second answer
/// waiting to disagree with the first.**
///
/// **The list was also wrong, and moving it is what showed that.** Measured on
/// riverpod 3.3.2: invalidating a provider does **not** re-run the providers it
/// reads. `myProjectRole` is one line — it returns
/// `projectRoleForUser(projectId, userId)` — and `projectRoleForUser` was not on
/// the list. So invalidating `myProjectRole` rebuilt it, it re-read the *cached*
/// `projectRoleForUser`, and it came back with the same role it started with.
/// What that cost: **an owner changing somebody's role saw the members list
/// update and the "Your role" card not**, on the same screen, from the same tap.
/// The fix is one line — [projectRoleForUserProvider] is on the list now — and
/// `project_view_refresh_test.dart` holds a case that goes red without it.
///
/// [projectId] names the project whose membership changed. **Pass null for
/// "every project on this device"**, which is what a sync pull needs: the page
/// it merged can carry rows for any project and the merger does not report
/// which. Passing null invalidates each family whole rather than one instance.
void refreshProjectViews(Ref ref, {required String? projectId}) =>
    visitProjectViewProviders((p) => ref.invalidate(p), projectId: projectId);

/// [refreshProjectViews] for a caller holding a [ProviderContainer] rather than
/// a [Ref] — tests, and any future non-provider caller.
void refreshProjectViewsIn(
  ProviderContainer container, {
  required String? projectId,
}) => visitProjectViewProviders(
  (p) => container.invalidate(p),
  projectId: projectId,
);

/// **The one list of what "the project views" means — and the one enumeration
/// of it** (task 11.154).
///
/// It takes a visitor rather than doing the invalidating itself so that the
/// guard can read *this* list rather than a copy of it. A test asserting
/// against a transcribed list would be a hand-maintained mirror of something
/// the code already knows, which is this project's most-repeated defect; here
/// the only thing a test knows is how to call this function.
/// `test/core/providers/refresh_lists_test.dart` is what reads it, and what
/// goes red when an entry is dropped or when an entry starts reading something
/// that is not refreshed with it.
///
/// [visit] is passed untyped for the reason `tag_view_refresh.dart` gives:
/// `ProviderOrFamily`, the type both `Ref.invalidate` and
/// `ProviderContainer.invalidate` take, is not exported by any package this app
/// depends on (riverpod 3.3.2). The dynamic call is checked at run time and
/// both callers above pass a real `invalidate`.
void visitProjectViewProviders(
  void Function(dynamic) visit, {
  required String? projectId,
}) {
  // **Not narrowed by [projectId], because none of these is keyed on one.**
  visit(allProjectsProvider);
  visit(ownedProjectIdsProvider);
  visit(departedProjectIdsProvider);
  visit(currentProjectProvider);
  // **Family-wide even when a project is named**, because its second key is the
  // user id and no caller here has one to hand without an await. It is a single
  // indexed row read per live instance, and it is the provider every other role
  // answer on this list is built out of — see the note above about what leaving
  // it off cost.
  visit(projectRoleForUserProvider);
  // Task 11.237: the provider [projectRoleForUserProvider] is now one line
  // over, and the list-screen set of read-only snapshots — which turns live
  // the moment a membership row arrives, so it must be re-derived with the
  // rest.
  visit(projectStandingForUserProvider);
  visit(snapshotProjectIdsProvider);

  if (projectId == null) {
    visit(projectMembershipsProvider);
    visit(projectOwnersProvider);
    visit(isProjectOwnerProvider);
    visit(myProjectStandingProvider);
    visit(myProjectRoleProvider);
    visit(mayWriteProjectDataProvider);
    visit(projectByIdProvider);
    visit(leaveProjectVerdictForProvider);
    return;
  }

  visit(projectMembershipsProvider(projectId));
  visit(projectOwnersProvider(projectId));
  visit(isProjectOwnerProvider(projectId));
  // Task 11.12's role-aware controls read these two for the signed-in user, and
  // a demoted (or promoted) member must see the change reflected immediately —
  // not after the next app restart happens to rebuild the provider fresh.
  visit(myProjectStandingProvider(projectId));
  visit(myProjectRoleProvider(projectId));
  visit(mayWriteProjectDataProvider(projectId));
  visit(projectByIdProvider(projectId));
  // Whether this person may leave is a question about the *other* members —
  // the last open owner cannot — so somebody else's stint ending, or a second
  // owner appearing, changes the answer without this person doing anything.
  visit(leaveProjectVerdictForProvider(projectId));
}
