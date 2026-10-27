import 'dart:io';

import 'package:test/test.dart';
import 'package:tritrack_server/tritrack_server.dart';

import '../support/fake_smtp_server.dart';

/// Task 11.287. Until this task a production server resolved to
/// `NullEmailSender` and delivered nothing, correctly answering `202` every
/// time (§4.5). These tests hold the three things that replace it:
///
/// 1. a link reaches a relay, over TLS, authenticated, with nothing
///    caller-supplied in the message but the address;
/// 2. an address carrying a line break never reaches the wire — the header
///    injection the plan recorded as "harmless only because neither existing
///    sender sends anything";
/// 3. every way a relay can fail lands in the log as a sentence an operator
///    can act on, and none of them reaches the caller — `sendMagicLink`
///    returns before a socket is opened and never throws.
void main() {
  const goodPassword = 'k9Qm-2vXe-7pLr-4wZt';

  Map<String, String> env({
    Map<String, String> overrides = const {},
    Set<String> without = const {},
  }) {
    final base = {
      'TRITRACK_SMTP_HOST': 'relay.example.edu',
      'TRITRACK_SMTP_FROM': 'tritrack@example.edu',
    };
    base.addAll(overrides);
    for (final key in without) {
      base.remove(key);
    }
    return base;
  }

  Matcher refusesNaming(List<String> needles, {List<String> never = const []}) {
    return throwsA(
      isA<StateError>().having(
        (e) => e.message,
        'message',
        allOf([
          for (final n in needles) contains(n),
          for (final n in never) isNot(contains(n)),
        ]),
      ),
    );
  }

  group('SmtpConfig.fromEnvironment', () {
    test('the minimum is a host and a sending address, STARTTLS on 587', () {
      final config = SmtpConfig.fromEnvironment(env());
      expect(config.host, 'relay.example.edu');
      expect(config.port, 587);
      expect(config.tls, SmtpTlsMode.starttls);
      expect(config.hasCredentials, isFalse);
      expect(config.from, 'tritrack@example.edu');
    });

    test('the default port follows the TLS mode', () {
      expect(
        SmtpConfig.fromEnvironment(
          env(overrides: {'TRITRACK_SMTP_TLS': 'implicit'}),
        ).port,
        465,
      );
      expect(
        SmtpConfig.fromEnvironment(
          env(overrides: {'TRITRACK_SMTP_TLS': 'none'}),
        ).port,
        25,
      );
      expect(
        SmtpConfig.fromEnvironment(
          env(overrides: {'TRITRACK_SMTP_PORT': '2525'}),
        ).port,
        2525,
      );
    });

    test('a port that is not one is refused', () {
      for (final bad in ['0', '65536', 'smtp', '-1']) {
        expect(
          () => SmtpConfig.fromEnvironment(
            env(overrides: {'TRITRACK_SMTP_PORT': bad}),
          ),
          refusesNaming(['TRITRACK_SMTP_PORT']),
          reason: bad,
        );
      }
    });

    test('an unknown TLS mode is refused rather than guessed', () {
      expect(
        () => SmtpConfig.fromEnvironment(
          env(overrides: {'TRITRACK_SMTP_TLS': 'yes'}),
        ),
        refusesNaming(['TRITRACK_SMTP_TLS']),
      );
    });

    test('half-configured credentials are refused, either half', () {
      expect(
        () => SmtpConfig.fromEnvironment(
          env(overrides: {'TRITRACK_SMTP_USERNAME': 'tritrack'}),
        ),
        refusesNaming(['TRITRACK_SMTP_USERNAME', 'TRITRACK_SMTP_PASSWORD']),
      );
      expect(
        () => SmtpConfig.fromEnvironment(
          env(overrides: {'TRITRACK_SMTP_PASSWORD': goodPassword}),
        ),
        refusesNaming(['TRITRACK_SMTP_USERNAME', 'TRITRACK_SMTP_PASSWORD']),
      );
    });

    test('a placeholder password is refused and never echoed (§4.6, §4.7)', () {
      for (final placeholder in ['changeme', 'password', '1234', 'aaaaaaaa']) {
        expect(
          () => SmtpConfig.fromEnvironment(
            env(
              overrides: {
                'TRITRACK_SMTP_USERNAME': 'tritrack',
                'TRITRACK_SMTP_PASSWORD': placeholder,
              },
            ),
          ),
          refusesNaming(['TRITRACK_SMTP_PASSWORD'], never: [placeholder]),
          reason: placeholder,
        );
      }
    });

    test('cleartext in production is refused', () {
      expect(
        () => SmtpConfig.fromEnvironment(
          env(
            overrides: {
              'TRITRACK_SMTP_TLS': 'none',
              'TRITRACK_ENV': 'Production ',
            },
          ),
        ),
        refusesNaming(['TRITRACK_SMTP_TLS=none', 'TRITRACK_ENV=production']),
      );
    });

    test('cleartext with credentials is refused in any environment', () {
      expect(
        () => SmtpConfig.fromEnvironment(
          env(
            overrides: {
              'TRITRACK_SMTP_TLS': 'none',
              'TRITRACK_SMTP_USERNAME': 'tritrack',
              'TRITRACK_SMTP_PASSWORD': goodPassword,
            },
          ),
        ),
        refusesNaming(['TRITRACK_SMTP_TLS=none'], never: [goodPassword]),
      );
    });

    test('the sending address is required and must be deliverable', () {
      expect(
        () => SmtpConfig.fromEnvironment(env(without: {'TRITRACK_SMTP_FROM'})),
        refusesNaming(['TRITRACK_SMTP_FROM']),
      );
      expect(
        () => SmtpConfig.fromEnvironment(
          env(overrides: {'TRITRACK_SMTP_FROM': 'TriTrack <a@b.edu>'}),
        ),
        refusesNaming(['TRITRACK_SMTP_FROM']),
      );
    });

    test('a CA file that does not exist is refused', () {
      expect(
        () => SmtpConfig.fromEnvironment(
          env(overrides: {'TRITRACK_SMTP_CA_CERT_PATH': '/nonexistent.pem'}),
        ),
        refusesNaming(['TRITRACK_SMTP_CA_CERT_PATH']),
      );
    });

    test('describe() names the relay and never the password', () {
      final config = SmtpConfig.fromEnvironment(
        env(
          overrides: {
            'TRITRACK_SMTP_USERNAME': 'tritrack',
            'TRITRACK_SMTP_PASSWORD': goodPassword,
          },
        ),
      );
      expect(config.describe(), contains('relay.example.edu:587'));
      expect(config.describe(), isNot(contains(goodPassword)));
    });
  });

  group('resolveEmailSender (task 11.287)', () {
    test(
      'production with no relay REFUSES rather than dropping every link',
      () {
        // The defect this task exists for: the bottom-right cell of the table
        // in `resolveEmailSender`'s doc comment used to be `NullEmailSender`.
        expect(
          () => resolveEmailSender({'TRITRACK_ENV': 'production'}),
          refusesNaming(['TRITRACK_ENV=production', 'TRITRACK_SMTP_HOST']),
        );
      },
    );

    test('a relay resolves to the SMTP sender, in production too', () {
      expect(
        resolveEmailSender(env(overrides: {'TRITRACK_ENV': 'production'})),
        isA<SmtpEmailSender>(),
      );
      expect(resolveEmailSender(env()), isA<SmtpEmailSender>());
    });

    test('a relay and a dev directory together are refused', () {
      expect(
        () => resolveEmailSender(
          env(overrides: {'TRITRACK_DEV_MAGIC_LINK_DIR': '/tmp/links'}),
        ),
        refusesNaming(['TRITRACK_SMTP_HOST', 'TRITRACK_DEV_MAGIC_LINK_DIR']),
      );
    });

    test('a relay misconfiguration surfaces through resolve, by name', () {
      expect(
        () => resolveEmailSender(env(without: {'TRITRACK_SMTP_FROM'})),
        refusesNaming(['TRITRACK_SMTP_FROM']),
      );
    });
  });

  group('isDeliverableAddress — the header-injection control', () {
    test('accepts the addresses people actually have', () {
      for (final ok in [
        'sam@example.com',
        'first.last+tag@sub.example.edu',
        "o'neil@example.org",
        'a@b',
        'x_y-z@host-1.example',
      ]) {
        expect(isDeliverableAddress(ok), isTrue, reason: ok);
      }
    });

    test('refuses everything that could end a header or a RCPT line', () {
      for (final bad in [
        'a@b.com\r\nBcc: attacker@example.org', // plan line 3334's payload
        'a@b.com\nBcc: attacker@example.org',
        'a@b.com>\r\nRCPT TO:<attacker@example.org',
        'a@b.com>',
        '<a@b.com>',
        'a b@example.com',
        'a@b.com,c@d.com',
        'a@b.com;c@d.com',
        'a@b.com\u0000',
        '"quoted local"@example.com',
        'a@[10.0.0.1]',
        'ünïcode@example.com',
        'a@',
        '@b.com',
        'a@@b.com',
        'a@b.com@c.com',
        '',
      ]) {
        expect(isDeliverableAddress(bad), isFalse, reason: bad);
      }
    });

    test('is bounded', () {
      expect(isDeliverableAddress('${'a' * 64}@${'b' * 250}'), isTrue);
      expect(isDeliverableAddress('${'a' * 65}@b.com'), isFalse);
      expect(isDeliverableAddress('a@${'b' * 300}'), isFalse);
    });
  });

  group('buildMagicLinkMessage', () {
    final now = DateTime.utc(2026, 9, 20, 15, 4, 5);
    final expiresAt = now.add(const Duration(minutes: 15));
    String build({
      String to = 'sam@example.com',
      String url = 'https://tritrack.example.edu/auth/redeem?token=T0KEN',
    }) => buildMagicLinkMessage(
      from: 'tritrack@example.edu',
      to: to,
      url: url,
      expiresAt: expiresAt,
      now: now,
      messageId: 'abc@example.edu',
    );

    test('the address appears once, in To:, and nowhere in the body', () {
      final message = build();
      final headers = message.substring(0, message.indexOf('\r\n\r\n'));
      final body = message.substring(message.indexOf('\r\n\r\n') + 4);
      expect(headers, contains('To: <sam@example.com>'));
      expect('sam@example.com'.allMatches(message).length, 1);
      expect(body, isNot(contains('sam@example.com')));
    });

    test(
      'the link is in the body on its own line, and the headers are sane',
      () {
        final message = build();
        final lines = message.split('\r\n');
        expect(
          lines,
          contains('https://tritrack.example.edu/auth/redeem?token=T0KEN'),
        );
        expect(lines, contains('From: TriTrack <tritrack@example.edu>'));
        expect(lines, contains('Subject: Your TriTrack sign-in link'));
        expect(lines, contains('Date: Sun, 20 Sep 2026 15:04:05 +0000'));
        expect(lines, contains('Message-ID: <abc@example.edu>'));
        expect(lines, contains('Auto-Submitted: auto-generated'));
        expect(message, contains('expires at Sun, 20 Sep 2026 15:19:05 +0000'));
        // Bare LF anywhere would be a broken message on the wire.
        expect(message.replaceAll('\r\n', ''), isNot(contains('\n')));
      },
    );

    test(
      'a non-ASCII byte is refused before any connection (7bit promised)',
      () {
        expect(
          () => build(url: 'https://trïtrack.example.edu/auth/redeem?token=T'),
          throwsA(isA<SmtpException>()),
        );
      },
    );

    test('the date is RFC 5322 and always UTC', () {
      expect(
        formatRfc5322Date(DateTime(2026, 1, 1, 0, 0, 0).toUtc()),
        matches(
          RegExp(
            r'^[A-Z][a-z]{2}, \d{1,2} [A-Z][a-z]{2} \d{4} \d\d:\d\d:\d\d \+0000$',
          ),
        ),
      );
      expect(
        formatRfc5322Date(DateTime.utc(2026, 9, 20)),
        'Sun, 20 Sep 2026 00:00:00 +0000',
      );
    });
  });

  group('against a relay', () {
    late FakeSmtpServer relay;
    late Directory certDir;
    late String certPath;

    setUpAll(() {
      // A certificate for `localhost`, made fresh each run so nothing PEM-shaped
      // is ever committed (the committed-secrets check scans for that).
      certDir = Directory.systemTemp.createTempSync('tritrack-smtp-tls-');
      certPath = '${certDir.path}/cert.pem';
      final result = Process.runSync('openssl', [
        'req',
        '-x509',
        '-newkey',
        'rsa:2048',
        '-nodes',
        '-days',
        '1',
        '-subj',
        '/CN=localhost',
        '-addext',
        'subjectAltName=DNS:localhost,IP:127.0.0.1',
        // A self-signed certificate is only accepted as a trust anchor when it
        // says it is one — and macOS's verifier, which Dart uses there, also
        // wants the key usages spelled out. Measured on 2026-09-20: without
        // the three extensions below the handshake fails with
        // CERTIFICATE_VERIFY_FAILED on macOS even with the file trusted.
        '-addext',
        'basicConstraints=critical,CA:TRUE',
        '-addext',
        'keyUsage=critical,digitalSignature,keyEncipherment,keyCertSign',
        '-addext',
        'extendedKeyUsage=serverAuth',
        '-keyout',
        '${certDir.path}/key.pem',
        '-out',
        certPath,
      ]);
      if (result.exitCode != 0) {
        throw StateError(
          'openssl could not make a test certificate: ${result.stderr}',
        );
      }
    });
    tearDownAll(() => certDir.deleteSync(recursive: true));

    SecurityContext serverTls() => SecurityContext()
      ..useCertificateChain(certPath)
      ..usePrivateKey('${certDir.path}/key.pem');

    setUp(() async {
      relay = await FakeSmtpServer.start();
    });
    tearDown(() => relay.close());

    SmtpConfig config({
      SmtpTlsMode tls = SmtpTlsMode.none,
      String? username,
      String? password,
      int? port,
      Duration timeout = const Duration(seconds: 10),
    }) => SmtpConfig(
      host: 'localhost',
      port: port ?? relay.port,
      tls: tls,
      from: 'tritrack@example.edu',
      username: username,
      password: password,
      caCertificatePath: tls == SmtpTlsMode.none ? null : certPath,
      timeout: timeout,
    );

    const url = 'http://tritrack.example.edu/auth/redeem?token=SECRETTOKEN';
    final expiresAt = DateTime.utc(2026, 9, 20, 15, 19, 5);

    /// Runs one send to completion and returns what the sender logged.
    Future<List<String>> send(
      SmtpConfig config, {
      String email = 'sam@example.com',
    }) async {
      final printed = <String>[];
      final sender = SmtpEmailSender(
        config: config,
        log: printed.add,
        now: () => DateTime.utc(2026, 9, 20, 15, 4, 5),
      );
      sender.sendMagicLink(email: email, url: url, expiresAt: expiresAt);
      await sender.drain();
      return printed;
    }

    test(
      'delivers end to end in cleartext, envelope and body correct',
      () async {
        final printed = await send(config());

        expect(relay.received, hasLength(1));
        final message = relay.received.single;
        expect(message.mailFrom, 'tritrack@example.edu');
        expect(message.recipients, ['sam@example.com']);
        expect(message.overTls, isFalse);
        expect(message.headers['To'], '<sam@example.com>');
        expect(message.headers['From'], 'TriTrack <tritrack@example.edu>');
        expect(message.body.split('\r\n'), contains(url));
        // The success line names the relay, never the token or the address.
        expect(
          printed.join('\n'),
          contains('handed to relay localhost:${relay.port}'),
        );
        expect(printed.join('\n'), isNot(contains('SECRETTOKEN')));
        expect(printed.join('\n'), isNot(contains('sam@example.com')));
      },
    );

    test(
      'onOutcome(true) fires once the relay has accepted the message '
      '(task 11.293)',
      () async {
        final outcomes = <bool>[];
        final sender = SmtpEmailSender(config: config(), log: (_) {});
        sender.sendMagicLink(
          email: 'sam@example.com',
          url: url,
          expiresAt: expiresAt,
          onOutcome: outcomes.add,
        );
        // Fired from the detached future, not synchronously — the same
        // shape a caller must handle whether delivery succeeds or fails.
        expect(outcomes, isEmpty);
        await sender.drain();
        expect(outcomes, [true]);
      },
    );

    test(
      'STARTTLS then AUTH PLAIN: TLS is negotiated before a credential moves',
      () async {
        relay
          ..tlsContext = serverTls()
          ..authMechanisms = ['PLAIN', 'LOGIN']
          ..expectedUsername = 'tritrack'
          ..expectedPassword = goodPassword;

        final printed = await send(
          config(
            tls: SmtpTlsMode.starttls,
            username: 'tritrack',
            password: goodPassword,
          ),
        );

        expect(printed.join('\n'), contains('handed to relay'));
        expect(relay.received, hasLength(1));
        expect(relay.received.single.overTls, isTrue);
        expect(relay.received.single.authenticatedAs, 'tritrack');
        final starttlsAt = relay.transcript.indexOf('STARTTLS');
        final authAt = relay.transcript.indexWhere(
          (l) => l.startsWith('AUTH '),
        );
        expect(starttlsAt, greaterThanOrEqualTo(0));
        expect(
          authAt,
          greaterThan(starttlsAt),
          reason: 'AUTH must follow STARTTLS',
        );
        // RFC 3207: EHLO is repeated after the upgrade.
        expect(relay.transcript.where((l) => l.startsWith('EHLO ')).length, 2);
      },
    );

    test('implicit TLS on a TLS-from-the-first-byte listener', () async {
      // The fake relay listens in cleartext; an implicit-TLS listener is a
      // separate socket. Stand one up for this test only.
      final tlsListener = await SecureServerSocket.bind(
        InternetAddress.loopbackIPv4,
        0,
        serverTls(),
      );
      addTearDown(() => tlsListener.close());
      final accepted = <String>[];
      tlsListener.listen((socket) async {
        socket.write('220 implicit-relay ready\r\n');
        socket.listen((chunk) {
          final text = String.fromCharCodes(chunk);
          accepted.add(text);
          if (text.startsWith('EHLO')) {
            socket.write('250-implicit-relay\r\n250 8BITMIME\r\n');
          } else if (text.startsWith('QUIT')) {
            socket.write('221 bye\r\n');
            socket.close();
          }
        });
      });

      final result = await SmtpClient(
        config(tls: SmtpTlsMode.implicit, port: tlsListener.port),
      ).probe();
      expect(result.tlsEstablished, isTrue);
      expect(result.greeting, contains('implicit-relay'));
      expect(accepted.join(), contains('EHLO'));
    });

    test('AUTH LOGIN when that is all the relay offers', () async {
      relay
        ..tlsContext = serverTls()
        ..authMechanisms = ['LOGIN']
        ..expectedUsername = 'tritrack'
        ..expectedPassword = goodPassword;

      await send(
        config(
          tls: SmtpTlsMode.starttls,
          username: 'tritrack',
          password: goodPassword,
        ),
      );

      expect(relay.received.single.authenticatedAs, 'tritrack');
      expect(relay.transcript, contains('AUTH LOGIN'));
    });

    test(
      'dot-stuffing: a body line starting with "." survives the wire',
      () async {
        final message =
            'From: <tritrack@example.edu>\r\nTo: <sam@example.com>\r\n\r\n'
            '.hidden\r\n..twice\r\nplain\r\n';
        await SmtpClient(config()).send(
          from: 'tritrack@example.edu',
          to: 'sam@example.com',
          message: message,
        );
        expect(relay.received.single.body, '.hidden\r\n..twice\r\nplain');
        expect(relay.transcript, isNot(contains('.hidden')));
      },
    );

    test('the startup probe reports TLS and authentication', () async {
      relay
        ..tlsContext = serverTls()
        ..authMechanisms = ['PLAIN']
        ..expectedUsername = 'tritrack'
        ..expectedPassword = goodPassword;
      final result = await SmtpClient(
        config(
          tls: SmtpTlsMode.starttls,
          username: 'tritrack',
          password: goodPassword,
        ),
      ).probe();
      expect(result.tlsEstablished, isTrue);
      expect(result.authenticated, isTrue);
      expect(result.greeting, contains('fake-relay'));
      expect(relay.received, isEmpty, reason: 'a probe sends no message');
      expect(relay.transcript, isNot(contains('DATA')));
    });

    group('header injection', () {
      test('an address with a line break never reaches the wire', () async {
        final printed = await send(
          config(),
          email: 'a@b.com\r\nBcc: attacker@example.org',
        );
        expect(relay.transcript, isEmpty, reason: 'no connection at all');
        expect(relay.received, isEmpty);
        expect(printed.join('\n'), contains('NOT DELIVERED'));
        expect(printed.join('\n'), isNot(contains('attacker')));
      });

      test('SmtpClient.send holds the rule on its own', () async {
        expect(
          () => SmtpClient(config()).send(
            from: 'tritrack@example.edu',
            to: 'a@b.com>\r\nRCPT TO:<attacker@example.org',
            message: 'x\r\n',
          ),
          throwsA(isA<SmtpException>()),
        );
        expect(relay.transcript, isEmpty);
      });
    });

    group('a delivery failure reaches the log and not the caller', () {
      test(
        'sendMagicLink returns before the relay is touched and never throws',
        () {
          // This is the property that keeps the HTTP response identical (§4.5):
          // `auth_routes.dart` has already returned its 202 by the time any of
          // the failures below happen.
          final sender = SmtpEmailSender(
            config: config(port: 1), // nothing listens on port 1
            log: (_) {},
          );
          expect(
            () => sender.sendMagicLink(
              email: 'sam@example.com',
              url: url,
              expiresAt: expiresAt,
            ),
            returnsNormally,
          );
          expect(relay.transcript, isEmpty);
          addTearDown(sender.drain);
        },
      );

      test(
        'a refused recipient: code quoted, address redacted, token absent',
        () async {
          relay.rcptReplyCode = 550;
          final printed = await send(config());
          final output = printed.join('\n');
          expect(output, contains('MAGIC LINK NOT DELIVERED'));
          expect(output, contains('550'));
          expect(output, contains('<recipient>'));
          expect(output, isNot(contains('sam@example.com')));
          expect(output, isNot(contains('SECRETTOKEN')));
          expect(output, contains('answered 202'));
          expect(relay.received, isEmpty);
        },
      );

      test(
        'onOutcome(false) fires on a refused recipient — the gap task 11.293 '
        'closes: a refused delivery must not read as sent forever',
        () async {
          relay.rcptReplyCode = 550;
          final outcomes = <bool>[];
          final sender = SmtpEmailSender(config: config(), log: (_) {});
          sender.sendMagicLink(
            email: 'sam@example.com',
            url: url,
            expiresAt: expiresAt,
            onOutcome: outcomes.add,
          );
          expect(outcomes, isEmpty, reason: 'must not fire synchronously');
          await sender.drain();
          expect(outcomes, [false]);
        },
      );

      test(
        'onOutcome(false) does not fire synchronously on an address the '
        'sender refuses — the third path, the one 11.293 did not test '
        '(task 11.298)',
        () async {
          // The two tests above reach an `await` before they can fail; this
          // path used to throw before the first one, so the callback ran
          // inside `sendMagicLink` and the interface's "strictly after this
          // method has returned" was false on exactly one path.
          final outcomes = <bool>[];
          final sender = SmtpEmailSender(config: config(), log: (_) {});
          sender.sendMagicLink(
            email: 'üser@example.com',
            url: url,
            expiresAt: expiresAt,
            onOutcome: outcomes.add,
          );
          expect(outcomes, isEmpty, reason: 'must not fire synchronously');
          await sender.drain();
          expect(outcomes, [false]);
          expect(relay.transcript, isEmpty, reason: 'no connection at all');
        },
      );

      test(
        'wrong credentials: names the variables, never the password',
        () async {
          relay
            ..tlsContext = serverTls()
            ..authMechanisms = ['PLAIN']
            ..expectedUsername = 'tritrack'
            ..expectedPassword = 'something-else-entirely';
          final printed = await send(
            config(
              tls: SmtpTlsMode.starttls,
              username: 'tritrack',
              password: goodPassword,
            ),
          );
          final output = printed.join('\n');
          expect(output, contains('NOT DELIVERED'));
          expect(output, contains('TRITRACK_SMTP_PASSWORD'));
          expect(output, isNot(contains(goodPassword)));
          expect(relay.received, isEmpty);
        },
      );

      test(
        'a relay without STARTTLS gets nothing — not the credentials, not the mail',
        () async {
          relay
            ..tlsContext = null
            ..authMechanisms = ['PLAIN'];
          final printed = await send(
            config(
              tls: SmtpTlsMode.starttls,
              username: 'tritrack',
              password: goodPassword,
            ),
          );
          expect(printed.join('\n'), contains('does not offer STARTTLS'));
          expect(relay.transcript.where((l) => l.startsWith('AUTH')), isEmpty);
          expect(relay.received, isEmpty);
        },
      );

      test('a certificate the client does not trust stops the send', () async {
        relay.tlsContext = serverTls();
        // No CA path: the self-signed test certificate is unknown to the
        // system store, which is the situation with a relay behind an
        // institutional CA before TRITRACK_SMTP_CA_CERT_PATH is set.
        final printed = await send(
          SmtpConfig(
            host: 'localhost',
            port: relay.port,
            tls: SmtpTlsMode.starttls,
            from: 'tritrack@example.edu',
            timeout: const Duration(seconds: 10),
          ),
        );
        expect(printed.join('\n'), contains('NOT DELIVERED'));
        expect(printed.join('\n'), contains('TLS'));
        expect(relay.received, isEmpty);
      });

      test('nothing listening: "could not connect"', () async {
        final printed = await send(config(port: 1));
        expect(printed.join('\n'), contains('NOT DELIVERED'));
        expect(printed.join('\n'), contains('could not connect'));
      });

      test('a relay that refuses in its greeting', () async {
        relay.refuseInGreeting = true;
        final printed = await send(config());
        expect(printed.join('\n'), contains('554'));
        expect(relay.received, isEmpty);
      });

      test('a relay that hangs up mid-DATA', () async {
        relay.hangUpDuringData = true;
        final printed = await send(config());
        // A destroyed socket arrives as a reset on macOS and as a clean end of
        // stream elsewhere; both are the same fact to an operator.
        expect(
          printed.join('\n'),
          anyOf(
            contains('closed the connection'),
            contains('connection to the relay dropped'),
          ),
        );
        expect(relay.received, isEmpty);
      });

      test(
        'a relay that goes silent: the wait is bounded and says so',
        () async {
          relay.neverAnswerEhlo = true;
          final printed = await send(
            config(timeout: const Duration(milliseconds: 300)),
          );
          expect(printed.join('\n'), contains('did not answer within'));
        },
      );

      test('every failure line says where to look next', () async {
        relay.rcptReplyCode = 550;
        final printed = await send(config());
        expect(printed.join('\n'), contains('TRITRACK_SMTP_'));
        expect(printed.join('\n'), contains('Sign-in email:'));
      });
    });
  });
}
