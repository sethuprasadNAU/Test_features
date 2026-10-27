// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'repository_providers.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint, type=warning
/// One provider per repository, each layered on [appDatabaseProvider]. They
/// resolve once the database has opened and migrated; screens/controllers
/// `await ref.watch(xRepositoryProvider.future)` (or use `.requireValue`
/// inside an already-resolved async scope). `keepAlive` matches the database
/// provider so repositories aren't rebuilt on every listen.

@ProviderFor(userRepository)
final userRepositoryProvider = UserRepositoryProvider._();

/// One provider per repository, each layered on [appDatabaseProvider]. They
/// resolve once the database has opened and migrated; screens/controllers
/// `await ref.watch(xRepositoryProvider.future)` (or use `.requireValue`
/// inside an already-resolved async scope). `keepAlive` matches the database
/// provider so repositories aren't rebuilt on every listen.

final class UserRepositoryProvider
    extends
        $FunctionalProvider<
          AsyncValue<UserRepository>,
          UserRepository,
          FutureOr<UserRepository>
        >
    with $FutureModifier<UserRepository>, $FutureProvider<UserRepository> {
  /// One provider per repository, each layered on [appDatabaseProvider]. They
  /// resolve once the database has opened and migrated; screens/controllers
  /// `await ref.watch(xRepositoryProvider.future)` (or use `.requireValue`
  /// inside an already-resolved async scope). `keepAlive` matches the database
  /// provider so repositories aren't rebuilt on every listen.
  UserRepositoryProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'userRepositoryProvider',
        isAutoDispose: false,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$userRepositoryHash();

  @$internal
  @override
  $FutureProviderElement<UserRepository> $createElement(
    $ProviderPointer pointer,
  ) => $FutureProviderElement(pointer);

  @override
  FutureOr<UserRepository> create(Ref ref) {
    return userRepository(ref);
  }
}

String _$userRepositoryHash() => r'f1c14a9ebc2add74f76cab40398e1954b939235f';

@ProviderFor(userEmailRepository)
final userEmailRepositoryProvider = UserEmailRepositoryProvider._();

final class UserEmailRepositoryProvider
    extends
        $FunctionalProvider<
          AsyncValue<UserEmailRepository>,
          UserEmailRepository,
          FutureOr<UserEmailRepository>
        >
    with
        $FutureModifier<UserEmailRepository>,
        $FutureProvider<UserEmailRepository> {
  UserEmailRepositoryProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'userEmailRepositoryProvider',
        isAutoDispose: false,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$userEmailRepositoryHash();

  @$internal
  @override
  $FutureProviderElement<UserEmailRepository> $createElement(
    $ProviderPointer pointer,
  ) => $FutureProviderElement(pointer);

  @override
  FutureOr<UserEmailRepository> create(Ref ref) {
    return userEmailRepository(ref);
  }
}

String _$userEmailRepositoryHash() =>
    r'c5c58cdb676f59c5cd82d1247dc3c3c7143ba8de';

@ProviderFor(projectRepository)
final projectRepositoryProvider = ProjectRepositoryProvider._();

final class ProjectRepositoryProvider
    extends
        $FunctionalProvider<
          AsyncValue<ProjectRepository>,
          ProjectRepository,
          FutureOr<ProjectRepository>
        >
    with
        $FutureModifier<ProjectRepository>,
        $FutureProvider<ProjectRepository> {
  ProjectRepositoryProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'projectRepositoryProvider',
        isAutoDispose: false,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$projectRepositoryHash();

  @$internal
  @override
  $FutureProviderElement<ProjectRepository> $createElement(
    $ProviderPointer pointer,
  ) => $FutureProviderElement(pointer);

  @override
  FutureOr<ProjectRepository> create(Ref ref) {
    return projectRepository(ref);
  }
}

String _$projectRepositoryHash() => r'7361da24fc174bfed16a77ed0ba956c6bc0b377d';

@ProviderFor(projectMembershipRepository)
final projectMembershipRepositoryProvider =
    ProjectMembershipRepositoryProvider._();

final class ProjectMembershipRepositoryProvider
    extends
        $FunctionalProvider<
          AsyncValue<ProjectMembershipRepository>,
          ProjectMembershipRepository,
          FutureOr<ProjectMembershipRepository>
        >
    with
        $FutureModifier<ProjectMembershipRepository>,
        $FutureProvider<ProjectMembershipRepository> {
  ProjectMembershipRepositoryProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'projectMembershipRepositoryProvider',
        isAutoDispose: false,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$projectMembershipRepositoryHash();

  @$internal
  @override
  $FutureProviderElement<ProjectMembershipRepository> $createElement(
    $ProviderPointer pointer,
  ) => $FutureProviderElement(pointer);

  @override
  FutureOr<ProjectMembershipRepository> create(Ref ref) {
    return projectMembershipRepository(ref);
  }
}

String _$projectMembershipRepositoryHash() =>
    r'b62f778e288478ffe12e8828d41f4aca21aa2114';

/// **The animals a project tracks** — task 11.240. Separate from
/// [tagRepository] because a collar and the animal wearing it are different
/// rows with different lifetimes; colour lives here, and the link between
/// the two is [deploymentRepository].

@ProviderFor(individualRepository)
final individualRepositoryProvider = IndividualRepositoryProvider._();

/// **The animals a project tracks** — task 11.240. Separate from
/// [tagRepository] because a collar and the animal wearing it are different
/// rows with different lifetimes; colour lives here, and the link between
/// the two is [deploymentRepository].

final class IndividualRepositoryProvider
    extends
        $FunctionalProvider<
          AsyncValue<IndividualRepository>,
          IndividualRepository,
          FutureOr<IndividualRepository>
        >
    with
        $FutureModifier<IndividualRepository>,
        $FutureProvider<IndividualRepository> {
  /// **The animals a project tracks** — task 11.240. Separate from
  /// [tagRepository] because a collar and the animal wearing it are different
  /// rows with different lifetimes; colour lives here, and the link between
  /// the two is [deploymentRepository].
  IndividualRepositoryProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'individualRepositoryProvider',
        isAutoDispose: false,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$individualRepositoryHash();

  @$internal
  @override
  $FutureProviderElement<IndividualRepository> $createElement(
    $ProviderPointer pointer,
  ) => $FutureProviderElement(pointer);

  @override
  FutureOr<IndividualRepository> create(Ref ref) {
    return individualRepository(ref);
  }
}

String _$individualRepositoryHash() =>
    r'882e3b7f74d3aa1b773f3c8cf47e93775bad0a3c';

/// **Which collar was on which animal, and when** — task 11.243. The third
/// row in the triple, and the one that carries the dates: see
/// `Tables.deployments`. It is also where Michael's interlock is enforced on
/// this side of the wire.

@ProviderFor(deploymentRepository)
final deploymentRepositoryProvider = DeploymentRepositoryProvider._();

/// **Which collar was on which animal, and when** — task 11.243. The third
/// row in the triple, and the one that carries the dates: see
/// `Tables.deployments`. It is also where Michael's interlock is enforced on
/// this side of the wire.

final class DeploymentRepositoryProvider
    extends
        $FunctionalProvider<
          AsyncValue<DeploymentRepository>,
          DeploymentRepository,
          FutureOr<DeploymentRepository>
        >
    with
        $FutureModifier<DeploymentRepository>,
        $FutureProvider<DeploymentRepository> {
  /// **Which collar was on which animal, and when** — task 11.243. The third
  /// row in the triple, and the one that carries the dates: see
  /// `Tables.deployments`. It is also where Michael's interlock is enforced on
  /// this side of the wire.
  DeploymentRepositoryProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'deploymentRepositoryProvider',
        isAutoDispose: false,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$deploymentRepositoryHash();

  @$internal
  @override
  $FutureProviderElement<DeploymentRepository> $createElement(
    $ProviderPointer pointer,
  ) => $FutureProviderElement(pointer);

  @override
  FutureOr<DeploymentRepository> create(Ref ref) {
    return deploymentRepository(ref);
  }
}

String _$deploymentRepositoryHash() =>
    r'ec04185c5080402e9b0187442713109c781d0313';

@ProviderFor(tagRepository)
final tagRepositoryProvider = TagRepositoryProvider._();

final class TagRepositoryProvider
    extends
        $FunctionalProvider<
          AsyncValue<TagRepository>,
          TagRepository,
          FutureOr<TagRepository>
        >
    with $FutureModifier<TagRepository>, $FutureProvider<TagRepository> {
  TagRepositoryProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'tagRepositoryProvider',
        isAutoDispose: false,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$tagRepositoryHash();

  @$internal
  @override
  $FutureProviderElement<TagRepository> $createElement(
    $ProviderPointer pointer,
  ) => $FutureProviderElement(pointer);

  @override
  FutureOr<TagRepository> create(Ref ref) {
    return tagRepository(ref);
  }
}

String _$tagRepositoryHash() => r'8671cbe47083134bec120a07f8ab5d4fa7185f09';

/// **This device's personal tag library** — task 11.219. Separate from
/// [tagRepository] because the two answer different questions: this one is
/// "what transmitters do I have", that one is "what tags does this project
/// hold". A library entry is device-local and reaches no server.

@ProviderFor(tagLibraryRepository)
final tagLibraryRepositoryProvider = TagLibraryRepositoryProvider._();

/// **This device's personal tag library** — task 11.219. Separate from
/// [tagRepository] because the two answer different questions: this one is
/// "what transmitters do I have", that one is "what tags does this project
/// hold". A library entry is device-local and reaches no server.

final class TagLibraryRepositoryProvider
    extends
        $FunctionalProvider<
          AsyncValue<TagLibraryRepository>,
          TagLibraryRepository,
          FutureOr<TagLibraryRepository>
        >
    with
        $FutureModifier<TagLibraryRepository>,
        $FutureProvider<TagLibraryRepository> {
  /// **This device's personal tag library** — task 11.219. Separate from
  /// [tagRepository] because the two answer different questions: this one is
  /// "what transmitters do I have", that one is "what tags does this project
  /// hold". A library entry is device-local and reaches no server.
  TagLibraryRepositoryProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'tagLibraryRepositoryProvider',
        isAutoDispose: false,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$tagLibraryRepositoryHash();

  @$internal
  @override
  $FutureProviderElement<TagLibraryRepository> $createElement(
    $ProviderPointer pointer,
  ) => $FutureProviderElement(pointer);

  @override
  FutureOr<TagLibraryRepository> create(Ref ref) {
    return tagLibraryRepository(ref);
  }
}

String _$tagLibraryRepositoryHash() =>
    r'9cc7cd56ef37429b850a013fed8c2ccf8d5647c4';

/// Task 11.32's `Tag_Versions` — what a tag read when a record was taken.
/// Separate from [tagRepository] because the two answer different questions
/// and must keep answering them differently: this one is "what was this
/// bearing recorded against?", that one is "what is this tag now?".

@ProviderFor(tagVersionRepository)
final tagVersionRepositoryProvider = TagVersionRepositoryProvider._();

/// Task 11.32's `Tag_Versions` — what a tag read when a record was taken.
/// Separate from [tagRepository] because the two answer different questions
/// and must keep answering them differently: this one is "what was this
/// bearing recorded against?", that one is "what is this tag now?".

final class TagVersionRepositoryProvider
    extends
        $FunctionalProvider<
          AsyncValue<TagVersionRepository>,
          TagVersionRepository,
          FutureOr<TagVersionRepository>
        >
    with
        $FutureModifier<TagVersionRepository>,
        $FutureProvider<TagVersionRepository> {
  /// Task 11.32's `Tag_Versions` — what a tag read when a record was taken.
  /// Separate from [tagRepository] because the two answer different questions
  /// and must keep answering them differently: this one is "what was this
  /// bearing recorded against?", that one is "what is this tag now?".
  TagVersionRepositoryProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'tagVersionRepositoryProvider',
        isAutoDispose: false,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$tagVersionRepositoryHash();

  @$internal
  @override
  $FutureProviderElement<TagVersionRepository> $createElement(
    $ProviderPointer pointer,
  ) => $FutureProviderElement(pointer);

  @override
  FutureOr<TagVersionRepository> create(Ref ref) {
    return tagVersionRepository(ref);
  }
}

String _$tagVersionRepositoryHash() =>
    r'edf8a0e6668e83df42238d2edd7f53acf534eff3';

@ProviderFor(triangulationSessionRepository)
final triangulationSessionRepositoryProvider =
    TriangulationSessionRepositoryProvider._();

final class TriangulationSessionRepositoryProvider
    extends
        $FunctionalProvider<
          AsyncValue<TriangulationSessionRepository>,
          TriangulationSessionRepository,
          FutureOr<TriangulationSessionRepository>
        >
    with
        $FutureModifier<TriangulationSessionRepository>,
        $FutureProvider<TriangulationSessionRepository> {
  TriangulationSessionRepositoryProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'triangulationSessionRepositoryProvider',
        isAutoDispose: false,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$triangulationSessionRepositoryHash();

  @$internal
  @override
  $FutureProviderElement<TriangulationSessionRepository> $createElement(
    $ProviderPointer pointer,
  ) => $FutureProviderElement(pointer);

  @override
  FutureOr<TriangulationSessionRepository> create(Ref ref) {
    return triangulationSessionRepository(ref);
  }
}

String _$triangulationSessionRepositoryHash() =>
    r'6ce717909e2bf0f2081e81120004871e5b09b5cf';

@ProviderFor(observationRepository)
final observationRepositoryProvider = ObservationRepositoryProvider._();

final class ObservationRepositoryProvider
    extends
        $FunctionalProvider<
          AsyncValue<ObservationRepository>,
          ObservationRepository,
          FutureOr<ObservationRepository>
        >
    with
        $FutureModifier<ObservationRepository>,
        $FutureProvider<ObservationRepository> {
  ObservationRepositoryProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'observationRepositoryProvider',
        isAutoDispose: false,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$observationRepositoryHash();

  @$internal
  @override
  $FutureProviderElement<ObservationRepository> $createElement(
    $ProviderPointer pointer,
  ) => $FutureProviderElement(pointer);

  @override
  FutureOr<ObservationRepository> create(Ref ref) {
    return observationRepository(ref);
  }
}

String _$observationRepositoryHash() =>
    r'a9b83a457a8f956821e78a5eefe98a5e9da4334a';

/// Task 11.7's supersede/exclude marks. Separate from
/// [observationRepository] on purpose: nothing that marks an observation ever
/// writes the observation.

@ProviderFor(observationExclusionRepository)
final observationExclusionRepositoryProvider =
    ObservationExclusionRepositoryProvider._();

/// Task 11.7's supersede/exclude marks. Separate from
/// [observationRepository] on purpose: nothing that marks an observation ever
/// writes the observation.

final class ObservationExclusionRepositoryProvider
    extends
        $FunctionalProvider<
          AsyncValue<ObservationExclusionRepository>,
          ObservationExclusionRepository,
          FutureOr<ObservationExclusionRepository>
        >
    with
        $FutureModifier<ObservationExclusionRepository>,
        $FutureProvider<ObservationExclusionRepository> {
  /// Task 11.7's supersede/exclude marks. Separate from
  /// [observationRepository] on purpose: nothing that marks an observation ever
  /// writes the observation.
  ObservationExclusionRepositoryProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'observationExclusionRepositoryProvider',
        isAutoDispose: false,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$observationExclusionRepositoryHash();

  @$internal
  @override
  $FutureProviderElement<ObservationExclusionRepository> $createElement(
    $ProviderPointer pointer,
  ) => $FutureProviderElement(pointer);

  @override
  FutureOr<ObservationExclusionRepository> create(Ref ref) {
    return observationExclusionRepository(ref);
  }
}

String _$observationExclusionRepositoryHash() =>
    r'55c03deea64dbbfae1583c88296c314a3dfa55ff';

@ProviderFor(nonDetectionRepository)
final nonDetectionRepositoryProvider = NonDetectionRepositoryProvider._();

final class NonDetectionRepositoryProvider
    extends
        $FunctionalProvider<
          AsyncValue<NonDetectionRepository>,
          NonDetectionRepository,
          FutureOr<NonDetectionRepository>
        >
    with
        $FutureModifier<NonDetectionRepository>,
        $FutureProvider<NonDetectionRepository> {
  NonDetectionRepositoryProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'nonDetectionRepositoryProvider',
        isAutoDispose: false,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$nonDetectionRepositoryHash();

  @$internal
  @override
  $FutureProviderElement<NonDetectionRepository> $createElement(
    $ProviderPointer pointer,
  ) => $FutureProviderElement(pointer);

  @override
  FutureOr<NonDetectionRepository> create(Ref ref) {
    return nonDetectionRepository(ref);
  }
}

String _$nonDetectionRepositoryHash() =>
    r'a48ae2253a8088d48591d9c5d38494e642f40df8';

@ProviderFor(estimatedPositionRepository)
final estimatedPositionRepositoryProvider =
    EstimatedPositionRepositoryProvider._();

final class EstimatedPositionRepositoryProvider
    extends
        $FunctionalProvider<
          AsyncValue<EstimatedPositionRepository>,
          EstimatedPositionRepository,
          FutureOr<EstimatedPositionRepository>
        >
    with
        $FutureModifier<EstimatedPositionRepository>,
        $FutureProvider<EstimatedPositionRepository> {
  EstimatedPositionRepositoryProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'estimatedPositionRepositoryProvider',
        isAutoDispose: false,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$estimatedPositionRepositoryHash();

  @$internal
  @override
  $FutureProviderElement<EstimatedPositionRepository> $createElement(
    $ProviderPointer pointer,
  ) => $FutureProviderElement(pointer);

  @override
  FutureOr<EstimatedPositionRepository> create(Ref ref) {
    return estimatedPositionRepository(ref);
  }
}

String _$estimatedPositionRepositoryHash() =>
    r'daad5c6115d3e2f54acb5afeb680183e7f54b26d';

@ProviderFor(actualTagLocationRepository)
final actualTagLocationRepositoryProvider =
    ActualTagLocationRepositoryProvider._();

final class ActualTagLocationRepositoryProvider
    extends
        $FunctionalProvider<
          AsyncValue<ActualTagLocationRepository>,
          ActualTagLocationRepository,
          FutureOr<ActualTagLocationRepository>
        >
    with
        $FutureModifier<ActualTagLocationRepository>,
        $FutureProvider<ActualTagLocationRepository> {
  ActualTagLocationRepositoryProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'actualTagLocationRepositoryProvider',
        isAutoDispose: false,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$actualTagLocationRepositoryHash();

  @$internal
  @override
  $FutureProviderElement<ActualTagLocationRepository> $createElement(
    $ProviderPointer pointer,
  ) => $FutureProviderElement(pointer);

  @override
  FutureOr<ActualTagLocationRepository> create(Ref ref) {
    return actualTagLocationRepository(ref);
  }
}

String _$actualTagLocationRepositoryHash() =>
    r'ba5eb996a37094c77d7cf97ea9f2feb9e32dda69';
