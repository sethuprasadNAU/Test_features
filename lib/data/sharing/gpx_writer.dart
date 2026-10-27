/// A single-waypoint GPX 1.1 file — task 11.209's "Share…" attaches one of
/// these beside the plain-text coordinates so a map card's selection can be
/// dropped straight into Gaia, Avenza, or any other GPX-reading app without
/// retyping a lat/lon.
///
/// **Deliberately minimal.** This app has no existing GPX support to reuse
/// (unlike the TriTrack payload — see `observation_share.dart`), and a single
/// `<wpt>` is all four selection types on the map card ever need: nothing
/// here writes tracks or routes. GPX 1.1's schema requires `lat`/`lon` as
/// attributes on `<wpt>` and permits `<ele>`, `<name>`, `<desc>`, `<time>` as
/// optional children in that order — this always emits `<name>` and, only
/// when given, `<ele>`, `<desc>` and `<time>`.
abstract final class GpxWaypointWriter {
  /// Builds the file text. [name] and [description] are escaped for XML;
  /// [elevationMeters] is omitted from the file when null (a truth point, a
  /// position estimate, and a free-tapped point carry no elevation — only an
  /// observation does), and [timeUtc] must already be UTC when given.
  static String build({
    required double latitude,
    required double longitude,
    required String name,
    double? elevationMeters,
    String? description,
    DateTime? timeUtc,
  }) {
    assert(
      timeUtc == null || timeUtc.isUtc,
      'GpxWaypointWriter.build: timeUtc must be a UTC DateTime.',
    );
    final buffer = StringBuffer()
      ..writeln('<?xml version="1.0" encoding="UTF-8"?>')
      ..writeln(
        '<gpx version="1.1" creator="TriTrack" '
        'xmlns="http://www.topografix.com/GPX/1/1">',
      )
      ..writeln('  <wpt lat="$latitude" lon="$longitude">');
    if (elevationMeters != null) {
      buffer.writeln('    <ele>$elevationMeters</ele>');
    }
    buffer.writeln('    <name>${_escape(name)}</name>');
    if (description != null && description.isNotEmpty) {
      buffer.writeln('    <desc>${_escape(description)}</desc>');
    }
    if (timeUtc != null) {
      buffer.writeln('    <time>${timeUtc.toIso8601String()}</time>');
    }
    buffer
      ..writeln('  </wpt>')
      ..writeln('</gpx>');
    return buffer.toString();
  }

  static String _escape(String text) => text
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;')
      .replaceAll("'", '&apos;');
}
