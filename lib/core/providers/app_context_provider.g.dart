// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'app_context_provider.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint, type=warning
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

@ProviderFor(currentUser)
final currentUserProvider = CurrentUserProvider._();

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

final class CurrentUserProvider
    extends $FunctionalProvider<AsyncValue<User>, User, FutureOr<User>>
    with $FutureModifier<User>, $FutureProvider<User> {
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
  CurrentUserProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'currentUserProvider',
        isAutoDispose: false,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$currentUserHash();

  @$internal
  @override
  $FutureProviderElement<User> $createElement($ProviderPointer pointer) =>
      $FutureProviderElement(pointer);

  @override
  FutureOr<User> create(Ref ref) {
    return currentUser(ref);
  }
}

String _$currentUserHash() => r'd1a49008c2a7888af4ae336b3977a951928a0895';

/// Resolves [ActiveProjectId] to a full [Project] row. Null means no project
/// has been created/selected yet — screens should show a "set up a project"
/// empty state rather than assuming one exists.

@ProviderFor(currentProject)
final currentProjectProvider = CurrentProjectProvider._();

/// Resolves [ActiveProjectId] to a full [Project] row. Null means no project
/// has been created/selected yet — screens should show a "set up a project"
/// empty state rather than assuming one exists.

final class CurrentProjectProvider
    extends
        $FunctionalProvider<AsyncValue<Project?>, Project?, FutureOr<Project?>>
    with $FutureModifier<Project?>, $FutureProvider<Project?> {
  /// Resolves [ActiveProjectId] to a full [Project] row. Null means no project
  /// has been created/selected yet — screens should show a "set up a project"
  /// empty state rather than assuming one exists.
  CurrentProjectProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'currentProjectProvider',
        isAutoDispose: false,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$currentProjectHash();

  @$internal
  @override
  $FutureProviderElement<Project?> $createElement($ProviderPointer pointer) =>
      $FutureProviderElement(pointer);

  @override
  FutureOr<Project?> create(Ref ref) {
    return currentProject(ref);
  }
}

String _$currentProjectHash() => r'4f038131004768e2bd46d8a65a890874e1f67e2a';

/// Resolves an arbitrary project by id — used by the Projects list screen
/// to edit/view a project that isn't necessarily the active one.
///
/// **Auto-disposing, with the same repair call as [allProjects]**, so it had
/// the same defect shape (task 11.235): a bare `ref.read(...future)` of it
/// would dispose it mid-repair. Every `ref.watch` now happens before the
/// first `await`, and the repair takes no `Ref`.

@ProviderFor(projectById)
final projectByIdProvider = ProjectByIdFamily._();

/// Resolves an arbitrary project by id — used by the Projects list screen
/// to edit/view a project that isn't necessarily the active one.
///
/// **Auto-disposing, with the same repair call as [allProjects]**, so it had
/// the same defect shape (task 11.235): a bare `ref.read(...future)` of it
/// would dispose it mid-repair. Every `ref.watch` now happens before the
/// first `await`, and the repair takes no `Ref`.

final class ProjectByIdProvider
    extends
        $FunctionalProvider<AsyncValue<Project?>, Project?, FutureOr<Project?>>
    with $FutureModifier<Project?>, $FutureProvider<Project?> {
  /// Resolves an arbitrary project by id — used by the Projects list screen
  /// to edit/view a project that isn't necessarily the active one.
  ///
  /// **Auto-disposing, with the same repair call as [allProjects]**, so it had
  /// the same defect shape (task 11.235): a bare `ref.read(...future)` of it
  /// would dispose it mid-repair. Every `ref.watch` now happens before the
  /// first `await`, and the repair takes no `Ref`.
  ProjectByIdProvider._({
    required ProjectByIdFamily super.from,
    required String super.argument,
  }) : super(
         retry: null,
         name: r'projectByIdProvider',
         isAutoDispose: true,
         dependencies: null,
         $allTransitiveDependencies: null,
       );

  @override
  String debugGetCreateSourceHash() => _$projectByIdHash();

  @override
  String toString() {
    return r'projectByIdProvider'
        ''
        '($argument)';
  }

  @$internal
  @override
  $FutureProviderElement<Project?> $createElement($ProviderPointer pointer) =>
      $FutureProviderElement(pointer);

  @override
  FutureOr<Project?> create(Ref ref) {
    final argument = this.argument as String;
    return projectById(ref, argument);
  }

  @override
  bool operator ==(Object other) {
    return other is ProjectByIdProvider && other.argument == argument;
  }

  @override
  int get hashCode {
    return argument.hashCode;
  }
}

String _$projectByIdHash() => r'f9cc80a6aed7c52dded99606eb713f4b6ec52624';

/// Resolves an arbitrary project by id — used by the Projects list screen
/// to edit/view a project that isn't necessarily the active one.
///
/// **Auto-disposing, with the same repair call as [allProjects]**, so it had
/// the same defect shape (task 11.235): a bare `ref.read(...future)` of it
/// would dispose it mid-repair. Every `ref.watch` now happens before the
/// first `await`, and the repair takes no `Ref`.

final class ProjectByIdFamily extends $Family
    with $FunctionalFamilyOverride<FutureOr<Project?>, String> {
  ProjectByIdFamily._()
    : super(
        retry: null,
        name: r'projectByIdProvider',
        dependencies: null,
        $allTransitiveDependencies: null,
        isAutoDispose: true,
      );

  /// Resolves an arbitrary project by id — used by the Projects list screen
  /// to edit/view a project that isn't necessarily the active one.
  ///
  /// **Auto-disposing, with the same repair call as [allProjects]**, so it had
  /// the same defect shape (task 11.235): a bare `ref.read(...future)` of it
  /// would dispose it mid-repair. Every `ref.watch` now happens before the
  /// first `await`, and the repair takes no `Ref`.

  ProjectByIdProvider call(String projectId) =>
      ProjectByIdProvider._(argument: projectId, from: this);

  @override
  String toString() => r'projectByIdProvider';
}

/// All non-deleted projects, for the Projects switcher/list screen — and the
/// tag database's + button, which is how task 11.235 found it (see
/// [_ensureOwnerMembership]).
///
/// **Every `ref.watch` is issued before the first `await`.** The repair loop
/// below runs on plain values and can be disposed out from under without
/// failing; `provider.future` still resolves with the finished list.

@ProviderFor(allProjects)
final allProjectsProvider = AllProjectsProvider._();

/// All non-deleted projects, for the Projects switcher/list screen — and the
/// tag database's + button, which is how task 11.235 found it (see
/// [_ensureOwnerMembership]).
///
/// **Every `ref.watch` is issued before the first `await`.** The repair loop
/// below runs on plain values and can be disposed out from under without
/// failing; `provider.future` still resolves with the finished list.

final class AllProjectsProvider
    extends
        $FunctionalProvider<
          AsyncValue<List<Project>>,
          List<Project>,
          FutureOr<List<Project>>
        >
    with $FutureModifier<List<Project>>, $FutureProvider<List<Project>> {
  /// All non-deleted projects, for the Projects switcher/list screen — and the
  /// tag database's + button, which is how task 11.235 found it (see
  /// [_ensureOwnerMembership]).
  ///
  /// **Every `ref.watch` is issued before the first `await`.** The repair loop
  /// below runs on plain values and can be disposed out from under without
  /// failing; `provider.future` still resolves with the finished list.
  AllProjectsProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'allProjectsProvider',
        isAutoDispose: true,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$allProjectsHash();

  @$internal
  @override
  $FutureProviderElement<List<Project>> $createElement(
    $ProviderPointer pointer,
  ) => $FutureProviderElement(pointer);

  @override
  FutureOr<List<Project>> create(Ref ref) {
    return allProjects(ref);
  }
}

String _$allProjectsHash() => r'05330dada0787b7068a2e76550a2294b29c6dbe5';

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

@ProviderFor(projectStandingForUser)
final projectStandingForUserProvider = ProjectStandingForUserFamily._();

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

final class ProjectStandingForUserProvider
    extends
        $FunctionalProvider<
          AsyncValue<ProjectStanding>,
          ProjectStanding,
          FutureOr<ProjectStanding>
        >
    with $FutureModifier<ProjectStanding>, $FutureProvider<ProjectStanding> {
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
  ProjectStandingForUserProvider._({
    required ProjectStandingForUserFamily super.from,
    required (String, String) super.argument,
  }) : super(
         retry: null,
         name: r'projectStandingForUserProvider',
         isAutoDispose: true,
         dependencies: null,
         $allTransitiveDependencies: null,
       );

  @override
  String debugGetCreateSourceHash() => _$projectStandingForUserHash();

  @override
  String toString() {
    return r'projectStandingForUserProvider'
        ''
        '$argument';
  }

  @$internal
  @override
  $FutureProviderElement<ProjectStanding> $createElement(
    $ProviderPointer pointer,
  ) => $FutureProviderElement(pointer);

  @override
  FutureOr<ProjectStanding> create(Ref ref) {
    final argument = this.argument as (String, String);
    return projectStandingForUser(ref, argument.$1, argument.$2);
  }

  @override
  bool operator ==(Object other) {
    return other is ProjectStandingForUserProvider &&
        other.argument == argument;
  }

  @override
  int get hashCode {
    return argument.hashCode;
  }
}

String _$projectStandingForUserHash() =>
    r'3fd59486189709aec9ceff2c59ecdff20311cd6a';

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

final class ProjectStandingForUserFamily extends $Family
    with
        $FunctionalFamilyOverride<FutureOr<ProjectStanding>, (String, String)> {
  ProjectStandingForUserFamily._()
    : super(
        retry: null,
        name: r'projectStandingForUserProvider',
        dependencies: null,
        $allTransitiveDependencies: null,
        isAutoDispose: true,
      );

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

  ProjectStandingForUserProvider call(String projectId, String userId) =>
      ProjectStandingForUserProvider._(
        argument: (projectId, userId),
        from: this,
      );

  @override
  String toString() => r'projectStandingForUserProvider';
}

/// [userId]'s role on [projectId], or null if they aren't a member — the
/// "what's my role here" read task 8.1/8.3 anticipated, routed through
/// [ProjectMembershipRepository] rather than a raw query (task 8.4).
///
/// One line over [projectStandingForUser] since task 11.237, so the two cannot
/// disagree. Callers that need to tell *not a member* from *cannot say* read
/// the standing; this is for the ones that only want the rung.

@ProviderFor(projectRoleForUser)
final projectRoleForUserProvider = ProjectRoleForUserFamily._();

/// [userId]'s role on [projectId], or null if they aren't a member — the
/// "what's my role here" read task 8.1/8.3 anticipated, routed through
/// [ProjectMembershipRepository] rather than a raw query (task 8.4).
///
/// One line over [projectStandingForUser] since task 11.237, so the two cannot
/// disagree. Callers that need to tell *not a member* from *cannot say* read
/// the standing; this is for the ones that only want the rung.

final class ProjectRoleForUserProvider
    extends
        $FunctionalProvider<
          AsyncValue<ProjectRole?>,
          ProjectRole?,
          FutureOr<ProjectRole?>
        >
    with $FutureModifier<ProjectRole?>, $FutureProvider<ProjectRole?> {
  /// [userId]'s role on [projectId], or null if they aren't a member — the
  /// "what's my role here" read task 8.1/8.3 anticipated, routed through
  /// [ProjectMembershipRepository] rather than a raw query (task 8.4).
  ///
  /// One line over [projectStandingForUser] since task 11.237, so the two cannot
  /// disagree. Callers that need to tell *not a member* from *cannot say* read
  /// the standing; this is for the ones that only want the rung.
  ProjectRoleForUserProvider._({
    required ProjectRoleForUserFamily super.from,
    required (String, String) super.argument,
  }) : super(
         retry: null,
         name: r'projectRoleForUserProvider',
         isAutoDispose: true,
         dependencies: null,
         $allTransitiveDependencies: null,
       );

  @override
  String debugGetCreateSourceHash() => _$projectRoleForUserHash();

  @override
  String toString() {
    return r'projectRoleForUserProvider'
        ''
        '$argument';
  }

  @$internal
  @override
  $FutureProviderElement<ProjectRole?> $createElement(
    $ProviderPointer pointer,
  ) => $FutureProviderElement(pointer);

  @override
  FutureOr<ProjectRole?> create(Ref ref) {
    final argument = this.argument as (String, String);
    return projectRoleForUser(ref, argument.$1, argument.$2);
  }

  @override
  bool operator ==(Object other) {
    return other is ProjectRoleForUserProvider && other.argument == argument;
  }

  @override
  int get hashCode {
    return argument.hashCode;
  }
}

String _$projectRoleForUserHash() =>
    r'2973175a1edfc444c6d0795047574ad9a56b7bd9';

/// [userId]'s role on [projectId], or null if they aren't a member — the
/// "what's my role here" read task 8.1/8.3 anticipated, routed through
/// [ProjectMembershipRepository] rather than a raw query (task 8.4).
///
/// One line over [projectStandingForUser] since task 11.237, so the two cannot
/// disagree. Callers that need to tell *not a member* from *cannot say* read
/// the standing; this is for the ones that only want the rung.

final class ProjectRoleForUserFamily extends $Family
    with $FunctionalFamilyOverride<FutureOr<ProjectRole?>, (String, String)> {
  ProjectRoleForUserFamily._()
    : super(
        retry: null,
        name: r'projectRoleForUserProvider',
        dependencies: null,
        $allTransitiveDependencies: null,
        isAutoDispose: true,
      );

  /// [userId]'s role on [projectId], or null if they aren't a member — the
  /// "what's my role here" read task 8.1/8.3 anticipated, routed through
  /// [ProjectMembershipRepository] rather than a raw query (task 8.4).
  ///
  /// One line over [projectStandingForUser] since task 11.237, so the two cannot
  /// disagree. Callers that need to tell *not a member* from *cannot say* read
  /// the standing; this is for the ones that only want the rung.

  ProjectRoleForUserProvider call(String projectId, String userId) =>
      ProjectRoleForUserProvider._(argument: (projectId, userId), from: this);

  @override
  String toString() => r'projectRoleForUserProvider';
}

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

@ProviderFor(myProjectStanding)
final myProjectStandingProvider = MyProjectStandingFamily._();

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

final class MyProjectStandingProvider
    extends
        $FunctionalProvider<
          AsyncValue<ProjectStanding>,
          ProjectStanding,
          FutureOr<ProjectStanding>
        >
    with $FutureModifier<ProjectStanding>, $FutureProvider<ProjectStanding> {
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
  MyProjectStandingProvider._({
    required MyProjectStandingFamily super.from,
    required String super.argument,
  }) : super(
         retry: null,
         name: r'myProjectStandingProvider',
         isAutoDispose: true,
         dependencies: null,
         $allTransitiveDependencies: null,
       );

  @override
  String debugGetCreateSourceHash() => _$myProjectStandingHash();

  @override
  String toString() {
    return r'myProjectStandingProvider'
        ''
        '($argument)';
  }

  @$internal
  @override
  $FutureProviderElement<ProjectStanding> $createElement(
    $ProviderPointer pointer,
  ) => $FutureProviderElement(pointer);

  @override
  FutureOr<ProjectStanding> create(Ref ref) {
    final argument = this.argument as String;
    return myProjectStanding(ref, argument);
  }

  @override
  bool operator ==(Object other) {
    return other is MyProjectStandingProvider && other.argument == argument;
  }

  @override
  int get hashCode {
    return argument.hashCode;
  }
}

String _$myProjectStandingHash() => r'bb567ea5d40b8f76dcf12098a7568ee0dcc18cfa';

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

final class MyProjectStandingFamily extends $Family
    with $FunctionalFamilyOverride<FutureOr<ProjectStanding>, String> {
  MyProjectStandingFamily._()
    : super(
        retry: null,
        name: r'myProjectStandingProvider',
        dependencies: null,
        $allTransitiveDependencies: null,
        isAutoDispose: true,
      );

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

  MyProjectStandingProvider call(String projectId) =>
      MyProjectStandingProvider._(argument: projectId, from: this);

  @override
  String toString() => r'myProjectStandingProvider';
}

/// The signed-in user's role on [projectId], via [myProjectStanding].

@ProviderFor(myProjectRole)
final myProjectRoleProvider = MyProjectRoleFamily._();

/// The signed-in user's role on [projectId], via [myProjectStanding].

final class MyProjectRoleProvider
    extends
        $FunctionalProvider<
          AsyncValue<ProjectRole?>,
          ProjectRole?,
          FutureOr<ProjectRole?>
        >
    with $FutureModifier<ProjectRole?>, $FutureProvider<ProjectRole?> {
  /// The signed-in user's role on [projectId], via [myProjectStanding].
  MyProjectRoleProvider._({
    required MyProjectRoleFamily super.from,
    required String super.argument,
  }) : super(
         retry: null,
         name: r'myProjectRoleProvider',
         isAutoDispose: true,
         dependencies: null,
         $allTransitiveDependencies: null,
       );

  @override
  String debugGetCreateSourceHash() => _$myProjectRoleHash();

  @override
  String toString() {
    return r'myProjectRoleProvider'
        ''
        '($argument)';
  }

  @$internal
  @override
  $FutureProviderElement<ProjectRole?> $createElement(
    $ProviderPointer pointer,
  ) => $FutureProviderElement(pointer);

  @override
  FutureOr<ProjectRole?> create(Ref ref) {
    final argument = this.argument as String;
    return myProjectRole(ref, argument);
  }

  @override
  bool operator ==(Object other) {
    return other is MyProjectRoleProvider && other.argument == argument;
  }

  @override
  int get hashCode {
    return argument.hashCode;
  }
}

String _$myProjectRoleHash() => r'0b7e13d02f233bac46a434556a957c21b72ce44e';

/// The signed-in user's role on [projectId], via [myProjectStanding].

final class MyProjectRoleFamily extends $Family
    with $FunctionalFamilyOverride<FutureOr<ProjectRole?>, String> {
  MyProjectRoleFamily._()
    : super(
        retry: null,
        name: r'myProjectRoleProvider',
        dependencies: null,
        $allTransitiveDependencies: null,
        isAutoDispose: true,
      );

  /// The signed-in user's role on [projectId], via [myProjectStanding].

  MyProjectRoleProvider call(String projectId) =>
      MyProjectRoleProvider._(argument: projectId, from: this);

  @override
  String toString() => r'myProjectRoleProvider';
}

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

@ProviderFor(mayWriteProjectData)
final mayWriteProjectDataProvider = MayWriteProjectDataFamily._();

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

final class MayWriteProjectDataProvider
    extends $FunctionalProvider<AsyncValue<bool>, bool, FutureOr<bool>>
    with $FutureModifier<bool>, $FutureProvider<bool> {
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
  MayWriteProjectDataProvider._({
    required MayWriteProjectDataFamily super.from,
    required String super.argument,
  }) : super(
         retry: null,
         name: r'mayWriteProjectDataProvider',
         isAutoDispose: true,
         dependencies: null,
         $allTransitiveDependencies: null,
       );

  @override
  String debugGetCreateSourceHash() => _$mayWriteProjectDataHash();

  @override
  String toString() {
    return r'mayWriteProjectDataProvider'
        ''
        '($argument)';
  }

  @$internal
  @override
  $FutureProviderElement<bool> $createElement($ProviderPointer pointer) =>
      $FutureProviderElement(pointer);

  @override
  FutureOr<bool> create(Ref ref) {
    final argument = this.argument as String;
    return mayWriteProjectData(ref, argument);
  }

  @override
  bool operator ==(Object other) {
    return other is MayWriteProjectDataProvider && other.argument == argument;
  }

  @override
  int get hashCode {
    return argument.hashCode;
  }
}

String _$mayWriteProjectDataHash() =>
    r'77e27776532d10f419efd39f80b616461b481066';

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

final class MayWriteProjectDataFamily extends $Family
    with $FunctionalFamilyOverride<FutureOr<bool>, String> {
  MayWriteProjectDataFamily._()
    : super(
        retry: null,
        name: r'mayWriteProjectDataProvider',
        dependencies: null,
        $allTransitiveDependencies: null,
        isAutoDispose: true,
      );

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

  MayWriteProjectDataProvider call(String projectId) =>
      MayWriteProjectDataProvider._(argument: projectId, from: this);

  @override
  String toString() => r'mayWriteProjectDataProvider';
}

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

@ProviderFor(snapshotProjectIds)
final snapshotProjectIdsProvider = SnapshotProjectIdsProvider._();

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

final class SnapshotProjectIdsProvider
    extends
        $FunctionalProvider<
          AsyncValue<Set<String>>,
          Set<String>,
          FutureOr<Set<String>>
        >
    with $FutureModifier<Set<String>>, $FutureProvider<Set<String>> {
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
  SnapshotProjectIdsProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'snapshotProjectIdsProvider',
        isAutoDispose: true,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$snapshotProjectIdsHash();

  @$internal
  @override
  $FutureProviderElement<Set<String>> $createElement(
    $ProviderPointer pointer,
  ) => $FutureProviderElement(pointer);

  @override
  FutureOr<Set<String>> create(Ref ref) {
    return snapshotProjectIds(ref);
  }
}

String _$snapshotProjectIdsHash() =>
    r'fa63dcf2247acaf5a55e6c2c97c0d0aa6b026591';

/// [projectId]'s current owners (task 11.1) — the read that replaced
/// `Projects.owner_user_id` as the answer to "who may manage this project".
///
/// Separate from [projectRoleForUser] on purpose. A role lookup answers about
/// one person and takes `rows.first`; ownership is a *set*, and the whole
/// point of 11.1 is that it can hold more than one name.

@ProviderFor(projectOwners)
final projectOwnersProvider = ProjectOwnersFamily._();

/// [projectId]'s current owners (task 11.1) — the read that replaced
/// `Projects.owner_user_id` as the answer to "who may manage this project".
///
/// Separate from [projectRoleForUser] on purpose. A role lookup answers about
/// one person and takes `rows.first`; ownership is a *set*, and the whole
/// point of 11.1 is that it can hold more than one name.

final class ProjectOwnersProvider
    extends
        $FunctionalProvider<
          AsyncValue<Set<String>>,
          Set<String>,
          FutureOr<Set<String>>
        >
    with $FutureModifier<Set<String>>, $FutureProvider<Set<String>> {
  /// [projectId]'s current owners (task 11.1) — the read that replaced
  /// `Projects.owner_user_id` as the answer to "who may manage this project".
  ///
  /// Separate from [projectRoleForUser] on purpose. A role lookup answers about
  /// one person and takes `rows.first`; ownership is a *set*, and the whole
  /// point of 11.1 is that it can hold more than one name.
  ProjectOwnersProvider._({
    required ProjectOwnersFamily super.from,
    required String super.argument,
  }) : super(
         retry: null,
         name: r'projectOwnersProvider',
         isAutoDispose: true,
         dependencies: null,
         $allTransitiveDependencies: null,
       );

  @override
  String debugGetCreateSourceHash() => _$projectOwnersHash();

  @override
  String toString() {
    return r'projectOwnersProvider'
        ''
        '($argument)';
  }

  @$internal
  @override
  $FutureProviderElement<Set<String>> $createElement(
    $ProviderPointer pointer,
  ) => $FutureProviderElement(pointer);

  @override
  FutureOr<Set<String>> create(Ref ref) {
    final argument = this.argument as String;
    return projectOwners(ref, argument);
  }

  @override
  bool operator ==(Object other) {
    return other is ProjectOwnersProvider && other.argument == argument;
  }

  @override
  int get hashCode {
    return argument.hashCode;
  }
}

String _$projectOwnersHash() => r'89f0dbe8fb29e8105d76fa551dcc82b032bd9a17';

/// [projectId]'s current owners (task 11.1) — the read that replaced
/// `Projects.owner_user_id` as the answer to "who may manage this project".
///
/// Separate from [projectRoleForUser] on purpose. A role lookup answers about
/// one person and takes `rows.first`; ownership is a *set*, and the whole
/// point of 11.1 is that it can hold more than one name.

final class ProjectOwnersFamily extends $Family
    with $FunctionalFamilyOverride<FutureOr<Set<String>>, String> {
  ProjectOwnersFamily._()
    : super(
        retry: null,
        name: r'projectOwnersProvider',
        dependencies: null,
        $allTransitiveDependencies: null,
        isAutoDispose: true,
      );

  /// [projectId]'s current owners (task 11.1) — the read that replaced
  /// `Projects.owner_user_id` as the answer to "who may manage this project".
  ///
  /// Separate from [projectRoleForUser] on purpose. A role lookup answers about
  /// one person and takes `rows.first`; ownership is a *set*, and the whole
  /// point of 11.1 is that it can hold more than one name.

  ProjectOwnersProvider call(String projectId) =>
      ProjectOwnersProvider._(argument: projectId, from: this);

  @override
  String toString() => r'projectOwnersProvider';
}

/// The ids of every project on this device the signed-in user currently owns.
///
/// The list-screen counterpart of [isProjectOwner]: one lookup for the whole
/// list, so a screen rendering N rows does not open N asynchronous ownership
/// questions and have them resolve at N different moments.

@ProviderFor(ownedProjectIds)
final ownedProjectIdsProvider = OwnedProjectIdsProvider._();

/// The ids of every project on this device the signed-in user currently owns.
///
/// The list-screen counterpart of [isProjectOwner]: one lookup for the whole
/// list, so a screen rendering N rows does not open N asynchronous ownership
/// questions and have them resolve at N different moments.

final class OwnedProjectIdsProvider
    extends
        $FunctionalProvider<
          AsyncValue<Set<String>>,
          Set<String>,
          FutureOr<Set<String>>
        >
    with $FutureModifier<Set<String>>, $FutureProvider<Set<String>> {
  /// The ids of every project on this device the signed-in user currently owns.
  ///
  /// The list-screen counterpart of [isProjectOwner]: one lookup for the whole
  /// list, so a screen rendering N rows does not open N asynchronous ownership
  /// questions and have them resolve at N different moments.
  OwnedProjectIdsProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'ownedProjectIdsProvider',
        isAutoDispose: true,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$ownedProjectIdsHash();

  @$internal
  @override
  $FutureProviderElement<Set<String>> $createElement(
    $ProviderPointer pointer,
  ) => $FutureProviderElement(pointer);

  @override
  FutureOr<Set<String>> create(Ref ref) {
    return ownedProjectIds(ref);
  }
}

String _$ownedProjectIdsHash() => r'eafc8f37466899b82ee4f5581f410d94233fa0d3';

/// Whether the signed-in user is one of [projectId]'s current owners — the
/// UI-layer gate for every owner-only affordance.
///
/// This is what task 8.3's `MutationRule.owner.permits(uid, ownerUserId)`
/// became. It is asynchronous where that was synchronous, which is the honest
/// shape: the answer now depends on rows, not on a column already in hand.

@ProviderFor(isProjectOwner)
final isProjectOwnerProvider = IsProjectOwnerFamily._();

/// Whether the signed-in user is one of [projectId]'s current owners — the
/// UI-layer gate for every owner-only affordance.
///
/// This is what task 8.3's `MutationRule.owner.permits(uid, ownerUserId)`
/// became. It is asynchronous where that was synchronous, which is the honest
/// shape: the answer now depends on rows, not on a column already in hand.

final class IsProjectOwnerProvider
    extends $FunctionalProvider<AsyncValue<bool>, bool, FutureOr<bool>>
    with $FutureModifier<bool>, $FutureProvider<bool> {
  /// Whether the signed-in user is one of [projectId]'s current owners — the
  /// UI-layer gate for every owner-only affordance.
  ///
  /// This is what task 8.3's `MutationRule.owner.permits(uid, ownerUserId)`
  /// became. It is asynchronous where that was synchronous, which is the honest
  /// shape: the answer now depends on rows, not on a column already in hand.
  IsProjectOwnerProvider._({
    required IsProjectOwnerFamily super.from,
    required String super.argument,
  }) : super(
         retry: null,
         name: r'isProjectOwnerProvider',
         isAutoDispose: true,
         dependencies: null,
         $allTransitiveDependencies: null,
       );

  @override
  String debugGetCreateSourceHash() => _$isProjectOwnerHash();

  @override
  String toString() {
    return r'isProjectOwnerProvider'
        ''
        '($argument)';
  }

  @$internal
  @override
  $FutureProviderElement<bool> $createElement($ProviderPointer pointer) =>
      $FutureProviderElement(pointer);

  @override
  FutureOr<bool> create(Ref ref) {
    final argument = this.argument as String;
    return isProjectOwner(ref, argument);
  }

  @override
  bool operator ==(Object other) {
    return other is IsProjectOwnerProvider && other.argument == argument;
  }

  @override
  int get hashCode {
    return argument.hashCode;
  }
}

String _$isProjectOwnerHash() => r'ce4f9a5310974a54a09d2891ead83e1cf3c07885';

/// Whether the signed-in user is one of [projectId]'s current owners — the
/// UI-layer gate for every owner-only affordance.
///
/// This is what task 8.3's `MutationRule.owner.permits(uid, ownerUserId)`
/// became. It is asynchronous where that was synchronous, which is the honest
/// shape: the answer now depends on rows, not on a column already in hand.

final class IsProjectOwnerFamily extends $Family
    with $FunctionalFamilyOverride<FutureOr<bool>, String> {
  IsProjectOwnerFamily._()
    : super(
        retry: null,
        name: r'isProjectOwnerProvider',
        dependencies: null,
        $allTransitiveDependencies: null,
        isAutoDispose: true,
      );

  /// Whether the signed-in user is one of [projectId]'s current owners — the
  /// UI-layer gate for every owner-only affordance.
  ///
  /// This is what task 8.3's `MutationRule.owner.permits(uid, ownerUserId)`
  /// became. It is asynchronous where that was synchronous, which is the honest
  /// shape: the answer now depends on rows, not on a column already in hand.

  IsProjectOwnerProvider call(String projectId) =>
      IsProjectOwnerProvider._(argument: projectId, from: this);

  @override
  String toString() => r'isProjectOwnerProvider';
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

@ProviderFor(projectActiveTags)
final projectActiveTagsProvider = ProjectActiveTagsFamily._();

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

final class ProjectActiveTagsProvider
    extends
        $FunctionalProvider<
          AsyncValue<List<Tag>>,
          List<Tag>,
          FutureOr<List<Tag>>
        >
    with $FutureModifier<List<Tag>>, $FutureProvider<List<Tag>> {
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
  ProjectActiveTagsProvider._({
    required ProjectActiveTagsFamily super.from,
    required String super.argument,
  }) : super(
         retry: null,
         name: r'projectActiveTagsProvider',
         isAutoDispose: true,
         dependencies: null,
         $allTransitiveDependencies: null,
       );

  @override
  String debugGetCreateSourceHash() => _$projectActiveTagsHash();

  @override
  String toString() {
    return r'projectActiveTagsProvider'
        ''
        '($argument)';
  }

  @$internal
  @override
  $FutureProviderElement<List<Tag>> $createElement($ProviderPointer pointer) =>
      $FutureProviderElement(pointer);

  @override
  FutureOr<List<Tag>> create(Ref ref) {
    final argument = this.argument as String;
    return projectActiveTags(ref, argument);
  }

  @override
  bool operator ==(Object other) {
    return other is ProjectActiveTagsProvider && other.argument == argument;
  }

  @override
  int get hashCode {
    return argument.hashCode;
  }
}

String _$projectActiveTagsHash() => r'35f7c84a0381fe2c87a23b586f822add56b483eb';

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

final class ProjectActiveTagsFamily extends $Family
    with $FunctionalFamilyOverride<FutureOr<List<Tag>>, String> {
  ProjectActiveTagsFamily._()
    : super(
        retry: null,
        name: r'projectActiveTagsProvider',
        dependencies: null,
        $allTransitiveDependencies: null,
        isAutoDispose: true,
      );

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

  ProjectActiveTagsProvider call(String projectId) =>
      ProjectActiveTagsProvider._(argument: projectId, from: this);

  @override
  String toString() => r'projectActiveTagsProvider';
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

@ProviderFor(projectTags)
final projectTagsProvider = ProjectTagsFamily._();

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

final class ProjectTagsProvider
    extends
        $FunctionalProvider<
          AsyncValue<List<Tag>>,
          List<Tag>,
          FutureOr<List<Tag>>
        >
    with $FutureModifier<List<Tag>>, $FutureProvider<List<Tag>> {
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
  ProjectTagsProvider._({
    required ProjectTagsFamily super.from,
    required String super.argument,
  }) : super(
         retry: null,
         name: r'projectTagsProvider',
         isAutoDispose: true,
         dependencies: null,
         $allTransitiveDependencies: null,
       );

  @override
  String debugGetCreateSourceHash() => _$projectTagsHash();

  @override
  String toString() {
    return r'projectTagsProvider'
        ''
        '($argument)';
  }

  @$internal
  @override
  $FutureProviderElement<List<Tag>> $createElement($ProviderPointer pointer) =>
      $FutureProviderElement(pointer);

  @override
  FutureOr<List<Tag>> create(Ref ref) {
    final argument = this.argument as String;
    return projectTags(ref, argument);
  }

  @override
  bool operator ==(Object other) {
    return other is ProjectTagsProvider && other.argument == argument;
  }

  @override
  int get hashCode {
    return argument.hashCode;
  }
}

String _$projectTagsHash() => r'09438d8329dead6b0d22c5e37008e0d3d1fbbf97';

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

final class ProjectTagsFamily extends $Family
    with $FunctionalFamilyOverride<FutureOr<List<Tag>>, String> {
  ProjectTagsFamily._()
    : super(
        retry: null,
        name: r'projectTagsProvider',
        dependencies: null,
        $allTransitiveDependencies: null,
        isAutoDispose: true,
      );

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

  ProjectTagsProvider call(String projectId) =>
      ProjectTagsProvider._(argument: projectId, from: this);

  @override
  String toString() => r'projectTagsProvider';
}
