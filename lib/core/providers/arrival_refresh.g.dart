// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'arrival_refresh.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint, type=warning
/// **Task 11.153. What arrives by syncing refreshes the screens that show it.**
///
/// Task 11.151 closed the eight routes where *this* device is the one that
/// acted. This closes the other half, and it is the worse half, because the
/// person it fails did nothing: an owner promotes you to contributor on their
/// phone, your device pulls the change, and — before this — **the Record screen
/// went on refusing your bearing and the Members screen went on showing your old
/// role until you closed and reopened the app**, with nothing on screen saying
/// so. The same for a teammate publishing a collar you need, and for a project
/// renamed somewhere else.
///
/// **Where it attaches, and why there.** Every route by which somebody else's
/// data reaches this device goes through `ProjectMerger` — a sync pull hands it
/// each page, a join is a pull from cursor zero, a restored backup is the same
/// call with a file behind it — and the merger announces through [DataArrival].
/// Attaching here rather than in `SyncController` is task 11.45's lesson kept:
/// the caller that forgot was the sync pull.
///
/// ## The trap, and exactly what was measured about it
///
/// **`DataArrival.announce()` can be called from inside a provider's build.**
/// `currentUserProvider` announces when it auto-creates a device's first user
/// and when it recovers a tombstoned one, so this is the ordinary first-run
/// path and not a test artefact. Measured on riverpod 3.3.2, with this app's
/// own providers:
///
/// - **Invalidating a provider while it is building orphans the `Future` an
///   awaiter is holding.** For a `keepAlive` provider — [currentProjectProvider]
///   is one — nothing ever completes it: measured, a bare
///   `container.read(currentProjectProvider.future)` with an announcement
///   landing mid-build **never returned**, and no error was raised. For an
///   `autoDispose` provider riverpod 3.3.2 is louder, throwing *"disposed
///   during loading state"* rather than hanging, and a provider a screen is
///   watching recovers on the rebuild.
/// - **Deferring the invalidation to a later event-loop turn does not fix it.**
///   A `Timer.run` was measured making no difference at all: an `async` build
///   stays "building" across its own awaits, so a timer lands inside the
///   window just as readily as a synchronous call does.
/// - **Waiting until the provider has settled does fix it**, and it is the only
///   thing tried that did.
///
/// So that is the guard: [settleFirst] names every provider on the two refresh
/// lists whose state can be asked for by name, and nothing is invalidated while
/// any of them is mid-build. **Families are absent from that list because
/// riverpod 3.3.2 has no way to enumerate a family's live instances**, and that
/// is a stated limit rather than an oversight — every family here is
/// `autoDispose`, which is the loud half of the measurement above.
///
/// **Task 11.154 turned that last sentence from an observation into an
/// assertion.** The live instances still cannot be enumerated; the providers on
/// the lists can, and `refresh_lists_test.dart` fails if any family on either
/// list is `keepAlive`. So the remaining exposure is a `keepAlive` family
/// reached *indirectly* — one this list never names and no listed provider
/// reads — and that is the residue, written down rather than assumed away.
///
/// **Waiting is not dropping.** An announcement that lands mid-build is re-run
/// the moment the build finishes — otherwise a sync round racing app start
/// would lose exactly the refresh this task exists to deliver, which is the
/// same defect with a stopwatch on it.
///
/// ## What it does not do
///
/// **It does not widen what anybody may do.** Every provider it invalidates
/// re-reads the same local membership rows it read before; the write path is
/// unchanged, and `BaseRepository.assertRoleMayWrite` and the server's
/// `RowAuthorizer` still decide every write. What changes is only *when* a
/// screen finds out what this device already believes.
///
/// It does not bump `recordingsRevisionProvider` either — [RecordingsRevision]
/// subscribes to [DataArrival] on its own account, and has since task 11.45.

@ProviderFor(ArrivalRefresh)
final arrivalRefreshProvider = ArrivalRefreshProvider._();

/// **Task 11.153. What arrives by syncing refreshes the screens that show it.**
///
/// Task 11.151 closed the eight routes where *this* device is the one that
/// acted. This closes the other half, and it is the worse half, because the
/// person it fails did nothing: an owner promotes you to contributor on their
/// phone, your device pulls the change, and — before this — **the Record screen
/// went on refusing your bearing and the Members screen went on showing your old
/// role until you closed and reopened the app**, with nothing on screen saying
/// so. The same for a teammate publishing a collar you need, and for a project
/// renamed somewhere else.
///
/// **Where it attaches, and why there.** Every route by which somebody else's
/// data reaches this device goes through `ProjectMerger` — a sync pull hands it
/// each page, a join is a pull from cursor zero, a restored backup is the same
/// call with a file behind it — and the merger announces through [DataArrival].
/// Attaching here rather than in `SyncController` is task 11.45's lesson kept:
/// the caller that forgot was the sync pull.
///
/// ## The trap, and exactly what was measured about it
///
/// **`DataArrival.announce()` can be called from inside a provider's build.**
/// `currentUserProvider` announces when it auto-creates a device's first user
/// and when it recovers a tombstoned one, so this is the ordinary first-run
/// path and not a test artefact. Measured on riverpod 3.3.2, with this app's
/// own providers:
///
/// - **Invalidating a provider while it is building orphans the `Future` an
///   awaiter is holding.** For a `keepAlive` provider — [currentProjectProvider]
///   is one — nothing ever completes it: measured, a bare
///   `container.read(currentProjectProvider.future)` with an announcement
///   landing mid-build **never returned**, and no error was raised. For an
///   `autoDispose` provider riverpod 3.3.2 is louder, throwing *"disposed
///   during loading state"* rather than hanging, and a provider a screen is
///   watching recovers on the rebuild.
/// - **Deferring the invalidation to a later event-loop turn does not fix it.**
///   A `Timer.run` was measured making no difference at all: an `async` build
///   stays "building" across its own awaits, so a timer lands inside the
///   window just as readily as a synchronous call does.
/// - **Waiting until the provider has settled does fix it**, and it is the only
///   thing tried that did.
///
/// So that is the guard: [settleFirst] names every provider on the two refresh
/// lists whose state can be asked for by name, and nothing is invalidated while
/// any of them is mid-build. **Families are absent from that list because
/// riverpod 3.3.2 has no way to enumerate a family's live instances**, and that
/// is a stated limit rather than an oversight — every family here is
/// `autoDispose`, which is the loud half of the measurement above.
///
/// **Task 11.154 turned that last sentence from an observation into an
/// assertion.** The live instances still cannot be enumerated; the providers on
/// the lists can, and `refresh_lists_test.dart` fails if any family on either
/// list is `keepAlive`. So the remaining exposure is a `keepAlive` family
/// reached *indirectly* — one this list never names and no listed provider
/// reads — and that is the residue, written down rather than assumed away.
///
/// **Waiting is not dropping.** An announcement that lands mid-build is re-run
/// the moment the build finishes — otherwise a sync round racing app start
/// would lose exactly the refresh this task exists to deliver, which is the
/// same defect with a stopwatch on it.
///
/// ## What it does not do
///
/// **It does not widen what anybody may do.** Every provider it invalidates
/// re-reads the same local membership rows it read before; the write path is
/// unchanged, and `BaseRepository.assertRoleMayWrite` and the server's
/// `RowAuthorizer` still decide every write. What changes is only *when* a
/// screen finds out what this device already believes.
///
/// It does not bump `recordingsRevisionProvider` either — [RecordingsRevision]
/// subscribes to [DataArrival] on its own account, and has since task 11.45.
final class ArrivalRefreshProvider
    extends $NotifierProvider<ArrivalRefresh, void> {
  /// **Task 11.153. What arrives by syncing refreshes the screens that show it.**
  ///
  /// Task 11.151 closed the eight routes where *this* device is the one that
  /// acted. This closes the other half, and it is the worse half, because the
  /// person it fails did nothing: an owner promotes you to contributor on their
  /// phone, your device pulls the change, and — before this — **the Record screen
  /// went on refusing your bearing and the Members screen went on showing your old
  /// role until you closed and reopened the app**, with nothing on screen saying
  /// so. The same for a teammate publishing a collar you need, and for a project
  /// renamed somewhere else.
  ///
  /// **Where it attaches, and why there.** Every route by which somebody else's
  /// data reaches this device goes through `ProjectMerger` — a sync pull hands it
  /// each page, a join is a pull from cursor zero, a restored backup is the same
  /// call with a file behind it — and the merger announces through [DataArrival].
  /// Attaching here rather than in `SyncController` is task 11.45's lesson kept:
  /// the caller that forgot was the sync pull.
  ///
  /// ## The trap, and exactly what was measured about it
  ///
  /// **`DataArrival.announce()` can be called from inside a provider's build.**
  /// `currentUserProvider` announces when it auto-creates a device's first user
  /// and when it recovers a tombstoned one, so this is the ordinary first-run
  /// path and not a test artefact. Measured on riverpod 3.3.2, with this app's
  /// own providers:
  ///
  /// - **Invalidating a provider while it is building orphans the `Future` an
  ///   awaiter is holding.** For a `keepAlive` provider — [currentProjectProvider]
  ///   is one — nothing ever completes it: measured, a bare
  ///   `container.read(currentProjectProvider.future)` with an announcement
  ///   landing mid-build **never returned**, and no error was raised. For an
  ///   `autoDispose` provider riverpod 3.3.2 is louder, throwing *"disposed
  ///   during loading state"* rather than hanging, and a provider a screen is
  ///   watching recovers on the rebuild.
  /// - **Deferring the invalidation to a later event-loop turn does not fix it.**
  ///   A `Timer.run` was measured making no difference at all: an `async` build
  ///   stays "building" across its own awaits, so a timer lands inside the
  ///   window just as readily as a synchronous call does.
  /// - **Waiting until the provider has settled does fix it**, and it is the only
  ///   thing tried that did.
  ///
  /// So that is the guard: [settleFirst] names every provider on the two refresh
  /// lists whose state can be asked for by name, and nothing is invalidated while
  /// any of them is mid-build. **Families are absent from that list because
  /// riverpod 3.3.2 has no way to enumerate a family's live instances**, and that
  /// is a stated limit rather than an oversight — every family here is
  /// `autoDispose`, which is the loud half of the measurement above.
  ///
  /// **Task 11.154 turned that last sentence from an observation into an
  /// assertion.** The live instances still cannot be enumerated; the providers on
  /// the lists can, and `refresh_lists_test.dart` fails if any family on either
  /// list is `keepAlive`. So the remaining exposure is a `keepAlive` family
  /// reached *indirectly* — one this list never names and no listed provider
  /// reads — and that is the residue, written down rather than assumed away.
  ///
  /// **Waiting is not dropping.** An announcement that lands mid-build is re-run
  /// the moment the build finishes — otherwise a sync round racing app start
  /// would lose exactly the refresh this task exists to deliver, which is the
  /// same defect with a stopwatch on it.
  ///
  /// ## What it does not do
  ///
  /// **It does not widen what anybody may do.** Every provider it invalidates
  /// re-reads the same local membership rows it read before; the write path is
  /// unchanged, and `BaseRepository.assertRoleMayWrite` and the server's
  /// `RowAuthorizer` still decide every write. What changes is only *when* a
  /// screen finds out what this device already believes.
  ///
  /// It does not bump `recordingsRevisionProvider` either — [RecordingsRevision]
  /// subscribes to [DataArrival] on its own account, and has since task 11.45.
  ArrivalRefreshProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'arrivalRefreshProvider',
        isAutoDispose: false,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$arrivalRefreshHash();

  @$internal
  @override
  ArrivalRefresh create() => ArrivalRefresh();

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(void value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<void>(value),
    );
  }
}

String _$arrivalRefreshHash() => r'6e2e413a6cce7bff12e48b5f5898968d2bd506ae';

/// **Task 11.153. What arrives by syncing refreshes the screens that show it.**
///
/// Task 11.151 closed the eight routes where *this* device is the one that
/// acted. This closes the other half, and it is the worse half, because the
/// person it fails did nothing: an owner promotes you to contributor on their
/// phone, your device pulls the change, and — before this — **the Record screen
/// went on refusing your bearing and the Members screen went on showing your old
/// role until you closed and reopened the app**, with nothing on screen saying
/// so. The same for a teammate publishing a collar you need, and for a project
/// renamed somewhere else.
///
/// **Where it attaches, and why there.** Every route by which somebody else's
/// data reaches this device goes through `ProjectMerger` — a sync pull hands it
/// each page, a join is a pull from cursor zero, a restored backup is the same
/// call with a file behind it — and the merger announces through [DataArrival].
/// Attaching here rather than in `SyncController` is task 11.45's lesson kept:
/// the caller that forgot was the sync pull.
///
/// ## The trap, and exactly what was measured about it
///
/// **`DataArrival.announce()` can be called from inside a provider's build.**
/// `currentUserProvider` announces when it auto-creates a device's first user
/// and when it recovers a tombstoned one, so this is the ordinary first-run
/// path and not a test artefact. Measured on riverpod 3.3.2, with this app's
/// own providers:
///
/// - **Invalidating a provider while it is building orphans the `Future` an
///   awaiter is holding.** For a `keepAlive` provider — [currentProjectProvider]
///   is one — nothing ever completes it: measured, a bare
///   `container.read(currentProjectProvider.future)` with an announcement
///   landing mid-build **never returned**, and no error was raised. For an
///   `autoDispose` provider riverpod 3.3.2 is louder, throwing *"disposed
///   during loading state"* rather than hanging, and a provider a screen is
///   watching recovers on the rebuild.
/// - **Deferring the invalidation to a later event-loop turn does not fix it.**
///   A `Timer.run` was measured making no difference at all: an `async` build
///   stays "building" across its own awaits, so a timer lands inside the
///   window just as readily as a synchronous call does.
/// - **Waiting until the provider has settled does fix it**, and it is the only
///   thing tried that did.
///
/// So that is the guard: [settleFirst] names every provider on the two refresh
/// lists whose state can be asked for by name, and nothing is invalidated while
/// any of them is mid-build. **Families are absent from that list because
/// riverpod 3.3.2 has no way to enumerate a family's live instances**, and that
/// is a stated limit rather than an oversight — every family here is
/// `autoDispose`, which is the loud half of the measurement above.
///
/// **Task 11.154 turned that last sentence from an observation into an
/// assertion.** The live instances still cannot be enumerated; the providers on
/// the lists can, and `refresh_lists_test.dart` fails if any family on either
/// list is `keepAlive`. So the remaining exposure is a `keepAlive` family
/// reached *indirectly* — one this list never names and no listed provider
/// reads — and that is the residue, written down rather than assumed away.
///
/// **Waiting is not dropping.** An announcement that lands mid-build is re-run
/// the moment the build finishes — otherwise a sync round racing app start
/// would lose exactly the refresh this task exists to deliver, which is the
/// same defect with a stopwatch on it.
///
/// ## What it does not do
///
/// **It does not widen what anybody may do.** Every provider it invalidates
/// re-reads the same local membership rows it read before; the write path is
/// unchanged, and `BaseRepository.assertRoleMayWrite` and the server's
/// `RowAuthorizer` still decide every write. What changes is only *when* a
/// screen finds out what this device already believes.
///
/// It does not bump `recordingsRevisionProvider` either — [RecordingsRevision]
/// subscribes to [DataArrival] on its own account, and has since task 11.45.

abstract class _$ArrivalRefresh extends $Notifier<void> {
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
