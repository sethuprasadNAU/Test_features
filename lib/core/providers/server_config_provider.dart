import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

import '../net/central_server.dart';

part 'server_config_provider.g.dart';

/// The app's one piece of server configuration: a base URL, or none.
///
/// "Not configured" (`baseUrl == null`) is the default and a fully supported,
/// first-class mode (task 10.2) — not a degraded or error state. Every
/// existing feature (recording, mapping, position estimation, backup/export)
/// works identically whether or not this is ever set; nothing added by this
/// phase may make any of that read path depend on a server being reachable.
class ServerConfig {
  /// Normalises on the way in, so **there is no such thing as a
  /// [ServerConfig] holding a non-canonical address** — see
  /// [normalizeServerBaseUrl] for what that means and why it is enforced here
  /// rather than at any call site.
  ServerConfig({String? baseUrl})
    : baseUrl = _canonicalOrNull(baseUrl);

  /// The unconfigured state, `const` so it stays usable where a constant is
  /// wanted. There is nothing to normalise.
  const ServerConfig.unconfigured() : baseUrl = null;

  static String? _canonicalOrNull(String? raw) {
    if (raw == null) return null;
    final canonical = normalizeServerBaseUrl(raw);
    return canonical.isEmpty ? null : canonical;
  }

  /// Canonical, non-empty absolute `http`/`https` URL, or null if
  /// unconfigured. Never a compile-time constant — always what the user last
  /// typed into [ServerConfigScreen], so switching between a laptop IP, a
  /// staging box, and eventually a production server is typing, not
  /// rebuilding.
  final String? baseUrl;

  bool get isConfigured => baseUrl != null;

  ServerConfig copyWith({String? baseUrl}) =>
      ServerConfig(baseUrl: baseUrl ?? this.baseUrl);
}

/// Puts a typed server address into the one form every caller can safely
/// append a path to: no trailing slash, no query, no fragment.
///
/// **Task 11.37, item 1 — and the reason it lives here and not at a call
/// site.** A saved address of `http://192.168.0.136:8080/` became
/// `http://192.168.0.136:8080//auth/magic-link`, the server answered `404`,
/// and the app reported it as a network failure. That was reproduced by hand
/// on 2026-08-26 and cost the first hour of the two-device walkthrough.
///
/// The tempting fix is to trim the slash where the sign-in URL is built. That
/// would be fixing the instance: at the time, **five call sites read
/// [ServerConfig.baseUrl] and append to it** — `AuthClient` (every auth
/// route) and four constructions of `HttpSyncTransport` (sync, project
/// publish/join, membership) — so repairing the one that happened to be hit
/// leaves the rest to be found the same way, one field session at a time.
/// **Task 11.97 took that argument one level up**: those four are now one, in
/// `server_transport_provider.dart`, so today there are two readers rather
/// than five. The reasoning below is unchanged by that and is why it did not
/// have to wait for it.
/// Normalising in [ServerConfig]'s constructor means every one of those five
/// receives a value that was already canonical, and a sixth added later
/// inherits it without knowing this function exists.
///
/// **It also has to run on read, not only on save**, which is the other half
/// of "the class". Michael's device already has the trailing slash in
/// `SharedPreferences`; normalising only in [ServerConfigNotifier.setUrl]
/// would leave every device that saved a bad value before this change broken
/// until somebody re-typed the field. Because the constructor is where it
/// happens, the value loaded in `build()` is normalised too, and the next
/// save writes the canonical form back.
///
/// Query and fragment are dropped rather than preserved: a base URL is a
/// prefix that paths are appended to, and `http://host/?debug=1` yields
/// `http://host/?debug=1/auth/magic-link` — a broken request that would
/// arrive as exactly the same misleading 404. Nothing about this field's
/// purpose gives either component a meaning, so carrying them along would
/// only preserve a way to fail.
///
/// A value this cannot parse is handed back trimmed and slash-stripped rather
/// than repaired or rejected. Refusing here would throw from a constructor
/// during a settings read; `validateServerUrl` and `requireValidServerUrl`
/// are the two places that say no, and they still get their say.
String normalizeServerBaseUrl(String raw) {
  final trimmed = raw.trim();
  if (trimmed.isEmpty) return '';
  final uri = Uri.tryParse(trimmed);
  // Deliberately **not** `uri.isAbsolute`, which this first used and which a
  // test caught: `Uri.isAbsolute` is false whenever a fragment is present, so
  // `http://host:8080/#top` — one of the exact shapes this function exists to
  // flatten — skipped normalisation and was handed straight back.
  if (uri == null || !uri.hasScheme || !uri.hasAuthority) {
    return _withoutTrailingSlashes(trimmed);
  }
  return '${uri.scheme}://${uri.authority}${_withoutTrailingSlashes(uri.path)}';
}

String _withoutTrailingSlashes(String value) {
  var end = value.length;
  while (end > 0 && value.codeUnitAt(end - 1) == 0x2F) {
    end--;
  }
  return value.substring(0, end);
}

/// The address this app ships with, [centralServerBaseUrl] (task 11.324,
/// item 4) — a provider only so a test can substitute a real-looking address
/// while the constant is still empty. Nothing in the app overrides it.
@Riverpod(keepAlive: true)
String centralServerAddress(Ref ref) => centralServerBaseUrl;

@Riverpod(keepAlive: true)
class ServerConfigNotifier extends _$ServerConfigNotifier {
  static const _prefsKey = 'server_base_url_v1';
  final _prefs = SharedPreferencesAsync();

  /// **Three stored states, since task 11.324.** No value: this device has
  /// never chosen, so it uses the central server the app ships with. An empty
  /// string: somebody cleared the field to work offline, and that choice
  /// survives a restart rather than the central address coming back by
  /// itself. Any other value: an address somebody typed (for testing).
  @override
  Future<ServerConfig> build() async {
    // Read before the `await`, never after it (task 11.236's hazard).
    final central = ref.watch(centralServerAddressProvider);
    final stored = await _prefs.getString(_prefsKey);
    // `ServerConfig` normalises, so a value saved by an older build — a
    // trailing slash typed before task 11.37 — is canonical from the first
    // read, without waiting for the field to be re-saved.
    return ServerConfig(baseUrl: stored ?? central);
  }

  /// Sets the configured server URL. [url] must already be validated (see
  /// `validateServerUrl`) — an empty/whitespace-only value is treated as
  /// [clear], since that's the natural way a text field represents "none".
  ///
  /// **Saving the central address stores nothing** (task 11.324): the device
  /// goes back to following the address the app ships with, so a later build
  /// that moves the central server carries this device along instead of
  /// leaving it on a frozen copy.
  Future<void> setUrl(String url) async {
    // Wait for the initial `build()` read to land first — otherwise, if a
    // caller mutates before that read resolves, its completion can overwrite
    // this call's state right after we set it (a real AsyncNotifier race, not
    // hypothetical). Callers that `watch`/`read` the provider before calling
    // this — every real one — already pay this cost implicitly.
    await future;
    final config = ServerConfig(baseUrl: url);
    // Also covers a value that is *only* punctuation — `///` normalises to
    // nothing, and storing an empty string as "configured" would be a server
    // that exists and cannot be reached.
    if (!config.isConfigured) return clear();
    state = AsyncData(config);
    if (config.baseUrl == ServerConfig(baseUrl: _central).baseUrl) {
      await _prefs.remove(_prefsKey);
      return;
    }
    // The canonical form is what gets persisted, so the stored value and the
    // value every caller uses are the same string.
    await _prefs.setString(_prefsKey, config.baseUrl!);
  }

  String get _central => ref.read(centralServerAddressProvider);

  /// Returns to the unconfigured (fully supported, offline) state, and keeps
  /// it there: an empty string is stored rather than the key removed, because
  /// a removed key now means "use the central server" (task 11.324).
  Future<void> clear() async {
    await future;
    state = const AsyncData(ServerConfig.unconfigured());
    await _prefs.setString(_prefsKey, '');
  }
}

/// **Why one address can be refused for five different reasons, and why each
/// gets its own sentence** (task 11.104, item 2).
///
/// Until this, three unrelated faults — text this app cannot parse at all, an
/// address with no `http://` in front of it, and an address asking for a
/// protocol this app does not speak — shared one message: *"Enter a full URL
/// starting with http:// or https://"*. That sentence is right for exactly
/// one of the three. For the other two it names the wrong thing to change,
/// which is the same defect, in miniature, as telling somebody their network
/// is down when this build has refused their address.
enum ServerUrlFault {
  /// Text this app cannot read as an address at all — `http://[bad`, a stray
  /// space, half a paste.
  unreadable,

  /// A host, and no `https://` in front of it. **The commonest typo**, and the
  /// one the old shared message was written for: `192.168.1.42:8080` on its
  /// own does not say how to connect, and `Uri.tryParse` cannot read it at all
  /// (measured — a bare `host:port` returns null, not a scheme-less `Uri`), so
  /// it has to be recognised by the *absence* of a `scheme://` prefix rather
  /// than by anything the parser hands back.
  noScheme,

  /// A protocol this app does not speak — `ftp://`, `ws://`, or a typo in the
  /// part before `://` such as `htp://`. Nothing about the *host* is wrong,
  /// so "enter a full URL" sends somebody to retype the half that is correct.
  unsupportedScheme,

  /// Plain `http://`, refused because this is not a debug build (§4.1, task
  /// 10.57). **The one that had no way to reach a person at all** before task
  /// 11.104: the app refused, and every surface that could have said so blamed
  /// the network instead.
  cleartextInThisBuild,

  /// Plain `http://` to a host that is not on a private network — refused in
  /// *every* build, including debug (§4.1, task 10.22).
  cleartextToPublicHost,
}

/// A refused server address: which fault, and the sentence to show a person.
///
/// **The message is carried as a value, never only as a thrown exception**,
/// and that is the whole architecture of task 11.104's fix. `InvalidServerUrl`
/// has held exactly the right sentence since task 10.48 and no part of the app
/// ever displayed it, because the throw happens inside a provider and — as
/// measured on 2026-08-31 — `await ref.read(serverHttpClientProvider.future)`
/// does not deliver it: the caller gets a `StateError` about the provider
/// being disposed mid-load, and the sentence is destroyed rather than merely
/// wrapped. A refusal that has to survive a provider boundary as an exception
/// is a refusal that does not arrive. This one is read, as a value, from
/// [serverUrlRefusalProvider].
class ServerUrlProblem {
  const ServerUrlProblem(this.fault, this.message);

  final ServerUrlFault fault;

  /// Client-authored, and **it always ends with something to try.** A
  /// diagnosis a person cannot act on is not help — see task 11.104's brief.
  final String message;

  @override
  String toString() => 'ServerUrlProblem(${fault.name}): $message';
}

/// Anything that looks like somebody meant to give a scheme: `http://`,
/// `htp://`, `ftp://`. Used only to tell [ServerUrlFault.unreadable] from
/// [ServerUrlFault.noScheme] when `Uri.tryParse` refuses the whole string.
final RegExp _schemePrefix = RegExp(r'^[a-zA-Z][a-zA-Z0-9+.\-]*://');

/// **What is wrong with [value] as a server address, or null if nothing is.**
///
/// The single decision behind three callers that must never disagree: the
/// settings field's `validator:` ([validateServerUrl]), the transport seam
/// ([requireValidServerUrl]), and the screens that explain a saved address
/// this build will not use ([serverUrlRefusalProvider]).
///
/// An empty value is not a fault — it is how the field says "clear the
/// configuration and work offline", and rejecting it would trap somebody with
/// a server they cannot remove.
///
/// **In a release or profile build, `http://` is rejected outright** (task
/// 10.14, `TriTrack_Security_Model.md` §4.1). Session tokens are bearer tokens
/// worth exactly what the transport is worth, and the LAN-cleartext exemption
/// exists for a debug-build development workflow — not for anything a user
/// installs, and **not for an internal-distribution build either** (task
/// 10.57, finding I-8): profile is how TestFlight/ad-hoc builds ship, and is
/// exactly the shape a real user runs, just without the store review. This is
/// the client half of the same decision the server enforces by refusing to
/// bind a non-loopback interface without either TLS or an explicit
/// development opt-in.
///
/// **And in *any* build, `http://` to a non-private host is rejected** (task
/// 10.22). §4.1 permits cleartext only when the build is debug *and* the
/// target is loopback or a private range; Security Gate C (§7.3 B3) found
/// that both enforcement points — this one and the server's — had built only
/// the first half of that sentence, so a debug build would happily post a
/// session token to `http://tracker.example.edu`.
///
/// [releaseMode] defaults to `!kDebugMode`, **not** `kReleaseMode` (task 10.57,
/// I-8): §3.4 and §4.1 both say the exemption is for "a debug build", but the
/// code read `kReleaseMode` until this task, and profile is neither debug nor
/// release — so an internal-distribution build silently kept the LAN-cleartext
/// exemption meant only for a developer's own machine. `!kDebugMode` is true
/// in both release and profile, which is what "not debug" actually means. It
/// remains a parameter, not a bare constant read, so the enforcement itself is
/// testable: a test binary is never a release *or* profile build, so a check
/// reading either constant directly would be permanently unexercised — and
/// §4.1 is explicit that "a control with no failing-path test is decoration."
ServerUrlProblem? describeServerUrlProblem(
  String? value, {
  bool releaseMode = !kDebugMode,
}) {
  final trimmed = (value ?? '').trim();
  if (trimmed.isEmpty) return null;
  final uri = Uri.tryParse(trimmed);
  if (uri == null || !uri.hasScheme) {
    // A bare `192.168.1.42:8080` and a mangled `http://[bad` both arrive here
    // as a null parse. They are different mistakes with different fixes, and
    // whether the person tried to write a scheme at all is what separates
    // them.
    return _schemePrefix.hasMatch(trimmed)
        ? const ServerUrlProblem(ServerUrlFault.unreadable, _unreadableMessage)
        : const ServerUrlProblem(ServerUrlFault.noScheme, _noSchemeMessage);
  }
  if (uri.scheme != 'http' && uri.scheme != 'https') {
    return const ServerUrlProblem(
      ServerUrlFault.unsupportedScheme,
      _unsupportedSchemeMessage,
    );
  }
  // **`hasAuthority`, not `isAbsolute`** — the same correction
  // [normalizeServerBaseUrl] carries, for the same reason and found the same
  // way. `Uri.isAbsolute` is false whenever a fragment is present, so this
  // field used to reject `http://192.168.1.42:8080/#top`: an address
  // `ServerConfig` would have accepted and flattened without complaint. A
  // validator stricter than the thing it guards refuses work that would have
  // succeeded.
  if (!uri.hasAuthority) {
    return const ServerUrlProblem(
      ServerUrlFault.unreadable,
      _unreadableMessage,
    );
  }
  if (releaseMode && uri.scheme == 'http') {
    return const ServerUrlProblem(
      ServerUrlFault.cleartextInThisBuild,
      _cleartextInThisBuildMessage,
    );
  }
  if (uri.scheme == 'http' && !_isPrivateTarget(uri.host)) {
    return const ServerUrlProblem(
      ServerUrlFault.cleartextToPublicHost,
      _cleartextToPublicHostMessage,
    );
  }
  return null;
}

const String _unreadableMessage =
    'This app cannot read that as a server address. It should look like '
    'https://tracker.example.edu or https://192.168.1.42:8443 — check for a '
    'stray space, a missing character, or half a paste.';

const String _noSchemeMessage =
    'Put https:// in front of it, so 192.168.1.42:8080 becomes '
    'https://192.168.1.42:8080. (A debug build of the app also accepts '
    'http:// on your own network.)';

const String _unsupportedSchemeMessage =
    'The part before :// should be https://. Check for a typo like htp:// or '
    'ftp://. (A debug build of the app also accepts http:// on your own '
    'network.)';

/// **The sentence task 11.66 measured being thrown away**, now with the half
/// the brief said was missing.
///
/// Everything before "Use an https://" is the diagnosis, and task 11.104's
/// brief is explicit that a diagnosis on its own is not help. The two routes
/// after it are the only two that exist, and both are named in `README.md` §4
/// under "The trap, named rather than left for you to find" — so this sentence
/// and that section say the same thing, and neither invents a third option.
const String _cleartextInThisBuildMessage =
    'This build of the app will not connect over plain http://, which anyone '
    'on the network could read. Your network is fine; this device is '
    'refusing. Use an https:// address: put TLS in front of the server '
    '(docker-compose.tls.yml, see "TLS termination" in server/README.md; it '
    'needs a hostname and a certificate), or, for testing only, use a debug '
    'build ("flutter run"), which accepts http:// on your own network.';

// Worded around what the researcher is actually holding: a laptop IP from
// the README, or a real address that needs https. Naming both is the
// difference between a rejection they can act on and one they work around.
const String _cleartextToPublicHostMessage =
    'Plain http:// only works to a server on your own network — a LAN '
    'address like 192.168.1.42, or localhost. For anything else, use '
    'https://';

/// The settings field's `validator:`, as the `String?` a `TextFormField`
/// wants. [describeServerUrlProblem] is where the decision lives; this is the
/// shape Flutter asks for.
///
/// **This is a *validator*, not the enforcement point** — §7.6/§8.5 flagged
/// that gap (F13) because `setUrl` persists whatever it is given and nothing
/// re-checked it downstream. [requireValidServerUrl] runs the same rule again
/// at the seam every request actually passes through
/// (`serverHttpClientProvider`), and [serverUrlRefusalProvider] runs it a
/// third time for the screens, which is what stops a cleartext URL that
/// reached storage some other way — a migration, a restore, a device handed
/// over already configured — from being refused silently.
String? validateServerUrl(String? value, {bool releaseMode = !kDebugMode}) =>
    describeServerUrlProblem(value, releaseMode: releaseMode)?.message;

/// Thrown by [requireValidServerUrl] for a stored base URL that fails the
/// same rule the settings field applies.
///
/// **Do not rely on catching this to tell a person anything** — that is the
/// mistake task 11.104 exists to correct. It is thrown from inside
/// `serverHttpClientProvider`, and a caller doing
/// `await ref.read(serverHttpClientProvider.future)` — which is what
/// `SyncController._engine` and `CurrentSession._requireClient` both do — does
/// **not** receive this object. Measured on 2026-08-31: it receives a
/// `StateError` reading "the provider serverHttpClientProvider was disposed
/// during loading state, yet no value could be emitted", because the provider
/// is autoDispose and `ref.read(...future)` holds no listener across the await.
/// The message below is destroyed on that path, not merely wrapped.
///
/// It stays because it is the *enforcement*: it is what makes a cleartext URL
/// fail to produce a client at all. Use [serverUrlRefusalProvider] to tell
/// somebody why.
class InvalidServerUrl implements Exception {
  const InvalidServerUrl(this.problem);

  final ServerUrlProblem problem;

  ServerUrlFault get fault => problem.fault;

  String get message => problem.message;

  @override
  String toString() => 'InvalidServerUrl: $message';
}

/// Re-runs [describeServerUrlProblem]'s rule against [baseUrl] — which, unlike
/// that function's `value`, is assumed non-empty, since only a configured
/// [ServerConfig.baseUrl] is ever passed here — and throws [InvalidServerUrl]
/// instead of returning a problem.
///
/// This is the transport-enforcement half of task 10.48 (F13): the settings
/// field's `validator:` only ever ran on what the user was actively typing,
/// so a value that reached storage another way skipped the check entirely.
/// Calling this from `serverHttpClientProvider` — the one seam every request
/// is required to pass through (task 10.2) — means the check now runs again
/// at construction time, on the stored value, regardless of how it got there.
void requireValidServerUrl(String baseUrl, {bool releaseMode = !kDebugMode}) {
  final problem = describeServerUrlProblem(baseUrl, releaseMode: releaseMode);
  if (problem != null) throw InvalidServerUrl(problem);
}

/// Whether this is anything other than a debug build.
///
/// **A provider rather than a bare `!kDebugMode` read at each site**, so that
/// the behaviour a beta tester actually gets can be exercised in a test. A
/// test binary is neither release nor profile, so every check keyed on the
/// constant is permanently unexercised from inside `flutter test` — §4.1's
/// "a control with no failing-path test is decoration", one level up from the
/// `releaseMode:` parameter that already exists for the same reason. Overriding
/// this in a test is how `test/features/more/server_address_refused_test.dart`
/// puts the app into the state task 11.66 measured on a phone.
@Riverpod(keepAlive: true)
bool nonDebugBuild(Ref ref) => !kDebugMode;

/// **Why this device will not use the server address it has saved, or null.**
///
/// The one thing every surface reads to answer that question, so the sync bar,
/// the sync-status screen and the Server Connection screen cannot come to
/// disagree — which is precisely what task 11.66 measured them doing, three
/// ways, about one fact.
///
/// **Null does not mean "the server is reachable."** It means nothing about
/// this address disqualifies it before a request is made. Reachability is a
/// different question with a different answer, and conflating the two is the
/// defect, in the other direction.
///
/// Deliberately returns a value and never throws: see [InvalidServerUrl] for
/// what happens to an exception raised inside a provider on this project.
@Riverpod(keepAlive: true)
Future<ServerUrlProblem?> serverUrlRefusal(Ref ref) async {
  final config = await ref.watch(serverConfigProvider.future);
  final baseUrl = config.baseUrl;
  if (baseUrl == null) return null;
  return describeServerUrlProblem(
    baseUrl,
    releaseMode: ref.watch(nonDebugBuildProvider),
  );
}

/// Whether [host], as typed, is loopback or on a private network.
///
/// Literal addresses are answered exactly, by the same predicate the server
/// checks its own interfaces with, so the two halves of §4.1 cannot disagree.
/// Names get the narrow, honest answer in [isLocalNetworkHostname]: a form
/// validator cannot resolve DNS, and guessing generously is how the check would
/// come to mean nothing.
bool _isPrivateTarget(String host) {
  // `Uri.host` keeps IPv6 literals bracketed (`[fd00::1]`); InternetAddress
  // does not parse them that way.
  final literal = host.startsWith('[') && host.endsWith(']')
      ? host.substring(1, host.length - 1)
      : host;
  final address = InternetAddress.tryParse(literal);
  if (address != null) return isPrivateNetworkAddress(address.rawAddress);
  return isLocalNetworkHostname(host);
}
