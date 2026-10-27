import 'package:flutter_riverpod/flutter_riverpod.dart' show ProviderSubscription;
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../data/db/data_arrival.dart';
import 'app_context_provider.dart';
import 'membership_provider.dart';
import 'project_view_refresh.dart';
import 'tag_view_refresh.dart';

part 'arrival_refresh.g.dart';

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
@Riverpod(keepAlive: true)
class ArrivalRefresh extends _$ArrivalRefresh {
  /// The one-shot subscription that re-runs a refresh the guard held back.
  /// Null whenever nothing is being waited on.
  ProviderSubscription<AsyncValue<Object?>>? _waiting;

  /// **Every provider on the two refresh lists that is not a family**, plus
  /// [currentUserProvider], which is not invalidated here but is the parent
  /// half the families are built out of and cannot be checked per instance.
  ///
  /// This is the list the guard reads. It is deliberately the same providers
  /// [_refreshNow] invalidates: a provider that can be invalidated mid-build
  /// and cannot be asked whether it is mid-build is the gap, so the two lists
  /// drifting apart is the failure to watch for.
  /// Untyped for the reason `tag_view_refresh.dart` records about its own
  /// invalidate callback: `ProviderBase`, the type `Ref.exists` and `Ref.read`
  /// both take, is not exported by any package this app depends on (riverpod
  /// 3.3.2). The entries are real providers and every use of them below is
  /// checked at run time.
  ///
  /// **Static and public so the guard reads this list rather than a copy**
  /// (task 11.154): `test/core/providers/refresh_lists_test.dart` asserts that
  /// every entry here is on one of the two refresh lists, and that every
  /// family on those lists is `autoDispose` — which is the property that makes
  /// leaving families off this list survivable at all.
  static List<dynamic> get settleFirst => [
    currentUserProvider,
    currentProjectProvider,
    allProjectsProvider,
    ownedProjectIdsProvider,
    departedProjectIdsProvider,
    // **The tag library used to be here and is deliberately not (task
    // 11.219).** A sync round cannot change it: `Tag_Library` is
    // device-local, in neither `syncTables` nor any archive, so no pull, no
    // push and no merge writes a row of it. What a pull *can* change is a
    // project's tags, and those are refreshed by the family entries on the
    // tag-view list rather than settled here.
  ];

  @override
  void build() {
    void onArrival() => _refreshWhenNothingIsMidBuild();
    DataArrival.addListener(onArrival);
    ref.onDispose(() {
      DataArrival.removeListener(onArrival);
      _stopWaiting();
    });
  }

  /// Refreshes now, or as soon as whatever is mid-build has finished.
  ///
  /// **`exists` is checked before `read`, and that ordering is load-bearing.**
  /// `ref.read` of a provider that has not been created yet *creates* it, and
  /// one of these mints a device's first user. A refresher that started that as
  /// a side effect of somebody importing a CSV would be a worse bug than the
  /// one this class fixes. A provider that does not exist also cannot be
  /// mid-build, so skipping it is right as well as safe.
  void _refreshWhenNothingIsMidBuild() {
    final busy = _firstMidBuild();
    if (busy == null) {
      _stopWaiting();
      _refreshNow();
      return;
    }
    // Already waiting on something: this announcement is covered by the
    // pending one, because what happens on release is the same invalidation
    // either way.
    if (_waiting != null) return;
    _waiting = ref.listen<AsyncValue<Object?>>(busy as dynamic, (_, next) {
      if (next.isLoading) return;
      _stopWaiting();
      // Re-asks rather than refreshing straight away: one of the *others* may
      // have started building while this one finished.
      _refreshWhenNothingIsMidBuild();
    });
  }

  dynamic _firstMidBuild() {
    for (final provider in settleFirst) {
      if (!ref.exists(provider)) continue;
      if ((ref.read(provider) as AsyncValue<Object?>).isLoading) {
        return provider;
      }
    }
    return null;
  }

  void _stopWaiting() {
    _waiting?.close();
    _waiting = null;
  }

  /// **Null for the project id, on both lists, and that is not laziness.** A
  /// merged page can carry rows for any project this device holds and the
  /// merger reports counts by table, not by project. Naming one project would
  /// be a guess, and the guess would be wrong for the case a second project
  /// is what changed.
  void _refreshNow() {
    refreshProjectViews(ref, projectId: null);
    refreshTagViewsEverywhere(ref);
  }
}
