import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'computation_status_provider.g.dart';

/// Status of a long-running computation (Lenth MLE solve, viewshed raster).
/// Drives the bottom progress bar the design doc requires for these ops.
sealed class ComputationStatus {
  const ComputationStatus();
}

class ComputationIdle extends ComputationStatus {
  const ComputationIdle();
}

class ComputationRunning extends ComputationStatus {
  const ComputationRunning({required this.label, this.progress});

  /// e.g. "Computing viewshed…" / "Solving position…"
  final String label;

  /// 0.0-1.0, or null if the operation can't report granular progress.
  final double? progress;
}

class ComputationDone extends ComputationStatus {
  const ComputationDone({required this.label});

  final String label;
}

class ComputationFailed extends ComputationStatus {
  const ComputationFailed({required this.label, required this.message});

  final String label;
  final String message;
}

// **Every write below is dropped once this provider has been disposed**
// (task 11.318 item 5). A computation outlives the screen that started it by
// design -- the viewshed deliberately reports its result here even after the
// map is closed, so the bar is never left showing "Computing viewshed..." --
// and so it can also outlive the whole provider container. In the app the
// bottom bar keeps this provider alive, so nothing is ever dropped. In a test
// the container is torn down while the calculation is still running, and the
// late write raised `UnmountedRefException` "after the test had completed",
// charged to whichever test happened to be running next. Checking `ref.mounted`
// here, once, covers every caller; checking it in each caller would have to
// be remembered by each new one.
@riverpod
class ComputationStatusNotifier extends _$ComputationStatusNotifier {
  @override
  ComputationStatus build() => const ComputationIdle();

  void start(String label, {double? progress}) {
    if (!ref.mounted) return;
    state = ComputationRunning(label: label, progress: progress);
  }

  void updateProgress(double progress) {
    if (!ref.mounted) return;
    final current = state;
    if (current is ComputationRunning) {
      state = ComputationRunning(label: current.label, progress: progress);
    }
  }

  void complete(String label) {
    if (!ref.mounted) return;
    state = ComputationDone(label: label);
  }

  void fail(String label, String message) {
    if (!ref.mounted) return;
    state = ComputationFailed(label: label, message: message);
  }

  void reset() {
    if (!ref.mounted) return;
    state = const ComputationIdle();
  }
}
