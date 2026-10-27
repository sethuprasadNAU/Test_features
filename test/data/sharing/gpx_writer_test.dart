// Task 11.209: "the GPX parses back... 'it was written' is not evidence that
// it is valid." This parses the file with a real XML parser (`xml`, already
// a transitive dependency — see pubspec.yaml's dev_dependencies comment) and
// reads the waypoint back out, rather than regex-matching text this test
// file just generated.
import 'package:flutter_test/flutter_test.dart';
import 'package:tritrack/data/sharing/gpx_writer.dart';
import 'package:xml/xml.dart';

void main() {
  group('GpxWaypointWriter.build', () {
    test('round-trips latitude, longitude, name, elevation, desc and time', () {
      final timeUtc = DateTime.utc(2026, 9, 9, 14, 32, 0);
      final gpx = GpxWaypointWriter.build(
        latitude: 45.123456,
        longitude: -111.654321,
        name: 'Bearing · MOOSE01 · 165.100 MHz',
        elevationMeters: 1523.4,
        description: 'Error ellipse 120×80 m · 3 bearings used',
        timeUtc: timeUtc,
      );

      final doc = XmlDocument.parse(gpx);
      final wpt = doc.findAllElements('wpt').single;

      expect(double.parse(wpt.getAttribute('lat')!), closeTo(45.123456, 1e-9));
      expect(double.parse(wpt.getAttribute('lon')!), closeTo(-111.654321, 1e-9));
      expect(
        wpt.findElements('name').single.innerText,
        'Bearing · MOOSE01 · 165.100 MHz',
      );
      expect(
        double.parse(wpt.findElements('ele').single.innerText),
        closeTo(1523.4, 1e-9),
      );
      expect(
        wpt.findElements('desc').single.innerText,
        'Error ellipse 120×80 m · 3 bearings used',
      );
      expect(
        DateTime.parse(wpt.findElements('time').single.innerText),
        timeUtc,
      );
    });

    test('omits ele, desc and time when not given, rather than a false 0/empty', () {
      final gpx = GpxWaypointWriter.build(
        latitude: 1.0,
        longitude: 2.0,
        name: 'Map point',
      );
      final doc = XmlDocument.parse(gpx);
      final wpt = doc.findAllElements('wpt').single;

      expect(wpt.findElements('ele'), isEmpty);
      expect(wpt.findElements('desc'), isEmpty);
      expect(wpt.findElements('time'), isEmpty);
      expect(wpt.findElements('name').single.innerText, 'Map point');
    });

    test('escapes XML-significant characters in name and description', () {
      final gpx = GpxWaypointWriter.build(
        latitude: 0,
        longitude: 0,
        name: 'Tag <A> & "B"',
        description: "It's <bad>",
      );
      // Must parse without throwing — an unescaped `<` or `&` would corrupt
      // the document structure, not just the text.
      final doc = XmlDocument.parse(gpx);
      final wpt = doc.findAllElements('wpt').single;
      expect(wpt.findElements('name').single.innerText, 'Tag <A> & "B"');
      expect(wpt.findElements('desc').single.innerText, "It's <bad>");
    });

    test('rejects a non-UTC timeUtc', () {
      expect(
        () => GpxWaypointWriter.build(
          latitude: 0,
          longitude: 0,
          name: 'x',
          timeUtc: DateTime(2026, 1, 1),
        ),
        throwsA(isA<AssertionError>()),
      );
    });
  });
}
