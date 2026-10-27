import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../compass/compass_controller.dart';
import '../../../compass/compass_reading.dart';
import '../../../core/providers/compass_provider.dart';
import '../../../core/providers/gps_provider.dart';
import '../../../core/providers/navigation_target_provider.dart';
import '../../../core/theme/design_tokens.dart';
import '../../../localization/coordinate_projection.dart';
import '../../../routing/tab_visibility.dart';
import '../../map/services/geo_math.dart';
import '../widgets/compass_dial.dart';
import '../widgets/declination_control.dart';
import '../widgets/interference_banner.dart';

/// Compass: a live instrument only — heading, true north, bubble level, and
/// interference/calibration feedback. It has no capture or save actions;
/// capturing and saving a bearing (single-point or range-capture) lives
/// entirely in the Record tab's bearing entry sheet, which shares this same
/// [CompassDial]/[compassControllerProvider] so the two always agree.
///
/// A "Save Bearing" button used to live here, but with no tag/observation
/// selected on this screen there was nothing meaningful to save it against —
/// removed 2026-07-17 per explicit user feedback that this and the Record
/// tab's bearing capture were confusingly redundant.
class CompassScreen extends ConsumerStatefulWidget {
  const CompassScreen({super.key});

  @override
  ConsumerState<CompassScreen> createState() => _CompassScreenState();
}

class _CompassScreenState extends ConsumerState<CompassScreen> {
  bool _bannerDismissed = false;

  @override
  Widget build(BuildContext context) {
    // Task 11.161: this tab is why the compass sensors run at all, so it puts
    // them down while it is off screen. Resuming costs the wait for the OS's
    // first heading sample — until it lands the dial reads CompassReading.initial
    // (0 degrees, no bubble level, no interference verdict), exactly as on a
    // cold start. While hidden it builds as available: nobody is looking at the
    // unavailable state, and CompassEverHeard keeps the real verdict.
    final compassAvailable = ref.watchWhileTabVisible(
        context, compassAvailableProvider, whileHidden: true);
    if (!compassAvailable) {
      return const Scaffold(body: _CompassUnavailableState());
    }

    final reading = ref.watchWhileTabVisible(context, compassControllerProvider,
        whileHidden: CompassReading.initial);
    final gps = ref.watch(gpsPositionProvider).value;
    final navTarget = ref.watch(navigationTargetProvider).value;

    final navDistanceBearing = (navTarget != null && gps != null)
        ? distanceAndBearing(
            GeoPoint(gps.latitude, gps.longitude),
            GeoPoint(navTarget.latitude, navTarget.longitude),
          )
        : null;

    return Scaffold(
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(
              horizontal: DesignTokens.spacingScreenHorizontal),
          child: Column(
            children: [
              if (!_bannerDismissed)
                InterferenceBanner(
                  assessment: reading.interference,
                  onDismiss: () => setState(() => _bannerDismissed = true),
                ),
              const SizedBox(height: 20),
              CompassDial(
                // No `capturedMagneticBearingDeg`: this screen never reviews
                // a saved capture, so the needle is the live heading and the
                // dial pins it to the top. Passing the heading in there as
                // well is what made it swing during a turn (task 11.177).
                trueBearingDeg: reading.trueHeadingDeg,
                liveHeadingDeg: reading.magneticHeadingDeg,
                liveTrueHeadingDeg: reading.trueHeadingDeg,
                isLevel: reading.level.isLevel(),
                levelOffsetX: reading.level.offsetX,
                levelOffsetY: reading.level.offsetY,
                navigationBearingDeg: navDistanceBearing?.bearingDeg,
              ),
              const SizedBox(height: 18),
              Row(
                children: [
                  Expanded(
                    child: _ReadoutBox(
                      label: 'Magnetic',
                      value: reading.magneticHeadingDeg == null
                          ? '—'
                          : '${reading.magneticHeadingDeg!.round()}°',
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _ReadoutBox(
                      label: 'True North',
                      value: reading.trueHeadingDeg == null
                          ? '—'
                          : '${reading.trueHeadingDeg!.round()}°',
                    ),
                  ),
                ],
              ),
              if (navTarget != null) ...[
                const SizedBox(height: 8),
                _ReadoutBox(
                  label: 'To ${navTarget.label ?? "target"}',
                  value: navDistanceBearing == null
                      ? '—'
                      : formatDistanceMeters(navDistanceBearing.distanceMeters),
                ),
              ],
              const SizedBox(height: 12),
              const DeclinationControl(),
              const SizedBox(height: 16),
              GestureDetector(
                onTap: () {
                  HapticFeedback.heavyImpact();
                  _showCalibrationPrompt(context);
                },
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 9),
                  decoration: BoxDecoration(
                    border: Border.all(color: Theme.of(context).colorScheme.onSurface, width: 1.5),
                    borderRadius: BorderRadius.circular(DesignTokens.radiusPill),
                  ),
                  child: const Text('⟲ Calibrate (figure-8)',
                      style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w800)),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'To capture and save a bearing, use the Record tab.',
                style: TextStyle(
                    fontSize: 10.5,
                    fontStyle: FontStyle.italic,
                    color: Theme.of(context).colorScheme.onSurfaceVariant),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
            ],
          ),
        ),
      ),
    );
  }

  void _showCalibrationPrompt(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Calibrate compass'),
        content: const Text(
          'Rotate the phone through a figure-eight motion until calibration '
          'improves. Keep away from metal, magnets, and vehicles.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Done'),
          ),
        ],
      ),
    );
  }
}

/// Shown instead of the dial/readouts when [compassAvailableProvider] is
/// false — no compass hardware, or `flutter_compass` has no implementation
/// on this platform (e.g. macOS). Routes to the Record tab, where a bearing
/// can still be entered manually.
class _CompassUnavailableState extends StatelessWidget {
  const _CompassUnavailableState();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.explore_off, size: 40),
            const SizedBox(height: 12),
            Text('No compass available on this device', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 6),
            const Text(
              'Bearings can still be entered manually on the Record screen.',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: () => context.go('/record'),
              child: const Text('Go to Record'),
            ),
          ],
        ),
      ),
    );
  }
}

class _ReadoutBox extends StatelessWidget {
  const _ReadoutBox({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        border: Border.all(color: scheme.onSurface, width: 1.5),
        borderRadius: BorderRadius.circular(DesignTokens.radiusSmall),
      ),
      child: Text('$label: $value',
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
    );
  }
}
