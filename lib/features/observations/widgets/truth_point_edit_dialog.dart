import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart' as ll;

import 'package:tritrack_sync/tritrack_sync.dart';

import '../../../core/errors/guarded_write.dart';

import '../../../core/providers/app_context_provider.dart';
import '../../../core/providers/device_id_provider.dart';
import '../../../core/providers/recordings_revision_provider.dart';
import '../../../data/models/actual_tag_location.dart';
import '../../../data/models/user.dart';
import '../../../data/repositories/mutation_authorization.dart';
import '../../../data/repositories/repository_providers.dart';
import '../../../widgets/segmented_toggle.dart';
import '../screens/record_position_preview_screen.dart';

/// What a truth point says was found there, in the words the screens use.
///
/// **Null is "not recorded", never a guess.** Only rows written before schema
/// v10 can carry it — every point this app writes answers the question — and a
/// reader who sees a blank must not read it as `animal + collar`, which is the
/// one value that would let it count towards an accuracy figure by default.
String truthFoundLabel(GroundTruthKind? kind) =>
    kind?.label ?? 'What was found: not recorded';

/// How this point's coordinate was got, in the words the screens use.
///
/// **Null is "not recorded", never a guess** — the same rule [truthFoundLabel]
/// follows and for the same reason. Only rows written before schema v11 can
/// carry it (task 11.93); a reader who sees a blank must not read it as a GPS
/// fix, which is the one value that would make the point look measured when
/// nobody knows whether it was.
String truthPositionSourceLabel(PositionSource? source) =>
    'Position: ${source?.label ?? 'not recorded'}';

/// Who found this point, in the words the screens use.
///
/// [finder] is the resolved `Users` row, or null when the app does not hold
/// one. The three answers are genuinely different and are worded differently:
/// a name; the raw id, when the point records a finder whose `Users` row has
/// not reached this device; and **"not recorded"** for a point written before
/// schema v11, which has no author and must never be attributed to whoever
/// last touched the row.
String truthFoundByLabel(ActualTagLocation location, User? finder) {
  final id = location.userId;
  if (id == null) return 'Found by: not recorded';
  if (finder == null) return 'Found by: $id';
  return 'Found by: ${finder.firstName} ${finder.lastName}';
}

/// Correcting a truth point — the record of where somebody physically found
/// the animal, the collar, or both (task 11.33's record; task 11.92's
/// correction; task 11.93's position and provenance).
///
/// **Precision is first and focused, because it is the field that gets
/// corrected.** A person who walked in to a collar in their hand routinely
/// knows better than the phone did — a phone claiming ±12 m when you are
/// standing on the transmitter is the normal case, not the odd one. What was
/// found comes second; both are what decide the meaning of the point.
///
/// **The position is editable here as of task 11.93, and 11.92's reasoning
/// for locking it was wrong.** 11.92 said somebody who stood in the wrong
/// place should delete the point and record a new one. The case this feature
/// exists for is a collared lion tracked from a truck: **nobody walks into a
/// pride**, so the recorded position is a place *near* the animal, and
/// re-recording changes nothing because the person is still in the truck.
///
/// **It is the record screen's map picker, not a second one** —
/// [RecordPositionPreviewScreen] in [PositionPickRequest] mode. The suppression
/// rule travels with it: **a hand-placed pin's precision is not the phone's GPS
/// accuracy**, so nothing here prefills the precision field from the device,
/// and moving the pin says out loud that the stored figure was recorded for the
/// old position.
///
/// **Who found it is shown and is not editable.** `user_id` is a fact about the
/// record — see [ActualTagLocation.userId] — and correcting a precision figure
/// does not make the corrector the finder. It is also **not** a permission: any
/// contributor may edit or delete this point, which is why nothing in here
/// consults [truthPointEditVerdict] differently for an author.
///
/// **Time is still not editable**, the same line the observation edit dialog
/// draws: when a record was taken is a recapture field, not a correction.
///
/// Returns the updated [ActualTagLocation] if saved, null if cancelled. Callers
/// with their own query provider should invalidate it on a non-null return.
Future<ActualTagLocation?> showEditTruthPointDialog(
  BuildContext context,
  WidgetRef ref,
  ActualTagLocation location,
) async {
  // Resolved before the dialog opens so the name is on screen from the first
  // frame — a "Found by" line that fills in a moment later reads as though it
  // changed its mind about who found the collar.
  final userRepo = await ref.read(userRepositoryProvider.future);
  if (!context.mounted) return null;
  final finderId = location.userId;
  final finder = finderId == null
      ? null
      : await userRepo.findById(finderId, includeDeleted: true);
  if (!context.mounted) return null;

  final precisionController = TextEditingController(
    text: _trimTrailingZero(location.uncertaintyRadius),
  );
  var kind = location.foundKind ?? GroundTruthKind.animalAndCollar;
  String? precisionError;
  var latitude = location.latitude;
  var longitude = location.longitude;

  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setDialogState) {
        final scheme = Theme.of(context).colorScheme;
        // Compared against the stored coordinate rather than tracked with a
        // flag, so moving the pin and moving it back is not "moved" — the
        // record would otherwise be restamped as hand-placed for no change.
        final moved =
            latitude != location.latitude || longitude != location.longitude;
        final source = moved
            ? positionSourceAfterHandMove(location.positionSource)
            : location.positionSource;
        return AlertDialog(
          title: const Text('Edit truth point'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  truthFoundByLabel(location, finder),
                  style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
                ),
                const SizedBox(height: 14),
                const Text('Position', style: TextStyle(fontWeight: FontWeight.w700)),
                const SizedBox(height: 6),
                Text(
                  '${latitude.toStringAsFixed(5)}, '
                  '${longitude.toStringAsFixed(5)}',
                  style: const TextStyle(fontSize: 13),
                ),
                const SizedBox(height: 2),
                Text(
                  truthPositionSourceLabel(source),
                  style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
                ),
                const SizedBox(height: 6),
                Align(
                  alignment: Alignment.centerLeft,
                  child: OutlinedButton.icon(
                    icon: const Icon(Icons.map_outlined, size: 18),
                    label: const Text('Move on map…'),
                    onPressed: () async {
                      // Pushed on the root navigator so the full-screen map
                      // covers the dialog rather than opening inside it; the
                      // dialog is still there underneath when it pops.
                      final picked = await Navigator.of(
                        context,
                        rootNavigator: true,
                      ).push<ll.LatLng>(
                        MaterialPageRoute(
                          builder: (_) => RecordPositionPreviewScreen(
                            pick: PositionPickRequest(
                              initial: ll.LatLng(latitude, longitude),
                              title: 'Move truth point',
                              helpText:
                                  'Recorded as placed by hand. The precision '
                                  'figure was recorded for the old position — '
                                  'check it when you get back.',
                            ),
                          ),
                        ),
                      );
                      if (picked == null) return;
                      setDialogState(() {
                        latitude = picked.latitude;
                        longitude = picked.longitude;
                      });
                    },
                  ),
                ),
                const SizedBox(height: 14),
                const Text('Precision', style: TextStyle(fontWeight: FontWeight.w700)),
                const SizedBox(height: 6),
                TextField(
                  controller: precisionController,
                  autofocus: true,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  decoration: InputDecoration(
                    border: const OutlineInputBorder(),
                    hintText: 'Radius in meters',
                    suffixText: 'm',
                    isDense: true,
                    errorText: precisionError,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  // **This sentence used to say the figure was prefilled from
                  // the device's GPS accuracy.** That is true of a point
                  // recorded on a GPS fix and false of one recorded on a map
                  // pin, where the prefill is deliberately suppressed — and it
                  // was false of any figure the person typed themselves. Copy
                  // describing a mechanism the record does not have is the same
                  // defect as a message naming the wrong cause.
                  moved
                      ? 'How closely the position is known. You moved the '
                            'pin, so check this figure: it was recorded for '
                            'the old position.'
                      : 'How closely the position is known — the radius the '
                            'tag was within. Change it if you know better.',
                  style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
                ),
                const SizedBox(height: 14),
                const Text('What was found', style: TextStyle(fontWeight: FontWeight.w700)),
                const SizedBox(height: 6),
                SegmentedToggle<GroundTruthKind>(
                  options: [for (final k in GroundTruthKind.values) (k, k.label)],
                  selected: kind,
                  onChanged: (k) => setDialogState(() => kind = k),
                ),
                const SizedBox(height: 4),
                Text(
                  'Only "animal + tag" checks a bearing estimate of a live '
                  'tagged animal. A tag on its own may have been shed.',
                  style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                // The same bound the record screen holds: a truth point with no
                // precision claim is a coordinate with no error bar, which is
                // the one thing it exists to carry.
                final parsed = double.tryParse(precisionController.text.trim());
                if (parsed == null || parsed <= 0 || !parsed.isFinite) {
                  setDialogState(
                    () => precisionError = 'Enter a radius in meters, greater than zero.',
                  );
                  return;
                }
                Navigator.of(context).pop(true);
              },
              child: const Text('Save'),
            ),
          ],
        );
      },
    ),
  );
  // Guard every `ref`/`context` touch after this await: the dialog can span an
  // arbitrarily long real-world gap (backgrounding the app, navigating away),
  // and `ref` throws — not a silent no-op — if the element is gone.
  if (confirmed != true || !context.mounted) return null;
  final precision = double.tryParse(precisionController.text.trim());
  if (precision == null || precision <= 0 || !precision.isFinite) return null;

  final user = await ref.read(currentUserProvider.future);
  if (!context.mounted) return null;
  final deviceId = await ref.read(deviceIdProvider.future);
  if (!context.mounted) return null;
  final repo = await ref.read(actualTagLocationRepositoryProvider.future);
  if (!context.mounted) return null;

  // `tagVersionId` is untouched on purpose. It records what the collar was
  // called and tuned to when the point was taken (task 11.32); correcting a
  // precision figure today says nothing about that, and refreshing it here
  // would quietly rewrite the history an export is matched by.
  //
  // **`userId` is untouched for a stronger reason** (task 11.93): a colleague
  // correcting this point has not become the person who found the collar.
  // Whoever made this change is recorded — in `sync.last_modified_by`, which
  // `repo.update` sets from `actor` below, and which is a different fact.
  final moved =
      latitude != location.latitude || longitude != location.longitude;
  final updated = location.copyWith(
    uncertaintyRadius: precision,
    foundKind: kind,
    latitude: latitude,
    longitude: longitude,
    // A fix that was nudged becomes `gpsFixAdjusted`; a pin stays a pin; a
    // point that never recorded a source becomes a plain hand-placed pin
    // rather than claiming to refine a measurement nobody recorded. See
    // `positionSourceAfterHandMove`.
    positionSource: moved
        ? positionSourceAfterHandMove(location.positionSource)
        : location.positionSource,
  );
  // Task 11.137. **Not one of the thirteen the sweep listed** — the table named
  // this file's delete and not its save, and the two are the same shape three
  // hundred lines apart. Fixed here and reported rather than done silently.
  final saved = await runGuardedWrite(
    context,
    write: () => repo.update(updated,
        actor: MutationActor.user(user.userId), deviceId: deviceId),
    refused: 'You can only change a truth point you recorded yourself, so '
        'this was not saved. Ask the person who found it, or a project owner.',
    failed: 'Could not save this truth point; it is unchanged. Try again, and '
        'report it if this keeps happening.',
  );
  if (!saved) return null;
  ref.read(recordingsRevisionProvider.notifier).bump();
  return updated;
}

/// Confirm, tombstone, and offer an undo — deleting a truth point.
///
/// **This is deleting field data, so it follows the app's existing destructive
/// pattern rather than a shorter one**: the confirm dialog guards a misclick,
/// and the soft delete behind it means the undo in the snackbar is a real undo
/// (the row is tombstoned and [ActualTagLocationRepository.restore] clears the
/// tombstone) rather than a re-creation with a new identity. Copied from
/// `log_screen.dart`'s `deleteLogEntry`, which is the same act on an
/// observation; the wording differs only where the thing being lost differs.
///
/// Returns true if the point was deleted.
Future<bool> confirmAndDeleteTruthPoint(
  BuildContext context,
  WidgetRef ref,
  ActualTagLocation location, {
  VoidCallback? onChanged,
}) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Delete this truth point?'),
      content: const Text(
        'Where the animal or tag was actually found cannot be re-measured '
        'from your desk. Deleting removes it from accuracy checks, the map, '
        'the Log and the CSV export, on every device once they sync.\n\n'
        'You can undo it straight after.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('Delete'),
        ),
      ],
    ),
  );
  if (confirmed != true || !context.mounted) return false;

  final user = await ref.read(currentUserProvider.future);
  if (!context.mounted) return false;
  final deviceId = await ref.read(deviceIdProvider.future);
  if (!context.mounted) return false;
  final repo = await ref.read(actualTagLocationRepositoryProvider.future);
  if (!context.mounted) return false;

  final actor = MutationActor.user(user.userId);
  final deleted = await runGuardedWrite(
    context,
    write: () => repo.softDelete(location, actor: actor, deviceId: deviceId),
    refused: 'You can only delete a truth point you recorded yourself, so '
        'this was not deleted. Ask the person who found it, or a project '
        'owner.',
    failed: 'Could not delete this truth point; it is still on the map and in '
        'the Log. Try again, and report it if this keeps happening.',
  );
  if (!deleted) return false;
  ref.read(recordingsRevisionProvider.notifier).bump();
  onChanged?.call();
  if (!context.mounted) return true;

  HapticFeedback.mediumImpact();
  // Clear any still-showing snackbar first — otherwise a second delete queues
  // its undo bar behind the first instead of replacing it.
  ScaffoldMessenger.of(context).clearSnackBars();
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: const Text('Truth point deleted'),
      duration: const Duration(seconds: 6),
      // Task 11.42: an action makes this default to `persist: true`
      // (Material 3), which leaves `duration` dead and the bar on screen for
      // ever — see `projects_screen.dart` for the finding.
      persist: false,
      action: SnackBarAction(
        label: 'UNDO',
        onPressed: () async {
          if (!context.mounted) return;
          final restored = await runGuardedWrite(
            context,
            write: () =>
                repo.restore(location, actor: actor, deviceId: deviceId),
            refused: 'You may no longer change this truth point, so it could '
                'not be brought back. Ask a project owner.',
            failed: 'Could not bring this truth point back; it is still '
                'deleted. Try again, and report it if this keeps happening.',
          );
          if (!restored) return;
          ref.read(recordingsRevisionProvider.notifier).bump();
          onChanged?.call();
        },
      ),
    ),
  );
  return true;
}

/// `12.0` → `12`, `12.5` → `12.5` — the same trimming the record screen's
/// precision field does, so a value typed there and re-opened here reads back
/// identically instead of gaining a `.0`.
String _trimTrailingZero(double value) {
  final text = value.toString();
  return text.endsWith('.0') ? text.substring(0, text.length - 2) : text;
}
