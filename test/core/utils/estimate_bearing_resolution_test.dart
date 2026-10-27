import 'package:flutter_test/flutter_test.dart';
import 'package:tritrack/core/utils/estimate_bearing_resolution.dart';

void main() {
  group('EstimateBearingResolution.of — task 11.259', () {
    test('fully local: resolved count equals the stored list, not carried', () {
      final r = EstimateBearingResolution.of(
        ['obs-1', 'obs-2', 'obs-3'],
        {'obs-1', 'obs-2', 'obs-3', 'obs-4'},
      );
      expect(r.resolvedCount, 3);
      expect(r.totalCount, 3);
      expect(r.isFullyCarried, isFalse);
      expect(r.label('bearings used'), '3 bearings used');
    });

    test('fully carried: none of the stored ids resolve locally', () {
      final r = EstimateBearingResolution.of(
        ['obs-1', 'obs-2'],
        {'obs-9'},
      );
      expect(r.resolvedCount, 0);
      expect(r.isFullyCarried, isTrue);
      // Never "0 <noun>" — that would claim the estimate came from nothing.
      expect(r.label('bearings used'), isNot(contains('0')));
      expect(r.label('bearings used'), 'computed in an earlier season');
    });

    test(
        'partial: a carried estimate with one bearing recorded new this '
        'season counts only what resolves, not the stored total', () {
      final r = EstimateBearingResolution.of(
        ['obs-carried-1', 'obs-carried-2', 'obs-new'],
        {'obs-new'},
      );
      expect(r.resolvedCount, 1);
      expect(r.totalCount, 3);
      expect(r.isFullyCarried, isFalse);
      expect(r.label('bearings used'), '1 bearings used');
    });

    test('an estimate with an empty observation list is not "carried"', () {
      final r = EstimateBearingResolution.of([], {'obs-1'});
      expect(r.isFullyCarried, isFalse,
          reason: 'nothing to resolve is not the same as everything failing '
              'to resolve');
      expect(r.label('bearings used'), '0 bearings used');
    });
  });
}
