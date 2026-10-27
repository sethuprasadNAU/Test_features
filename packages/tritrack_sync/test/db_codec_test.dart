import 'package:test/test.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

void main() {
  group('DbCodec', () {
    test('encodeUtc/decodeUtc round-trip and normalize to UTC', () {
      final dt = DateTime.utc(2026, 7, 16, 18, 30);
      final encoded = DbCodec.encodeUtc(dt);
      expect(encoded, endsWith('Z'));
      expect(DbCodec.decodeUtc(encoded), dt);
    });

    test('encodeUtcOrNull/decodeUtcOrNull pass null through', () {
      expect(DbCodec.encodeUtcOrNull(null), isNull);
      expect(DbCodec.decodeUtcOrNull(null), isNull);
    });

    test('encodeLocal preserves wall-clock time regardless of zone', () {
      final local = DateTime(2026, 7, 16, 11, 30);
      final encoded = DbCodec.encodeLocal(local);
      expect(DbCodec.decodeLocal(encoded), local);
    });

    test('encodeOffset formats a signed HH:MM zone string', () {
      expect(DbCodec.encodeOffset(const Duration(hours: -7)), '-07:00');
      expect(
        DbCodec.encodeOffset(const Duration(hours: 5, minutes: 30)),
        '+05:30',
      );
    });

    test('bool encode/decode round-trips through INTEGER 0/1', () {
      expect(DbCodec.encodeBool(true), 1);
      expect(DbCodec.encodeBool(false), 0);
      expect(DbCodec.decodeBool(1), isTrue);
      expect(DbCodec.decodeBool(0), isFalse);
      expect(DbCodec.encodeBoolOrNull(null), isNull);
      expect(DbCodec.decodeBoolOrNull(null), isNull);
    });

    test('string list encode/decode round-trips through JSON text', () {
      final values = ['tag-1', 'tag-2'];
      final encoded = DbCodec.encodeStringList(values);
      expect(DbCodec.decodeStringList(encoded), values);
      expect(DbCodec.decodeStringList(null), isEmpty);
    });

    // Task 10.67: every decode* below used a naked `as` cast — a wrong-typed
    // column (from a synced row this build didn't validate as strictly as it
    // should have, or a hand-edited backup) threw a raw, unlabeled
    // `TypeError` instead of a caller-recognizable exception. Reached from
    // every model's `fromRow` and from `backup_format.dart`'s manifest
    // parser, so this is the single place that closes the gap for both.
    group('rejection paths (task 10.67)', () {
      test('decodeUtc rejects a wrong-typed value', () {
        expect(
          () => DbCodec.decodeUtc(1721150200000),
          throwsA(isA<DbCodecFormatException>()),
        );
      });

      test('decodeUtc rejects an unparseable string', () {
        expect(
          () => DbCodec.decodeUtc('not-a-timestamp'),
          throwsA(isA<DbCodecFormatException>()),
        );
      });

      test('decodeUtc rejects null (not nullable, unlike decodeUtcOrNull)', () {
        expect(
          () => DbCodec.decodeUtc(null),
          throwsA(isA<DbCodecFormatException>()),
        );
      });

      test('decodeUtcOrNull rejects a wrong-typed non-null value', () {
        expect(
          () => DbCodec.decodeUtcOrNull(42),
          throwsA(isA<DbCodecFormatException>()),
        );
      });

      test('decodeLocal rejects a wrong-typed value', () {
        expect(
          () => DbCodec.decodeLocal(true),
          throwsA(isA<DbCodecFormatException>()),
        );
      });

      test('decodeBool rejects a wrong-typed value', () {
        expect(
          () => DbCodec.decodeBool('1'),
          throwsA(isA<DbCodecFormatException>()),
        );
      });

      test('decodeBoolOrNull rejects a wrong-typed non-null value', () {
        expect(
          () => DbCodec.decodeBoolOrNull('true'),
          throwsA(isA<DbCodecFormatException>()),
        );
      });

      test('decodeStringList rejects a non-string value', () {
        expect(
          () => DbCodec.decodeStringList(42),
          throwsA(isA<DbCodecFormatException>()),
        );
      });

      test('decodeStringList rejects malformed JSON', () {
        expect(
          () => DbCodec.decodeStringList('not-json'),
          throwsA(isA<DbCodecFormatException>()),
        );
      });

      test('decodeStringList rejects a JSON value that is not an array', () {
        expect(
          () => DbCodec.decodeStringList('{"a": 1}'),
          throwsA(isA<DbCodecFormatException>()),
        );
      });

      test('decodeStringList rejects an array with a non-string element', () {
        expect(
          () => DbCodec.decodeStringList('["tag-1", 2]'),
          throwsA(isA<DbCodecFormatException>()),
        );
      });
    });
  });
}
