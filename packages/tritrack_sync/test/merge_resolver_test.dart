import 'package:test/test.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

/// A minimal sync-column row. Only the four columns [MergeResolver] consults.
Map<String, Object?> row({
  int revision = 0,
  String updatedAt = '2026-07-16T18:30:00.000Z',
  String? device,
}) => {
  'revision': revision,
  'updated_at': updatedAt,
  'origin_device_id': device,
};

void main() {
  group('MergeResolver last-write-wins ordering', () {
    test('higher revision wins even with an older updated_at', () {
      final incoming = row(revision: 3, updatedAt: '2000-01-01T00:00:00.000Z');
      final local = row(revision: 2, updatedAt: '2026-07-16T18:30:00.000Z');
      expect(MergeResolver.incomingWins(incoming, local), isTrue);
      expect(MergeResolver.incomingWins(local, incoming), isFalse);
    });

    test('equal revision → later updated_at wins', () {
      final newer = row(revision: 1, updatedAt: '2026-07-17T00:00:00.000Z');
      final older = row(revision: 1, updatedAt: '2026-07-16T00:00:00.000Z');
      expect(MergeResolver.incomingWins(newer, older), isTrue);
      expect(MergeResolver.incomingWins(older, newer), isFalse);
    });

    test(
      'equal revision + updated_at → higher device id wins; null is lowest',
      () {
        final b = row(device: 'device-B');
        final a = row(device: 'device-A');
        final none = row();
        expect(MergeResolver.incomingWins(b, a), isTrue);
        expect(MergeResolver.incomingWins(a, b), isFalse);
        expect(MergeResolver.incomingWins(a, none), isTrue);
        expect(MergeResolver.incomingWins(none, a), isFalse);
      },
    );

    test('fully-equal sync state is a no-op (incoming does not win)', () {
      final x = row(
        revision: 4,
        updatedAt: '2026-07-16T18:30:00.000Z',
        device: 'd',
      );
      final y = row(
        revision: 4,
        updatedAt: '2026-07-16T18:30:00.000Z',
        device: 'd',
      );
      expect(MergeResolver.incomingWins(x, y), isFalse);
      expect(MergeResolver.compare(x, y), 0);
    });

    test(
      'sub-second precision differences are parsed, not compared lexically',
      () {
        // '...30Z' vs '...30.500Z': lexical compare would put the shorter string
        // first; parsed, the fractional one is later.
        final frac = row(revision: 1, updatedAt: '2026-07-16T18:30:30.500Z');
        final whole = row(revision: 1, updatedAt: '2026-07-16T18:30:30Z');
        expect(MergeResolver.incomingWins(frac, whole), isTrue);
      },
    );

    test('missing/invalid fields sort oldest without throwing', () {
      final empty = <String, Object?>{};
      final real = row(revision: 1);
      expect(MergeResolver.incomingWins(real, empty), isTrue);
      expect(MergeResolver.incomingWins(empty, real), isFalse);
    });
  });
}
