import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/providers/app_context_provider.dart';
import '../../../core/providers/device_id_provider.dart';
import '../../../core/providers/recordings_revision_provider.dart';
import '../../../core/theme/app_theme.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

import '../../../core/errors/guarded_write.dart';
import '../../../core/format/observation_quality_display.dart';
import '../../../data/models/observation.dart';
import '../../../data/repositories/repository_providers.dart';
import '../../../data/repositories/mutation_authorization.dart';

/// Best-first display order for the signal-strength chips (task 11.188) —
/// `SignalStrength.values` itself stays declared worst-to-best.
const _signalStrengthDisplayOrder = [
  SignalStrength.veryStrong,
  SignalStrength.strong,
  SignalStrength.medium,
  SignalStrength.weak,
  SignalStrength.faint,
];

/// Swatch color for a signal-strength level, interpolated along the app's
/// bounce-red → animal-fix ramp.
Color signalStrengthColor(SignalStrength s, BuildContext context) {
  final colors = Theme.of(context).extension<TriTrackColors>()!;
  final t = SignalStrength.values.indexOf(s) / (SignalStrength.values.length - 1);
  return Color.lerp(colors.bounceRed, colors.animalFix, t)!;
}

/// Shared "edit observation" dialog (notes / signal strength / bearing
/// quality). Persists via the observation repository and bumps
/// [recordingsRevisionProvider] so any open map refreshes. Returns the updated
/// [Observation] if saved, or null if cancelled/dismissed.
///
/// Callers that maintain their own query provider (e.g. the Log history list)
/// should invalidate it when this returns non-null.
Future<Observation?> showEditObservationDialog(
  BuildContext context,
  WidgetRef ref,
  Observation o,
) async {
  final notesController = TextEditingController(text: o.notes ?? '');
  var quality = o.bearingQuality;
  var strength = o.signalStrength;

  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setDialogState) => AlertDialog(
        title: const Text('Edit observation'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: notesController,
              decoration: const InputDecoration(labelText: 'Notes'),
              minLines: 1,
              maxLines: 3,
            ),
            const SizedBox(height: 12),
            const Text('Signal strength', style: TextStyle(fontWeight: FontWeight.w700)),
            Wrap(
              spacing: 6,
              // Best first (task 11.188), matching the Record screen's
              // rollers — `SignalStrength.values` itself stays faint-to-strong.
              children: [
                for (final s in _signalStrengthDisplayOrder)
                  ChoiceChip(
                    label: Text(signalStrengthLabel(s)),
                    selected: strength == s,
                    selectedColor: signalStrengthColor(s, context).withValues(alpha: 0.35),
                    onSelected: (_) => setDialogState(() => strength = s),
                  ),
              ],
            ),
            if (o.observationType == ObservationType.directional) ...[
              const SizedBox(height: 12),
              const Text('Bearing quality', style: TextStyle(fontWeight: FontWeight.w700)),
              Wrap(
                spacing: 6,
                // `BearingQuality.values` is declared good, fair,
                // suspectedBounce — already best-first, unlike
                // `SignalStrength.values` above — so no reorder needed here
                // (task 11.188).
                children: [
                  for (final q in BearingQuality.values)
                    ChoiceChip(
                      label: Text(bearingQualityLabel(q)),
                      selected: quality == q,
                      onSelected: (_) => setDialogState(() => quality = q),
                    ),
                ],
              ),
            ],
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('Save')),
        ],
      ),
    ),
  );
  // Guard every `ref`/`context` touch after this await: the dialog can span an
  // arbitrarily long real-world gap (backgrounding the app, navigating away),
  // and `ref` throws — not a silent no-op — if the element is gone.
  if (confirmed != true || !context.mounted) return null;

  final user = await ref.read(currentUserProvider.future);
  if (!context.mounted) return null;
  final deviceId = await ref.read(deviceIdProvider.future);
  if (!context.mounted) return null;
  final repo = await ref.read(observationRepositoryProvider.future);
  if (!context.mounted) return null;
  final updated = o.copyWith(
    notes: notesController.text.trim().isEmpty ? null : notesController.text.trim(),
    signalStrength: strength,
    bearingQuality: quality,
  );
  // Task 11.137: this returned null on a refusal exactly as it does on Cancel,
  // so a refused Save was indistinguishable from a tap that never landed.
  final saved = await runGuardedWrite(
    context,
    write: () => repo.update(updated,
        actor: MutationActor.user(user.userId), deviceId: deviceId),
    refused: 'You can only change an observation you recorded yourself, so '
        'your edits were not saved. A project owner can supersede or exclude '
        'it instead.',
    failed: 'Could not save this observation; it is unchanged. Try again, and '
        'report it if this keeps happening.',
  );
  if (!saved) return null;
  ref.read(recordingsRevisionProvider.notifier).bump();
  return updated;
}
