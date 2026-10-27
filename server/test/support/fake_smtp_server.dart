/// An in-process SMTP relay for `smtp_email_sender_test.dart` (task 11.287).
///
/// Speaks just enough of RFC 5321, 3207 and 4954 to receive one message from
/// `SmtpClient`, and — more to the point — enough to be **broken on demand**:
/// refuse the recipient, reject the password, hang up mid-`DATA`, offer no
/// `STARTTLS`. The sender's whole job is to fail visibly in the log and
/// invisibly to the caller, and a relay that only ever says yes cannot test
/// that (defect vocabulary 70: *an instrument's behavior on a broken server is
/// a different question from its behavior on a healthy one*).
///
/// Every byte the client sent is kept in [transcript], so a test can assert
/// what went on the wire rather than what the client believed it sent.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// One message the relay accepted: envelope and the un-dot-stuffed data.
class ReceivedMessage {
  ReceivedMessage({
    required this.mailFrom,
    required this.recipients,
    required this.data,
    required this.overTls,
    required this.authenticatedAs,
  });

  final String mailFrom;
  final List<String> recipients;

  /// The message as the relay would store it: CRLF lines, dot-stuffing
  /// removed, without the terminating `.`.
  final String data;
  final bool overTls;
  final String? authenticatedAs;

  Map<String, String> get headers {
    final result = <String, String>{};
    for (final line in data.split('\r\n')) {
      if (line.isEmpty) break;
      final colon = line.indexOf(':');
      if (colon > 0) {
        result[line.substring(0, colon)] = line.substring(colon + 1).trim();
      }
    }
    return result;
  }

  String get body {
    final split = data.indexOf('\r\n\r\n');
    return split == -1 ? '' : data.substring(split + 4);
  }
}

class FakeSmtpServer {
  FakeSmtpServer._(this._server);

  final ServerSocket _server;
  final _connections = <Socket>[];

  /// Messages accepted with a final `250` after `DATA`.
  final received = <ReceivedMessage>[];

  /// Every command line the client sent, in order, across connections. The
  /// bytes after `AUTH` are recorded too — this is a test relay and the
  /// assertions need them.
  final transcript = <String>[];

  /// Set [tlsContext] to offer `STARTTLS`; leave null to offer none.
  SecurityContext? tlsContext;

  /// When non-null, `AUTH` is advertised with these mechanisms and a
  /// credential that does not match is refused with `535`.
  List<String>? authMechanisms;
  String? expectedUsername;
  String? expectedPassword;

  /// Scripted failures, each off by default.
  bool refuseInGreeting = false;
  int? rcptReplyCode;
  bool hangUpDuringData = false;
  bool neverAnswerEhlo = false;

  int get port => _server.port;

  static Future<FakeSmtpServer> start() async {
    final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final server = FakeSmtpServer._(socket);
    socket.listen(server._serve);
    return server;
  }

  Future<void> close() async {
    for (final connection in _connections) {
      connection.destroy();
    }
    await _server.close();
  }

  Future<void> _serve(Socket plain) async {
    _connections.add(plain);
    var socket = plain;
    var reader = _Lines(socket);
    var secured = false;
    String? authenticatedAs;
    String? mailFrom;
    final recipients = <String>[];

    void reply(String line) => socket.write('$line\r\n');
    Future<String?> next() async {
      final line = await reader.next();
      if (line != null) transcript.add(line);
      return line;
    }

    if (refuseInGreeting) {
      reply('554 fake-relay not accepting connections');
      await socket.close();
      return;
    }
    reply('220 fake-relay ESMTP ready');

    while (true) {
      final line = await next();
      if (line == null) return;
      final upper = line.toUpperCase();
      if (upper.startsWith('EHLO ') || upper.startsWith('HELO ')) {
        if (neverAnswerEhlo) continue;
        final lines = ['250-fake-relay greets you'];
        if (tlsContext != null && !secured) lines.add('250-STARTTLS');
        final auth = authMechanisms;
        if (auth != null && (secured || tlsContext == null)) {
          lines.add('250-AUTH ${auth.join(' ')}');
        }
        lines.add('250 8BITMIME');
        for (final l in lines) {
          reply(l);
        }
      } else if (upper == 'STARTTLS') {
        final context = tlsContext;
        if (context == null || secured) {
          reply('454 TLS not available');
          continue;
        }
        reply('220 go ahead');
        await socket.flush();
        reader.detach();
        try {
          socket = await SecureSocket.secureServer(socket, context);
        } on Object {
          // The client rejected our certificate. That is its test, not ours.
          plain.destroy();
          return;
        }
        _connections.add(socket);
        reader = _Lines(socket);
        secured = true;
      } else if (upper.startsWith('AUTH ')) {
        final parts = line.split(' ');
        final mechanism = parts[1].toUpperCase();
        String? user;
        String? pass;
        if (mechanism == 'PLAIN') {
          final initial = parts.length > 2
              ? parts[2]
              : () {
                  reply('334 ');
                  return null;
                }();
          final encoded = initial ?? await next();
          if (encoded == null) return;
          final fields = utf8.decode(base64.decode(encoded)).split('\u0000');
          user = fields[1];
          pass = fields[2];
        } else if (mechanism == 'LOGIN') {
          reply('334 ${base64.encode(utf8.encode('Username:'))}');
          final u = await next();
          if (u == null) return;
          reply('334 ${base64.encode(utf8.encode('Password:'))}');
          final p = await next();
          if (p == null) return;
          user = utf8.decode(base64.decode(u));
          pass = utf8.decode(base64.decode(p));
        } else {
          reply('504 mechanism not supported');
          continue;
        }
        if (user == expectedUsername && pass == expectedPassword) {
          authenticatedAs = user;
          reply('235 2.7.0 authenticated');
        } else {
          reply('535 5.7.8 authentication credentials invalid');
        }
      } else if (upper.startsWith('MAIL FROM:')) {
        mailFrom = _angle(line.substring('MAIL FROM:'.length));
        recipients.clear();
        reply('250 2.1.0 sender ok');
      } else if (upper.startsWith('RCPT TO:')) {
        final rcpt = _angle(line.substring('RCPT TO:'.length));
        final code = rcptReplyCode;
        if (code != null && code != 250) {
          reply('$code 5.1.1 $rcpt: recipient refused by fake-relay');
        } else {
          recipients.add(rcpt);
          reply('250 2.1.5 recipient ok');
        }
      } else if (upper == 'DATA') {
        if (hangUpDuringData) {
          reply('354 go ahead');
          await socket.flush();
          socket.destroy();
          return;
        }
        reply('354 end data with <CR><LF>.<CR><LF>');
        final lines = <String>[];
        while (true) {
          final dataLine = await reader.next();
          if (dataLine == null) return;
          if (dataLine == '.') break;
          lines.add(
            dataLine.startsWith('..') ? dataLine.substring(1) : dataLine,
          );
        }
        received.add(
          ReceivedMessage(
            mailFrom: mailFrom ?? '',
            recipients: List.of(recipients),
            data: lines.join('\r\n'),
            overTls: secured,
            authenticatedAs: authenticatedAs,
          ),
        );
        reply('250 2.0.0 queued as fake-${received.length}');
      } else if (upper == 'QUIT') {
        reply('221 bye');
        await socket.flush();
        await socket.close();
        return;
      } else if (upper == 'RSET' || upper == 'NOOP') {
        reply('250 ok');
      } else {
        reply('500 command not recognized');
      }
    }
  }

  static String _angle(String value) {
    final trimmed = value.trim();
    return trimmed.startsWith('<') && trimmed.endsWith('>')
        ? trimmed.substring(1, trimmed.length - 1)
        : trimmed;
  }
}

/// CRLF line reader that can be paused for a TLS upgrade.
class _Lines {
  _Lines(Stream<Uint8List> stream) {
    _subscription = stream.listen(
      (chunk) {
        _buffer.addAll(chunk);
        _flush();
      },
      onDone: () {
        _done = true;
        _flush();
      },
      onError: (_) {
        _done = true;
        _flush();
      },
    );
  }

  late final StreamSubscription<Uint8List> _subscription;
  final _buffer = <int>[];
  final _ready = <String>[];
  Completer<String?>? _waiter;
  bool _done = false;

  void _flush() {
    var start = 0;
    for (var i = 1; i < _buffer.length; i++) {
      if (_buffer[i - 1] == 0x0d && _buffer[i] == 0x0a) {
        _ready.add(utf8.decode(_buffer.sublist(start, i - 1)));
        start = i + 1;
      }
    }
    _buffer.removeRange(0, start);
    final waiter = _waiter;
    if (waiter == null) return;
    if (_ready.isNotEmpty) {
      _waiter = null;
      waiter.complete(_ready.removeAt(0));
    } else if (_done) {
      _waiter = null;
      waiter.complete(null);
    }
  }

  Future<String?> next() {
    if (_ready.isNotEmpty) return Future.value(_ready.removeAt(0));
    if (_done) return Future.value(null);
    final completer = Completer<String?>();
    _waiter = completer;
    return completer.future;
  }

  void detach() => _subscription.pause();
}
