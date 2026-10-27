// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'membership_provider.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint, type=warning
/// Every membership row of a project, ended stints included, for the owner's
/// members screen (task 11.2).
///
/// **Reads local SQLite, so the screen works offline.** Who is on the project
/// is synced data; only the *join code and the pending requests* need the
/// server, which is why they are separate providers that can fail on their own
/// without taking the member list down with them.

@ProviderFor(projectMemberships)
final projectMembershipsProvider = ProjectMembershipsFamily._();

/// Every membership row of a project, ended stints included, for the owner's
/// members screen (task 11.2).
///
/// **Reads local SQLite, so the screen works offline.** Who is on the project
/// is synced data; only the *join code and the pending requests* need the
/// server, which is why they are separate providers that can fail on their own
/// without taking the member list down with them.

final class ProjectMembershipsProvider
    extends
        $FunctionalProvider<
          AsyncValue<List<ProjectMember>>,
          List<ProjectMember>,
          FutureOr<List<ProjectMember>>
        >
    with
        $FutureModifier<List<ProjectMember>>,
        $FutureProvider<List<ProjectMember>> {
  /// Every membership row of a project, ended stints included, for the owner's
  /// members screen (task 11.2).
  ///
  /// **Reads local SQLite, so the screen works offline.** Who is on the project
  /// is synced data; only the *join code and the pending requests* need the
  /// server, which is why they are separate providers that can fail on their own
  /// without taking the member list down with them.
  ProjectMembershipsProvider._({
    required ProjectMembershipsFamily super.from,
    required String super.argument,
  }) : super(
         retry: null,
         name: r'projectMembershipsProvider',
         isAutoDispose: true,
         dependencies: null,
         $allTransitiveDependencies: null,
       );

  @override
  String debugGetCreateSourceHash() => _$projectMembershipsHash();

  @override
  String toString() {
    return r'projectMembershipsProvider'
        ''
        '($argument)';
  }

  @$internal
  @override
  $FutureProviderElement<List<ProjectMember>> $createElement(
    $ProviderPointer pointer,
  ) => $FutureProviderElement(pointer);

  @override
  FutureOr<List<ProjectMember>> create(Ref ref) {
    final argument = this.argument as String;
    return projectMemberships(ref, argument);
  }

  @override
  bool operator ==(Object other) {
    return other is ProjectMembershipsProvider && other.argument == argument;
  }

  @override
  int get hashCode {
    return argument.hashCode;
  }
}

String _$projectMembershipsHash() =>
    r'f008b8b1a78ddeaf250778a81fed974cad2a6e7e';

/// Every membership row of a project, ended stints included, for the owner's
/// members screen (task 11.2).
///
/// **Reads local SQLite, so the screen works offline.** Who is on the project
/// is synced data; only the *join code and the pending requests* need the
/// server, which is why they are separate providers that can fail on their own
/// without taking the member list down with them.

final class ProjectMembershipsFamily extends $Family
    with $FunctionalFamilyOverride<FutureOr<List<ProjectMember>>, String> {
  ProjectMembershipsFamily._()
    : super(
        retry: null,
        name: r'projectMembershipsProvider',
        dependencies: null,
        $allTransitiveDependencies: null,
        isAutoDispose: true,
      );

  /// Every membership row of a project, ended stints included, for the owner's
  /// members screen (task 11.2).
  ///
  /// **Reads local SQLite, so the screen works offline.** Who is on the project
  /// is synced data; only the *join code and the pending requests* need the
  /// server, which is why they are separate providers that can fail on their own
  /// without taking the member list down with them.

  ProjectMembershipsProvider call(String projectId) =>
      ProjectMembershipsProvider._(argument: projectId, from: this);

  @override
  String toString() => r'projectMembershipsProvider';
}

/// **The projects on this device that the signed-in person is no longer on**
/// (task 11.54).
///
/// A closed stint and no open one, and that is the whole definition —
/// `ProjectMembershipRepository.hasDeparted`, the same question
/// `SyncController._weHaveLeft` asks about the active project, asked here for
/// the whole list at once because the projects screen has to render every
/// row's controls in one pass. One derivation since task 11.305, which found
/// the sync round asking a wider version of it and unlinking a project on the
/// answer.
///
/// **Requiring a closed stint, rather than merely the absence of an open one,
/// is what keeps this from meaning "every project you never joined".** A purely
/// local project has no membership rows for anybody, and offering to treat one
/// of those as a project you left would be wrong on the most common kind of
/// project this app holds.

@ProviderFor(departedProjectIds)
final departedProjectIdsProvider = DepartedProjectIdsProvider._();

/// **The projects on this device that the signed-in person is no longer on**
/// (task 11.54).
///
/// A closed stint and no open one, and that is the whole definition —
/// `ProjectMembershipRepository.hasDeparted`, the same question
/// `SyncController._weHaveLeft` asks about the active project, asked here for
/// the whole list at once because the projects screen has to render every
/// row's controls in one pass. One derivation since task 11.305, which found
/// the sync round asking a wider version of it and unlinking a project on the
/// answer.
///
/// **Requiring a closed stint, rather than merely the absence of an open one,
/// is what keeps this from meaning "every project you never joined".** A purely
/// local project has no membership rows for anybody, and offering to treat one
/// of those as a project you left would be wrong on the most common kind of
/// project this app holds.

final class DepartedProjectIdsProvider
    extends
        $FunctionalProvider<
          AsyncValue<Set<String>>,
          Set<String>,
          FutureOr<Set<String>>
        >
    with $FutureModifier<Set<String>>, $FutureProvider<Set<String>> {
  /// **The projects on this device that the signed-in person is no longer on**
  /// (task 11.54).
  ///
  /// A closed stint and no open one, and that is the whole definition —
  /// `ProjectMembershipRepository.hasDeparted`, the same question
  /// `SyncController._weHaveLeft` asks about the active project, asked here for
  /// the whole list at once because the projects screen has to render every
  /// row's controls in one pass. One derivation since task 11.305, which found
  /// the sync round asking a wider version of it and unlinking a project on the
  /// answer.
  ///
  /// **Requiring a closed stint, rather than merely the absence of an open one,
  /// is what keeps this from meaning "every project you never joined".** A purely
  /// local project has no membership rows for anybody, and offering to treat one
  /// of those as a project you left would be wrong on the most common kind of
  /// project this app holds.
  DepartedProjectIdsProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'departedProjectIdsProvider',
        isAutoDispose: true,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$departedProjectIdsHash();

  @$internal
  @override
  $FutureProviderElement<Set<String>> $createElement(
    $ProviderPointer pointer,
  ) => $FutureProviderElement(pointer);

  @override
  FutureOr<Set<String>> create(Ref ref) {
    return departedProjectIds(ref);
  }
}

String _$departedProjectIdsHash() =>
    r'c19dea8e9e0c5298d04a846f6c7c7925058f9874';

/// **How many of this device's records for [projectId] will never reach the
/// server** (task 11.54).
///
/// Asked before warning somebody that deleting the project loses them, because
/// *"you will lose everything"* and *"you will lose only what never synced"*
/// lead a person to different decisions and only one of them is true on any
/// given day. Warning as though something is stranded when nothing is would
/// train somebody to ignore the warning on the day something is.
///
/// Two numbers, and they are the two ways a record can be on this device and
/// nowhere else:
///
/// - **[waiting]** — never offered to the server yet. Ordinary before this
///   person left; permanent now, because every further attempt is refused.
/// - **[refused]** — offered and refused, already counted against "everything
///   is synced" by the held-row store since task 10.28.
///
/// Both come from the sync engine's own predicates rather than from a second
/// query written to match them, for the reason task 10.33 gave: a count kept in
/// step by hand is a count that eventually disagrees with the thing it counts.
///
/// [everSynced] is the third answer, and it is what stops the warning claiming
/// something about a server for a project that has never been on one. Read from
/// `SyncRowReceiptStore`, which holds one durable receipt per row the server has
/// confirmed and — unlike the cursor and the linked flag — is **deliberately
/// not cleared** when a project unlinks. That is exactly why it can still answer
/// "did this ever reach a server" after leaving, when nothing else can.
///
/// **Every `ref.watch` before the first `await` (task 11.236).** This is one
/// of the four providers named in `TASK_COMMS.md`'s entry for task 11.236,
/// alongside [heldRowRetryProvider] — read bare
/// (`ref.read(strandedRecordCountProvider(...).future)`) by the Projects
/// screen's leave/delete warning, which is exactly the shape
/// [_ensureOwnerMembership] broke on: an auto-disposing provider whose body
/// `ref.watch`ed a second thing after its first `await`. The two watches here
/// have no dependency on one another, so both are issued synchronously before
/// either is awaited.

@ProviderFor(strandedRecordCount)
final strandedRecordCountProvider = StrandedRecordCountFamily._();

/// **How many of this device's records for [projectId] will never reach the
/// server** (task 11.54).
///
/// Asked before warning somebody that deleting the project loses them, because
/// *"you will lose everything"* and *"you will lose only what never synced"*
/// lead a person to different decisions and only one of them is true on any
/// given day. Warning as though something is stranded when nothing is would
/// train somebody to ignore the warning on the day something is.
///
/// Two numbers, and they are the two ways a record can be on this device and
/// nowhere else:
///
/// - **[waiting]** — never offered to the server yet. Ordinary before this
///   person left; permanent now, because every further attempt is refused.
/// - **[refused]** — offered and refused, already counted against "everything
///   is synced" by the held-row store since task 10.28.
///
/// Both come from the sync engine's own predicates rather than from a second
/// query written to match them, for the reason task 10.33 gave: a count kept in
/// step by hand is a count that eventually disagrees with the thing it counts.
///
/// [everSynced] is the third answer, and it is what stops the warning claiming
/// something about a server for a project that has never been on one. Read from
/// `SyncRowReceiptStore`, which holds one durable receipt per row the server has
/// confirmed and — unlike the cursor and the linked flag — is **deliberately
/// not cleared** when a project unlinks. That is exactly why it can still answer
/// "did this ever reach a server" after leaving, when nothing else can.
///
/// **Every `ref.watch` before the first `await` (task 11.236).** This is one
/// of the four providers named in `TASK_COMMS.md`'s entry for task 11.236,
/// alongside [heldRowRetryProvider] — read bare
/// (`ref.read(strandedRecordCountProvider(...).future)`) by the Projects
/// screen's leave/delete warning, which is exactly the shape
/// [_ensureOwnerMembership] broke on: an auto-disposing provider whose body
/// `ref.watch`ed a second thing after its first `await`. The two watches here
/// have no dependency on one another, so both are issued synchronously before
/// either is awaited.

final class StrandedRecordCountProvider
    extends
        $FunctionalProvider<
          AsyncValue<({bool everSynced, int refused, int waiting})>,
          ({bool everSynced, int refused, int waiting}),
          FutureOr<({bool everSynced, int refused, int waiting})>
        >
    with
        $FutureModifier<({bool everSynced, int refused, int waiting})>,
        $FutureProvider<({bool everSynced, int refused, int waiting})> {
  /// **How many of this device's records for [projectId] will never reach the
  /// server** (task 11.54).
  ///
  /// Asked before warning somebody that deleting the project loses them, because
  /// *"you will lose everything"* and *"you will lose only what never synced"*
  /// lead a person to different decisions and only one of them is true on any
  /// given day. Warning as though something is stranded when nothing is would
  /// train somebody to ignore the warning on the day something is.
  ///
  /// Two numbers, and they are the two ways a record can be on this device and
  /// nowhere else:
  ///
  /// - **[waiting]** — never offered to the server yet. Ordinary before this
  ///   person left; permanent now, because every further attempt is refused.
  /// - **[refused]** — offered and refused, already counted against "everything
  ///   is synced" by the held-row store since task 10.28.
  ///
  /// Both come from the sync engine's own predicates rather than from a second
  /// query written to match them, for the reason task 10.33 gave: a count kept in
  /// step by hand is a count that eventually disagrees with the thing it counts.
  ///
  /// [everSynced] is the third answer, and it is what stops the warning claiming
  /// something about a server for a project that has never been on one. Read from
  /// `SyncRowReceiptStore`, which holds one durable receipt per row the server has
  /// confirmed and — unlike the cursor and the linked flag — is **deliberately
  /// not cleared** when a project unlinks. That is exactly why it can still answer
  /// "did this ever reach a server" after leaving, when nothing else can.
  ///
  /// **Every `ref.watch` before the first `await` (task 11.236).** This is one
  /// of the four providers named in `TASK_COMMS.md`'s entry for task 11.236,
  /// alongside [heldRowRetryProvider] — read bare
  /// (`ref.read(strandedRecordCountProvider(...).future)`) by the Projects
  /// screen's leave/delete warning, which is exactly the shape
  /// [_ensureOwnerMembership] broke on: an auto-disposing provider whose body
  /// `ref.watch`ed a second thing after its first `await`. The two watches here
  /// have no dependency on one another, so both are issued synchronously before
  /// either is awaited.
  StrandedRecordCountProvider._({
    required StrandedRecordCountFamily super.from,
    required String super.argument,
  }) : super(
         retry: null,
         name: r'strandedRecordCountProvider',
         isAutoDispose: true,
         dependencies: null,
         $allTransitiveDependencies: null,
       );

  @override
  String debugGetCreateSourceHash() => _$strandedRecordCountHash();

  @override
  String toString() {
    return r'strandedRecordCountProvider'
        ''
        '($argument)';
  }

  @$internal
  @override
  $FutureProviderElement<({bool everSynced, int refused, int waiting})>
  $createElement($ProviderPointer pointer) => $FutureProviderElement(pointer);

  @override
  FutureOr<({bool everSynced, int refused, int waiting})> create(Ref ref) {
    final argument = this.argument as String;
    return strandedRecordCount(ref, argument);
  }

  @override
  bool operator ==(Object other) {
    return other is StrandedRecordCountProvider && other.argument == argument;
  }

  @override
  int get hashCode {
    return argument.hashCode;
  }
}

String _$strandedRecordCountHash() =>
    r'be72c9561bdf61f24edb2037bd86d67dc35bc2db';

/// **How many of this device's records for [projectId] will never reach the
/// server** (task 11.54).
///
/// Asked before warning somebody that deleting the project loses them, because
/// *"you will lose everything"* and *"you will lose only what never synced"*
/// lead a person to different decisions and only one of them is true on any
/// given day. Warning as though something is stranded when nothing is would
/// train somebody to ignore the warning on the day something is.
///
/// Two numbers, and they are the two ways a record can be on this device and
/// nowhere else:
///
/// - **[waiting]** — never offered to the server yet. Ordinary before this
///   person left; permanent now, because every further attempt is refused.
/// - **[refused]** — offered and refused, already counted against "everything
///   is synced" by the held-row store since task 10.28.
///
/// Both come from the sync engine's own predicates rather than from a second
/// query written to match them, for the reason task 10.33 gave: a count kept in
/// step by hand is a count that eventually disagrees with the thing it counts.
///
/// [everSynced] is the third answer, and it is what stops the warning claiming
/// something about a server for a project that has never been on one. Read from
/// `SyncRowReceiptStore`, which holds one durable receipt per row the server has
/// confirmed and — unlike the cursor and the linked flag — is **deliberately
/// not cleared** when a project unlinks. That is exactly why it can still answer
/// "did this ever reach a server" after leaving, when nothing else can.
///
/// **Every `ref.watch` before the first `await` (task 11.236).** This is one
/// of the four providers named in `TASK_COMMS.md`'s entry for task 11.236,
/// alongside [heldRowRetryProvider] — read bare
/// (`ref.read(strandedRecordCountProvider(...).future)`) by the Projects
/// screen's leave/delete warning, which is exactly the shape
/// [_ensureOwnerMembership] broke on: an auto-disposing provider whose body
/// `ref.watch`ed a second thing after its first `await`. The two watches here
/// have no dependency on one another, so both are issued synchronously before
/// either is awaited.

final class StrandedRecordCountFamily extends $Family
    with
        $FunctionalFamilyOverride<
          FutureOr<({bool everSynced, int refused, int waiting})>,
          String
        > {
  StrandedRecordCountFamily._()
    : super(
        retry: null,
        name: r'strandedRecordCountProvider',
        dependencies: null,
        $allTransitiveDependencies: null,
        isAutoDispose: true,
      );

  /// **How many of this device's records for [projectId] will never reach the
  /// server** (task 11.54).
  ///
  /// Asked before warning somebody that deleting the project loses them, because
  /// *"you will lose everything"* and *"you will lose only what never synced"*
  /// lead a person to different decisions and only one of them is true on any
  /// given day. Warning as though something is stranded when nothing is would
  /// train somebody to ignore the warning on the day something is.
  ///
  /// Two numbers, and they are the two ways a record can be on this device and
  /// nowhere else:
  ///
  /// - **[waiting]** — never offered to the server yet. Ordinary before this
  ///   person left; permanent now, because every further attempt is refused.
  /// - **[refused]** — offered and refused, already counted against "everything
  ///   is synced" by the held-row store since task 10.28.
  ///
  /// Both come from the sync engine's own predicates rather than from a second
  /// query written to match them, for the reason task 10.33 gave: a count kept in
  /// step by hand is a count that eventually disagrees with the thing it counts.
  ///
  /// [everSynced] is the third answer, and it is what stops the warning claiming
  /// something about a server for a project that has never been on one. Read from
  /// `SyncRowReceiptStore`, which holds one durable receipt per row the server has
  /// confirmed and — unlike the cursor and the linked flag — is **deliberately
  /// not cleared** when a project unlinks. That is exactly why it can still answer
  /// "did this ever reach a server" after leaving, when nothing else can.
  ///
  /// **Every `ref.watch` before the first `await` (task 11.236).** This is one
  /// of the four providers named in `TASK_COMMS.md`'s entry for task 11.236,
  /// alongside [heldRowRetryProvider] — read bare
  /// (`ref.read(strandedRecordCountProvider(...).future)`) by the Projects
  /// screen's leave/delete warning, which is exactly the shape
  /// [_ensureOwnerMembership] broke on: an auto-disposing provider whose body
  /// `ref.watch`ed a second thing after its first `await`. The two watches here
  /// have no dependency on one another, so both are issued synchronously before
  /// either is awaited.

  StrandedRecordCountProvider call(String projectId) =>
      StrandedRecordCountProvider._(argument: projectId, from: this);

  @override
  String toString() => r'strandedRecordCountProvider';
}

/// Whether the signed-in user may leave [projectId], and if not, why — the
/// screen-side half of task 11.28, computed from the same membership rows the
/// repository will read at the write.
///
/// Both inputs come from the shared resolution ([resolveProjectOwners] via
/// `ownersOf`, and `findForUser`'s `end_date IS NULL`), so the control cannot
/// render enabled for a write that will then be refused — the failure task
/// 11.12 exists to prevent.

@ProviderFor(leaveProjectVerdictFor)
final leaveProjectVerdictForProvider = LeaveProjectVerdictForFamily._();

/// Whether the signed-in user may leave [projectId], and if not, why — the
/// screen-side half of task 11.28, computed from the same membership rows the
/// repository will read at the write.
///
/// Both inputs come from the shared resolution ([resolveProjectOwners] via
/// `ownersOf`, and `findForUser`'s `end_date IS NULL`), so the control cannot
/// render enabled for a write that will then be refused — the failure task
/// 11.12 exists to prevent.

final class LeaveProjectVerdictForProvider
    extends
        $FunctionalProvider<
          AsyncValue<({bool canLeave, String? reason})>,
          ({bool canLeave, String? reason}),
          FutureOr<({bool canLeave, String? reason})>
        >
    with
        $FutureModifier<({bool canLeave, String? reason})>,
        $FutureProvider<({bool canLeave, String? reason})> {
  /// Whether the signed-in user may leave [projectId], and if not, why — the
  /// screen-side half of task 11.28, computed from the same membership rows the
  /// repository will read at the write.
  ///
  /// Both inputs come from the shared resolution ([resolveProjectOwners] via
  /// `ownersOf`, and `findForUser`'s `end_date IS NULL`), so the control cannot
  /// render enabled for a write that will then be refused — the failure task
  /// 11.12 exists to prevent.
  LeaveProjectVerdictForProvider._({
    required LeaveProjectVerdictForFamily super.from,
    required String super.argument,
  }) : super(
         retry: null,
         name: r'leaveProjectVerdictForProvider',
         isAutoDispose: true,
         dependencies: null,
         $allTransitiveDependencies: null,
       );

  @override
  String debugGetCreateSourceHash() => _$leaveProjectVerdictForHash();

  @override
  String toString() {
    return r'leaveProjectVerdictForProvider'
        ''
        '($argument)';
  }

  @$internal
  @override
  $FutureProviderElement<({bool canLeave, String? reason})> $createElement(
    $ProviderPointer pointer,
  ) => $FutureProviderElement(pointer);

  @override
  FutureOr<({bool canLeave, String? reason})> create(Ref ref) {
    final argument = this.argument as String;
    return leaveProjectVerdictFor(ref, argument);
  }

  @override
  bool operator ==(Object other) {
    return other is LeaveProjectVerdictForProvider &&
        other.argument == argument;
  }

  @override
  int get hashCode {
    return argument.hashCode;
  }
}

String _$leaveProjectVerdictForHash() =>
    r'091f246b780483eaccc44202542782e1a7dfc159';

/// Whether the signed-in user may leave [projectId], and if not, why — the
/// screen-side half of task 11.28, computed from the same membership rows the
/// repository will read at the write.
///
/// Both inputs come from the shared resolution ([resolveProjectOwners] via
/// `ownersOf`, and `findForUser`'s `end_date IS NULL`), so the control cannot
/// render enabled for a write that will then be refused — the failure task
/// 11.12 exists to prevent.

final class LeaveProjectVerdictForFamily extends $Family
    with
        $FunctionalFamilyOverride<
          FutureOr<({bool canLeave, String? reason})>,
          String
        > {
  LeaveProjectVerdictForFamily._()
    : super(
        retry: null,
        name: r'leaveProjectVerdictForProvider',
        dependencies: null,
        $allTransitiveDependencies: null,
        isAutoDispose: true,
      );

  /// Whether the signed-in user may leave [projectId], and if not, why — the
  /// screen-side half of task 11.28, computed from the same membership rows the
  /// repository will read at the write.
  ///
  /// Both inputs come from the shared resolution ([resolveProjectOwners] via
  /// `ownersOf`, and `findForUser`'s `end_date IS NULL`), so the control cannot
  /// render enabled for a write that will then be refused — the failure task
  /// 11.12 exists to prevent.

  LeaveProjectVerdictForProvider call(String projectId) =>
      LeaveProjectVerdictForProvider._(argument: projectId, from: this);

  @override
  String toString() => r'leaveProjectVerdictForProvider';
}

/// A project's join settings: whether joining is on, the code, the limit, and
/// the two counts. Requires connectivity and ownership.
///
/// **Carries the join code in readable form** — Security Model §4.2.1, the one
/// written exception to §4.2's plaintext rule, so an owner can re-read it after
/// closing the screen instead of rotating and re-broadcasting to a whole crew.

@ProviderFor(projectJoinSettings)
final projectJoinSettingsProvider = ProjectJoinSettingsFamily._();

/// A project's join settings: whether joining is on, the code, the limit, and
/// the two counts. Requires connectivity and ownership.
///
/// **Carries the join code in readable form** — Security Model §4.2.1, the one
/// written exception to §4.2's plaintext rule, so an owner can re-read it after
/// closing the screen instead of rotating and re-broadcasting to a whole crew.

final class ProjectJoinSettingsProvider
    extends
        $FunctionalProvider<
          AsyncValue<JoinSettings>,
          JoinSettings,
          FutureOr<JoinSettings>
        >
    with $FutureModifier<JoinSettings>, $FutureProvider<JoinSettings> {
  /// A project's join settings: whether joining is on, the code, the limit, and
  /// the two counts. Requires connectivity and ownership.
  ///
  /// **Carries the join code in readable form** — Security Model §4.2.1, the one
  /// written exception to §4.2's plaintext rule, so an owner can re-read it after
  /// closing the screen instead of rotating and re-broadcasting to a whole crew.
  ProjectJoinSettingsProvider._({
    required ProjectJoinSettingsFamily super.from,
    required String super.argument,
  }) : super(
         retry: null,
         name: r'projectJoinSettingsProvider',
         isAutoDispose: true,
         dependencies: null,
         $allTransitiveDependencies: null,
       );

  @override
  String debugGetCreateSourceHash() => _$projectJoinSettingsHash();

  @override
  String toString() {
    return r'projectJoinSettingsProvider'
        ''
        '($argument)';
  }

  @$internal
  @override
  $FutureProviderElement<JoinSettings> $createElement(
    $ProviderPointer pointer,
  ) => $FutureProviderElement(pointer);

  @override
  FutureOr<JoinSettings> create(Ref ref) {
    final argument = this.argument as String;
    return projectJoinSettings(ref, argument);
  }

  @override
  bool operator ==(Object other) {
    return other is ProjectJoinSettingsProvider && other.argument == argument;
  }

  @override
  int get hashCode {
    return argument.hashCode;
  }
}

String _$projectJoinSettingsHash() =>
    r'f232643979f7d005dcf792769e5805333f0e3dfe';

/// A project's join settings: whether joining is on, the code, the limit, and
/// the two counts. Requires connectivity and ownership.
///
/// **Carries the join code in readable form** — Security Model §4.2.1, the one
/// written exception to §4.2's plaintext rule, so an owner can re-read it after
/// closing the screen instead of rotating and re-broadcasting to a whole crew.

final class ProjectJoinSettingsFamily extends $Family
    with $FunctionalFamilyOverride<FutureOr<JoinSettings>, String> {
  ProjectJoinSettingsFamily._()
    : super(
        retry: null,
        name: r'projectJoinSettingsProvider',
        dependencies: null,
        $allTransitiveDependencies: null,
        isAutoDispose: true,
      );

  /// A project's join settings: whether joining is on, the code, the limit, and
  /// the two counts. Requires connectivity and ownership.
  ///
  /// **Carries the join code in readable form** — Security Model §4.2.1, the one
  /// written exception to §4.2's plaintext rule, so an owner can re-read it after
  /// closing the screen instead of rotating and re-broadcasting to a whole crew.

  ProjectJoinSettingsProvider call(String projectId) =>
      ProjectJoinSettingsProvider._(argument: projectId, from: this);

  @override
  String toString() => r'projectJoinSettingsProvider';
}

/// The people waiting for this project's owner to decide. Owner-only, and needs
/// the server — who is *on* the project is synced data and works offline, but a
/// pending request is server-only state by design, so these are separate
/// providers that can fail independently.

@ProviderFor(projectJoinRequests)
final projectJoinRequestsProvider = ProjectJoinRequestsFamily._();

/// The people waiting for this project's owner to decide. Owner-only, and needs
/// the server — who is *on* the project is synced data and works offline, but a
/// pending request is server-only state by design, so these are separate
/// providers that can fail independently.

final class ProjectJoinRequestsProvider
    extends
        $FunctionalProvider<
          AsyncValue<List<JoinRequestSummary>>,
          List<JoinRequestSummary>,
          FutureOr<List<JoinRequestSummary>>
        >
    with
        $FutureModifier<List<JoinRequestSummary>>,
        $FutureProvider<List<JoinRequestSummary>> {
  /// The people waiting for this project's owner to decide. Owner-only, and needs
  /// the server — who is *on* the project is synced data and works offline, but a
  /// pending request is server-only state by design, so these are separate
  /// providers that can fail independently.
  ProjectJoinRequestsProvider._({
    required ProjectJoinRequestsFamily super.from,
    required String super.argument,
  }) : super(
         retry: null,
         name: r'projectJoinRequestsProvider',
         isAutoDispose: true,
         dependencies: null,
         $allTransitiveDependencies: null,
       );

  @override
  String debugGetCreateSourceHash() => _$projectJoinRequestsHash();

  @override
  String toString() {
    return r'projectJoinRequestsProvider'
        ''
        '($argument)';
  }

  @$internal
  @override
  $FutureProviderElement<List<JoinRequestSummary>> $createElement(
    $ProviderPointer pointer,
  ) => $FutureProviderElement(pointer);

  @override
  FutureOr<List<JoinRequestSummary>> create(Ref ref) {
    final argument = this.argument as String;
    return projectJoinRequests(ref, argument);
  }

  @override
  bool operator ==(Object other) {
    return other is ProjectJoinRequestsProvider && other.argument == argument;
  }

  @override
  int get hashCode {
    return argument.hashCode;
  }
}

String _$projectJoinRequestsHash() =>
    r'd99c0676716d4519615431ba29ebaad62bf3e24f';

/// The people waiting for this project's owner to decide. Owner-only, and needs
/// the server — who is *on* the project is synced data and works offline, but a
/// pending request is server-only state by design, so these are separate
/// providers that can fail independently.

final class ProjectJoinRequestsFamily extends $Family
    with $FunctionalFamilyOverride<FutureOr<List<JoinRequestSummary>>, String> {
  ProjectJoinRequestsFamily._()
    : super(
        retry: null,
        name: r'projectJoinRequestsProvider',
        dependencies: null,
        $allTransitiveDependencies: null,
        isAutoDispose: true,
      );

  /// The people waiting for this project's owner to decide. Owner-only, and needs
  /// the server — who is *on* the project is synced data and works offline, but a
  /// pending request is server-only state by design, so these are separate
  /// providers that can fail independently.

  ProjectJoinRequestsProvider call(String projectId) =>
      ProjectJoinRequestsProvider._(argument: projectId, from: this);

  @override
  String toString() => r'projectJoinRequestsProvider';
}

/// The authenticated transport this device can reach a server with, or null
/// when it cannot.
///
/// The membership surface's name for [serverTransportProvider].
///
/// **A one-line delegation since task 11.97, and the name is kept on
/// purpose.** Task 11.83 made this a provider so that the seam every
/// membership call and the join-request watcher reach the server through
/// could be replaced in a test, and `/w-05`'s screenshot harness overrides it
/// by that name. What changed is only where the connection is *built*: there
/// is now one construction of [HttpSyncTransport] in the app rather than
/// three, so a test that substitutes a failing server no longer has to know
/// which surface it is substituting it for.
///
/// **Which override to reach for.** Overriding [serverTransportProvider]
/// replaces the connection everywhere, this provider included, because this
/// one reads it. Overriding *this* one replaces it for the membership surface
/// alone and leaves the sync engine on a real connection — which is exactly
/// what the screenshot harness wants and is not what an app-level test wants.

@ProviderFor(membershipTransport)
final membershipTransportProvider = MembershipTransportProvider._();

/// The authenticated transport this device can reach a server with, or null
/// when it cannot.
///
/// The membership surface's name for [serverTransportProvider].
///
/// **A one-line delegation since task 11.97, and the name is kept on
/// purpose.** Task 11.83 made this a provider so that the seam every
/// membership call and the join-request watcher reach the server through
/// could be replaced in a test, and `/w-05`'s screenshot harness overrides it
/// by that name. What changed is only where the connection is *built*: there
/// is now one construction of [HttpSyncTransport] in the app rather than
/// three, so a test that substitutes a failing server no longer has to know
/// which surface it is substituting it for.
///
/// **Which override to reach for.** Overriding [serverTransportProvider]
/// replaces the connection everywhere, this provider included, because this
/// one reads it. Overriding *this* one replaces it for the membership surface
/// alone and leaves the sync engine on a real connection — which is exactly
/// what the screenshot harness wants and is not what an app-level test wants.

final class MembershipTransportProvider
    extends
        $FunctionalProvider<
          AsyncValue<SyncTransport?>,
          SyncTransport?,
          FutureOr<SyncTransport?>
        >
    with $FutureModifier<SyncTransport?>, $FutureProvider<SyncTransport?> {
  /// The authenticated transport this device can reach a server with, or null
  /// when it cannot.
  ///
  /// The membership surface's name for [serverTransportProvider].
  ///
  /// **A one-line delegation since task 11.97, and the name is kept on
  /// purpose.** Task 11.83 made this a provider so that the seam every
  /// membership call and the join-request watcher reach the server through
  /// could be replaced in a test, and `/w-05`'s screenshot harness overrides it
  /// by that name. What changed is only where the connection is *built*: there
  /// is now one construction of [HttpSyncTransport] in the app rather than
  /// three, so a test that substitutes a failing server no longer has to know
  /// which surface it is substituting it for.
  ///
  /// **Which override to reach for.** Overriding [serverTransportProvider]
  /// replaces the connection everywhere, this provider included, because this
  /// one reads it. Overriding *this* one replaces it for the membership surface
  /// alone and leaves the sync engine on a real connection — which is exactly
  /// what the screenshot harness wants and is not what an app-level test wants.
  MembershipTransportProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'membershipTransportProvider',
        isAutoDispose: false,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$membershipTransportHash();

  @$internal
  @override
  $FutureProviderElement<SyncTransport?> $createElement(
    $ProviderPointer pointer,
  ) => $FutureProviderElement(pointer);

  @override
  FutureOr<SyncTransport?> create(Ref ref) {
    return membershipTransport(ref);
  }
}

String _$membershipTransportHash() =>
    r'246662debe4409b2d0a10341f6a760421b7dfcf9';

/// Membership actions: ask to join, approve, reject, rotate the code, re-admit
/// a past member, change a role, end a stint.
///
/// Split from [ProjectLinkController] for the reason that one was split from
/// [SyncController]: these act on a project the *owner* is managing, which is
/// not necessarily the one currently open, and one of them (redeem) acts on a
/// project this device has never seen.

@ProviderFor(MembershipController)
final membershipControllerProvider = MembershipControllerProvider._();

/// Membership actions: ask to join, approve, reject, rotate the code, re-admit
/// a past member, change a role, end a stint.
///
/// Split from [ProjectLinkController] for the reason that one was split from
/// [SyncController]: these act on a project the *owner* is managing, which is
/// not necessarily the one currently open, and one of them (redeem) acts on a
/// project this device has never seen.
final class MembershipControllerProvider
    extends $NotifierProvider<MembershipController, void> {
  /// Membership actions: ask to join, approve, reject, rotate the code, re-admit
  /// a past member, change a role, end a stint.
  ///
  /// Split from [ProjectLinkController] for the reason that one was split from
  /// [SyncController]: these act on a project the *owner* is managing, which is
  /// not necessarily the one currently open, and one of them (redeem) acts on a
  /// project this device has never seen.
  MembershipControllerProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'membershipControllerProvider',
        isAutoDispose: false,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$membershipControllerHash();

  @$internal
  @override
  MembershipController create() => MembershipController();

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(void value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<void>(value),
    );
  }
}

String _$membershipControllerHash() =>
    r'3605d054abc5abf10bba7d461471d3b1e522480d';

/// Membership actions: ask to join, approve, reject, rotate the code, re-admit
/// a past member, change a role, end a stint.
///
/// Split from [ProjectLinkController] for the reason that one was split from
/// [SyncController]: these act on a project the *owner* is managing, which is
/// not necessarily the one currently open, and one of them (redeem) acts on a
/// project this device has never seen.

abstract class _$MembershipController extends $Notifier<void> {
  void build();
  @$mustCallSuper
  @override
  WhenComplete runBuild() {
    final ref = this.ref as $Ref<void, void>;
    final element =
        ref.element
            as $ClassProviderElement<
              AnyNotifier<void, void>,
              void,
              Object?,
              Object?
            >;
    return element.handleCreate(ref, build);
  }
}
