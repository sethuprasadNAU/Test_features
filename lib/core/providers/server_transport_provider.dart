import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../data/sync/sync_transport.dart';
import 'auth_provider.dart';
import 'server_config_provider.dart';
import 'server_http_client_provider.dart';

part 'server_transport_provider.g.dart';

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
@Riverpod(keepAlive: true)
Future<SyncTransport?> serverTransport(Ref ref) async {
  final config = await ref.watch(serverConfigProvider.future);
  final http = await ref.watch(serverHttpClientProvider.future);
  final session = await ref.watch(currentSessionProvider.future);
  if (!config.isConfigured || http == null || session == null) return null;
  return HttpSyncTransport(
    httpClient: http,
    baseUrl: config.baseUrl!,
    sessionToken: session.token,
  );
}

/// **Why this device cannot reach a server at all**, as a value — task 11.142.
///
/// Null means nothing structural is in the way: there is an address this build
/// will use and a session to use it with, so a request would actually go out.
/// It says nothing about whether that request would *succeed*, and it must not
/// be read as if it did.
///
/// ## Why a value and not the thrown `not_configured`
///
/// Both halves of the Members screen that need a server threw the same bare
/// `SyncTransportException('not_configured')` whether this device had no
/// server address at all or had one and was signed out, and both landed in the
/// same `error:` branch as *the server did not answer*. Those are three
/// different situations with three different things to do about them, and a
/// screen cannot tell them apart from an exception that does not distinguish
/// them. **A device with no server is this app's default, fully supported
/// state** — task 10.2 built that seam on purpose — so "you have no
/// connection" is the wrong cause to give the person opening the app for the
/// first time. There is nothing wrong with their network; there is no server,
/// and there does not have to be one.
///
/// This is the same shape as [serverUrlRefusalProvider], for the same reason
/// task 11.104 gave: a refusal that travels as a value can be *read*, where one
/// that travels as a thrown exception is a state a screen has to guess at.
enum NoServerReason {
  /// No server address is saved. The app's default, and not a fault.
  noAddress,

  /// An address is saved and this build will not use it. See
  /// [serverUrlRefusalProvider] for which part of it is the problem.
  addressRefused,

  /// There is an address, but this device holds no session for it.
  notSignedIn,
}

/// [NoServerReason] for this device, or null when a request could be made.
///
/// **Keeps the order [requireServerTransport] uses, and for the same reason:**
/// a refused address is checked before anything else, because from the outside
/// it looks identical to having no connection and the remedy is not remotely
/// the same.
@Riverpod(keepAlive: true)
Future<NoServerReason?> noServerReason(Ref ref) async {
  if (await ref.watch(serverUrlRefusalProvider.future) != null) {
    return NoServerReason.addressRefused;
  }
  final config = await ref.watch(serverConfigProvider.future);
  if (!config.isConfigured) return NoServerReason.noAddress;
  if (await ref.watch(currentSessionProvider.future) == null) {
    return NoServerReason.notSignedIn;
  }
  return null;
}

/// [serverTransportProvider], with the two refusals every caller has to make
/// before it turned into named [SyncTransportException]s.
///
/// **The address check comes first, and the order is load-bearing** (task
/// 11.104). Building the http client is what enforces the https rule, but the
/// exception it throws is destroyed on the way out of the provider; asking
/// `serverUrlRefusalProvider` for the refusal *as a value* is what turns
/// "this build will not use the address you saved" into a reason the sync bar
/// and the join screens already know how to render, instead of a generic
/// breakage.
Future<SyncTransport> requireServerTransport(Ref ref) async {
  if (await ref.read(serverUrlRefusalProvider.future) != null) {
    throw const SyncTransportException(
      SyncTransportException.serverAddressRefused,
    );
  }
  final transport = await ref.read(serverTransportProvider.future);
  if (transport == null) throw const SyncTransportException('not_configured');
  return transport;
}
