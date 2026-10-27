// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'server_http_client_provider.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint, type=warning
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

@ProviderFor(serverHttpClient)
final serverHttpClientProvider = ServerHttpClientProvider._();

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

final class ServerHttpClientProvider
    extends
        $FunctionalProvider<
          AsyncValue<http.Client?>,
          http.Client?,
          FutureOr<http.Client?>
        >
    with $FutureModifier<http.Client?>, $FutureProvider<http.Client?> {
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
  ServerHttpClientProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'serverHttpClientProvider',
        isAutoDispose: true,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$serverHttpClientHash();

  @$internal
  @override
  $FutureProviderElement<http.Client?> $createElement(
    $ProviderPointer pointer,
  ) => $FutureProviderElement(pointer);

  @override
  FutureOr<http.Client?> create(Ref ref) {
    return serverHttpClient(ref);
  }
}

String _$serverHttpClientHash() => r'7600e2ea849ae485ba864b269480892d757d71ff';
