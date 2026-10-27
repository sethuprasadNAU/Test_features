import 'dart:io' show HttpClient, Platform;

import 'package:cupertino_http/cupertino_http.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart' show IOClient;
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../net/request_deadline.dart';
import 'server_config_provider.dart';

part 'server_http_client_provider.g.dart';

/// The single seam through which any future sync code (task 10.7/10.8) is
/// meant to obtain an HTTP client for talking to the server — never
/// `http.Client()` directly at a call site.
///
/// Resolves to `null` whenever [serverConfigProvider] is unconfigured, and
/// critically, an `http.Client` is never constructed on that path: the
/// constructor call below is unreachable unless [ServerConfig.isConfigured]
/// is true. This is what makes "zero network calls in the unconfigured
/// state" (task 10.2) an enforced invariant rather than a hope — sync code
/// that null-checks this provider's value can't accidentally reach the
/// network with no server configured, because there is no client to call
/// a method on.
///
/// **This is also where task 10.48 (F13) closes.** `validateServerUrl` used
/// to be the *only* place a cleartext base URL was ever rejected, and it was
/// wired to a single `TextFormField.validator` — a saved value, a migration,
/// or a future code path that wrote `baseUrl` directly all skipped it, and
/// every caller that later read the config trusted it unchecked.
/// [requireValidServerUrl] runs the same rule here instead, at the seam every
/// one of those callers already has to pass through to get a client at all,
/// so there is no longer a second way in.
///
/// **Every `ref.watch` before the first `await` (task 11.236).** Read bare —
/// `await ref.read(serverHttpClientProvider.future)` — by `CurrentSession
/// ._requireClient` (sign-in) and `SyncController._engine`, the same shape
/// [_ensureOwnerMembership] broke on: an auto-disposing provider whose body
/// `ref.watch`ed a second thing (`nonDebugBuildProvider`) after its first
/// `await`. Both watches are now issued synchronously up front.
@riverpod
Future<http.Client?> serverHttpClient(Ref ref) async {
  final configFuture = ref.watch(serverConfigProvider.future);
  final releaseMode = ref.watch(nonDebugBuildProvider);
  final config = await configFuture;
  if (!config.isConfigured) return null;
  requireValidServerUrl(config.baseUrl!, releaseMode: releaseMode);
  return createPlatformHttpClient();
}

/// Builds the client every request to a configured server goes out on.
///
/// On iOS and macOS this is [CupertinoClient], backed by `NSURLSession`
/// rather than the plain `http.Client()` this replaced, which opened sockets
/// directly through `dart:io` — invisibly to App Transport Security, since
/// ATS only ever inspects CFNetwork/`NSURLSession` traffic. That gap is what
/// §7.6/§8.5 of `TriTrack_Security_Model.md` flagged: `NSAllowsLocalNetworking`
/// in both platforms' `Info.plist` (task 5.1) looked like a compensating
/// control but, with no `NSURLSession`-backed client in the dependency tree,
/// had no traffic to apply to. Routing through [CupertinoClient] gives ATS
/// something to actually govern, so a cleartext connection to anything
/// **outside** what `NSAllowsLocalNetworking` permits is refused by the OS
/// itself — a second, independent enforcement point behind
/// [requireValidServerUrl] above, not a replacement for it.
///
/// Every other platform builds an [IOClient] over a `dart:io` [HttpClient].
///
/// **Both are given a deadline, and both are then wrapped** (task 11.61).
/// Until that task nothing this app sent could ever give up: a server that
/// accepted the connection and went quiet held the control that started the
/// request for sixty seconds on an iPhone — Apple's default, the only thing
/// ending it — and *forever* on Android, Windows and Linux, which have no such
/// default. See `core/net/request_deadline.dart` for the numbers, what a
/// person waits end to end, and why a screen timer would have been the wrong
/// answer.
///
/// **What each platform can enforce for itself is set natively here, so that a
/// deadline reached genuinely cancels rather than merely being reported:**
///
/// - iOS and macOS get `timeoutIntervalForRequest`, which Apple documents as
///   the interval to wait *for additional data*, reset whenever more arrives.
///   That is a true inactivity deadline and it covers the upload half as well
///   as the download half. Setting it to [kQuietDeadline] keeps the behaviour
///   an iPhone already had and makes it a declared choice.
/// - Everywhere else gets [HttpClient.connectionTimeout], which bounds opening
///   the socket. `dart:io` has nothing that bounds a connection that opens and
///   then stops delivering — `idleTimeout` is about pooled keep-alive sockets,
///   not this — so the rest is enforced in Dart by [withRequestDeadlines].
http.Client createPlatformHttpClient() =>
    withRequestDeadlines(_platformHttpClient());

http.Client _platformHttpClient() {
  if (Platform.isIOS || Platform.isMacOS) {
    final configuration = URLSessionConfiguration.defaultSessionConfiguration()
      ..timeoutIntervalForRequest = kQuietDeadline;
    return CupertinoClient.fromSessionConfiguration(configuration);
  }
  return IOClient(HttpClient()..connectionTimeout = kConnectDeadline);
}
