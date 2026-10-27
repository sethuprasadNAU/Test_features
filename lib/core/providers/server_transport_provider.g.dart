// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'server_transport_provider.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint, type=warning
/// **The one place this app builds a connection to its server** (task 11.97).
///
/// ## Why this file exists
///
/// Until this task there were three constructions of [HttpSyncTransport] —
/// the sync engine's, the membership surface's, and the join/publish
/// controller's — each assembling the same three inputs by hand.
/// `server_config_provider.dart` had already written down why that is a class
/// rather than three instances (the trailing-slash defect, which was fixed in
/// one constructor precisely so the other call sites could not repeat it).
/// This is the same argument applied one level up: a connection is built here
/// and nowhere else, so a test can substitute a failing server for **every**
/// path at once.
///
/// ## What that buys, which is the point rather than the tidiness
///
/// *Offline*, *records refused*, *records missing* and *you are no longer on
/// this project* are four states the sync bar draws and explains, and before
/// this seam existed no test could drive any of them through the app — the
/// engine's own tests drove the engine directly, and the bar's tests handed
/// the widget a hand-built status. Tasks 11.54 and 11.60 exist because two of
/// those states were wrong in ways only a person on real hardware found.
/// `test/core/providers/sync_bar_states_end_to_end_test.dart` is what this
/// file is for.
///
/// ## Null rather than thrown
///
/// Returns null when the app is not in a state to talk to a server at all —
/// no address, no TLS-enforcing client, no session. It does **not** report a
/// *refused* address, because a refusal's explanation does not survive
/// `ref.read(...future)` (measured in task 11.104: the caller gets a
/// `StateError` about a provider disposed mid-load, and the sentence naming
/// the fault is destroyed). That check belongs ahead of this provider, and
/// [requireServerTransport] is where it is written once.

@ProviderFor(serverTransport)
final serverTransportProvider = ServerTransportProvider._();

/// **The one place this app builds a connection to its server** (task 11.97).
///
/// ## Why this file exists
///
/// Until this task there were three constructions of [HttpSyncTransport] —
/// the sync engine's, the membership surface's, and the join/publish
/// controller's — each assembling the same three inputs by hand.
/// `server_config_provider.dart` had already written down why that is a class
/// rather than three instances (the trailing-slash defect, which was fixed in
/// one constructor precisely so the other call sites could not repeat it).
/// This is the same argument applied one level up: a connection is built here
/// and nowhere else, so a test can substitute a failing server for **every**
/// path at once.
///
/// ## What that buys, which is the point rather than the tidiness
///
/// *Offline*, *records refused*, *records missing* and *you are no longer on
/// this project* are four states the sync bar draws and explains, and before
/// this seam existed no test could drive any of them through the app — the
/// engine's own tests drove the engine directly, and the bar's tests handed
/// the widget a hand-built status. Tasks 11.54 and 11.60 exist because two of
/// those states were wrong in ways only a person on real hardware found.
/// `test/core/providers/sync_bar_states_end_to_end_test.dart` is what this
/// file is for.
///
/// ## Null rather than thrown
///
/// Returns null when the app is not in a state to talk to a server at all —
/// no address, no TLS-enforcing client, no session. It does **not** report a
/// *refused* address, because a refusal's explanation does not survive
/// `ref.read(...future)` (measured in task 11.104: the caller gets a
/// `StateError` about a provider disposed mid-load, and the sentence naming
/// the fault is destroyed). That check belongs ahead of this provider, and
/// [requireServerTransport] is where it is written once.

final class ServerTransportProvider
    extends
        $FunctionalProvider<
          AsyncValue<SyncTransport?>,
          SyncTransport?,
          FutureOr<SyncTransport?>
        >
    with $FutureModifier<SyncTransport?>, $FutureProvider<SyncTransport?> {
  /// **The one place this app builds a connection to its server** (task 11.97).
  ///
  /// ## Why this file exists
  ///
  /// Until this task there were three constructions of [HttpSyncTransport] —
  /// the sync engine's, the membership surface's, and the join/publish
  /// controller's — each assembling the same three inputs by hand.
  /// `server_config_provider.dart` had already written down why that is a class
  /// rather than three instances (the trailing-slash defect, which was fixed in
  /// one constructor precisely so the other call sites could not repeat it).
  /// This is the same argument applied one level up: a connection is built here
  /// and nowhere else, so a test can substitute a failing server for **every**
  /// path at once.
  ///
  /// ## What that buys, which is the point rather than the tidiness
  ///
  /// *Offline*, *records refused*, *records missing* and *you are no longer on
  /// this project* are four states the sync bar draws and explains, and before
  /// this seam existed no test could drive any of them through the app — the
  /// engine's own tests drove the engine directly, and the bar's tests handed
  /// the widget a hand-built status. Tasks 11.54 and 11.60 exist because two of
  /// those states were wrong in ways only a person on real hardware found.
  /// `test/core/providers/sync_bar_states_end_to_end_test.dart` is what this
  /// file is for.
  ///
  /// ## Null rather than thrown
  ///
  /// Returns null when the app is not in a state to talk to a server at all —
  /// no address, no TLS-enforcing client, no session. It does **not** report a
  /// *refused* address, because a refusal's explanation does not survive
  /// `ref.read(...future)` (measured in task 11.104: the caller gets a
  /// `StateError` about a provider disposed mid-load, and the sentence naming
  /// the fault is destroyed). That check belongs ahead of this provider, and
  /// [requireServerTransport] is where it is written once.
  ServerTransportProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'serverTransportProvider',
        isAutoDispose: false,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$serverTransportHash();

  @$internal
  @override
  $FutureProviderElement<SyncTransport?> $createElement(
    $ProviderPointer pointer,
  ) => $FutureProviderElement(pointer);

  @override
  FutureOr<SyncTransport?> create(Ref ref) {
    return serverTransport(ref);
  }
}

String _$serverTransportHash() => r'c817da87d63214c8740e8186d64e8f02fba04f00';

/// [NoServerReason] for this device, or null when a request could be made.
///
/// **Keeps the order [requireServerTransport] uses, and for the same reason:**
/// a refused address is checked before anything else, because from the outside
/// it looks identical to having no connection and the remedy is not remotely
/// the same.

@ProviderFor(noServerReason)
final noServerReasonProvider = NoServerReasonProvider._();

/// [NoServerReason] for this device, or null when a request could be made.
///
/// **Keeps the order [requireServerTransport] uses, and for the same reason:**
/// a refused address is checked before anything else, because from the outside
/// it looks identical to having no connection and the remedy is not remotely
/// the same.

final class NoServerReasonProvider
    extends
        $FunctionalProvider<
          AsyncValue<NoServerReason?>,
          NoServerReason?,
          FutureOr<NoServerReason?>
        >
    with $FutureModifier<NoServerReason?>, $FutureProvider<NoServerReason?> {
  /// [NoServerReason] for this device, or null when a request could be made.
  ///
  /// **Keeps the order [requireServerTransport] uses, and for the same reason:**
  /// a refused address is checked before anything else, because from the outside
  /// it looks identical to having no connection and the remedy is not remotely
  /// the same.
  NoServerReasonProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'noServerReasonProvider',
        isAutoDispose: false,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$noServerReasonHash();

  @$internal
  @override
  $FutureProviderElement<NoServerReason?> $createElement(
    $ProviderPointer pointer,
  ) => $FutureProviderElement(pointer);

  @override
  FutureOr<NoServerReason?> create(Ref ref) {
    return noServerReason(ref);
  }
}

String _$noServerReasonHash() => r'399fd27c4b07e65a8235f112931b40691b184f65';
