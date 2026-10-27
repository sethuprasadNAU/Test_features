import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../../compass/bearing_capture.dart';
import '../../../compass/compass_controller.dart';

part 'bearing_capture_provider.g.dart';

/// UI-facing state for the Compass Calibration screen: which capture mode is
/// active, an in-progress range sweep, and the last captured bearing (shown
/// in the readout disc and the "Save Bearing" action). Wraps the pure
/// [BearingCaptureController] so the screen never touches sensor streams
/// directly — it reads the live heading from [compassControllerProvider].
class BearingCaptureUiState {
  const BearingCaptureUiState({
    required this.mode,
    this.rangeStartDeg,
    this.lastCaptured,
    this.singleUncertaintyDeg = 12.0,
  });

  final CaptureMode mode;
  final double? rangeStartDeg;
  final CapturedBearing? lastCaptured;
  final double singleUncertaintyDeg;

  BearingCaptureUiState copyWith({
    CaptureMode? mode,
    double? rangeStartDeg,
    bool clearRangeStart = false,
    CapturedBearing? lastCaptured,
    double? singleUncertaintyDeg,
  }) {
    return BearingCaptureUiState(
      mode: mode ?? this.mode,
      rangeStartDeg: clearRangeStart ? null : (rangeStartDeg ?? this.rangeStartDeg),
      lastCaptured: lastCaptured ?? this.lastCaptured,
      singleUncertaintyDeg: singleUncertaintyDeg ?? this.singleUncertaintyDeg,
    );
  }
}

@riverpod
class BearingCaptureUi extends _$BearingCaptureUi {
  final _controller = BearingCaptureController();

  @override
  BearingCaptureUiState build() {
    return const BearingCaptureUiState(mode: CaptureMode.singlePoint);
  }

  void setMode(CaptureMode mode) {
    _controller.setMode(mode);
    state = state.copyWith(mode: mode, clearRangeStart: true);
  }

  void setUncertainty(double deg) {
    state = state.copyWith(singleUncertaintyDeg: deg);
  }

  /// Captures a single-point bearing from the current live heading.
  void captureSingle() {
    final heading = ref.read(compassControllerProvider).magneticHeadingDeg;
    if (heading == null) return;
    final captured = _controller.captureSinglePoint(
      heading,
      uncertaintyDeg: state.singleUncertaintyDeg,
    );
    state = state.copyWith(lastCaptured: captured);
  }

  /// Marks the start of a range sweep at the current live heading.
  void markRangeStart() {
    final heading = ref.read(compassControllerProvider).magneticHeadingDeg;
    if (heading == null) return;
    _controller.markRangeStart(heading);
    state = state.copyWith(rangeStartDeg: heading);
  }

  /// Marks the end of a range sweep at the current live heading, resolving
  /// the captured bearing.
  void markRangeEnd() {
    final heading = ref.read(compassControllerProvider).magneticHeadingDeg;
    if (heading == null) return;
    final captured = _controller.markRangeEnd(heading);
    if (captured == null) return;
    state = state.copyWith(lastCaptured: captured, clearRangeStart: true);
  }

  void cancelRange() {
    _controller.cancelRange();
    state = state.copyWith(clearRangeStart: true);
  }

  void clearCaptured() {
    state = BearingCaptureUiState(
      mode: state.mode,
      singleUncertaintyDeg: state.singleUncertaintyDeg,
    );
  }
}
