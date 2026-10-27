import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../compass/compass_controller.dart';
import '../../../compass/compass_reading.dart';
import '../../../routing/tab_visibility.dart';
import '../../../core/theme/app_theme.dart';
import '../../../localization/declination/declination_override_provider.dart';

/// Formats a declination (° east positive) as e.g. "12.3°E" / "5.0°W".
String formatDeclination(double deg) {
  final a = deg.abs();
  if (a < 0.05) return '0.0°';
  return '${a.toStringAsFixed(1)}°${deg >= 0 ? 'E' : 'W'}';
}

/// Shows the current magnetic declination and lets the user override it
/// manually. Shared by the Compass tab and the Record tab's bearing-entry
/// sheet so both always reflect (and clearly flag) a manual override.
///
/// - No override: shows the location-computed declination + an "Adjust" action.
/// - Override active: an amber note showing the manual value alongside the
///   computed one, with Edit / Reset. Applying a manual value first asks the
///   user to confirm they want to keep using it for all bearing measurements.
class DeclinationControl extends ConsumerWidget {
  const DeclinationControl({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Task 11.161: gated with the rest of the Compass tab. While hidden the
    // computed declination reads as unknown, which is what this control shows
    // before the first fix anyway; resuming costs one sensor sample.
    final reading = ref.watchWhileTabVisible(context, compassControllerProvider,
        whileHidden: CompassReading.initial);
    final colors = Theme.of(context).extension<TriTrackColors>()!;
    final scheme = Theme.of(context).colorScheme;

    final computed = reading.computedDeclinationDeg;
    final manual = ref.watch(declinationOverrideProvider).value;

    if (manual != null) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: colors.fairAmber.withValues(alpha: 0.1),
          border: Border.all(color: colors.fairAmber, width: 1.5),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '⚠ Manual declination: ${formatDeclination(manual)}',
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w800,
                color: colors.fairAmber,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              computed == null
                  ? 'Overriding the computed value. Bearings use the manual value.'
                  : 'Computed here is ${formatDeclination(computed)}. Bearings use the manual value.',
              style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 4),
            Row(
              children: [
                TextButton(
                  onPressed: () => _edit(context, ref, manual, computed),
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                  ),
                  child: const Text('Edit', style: TextStyle(fontSize: 12.5)),
                ),
                TextButton(
                  onPressed: () => ref.read(declinationOverrideProvider.notifier).clear(),
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                  ),
                  child: const Text('Reset to computed', style: TextStyle(fontSize: 12.5)),
                ),
              ],
            ),
          ],
        ),
      );
    }

    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Text(
          'Declination: ${computed == null ? '—' : formatDeclination(computed)}',
          style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700),
        ),
        TextButton(
          onPressed: () => _edit(context, ref, computed, computed),
          style: TextButton.styleFrom(
            visualDensity: VisualDensity.compact,
            padding: const EdgeInsets.symmetric(horizontal: 10),
          ),
          child: const Text('Adjust', style: TextStyle(fontSize: 12.5)),
        ),
      ],
    );
  }

  Future<void> _edit(
    BuildContext context,
    WidgetRef ref,
    double? initial,
    double? computed,
  ) async {
    final controller = TextEditingController(
      text: initial == null ? '' : initial.toStringAsFixed(1),
    );
    final entered = await showDialog<double>(
      context: context,
      builder: (context) {
        String? error;
        return StatefulBuilder(
          builder: (context, setDialogState) => AlertDialog(
            title: const Text('Manual declination'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Enter magnetic declination in degrees. Positive = East, '
                  'negative = West.',
                  style: TextStyle(fontSize: 12),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: controller,
                  autofocus: true,
                  keyboardType: const TextInputType.numberWithOptions(
                    signed: true,
                    decimal: true,
                  ),
                  inputFormatters: [
                    FilteringTextInputFormatter.allow(RegExp(r'[0-9.\-]')),
                  ],
                  decoration: InputDecoration(
                    labelText: 'Declination (°)',
                    errorText: error,
                    helperText: computed == null
                        ? null
                        : 'Computed here: ${formatDeclination(computed)}',
                  ),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () {
                  final v = double.tryParse(controller.text.trim());
                  if (v == null || v < -90 || v > 90) {
                    setDialogState(() => error = 'Enter a number between -90 and 90');
                    return;
                  }
                  Navigator.of(context).pop(v);
                },
                child: const Text('Next'),
              ),
            ],
          ),
        );
      },
    );
    if (entered == null || !context.mounted) return;

    // Confirm the user really wants to keep using a manual value for all
    // bearing measurements (design ask: "confirm the user wants to continue").
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Use manual declination?'),
        content: Text(
          'All bearing measurements will use a manual declination of '
          '${formatDeclination(entered)} instead of the location-computed value'
          '${computed == null ? '' : ' (${formatDeclination(computed)})'}.\n\n'
          'This stays in effect until you reset it.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Use manual'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await ref.read(declinationOverrideProvider.notifier).set(entered);
    }
  }
}
