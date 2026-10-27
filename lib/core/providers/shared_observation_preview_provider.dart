import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../data/sharing/observation_share.dart';

part 'shared_observation_preview_provider.g.dart';

/// The pasted-and-parsed [SharedObservation] currently previewed as a
/// temporary map overlay (design doc §10: "Paste incoming payload to parse
/// and preview on map as a temporary overlay"). Deliberately in-memory only,
/// not persisted — a preview is ephemeral by design ("not stored unless
/// explicitly saved") and should not survive an app restart.
@riverpod
class SharedObservationPreview extends _$SharedObservationPreview {
  @override
  SharedObservation? build() => null;

  void set(SharedObservation? value) => state = value;

  void clear() => state = null;
}
