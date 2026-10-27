import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart' as ll;

import '../../../core/providers/gps_provider.dart';
import '../../../localization/coordinate_projection.dart';
import '../../../viewshed/dem_tile_store.dart';
import '../../../viewshed/elevation_grid.dart';
import '../services/geo_math.dart';
import '../services/terrain_profile.dart';

/// **What the panel says when the DEM has no tiles here at all.** The same
/// sentence the viewshed uses for the same fact — one vocabulary for "we did
/// not download the ground you are standing on", not two.
const String kNoElevationDataMessage =
    'No elevation data downloaded for this area.';

/// **What it says when only part of the line has elevation.** The totals are
/// still shown, because a climb summed over the parts that have data is
/// genuinely useful to somebody who knows that is what it is — and a total
/// quietly summed over half a line, presented as the whole, is the same
/// under-reporting defect [TerrainProfile] exists to prevent.
/// **What it says before the first fix arrives**, when it is following one.
const String kWaitingForFixMessage = 'Waiting for a position fix.';

const String kPartialElevationProfileMessage =
    'Part of this line has no elevation data, so the climb and descent are '
    'only for the parts that do.';

/// A drag-resizable panel over the map showing the straight line between two
/// points: distance, bearing, total climb and total descent in the header,
/// and the terrain profile as a chart in the body.
///
/// **One panel, two callers.** The measure tool mounts it over two tapped
/// points; navigation mounts it over the live fix and the target, where it
/// replaces the grey banner that used to carry the same numbers. They are one
/// widget deliberately: two copies of this chart would drift within a month
/// and the climb number would then be right in one of them.
///
/// Collapsed it is a single row — the numbers and [action] — and that row is
/// the whole panel, so it is the one that has to hold everything; the label
/// ellipsises before anything else gives way. Dragging it up brings the chart.
///
/// ## Following a person as they walk (task 11.207)
///
/// With [origin] null the panel takes its start point from the live GPS fix,
/// which makes it **the first thing in this app that recomputes because a
/// person moved** rather than because somebody tapped. Three containments,
/// and they are the whole design:
///
/// 1. **It works only while the app is in the foreground.** The position
///    subscription is held only while the lifecycle state is `resumed` and is
///    dropped otherwise, so a phone in a pocket does no work here at all.
///    **No background location permission is introduced by this and none is
///    wanted** — the workflow is look, decide, pocket the phone, walk, check
///    once or twice. The next person here will be tempted to make this follow
///    somebody with the screen off; that is a different app.
/// 2. **The expensive half only runs when it is being looked at.** Distance
///    and bearing are arithmetic on two coordinates and are updated on every
///    fix, collapsed or not — they are what people actually check. The
///    profile is sampled once when the first fix arrives, so the collapsed
///    row has its climb and descent, and after that it is **re-sampled only
///    while the panel is open**, and only once the person has moved further
///    than [_movementThresholdMeters], which is
///    `max(10 m, this fix's own reported accuracy)`: a flat 10 m redraws
///    forever on a phone standing still, because 10 m is roughly what GPS
///    noise is.
/// 3. **Walking out of downloaded terrain is expected here**, far more than
///    on the measure tool. The chart says so and the distance and bearing
///    carry on unaffected — losing the graph must not lose the navigation.
///
/// **What this does not control.** The GPS stream itself is
/// `gpsPositionProvider`, which the Main Map already watches for its own
/// location marker; dropping this subscription stops *this panel's* work, not
/// the OS's fixes. Pausing the stream itself while the app is backgrounded is
/// a separate, unwired concern recorded in `gps_provider.dart`.
class ElevationProfilePanel extends ConsumerStatefulWidget {
  const ElevationProfilePanel({
    super.key,
    required this.destination,
    required this.origin,
    required this.icon,
    required this.action,
    required this.lineColor,
    this.label,
    this.initiallyCollapsed = false,
  });

  /// The fixed end of the line.
  final ll.LatLng destination;

  /// The other end, or **null to follow the live GPS fix** — see the class
  /// doc for what that does and does not do.
  final ll.LatLng? origin;

  /// Leading icon for the header row.
  final IconData icon;

  /// **The colour of the line this is a profile of, as it is drawn on the
  /// map** — the navigation blue for navigation, the measure tool's own
  /// stroke for the measure tool, with the ground under the trace shaded in
  /// the same colour.
  ///
  /// It is a parameter rather than a theme lookup because that is the whole
  /// rule: *the graph is drawn in the colour of the line it is about.* It was
  /// `ColorScheme.primary` — the brand green — at both call sites, which is a
  /// colour nobody chose, matching nothing on the map, on a panel whose only
  /// subject is one line that is right there in a different colour.
  final Color lineColor;

  /// The panel's one action — Clear for the measure tool, Stop for
  /// navigation. Always reachable, including while collapsed.
  final Widget action;

  /// Optional text before the numbers, e.g. the navigation target's name.
  /// Ellipsises first when the row runs out of width.
  final String? label;

  /// Whether to open collapsed (navigation, where the row replaces a banner)
  /// or at the default height (the measure tool, where the chart is why the
  /// panel appeared).
  final bool initiallyCollapsed;

  @override
  ConsumerState<ElevationProfilePanel> createState() =>
      _ElevationProfilePanelState();
}

class _ElevationProfilePanelState extends ConsumerState<ElevationProfilePanel>
    with WidgetsBindingObserver {
  static const _defaultFraction = 0.20;
  static const _minFraction = 0.10;
  static const _maxFraction = 0.45;
  static const _handleFraction = 0.045;

  /// **The floor under "has this person moved?".** A fix's reported accuracy
  /// is used when it is worse than this; below it, this wins. A phone lying
  /// still on a table reports positions that wander by roughly this much, so
  /// a smaller number is a redraw on every fix forever.
  static const double _movementThresholdMeters = 10.0;

  double _heightFraction = _defaultFraction;

  ElevationGrid? _dem;
  bool _loadingDem = true;

  /// The sampled line, or null while it is being worked out / when there is
  /// no elevation data for it.
  TerrainProfile? _profile;

  /// The origin the current [_profile] was sampled from — which is not the
  /// current origin once somebody has walked away from it.
  ll.LatLng? _profileOrigin;

  /// The latest fix, when this panel follows one.
  ll.LatLng? _liveOrigin;

  ProviderSubscription<AsyncValue<Position>>? _gpsSubscription;

  /// Guards against an older DEM load finishing after a newer one.
  int _loadToken = 0;

  bool get _followsPosition => widget.origin == null;

  ll.LatLng? get _origin => widget.origin ?? _liveOrigin;

  bool get _collapsed => _heightFraction <= _handleFraction + 0.005;

  @override
  void initState() {
    super.initState();
    if (widget.initiallyCollapsed) _heightFraction = _handleFraction;
    if (_followsPosition) {
      WidgetsBinding.instance.addObserver(this);
      // A test binding reports no lifecycle state until one is dispatched;
      // an app that is on screen is resumed. Treating "not told yet" as
      // paused would leave the panel dead on arrival.
      final state = WidgetsBinding.instance.lifecycleState;
      if (state == null || state == AppLifecycleState.resumed) {
        _subscribeToPosition();
      }
    }
    unawaited(_refresh());
  }

  @override
  void dispose() {
    if (_followsPosition) WidgetsBinding.instance.removeObserver(this);
    _gpsSubscription?.close();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant ElevationProfilePanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.destination != widget.destination ||
        oldWidget.origin != widget.origin) {
      unawaited(_refresh());
    }
  }

  // ---------------------------------------------------------------------
  // Following a fix — see the class doc for why each of these is here.
  // ---------------------------------------------------------------------

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!_followsPosition) return;
    if (state == AppLifecycleState.resumed) {
      _subscribeToPosition();
    } else {
      // inactive, hidden, paused, detached: the app is not in front of
      // anybody, so nothing here needs to be true.
      _gpsSubscription?.close();
      _gpsSubscription = null;
    }
  }

  void _subscribeToPosition() {
    if (_gpsSubscription != null) return;
    _gpsSubscription = ref.listenManual(
      gpsPositionProvider,
      (_, next) {
        final fix = next.value;
        if (fix != null) _onFix(fix);
      },
      fireImmediately: true,
    );
  }

  void _onFix(Position fix) {
    if (!mounted) return;
    // The cheap half: distance and bearing are two coordinates and a
    // formula, and they are what somebody glances at. They move on every fix,
    // open or shut.
    setState(() => _liveOrigin = ll.LatLng(fix.latitude, fix.longitude));

    // **The first fix is sampled whatever the state**, because the collapsed
    // row carries the climb and descent too — that row is the whole panel
    // when it is shut, and a row with a blank where a number goes is worse
    // than a row without the number. After that, a shut panel does not
    // re-sample: the graph is the expensive half and nobody is looking at it.
    if (_collapsed && _profileOrigin != null) return;
    final since = _profileOrigin;
    if (since != null) {
      final moved = const ll.Distance().as(
        ll.LengthUnit.Meter,
        since,
        ll.LatLng(fix.latitude, fix.longitude),
      );
      final threshold = math.max(
        _movementThresholdMeters,
        fix.accuracy.isFinite ? fix.accuracy : 0.0,
      );
      if (moved < threshold) return;
    }
    unawaited(_refresh());
  }

  // ---------------------------------------------------------------------
  // Sampling
  // ---------------------------------------------------------------------

  /// Loads whatever DEM this line needs (only when the one in hand does not
  /// cover it) and re-samples the profile.
  Future<void> _refresh() async {
    final origin = _origin;
    if (origin == null) return;
    final destination = widget.destination;

    var dem = _dem;
    final covered = dem != null &&
        dem.contains(origin.latitude, origin.longitude) &&
        dem.contains(destination.latitude, destination.longitude);
    if (!covered) {
      final token = ++_loadToken;
      if (!_loadingDem) setState(() => _loadingDem = true);
      dem = await DemTileStore().composeForBounds(
        minLat: math.min(origin.latitude, destination.latitude),
        minLon: math.min(origin.longitude, destination.longitude),
        maxLat: math.max(origin.latitude, destination.latitude),
        maxLon: math.max(origin.longitude, destination.longitude),
      );
      // A fix that arrived while this was reading tiles has already started a
      // newer load; this one's answer is about a place the person has left.
      if (!mounted || token != _loadToken) return;
    }

    // Re-read the origin: it may have moved while the tiles were being read.
    final now = _origin ?? origin;
    setState(() {
      _dem = dem;
      _loadingDem = false;
      _profileOrigin = now;
      _profile = dem == null
          ? null
          : sampleTerrainProfile(
              from: GeoPoint(now.latitude, now.longitude),
              to: GeoPoint(destination.latitude, destination.longitude),
              grid: dem,
            );
    });
  }

  // ---------------------------------------------------------------------
  // Layout
  // ---------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final screenHeight = MediaQuery.of(context).size.height;
    final collapsed = _collapsed;
    final origin = _origin;

    final line = origin == null
        ? null
        : distanceAndBearing(
            GeoPoint(origin.latitude, origin.longitude),
            GeoPoint(widget.destination.latitude, widget.destination.longitude),
          );
    final numbers = line == null
        ? 'Waiting for a position fix'  // the header's short form
        : '${formatDistanceMeters(line.distanceMeters)} · '
            '${line.bearingDeg.toStringAsFixed(0)}°';
    final label = widget.label;
    final profile = _profile;
    final relief = profile == null
        ? ''
        : ' · \u2191${profile.ascentMeters.round()} m '
            '\u2193${profile.descentMeters.round()} m';

    // **One run of text, not four widgets in a row.** This row *is* the
    // collapsed panel, so it is the one that has to hold everything, and a
    // row of separate children overflows at the accessibility text sizes.
    // One `Text` cannot, at any size and however long a target's name is.
    //
    // **It wraps to a second line rather than hiding what it cannot fit**,
    // which is the fix for what Michael found walking with it — see the
    // layout note below. **The cap is two lines and the number is measured
    // rather than chosen:** with no cap at all the map's clear band fell from
    // 289 to 201 logical pixels at AX3 and from 195 to **37** at AX4, against
    // a floor of 96, because a bar at 2.76× text takes four or five lines off
    // the bottom of the map. At two lines every number on that ladder is
    // exactly what it was before this row could wrap — the wrapping is free —
    // and an ordinary target name is shown whole on any phone. See
    // `map_screen_space_budget_test.dart`.
    //
    // **The arrows are shorthand, and the words are in the accessibility
    // label rather than lost.** Nothing here is carried by colour: this app's
    // rule is that colour accelerates a meaning and never is one, and there
    // is no legend on this panel to teach one.
    final header = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10),
      child: Row(
        children: [
          Icon(widget.icon, size: 16),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              '${label == null ? '' : '$label · '}$numbers$relief',
              style: const TextStyle(
                fontWeight: FontWeight.w700,
                fontSize: 12,
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              semanticsLabel: [
                ?label,
                if (line != null) ...[
                  formatDistanceMeters(line.distanceMeters),
                  'bearing ${line.bearingDeg.toStringAsFixed(0)} degrees',
                ] else
                  numbers,
                if (profile != null) ...[
                  'total climb ${profile.ascentMeters.round()} meters',
                  'total descent ${profile.descentMeters.round()} meters',
                  if (profile.hasGaps)
                    'over the parts of the line with elevation data',
                ],
              ].join(', '),
            ),
          ),
          widget.action,
        ],
      ),
    );

    final handle = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const SizedBox(height: 6),
        Container(
          width: 36,
          height: 4,
          decoration: BoxDecoration(
            color: scheme.outline,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        const SizedBox(height: 6),
      ],
    );

    // **The panel is its header plus its chart, and the drag sizes the
    // chart** — the header is never given a fixed share of anything.
    //
    // It was the other way round until Michael walked with it: the panel took
    // a fraction of the screen and the header was squeezed into whatever was
    // left, which at the default text size meant *"To estimated position ·
    // 8.96 km …"* with the rest of the line behind an ellipsis **and no way
    // to see it** — the target's own name cut off on the one row that is the
    // whole panel when it is shut. A row that hides what it cannot fit is
    // only honest when there is somewhere else to read it, and there is not.
    // So it wraps, and the panel grows by the line it needed.
    //
    // This also removes the class rather than the instance: nothing here has
    // a fixed height any more, so no text size and no length of name can
    // overflow it or hide anything inside it.
    final body = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        handle,
        header,
        if (!collapsed)
          SizedBox(
            height: screenHeight * _heightFraction,
            // **A spinner is only honest while something is running.** With
            // no fix yet there is no line to sample and nothing is loading,
            // so this says what it is waiting for rather than turning
            // forever — which is what it did while somebody stood under a
            // canopy waiting for GPS.
            child: origin == null
                ? const _ChartMessage(kWaitingForFixMessage)
                : _loadingDem
                    ? const Center(
                        child: SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      )
                    : _ElevationChart(
                        profile: _profile,
                        lineColor: widget.lineColor,
                      ),
          ),
      ],
    );

    return GestureDetector(
      onVerticalDragUpdate: (details) => setState(() {
        _heightFraction = (_heightFraction - details.delta.dy / screenHeight)
            .clamp(_handleFraction, _maxFraction);
      }),
      onVerticalDragEnd: (details) {
        setState(() {
          // Snap: close to the handle → fully collapse; otherwise don't let
          // it rest somewhere uncomfortably thin.
          if (_heightFraction < _minFraction * 0.6) {
            _heightFraction = _handleFraction;
          } else if (_heightFraction < _minFraction) {
            _heightFraction = _minFraction;
          }
        });
        // Opened after a walk: the profile in hand is for wherever the person
        // was when they shut it, so it is re-sampled on the way up.
        if (!_collapsed && _followsPosition) unawaited(_refresh());
      },
      child: Material(
        color: scheme.surface,
        elevation: 6,
        child: body,
      ),
    );
  }
}

/// The terrain profile as a chart: the same samples the totals were summed
/// from, so the picture and the numbers cannot disagree.
class _ElevationChart extends StatelessWidget {
  const _ElevationChart({required this.profile, required this.lineColor});

  final TerrainProfile? profile;
  final Color lineColor;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final profile = this.profile;
    if (profile == null) {
      return _ChartMessage(kNoElevationDataMessage);
    }
    if (!profile.hasAnyData) {
      return const _ChartMessage('No elevation data along this line.');
    }

    final known = profile.elevations.whereType<double>();
    final minE = known.reduce(math.min);
    final maxE = known.reduce(math.max);

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${maxE.round()} m',
            style: TextStyle(fontSize: 10, color: scheme.onSurfaceVariant),
          ),
          Expanded(
            child: CustomPaint(
              painter: _ElevationChartPainter(
                elevations: profile.elevations,
                minElevation: minE,
                maxElevation: maxE,
                distanceMeters: profile.distanceMeters,
                lineColor: lineColor,
                // **Task 11.200: the label's 0.55 came off a token that was
                // silently full-strength.** Fading body text to 0.55 gave
                // 3.90:1 light / 5.47:1 dark; fading the real muted grey the
                // same way gives 2.22:1 and 2.79:1, which is not a readable
                // axis label. The label now takes the token at full strength
                // (5.35:1 / 6.19:1) — the fading was doing the muting, and
                // the token does it now. `gridColor` keeps its alpha: those
                // are decorative rules behind the trace, not something to
                // read.
                gridColor: scheme.onSurfaceVariant.withValues(alpha: 0.18),
                labelColor: scheme.onSurfaceVariant,
              ),
              size: Size.infinite,
            ),
          ),
          Row(
            children: [
              Text(
                '${minE.round()} m',
                style: TextStyle(fontSize: 10, color: scheme.onSurfaceVariant),
              ),
              if (profile.hasGaps) ...[
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    kPartialElevationProfileMessage,
                    style: TextStyle(
                      fontSize: 10,
                      color: scheme.onSurfaceVariant,
                    ),
                    overflow: TextOverflow.ellipsis,
                    maxLines: 2,
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

class _ChartMessage extends StatelessWidget {
  const _ChartMessage(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Text(
          text,
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 12,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}

class _ElevationChartPainter extends CustomPainter {
  _ElevationChartPainter({
    required this.elevations,
    required this.minElevation,
    required this.maxElevation,
    required this.distanceMeters,
    required this.lineColor,
    required this.gridColor,
    required this.labelColor,
  });

  final List<double?> elevations;
  final double minElevation;
  final double maxElevation;
  final double distanceMeters;
  final Color lineColor;
  final Color gridColor;
  final Color labelColor;

  /// Rounds [rawStep] up to a "nice" 1/2/5 × 10^k value so gridline values
  /// read as round numbers rather than arbitrary fractions.
  static double _niceStep(double rawStep) {
    if (rawStep <= 0) return 1;
    final magnitude = math.pow(
      10,
      (math.log(rawStep) / math.ln10).floor(),
    ).toDouble();
    final residual = rawStep / magnitude;
    final double niceResidual;
    if (residual > 5) {
      niceResidual = 10;
    } else if (residual > 2) {
      niceResidual = 5;
    } else if (residual > 1) {
      niceResidual = 2;
    } else {
      niceResidual = 1;
    }
    return niceResidual * magnitude;
  }

  void _drawGrid(Canvas canvas, Size size) {
    // Target a comfortable ~30-55px pixel spacing between gridlines by
    // deriving the number of divisions from the painted size, then snap the
    // resulting step to a "nice" round number for each axis.
    const targetSpacing = 40.0;
    final targetHLines = (size.height / targetSpacing).clamp(2, 12).round();
    final targetVLines = (size.width / targetSpacing).clamp(2, 12).round();

    final gridPaint = Paint()
      ..color = gridColor
      ..strokeWidth = 0.75;

    final elevationRange = (maxElevation - minElevation).abs() < 1
        ? 1.0
        : maxElevation - minElevation;
    final showLabels = size.width > 50 && size.height > 40;
    final labelStyle = TextStyle(fontSize: 9, color: labelColor);

    // Horizontal (constant-elevation) lines.
    final eStep = _niceStep(elevationRange / targetHLines);
    var e = (minElevation / eStep).ceil() * eStep;
    for (; e <= maxElevation + 1e-6; e += eStep) {
      final y =
          size.height - ((e - minElevation) / elevationRange) * size.height;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), gridPaint);
      if (showLabels) {
        final tp = TextPainter(
          text: TextSpan(text: '${e.round()} m', style: labelStyle),
          textDirection: TextDirection.ltr,
        )..layout();
        final ty = (y - tp.height - 1).clamp(0.0, size.height - tp.height);
        tp.paint(canvas, Offset(2, ty));
      }
    }

    // Vertical (constant-distance) lines.
    if (distanceMeters > 0) {
      final dStep = _niceStep(distanceMeters / targetVLines);
      var d = dStep;
      for (; d <= distanceMeters + 1e-6; d += dStep) {
        final x = size.width * d / distanceMeters;
        canvas.drawLine(Offset(x, 0), Offset(x, size.height), gridPaint);
        if (showLabels) {
          final tp = TextPainter(
            text: TextSpan(
              text: formatDistanceMeters(d),
              style: labelStyle,
            ),
            textDirection: TextDirection.ltr,
          )..layout();
          final tx = (x - tp.width / 2).clamp(0.0, size.width - tp.width);
          tp.paint(canvas, Offset(tx, size.height - tp.height));
        }
      }
    }
  }

  @override
  void paint(Canvas canvas, Size size) {
    final range = (maxElevation - minElevation).abs() < 1
        ? 1.0
        : maxElevation - minElevation;
    final n = elevations.length;
    if (n < 2) return;

    _drawGrid(canvas, size);

    Offset pointAt(int i) {
      final e = elevations[i]!;
      final x = size.width * i / (n - 1);
      final y = size.height - ((e - minElevation) / range) * size.height;
      return Offset(x, y);
    }

    // Draw in contiguous runs of known samples — DEM coverage gaps at the
    // line's edges (or occasional no-data cells) just break the line rather
    // than being guessed at.
    var i = 0;
    while (i < n) {
      if (elevations[i] == null) {
        i++;
        continue;
      }
      var j = i;
      while (j + 1 < n && elevations[j + 1] != null) {
        j++;
      }
      if (j > i) {
        final path = Path()..moveTo(pointAt(i).dx, pointAt(i).dy);
        for (var k = i + 1; k <= j; k++) {
          final p = pointAt(k);
          path.lineTo(p.dx, p.dy);
        }
        final fillPath = Path.from(path)
          ..lineTo(pointAt(j).dx, size.height)
          ..lineTo(pointAt(i).dx, size.height)
          ..close();
        canvas.drawPath(
          fillPath,
          Paint()..color = lineColor.withValues(alpha: 0.15),
        );
        canvas.drawPath(
          path,
          Paint()
            ..color = lineColor
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2,
        );
      }
      i = j + 1;
    }
  }

  @override
  bool shouldRepaint(covariant _ElevationChartPainter oldDelegate) =>
      oldDelegate.elevations != elevations ||
      oldDelegate.minElevation != minElevation ||
      oldDelegate.maxElevation != maxElevation ||
      oldDelegate.distanceMeters != distanceMeters ||
      oldDelegate.lineColor != lineColor ||
      oldDelegate.gridColor != gridColor ||
      oldDelegate.labelColor != labelColor;
}
