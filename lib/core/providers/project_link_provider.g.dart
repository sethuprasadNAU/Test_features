// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'project_link_provider.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint, type=warning
/// Whether [projectId] has been published or joined — the gate that decides
/// whether a "Publish" action or a sync attempt makes sense for it. A family
/// provider (not a single value) because a device typically holds several
/// local projects with different link states at once.

@ProviderFor(isProjectLinked)
final isProjectLinkedProvider = IsProjectLinkedFamily._();

/// Whether [projectId] has been published or joined — the gate that decides
/// whether a "Publish" action or a sync attempt makes sense for it. A family
/// provider (not a single value) because a device typically holds several
/// local projects with different link states at once.

final class IsProjectLinkedProvider
    extends $FunctionalProvider<AsyncValue<bool>, bool, FutureOr<bool>>
    with $FutureModifier<bool>, $FutureProvider<bool> {
  /// Whether [projectId] has been published or joined — the gate that decides
  /// whether a "Publish" action or a sync attempt makes sense for it. A family
  /// provider (not a single value) because a device typically holds several
  /// local projects with different link states at once.
  IsProjectLinkedProvider._({
    required IsProjectLinkedFamily super.from,
    required String super.argument,
  }) : super(
         retry: null,
         name: r'isProjectLinkedProvider',
         isAutoDispose: true,
         dependencies: null,
         $allTransitiveDependencies: null,
       );

  @override
  String debugGetCreateSourceHash() => _$isProjectLinkedHash();

  @override
  String toString() {
    return r'isProjectLinkedProvider'
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
    return isProjectLinked(ref, argument);
  }

  @override
  bool operator ==(Object other) {
    return other is IsProjectLinkedProvider && other.argument == argument;
  }

  @override
  int get hashCode {
    return argument.hashCode;
  }
}

String _$isProjectLinkedHash() => r'd8ab68bbbb111d7b57932053216ac5a9b20d366e';

/// Whether [projectId] has been published or joined — the gate that decides
/// whether a "Publish" action or a sync attempt makes sense for it. A family
/// provider (not a single value) because a device typically holds several
/// local projects with different link states at once.

final class IsProjectLinkedFamily extends $Family
    with $FunctionalFamilyOverride<FutureOr<bool>, String> {
  IsProjectLinkedFamily._()
    : super(
        retry: null,
        name: r'isProjectLinkedProvider',
        dependencies: null,
        $allTransitiveDependencies: null,
        isAutoDispose: true,
      );

  /// Whether [projectId] has been published or joined — the gate that decides
  /// whether a "Publish" action or a sync attempt makes sense for it. A family
  /// provider (not a single value) because a device typically holds several
  /// local projects with different link states at once.

  IsProjectLinkedProvider call(String projectId) =>
      IsProjectLinkedProvider._(argument: projectId, from: this);

  @override
  String toString() => r'isProjectLinkedProvider';
}

/// The projects on this device the signed-in person **currently holds a
/// role on** that are **not yet linked to any server** — task 11.238's "why
/// has nothing left my phone" line, for `ImportCase.adopt`'s live-but-
/// unlinked project and for an ordinary local project nobody has published
/// yet (see [notSyncingYetOwnerDescription]'s doc for why those two cannot
/// be told apart, and why that is fine).
///
/// **Derived on every read, never stored — the same shape
/// [snapshotProjectIdsProvider] uses, on purpose** (11.238's brief: reuse the
/// mechanism 11.237 built rather than invent a second one). A project leaves
/// this set the moment it links, whether by Publish or by properly joining;
/// nothing here needs to know which import produced it, because `ImportCase`
/// is a report about one merge transaction and was never meant to survive
/// past it.
///
/// Same `ref`-after-`await` shape as [snapshotProjectIdsProvider], safe for
/// the same checked reason — see the note there (task 11.256).

@ProviderFor(unsyncedMemberProjectIds)
final unsyncedMemberProjectIdsProvider = UnsyncedMemberProjectIdsProvider._();

/// The projects on this device the signed-in person **currently holds a
/// role on** that are **not yet linked to any server** — task 11.238's "why
/// has nothing left my phone" line, for `ImportCase.adopt`'s live-but-
/// unlinked project and for an ordinary local project nobody has published
/// yet (see [notSyncingYetOwnerDescription]'s doc for why those two cannot
/// be told apart, and why that is fine).
///
/// **Derived on every read, never stored — the same shape
/// [snapshotProjectIdsProvider] uses, on purpose** (11.238's brief: reuse the
/// mechanism 11.237 built rather than invent a second one). A project leaves
/// this set the moment it links, whether by Publish or by properly joining;
/// nothing here needs to know which import produced it, because `ImportCase`
/// is a report about one merge transaction and was never meant to survive
/// past it.
///
/// Same `ref`-after-`await` shape as [snapshotProjectIdsProvider], safe for
/// the same checked reason — see the note there (task 11.256).

final class UnsyncedMemberProjectIdsProvider
    extends
        $FunctionalProvider<
          AsyncValue<Set<String>>,
          Set<String>,
          FutureOr<Set<String>>
        >
    with $FutureModifier<Set<String>>, $FutureProvider<Set<String>> {
  /// The projects on this device the signed-in person **currently holds a
  /// role on** that are **not yet linked to any server** — task 11.238's "why
  /// has nothing left my phone" line, for `ImportCase.adopt`'s live-but-
  /// unlinked project and for an ordinary local project nobody has published
  /// yet (see [notSyncingYetOwnerDescription]'s doc for why those two cannot
  /// be told apart, and why that is fine).
  ///
  /// **Derived on every read, never stored — the same shape
  /// [snapshotProjectIdsProvider] uses, on purpose** (11.238's brief: reuse the
  /// mechanism 11.237 built rather than invent a second one). A project leaves
  /// this set the moment it links, whether by Publish or by properly joining;
  /// nothing here needs to know which import produced it, because `ImportCase`
  /// is a report about one merge transaction and was never meant to survive
  /// past it.
  ///
  /// Same `ref`-after-`await` shape as [snapshotProjectIdsProvider], safe for
  /// the same checked reason — see the note there (task 11.256).
  UnsyncedMemberProjectIdsProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'unsyncedMemberProjectIdsProvider',
        isAutoDispose: true,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$unsyncedMemberProjectIdsHash();

  @$internal
  @override
  $FutureProviderElement<Set<String>> $createElement(
    $ProviderPointer pointer,
  ) => $FutureProviderElement(pointer);

  @override
  FutureOr<Set<String>> create(Ref ref) {
    return unsyncedMemberProjectIds(ref);
  }
}

String _$unsyncedMemberProjectIdsHash() =>
    r'd4b027043bada05203d4ab0effe055e4a5b97dad';

/// Publish, discover, and join server projects (task 10.9).
///
/// Deliberately a separate provider from [SyncController]: publishing and
/// joining act on a project the user picks, which is not necessarily the
/// currently *active* one (join in particular targets a project this device
/// has no local copy of yet, so it cannot be "active"). Ongoing sync, by
/// contrast, always operates on the active project. Folding both into one
/// provider would conflate "which project is this action about" with "which
/// project is currently open."

@ProviderFor(ProjectLinkController)
final projectLinkControllerProvider = ProjectLinkControllerProvider._();

/// Publish, discover, and join server projects (task 10.9).
///
/// Deliberately a separate provider from [SyncController]: publishing and
/// joining act on a project the user picks, which is not necessarily the
/// currently *active* one (join in particular targets a project this device
/// has no local copy of yet, so it cannot be "active"). Ongoing sync, by
/// contrast, always operates on the active project. Folding both into one
/// provider would conflate "which project is this action about" with "which
/// project is currently open."
final class ProjectLinkControllerProvider
    extends $NotifierProvider<ProjectLinkController, void> {
  /// Publish, discover, and join server projects (task 10.9).
  ///
  /// Deliberately a separate provider from [SyncController]: publishing and
  /// joining act on a project the user picks, which is not necessarily the
  /// currently *active* one (join in particular targets a project this device
  /// has no local copy of yet, so it cannot be "active"). Ongoing sync, by
  /// contrast, always operates on the active project. Folding both into one
  /// provider would conflate "which project is this action about" with "which
  /// project is currently open."
  ProjectLinkControllerProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'projectLinkControllerProvider',
        isAutoDispose: false,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$projectLinkControllerHash();

  @$internal
  @override
  ProjectLinkController create() => ProjectLinkController();

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(void value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<void>(value),
    );
  }
}

String _$projectLinkControllerHash() =>
    r'3a110c00d9b9b95cc40b7a2e76485328d7aab057';

/// Publish, discover, and join server projects (task 10.9).
///
/// Deliberately a separate provider from [SyncController]: publishing and
/// joining act on a project the user picks, which is not necessarily the
/// currently *active* one (join in particular targets a project this device
/// has no local copy of yet, so it cannot be "active"). Ongoing sync, by
/// contrast, always operates on the active project. Folding both into one
/// provider would conflate "which project is this action about" with "which
/// project is currently open."

abstract class _$ProjectLinkController extends $Notifier<void> {
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
