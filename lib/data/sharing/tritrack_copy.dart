import '../models/observation.dart';
import '../models/tag.dart';
import '../models/user.dart';
import '../repositories/tag_version_repository.dart';
import 'observation_share.dart';

/// Builds the TriTrack `TT1:` clipboard payload for [observation] the same
/// way everywhere in the app that offers "Copy for TriTrack" — the Log/Team
/// tabs' per-row Copy (`log_screen.dart`) and the map's selection-card menu
/// (`map_screen.dart`, task 11.209) both call this rather than re-encoding, so
/// a payload copied from either screen for the same observation is
/// byte-identical
/// (`test/data/sharing/tritrack_copy_parity_test.dart`).
///
/// [tagVersionRepo] is the caller's own repository instance (each screen
/// already reads it off its own `WidgetRef`), so this stays free of Riverpod
/// and is plain-Dart testable. [observer] must be the observation's author —
/// [ObservationShare.encode] asserts it.
Future<String> buildTriTrackClipboardPayload({
  required TagVersionRepository tagVersionRepo,
  required Observation observation,
  required Tag tag,
  required User observer,
}) async {
  // Task 11.32: what the bearing was recorded against travels, not what the
  // tag reads today.
  final recorded = await tagVersionRepo.recordedStateOf(observation, tag: tag);
  return ObservationShare.encode(
    observation,
    tag: tag,
    observer: observer,
    recorded: recorded,
  );
}
