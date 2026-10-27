import 'package:flutter_test/flutter_test.dart';
import 'package:tritrack/core/utils/natural_sort.dart';

void main() {
  group('naturalCompare', () {
    test('orders embedded digit runs numerically, not lexically', () {
      final names = ['Tag 10', 'Tag 2', 'Tag 1'];
      names.sort(naturalCompare);
      expect(names, ['Tag 1', 'Tag 2', 'Tag 10']);
    });

    test('orders decimal-looking names numerically by their digit runs', () {
      final names = ['148.123', '9.5', '148.9'];
      names.sort(naturalCompare);
      // Each run of digits compares as a number: "148" < "9" is false, so
      // "9.5" sorts before "148.123"/"148.9"; within the "148." prefix,
      // "123" > "9" numerically.
      expect(names, ['9.5', '148.9', '148.123']);
    });

    test('is case-insensitive', () {
      final names = ['banana', 'Apple', 'cherry'];
      names.sort(naturalCompare);
      expect(names, ['Apple', 'banana', 'cherry']);
    });

    test('a name that is a strict prefix of another sorts first', () {
      final names = ['Tag 1a', 'Tag 1'];
      names.sort(naturalCompare);
      expect(names, ['Tag 1', 'Tag 1a']);
    });

    test('equal names compare as zero', () {
      expect(naturalCompare('Tag 7', 'Tag 7'), 0);
    });
  });
}
