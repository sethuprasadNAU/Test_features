import 'dart:convert';

import 'package:test/test.dart';
import 'package:tritrack_server/tritrack_server.dart';

void main() {
  group('generate', () {
    test('produces 256 bits of entropy, base64url without padding', () {
      final token = Tokens.generate();
      expect(token, isNot(contains('=')));
      expect(token, matches(RegExp(r'^[A-Za-z0-9_-]+$')));
      expect(
        base64Url.decode(
          '$token='.substring(0, token.length + (4 - token.length % 4) % 4),
        ),
        hasLength(Tokens.entropyBytes),
      );
    });

    test('never repeats across a large sample', () {
      final tokens = {for (var i = 0; i < 2000; i++) Tokens.generate()};
      expect(tokens, hasLength(2000));
    });

    test('is URL-safe, so it survives being emailed as a query parameter', () {
      for (var i = 0; i < 200; i++) {
        final token = Tokens.generate();
        expect(Uri.encodeComponent(token), token);
      }
    });
  });

  group('hash', () {
    test('is stable and 64 hex characters (SHA-256)', () {
      final token = Tokens.generate();
      expect(Tokens.hash(token), Tokens.hash(token));
      expect(Tokens.hash(token), matches(RegExp(r'^[0-9a-f]{64}$')));
    });

    test('differs for different tokens', () {
      expect(
        Tokens.hash(Tokens.generate()),
        isNot(Tokens.hash(Tokens.generate())),
      );
    });

    test('does not contain the token', () {
      // The point of hashing at rest: a database read must not yield usable
      // tokens.
      final token = Tokens.generate();
      expect(Tokens.hash(token), isNot(contains(token)));
    });
  });

  group('constantTimeEquals', () {
    test('matches identical digests', () {
      final digest = Tokens.hash('x');
      expect(Tokens.constantTimeEquals(digest, digest), isTrue);
    });

    test('rejects different digests, including a one-character difference', () {
      final a = Tokens.hash('a');
      final b = '${a.substring(0, a.length - 1)}${a.endsWith('0') ? '1' : '0'}';
      expect(Tokens.constantTimeEquals(a, b), isFalse);
    });

    test('rejects different lengths without throwing', () {
      expect(Tokens.constantTimeEquals('abc', 'abcd'), isFalse);
      expect(Tokens.constantTimeEquals('', 'a'), isFalse);
      expect(Tokens.constantTimeEquals('', ''), isTrue);
    });
  });
}
