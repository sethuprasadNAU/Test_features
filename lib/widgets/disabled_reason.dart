/// **A disabled control says why on the control, never in a tooltip.**
///
/// Task 11.99 established this for `projects_screen.dart`'s row menu, with the
/// doc comment *"Disabled with the reason on the item, not in a tooltip."* Task
/// 11.94's sweep then found the same defect surviving next door: eight controls
/// in `log_screen.dart` and `map_screen.dart` put their *disabled reason* in a
/// [Tooltip] while their own text label was perfectly visible.
///
/// **A tooltip needs a hover or a long press.** On a phone — which is where this
/// app is used, in a field, one-handed — a hover does not exist and nobody long-
/// presses a row that is already greyed out. So the person saw a greyed control
/// and no reason at all, which is indistinguishable from the app being broken.
///
/// This file holds 11.99's shape, lifted out of that screen so there is one of
/// it rather than three copies: [reasonedMenuItem] for a popup menu entry, and
/// [DisabledReasonNote] for a row of buttons, where a second line on each button
/// would repeat the same sentence three times.
///
/// A tooltip is still right for a control whose *label* is a bare icon and whose
/// meaning is otherwise unguessable — that is the different defect task 11.101
/// counted, and the `more_vert` overflow trigger is its standing exemption.
library;

import 'package:flutter/material.dart';

/// One popup-menu entry: a label, optionally an icon, and — when there is one —
/// a second line saying what it does or why it is unavailable.
///
/// [note] is shown whether or not the item is [enabled]: the same second line
/// carries a description on an available item and the reason on an unavailable
/// one, which is why an unavailable item is shown at all rather than hidden.
PopupMenuItem<T> reasonedMenuItem<T>(
  BuildContext context, {
  required T value,
  required String label,
  IconData? icon,
  String? note,
  bool enabled = true,
  bool destructive = false,
}) {
  final theme = Theme.of(context);
  final colour = !enabled
      ? theme.disabledColor
      : destructive
      ? theme.colorScheme.error
      : null;
  return PopupMenuItem<T>(
    value: value,
    enabled: enabled,
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (icon != null) ...[
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Icon(icon, size: 20, color: colour),
          ),
          const SizedBox(width: 12),
        ],
        Flexible(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(label, style: TextStyle(color: colour)),
              if (note != null)
                Text(
                  note,
                  style: theme.textTheme.bodySmall?.copyWith(color: colour),
                ),
            ],
          ),
        ),
      ],
    ),
  );
}

/// The reason a nearby control is disabled, as a line of text under it.
///
/// For the map's selection card, where two or three buttons share one verdict:
/// a second line on each button would say the same sentence twice, and the card
/// is the surface task 11.133 was shrinking rather than one with room to spare.
/// It takes no height at all while the controls are usable — [reason] is null
/// then — so the cost is paid only by the person who needs the sentence.
class DisabledReasonNote extends StatelessWidget {
  const DisabledReasonNote({super.key, required this.reason});

  /// Null when the controls are available, and nothing is rendered.
  final String? reason;

  /// The gap between the control above and the sentence.
  static const _topPadding = 4.0;

  /// **How tall this note will be**, for a caller that has to reserve the
  /// space before laying it out.
  ///
  /// Task 11.139. The Position screen's save row is a fixed-height box, and
  /// task 11.138 sized it by measuring this sentence **once, at the default
  /// system text size**. A sentence that wraps does not grow smoothly with
  /// the text size — it grows a whole line at a time, at widths nobody can
  /// predict — so **at one notch above the default the sentence was 24
  /// logical pixels taller than the box and the panel rendered with the
  /// yellow-and-black overflow stripe.**
  ///
  /// So the caller asks instead of guessing. [maxWidth] is the width the note
  /// will be laid out in; the ambient text scaler and theme come from
  /// [context], which is what makes the answer follow the phone's setting.
  static double heightFor(
    BuildContext context, {
    required String? reason,
    required double maxWidth,
  }) {
    if (reason == null) return 0;
    final theme = Theme.of(context);
    final painter = TextPainter(
      text: TextSpan(
        text: reason,
        style: theme.textTheme.bodySmall?.copyWith(color: theme.disabledColor),
      ),
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
    )..layout(maxWidth: maxWidth);
    final height = painter.height;
    painter.dispose();
    return _topPadding + height;
  }

  @override
  Widget build(BuildContext context) {
    final reason = this.reason;
    if (reason == null) return const SizedBox.shrink();
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: _topPadding),
      child: Text(
        reason,
        style: theme.textTheme.bodySmall?.copyWith(color: theme.disabledColor),
      ),
    );
  }
}
