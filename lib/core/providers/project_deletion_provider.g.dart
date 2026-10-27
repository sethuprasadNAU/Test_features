// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'project_deletion_provider.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint, type=warning
/// **Where each project's scheduled deletion stands, as this device last
/// heard it** (task 11.290) — keyed by project id.
///
/// The Projects list draws its countdowns from this. It is read from
/// `SyncStateStore` so the list is right offline, and refreshed from
/// `GET /projects/mine` whenever a person is looking at the list — on
/// opening it, on pull-to-refresh, and when the app comes to the foreground.
///
/// ## Who writes it
///
/// - [refreshFromServer]: every project the directory lists gets the date it
///   carries, or has its notice removed when it carries none (the owner
///   canceled). A project the directory *no longer lists* while this device
///   is still counting it down is **asked about directly** — one pull of one
///   row — because from the listing alone the device cannot tell "destroyed"
///   from "I was removed", and only the server's named refusal settles it.
///   Michael's device look (2026-09-20) found the gap: the sweep ran, the
///   project left the listing, and the row on a phone that did not have that
///   project open went on saying the date had passed unconfirmed, because
///   the only thing that had ever asked the server *about that project* was
///   its own sync round.
/// - [markDestroyed]: the server refused the project with
///   `project_destroyed`, or the owner's own *delete now* ran on this device.
///   The row then says the project is gone from the server, rather than
///   counting down past zero.
/// - [act]: the owner scheduled, canceled or destroyed from this device, and
///   the server's answer is written straight in so the row moves at once.

@ProviderFor(ProjectDeletionNotices)
final projectDeletionNoticesProvider = ProjectDeletionNoticesProvider._();

/// **Where each project's scheduled deletion stands, as this device last
/// heard it** (task 11.290) — keyed by project id.
///
/// The Projects list draws its countdowns from this. It is read from
/// `SyncStateStore` so the list is right offline, and refreshed from
/// `GET /projects/mine` whenever a person is looking at the list — on
/// opening it, on pull-to-refresh, and when the app comes to the foreground.
///
/// ## Who writes it
///
/// - [refreshFromServer]: every project the directory lists gets the date it
///   carries, or has its notice removed when it carries none (the owner
///   canceled). A project the directory *no longer lists* while this device
///   is still counting it down is **asked about directly** — one pull of one
///   row — because from the listing alone the device cannot tell "destroyed"
///   from "I was removed", and only the server's named refusal settles it.
///   Michael's device look (2026-09-20) found the gap: the sweep ran, the
///   project left the listing, and the row on a phone that did not have that
///   project open went on saying the date had passed unconfirmed, because
///   the only thing that had ever asked the server *about that project* was
///   its own sync round.
/// - [markDestroyed]: the server refused the project with
///   `project_destroyed`, or the owner's own *delete now* ran on this device.
///   The row then says the project is gone from the server, rather than
///   counting down past zero.
/// - [act]: the owner scheduled, canceled or destroyed from this device, and
///   the server's answer is written straight in so the row moves at once.
final class ProjectDeletionNoticesProvider
    extends
        $AsyncNotifierProvider<
          ProjectDeletionNotices,
          Map<String, ProjectDeletionNotice>
        > {
  /// **Where each project's scheduled deletion stands, as this device last
  /// heard it** (task 11.290) — keyed by project id.
  ///
  /// The Projects list draws its countdowns from this. It is read from
  /// `SyncStateStore` so the list is right offline, and refreshed from
  /// `GET /projects/mine` whenever a person is looking at the list — on
  /// opening it, on pull-to-refresh, and when the app comes to the foreground.
  ///
  /// ## Who writes it
  ///
  /// - [refreshFromServer]: every project the directory lists gets the date it
  ///   carries, or has its notice removed when it carries none (the owner
  ///   canceled). A project the directory *no longer lists* while this device
  ///   is still counting it down is **asked about directly** — one pull of one
  ///   row — because from the listing alone the device cannot tell "destroyed"
  ///   from "I was removed", and only the server's named refusal settles it.
  ///   Michael's device look (2026-09-20) found the gap: the sweep ran, the
  ///   project left the listing, and the row on a phone that did not have that
  ///   project open went on saying the date had passed unconfirmed, because
  ///   the only thing that had ever asked the server *about that project* was
  ///   its own sync round.
  /// - [markDestroyed]: the server refused the project with
  ///   `project_destroyed`, or the owner's own *delete now* ran on this device.
  ///   The row then says the project is gone from the server, rather than
  ///   counting down past zero.
  /// - [act]: the owner scheduled, canceled or destroyed from this device, and
  ///   the server's answer is written straight in so the row moves at once.
  ProjectDeletionNoticesProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'projectDeletionNoticesProvider',
        isAutoDispose: false,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$projectDeletionNoticesHash();

  @$internal
  @override
  ProjectDeletionNotices create() => ProjectDeletionNotices();
}

String _$projectDeletionNoticesHash() =>
    r'23561223170da23b41e0dfbbabfe06b940bdc573';

/// **Where each project's scheduled deletion stands, as this device last
/// heard it** (task 11.290) — keyed by project id.
///
/// The Projects list draws its countdowns from this. It is read from
/// `SyncStateStore` so the list is right offline, and refreshed from
/// `GET /projects/mine` whenever a person is looking at the list — on
/// opening it, on pull-to-refresh, and when the app comes to the foreground.
///
/// ## Who writes it
///
/// - [refreshFromServer]: every project the directory lists gets the date it
///   carries, or has its notice removed when it carries none (the owner
///   canceled). A project the directory *no longer lists* while this device
///   is still counting it down is **asked about directly** — one pull of one
///   row — because from the listing alone the device cannot tell "destroyed"
///   from "I was removed", and only the server's named refusal settles it.
///   Michael's device look (2026-09-20) found the gap: the sweep ran, the
///   project left the listing, and the row on a phone that did not have that
///   project open went on saying the date had passed unconfirmed, because
///   the only thing that had ever asked the server *about that project* was
///   its own sync round.
/// - [markDestroyed]: the server refused the project with
///   `project_destroyed`, or the owner's own *delete now* ran on this device.
///   The row then says the project is gone from the server, rather than
///   counting down past zero.
/// - [act]: the owner scheduled, canceled or destroyed from this device, and
///   the server's answer is written straight in so the row moves at once.

abstract class _$ProjectDeletionNotices
    extends $AsyncNotifier<Map<String, ProjectDeletionNotice>> {
  FutureOr<Map<String, ProjectDeletionNotice>> build();
  @$mustCallSuper
  @override
  WhenComplete runBuild() {
    final ref =
        this.ref
            as $Ref<
              AsyncValue<Map<String, ProjectDeletionNotice>>,
              Map<String, ProjectDeletionNotice>
            >;
    final element =
        ref.element
            as $ClassProviderElement<
              AnyNotifier<
                AsyncValue<Map<String, ProjectDeletionNotice>>,
                Map<String, ProjectDeletionNotice>
              >,
              AsyncValue<Map<String, ProjectDeletionNotice>>,
              Object?,
              Object?
            >;
    return element.handleCreate(ref, build);
  }
}

/// **The refusal the last delivery attempt for a project's own row met**,
/// keyed by project id (task 11.290, folding in task 11.289's open question).
///
/// `SyncController.deliverPendingProjectChanges` runs one round per stranded
/// `Projects` row and swallows every failure — correctly, because "delivered"
/// is decided from the pending set and not from the round. What it could not
/// do was *say* anything: an owner whose deletion the server refused (the
/// project records somebody else as owner; a build too old) believed the
/// project gone while it stayed live for the team, and nothing anywhere
/// showed the refusal. This is where the round writes the cause, so the
/// Projects list can put a row on screen saying **the server has not accepted
/// this deletion**. Cleared when the row is finally delivered, or when the
/// device gives up on it (the project is unlinked).

@ProviderFor(ProjectChangeRefusals)
final projectChangeRefusalsProvider = ProjectChangeRefusalsProvider._();

/// **The refusal the last delivery attempt for a project's own row met**,
/// keyed by project id (task 11.290, folding in task 11.289's open question).
///
/// `SyncController.deliverPendingProjectChanges` runs one round per stranded
/// `Projects` row and swallows every failure — correctly, because "delivered"
/// is decided from the pending set and not from the round. What it could not
/// do was *say* anything: an owner whose deletion the server refused (the
/// project records somebody else as owner; a build too old) believed the
/// project gone while it stayed live for the team, and nothing anywhere
/// showed the refusal. This is where the round writes the cause, so the
/// Projects list can put a row on screen saying **the server has not accepted
/// this deletion**. Cleared when the row is finally delivered, or when the
/// device gives up on it (the project is unlinked).
final class ProjectChangeRefusalsProvider
    extends
        $NotifierProvider<
          ProjectChangeRefusals,
          Map<String, SyncFailureCause>
        > {
  /// **The refusal the last delivery attempt for a project's own row met**,
  /// keyed by project id (task 11.290, folding in task 11.289's open question).
  ///
  /// `SyncController.deliverPendingProjectChanges` runs one round per stranded
  /// `Projects` row and swallows every failure — correctly, because "delivered"
  /// is decided from the pending set and not from the round. What it could not
  /// do was *say* anything: an owner whose deletion the server refused (the
  /// project records somebody else as owner; a build too old) believed the
  /// project gone while it stayed live for the team, and nothing anywhere
  /// showed the refusal. This is where the round writes the cause, so the
  /// Projects list can put a row on screen saying **the server has not accepted
  /// this deletion**. Cleared when the row is finally delivered, or when the
  /// device gives up on it (the project is unlinked).
  ProjectChangeRefusalsProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'projectChangeRefusalsProvider',
        isAutoDispose: false,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$projectChangeRefusalsHash();

  @$internal
  @override
  ProjectChangeRefusals create() => ProjectChangeRefusals();

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(Map<String, SyncFailureCause> value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<Map<String, SyncFailureCause>>(
        value,
      ),
    );
  }
}

String _$projectChangeRefusalsHash() =>
    r'b9a92a288c7827de65948316ff53b1123d333e5f';

/// **The refusal the last delivery attempt for a project's own row met**,
/// keyed by project id (task 11.290, folding in task 11.289's open question).
///
/// `SyncController.deliverPendingProjectChanges` runs one round per stranded
/// `Projects` row and swallows every failure — correctly, because "delivered"
/// is decided from the pending set and not from the round. What it could not
/// do was *say* anything: an owner whose deletion the server refused (the
/// project records somebody else as owner; a build too old) believed the
/// project gone while it stayed live for the team, and nothing anywhere
/// showed the refusal. This is where the round writes the cause, so the
/// Projects list can put a row on screen saying **the server has not accepted
/// this deletion**. Cleared when the row is finally delivered, or when the
/// device gives up on it (the project is unlinked).

abstract class _$ProjectChangeRefusals
    extends $Notifier<Map<String, SyncFailureCause>> {
  Map<String, SyncFailureCause> build();
  @$mustCallSuper
  @override
  WhenComplete runBuild() {
    final ref =
        this.ref
            as $Ref<
              Map<String, SyncFailureCause>,
              Map<String, SyncFailureCause>
            >;
    final element =
        ref.element
            as $ClassProviderElement<
              AnyNotifier<
                Map<String, SyncFailureCause>,
                Map<String, SyncFailureCause>
              >,
              Map<String, SyncFailureCause>,
              Object?,
              Object?
            >;
    return element.handleCreate(ref, build);
  }
}

/// **Every project deleted here that is still live on the server as far as
/// this device knows** — task 11.289's own recommendation, built as a row on
/// the Projects list rather than a retry.
///
/// Derived from the same predicate the push runs (`findUndeliveredProjectChanges`
/// → `SyncEngine.wouldOffer`), narrowed to tombstones, and joined with the
/// refusal memory above. A deleted project is otherwise invisible on every
/// screen, so this is the one place the person who deleted it can learn it
/// did not take.

@ProviderFor(undeliveredProjectDeletions)
final undeliveredProjectDeletionsProvider =
    UndeliveredProjectDeletionsProvider._();

/// **Every project deleted here that is still live on the server as far as
/// this device knows** — task 11.289's own recommendation, built as a row on
/// the Projects list rather than a retry.
///
/// Derived from the same predicate the push runs (`findUndeliveredProjectChanges`
/// → `SyncEngine.wouldOffer`), narrowed to tombstones, and joined with the
/// refusal memory above. A deleted project is otherwise invisible on every
/// screen, so this is the one place the person who deleted it can learn it
/// did not take.

final class UndeliveredProjectDeletionsProvider
    extends
        $FunctionalProvider<
          AsyncValue<List<UndeliveredProjectDeletion>>,
          List<UndeliveredProjectDeletion>,
          FutureOr<List<UndeliveredProjectDeletion>>
        >
    with
        $FutureModifier<List<UndeliveredProjectDeletion>>,
        $FutureProvider<List<UndeliveredProjectDeletion>> {
  /// **Every project deleted here that is still live on the server as far as
  /// this device knows** — task 11.289's own recommendation, built as a row on
  /// the Projects list rather than a retry.
  ///
  /// Derived from the same predicate the push runs (`findUndeliveredProjectChanges`
  /// → `SyncEngine.wouldOffer`), narrowed to tombstones, and joined with the
  /// refusal memory above. A deleted project is otherwise invisible on every
  /// screen, so this is the one place the person who deleted it can learn it
  /// did not take.
  UndeliveredProjectDeletionsProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'undeliveredProjectDeletionsProvider',
        isAutoDispose: true,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$undeliveredProjectDeletionsHash();

  @$internal
  @override
  $FutureProviderElement<List<UndeliveredProjectDeletion>> $createElement(
    $ProviderPointer pointer,
  ) => $FutureProviderElement(pointer);

  @override
  FutureOr<List<UndeliveredProjectDeletion>> create(Ref ref) {
    return undeliveredProjectDeletions(ref);
  }
}

String _$undeliveredProjectDeletionsHash() =>
    r'4145fb18f6d69368ec894fbd41bb4011317b9dfe';
