import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart' as ll;
import 'package:url_launcher/url_launcher.dart';

import '../../../core/format/coordinate_formatter.dart';
import 'package:tritrack_sync/tritrack_sync.dart';
import '../../../localization/coordinate_projection.dart';
import '../../../widgets/segmented_toggle.dart';
import '../services/geo_math.dart';
import '../services/tile_fetch_health.dart';
import '../services/tile_sources.dart';
import '../services/scale_bar_math.dart';

/// Shared "map furniture" overlay widgets (design doc "Map Furniture"),
/// factored out of the Main Map so the Position Estimation map presents the
/// same scale bar / north arrow / coordinate readout / legend / measure
/// controls — same code, so the two maps can never visually drift apart.

/// Live GPS coordinate readout in the user's chosen [CoordinateFormat].
class CoordinateReadout extends StatelessWidget {
  const CoordinateReadout({super.key, required this.gps, required this.format});
  final Position? gps;
  final CoordinateFormat format;

  /// The box's own padding, and the text metrics inside it.
  ///
  /// These are `static` rather than literals in [build] because
  /// [MapBottomReadoutColumn.heightFor] measures this widget without building
  /// it, and a second copy of the numbers is a second answer to the same
  /// question (task 11.148).
  static const padding = EdgeInsets.symmetric(horizontal: 6, vertical: 2);
  static const fontSize = 11.0;
  static const fontFamily = 'monospace';

  /// What this widget will print for a given fix — the same string [build]
  /// lays out, so a measurement of it is a measurement of the real words.
  static String textFor(Position? gps, CoordinateFormat format) => gps == null
      ? '—'
      : CoordinateFormatter.format(gps.latitude, gps.longitude, format);

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: isDark ? Colors.black.withValues(alpha: 0.55) : Colors.white.withValues(alpha: 0.85),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        textFor(gps, format),
        style: TextStyle(
          fontFamily: fontFamily,
          fontSize: fontSize,
          color: isDark ? const Color(0xFFF2F2F0) : const Color(0xFF1A1A1A),
        ),
      ),
    );
  }
}

/// The tile provider's required on-screen credit, wrapped rather than clipped.
///
/// Task 11.95: this replaces flutter_map's `SimpleAttributionWidget`, which
/// lays its credit out in one non-wrapping `Row`. With the default Terrain
/// basemap — whose credit string is the long one — that row ran 61 logical
/// pixels off the right-hand edge of a 6.9-inch iPhone. A debug build paints
/// the yellow-and-black overflow stripes over it; a release build silently
/// clips the tail, which is the worse of the two, because showing the credit
/// is a condition of the OpenStreetMap and OpenTopoMap tile licences and a
/// credit running off the edge of the screen is arguably not shown at all.
///
/// Two changes make the whole string fit at phone width. The text wraps to as
/// many lines as it needs, and flutter_map's own `flutter_map | ©` prefix is
/// gone: that prefix is package branding rather than a licence condition, and
/// at the default body text size it was eating roughly a third of the width
/// the licence text needed.
///
/// Deliberately no `maxLines` and no `overflow` — the whole credit is the
/// point, so this takes the height it needs instead of losing its tail. It
/// fills the width it is given, so the caller controls where it wraps by
/// choosing the `Positioned` insets (both maps keep it clear of the
/// bottom-right controls).
/// Task 11.133 item 2 adds the "ⓘ" beside the credit, and it is worth being
/// exact about what that button did and did not buy, because Michael's
/// question was "do we need the map info bars at all?"
///
/// **The answer is yes, and for two of the three basemaps the band does not
/// get any shorter.** Showing the credit is a condition of the tile licences,
/// not decoration. Each provider's terms were read on 2026-09-02 and each got
/// its own verdict; they are recorded on the sources themselves in
/// `tile_sources.dart`, which is where somebody changing a credit will be
/// standing. In short: OpenStreetMap's string is already the shortest form its
/// guidelines name; OpenTopoMap's is ambiguous and therefore stays whole, and
/// OpenTopoMap is the default basemap; only Esri's terms grant a small-screen
/// short form outright.
///
/// What the "ⓘ" is for, then, is not shrinking — it is the *"way to access
/// more information, including origin and licence of the data"* that the OSM
/// attribution guidelines require, and the expandable UI Esri's require. It
/// opens the full credit for the basemap being drawn, with a link to that
/// provider's own licence page, and points at App Info for all three.
class MapAttribution extends StatelessWidget {
  const MapAttribution({super.key, required this.source, this.onShowDetails});

  /// The basemap currently being drawn. Takes the whole source rather than a
  /// string so this widget can tell an abbreviated credit from a complete one
  /// — see [TileSource.isAbbreviated] — instead of the caller deciding.
  final TileSource source;

  /// Opens the full attribution. Null hides the "ⓘ", which is only correct
  /// where the surface genuinely cannot present one; both maps supply it.
  final VoidCallback? onShowDetails;

  /// The width reserved at the right-hand end of the credit line for the
  /// "ⓘ", when there is one.
  static const iconSlot = 22.0;

  /// The credit box's own padding, and the size its text is set at. Shared
  /// with [MapBottomReadoutColumn.heightFor], which has to know how tall this
  /// credit will be *before* it is laid out — the credit wraps, and this
  /// whole task exists because somebody predicted a wrapping sentence once
  /// (task 11.148).
  static const padding = EdgeInsets.fromLTRB(6, 3, 4, 3);
  static const fontSize = 10.0;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final foreground =
        isDark ? const Color(0xFFF2F2F0) : const Color(0xFF1A1A1A);
    // **This widget takes a pointer in exactly one place, and does so itself
    // rather than asking its callers to.**
    //
    // The Main Map's bottom band is wrapped in an `IgnorePointer`, for two
    // reasons that both still hold: a pan starting on the scale bar should pan
    // the map, and task 11.131's bearing tip, dragged out over this band, must
    // still be grabbable to pull it back. A button cannot work inside an
    // `IgnorePointer` — so the credit's own text and backing stay inside one
    // here, and only the "ⓘ" sits outside it, as a `Stack` overlay in a slot
    // the `Row` has already reserved.
    //
    // Doing it here rather than at the call sites is deliberate: there are two
    // maps, and a rule that lives in a widget cannot be got wrong by the
    // second one. The cost is a roughly 22-pixel square at the right-hand end
    // of the credit line that swallows a drag; `bearing_tip_drag_test.dart`
    // holds the handle grabbable, and `map_screen_overlap_test.dart` holds the
    // band clear of the panels.
    return Stack(
      children: [
        IgnorePointer(
          child: Container(
            width: double.infinity,
            padding: padding,
            decoration: BoxDecoration(
              color: isDark
                  ? Colors.black.withValues(alpha: 0.55)
                  : Colors.white.withValues(alpha: 0.85),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    source.onScreenAttribution,
                    softWrap: true,
                    style: TextStyle(fontSize: fontSize, color: foreground),
                  ),
                ),
                if (onShowDetails != null) const SizedBox(width: iconSlot),
              ],
            ),
          ),
        ),
        if (onShowDetails != null)
          Positioned(
            right: 2,
            top: 0,
            bottom: 0,
            width: iconSlot,
            child: Center(
              child: Semantics(
                button: true,
                label: 'Map credit and license',
                child: InkResponse(
                  onTap: onShowDetails,
                  radius: 14,
                  child: Icon(Icons.info_outline, size: 14, color: foreground),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// The full credit for [source], with its provider's own licence page.
///
/// **The credit gets smaller; it never disappears** — this is where the part
/// that is not on the map lives, and it is reachable in one tap from the map
/// and from App Info under More.
Future<void> showMapAttributionSheet(
  BuildContext context,
  TileSource source,
) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (context) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              source.name,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            SelectableText(source.attribution),
            if (source.poweredByCredit != null) ...[
              const SizedBox(height: 6),
              // Task 11.134 item 3. Esri's second, separate credit — allowed
              // by their terms to live behind a button, which is what this
              // sheet is. See TileSource.poweredByCredit for why it is
              // satisfied rather than researched further.
              SelectableText(
                source.poweredByCredit!,
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ],
            const SizedBox(height: 12),
            if (source.attributionUrl != null)
              AttributionLink(
                label: 'License and data sources',
                url: source.attributionUrl!,
              ),
            const SizedBox(height: 4),
            Text(
              'Every basemap requires its credit to stay on screen — a '
              'condition of using the tiles. More › App Info lists them all.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    ),
  );
}

/// What "new map tiles are not arriving" means, one tap behind the band that
/// says it.
///
/// **Task 11.134 item 1.** Shared rather than written into the Main Map,
/// because the counting behind it is process-wide — every live tile in the
/// app is fetched through one provider — so any map that decides to show the
/// band gets the same explanation without a second copy of these words.
Future<void> showTilesNotLoadingSheet(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (context) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              TileFetchHealth.notLoadingMessage,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 12),
            Text(
              TileFetchHealth.notLoadingDetail,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ],
        ),
      ),
    ),
  );
}

/// A small card over a map saying one thing the map itself cannot.
///
/// **Task 11.135 lifted this out of `map_screen.dart`**, where it was the
/// private `_NothingToShowBanner`. It moved because a second, third and
/// fourth map now need the *same* sentence — "new map tiles are not
/// arriving" — and this project's rule is that a shape repeated at several
/// call sites is a shape that drifts at several call sites. One widget, so
/// five maps cannot end up saying the same thing four different ways.
///
/// Deliberately not sized: it takes the width its parent gives it and the
/// height its text needs, so a caller that stacks it in a column pays exactly
/// what it costs and a screen-space budget can measure it.
class MapNoticeBanner extends StatelessWidget {
  const MapNoticeBanner({
    super.key,
    required this.message,
    this.bannerKey = const ValueKey('map-nothing-to-show'),
    this.icon = Icons.location_off_outlined,
    this.onTap,
  });

  final String message;
  final ValueKey<String> bannerKey;
  final IconData icon;

  /// Where the rest of the sentence lives, when there is more than fits.
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final card = Container(
      key: bannerKey,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(10),
        boxShadow: const [
          BoxShadow(color: Colors.black26, blurRadius: 6, offset: Offset(0, 2)),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: scheme.onSurfaceVariant),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              message,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
          if (onTap != null) ...[
            const SizedBox(width: 6),
            Icon(Icons.info_outline, size: 14, color: scheme.onSurfaceVariant),
          ],
        ],
      ),
    );
    final handler = onTap;
    if (handler == null) return card;
    return InkWell(
      onTap: handler,
      borderRadius: BorderRadius.circular(10),
      child: card,
    );
  }
}

/// "New map tiles are not arriving", on whichever map chooses to say it —
/// and nothing at all the rest of the time.
///
/// **Task 11.134 built the signal and connected one screen; task 11.135
/// decided the other five one at a time.** The verdicts, with what each one
/// measured, are in that task's entry and repeated on each screen beside the
/// call (or beside the deliberate absence of one). What is shared is this:
/// the band listens to the process-wide [TileFetchHealth] rather than to any
/// per-screen counter, costs nothing while tiles are arriving or while the
/// region is fully cached — a cache hit is reported as neither outcome — and
/// keeps the same words and the same one-tap explanation everywhere.
///
/// **The key is per screen, supplied by the caller**, because each screen's
/// space-budget test has to find its own band.
class TilesNotLoadingBand extends StatelessWidget {
  const TilesNotLoadingBand({
    super.key,
    required this.bannerKey,
    this.padding = EdgeInsets.zero,
  });

  final ValueKey<String> bannerKey;

  /// Spacing that appears **only when the band does**, so a caller stacking
  /// it in a column does not pay a gap on the ordinary day when tiles are
  /// arriving and this widget occupies nothing.
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: TileFetchHealth.instance.failing,
      builder: (context, failing, _) => failing
          ? Padding(
              padding: padding,
              child: MapNoticeBanner(
                bannerKey: bannerKey,
                icon: Icons.cloud_off_outlined,
                message: TileFetchHealth.notLoadingMessage,
                onTap: () => showTilesNotLoadingSheet(context),
              ),
            )
          : const SizedBox.shrink(),
    );
  }
}

/// A provider's licence page, opened in the browser.
///
/// **Says so when it cannot open**, rather than doing nothing. A dead link in
/// an attribution block is not a cosmetic failure: *"there needs to be a way
/// to access more information, including origin and licence of the data"* is
/// a condition of the OpenStreetMap tile licence, and a button that silently
/// does nothing is not a way. The URL is shown either way, so somebody can
/// always type it.
class AttributionLink extends StatelessWidget {
  const AttributionLink({super.key, required this.label, required this.url});
  final String label;
  final String url;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: TextButton.icon(
        icon: const Icon(Icons.open_in_new, size: 16),
        label: Text(label),
        onPressed: () async {
          final messenger = ScaffoldMessenger.maybeOf(context);
          var opened = false;
          try {
            opened = await launchUrl(
              Uri.parse(url),
              mode: LaunchMode.externalApplication,
            );
          } catch (_) {
            opened = false;
          }
          if (!opened) {
            messenger?.showSnackBar(
              SnackBar(
                content: Text('Could not open a browser. The address is $url'),
              ),
            );
          }
        },
      ),
    );
  }
}

/// Cartographic scale bar. Pure meters-per-pixel math lives in [ScaleBarMath]
/// so it's unit-testable without a live map; this just renders bracket + label.
class MapScaleBar extends StatelessWidget {
  const MapScaleBar({super.key, required this.latitude, required this.zoom});
  final double latitude;
  final double zoom;

  /// The bracket drawn above the label, the gap under it, and the label box's
  /// own padding and text size. Shared with
  /// [MapBottomReadoutColumn.heightFor] rather than written twice (task
  /// 11.148): the bracket is a fixed number of pixels, the label is not.
  static const bracketHeight = 5.0;
  static const bracketToLabelGap = 2.0;
  static const labelPadding = EdgeInsets.symmetric(horizontal: 4, vertical: 1);
  static const fontSize = 10.0;

  @override
  Widget build(BuildContext context) {
    final spec = ScaleBarMath.pick(latitudeDeg: latitude, zoom: zoom);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final lineColor = isDark ? Colors.white : Colors.black;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: spec.pixelWidth,
          height: bracketHeight,
          decoration: BoxDecoration(
            border: Border(
              left: BorderSide(color: lineColor, width: 1.5),
              right: BorderSide(color: lineColor, width: 1.5),
              bottom: BorderSide(color: lineColor, width: 1.5),
            ),
          ),
        ),
        const SizedBox(height: bracketToLabelGap),
        Container(
          padding: labelPadding,
          decoration: BoxDecoration(
            color: isDark ? Colors.black.withValues(alpha: 0.55) : Colors.white.withValues(alpha: 0.85),
            borderRadius: BorderRadius.circular(3),
          ),
          child: Text(
            spec.label,
            style: TextStyle(fontSize: fontSize, color: isDark ? Colors.white : Colors.black),
          ),
        ),
      ],
    );
  }
}

/// The bottom-left readout column: the scale bar and the live coordinate
/// readout sharing one line, with the map-source credit under them.
///
/// **This widget exists so that the height of the column and the drawing of
/// the column are one thing** (task 11.148). The Position screen has to
/// reserve room for this column *before* it lays the map out — the map/panel
/// split is computed from that reservation — and until this task the
/// reservation was the constant `94`. That number was measured once, at the
/// default system text size, and the column is text: at xLarge, the first
/// notch above the default, the band of map with nothing drawn over it fell
/// to 93 logical pixels against a floor of 96, and at xxxLarge to 62, while
/// the map's own height never moved. The reservation was wrong and nothing
/// could tell, because the column simply grew upward over the map.
///
/// **Scaling the constant by the text scaler would not have fixed it**, and
/// task 11.147 measured why: the credit does not grow smoothly, it gains a
/// whole line, at a width nobody can predict. `94 * textScaler` is still a
/// prediction about wrapping text — it happens to over-reserve at some sizes
/// and under-reserve at others. So [heightFor] lays the real strings out at
/// the real width and the real text size and reports what it gets, the way
/// `DisabledReasonNote.heightFor` does.
///
/// **The Main Map's bottom band is deliberately not this widget.** It stacks
/// its three pieces rather than sharing a line, and it wraps the two
/// output-only ones in an `IgnorePointer` so a pan starting on the scale bar
/// pans the map — see `map_screen.dart`. It also has nothing to reserve
/// against: its map fills the screen, so its furniture floats over the map
/// instead of being budgeted out of it, and its clear band already holds
/// across the whole ordinary text-size slider. Sharing this widget would
/// have meant changing a screen that is not broken.
class MapBottomReadoutColumn extends StatelessWidget {
  const MapBottomReadoutColumn({
    super.key,
    required this.latitude,
    required this.zoom,
    required this.gps,
    required this.format,
    required this.source,
    this.onShowAttributionDetails,
  });

  /// Camera position, for the scale bar's "nice round distance" pick.
  final double latitude;
  final double zoom;

  /// The live fix, for the coordinate readout. Null renders an em dash.
  final Position? gps;
  final CoordinateFormat format;

  /// The basemap being drawn, whose credit is a licence condition.
  final TileSource source;
  final VoidCallback? onShowAttributionDetails;

  /// The gap between the scale bar and the coordinate readout on the top
  /// line, and between that line and the credit under it.
  static const _rowGap = 10.0;
  static const _lineGap = 6.0;

  /// **How tall this column will be at [maxWidth], at this context's system
  /// text size.**
  ///
  /// Every string it lays out is the one [build] renders, and every metric it
  /// uses is the `static` the corresponding widget builds itself from — so
  /// the answer cannot drift from the thing it is about without the widget
  /// failing to compile.
  ///
  /// [maxWidth] is the width the column is laid out in, which is what decides
  /// where the credit wraps.
  static double heightFor(
    BuildContext context, {
    required double maxWidth,
    required double latitude,
    required double zoom,
    required Position? gps,
    required CoordinateFormat format,
    required TileSource source,
    bool hasAttributionDetails = true,
  }) {
    final scaler = MediaQuery.textScalerOf(context);
    final direction = Directionality.of(context);
    // **The ambient default is part of the answer.** A `Text` merges its own
    // style onto `DefaultTextStyle`, so its font family, line height and
    // leading come from the theme — measuring the bare `TextStyle` written at
    // the call site below understated every line by a few pixels, and the
    // credit by a few pixels a line.
    final base = DefaultTextStyle.of(context).style;

    Size measure(String text, TextStyle style, double width) {
      final painter = TextPainter(
        text: TextSpan(text: text, style: base.merge(style)),
        textDirection: direction,
        textScaler: scaler,
      )..layout(maxWidth: math.max(0, width));
      final size = Size(painter.width, painter.height);
      painter.dispose();
      return size;
    }

    // The scale bar. Its bracket is a fixed pixel width, but its label box can
    // be wider than the bracket once the text is scaled up, and it is the
    // wider of the two that pushes the coordinate readout along.
    final spec = ScaleBarMath.pick(latitudeDeg: latitude, zoom: zoom);
    final label = measure(
      spec.label,
      const TextStyle(fontSize: MapScaleBar.fontSize),
      double.infinity,
    );
    final scaleBarWidth = math.max(
      spec.pixelWidth,
      label.width + MapScaleBar.labelPadding.horizontal,
    );
    final scaleBarHeight = MapScaleBar.bracketHeight +
        MapScaleBar.bracketToLabelGap +
        MapScaleBar.labelPadding.vertical +
        label.height;

    // The coordinate readout takes what the scale bar leaves. It is `Flexible`
    // in the row, so at a large enough text size it wraps rather than
    // overflowing — which is exactly the case a constant cannot see.
    final readoutWidth =
        maxWidth - scaleBarWidth - _rowGap - CoordinateReadout.padding.horizontal;
    final readout = measure(
      CoordinateReadout.textFor(gps, format),
      const TextStyle(
        fontSize: CoordinateReadout.fontSize,
        fontFamily: CoordinateReadout.fontFamily,
      ),
      readoutWidth,
    );
    final readoutHeight = CoordinateReadout.padding.vertical + readout.height;

    // The credit, which wraps to as many lines as it needs and is the reason
    // this function exists.
    final creditWidth = maxWidth -
        MapAttribution.padding.horizontal -
        (hasAttributionDetails ? MapAttribution.iconSlot : 0);
    final credit = measure(
      source.onScreenAttribution,
      const TextStyle(fontSize: MapAttribution.fontSize),
      creditWidth,
    );
    final creditHeight = MapAttribution.padding.vertical + credit.height;

    return math.max(scaleBarHeight, readoutHeight) + _lineGap + creditHeight;
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        // The scale bar and the coordinate readout share one line: both are
        // short, neither needs the width, and stacking them cost the map a
        // whole row it could not spare. The credit keeps its own full-width
        // line — it wraps, and wrapping is the point (task 11.95).
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            MapScaleBar(latitude: latitude, zoom: zoom),
            const SizedBox(width: _rowGap),
            Flexible(child: CoordinateReadout(gps: gps, format: format)),
          ],
        ),
        const SizedBox(height: _lineGap),
        MapAttribution(source: source, onShowDetails: onShowAttributionDetails),
      ],
    );
  }
}

/// A north-pointing arrow that counter-rotates against the map's own rotation
/// so it always genuinely points true north. Tapping resets orientation to
/// north-up (caller wires [onTap] to [MapController.rotate]).
class MapNorthArrow extends StatelessWidget {
  const MapNorthArrow({super.key, required this.rotationDeg, required this.onTap});
  final double rotationDeg;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final color = isDark ? Colors.white : Colors.black;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 28,
        height: 28,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: isDark ? Colors.black.withValues(alpha: 0.55) : Colors.white.withValues(alpha: 0.85),
        ),
        child: Transform.rotate(
          angle: -rotationDeg * math.pi / 180.0,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.arrow_upward, size: 14, color: color),
              // Part of the glyph, inside a fixed 28-pixel circle, so it does
              // not grow with the text size — the `Icon` above it does not
              // either (task 11.315; the Record pencil's reason, task 11.139).
              // Left scaling, the two stopped fitting the circle at xxxLarge.
              Text(
                'N',
                textScaler: TextScaler.noScaling,
                style: TextStyle(fontSize: 8, fontWeight: FontWeight.w800, color: color),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Color/shape legend. Rows are supplied by the caller (Main Map and Position
/// Estimation show different layers) but the colors always come from
/// `TriTrackColors` so a legend can never drift from what's actually drawn.
class MapLegendCard extends StatelessWidget {
  const MapLegendCard({super.key, required this.rows, this.footnote});

  /// (swatch color, label) pairs, top to bottom.
  final List<(Color, String)> rows;

  /// One line of "and here is what you can do with these", shown under the
  /// swatches. **This is where a screen's onboarding copy goes** (task
  /// 11.110): a sentence teaching a gesture is read once and then costs the
  /// map its space forever, so it belongs behind the legend button — which
  /// is the control a person already presses to ask what they are looking
  /// at — rather than in a permanent band over the map.
  final String? footnote;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final textColor = isDark ? Colors.white : Colors.black;
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: isDark ? Colors.black.withValues(alpha: 0.75) : Colors.white.withValues(alpha: 0.92),
        borderRadius: BorderRadius.circular(8),
        boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 6, offset: Offset(0, 2))],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final (color, label) in rows)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(width: 12, height: 12, color: color),
                  const SizedBox(width: 6),
                  Text(label, style: TextStyle(fontSize: 11, color: textColor)),
                ],
              ),
            ),
          if (footnote != null) ...[
            const SizedBox(height: 4),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 180),
              child: Text(
                footnote!,
                style: TextStyle(
                  fontSize: 11,
                  color: textColor.withValues(alpha: 0.75),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Toggle button for measure mode.
///
/// Task 11.94/11.101 exemption: this and the round map buttons below (legend,
/// clear) are labelled only by `tooltip:`, which a touchscreen never shows.
/// Left as-is rather than redesigned: each is a non-destructive, reversible
/// toggle or dismiss with no consequence beyond re-tapping it, none sits
/// beside a destructive twin, and this is exactly the map-furniture cluster
/// task 11.109/11.133 have already spent a budget fighting to keep small —
/// adding visible text labels here is the crowding problem those tasks fixed,
/// reintroduced. If a specific one of these turns out to be genuinely
/// undiscoverable in practice, fix that one rather than labelling the row.
class MeasureButton extends StatelessWidget {
  const MeasureButton({super.key, required this.active, required this.onPressed});
  final bool active;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: active ? scheme.primary : scheme.surface,
        borderRadius: BorderRadius.circular(10),
        boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 6, offset: Offset(0, 2))],
      ),
      child: IconButton(
        tooltip: active ? 'Tap two map points to measure' : 'Measure distance & bearing',
        icon: Icon(Icons.straighten, color: active ? scheme.onPrimary : null),
        onPressed: onPressed,
      ),
    );
  }
}

/// Toggle button for the map legend overlay.
class MapLegendButton extends StatelessWidget {
  const MapLegendButton({super.key, required this.active, required this.onPressed});
  final bool active;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: active ? scheme.primary : scheme.surface,
        borderRadius: BorderRadius.circular(10),
        boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 6, offset: Offset(0, 2))],
      ),
      child: IconButton(
        tooltip: 'Map legend',
        icon: Icon(Icons.info_outline, color: active ? scheme.onPrimary : null),
        onPressed: onPressed,
      ),
    );
  }
}

/// Toggle button for the map-type (layers) panel (task 11.203). Built to the
/// same shape as [MapLegendButton] beside it, on purpose — same rounded
/// square, same shadow, same active fill.
class MapLayersButton extends StatelessWidget {
  const MapLayersButton({super.key, required this.active, required this.onPressed});
  final bool active;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: active ? scheme.primary : scheme.surface,
        borderRadius: BorderRadius.circular(10),
        boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 6, offset: Offset(0, 2))],
      ),
      child: IconButton(
        tooltip: 'Map type',
        icon: Icon(Icons.layers_outlined, color: active ? scheme.onPrimary : null),
        onPressed: onPressed,
      ),
    );
  }
}

/// Distance + bearing readout between two tapped points (or a prompt to tap a
/// second point). Calls the shared spherical [distanceAndBearing] math.
class MeasureResultCard extends StatelessWidget {
  const MeasureResultCard({super.key, required this.points, required this.onClear});
  final List<ll.LatLng> points;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final String text;
    if (points.length < 2) {
      text = 'Tap a second point to measure';
    } else {
      final result = distanceAndBearing(
        GeoPoint(points[0].latitude, points[0].longitude),
        GeoPoint(points[1].latitude, points[1].longitude),
      );
      final distanceLabel = result.distanceMeters >= 1000
          ? '${(result.distanceMeters / 1000).toStringAsFixed(2)} km'
          : '${result.distanceMeters.toStringAsFixed(0)} m';
      text = '$distanceLabel · ${result.bearingDeg.toStringAsFixed(0)}°';
    }
    return Material(
      color: Theme.of(context).colorScheme.surface,
      elevation: 3,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.straighten, size: 16),
            const SizedBox(width: 8),
            Text(text, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 12)),
            const SizedBox(width: 4),
            IconButton(
              icon: const Icon(Icons.close, size: 16),
              tooltip: 'Clear measurement',
              onPressed: onClear,
              visualDensity: VisualDensity.compact,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(),
            ),
          ],
        ),
      ),
    );
  }
}

/// **DECISION, Michael, 2026-09-30 — do not "fix" this toggle's legibility.**
/// Task 11.319 measured the unselected labels at 1.7–2.7 : 1 against real
/// map tiles and replaced the blurred halo below with an opaque outline.
/// **Michael rejected it: the outline hides the map, and a person already
/// knows the three options, so the labels do not need to be readable on
/// their own — the selected one is filled green.** It was put back as it
/// was. This is the second time a task has tried to make these labels more
/// legible (task 11.106 added a panel; 11.190 removed it at his request), and
/// both were unwanted. A contrast number under 4.5 : 1 here is **not** a
/// defect to file.
///
/// The Main Map's floating map-type selector (task 11.190), factored out so
/// *Take on map* (task 11.317) can put the same control, backed by the same
/// `selectedTileCategoryProvider`, on its own screen — one setting, changed
/// from either screen, rather than a second control that could drift from
/// this one.
///
/// A blurred, darkened silhouette of the toggle sits behind the real one (a
/// "halo") so the unselected labels stay legible directly over the map, with
/// no background panel: `ColorFiltered` flattens a duplicate of the toggle
/// to a solid dark shape, `ImageFiltered` blurs it, and the real toggle sits
/// on top. The unselected labels' own color follows which basemap is
/// showing: white over terrain/street, `onSurface` (dark) over satellite.
class MapTypeToggle extends StatelessWidget {
  const MapTypeToggle({super.key, required this.category, required this.onChanged});

  final TileCategory category;
  final ValueChanged<TileCategory> onChanged;

  @override
  Widget build(BuildContext context) {
    final toggle = SegmentedToggle<TileCategory>(
      height: 34,
      options: const [
        (TileCategory.terrain, 'Terrain'),
        (TileCategory.street, 'Street'),
        (TileCategory.satellite, 'Satellite'),
      ],
      selected: category,
      onChanged: onChanged,
    );
    final unselectedLabelColor = switch (category) {
      TileCategory.satellite => null,
      TileCategory.terrain || TileCategory.street => Colors.white,
    };
    final topToggle = unselectedLabelColor == null
        ? toggle
        : Theme(
            data: Theme.of(context).copyWith(
              colorScheme: Theme.of(context).colorScheme.copyWith(
                onSurface: unselectedLabelColor,
              ),
            ),
            child: toggle,
          );
    return Stack(
      children: [
        Positioned.fill(
          child: IgnorePointer(
            child: ImageFiltered(
              imageFilter: ui.ImageFilter.blur(sigmaX: 2.5, sigmaY: 2.5),
              child: ColorFiltered(
                colorFilter: const ColorFilter.mode(Colors.black54, BlendMode.srcIn),
                child: toggle,
              ),
            ),
          ),
        ),
        topToggle,
      ],
    );
  }
}
