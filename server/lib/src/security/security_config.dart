/// Transport security: what interface the server binds, and whether it serves
/// TLS (task 10.14, Security Model §4.1).
library;

import 'dart:io';

import 'package:tritrack_sync/tritrack_sync.dart';

/// Whether `TRITRACK_ENV` declares this a production deployment.
///
/// Normalised (trimmed, case-folded) rather than compared with `==`
/// (Security Model §16.3's M-11 sweep). Four sites in this server key a
/// production-only refusal off this variable — cleartext-LAN here,
/// disabling the per-source rate limit, and writing magic links to disk —
/// and every one of them used to compare with `== 'production'` exactly. A
/// value like `"Production"` or `"production "` is precisely what an
/// operator would type without a second thought, and each of those sites
/// took the *less* safe branch on the typo rather than refusing: the
/// refusal that exists specifically to catch "someone meant to lock this
/// down" never fired. `trusted_proxies.dart` does not use this helper
/// because its refusal is independently gated on reachability
/// (`DeploymentReach`), not solely on this variable.
bool isProductionEnvironment(Map<String, String> environment) =>
    (environment['TRITRACK_ENV'] ?? '').trim().toLowerCase() == 'production';

/// Which interface the server should listen on.
enum BindScope {
  /// Loopback only. The default with no configuration at all, and the only
  /// scope that is safe without TLS.
  loopback,

  /// All interfaces. Requires either TLS or an explicit cleartext-LAN opt-in.
  allInterfaces,
}

/// Resolved transport-security posture.
///
/// **§4.1's decision, as a decision table:** every listener on any interface
/// other than loopback serves TLS. Cleartext beyond loopback is permitted only
/// by explicit opt-in, is never permitted in production, is never permitted on
/// a publicly routable interface, and is never the default.
///
/// | TLS configured | `ALLOW_CLEARTEXT_LAN` | `TRITRACK_ENV` | Host interfaces | Result |
/// | --- | --- | --- | --- | --- |
/// | yes | — | any | any | all interfaces, TLS |
/// | no | yes | not production | all private | all interfaces, cleartext + warning |
/// | no | yes | not production | any public | **refuses to start** |
/// | no | yes | production | any | **refuses to start** |
/// | no | no | any | any | loopback only, cleartext |
///
/// The bottom row is why the default is safe: a server deployed with no
/// transport configuration at all is not reachable from another machine, so a
/// forgotten setting fails closed (§1.5) rather than publishing bearer tokens
/// to a shared network.
///
/// **Row three is task 10.22 (Gate C finding C-3).** §4.1 permits cleartext
/// only when the build is a development one *and* the target is loopback or a
/// private range; through 10.14 only the first half existed here, so
/// `TRITRACK_ALLOW_CLEARTEXT_LAN=1` on a VPS with a public address warned and
/// then served. See [assertExposureIsPrivate] — including what it cannot see.
class TransportSecurityConfig {
  const TransportSecurityConfig({
    required this.scope,
    required this.isProduction,
    required this.allowCleartextLan,
    this.tlsCertificatePath,
    this.tlsPrivateKeyPath,
  });

  final BindScope scope;
  final bool isProduction;

  /// Whether `TRITRACK_ALLOW_CLEARTEXT_LAN=1` was set. Only meaningful when
  /// TLS is not configured.
  final bool allowCleartextLan;

  final String? tlsCertificatePath;
  final String? tlsPrivateKeyPath;

  bool get tlsEnabled =>
      tlsCertificatePath != null && tlsPrivateKeyPath != null;

  /// True when this configuration serves cleartext to anything but loopback —
  /// the state that gets a startup warning on every boot, because a warning
  /// that only prints once is a warning nobody sees.
  bool get isCleartextBeyondLoopback =>
      scope == BindScope.allInterfaces && !tlsEnabled;

  InternetAddress get address => scope == BindScope.loopback
      ? InternetAddress.loopbackIPv4
      : InternetAddress.anyIPv4;

  /// Builds the `SecurityContext` for `shelf_io.serve`, or null for cleartext.
  SecurityContext? securityContext() {
    if (!tlsEnabled) return null;
    return SecurityContext()
      ..useCertificateChain(tlsCertificatePath!)
      ..usePrivateKey(tlsPrivateKeyPath!);
  }

  /// The entry point `bin/server.dart` uses: resolve the posture from the
  /// environment **and** check it against the interfaces this machine actually
  /// has, before anything binds a socket.
  ///
  /// [TransportSecurityConfig.fromEnvironment] is the configuration half and is
  /// public only because §4.1's decision table is tested as a pure decision.
  /// Calling it alone skips [assertExposureIsPrivate], which is exactly the
  /// omission finding C-3 was — so `startup_refusal_test.dart` asserts the real
  /// entry point calls this instead.
  static Future<TransportSecurityConfig> resolve({
    Map<String, String>? env,
    Future<List<NetworkInterface>> Function()? listInterfaces,
  }) async {
    final config = TransportSecurityConfig.fromEnvironment(env);
    await config.assertExposureIsPrivate(listInterfaces: listInterfaces);
    return config;
  }

  /// §4.1's second condition: cleartext beyond loopback is permitted only when
  /// every interface it would be served on is loopback or a private range.
  ///
  /// Throws [StateError] naming the offending interface and address. A warning
  /// was the old behaviour and is what finding C-3 was: the operator who set
  /// `TRITRACK_ALLOW_CLEARTEXT_LAN=1` to get their phone onto the dev server is
  /// the same operator who later runs the same configuration on a box with a
  /// public address, and a line of startup output has never stopped anyone.
  ///
  /// **What this cannot see, stated plainly because a control's blind spot
  /// belongs next to the control.** Inside a container every interface is the
  /// Docker bridge — private by construction — so this check passes on a public
  /// VPS and says nothing about how the host publishes the port. Confining that
  /// is `docker-compose.yml`'s job, and it defaults the publish address to
  /// loopback for exactly this reason. Recorded in §4.1 and §7.3 B3 rather than
  /// papered over here: this is a real gap in a real control, not a formality.
  Future<void> assertExposureIsPrivate({
    Future<List<NetworkInterface>> Function()? listInterfaces,
  }) async {
    if (!isCleartextBeyondLoopback) return;

    final interfaces = await (listInterfaces ?? _hostInterfaces)();
    final public = <String>[
      for (final interface in interfaces)
        for (final address in interface.addresses)
          if (!address.isLoopback &&
              !isPrivateNetworkAddress(address.rawAddress))
            '${interface.name} (${address.address})',
    ];
    if (public.isEmpty) return;

    throw StateError(
      'Refusing to serve cleartext HTTP on all interfaces: this machine has a '
      'publicly routable address — ${public.join(', ')}. '
      'TRITRACK_ALLOW_CLEARTEXT_LAN is for a laptop on a private network '
      'serving a phone on the same Wi-Fi; on a public address it publishes '
      'session tokens and observation coordinates to the internet '
      '(Security Model §4.1). Either configure TRITRACK_TLS_CERT_PATH and '
      'TRITRACK_TLS_KEY_PATH, or unset TRITRACK_ALLOW_CLEARTEXT_LAN and reach '
      'this server over an SSH tunnel to its loopback interface.',
    );
  }

  static Future<List<NetworkInterface>> _hostInterfaces() =>
      NetworkInterface.list(
        includeLoopback: false,
        type: InternetAddressType.any,
      );

  /// Reads the posture from the environment, refusing configurations §4.1
  /// forbids.
  ///
  /// Throws [StateError] rather than degrading when production and cleartext
  /// are both requested. Degrading quietly to loopback would be *safe* but
  /// invisible — the operator asked for LAN reachability and would spend an
  /// afternoon debugging why the phone cannot connect. Refusing to start names
  /// the contradiction immediately, which is the same posture
  /// `resolveEmailSender` already takes for the dev magic-link directory.
  factory TransportSecurityConfig.fromEnvironment([Map<String, String>? env]) {
    final environment = env ?? Platform.environment;
    final isProduction = isProductionEnvironment(environment);
    final allowCleartextLan =
        environment['TRITRACK_ALLOW_CLEARTEXT_LAN'] == '1';
    final certPath = _nonEmpty(environment['TRITRACK_TLS_CERT_PATH']);
    final keyPath = _nonEmpty(environment['TRITRACK_TLS_KEY_PATH']);

    if ((certPath == null) != (keyPath == null)) {
      // Half-configured TLS would otherwise fall through to the cleartext
      // branches, i.e. an operator who set up a certificate would silently get
      // plain HTTP — the exact "I thought it was encrypted" failure §4.1 exists
      // to prevent.
      throw StateError(
        'TLS is half-configured: set both TRITRACK_TLS_CERT_PATH and '
        'TRITRACK_TLS_KEY_PATH, or neither.',
      );
    }

    if (certPath != null && keyPath != null) {
      return TransportSecurityConfig(
        scope: BindScope.allInterfaces,
        isProduction: isProduction,
        allowCleartextLan: allowCleartextLan,
        tlsCertificatePath: certPath,
        tlsPrivateKeyPath: keyPath,
      );
    }

    if (allowCleartextLan) {
      if (isProduction) {
        throw StateError(
          'TRITRACK_ALLOW_CLEARTEXT_LAN=1 is set but TRITRACK_ENV=production. '
          'Serving session tokens in cleartext beyond loopback is a '
          'development-only affordance (Security Model §4.1). Configure TLS '
          'via TRITRACK_TLS_CERT_PATH and TRITRACK_TLS_KEY_PATH instead.',
        );
      }
      return TransportSecurityConfig(
        scope: BindScope.allInterfaces,
        isProduction: isProduction,
        allowCleartextLan: true,
      );
    }

    return TransportSecurityConfig(
      scope: BindScope.loopback,
      isProduction: isProduction,
      allowCleartextLan: false,
    );
  }

  /// The warning printed on every start when serving cleartext off-loopback.
  ///
  /// Every start, not once: §4.1 requires the flag "logs a prominent warning on
  /// every startup", and a container that restarts nightly would otherwise bury
  /// the one warning it ever printed.
  ///
  /// **Says "anyone who can reach this port", not "anyone on this network"**
  /// (task 10.22). Under `docker-compose.yml`'s corrected defaults the port is
  /// published to loopback, so the older wording was alarming and false — and a
  /// warning that overstates on every ordinary dev start is a warning people
  /// learn to scroll past, which costs exactly the boot where it is true.
  String get startupWarning =>
      '!!! Serving CLEARTEXT HTTP on every interface of this host. Session '
      'tokens and observation coordinates are readable by anyone who can reach '
      'this port — under Docker that is whoever the published address lets in '
      '(SERVER_PUBLISH_ADDRESS, 127.0.0.1 by default). Development only, on a '
      'private network — set TRITRACK_TLS_CERT_PATH/TRITRACK_TLS_KEY_PATH for '
      'any real deployment (Security Model §4.1).';

  static String? _nonEmpty(String? value) =>
      value == null || value.isEmpty ? null : value;
}
