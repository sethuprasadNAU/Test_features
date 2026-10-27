/// The URI "Open in Maps" hands to the platform for a map coordinate — task
/// 11.209. Pure and platform-check-free (the caller passes [isAndroid]) so
/// both destinations are assertable without a device.
abstract final class MapHandoff {
  /// A `geo:` URI on Android — opening it shows the OS chooser, which is how
  /// a point reaches Gaia or Avenza without a second menu entry in this app.
  /// An Apple Maps `https://maps.apple.com` URL everywhere else, per Apple's
  /// documented URL scheme.
  ///
  /// [label] becomes the pin's name where given; both schemes accept a bare
  /// coordinate with none (a free-tapped point has no label to give it).
  static Uri uriFor(
    double latitude,
    double longitude, {
    String? label,
    required bool isAndroid,
  }) {
    if (isAndroid) {
      final query = label == null
          ? '$latitude,$longitude'
          : '$latitude,$longitude(${Uri.encodeComponent(label)})';
      return Uri.parse('geo:$latitude,$longitude?q=$query');
    }
    return Uri.https('maps.apple.com', '/', {
      'll': '$latitude,$longitude',
      'q': ?label,
    });
  }
}
