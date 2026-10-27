import 'package:flutter/widgets.dart';

/// A hold-to-sweep gesture that tracks one raw pointer, so a thumb sliding
/// while held does not lose the sweep — only that same finger's lift ends
/// it, wherever it has wandered, and a second finger elsewhere does nothing.
///
/// A tap-gesture recognizer (`GestureDetector`'s `onTapDown`/`onTapUp`) gives
/// up once a finger slides more than a few pixels, which is what *Take on
/// map* (task 11.315) needed to avoid for its range sweep, and built as a
/// raw [Listener] rather than a recognizer. Task 11.317 item 3 moved RANGE's
/// own hold onto this same detector — measured in a throwaway widget test, a
/// 30-pixel slide (about 3 mm) used to lose RANGE's bearing — rather than
/// writing a third copy of the mechanism.
class RawHoldGestureDetector extends StatelessWidget {
  const RawHoldGestureDetector({
    super.key,
    required this.enabled,
    required this.onStart,
    required this.onEnd,
    required this.onCancel,
    required this.child,
  });

  /// Gates only [onStart] — a hold already in progress must still be told
  /// about its own release even if disabled mid-hold.
  final bool enabled;
  final void Function(int pointer) onStart;
  final void Function(int pointer) onEnd;
  final void Function(int pointer) onCancel;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.opaque,
      onPointerDown: enabled ? (e) => onStart(e.pointer) : null,
      onPointerUp: (e) => onEnd(e.pointer),
      onPointerCancel: (e) => onCancel(e.pointer),
      child: child,
    );
  }
}
