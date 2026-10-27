/// Colorblind-safe palette tags are auto-assigned from on creation (Phase 4,
/// "Tag Color Coding"). Okabe-Ito based, with two entries darkened for
/// legibility as a filled map marker rather than pure Okabe-Ito hues: `gold`
/// instead of yellow, and `dark gray` instead of black (so it doesn't read as
/// the default UI text/icon color).
///
/// This is the single source of truth for the palette — the schema migration
/// backfill and the tag-creation auto-assign logic both go through
/// [colorForIndex]/[nextColor] so the list can't drift between the two call
/// sites.
abstract final class TagColorPalette {
  static const List<String> colors = [
    '#E69F00', // orange
    '#56B4E9', // sky blue
    '#009E73', // bluish green
    '#D55E00', // vermillion
    '#0072B2', // blue
    '#CC79A7', // reddish purple
    '#C9A227', // gold
    '#E4298C', // magenta
    '#017374', // teal
    '#8B4513', // brown
    '#4D4D4D', // dark gray
    '#6B8E23', // olive
  ];

  /// [colors] first entry, as a standalone constant — `colors[0]` isn't a
  /// valid constant expression in Dart, but callers (e.g. test fixtures)
  /// sometimes need a compile-time-constant default color.
  static const String defaultColor = '#E69F00';

  /// What a collar with **no individual** draws in (task 11.240).
  ///
  /// A rendering constant, not a stored value and not a fallback to
  /// `Tags.color_hex` — that column is retired and read by nothing. Colour is
  /// the animal's, so a transmitter nobody has said the animal for has no
  /// colour of its own; this neutral grey is deliberately outside [colors] so
  /// it cannot be mistaken for an assigned one on a map legend.
  static const String noIndividual = '#9E9E9E';

  static final RegExp hexPattern = RegExp(r'^#[0-9A-Fa-f]{6}$');

  static bool isValidHex(String value) => hexPattern.hasMatch(value);

  /// The palette color at round-robin position [index], wrapping after
  /// [colors.length].
  static String colorForIndex(int index) => colors[index % colors.length];

  /// The next unused color given [existingTagCount] tags already assigned a
  /// color, round-robin. Callers pass the count of tags created so far (in
  /// creation order) so consecutive tag creations get distinct colors.
  static String nextColor(int existingTagCount) =>
      colorForIndex(existingTagCount);
}
