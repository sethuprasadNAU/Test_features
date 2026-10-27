/// **Task 11.257 — a fixed-height box around a `FilledButton` clips its own
/// label at large text sizes, and it was the same defect on four screens.**
///
/// `identity_setup_screen.dart`, `profile_screen.dart`,
/// `server_config_screen.dart` and `project_setup_screen.dart` each wrapped a
/// primary `FilledButton` in a `SizedBox` with an **exact** height —
/// `DesignTokens.minTouchTarget` or a literal `48` — so that button could
/// never be shorter than a touch target, but also could never be taller than
/// one either. At *Larger Accessibility Sizes*, the button's own label needs
/// a few pixels more line height than that fixed box allows, and `Text` has
/// no `maxLines` set, so the framework does not stripe an overflow — it
/// silently clips the bottom of the word. `CONTINUE`, `SAVE` (twice) and
/// `SAVE PROJECT` all lost about 6-9% of their height this way, found by
/// `test/features/clipped_text_sweep_test.dart`.
///
/// **The fix is a floor, not a ceiling**: a [ConstrainedBox] with a
/// `minHeight` lets the button grow to fit its label when the label needs
/// more room, while still guaranteeing the touch target at ordinary text
/// sizes. Nothing about the button's *appearance* changes at any size this
/// project has ever shipped — it only stops refusing the button the height
/// its own label asks for.
library;

import 'package:flutter/material.dart';

import '../core/theme/design_tokens.dart';

/// A full-width primary action button that shows a small spinner in place of
/// its label while [saving] is true.
///
/// Used for the one pinned "commit this form" button a screen has — CONTINUE,
/// SAVE, SAVE PROJECT — never for a secondary action, which is why there is
/// no `child` slot: every caller of this shape wants exactly a label and a
/// saving state, and a slot would invite the fixed-height mistake right back
/// in on whatever gets put in it.
class SavingFilledButton extends StatelessWidget {
  const SavingFilledButton({
    super.key,
    required this.label,
    required this.onPressed,
    required this.saving,
    this.minHeight = DesignTokens.minTouchTarget,
  });

  final String label;
  final VoidCallback? onPressed;
  final bool saving;

  /// The touch-target floor. Defaults to [DesignTokens.minTouchTarget];
  /// `project_setup_screen.dart` passes its own `48` to keep its existing
  /// look at ordinary text sizes.
  final double minHeight;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      child: ConstrainedBox(
        constraints: BoxConstraints(minHeight: minHeight),
        child: FilledButton(
          onPressed: onPressed,
          child: saving
              ? const SizedBox(
                  height: 20,
                  width: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(label, style: const TextStyle(fontWeight: FontWeight.w800)),
        ),
      ),
    );
  }
}
