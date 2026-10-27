// Task 11.209: "Open in Maps" — pure and assertable without a device.
import 'package:flutter_test/flutter_test.dart';
import 'package:tritrack/data/sharing/map_handoff.dart';

void main() {
  group('MapHandoff.uriFor', () {
    test('Android: a geo: URI with a bare coordinate when there is no label', () {
      final uri = MapHandoff.uriFor(45.123456, -111.654321, isAndroid: true);
      expect(uri.toString(), 'geo:45.123456,-111.654321?q=45.123456,-111.654321');
    });

    test('Android: the label is encoded onto the query as a named pin', () {
      final uri = MapHandoff.uriFor(
        45.123456,
        -111.654321,
        label: "Bearing · observer's position",
        isAndroid: true,
      );
      expect(
        uri.toString(),
        'geo:45.123456,-111.654321?q=45.123456,-111.654321'
        '(${Uri.encodeComponent("Bearing · observer's position")})',
      );
    });

    test('iOS/macOS: an Apple Maps URL with ll and no q when there is no label', () {
      final uri = MapHandoff.uriFor(45.123456, -111.654321, isAndroid: false);
      expect(uri.toString(), 'https://maps.apple.com/?ll=45.123456%2C-111.654321');
    });

    test('iOS/macOS: q carries the label', () {
      final uri = MapHandoff.uriFor(
        45.123456,
        -111.654321,
        label: 'Truth point',
        isAndroid: false,
      );
      expect(
        uri.toString(),
        'https://maps.apple.com/?ll=45.123456%2C-111.654321&q=Truth+point',
      );
    });
  });
}
