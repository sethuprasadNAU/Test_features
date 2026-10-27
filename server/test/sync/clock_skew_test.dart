import 'package:test/test.dart';
import 'package:tritrack_server/tritrack_server.dart';

void main() {
  final receivedAt = DateTime.utc(2026, 8, 1, 12, 0, 0);

  group('future-dated rows', () {
    test('a row well ahead of the server clock is flagged', () {
      expect(
        ClockSkew.classify(
          updatedAt: receivedAt.add(const Duration(hours: 3)),
          receivedAt: receivedAt,
        ),
        ClockSkewFlag.future,
      );
    });

    test('ordinary drift inside the tolerance is not flagged', () {
      // Flagging every mildly-drifted phone would make the signal noise, and
      // noise gets ignored — which is worse than no flag, because a real
      // problem then hides among the false ones.
      expect(
        ClockSkew.classify(
          updatedAt: receivedAt.add(const Duration(minutes: 2)),
          receivedAt: receivedAt,
        ),
        isNull,
      );
    });

    test('the tolerance boundary itself is not flagged', () {
      expect(
        ClockSkew.classify(
          updatedAt: receivedAt.add(ClockSkew.tolerance),
          receivedAt: receivedAt,
        ),
        isNull,
      );
    });

    test('just past the tolerance is flagged', () {
      expect(
        ClockSkew.classify(
          updatedAt: receivedAt.add(
            ClockSkew.tolerance + const Duration(seconds: 1),
          ),
          receivedAt: receivedAt,
        ),
        ClockSkewFlag.future,
      );
    });
  });

  group('old rows', () {
    // The distinction this group exists to protect: a device off-network for a
    // field season legitimately pushes rows weeks old. Treating relative age
    // as a fault would flag normal field use, so only an *absolute* floor
    // (a clock that reset) counts as broken.
    test(
      'a row from three weeks ago is NOT flagged — that is normal backlog',
      () {
        expect(
          ClockSkew.classify(
            updatedAt: receivedAt.subtract(const Duration(days: 21)),
            receivedAt: receivedAt,
          ),
          isNull,
        );
      },
    );

    test('a row from a full season ago is NOT flagged', () {
      expect(
        ClockSkew.classify(
          updatedAt: receivedAt.subtract(const Duration(days: 150)),
          receivedAt: receivedAt,
        ),
        isNull,
      );
    });

    test('a dead-battery 1970 timestamp IS flagged', () {
      expect(
        ClockSkew.classify(
          updatedAt: DateTime.utc(1970),
          receivedAt: receivedAt,
        ),
        ClockSkewFlag.implausiblePast,
      );
    });

    test('anything below the plausible floor is flagged', () {
      expect(
        ClockSkew.classify(
          updatedAt: ClockSkew.plausibleFloor.subtract(const Duration(days: 1)),
          receivedAt: receivedAt,
        ),
        ClockSkewFlag.implausiblePast,
      );
    });

    test('the floor itself is not flagged', () {
      expect(
        ClockSkew.classify(
          updatedAt: ClockSkew.plausibleFloor,
          receivedAt: receivedAt,
        ),
        isNull,
      );
    });
  });

  group('internally inconsistent rows', () {
    test('updated_at before created_at is flagged', () {
      expect(
        ClockSkew.classify(
          updatedAt: receivedAt.subtract(const Duration(days: 2)),
          receivedAt: receivedAt,
          createdAt: receivedAt.subtract(const Duration(days: 1)),
        ),
        ClockSkewFlag.updatedBeforeCreated,
      );
    });

    test('updated_at equal to created_at is fine (a never-edited row)', () {
      final at = receivedAt.subtract(const Duration(days: 1));
      expect(
        ClockSkew.classify(
          updatedAt: at,
          receivedAt: receivedAt,
          createdAt: at,
        ),
        isNull,
      );
    });

    test('a future row is reported as future even if also inconsistent', () {
      // Ordering matters only for which single flag is reported; `future` is
      // the more actionable signal, so it wins.
      expect(
        ClockSkew.classify(
          updatedAt: receivedAt.add(const Duration(days: 1)),
          receivedAt: receivedAt,
          createdAt: receivedAt.add(const Duration(days: 2)),
        ),
        ClockSkewFlag.future,
      );
    });
  });

  group('classifyRow', () {
    test('classifies a well-formed row map', () {
      expect(
        ClockSkew.classifyRow({
          'updated_at': '2026-08-05T12:00:00.000Z',
          'created_at': '2026-08-01T12:00:00.000Z',
        }, receivedAt: receivedAt),
        ClockSkewFlag.future,
      );
    });

    test('a clean row yields no flag', () {
      expect(
        ClockSkew.classifyRow({
          'updated_at': '2026-07-30T12:00:00.000Z',
          'created_at': '2026-07-29T12:00:00.000Z',
        }, receivedAt: receivedAt),
        isNull,
      );
    });

    test('an unparseable updated_at is not reported as skew', () {
      // That is a validation problem (RowValidator's job); calling it a clock
      // fault would send whoever reads the diagnostics console the wrong way.
      expect(
        ClockSkew.classifyRow({
          'updated_at': 'not-a-timestamp',
        }, receivedAt: receivedAt),
        isNull,
      );
      expect(
        ClockSkew.classifyRow({'updated_at': null}, receivedAt: receivedAt),
        isNull,
      );
      expect(ClockSkew.classifyRow({}, receivedAt: receivedAt), isNull);
    });

    test('a missing created_at just skips the consistency check', () {
      expect(
        ClockSkew.classifyRow({
          'updated_at': '2026-07-30T12:00:00.000Z',
        }, receivedAt: receivedAt),
        isNull,
      );
    });

    test('non-UTC offsets are normalised before comparison', () {
      // Same instant as receivedAt + 2h, written with an offset rather than Z.
      expect(
        ClockSkew.classifyRow({
          'updated_at': '2026-08-01T16:00:00.000+02:00',
        }, receivedAt: receivedAt),
        ClockSkewFlag.future,
      );
    });
  });

  group('flag round-trip', () {
    test('every flag survives a database round-trip', () {
      for (final flag in ClockSkewFlag.values) {
        expect(ClockSkewFlag.fromDb(flag.db), flag);
      }
    });

    test('null maps to null', () {
      expect(ClockSkewFlag.fromDb(null), isNull);
    });
  });
}
