import 'package:flutter_test/flutter_test.dart';
import 'package:tritrack/data/auth/auth_client.dart';
import 'package:tritrack/data/auth/session_store.dart';

void main() {
  group('extractSignInToken', () {
    // Both forms are things a person will reasonably paste: the browser
    // landing page offers the bare code, but someone may copy the link out of
    // the email instead. Rejecting either would read as a broken sign-in.
    test('accepts a bare code', () {
      const token = 'abcdefghijklmnopqrstuvwxyz0123456789_-AB';
      expect(extractSignInToken(token), token);
    });

    test('accepts the whole sign-in URL', () {
      const token = 'abcdefghijklmnopqrstuvwxyz0123456789_-AB';
      expect(
        extractSignInToken('http://192.168.1.42:8080/auth/redeem?token=$token'),
        token,
      );
    });

    test('tolerates surrounding whitespace from a sloppy copy', () {
      const token = 'abcdefghijklmnopqrstuvwxyz0123456789_-AB';
      expect(extractSignInToken('  $token \n'), token);
    });

    test('rejects empty and obviously-not-a-code input', () {
      expect(extractSignInToken(''), isNull);
      expect(extractSignInToken('   '), isNull);
      expect(extractSignInToken('hello there'), isNull);
      expect(extractSignInToken('short'), isNull);
    });

    test('rejects a URL with no token parameter', () {
      expect(
        extractSignInToken('http://192.168.1.42:8080/auth/redeem'),
        isNull,
      );
    });
  });

  group('StoredSession', () {
    final expires = DateTime.utc(2026, 11, 1);

    test('round-trips through JSON', () {
      final session = StoredSession(
        token: 'tok',
        userId: 'user-1',
        email: 'sam@example.com',
        expiresAt: expires,
      );
      final decoded = StoredSession.fromJson(session.toJson())!;
      expect(decoded.token, 'tok');
      expect(decoded.userId, 'user-1');
      expect(decoded.email, 'sam@example.com');
      expect(decoded.expiresAt, expires);
    });

    test('malformed stored state decodes to null rather than throwing', () {
      // Being signed out is a fully supported state, so a corrupt or
      // older-format entry has nothing to recover and nothing to report.
      expect(StoredSession.fromJson({}), isNull);
      expect(StoredSession.fromJson({'token': 'x'}), isNull);
      expect(
        StoredSession.fromJson({
          'token': 'x',
          'user_id': 'u',
          'email': 'e',
          'expires_at': 'not-a-date',
        }),
        isNull,
      );
    });

    test('expiry is evaluated against a supplied clock', () {
      final session = StoredSession(
        token: 'tok',
        userId: 'user-1',
        email: 'sam@example.com',
        expiresAt: expires,
      );
      expect(
        session.isExpiredAt(expires.subtract(const Duration(days: 1))),
        isFalse,
      );
      expect(session.isExpiredAt(expires), isTrue);
      expect(session.isExpiredAt(expires.add(const Duration(days: 1))), isTrue);
    });
  });
}
