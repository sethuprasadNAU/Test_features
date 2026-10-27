import 'package:test/test.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

void main() {
  group('TagColorPalette', () {
    test('has 12 distinct colorblind-safe colors', () {
      expect(TagColorPalette.colors, hasLength(12));
      expect(TagColorPalette.colors.toSet(), hasLength(12));
    });

    test('isValidHex accepts well-formed #RRGGBB', () {
      expect(TagColorPalette.isValidHex('#E69F00'), isTrue);
      expect(TagColorPalette.isValidHex('#abcdef'), isTrue);
    });

    test('isValidHex rejects malformed values', () {
      expect(TagColorPalette.isValidHex('E69F00'), isFalse);
      expect(TagColorPalette.isValidHex('#E69F0'), isFalse);
      expect(TagColorPalette.isValidHex('#GGGGGG'), isFalse);
      expect(TagColorPalette.isValidHex('#E69F0000'), isFalse);
    });

    test('nextColor round-robins through the palette rather than always '
        'returning the first color', () {
      final assigned = List.generate(12, TagColorPalette.nextColor);
      expect(
        assigned.toSet(),
        hasLength(12),
        reason: 'first 12 assignments should all be distinct',
      );
      expect(assigned, TagColorPalette.colors);
    });

    test('nextColor wraps around after exhausting the palette', () {
      expect(TagColorPalette.nextColor(12), TagColorPalette.colors[0]);
      expect(TagColorPalette.nextColor(13), TagColorPalette.colors[1]);
      expect(TagColorPalette.nextColor(24), TagColorPalette.colors[0]);
    });

    test('colorForIndex is consistent with nextColor', () {
      for (var i = 0; i < 30; i++) {
        expect(TagColorPalette.colorForIndex(i), TagColorPalette.nextColor(i));
      }
    });
  });
}
