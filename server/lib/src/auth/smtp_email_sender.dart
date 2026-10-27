/// Sign-in link delivery over SMTP (task 11.287).
///
/// **Why this file exists.** `resolveEmailSender` returned `NullEmailSender`
/// whenever `TRITRACK_ENV=production`, and `NullEmailSender.sendMagicLink` is
/// an empty method. A production deployment accepted `POST /auth/magic-link`,
/// answered `202`, wrote the token, and delivered nothing — and the `202` was
/// *correct*, because §4.5 requires an identical response whether or not
/// delivery worked. The account-enumeration defense was hiding a total outage.
///
/// **Why a client of our own rather than a package.** Security Model §3.8:
/// exact pins, and *"whatever sends email (handles magic-link tokens)"* gets
/// scrutiny beyond the rest, because it sits directly on asset 3. The
/// established Dart SMTP package pulls nine direct dependencies (an
/// internationalization library, Unicode normalization, punycode, MIME, path,
/// logging, …) into a process that holds every magic-link token — for a
/// message that has one recipient, no attachment, a fixed body and needs
/// four commands. The protocol subset here is RFC 5321 (SMTP), RFC 3207
/// (STARTTLS) and RFC 4954 (AUTH PLAIN / LOGIN), and every byte written to
/// the wire is in this file where it can be read.
///
/// **The whole security surface of this feature is one rule**, carried over
/// from `EmailSender`'s contract: nothing a caller supplied reaches the
/// message except the address, and the address is checked here — again,
/// independently of `auth_routes.dart`'s boundary check — before it is
/// written into `RCPT TO` or a `To:` header. See [isDeliverableAddress].
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import '../security/placeholder_secrets.dart';
import '../security/security_config.dart';
import 'email_sender.dart';

/// How the connection to the relay is protected.
enum SmtpTlsMode {
  /// Connect in cleartext and upgrade with `STARTTLS` before anything else is
  /// said — the submission convention on port 587. **Required**, not
  /// opportunistic: a relay that does not offer `STARTTLS` gets no
  /// credentials and no message.
  starttls,

  /// TLS from the first byte — the SMTPS convention on port 465.
  implicit,

  /// Cleartext throughout. Refused in production, and refused alongside
  /// credentials in any environment: a password on an unencrypted hop is a
  /// password on the network.
  none,
}

/// The relay, resolved from the environment.
///
/// **Relay-agnostic on purpose.** NAU has not said which relay it will
/// provide, and a generic SMTP client does not care: the same six variables
/// point it at a campus relay, a commercial sending service, or a throwaway
/// catcher on a laptop. There is no provider name anywhere in this file.
class SmtpConfig {
  const SmtpConfig({
    required this.host,
    required this.port,
    required this.tls,
    required this.from,
    this.username,
    this.password,
    this.caCertificatePath,
    this.timeout = const Duration(seconds: 30),
  });

  final String host;
  final int port;
  final SmtpTlsMode tls;

  /// The sending address, written verbatim into `MAIL FROM` and `From:`.
  final String from;

  /// Both or neither — see [fromEnvironment].
  final String? username;
  final String? password;

  /// Extra trusted root certificates, PEM. For a relay that presents a
  /// certificate from an institutional CA the system store does not know.
  /// There is deliberately no knob that skips verification.
  final String? caCertificatePath;

  /// Ceiling on a single connect, and on waiting for any one reply.
  final Duration timeout;

  bool get hasCredentials => username != null;

  /// Whether the environment names a relay at all. The presence gate
  /// `resolveEmailSender` reads before deciding which sender to build.
  static bool isConfigured(Map<String, String> environment) =>
      (environment['TRITRACK_SMTP_HOST'] ?? '').trim().isNotEmpty;

  /// Reads the relay from `TRITRACK_SMTP_*`, refusing anything half-set.
  ///
  /// Throws [StateError] naming the variable — **never its value** (§4.7 rule
  /// 5: SMTP credentials are on the never-log list, and a refusal message
  /// lands in every log that captured the startup output).
  factory SmtpConfig.fromEnvironment(Map<String, String> environment) {
    final isProduction = isProductionEnvironment(environment);
    String? read(String name) {
      final value = environment[name]?.trim();
      return value == null || value.isEmpty ? null : value;
    }

    final host = read('TRITRACK_SMTP_HOST');
    if (host == null) {
      throw StateError('TRITRACK_SMTP_HOST is not set.');
    }

    final tlsName = read('TRITRACK_SMTP_TLS') ?? 'starttls';
    final tls = switch (tlsName.toLowerCase()) {
      'starttls' => SmtpTlsMode.starttls,
      'implicit' || 'tls' || 'smtps' => SmtpTlsMode.implicit,
      'none' => SmtpTlsMode.none,
      _ => throw StateError(
        'TRITRACK_SMTP_TLS must be one of starttls, implicit or none.',
      ),
    };
    if (tls == SmtpTlsMode.none && isProduction) {
      // Same posture as the cleartext-LAN refusal in security_config.dart: a
      // sign-in link is a credential, and the first hop to the relay is the
      // one hop this deployment controls.
      throw StateError(
        'TRITRACK_SMTP_TLS=none is set but TRITRACK_ENV=production. A sign-in '
        'link is a live credential; sending it to the relay in cleartext is '
        'a development-only affordance. Use starttls (port 587) or implicit '
        '(port 465).',
      );
    }

    final portText = read('TRITRACK_SMTP_PORT');
    final int port;
    if (portText == null) {
      port = switch (tls) {
        SmtpTlsMode.starttls => 587,
        SmtpTlsMode.implicit => 465,
        SmtpTlsMode.none => 25,
      };
    } else {
      final parsed = int.tryParse(portText);
      if (parsed == null || parsed < 1 || parsed > 65535) {
        throw StateError('TRITRACK_SMTP_PORT must be a port number (1–65535).');
      }
      port = parsed;
    }

    final username = read('TRITRACK_SMTP_USERNAME');
    final password = read('TRITRACK_SMTP_PASSWORD');
    if ((username == null) != (password == null)) {
      throw StateError(
        'SMTP credentials are half-configured: set both '
        'TRITRACK_SMTP_USERNAME and TRITRACK_SMTP_PASSWORD, or neither.',
      );
    }
    if (password != null && isPlaceholderSecret(password)) {
      throw StateError(
        'TRITRACK_SMTP_PASSWORD is a known placeholder rather than a real '
        'credential (Security Model §4.6).',
      );
    }
    if (username != null && tls == SmtpTlsMode.none) {
      throw StateError(
        'TRITRACK_SMTP_TLS=none cannot carry credentials: '
        'TRITRACK_SMTP_PASSWORD would cross the network in cleartext. Use '
        'starttls or implicit, or drop the credentials for a relay that does '
        'not need them.',
      );
    }

    final from = read('TRITRACK_SMTP_FROM');
    if (from == null) {
      throw StateError(
        'TRITRACK_SMTP_FROM is not set. It is the address sign-in links are '
        'sent from, and the relay decides whether it may send as that address.',
      );
    }
    if (!isDeliverableAddress(from)) {
      throw StateError(
        'TRITRACK_SMTP_FROM is not a plain address this sender can write into '
        'a MAIL FROM command (one @, ASCII, no brackets, spaces or control '
        'characters).',
      );
    }

    final caPath = read('TRITRACK_SMTP_CA_CERT_PATH');
    if (caPath != null && !File(caPath).existsSync()) {
      throw StateError(
        'TRITRACK_SMTP_CA_CERT_PATH names a file that does not exist.',
      );
    }

    return SmtpConfig(
      host: host,
      port: port,
      tls: tls,
      from: from,
      username: username,
      password: password,
      caCertificatePath: caPath,
    );
  }

  /// One line for the startup log. Host, port and mode — never the password.
  String describe() =>
      '$host:$port (${tls.name}'
      '${hasCredentials ? ', authenticated as configured' : ', no credentials'}'
      ') from $from';
}

/// Characters an address may contain before this sender will put it on the
/// wire: RFC 5322's unquoted local-part set, one `@`, and a hostname.
///
/// **This is the header-injection control, and it is deliberately narrower
/// than "valid email".** Quoted local parts (`"a b"@x`), domain literals
/// (`a@[10.0.0.1]`), non-ASCII (needs SMTPUTF8, which relays support
/// unevenly) and anything with `<`, `>`, `:`, a space or a control character
/// are refused. `auth_routes.dart` applies this same rule at the HTTP
/// boundary (task 11.298 — until then it applied a looser one, and the people
/// in the gap got a `202` and no mail); this check is still made here,
/// independently, so that a future route reaching `EmailSender` by another
/// path cannot turn `RCPT TO:<a@b.com>\r\nRCPT TO:<attacker@example.org>`
/// into two recipients. A refused address is a delivery failure — logged,
/// never delivered, and whatever answered the caller has already answered.
final RegExp _deliverableAddress = RegExp(
  r"^[A-Za-z0-9!#$%&'*+/=?^_`{|}~.-]{1,64}@[A-Za-z0-9](?:[A-Za-z0-9.-]{0,253}[A-Za-z0-9])?$",
);

/// Whether [address] is something this sender will write into `RCPT TO`,
/// `MAIL FROM` and a `To:`/`From:` header. See [_deliverableAddress].
bool isDeliverableAddress(String address) =>
    address.length <= 320 && _deliverableAddress.hasMatch(address);

/// A failure talking to the relay. The message names the step and quotes
/// the relay's reply with the recipient address redacted; it never contains
/// credentials, the message body, or the URL.
class SmtpException implements Exception {
  SmtpException(this.message);
  final String message;
  @override
  String toString() => 'SmtpException: $message';
}

/// Sends the sign-in link through the configured relay.
///
/// **Fire-and-forget, as the interface requires** (§4.5: *"enqueue the email
/// asynchronously so the response returns before delivery either way"*; a
/// synchronous send is on the section's *Violated by* list). The SMTP
/// conversation runs on its own future; [sendMagicLink] returns before the
/// socket is even open, so the HTTP response cannot vary in latency with
/// anything the relay does.
///
/// **A delivery failure reaches the operator and never the caller.** Same
/// shape `FileEmailSender` settled on after 2026-08-30, when a root-owned
/// directory meant no link was written and eleven gate instruments could only
/// report the symptom: the diagnosis goes to this container's log, where a
/// caller cannot see it, naming the relay and the step that failed — never
/// the token (§4.7 rule 1), never the URL (rule 4), never the credentials
/// (rule 5), and not the address either, so a run that fails for every
/// address in turn does not accumulate a list of them in the log.
///
/// **The log line alone was the whole story until task 11.293.** Because
/// delivery is detached, a refused link answered the same `202` as a
/// delivered one and recorded the same `outcome: 'sent'` in the audit table
/// — the one place `auth_routes.dart`'s own comment says operational
/// visibility lives. `sendMagicLink`'s `onOutcome` callback (called from
/// [_deliver], strictly after `sendMagicLink` has returned — and *only* that;
/// whether it lands before or after the route's own audit write is the
/// route's problem to order, and since task 11.298 it does) is how
/// `auth_routes.dart` learns to write a second audit row.
class SmtpEmailSender implements EmailSender {
  SmtpEmailSender({
    required this.config,
    SmtpClient? client,
    void Function(String line)? log,
    DateTime Function()? now,
    String? messageIdDomain,
  }) : _client = client ?? SmtpClient(config),
       _log = log ?? _print,
       _now = now ?? _utcNow,
       _messageIdDomain = messageIdDomain ?? _domainOf(config.from);

  final SmtpConfig config;
  final SmtpClient _client;
  final void Function(String line) _log;
  final DateTime Function() _now;
  final String _messageIdDomain;
  final _inFlight = <Future<void>>{};

  static DateTime _utcNow() => DateTime.now().toUtc();
  // ignore: avoid_print
  static void _print(String line) => print(line);
  static String _domainOf(String address) =>
      address.substring(address.indexOf('@') + 1);

  @override
  void sendMagicLink({
    required String email,
    required String url,
    required DateTime expiresAt,
    void Function(bool delivered)? onOutcome,
  }) {
    late final Future<void> delivery;
    // In a microtask, not called directly (task 11.298). An `async` function
    // runs synchronously up to its first `await`, and [_deliver]'s address
    // check sits before that `await` — so a refused address used to throw,
    // log and call [onOutcome] *inside this method*, in the request's own
    // frame, on the one path that never opens a socket. That broke the
    // interface's promise that the callback fires strictly after this method
    // has returned, and `auth_routes.dart` recorded the failure row ahead of
    // the request's own row because of it. Task 11.293's tests asserted the
    // promise on the two paths that reach an `await`; this is the third.
    delivery = Future.microtask(
      () => _deliver(
        email: email,
        url: url,
        expiresAt: expiresAt,
        onOutcome: onOutcome,
      ),
    ).whenComplete(() => _inFlight.remove(delivery));
    _inFlight.add(delivery);
  }

  /// Completes when every send started so far has finished, succeeded or
  /// not. For tests, and for a shutdown that wants to let the last link out.
  Future<void> drain() => Future.wait(_inFlight.toList());

  Future<void> _deliver({
    required String email,
    required String url,
    required DateTime expiresAt,
    void Function(bool delivered)? onOutcome,
  }) async {
    try {
      if (!isDeliverableAddress(email)) {
        // Unreachable from `/auth/magic-link` since task 11.298: the boundary
        // applies this same rule and answers `400` (see
        // `isAcceptableSignInAddress`). Kept, and kept independent of the
        // boundary, for the route that does not exist yet — a second path to
        // `EmailSender` must meet the header-injection control here whether
        // or not it remembered to check.
        throw SmtpException(
          'the address is not one this sender will write into a mail header '
          '(it has a quoted local part, a bracketed domain, a non-ASCII '
          'character, or a control character) — refused before any '
          'connection was opened. /auth/magic-link refuses such an address '
          'with 400 before it gets here, so this line means some other path '
          'reached the sender without that check',
        );
      }
      final message = buildMagicLinkMessage(
        from: config.from,
        to: email,
        url: url,
        expiresAt: expiresAt,
        now: _now(),
        messageId: newMessageId(_messageIdDomain),
      );
      await _client.send(from: config.from, to: email, message: message);
      _log('[auth] magic link handed to relay ${config.host}:${config.port}');
      onOutcome?.call(true);
    } on Object catch (error) {
      final detail = switch (error) {
        SmtpException(:final message) => _redact(message, email),
        SocketException(:final message, :final osError) =>
          'the connection to the relay dropped: ${osError?.message ?? message}',
        TlsException(:final message) => 'TLS failed: $message',
        TimeoutException() =>
          'the relay did not answer within ${config.timeout.inSeconds}s',
        _ => '${error.runtimeType}',
      };
      _log(
        '[auth] MAGIC LINK NOT DELIVERED. Relay ${config.host}:${config.port} '
        '(${config.tls.name}): $detail. The sign-in request still answered '
        '202 — it must (Security Model §4.5) — so nothing outside this log '
        'will tell anybody the link never arrived. Check TRITRACK_SMTP_* in '
        '.env; the startup log line beginning "Sign-in email:" says what the '
        'relay answered when this server came up.',
      );
      onOutcome?.call(false);
    }
  }

  /// A relay's reply may echo the recipient — `550 5.1.1 sam@x: user
  /// unknown` is a common shape. The address is not on §4.7's never-log list, but the file
  /// sender's failure line deliberately omits it, and this one follows.
  static String _redact(String message, String email) => message.replaceAll(
    RegExp(RegExp.escape(email), caseSensitive: false),
    '<recipient>',
  );
}

/// Builds the message: RFC 5322 headers, a fixed plain-text body, the link.
///
/// **Nothing a caller supplied is here except [to]**, and [to] appears only
/// in the `To:` header after [isDeliverableAddress] has passed it. The body
/// does not repeat the address — the recipient knows it — so the only
/// caller-influenced bytes in the whole message are one header value that
/// cannot contain a line break.
///
/// Lines are `\r\n`-terminated as SMTP requires, and the caller of
/// [SmtpClient.send] dot-stuffs; this function does not.
String buildMagicLinkMessage({
  required String from,
  required String to,
  required String url,
  required DateTime expiresAt,
  required DateTime now,
  required String messageId,
}) {
  assert(isDeliverableAddress(to), 'checked by the caller');
  final expiry = expiresAt.toUtc();
  final lines = <String>[
    'From: TriTrack <$from>',
    'To: <$to>',
    'Subject: Your TriTrack sign-in link',
    'Date: ${formatRfc5322Date(now)}',
    'Message-ID: <$messageId>',
    'MIME-Version: 1.0',
    'Content-Type: text/plain; charset=us-ascii',
    'Content-Transfer-Encoding: 7bit',
    // RFC 3834: tells auto-responders (vacation replies, ticketing systems)
    // not to answer this, which is how a sign-in link ends up in a helpdesk
    // queue.
    'Auto-Submitted: auto-generated',
    '',
    'Open this link to sign in to TriTrack:',
    '',
    url,
    '',
    'It works once and expires at ${formatRfc5322Date(expiry)}, fifteen '
        'minutes after it was requested.',
    '',
    'If you did not ask for this, ignore it. Nobody can sign in as you '
        'without opening the link, and it will expire on its own.',
    '',
  ];
  final message = lines.join('\r\n');
  for (final unit in message.codeUnits) {
    if (unit > 0x7e || (unit < 0x20 && unit != 0x0d && unit != 0x0a)) {
      // The one way a non-ASCII byte gets here is TRITRACK_PUBLIC_URL, which
      // is configuration. 7bit is what the header above promises; sending
      // something else would be a lie the relay may reject or mangle.
      throw SmtpException(
        'the message is not 7-bit ASCII (check TRITRACK_PUBLIC_URL) — '
        'refused before any connection was opened',
      );
    }
  }
  return message;
}

/// The message `bin/server.dart --send-test-email` sends: same headers as a
/// sign-in link, a body that says what it is, and no link. For an operator
/// standing up a deployment, this is the difference between "the relay
/// accepted it" and "it arrived": the first is in the server's log, the
/// second is in an inbox, and the plan for task 11.287 is explicit that only
/// the second closes the task.
String buildTestMessage({
  required String from,
  required String to,
  required DateTime now,
  required String messageId,
  required String relay,
}) {
  assert(isDeliverableAddress(to), 'checked by the caller');
  final lines = <String>[
    'From: TriTrack <$from>',
    'To: <$to>',
    'Subject: TriTrack sign-in email test',
    'Date: ${formatRfc5322Date(now)}',
    'Message-ID: <$messageId>',
    'MIME-Version: 1.0',
    'Content-Type: text/plain; charset=us-ascii',
    'Content-Transfer-Encoding: 7bit',
    'Auto-Submitted: auto-generated',
    '',
    'This is a test message from a TriTrack server.',
    '',
    'An operator ran "server --send-test-email" to check that sign-in links',
    'can reach an inbox through the relay $relay.',
    '',
    'If you are reading it, they can. No link is included and there is',
    'nothing to do.',
    '',
  ];
  final message = lines.join('\r\n');
  for (final unit in message.codeUnits) {
    if (unit > 0x7e || (unit < 0x20 && unit != 0x0d && unit != 0x0a)) {
      throw SmtpException('the message is not 7-bit ASCII');
    }
  }
  return message;
}

/// A fresh, unguessable id for a `Message-ID` header.
String newMessageId(String domain) {
  final random = Random.secure();
  final bytes = Uint8List.fromList(
    List<int>.generate(16, (_) => random.nextInt(256)),
  );
  return '${base64Url.encode(bytes).replaceAll('=', '')}@$domain';
}

const _weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
const _months = [
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];

/// `Sat, 20 Sep 2026 15:04:05 +0000` — RFC 5322 §3.3, always in UTC.
String formatRfc5322Date(DateTime value) {
  final t = value.toUtc();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${_weekdays[t.weekday - 1]}, ${t.day} ${_months[t.month - 1]} '
      '${t.year} ${two(t.hour)}:${two(t.minute)}:${two(t.second)} +0000';
}

/// What a startup probe learned. See [SmtpClient.probe].
class SmtpProbeResult {
  const SmtpProbeResult({
    required this.greeting,
    required this.tlsEstablished,
    required this.authenticated,
    required this.extensions,
  });

  /// The relay's own name from its `220` banner — useful when a DNS name
  /// resolves to the wrong machine.
  final String greeting;
  final bool tlsEstablished;
  final bool authenticated;
  final List<String> extensions;
}

/// The minimal SMTP client: connect, EHLO, STARTTLS, AUTH, one message, QUIT.
class SmtpClient {
  SmtpClient(this.config, {String? clientName})
    : _clientName = clientName ?? _defaultClientName();

  final SmtpConfig config;
  final String _clientName;

  /// `EHLO` needs a hostname or an address literal; a container's hostname
  /// is a hex id, which is a valid label. Anything odd falls back to a name
  /// the strictest relay will accept.
  static String _defaultClientName() {
    final name = Platform.localHostname;
    return RegExp(r'^[A-Za-z0-9.-]+$').hasMatch(name) ? name : '[127.0.0.1]';
  }

  /// Delivers one message. Throws [SmtpException] on any refusal, and lets
  /// socket, TLS and timeout errors through unchanged.
  Future<void> send({
    required String from,
    required String to,
    required String message,
  }) async {
    if (!isDeliverableAddress(to) || !isDeliverableAddress(from)) {
      // Belt and braces: `SmtpEmailSender` checks first, but this method is
      // public and the rule is cheap to hold at every entry.
      throw SmtpException('refusing an address this client will not quote');
    }
    final session = await _open();
    try {
      await session.expect('MAIL FROM:<$from>', 250);
      await session.expect('RCPT TO:<$to>', 250, alsoOk: const {251});
      await session.expect('DATA', 354);
      session.writeRaw(_dotStuff(message));
      await session.expect('.', 250);
      await session.quit();
    } finally {
      await session.close();
    }
  }

  /// Everything [send] does up to the point of naming a recipient: connect,
  /// greet, negotiate TLS and authenticate, then `QUIT`. Run once at
  /// startup so a wrong host, a relay with no STARTTLS, or a bad password is
  /// in the log at `docker compose up` rather than discovered by the first
  /// person who cannot sign in.
  Future<SmtpProbeResult> probe() async {
    final session = await _open();
    try {
      await session.quit();
    } finally {
      await session.close();
    }
    return SmtpProbeResult(
      greeting: session.greeting,
      tlsEstablished: session.secured,
      authenticated: session.authenticated,
      extensions: session.extensions.keys.toList(),
    );
  }

  Future<_Session> _open() async {
    final context = _securityContext();
    final Socket socket;
    try {
      if (config.tls == SmtpTlsMode.implicit) {
        socket = await SecureSocket.connect(
          config.host,
          config.port,
          context: context,
          timeout: config.timeout,
        );
      } else {
        socket = await Socket.connect(
          config.host,
          config.port,
          timeout: config.timeout,
        );
      }
    } on SocketException catch (e) {
      // Named here, at the one place it means "could not connect", so that a
      // socket error later in the conversation is not reported as one.
      throw SmtpException(
        'could not connect: ${e.osError?.message ?? e.message}',
      );
    }
    final session = _Session(socket, config.timeout);
    session.secured = config.tls == SmtpTlsMode.implicit;
    try {
      final banner = await session.readReply();
      if (banner.code != 220) {
        throw SmtpException(
          'the relay refused the connection in its greeting: '
          '${banner.summary}',
        );
      }
      session.greeting = banner.lines.isEmpty ? '' : banner.lines.first;
      await session.ehlo(_clientName);

      if (config.tls == SmtpTlsMode.starttls) {
        if (!session.extensions.containsKey('STARTTLS')) {
          throw SmtpException(
            'the relay does not offer STARTTLS, and TRITRACK_SMTP_TLS is '
            'starttls — nothing was sent. If the relay only speaks TLS on '
            'port 465, set TRITRACK_SMTP_TLS=implicit',
          );
        }
        await session.expect('STARTTLS', 220);
        await session.upgrade(host: config.host, context: context);
        // RFC 3207 §4.2: the client MUST discard everything it learned about
        // the server before TLS and issue EHLO again.
        await session.ehlo(_clientName);
      }

      if (config.hasCredentials) {
        // Never before TLS. `none` with credentials was refused at config
        // time, and `starttls` has upgraded by now, so this holds by
        // construction — asserted rather than assumed because it is the line
        // that keeps the password off the wire.
        if (!session.secured) {
          throw SmtpException(
            'refusing to send credentials over a connection that is not TLS',
          );
        }
        await session.authenticate(config.username!, config.password!);
      }
      return session;
    } catch (_) {
      await session.close();
      rethrow;
    }
  }

  SecurityContext? _securityContext() {
    final path = config.caCertificatePath;
    if (path == null) return null;
    // `withTrustedRoots: true` keeps the system store, so an extra CA adds to
    // what is trusted rather than replacing it.
    return SecurityContext(withTrustedRoots: true)
      ..setTrustedCertificates(path);
  }

  /// RFC 5321 §4.5.2: a line beginning with `.` gets a second `.` so the
  /// relay does not read it as end-of-data. The terminator is sent separately
  /// by [send].
  static String _dotStuff(String message) {
    final buffer = StringBuffer();
    final body = message.endsWith('\r\n')
        ? message.substring(0, message.length - 2)
        : message;
    for (final line in body.split('\r\n')) {
      if (line.startsWith('.')) buffer.write('.');
      buffer
        ..write(line)
        ..write('\r\n');
    }
    return buffer.toString();
  }
}

/// One reply from the relay: the three-digit code and every line of text.
class _Reply {
  _Reply(this.code, this.lines);
  final int code;
  final List<String> lines;

  /// The reply as a person should see it in a log: code and first line,
  /// truncated so a hostile relay cannot fill the log with one answer.
  String get summary {
    final first = lines.isEmpty ? '' : lines.first;
    final clipped = first.length > 200 ? '${first.substring(0, 200)}…' : first;
    return '$code $clipped'.trim();
  }
}

/// An open connection with a line reader that survives the STARTTLS upgrade.
class _Session {
  _Session(this._socket, this._timeout) : _reader = _LineReader(_socket);

  Socket _socket;
  _LineReader _reader;
  final Duration _timeout;

  String greeting = '';
  bool secured = false;
  bool authenticated = false;

  /// EHLO keywords → parameters, e.g. `AUTH` → `PLAIN LOGIN`.
  Map<String, String> extensions = const {};

  /// Sends one command line and returns the reply.
  Future<_Reply> command(String line) async {
    _socket.write('$line\r\n');
    await _socket.flush();
    return readReply();
  }

  /// Sends a command and refuses anything but [code] (or [alsoOk]).
  Future<_Reply> expect(
    String line,
    int code, {
    Set<int> alsoOk = const {},
  }) async {
    final reply = await command(line);
    if (reply.code != code && !alsoOk.contains(reply.code)) {
      throw SmtpException(
        'the relay answered "${reply.summary}" to ${_describe(line)}',
      );
    }
    return reply;
  }

  /// Names a command for a log line without quoting anything sensitive —
  /// `AUTH` carries the credentials, so it is never echoed.
  static String _describe(String line) {
    final verb = line.split(' ').first.split(':').first;
    return verb == 'AUTH' ? 'AUTH' : line;
  }

  void writeRaw(String data) => _socket.write(data);

  Future<void> ehlo(String clientName) async {
    final reply = await expect('EHLO $clientName', 250);
    final parsed = <String, String>{};
    // First line is the relay's own name; the rest are keywords.
    for (final line in reply.lines.skip(1)) {
      final space = line.indexOf(' ');
      final keyword = (space == -1 ? line : line.substring(0, space))
          .toUpperCase();
      final params = space == -1 ? '' : line.substring(space + 1);
      parsed[keyword] = params;
    }
    extensions = parsed;
  }

  Future<void> upgrade({
    required String host,
    required SecurityContext? context,
  }) async {
    // Pause the reader's subscription first — the SDK says a subscription
    // that exists when `secure` runs stops receiving events, and pausing is
    // "in most cases the right thing to do".
    _reader.detach();
    _socket = await SecureSocket.secure(_socket, host: host, context: context);
    _reader = _LineReader(_socket);
    secured = true;
  }

  Future<void> authenticate(String username, String password) async {
    final offered = (extensions['AUTH'] ?? '').toUpperCase().split(' ');
    final _Reply reply;
    if (offered.contains('PLAIN') || !offered.contains('LOGIN')) {
      // RFC 4616: one line, initial response inline. PLAIN when offered;
      // also PLAIN when nothing is offered, because some relays advertise
      // AUTH only after TLS and some not at all, and a 5xx reply is a
      // clearer diagnosis than "no mechanism".
      final initial = base64.encode(
        utf8.encode('\u0000$username\u0000$password'),
      );
      reply = await command('AUTH PLAIN $initial');
    } else {
      // RFC 4954's LOGIN: two challenges, both base64.
      var step = await command('AUTH LOGIN');
      if (step.code != 334) {
        throw SmtpException('the relay refused AUTH LOGIN: ${step.summary}');
      }
      step = await command(base64.encode(utf8.encode(username)));
      if (step.code != 334) {
        throw SmtpException('the relay refused the username: ${step.summary}');
      }
      reply = await command(base64.encode(utf8.encode(password)));
    }
    if (reply.code != 235) {
      throw SmtpException(
        'the relay rejected the credentials: ${reply.summary}. Check '
        'TRITRACK_SMTP_USERNAME and TRITRACK_SMTP_PASSWORD',
      );
    }
    authenticated = true;
  }

  Future<void> quit() async {
    try {
      await command('QUIT');
    } on Object {
      // The message is already accepted by the time this is sent; a relay
      // that hangs up without a 221 has not undone that.
    }
  }

  /// Reads one full reply, following `250-` continuation lines to the
  /// `250 ` terminator.
  Future<_Reply> readReply() async {
    final lines = <String>[];
    int? code;
    while (true) {
      final line = await _reader.readLine(_timeout);
      if (line.length < 3 || int.tryParse(line.substring(0, 3)) == null) {
        throw SmtpException('the relay sent a line that is not SMTP: "$line"');
      }
      final thisCode = int.parse(line.substring(0, 3));
      code ??= thisCode;
      if (thisCode != code) {
        throw SmtpException('the relay changed reply code mid-reply');
      }
      lines.add(line.length > 4 ? line.substring(4) : '');
      final separator = line.length > 3 ? line[3] : ' ';
      if (separator != '-') return _Reply(code, lines);
    }
  }

  Future<void> close() async {
    _reader.detach();
    try {
      await _socket.close();
    } on Object {
      // Closing is best-effort; the failure that matters was already raised.
    }
  }
}

/// Buffers a socket into CRLF-terminated lines on demand.
class _LineReader {
  _LineReader(Stream<Uint8List> stream) {
    _subscription = stream.listen(
      _onData,
      onError: _onError,
      onDone: _onDone,
      cancelOnError: true,
    );
  }

  /// Longest single reply line accepted before the relay is declared
  /// hostile. RFC 5321 allows 512 bytes; this is generous.
  static const int _maxLineBytes = 8 * 1024;

  late final StreamSubscription<Uint8List> _subscription;
  final _pending = <int>[];
  final _lines = <String>[];
  Completer<String>? _waiter;
  Object? _failure;
  bool _done = false;

  void _onData(Uint8List chunk) {
    _pending.addAll(chunk);
    var start = 0;
    for (var i = 1; i < _pending.length; i++) {
      if (_pending[i - 1] == 0x0d && _pending[i] == 0x0a) {
        _lines.add(
          ascii.decode(_pending.sublist(start, i - 1), allowInvalid: true),
        );
        start = i + 1;
      }
    }
    _pending.removeRange(0, start);
    if (_pending.length > _maxLineBytes) {
      _onError(SmtpException('the relay sent a reply line over 8 KiB'));
      return;
    }
    _deliver();
  }

  void _onError(Object error) {
    _failure = error;
    _deliver();
  }

  void _onDone() {
    _done = true;
    _deliver();
  }

  void _deliver() {
    final waiter = _waiter;
    if (waiter == null || waiter.isCompleted) return;
    if (_lines.isNotEmpty) {
      _waiter = null;
      waiter.complete(_lines.removeAt(0));
    } else if (_failure != null) {
      _waiter = null;
      waiter.completeError(_failure!);
    } else if (_done) {
      _waiter = null;
      waiter.completeError(
        SmtpException('the relay closed the connection mid-conversation'),
      );
    }
  }

  Future<String> readLine(Duration timeout) {
    if (_lines.isNotEmpty) return Future.value(_lines.removeAt(0));
    final completer = Completer<String>();
    _waiter = completer;
    _deliver();
    return completer.future.timeout(
      timeout,
      onTimeout: () {
        _waiter = null;
        throw TimeoutException('no reply from the relay', timeout);
      },
    );
  }

  /// Stops reading so the socket can be handed to TLS, or closed.
  void detach() {
    _subscription.pause();
  }
}
