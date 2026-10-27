import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../compass/bearing_capture.dart';
import '../../../compass/compass_controller.dart';
import '../../../compass/compass_reading.dart';
import '../../../routing/tab_visibility.dart';
import '../../compass/providers/bearing_capture_provider.dart';
import '../../compass/widgets/compass_dial.dart';
import '../../compass/widgets/declination_control.dart';
import '../../../widgets/segmented_toggle.dart';

/// Result handed back to Observation Logging when the sheet is dismissed
/// with a bearing resolved (either from the live compass or typed by hand).
class BearingEntryResult {
  const BearingEntryResult({
    required this.magneticBearingDeg,
    required this.uncertaintyDeg,
    this.captureMethod,
    this.startDeg,
    this.endDeg,
    this.ambiguousSweep = false,
  });

  final double magneticBearingDeg;
  final double uncertaintyDeg;

  /// Null for a manually-typed/sighted bearing (no compass capture method).
  final CaptureMode? captureMethod;
  final double? startDeg;
  final double? endDeg;
  final bool ambiguousSweep;
}

/// Bottom sheet offering "Compass or manual bearing entry" (design doc) for
/// Observation Logging. The compass tab reuses the same [BearingCaptureUi] /
/// [CompassController] providers as the Compass Calibration screen so bearing
/// math is never re-derived; the manual tab stays equally prominent per
/// TC:200 — the normal field posture (holding a metal antenna) corrupts the
/// magnetometer, so typed/sighted entry must be a first-class path, not a
/// buried fallback.
Future<BearingEntryResult?> showBearingEntrySheet(
  BuildContext context, {
  bool initialManualTab = false,
}) {
  return showModalBottomSheet<BearingEntryResult>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (context) => _BearingEntrySheet(initialManualTab: initialManualTab),
  );
}

class _BearingEntrySheet extends ConsumerStatefulWidget {
  const _BearingEntrySheet({this.initialManualTab = false});

  /// Preselects the Manual entry tab — used when the caller already knows no
  /// compass is available, so the sheet doesn't open on a dead Compass tab.
  final bool initialManualTab;

  @override
  ConsumerState<_BearingEntrySheet> createState() => _BearingEntrySheetState();
}

class _BearingEntrySheetState extends ConsumerState<_BearingEntrySheet> {
  late bool _manualTab = widget.initialManualTab;
  final _manualController = TextEditingController();
  double _manualUncertainty = 12.0;
  String? _manualError;

  @override
  void dispose() {
    _manualController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Task 11.161: gated with the rest of the Record tab. This sheet is
    // normally in the root navigator, above the shell, where TabVisibility is
    // absent and this is an ordinary watch — the pause only applies when it is
    // built inside a hidden branch.
    final reading = ref.watchWhileTabVisible(context, compassControllerProvider,
        whileHidden: CompassReading.initial);
    final captureState = ref.watch(bearingCaptureUiProvider);
    final captureNotifier = ref.read(bearingCaptureUiProvider.notifier);

    // Fill the available width with the dial (its widget box is size+50 for
    // the level-badge/label overhang, inside 20px horizontal padding each
    // side) instead of leaving big empty margins around a fixed 200px dial.
    final dialSize =
        (MediaQuery.of(context).size.width - 40 - 50).clamp(220.0, 320.0);

    return Padding(
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
        top: 4,
        bottom: MediaQuery.of(context).viewInsets.bottom + 20,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SegmentedToggle<bool>(
            options: const [(false, 'Compass'), (true, 'Manual entry')],
            selected: _manualTab,
            onChanged: (v) => setState(() => _manualTab = v),
          ),
          const SizedBox(height: 8),
          const DeclinationControl(),
          const SizedBox(height: 8),
          if (!_manualTab) ...[
            CompassDial(
              // Only the frozen value. The `?? reading.magneticHeadingDeg`
              // fallback that used to be here fed the raw live heading into a
              // subtraction against the smoothed ring (task 11.177); with it
              // null the dial draws the live needle at the top instead.
              capturedMagneticBearingDeg: captureState.lastCaptured?.magneticBearingDeg,
              trueBearingDeg: reading.trueHeadingDeg,
              uncertaintyDeg: captureState.lastCaptured?.uncertaintyDeg ??
                  (captureState.mode == CaptureMode.singlePoint
                      ? captureState.singleUncertaintyDeg
                      : null),
              liveHeadingDeg: reading.magneticHeadingDeg,
              liveTrueHeadingDeg: reading.trueHeadingDeg,
              inProgressRangeStartDeg:
                  captureState.mode == CaptureMode.rangeCapture && captureState.lastCaptured == null
                      ? captureState.rangeStartDeg
                      : null,
              capturedRangeStartDeg:
                  captureState.mode == CaptureMode.rangeCapture
                      ? captureState.lastCaptured?.magneticStartDeg
                      : null,
              capturedRangeEndDeg:
                  captureState.mode == CaptureMode.rangeCapture
                      ? captureState.lastCaptured?.magneticEndDeg
                      : null,
              isLevel: reading.level.isLevel(),
              levelOffsetX: reading.level.offsetX,
              levelOffsetY: reading.level.offsetY,
              size: dialSize,
            ),
            const SizedBox(height: 14),
            SegmentedToggle<CaptureMode>(
              options: const [
                (CaptureMode.singlePoint, 'Single Point'),
                (CaptureMode.rangeCapture, 'Range Capture'),
              ],
              selected: captureState.mode,
              onChanged: captureNotifier.setMode,
            ),
            const SizedBox(height: 10),
            if (captureState.mode == CaptureMode.rangeCapture)
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: reading.magneticHeadingDeg == null
                          ? null
                          : () {
                              HapticFeedback.mediumImpact();
                              captureNotifier.markRangeStart();
                            },
                      child: const Text('● Start'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton(
                      onPressed: captureState.rangeStartDeg == null
                          ? null
                          : () {
                              HapticFeedback.mediumImpact();
                              captureNotifier.markRangeEnd();
                            },
                      child: const Text('▪ End'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  // Task 11.94/11.101 exemption: labelled only by
                  // `tooltip:`. Left as-is: `refresh` is a conventional
                  // reset glyph, the action only clears an in-progress
                  // capture (nothing saved is touched), and it is alone next
                  // to the End/CAPTURE button rather than beside a
                  // destructive twin.
                  IconButton(
                    tooltip: 'Reset',
                    onPressed: captureState.rangeStartDeg == null && captureState.lastCaptured == null
                        ? null
                        : () {
                            HapticFeedback.lightImpact();
                            captureNotifier.clearCaptured();
                          },
                    icon: const Icon(Icons.refresh),
                  ),
                ],
              )
            else ...[
              Slider(
                value: captureState.singleUncertaintyDeg,
                min: 5,
                max: 25,
                divisions: 20,
                label: '±${captureState.singleUncertaintyDeg.round()}°',
                onChanged: captureNotifier.setUncertainty,
              ),
              Row(
                children: [
                  Expanded(
                    child: FilledButton(
                      onPressed: reading.magneticHeadingDeg == null
                          ? null
                          : () {
                              HapticFeedback.mediumImpact();
                              captureNotifier.captureSingle();
                            },
                      child: const Text('CAPTURE'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  // Task 11.94/11.101 exemption: same reasoning as the Reset
                  // button above, in the sheet's other capture mode.
                  IconButton(
                    tooltip: 'Reset',
                    onPressed: captureState.lastCaptured == null
                        ? null
                        : () {
                            HapticFeedback.lightImpact();
                            captureNotifier.clearCaptured();
                          },
                    icon: const Icon(Icons.refresh),
                  ),
                ],
              ),
            ],
            if (captureState.lastCaptured?.ambiguousSweep == true)
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text(
                  'Sweep was ≥180° — rotation direction is ambiguous.',
                  style: TextStyle(fontSize: 11, color: Colors.orange),
                  textAlign: TextAlign.center,
                ),
              ),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: captureState.lastCaptured == null
                  ? null
                  : () {
                      final captured = captureState.lastCaptured!;
                      Navigator.of(context).pop(
                        BearingEntryResult(
                          magneticBearingDeg: captured.magneticBearingDeg,
                          uncertaintyDeg: captured.uncertaintyDeg,
                          captureMethod: captured.method,
                          startDeg: captured.magneticStartDeg,
                          endDeg: captured.magneticEndDeg,
                          ambiguousSweep: captured.ambiguousSweep,
                        ),
                      );
                    },
              child: const Text('USE THIS BEARING'),
            ),
          ] else ...[
            const Text(
              'Enter a magnetic bearing, as read off a compass (degrees '
              'clockwise from magnetic north). The app converts it to true '
              'north — don\'t convert it yourself.',
              style: TextStyle(fontSize: 11.5),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _manualController,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
              decoration: InputDecoration(
                labelText: 'Magnetic bearing (°)',
                border: const OutlineInputBorder(),
                errorText: _manualError,
              ),
              onChanged: (_) {
                if (_manualError != null) setState(() => _manualError = null);
              },
            ),
            const SizedBox(height: 12),
            Text('Uncertainty: ±${_manualUncertainty.round()}°'),
            Slider(
              value: _manualUncertainty,
              min: 5,
              max: 25,
              divisions: 20,
              onChanged: (v) => setState(() => _manualUncertainty = v),
            ),
            const SizedBox(height: 8),
            FilledButton(
              onPressed: () {
                final raw = _manualController.text.trim();
                if (raw.isEmpty) {
                  setState(() => _manualError = 'Enter a bearing');
                  return;
                }
                final value = double.tryParse(raw);
                if (value == null) {
                  setState(() => _manualError = 'Enter a valid number');
                  return;
                }
                if (value > 360) {
                  setState(() => _manualError = 'Bearing must be 360° or less');
                  return;
                }
                // 360 is a valid magnetic bearing (same direction as 0) —
                // normalize it rather than rejecting it as out of range.
                final normalized = value == 360 ? 0.0 : value;
                Navigator.of(context).pop(
                  BearingEntryResult(
                    magneticBearingDeg: normalized,
                    uncertaintyDeg: _manualUncertainty,
                  ),
                );
              },
              child: const Text('USE THIS BEARING'),
            ),
          ],
        ],
      ),
    );
  }
}
