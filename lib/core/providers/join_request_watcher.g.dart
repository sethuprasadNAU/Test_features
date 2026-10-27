// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'join_request_watcher.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint, type=warning
/// **Turns "the owner approved you" into "the project is on your phone"**
/// (task 11.83).
///
/// ## The defect this exists to close
///
/// Task 11.81 shipped the flow the design specified, and §2.3 of
/// `JOIN_CODE_AND_APPROVAL_DESIGN.md` said of the requester's side *"nothing
/// new is needed"* — because after approval the project does appear in
/// `GET /projects/mine`, and the "Join a project" screen does render it with a
/// Join button. Michael ran it on two real devices on 2026-08-31: the Mac
/// approved, and the project never appeared on the iPhone. Nothing errored.
/// **The person had no reason to go back to that screen and nothing told them
/// to**, and the one element that had been tracking the request — the "Your
/// requests" card — filtered approvals out of its own list, so at the exact
/// moment the news arrived it went blank.
///
/// So this does two things, and they are one mechanism rather than two:
///
/// 1. **It completes the join without being asked.** A device that knows it
///    has been let in and waits to be told again is the same silence in a new
///    place.
/// 2. **It carries the state the card narrates**, so approval and rejection
///    are told through the same element in the same place.
///
/// ## When it asks
///
/// - **Every [joinRequestPollInterval] while a request is outstanding**, and
///   only then. A device with nothing pending polls nothing, and the poll
///   stops the moment the last outstanding request is decided — see
///   [_reschedule]. That is what keeps this from being a battery cost with no
///   purpose.
/// - **Once whenever the app comes to the foreground.** The approval usually
///   lands while the phone is in a pocket, so this is the common real case.
/// - **On pull-to-refresh** on the projects screen, which is the manual
///   override and the thing a person actually reaches for.
///
/// **Foreground only. If the app is closed, nothing arrives until it is
/// opened**, and there is no mechanism here or anywhere else in this app that
/// changes that: delivering to a closed app means push notifications, which
/// need an Apple developer account this project does not have.
///
/// **It is not the sync tick, and that was measured rather than assumed.**
/// Automatic sync (task 11.59) runs against the *active, linked* project and
/// asks neither `/projects/join-requests/mine` nor `/projects/mine` —
/// so for somebody joining their **first** project, which is the case that
/// matters most, there is no loop to piggyback on at all.

@ProviderFor(JoinRequestWatcher)
final joinRequestWatcherProvider = JoinRequestWatcherProvider._();

/// **Turns "the owner approved you" into "the project is on your phone"**
/// (task 11.83).
///
/// ## The defect this exists to close
///
/// Task 11.81 shipped the flow the design specified, and §2.3 of
/// `JOIN_CODE_AND_APPROVAL_DESIGN.md` said of the requester's side *"nothing
/// new is needed"* — because after approval the project does appear in
/// `GET /projects/mine`, and the "Join a project" screen does render it with a
/// Join button. Michael ran it on two real devices on 2026-08-31: the Mac
/// approved, and the project never appeared on the iPhone. Nothing errored.
/// **The person had no reason to go back to that screen and nothing told them
/// to**, and the one element that had been tracking the request — the "Your
/// requests" card — filtered approvals out of its own list, so at the exact
/// moment the news arrived it went blank.
///
/// So this does two things, and they are one mechanism rather than two:
///
/// 1. **It completes the join without being asked.** A device that knows it
///    has been let in and waits to be told again is the same silence in a new
///    place.
/// 2. **It carries the state the card narrates**, so approval and rejection
///    are told through the same element in the same place.
///
/// ## When it asks
///
/// - **Every [joinRequestPollInterval] while a request is outstanding**, and
///   only then. A device with nothing pending polls nothing, and the poll
///   stops the moment the last outstanding request is decided — see
///   [_reschedule]. That is what keeps this from being a battery cost with no
///   purpose.
/// - **Once whenever the app comes to the foreground.** The approval usually
///   lands while the phone is in a pocket, so this is the common real case.
/// - **On pull-to-refresh** on the projects screen, which is the manual
///   override and the thing a person actually reaches for.
///
/// **Foreground only. If the app is closed, nothing arrives until it is
/// opened**, and there is no mechanism here or anywhere else in this app that
/// changes that: delivering to a closed app means push notifications, which
/// need an Apple developer account this project does not have.
///
/// **It is not the sync tick, and that was measured rather than assumed.**
/// Automatic sync (task 11.59) runs against the *active, linked* project and
/// asks neither `/projects/join-requests/mine` nor `/projects/mine` —
/// so for somebody joining their **first** project, which is the case that
/// matters most, there is no loop to piggyback on at all.
final class JoinRequestWatcherProvider
    extends $NotifierProvider<JoinRequestWatcher, JoinWatch> {
  /// **Turns "the owner approved you" into "the project is on your phone"**
  /// (task 11.83).
  ///
  /// ## The defect this exists to close
  ///
  /// Task 11.81 shipped the flow the design specified, and §2.3 of
  /// `JOIN_CODE_AND_APPROVAL_DESIGN.md` said of the requester's side *"nothing
  /// new is needed"* — because after approval the project does appear in
  /// `GET /projects/mine`, and the "Join a project" screen does render it with a
  /// Join button. Michael ran it on two real devices on 2026-08-31: the Mac
  /// approved, and the project never appeared on the iPhone. Nothing errored.
  /// **The person had no reason to go back to that screen and nothing told them
  /// to**, and the one element that had been tracking the request — the "Your
  /// requests" card — filtered approvals out of its own list, so at the exact
  /// moment the news arrived it went blank.
  ///
  /// So this does two things, and they are one mechanism rather than two:
  ///
  /// 1. **It completes the join without being asked.** A device that knows it
  ///    has been let in and waits to be told again is the same silence in a new
  ///    place.
  /// 2. **It carries the state the card narrates**, so approval and rejection
  ///    are told through the same element in the same place.
  ///
  /// ## When it asks
  ///
  /// - **Every [joinRequestPollInterval] while a request is outstanding**, and
  ///   only then. A device with nothing pending polls nothing, and the poll
  ///   stops the moment the last outstanding request is decided — see
  ///   [_reschedule]. That is what keeps this from being a battery cost with no
  ///   purpose.
  /// - **Once whenever the app comes to the foreground.** The approval usually
  ///   lands while the phone is in a pocket, so this is the common real case.
  /// - **On pull-to-refresh** on the projects screen, which is the manual
  ///   override and the thing a person actually reaches for.
  ///
  /// **Foreground only. If the app is closed, nothing arrives until it is
  /// opened**, and there is no mechanism here or anywhere else in this app that
  /// changes that: delivering to a closed app means push notifications, which
  /// need an Apple developer account this project does not have.
  ///
  /// **It is not the sync tick, and that was measured rather than assumed.**
  /// Automatic sync (task 11.59) runs against the *active, linked* project and
  /// asks neither `/projects/join-requests/mine` nor `/projects/mine` —
  /// so for somebody joining their **first** project, which is the case that
  /// matters most, there is no loop to piggyback on at all.
  JoinRequestWatcherProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'joinRequestWatcherProvider',
        isAutoDispose: false,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$joinRequestWatcherHash();

  @$internal
  @override
  JoinRequestWatcher create() => JoinRequestWatcher();

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(JoinWatch value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<JoinWatch>(value),
    );
  }
}

String _$joinRequestWatcherHash() =>
    r'6c6d2c6108ae05959030ef47da753c58e9bbe655';

/// **Turns "the owner approved you" into "the project is on your phone"**
/// (task 11.83).
///
/// ## The defect this exists to close
///
/// Task 11.81 shipped the flow the design specified, and §2.3 of
/// `JOIN_CODE_AND_APPROVAL_DESIGN.md` said of the requester's side *"nothing
/// new is needed"* — because after approval the project does appear in
/// `GET /projects/mine`, and the "Join a project" screen does render it with a
/// Join button. Michael ran it on two real devices on 2026-08-31: the Mac
/// approved, and the project never appeared on the iPhone. Nothing errored.
/// **The person had no reason to go back to that screen and nothing told them
/// to**, and the one element that had been tracking the request — the "Your
/// requests" card — filtered approvals out of its own list, so at the exact
/// moment the news arrived it went blank.
///
/// So this does two things, and they are one mechanism rather than two:
///
/// 1. **It completes the join without being asked.** A device that knows it
///    has been let in and waits to be told again is the same silence in a new
///    place.
/// 2. **It carries the state the card narrates**, so approval and rejection
///    are told through the same element in the same place.
///
/// ## When it asks
///
/// - **Every [joinRequestPollInterval] while a request is outstanding**, and
///   only then. A device with nothing pending polls nothing, and the poll
///   stops the moment the last outstanding request is decided — see
///   [_reschedule]. That is what keeps this from being a battery cost with no
///   purpose.
/// - **Once whenever the app comes to the foreground.** The approval usually
///   lands while the phone is in a pocket, so this is the common real case.
/// - **On pull-to-refresh** on the projects screen, which is the manual
///   override and the thing a person actually reaches for.
///
/// **Foreground only. If the app is closed, nothing arrives until it is
/// opened**, and there is no mechanism here or anywhere else in this app that
/// changes that: delivering to a closed app means push notifications, which
/// need an Apple developer account this project does not have.
///
/// **It is not the sync tick, and that was measured rather than assumed.**
/// Automatic sync (task 11.59) runs against the *active, linked* project and
/// asks neither `/projects/join-requests/mine` nor `/projects/mine` —
/// so for somebody joining their **first** project, which is the case that
/// matters most, there is no loop to piggyback on at all.

abstract class _$JoinRequestWatcher extends $Notifier<JoinWatch> {
  JoinWatch build();
  @$mustCallSuper
  @override
  WhenComplete runBuild() {
    final ref = this.ref as $Ref<JoinWatch, JoinWatch>;
    final element =
        ref.element
            as $ClassProviderElement<
              AnyNotifier<JoinWatch, JoinWatch>,
              JoinWatch,
              Object?,
              Object?
            >;
    return element.handleCreate(ref, build);
  }
}
