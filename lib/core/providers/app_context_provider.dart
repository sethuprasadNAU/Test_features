import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:uuid/uuid.dart';

import '../../data/db/data_arrival.dart';
import '../../data/models/project.dart';
import '../../data/models/sync_meta.dart';
import '../../data/models/tag.dart';
import '../../data/models/user.dart';
import 'package:tritrack_sync/tritrack_sync.dart';
import '../../data/repositories/project_membership_repository.dart';
import '../../data/repositories/repository_providers.dart';
import 'active_selection_provider.dart';
import 'auth_provider.dart';
import 'device_id_provider.dart';
import '../../data/repositories/mutation_authorization.dart';

part 'app_context_provider.g.dart';

/// Resolves [ActiveUserId] to a full [User] row, auto-creating a single local
/// "Field User" the first time the app runs on a device with no user yet.
/// Phase One has no login flow (parked under More, un-designed), so every
/// screen that needs a `userId` for audit columns goes through this instead
/// of assuming one exists.
///
/// If `active_user_id` survives in `SharedPreferences` but the row itself is
/// gone (the DB file was replaced, or the row was tombstoned by a merge —
/// [UserRepository.findById] excludes tombstones by default), this used to
/// silently mint a brand-new user, orphaning every observation/tag/project
/// already attributed to the old id with no way back. It now prefers
/// recovering that row (clearing its tombstone) over creating a second
/// identity; a genuinely new user is only minted when the id can't be found
/// at all, and that placeholder-email row is exactly what
/// [User.hasPlaceholderIdentity] treats as "identity not yet set" — so the
/// Phase 7 identity gate (`SplashScreen`/`IdentitySetupScreen`) surfaces the
/// recreation to the user on this same launch rather than doing it silently.
@Riverpod(keepAlive: true)
Future<User> currentUser(Ref ref) async {
  // `ref.read`, not `watch`: this provider itself writes `activeUserIdProvider`
  // below (auto-creating a user the first time), and watching + mutating the
  // same dependency inside one computation makes Riverpod restart the build
  // mid-flight, orphaning the original Future forever (it never resolves).
  final activeId = await ref.read(activeUserIdProvider.future);
  final repo = await ref.watch(userRepositoryProvider.future);
  final deviceId = await ref.watch(deviceIdProvider.future);

  if (activeId != null) {
    final existing = await repo.findById(activeId);
    if (existing != null) return existing;

    final tombstoned = await repo.findById(activeId, includeDeleted: true);
    if (tombstoned != null) {
      await repo.restoreById(
        activeId,
        actor: MutationActor.user(activeId),
        deviceId: deviceId,
      );
      // The log names the author of every row from the `Users` table; a user
      // row coming back from a tombstone changes what it can name (11.45).
      DataArrival.announce();
      return (await repo.findById(activeId))!;
    }

    // `activeId` is neither present nor tombstoned. The one way this
    // currently happens: `CurrentSession.completeSignIn` (auth_provider.dart)
    // was interrupted after `ServerIdentityAdopter.adopt()` committed — which
    // hard-deletes this device's old local `Users` row, because adoption
    // folds it onto the server's id rather than leaving both around (a
    // tombstone here would be false: the person still exists, under the new
    // id — see that class's own doc comment) — but before `ActiveUserId` was
    // repointed at the adopted id. A stored session survives that same
    // interruption whenever it was written first (`completeSignIn`'s
    // deliberate ordering: adopt, then store the session, then repoint
    // `ActiveUserId` last), so recovering through it — rather than minting a
    // third identity and stranding the data that was just correctly
    // adopted — is possible whenever the session made it to disk before the
    // interruption.
    final session = await ref.read(sessionStoreProvider).read();
    if (session != null && !session.isExpiredAt(DateTime.now().toUtc())) {
      final adopted = await repo.findById(session.userId);
      if (adopted != null) {
        await ref.read(activeUserIdProvider.notifier).set(adopted.userId);
        return adopted;
      }
    }
  }

  final newUserId = const Uuid().v4();
  final user = User(
    userId: newUserId,
    firstName: 'Field',
    lastName: 'User',
    email: 'field-user-${const Uuid().v4()}@local.tritrack',
    sync: SyncMeta.initial(
      now: DateTime.now(),
      modifiedBy: newUserId,
      originDeviceId: deviceId,
    ),
  );
  await repo.insert(user);
  DataArrival.announce();
  await ref.read(activeUserIdProvider.notifier).set(user.userId);
  return user;
}

/// Backfills the creator's `Project_Memberships` row for [project] if the
/// project has **no open owner membership at all** (task 8.4, corrected by
/// 11.1) — the same "recover on load rather than migrate" approach
/// [currentUser] already uses for its own recovery case, applied here to
/// projects created before this table was adopted. Idempotent: it
/// short-circuits once an owner membership exists, so this is a cheap no-op on
/// every subsequent load.
///
/// **The condition changed in 11.1, and it had to.** 8.4 asked whether
/// `project.ownerUserId` had *any* open membership — any role, and only that
/// user's. Once ownership can be transferred, that question has two wrong
/// answers. A creator who handed the project on and ended their own owner
/// stint has no open membership, so the next project load would silently hand
/// ownership straight back to them, undoing the transfer without anyone
/// asking. And a creator demoted to contributor still has an open membership,
/// so a project whose only owner had left would *not* be repaired. Asking
/// about the project's owners instead of about one user's row answers both.
///
/// ## It takes no `Ref`, and that is the fix for task 11.235
///
/// It used to take the caller's `Ref` and `ref.watch` the membership
/// repository and the device id itself — **after an `await`, inside a loop,
/// from providers that auto-dispose.** [allProjects] is read by the tag
/// database's + button through `ref.read(allProjectsProvider.future)`, a read
/// with no listener behind it, so Riverpod disposes the provider a microtask
/// after the read returns while its body is still working through the
/// projects. The next `ref.watch` threw *"Cannot use the Ref of
/// allProjectsProvider after it has been disposed"*, the future the dialog was
/// waiting on never delivered, and the button did nothing. Measured on
/// Michael's phone (2026-09-13) and reproduced in
/// `test/features/more/tag_database_plus_button_test.dart`.
///
/// Now every caller resolves what this needs **before** it starts any
/// per-project work and passes it in, so the helper never touches a `Ref` at
/// all. `ref.mounted` checks after each gap would have silenced the exception
/// and left the button just as broken — the loop would abandon its repair
/// quietly — which is why this is a change of shape and not a guard.
///
/// ## A write inside a read — stated, not moved (task 11.235 §4)
///
/// This is a **write** (a membership row inserted or promoted) running inside
/// providers whose job is to **answer a question**, and that is what made the
/// defect possible: a read may be thrown away at any moment, and a repair
/// running inside it was thrown away with it. It stays here for now, with the
/// reasoning written down rather than assumed:
///
/// - **Why it is safe to run from a disposable read after this change.** The
///   repair is a plain Dart future once it starts: disposing the provider no
///   longer interrupts it, because nothing in it can fail on a dead `Ref`.
///   Riverpod keeps `provider.future` attached to the body's own future on
///   dispose (`ElementWithFuture.dispose` — "let `provider.future` resolve
///   with the last value"), so a bare `read` still receives the list *after*
///   every repair in the loop has finished. The database write itself is one
///   `INSERT`/`UPDATE` per project and cannot be half-done.
/// - **What still holds only by habit.** It is idempotent, and idempotent
///   means safe to *repeat*, not safe to *interrupt* — the interruption is
///   exactly what broke the screen. What protects it now is the absence of
///   `Ref` use, which a later edit could reintroduce in one line.
///   `test/core/providers/no_ref_after_await_in_owner_repair_test.dart` reads
///   this function's body and refuses a `ref.` inside it.
/// - **Where it would belong instead.** Once at startup, or once per sync
///   round (the two moments a project can newly lack an owner row: a
///   pre-8.4 database, and a merge landing mid-transfer). Moving it is a
///   decision about when a project without an owner gets one, with the
///   history above behind it, and this task did not take it. Recorded for the
///   planning session.
///
/// [currentProject] carries the same call and never failed **only because it
/// is `keepAlive`** — nothing ever disposed it mid-build. That was luck; it is
/// now written down as the condition it is, and the guard test reads the
/// annotation, so removing `keepAlive` from that provider fails a test rather
/// than reintroducing this defect on the Map screen.
Future<void> _ensureOwnerMembership(
  ProjectMembershipRepository membershipRepo,
  String? deviceId,
  Project project,
) {
  return membershipRepo.ensureOwnerMembership(
    projectId: project.projectId,
    creationDate: project.creationDate,
    now: DateTime.now(),
    deviceId: deviceId,
  );
}

/// The two things [_ensureOwnerMembership] needs, resolved in one place so
/// each caller `ref.watch`es them before its first `await` on the database.
///
/// **Every `ref.watch` is issued before the first `await`**, on purpose: an
/// auto-disposing provider read without a listener is disposed one microtask
/// after the read returns, so even a `ref.watch` behind an `await` of an
/// already-resolved future is a `ref.watch` on a `Ref` that may be dead.
/// Issuing the watches synchronously registers every dependency while the
/// `Ref` is certainly alive; the awaits that follow touch no `Ref`.
Future<(ProjectMembershipRepository, String?)> _ownerRepairInputs(Ref ref) async {
  final membershipRepo = ref.watch(projectMembershipRepositoryProvider.future);
  final deviceId = ref.watch(deviceIdProvider.future);
  return (await membershipRepo, await deviceId);
}

/// Resolves [ActiveProjectId] to a full [Project] row. Null means no project
/// has been created/selected yet — screens should show a "set up a project"
/// empty state rather than assuming one exists.
@Riverpod(keepAlive: true)
Future<Project?> currentProject(Ref ref) async {
  // **`keepAlive` is load-bearing here, and the guard test asserts it.** The
  // repair inputs are fetched *after* the awaits below, which the two
  // auto-disposing callers may not do — a bare read of them is disposed one
  // microtask after it returns. Nothing disposes this provider mid-build, so
  // the order is legal; and it has to be this order, because this provider
  // must not touch the database when there is no active project (every
  // screen test that pumps without a project relies on that — an opened
  // database inside a widget test's fake clock is a dead pump loop, and
  // task 11.235 measured exactly that hang when it tried the other order).
  final activeId = await ref.watch(activeProjectIdProvider.future);
  if (activeId == null) return null;
  final repo = await ref.watch(projectRepositoryProvider.future);
  final project = await repo.findById(activeId);
  if (project != null) {
    final (membershipRepo, deviceId) = await _ownerRepairInputs(ref);
    await _ensureOwnerMembership(membershipRepo, deviceId, project);
  }
  return project;
}

/// Resolves an arbitrary project by id — used by the Projects list screen
/// to edit/view a project that isn't necessarily the active one.
///
/// **Auto-disposing, with the same repair call as [allProjects]**, so it had
/// the same defect shape (task 11.235): a bare `ref.read(...future)` of it
/// would dispose it mid-repair. Every `ref.watch` now happens before the
/// first `await`, and the repair takes no `Ref`.
@riverpod
Future<Project?> projectById(Ref ref, String projectId) async {
  final repair = _ownerRepairInputs(ref);
  final repo = await ref.watch(projectRepositoryProvider.future);
  final (membershipRepo, deviceId) = await repair;
  final project = await repo.findById(projectId);
  if (project != null) {
    await _ensureOwnerMembership(membershipRepo, deviceId, project);
  }
  return project;
}

/// All non-deleted projects, for the Projects switcher/list screen — and the
/// tag database's + button, which is how task 11.235 found it (see
/// [_ensureOwnerMembership]).
///
/// **Every `ref.watch` is issued before the first `await`.** The repair loop
/// below runs on plain values and can be disposed out from under without
/// failing; `provider.future` still resolves with the finished list.
@riverpod
Future<List<Project>> allProjects(Ref ref) async {
  final repair = _ownerRepairInputs(ref);
  final repo = await ref.watch(projectRepositoryProvider.future);
  final projects = await repo.findAll();
  final (membershipRepo, deviceId) = await repair;
  for (final project in projects) {
    await _ensureOwnerMembership(membershipRepo, deviceId, project);
  }
  return projects;
}

/// [userId]'s standing on [projectId] — their role, *not a member*, or *this
/// device cannot say* (task 11.237; see [ProjectStanding] for the three).
///
/// **Routed through [BaseRepository.projectStandingFor]** — the exact query
/// `BaseRepository.assertRoleMayWrite` runs before every write, creator
/// fallback via [resolveProjectOwners] included, least-permissive-of-two-open-
/// rows included. A screen asking "may I offer this control" and a repository
/// asking "may this write proceed" must get the same answer from the same
/// membership rows, or a control this provider enabled could still be refused
/// at the tap. (Task 11.12 established that for the role; 11.237 widened the
/// answer and kept the single source.) [ProjectMembershipRepository] extends
/// [BaseRepository], so the call costs nothing extra.
///
/// **Derived on every read.** Nothing stores "this project is read-only": the
/// day this person's open membership row arrives by sync,
/// [refreshProjectViews] invalidates this and the snapshot is a live project
/// with no re-import.
@riverpod
Future<ProjectStanding> projectStandingForUser(
  Ref ref,
  String projectId,
  String userId,
) async {
  final membershipRepo = await ref.watch(
    projectMembershipRepositoryProvider.future,
  );
  return membershipRepo.projectStandingFor(projectId, userId);
}

/// [userId]'s role on [projectId], or null if they aren't a member — the
/// "what's my role here" read task 8.1/8.3 anticipated, routed through
/// [ProjectMembershipRepository] rather than a raw query (task 8.4).
///
/// One line over [projectStandingForUser] since task 11.237, so the two cannot
/// disagree. Callers that need to tell *not a member* from *cannot say* read
/// the standing; this is for the ones that only want the rung.
@riverpod
Future<ProjectRole?> projectRoleForUser(
  Ref ref,
  String projectId,
  String userId,
) async =>
    (await ref.watch(projectStandingForUserProvider(projectId, userId).future))
        .role;

/// The signed-in user's standing on [projectId] — resolving `userId` off
/// [currentUserProvider] so call sites don't each re-fetch it.
///
/// **Reads [ProjectMembershipRepository] directly rather than
/// `ref.watch(projectStandingForUserProvider(...).future)` (task 11.236).**
/// This is `mayWriteProjectDataProvider`'s dependency, and
/// `mayWriteProjectDataProvider` is read bare — `ref.read(...future)`, no
/// listener — by [_projectsThisPersonMayAddTo] in `tag_database_screen.dart`
/// and by the Record screen's *Add new tag*, in a per-project loop, the exact
/// shape [_ensureOwnerMembership] broke on. `userId` here only exists after
/// an `await`, so the second lookup this used to make —
/// `projectStandingForUserProvider(projectId, userId)` — could never be
/// resolved before that gap the way [_ownerRepairInputs] resolves its two
/// inputs; **it was a `ref.watch` after an `await`, on a `Ref` that this
/// whole chain can lose the moment its only listener is a bare read.** Going
/// straight to the repository sidesteps the second `ref` call rather than
/// reordering it, since there is nothing to reorder it to.
@riverpod
Future<ProjectStanding> myProjectStanding(Ref ref, String projectId) async {
  final userFuture = ref.watch(currentUserProvider.future);
  final membershipRepoFuture = ref.watch(
    projectMembershipRepositoryProvider.future,
  );
  final userId = (await userFuture).userId;
  final membershipRepo = await membershipRepoFuture;
  return membershipRepo.projectStandingFor(projectId, userId);
}

/// The signed-in user's role on [projectId], via [myProjectStanding].
@riverpod
Future<ProjectRole?> myProjectRole(Ref ref, String projectId) async =>
    (await ref.watch(myProjectStandingProvider(projectId).future)).role;

/// Whether the signed-in user may create or change project data in
/// [projectId] — the UI-layer gate for task 11.12's sweep, mirroring
/// [BaseRepository.assertRoleMayWrite]'s own permit logic exactly: a standing
/// this device cannot resolve defers to the server and permits, a `viewer` is
/// refused, and so is somebody the device can see is not on the project at all
/// (task 11.237). Owner-only affordances (membership, project settings) stay
/// on [isProjectOwnerProvider]; this is the coarser "may write anything in
/// this project at all" rung below it.
///
/// A screen that has a sentence to show when this is false should read
/// [myProjectStandingProvider] and ask `writeRefusal` instead, because *why*
/// it is false decides which sentence is true.
@riverpod
Future<bool> mayWriteProjectData(Ref ref, String projectId) async =>
    (await ref.watch(myProjectStandingProvider(projectId).future))
        .mayWriteProjectData;

/// The ids of every project on this device that is a **read-only snapshot**
/// for the signed-in user — here, with its membership rows here, and none of
/// them theirs (task 11.237).
///
/// The list-screen counterpart of [myProjectStanding], on the same pattern as
/// [ownedProjectIds]: one lookup for the whole list, so a screen rendering N
/// rows does not open N asynchronous questions that resolve at N different
/// moments. Derived per read, never stored — see [ProjectStanding].
///
/// **It uses `ref` after its first `await`, and that is safe because nothing
/// reads it bare** (task 11.256). Task 11.238 flagged the shape; the
/// measurement in `ref_after_await_hazards_test.dart` shows the failure needs
/// a read with no listener as well as the shape, and
/// `ref_after_await_guard_test.dart` goes red the day a `.read(` of this
/// appears anywhere in `lib/` — so the statement is checked, not remembered.
@riverpod
Future<Set<String>> snapshotProjectIds(Ref ref) async {
  final projects = await ref.watch(allProjectsProvider.future);
  final userId = (await ref.watch(currentUserProvider.future)).userId;
  final membershipRepo = await ref.watch(
    projectMembershipRepositoryProvider.future,
  );
  final snapshots = <String>{};
  for (final project in projects) {
    final standing = await membershipRepo.projectStandingFor(
      project.projectId,
      userId,
    );
    if (standing.isSnapshot) snapshots.add(project.projectId);
  }
  return snapshots;
}

/// [projectId]'s current owners (task 11.1) — the read that replaced
/// `Projects.owner_user_id` as the answer to "who may manage this project".
///
/// Separate from [projectRoleForUser] on purpose. A role lookup answers about
/// one person and takes `rows.first`; ownership is a *set*, and the whole
/// point of 11.1 is that it can hold more than one name.
@riverpod
Future<Set<String>> projectOwners(Ref ref, String projectId) async {
  final membershipRepo = await ref.watch(
    projectMembershipRepositoryProvider.future,
  );
  return membershipRepo.ownersOf(projectId);
}

/// The ids of every project on this device the signed-in user currently owns.
///
/// The list-screen counterpart of [isProjectOwner]: one lookup for the whole
/// list, so a screen rendering N rows does not open N asynchronous ownership
/// questions and have them resolve at N different moments.
@riverpod
Future<Set<String>> ownedProjectIds(Ref ref) async {
  final projects = await ref.watch(allProjectsProvider.future);
  final userId = (await ref.watch(currentUserProvider.future)).userId;
  final membershipRepo = await ref.watch(
    projectMembershipRepositoryProvider.future,
  );
  final owned = <String>{};
  for (final project in projects) {
    final owners = await membershipRepo.ownersOf(
      project.projectId,
      creatorUserId: project.ownerUserId,
    );
    if (owners.contains(userId)) owned.add(project.projectId);
  }
  return owned;
}

/// Whether the signed-in user is one of [projectId]'s current owners — the
/// UI-layer gate for every owner-only affordance.
///
/// This is what task 8.3's `MutationRule.owner.permits(uid, ownerUserId)`
/// became. It is asynchronous where that was synchronous, which is the honest
/// shape: the answer now depends on rows, not on a column already in hand.
@riverpod
Future<bool> isProjectOwner(Ref ref, String projectId) async {
  final userId = (await ref.watch(currentUserProvider.future)).userId;
  return (await ref.watch(
    projectOwnersProvider(projectId).future,
  )).contains(userId);
}

/// Active tags for one project, sorted by frequency — the input list for the
/// tag wheel picker in Observation Logging and the tag selector in Position
/// Estimation.
///
/// **One read since task 11.219, where it used to be a link-then-lookup.** A
/// tag belongs to one project now, so this is `WHERE project_id = ?` and a
/// status filter; there is no `Project_Tags` link to resolve and no global
/// table to look each id up in.
///
/// **Refreshed by [refreshTagViews] — see that function for task 11.151.**
@riverpod
Future<List<Tag>> projectActiveTags(Ref ref, String projectId) async {
  final tagRepo = await ref.watch(tagRepositoryProvider.future);
  final tags = [
    for (final tag in await tagRepo.findByProject(projectId))
      if (tag.status == TagStatus.active) tag,
  ]..sort((a, b) => a.frequencyMhz.compareTo(b.frequencyMhz));
  return tags;
}

/// Every tag in one project, **including ones removed from it and ones whose
/// collar is recovered, lost or malfunctioning** — for the screens that have
/// to show what a project once used, not only what it uses now.
///
/// Project Setup lists these so a removed tag can be seen and added back, and
/// Position Estimation offers them so a recovered collar's historical
/// bearings can still be solved.
///
/// **"Removed from this project" is a tombstone on the project's own tag row
/// since task 11.219**, where it used to be `Project_Tags.status = inactive`.
/// The row stays — soft-delete, never a hard one — so every bearing that
/// names it still resolves and the removal can be undone.
///
/// **Refreshed by [refreshTagViews] — see that function for task 11.151.**
@riverpod
Future<List<Tag>> projectTags(Ref ref, String projectId) async {
  final tagRepo = await ref.watch(tagRepositoryProvider.future);
  return tagRepo.findByProject(projectId, includeDeleted: true);
}
