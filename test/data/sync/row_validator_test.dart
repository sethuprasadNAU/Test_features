import 'package:flutter_test/flutter_test.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

import '../fixtures.dart';

void main() {
  group('RowValidator', () {
    test('a fully-populated valid observation has no issues', () {
      final issues =
          RowValidator.validate(Tables.observations, sampleObservation().toColumns());
      expect(issues, isEmpty);
    });

    test('null optional fields are not flagged', () {
      final issues = RowValidator.validate(
          Tables.observations, sampleMinimalObservation().toColumns());
      expect(issues, isEmpty);
    });

    test('bearing out of 0–360 is rejected', () {
      final row = sampleObservation().toColumns()..['true_north_bearing'] = 400.0;
      final issues = RowValidator.validate(Tables.observations, row);
      expect(issues, hasLength(1));
      expect(issues.single.field, 'true_north_bearing');
    });

    test('latitude/longitude out of range are rejected', () {
      final row = sampleObservation().toColumns()
        ..['latitude'] = 120.0
        ..['longitude'] = -999.0;
      final issues = RowValidator.validate(Tables.observations, row);
      expect(issues.map((i) => i.field), containsAll(['latitude', 'longitude']));
    });

    test('non-positive bearing uncertainty is rejected', () {
      final row = sampleObservation().toColumns()..['bearing_uncertainty'] = 0.0;
      final issues = RowValidator.validate(Tables.observations, row);
      expect(issues.single.field, 'bearing_uncertainty');
    });

    test('frequency outside the sane VHF band is rejected', () {
      final low = sampleTag().toColumns()..['frequency_mhz'] = 5.0;
      final high = sampleTag().toColumns()..['frequency_mhz'] = 99999.0;
      expect(RowValidator.validate(Tables.tags, low).single.field, 'frequency_mhz');
      expect(RowValidator.validate(Tables.tags, high).single.field, 'frequency_mhz');
    });

    test('non-positive pulse rate is rejected', () {
      final row = sampleTag().toColumns()..['pulse_rate'] = -1.0;
      expect(RowValidator.validate(Tables.tags, row).single.field, 'pulse_rate');
    });

    test('malformed color_hex is rejected', () {
      final missingHash = sampleTag().toColumns()..['color_hex'] = 'E69F00';
      final tooShort = sampleTag().toColumns()..['color_hex'] = '#E69F0';
      final badChars = sampleTag().toColumns()..['color_hex'] = '#GGGGGG';
      expect(RowValidator.validate(Tables.tags, missingHash).single.field, 'color_hex');
      expect(RowValidator.validate(Tables.tags, tooShort).single.field, 'color_hex');
      expect(RowValidator.validate(Tables.tags, badChars).single.field, 'color_hex');
    });

    test('a well-formed color_hex is accepted', () {
      final row = sampleTag().toColumns()..['color_hex'] = '#aabbcc';
      expect(RowValidator.validate(Tables.tags, row), isEmpty);
    });

    test('unknown enum value is rejected (guards the raw-map insert path)', () {
      final row = sampleObservation().toColumns()..['signal_strength'] = 'ludicrous';
      final issues = RowValidator.validate(Tables.observations, row);
      expect(issues.single.field, 'signal_strength');
    });

    test('estimated-position axes must be positive and rotation in range', () {
      final row = sampleEstimatedPosition().toColumns()
        ..['semi_major_axis'] = 0.0
        ..['rotation_angle'] = 500.0;
      final issues = RowValidator.validate(Tables.estimatedPositions, row);
      expect(issues.map((i) => i.field),
          containsAll(['semi_major_axis', 'rotation_angle']));
    });

    test('actual-location uncertainty radius must be positive', () {
      final row = sampleActualLocation().toColumns()..['uncertainty_radius'] = 0.0;
      expect(RowValidator.validate(Tables.actualTagLocations, row).single.field,
          'uncertainty_radius');
    });

    test('empty user email is rejected', () {
      final row = sampleUser().toColumns()..['email'] = '   ';
      expect(RowValidator.validate(Tables.users, row).single.field, 'email');
    });
  });
}
