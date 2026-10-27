import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// A bordered, multi-option segmented control — the app-wide pattern for
/// mutually-exclusive choices (Directional/Omni, Peak/Null, Single/Range,
/// coordinate format, ...). Active segment fills brand green; others are
/// plain text. Never a dropdown, per the design doc's interaction rules.
class SegmentedToggle<T> extends StatelessWidget {
  const SegmentedToggle({
    super.key,
    required this.options,
    required this.selected,
    required this.onChanged,
    this.height = 40,
    this.iconFor,
  });

  final List<(T value, String label)> options;
  final T selected;
  final ValueChanged<T> onChanged;
  final double height;

  /// **Optional: draw each segment as an icon instead of its word** (task
  /// 11.197). Michael, having used the Record screen in the field: *"the
  /// record type selector looks crowded with text all the way up to the
  /// vertical separator lines."*
  ///
  /// **The selected segment keeps its word; the others show only their
  /// icon.** That is the whole of the compromise, and it is deliberate.
  /// `CLAUDE.md`'s rule is that a colour never carries a meaning on its own
  /// — a filled green segment with a wordless glyph in it would be exactly
  /// that, on the one control in this app that decides *what kind of record
  /// gets written*. Getting it wrong is a wrong row in somebody's data, not
  /// a wrong-looking screen. Keeping the word on the selected segment costs
  /// one short label and answers *what am I recording right now* without
  /// anybody having to learn five glyphs first; the unselected four give
  /// back the width, and a person finds out what they are by pressing one,
  /// which is the exploration the same rule licences.
  ///
  /// **Every segment carries its word as a `Semantics` label either way**,
  /// so a screen reader is told the same five things whether or not the ink
  /// is there. That is not optional: an icon-only control is silent to a
  /// screen reader unless somebody says the word for it.
  final IconData Function(T value)? iconFor;

  // **Task 11.203: `Container`'s `clipBehavior` clips its child to the
  // decoration's OUTER rounded path, not the inner one the border leaves
  // behind.** A `BoxDecoration`'s border is painted with the background,
  // before the child, and it insets the child by its own width — which is
  // why the straight edges are clean. In a corner, though, the inset
  // rectangle's corner reaches past the inner arc, so the child (painted
  // after the border) covers the ink it finds there. The fix is to clip the
  // child itself to the inner rounded rect, derived from the two numbers
  // that produce it rather than typed as a third.
  static const double _borderWidth = 1.5;
  static const double _outerRadius = 10;
  static const double _innerRadius = _outerRadius - _borderWidth;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      height: height,
      decoration: BoxDecoration(
        border: Border.all(color: scheme.onSurface, width: _borderWidth),
        borderRadius: BorderRadius.circular(_outerRadius),
      ),
      clipBehavior: Clip.antiAlias,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(_innerRadius),
        child: Row(
          children: [
            for (var i = 0; i < options.length; i++)
              Expanded(
                child: _Segment(
                  // **A stable handle for each segment, because a segment
                  // showing only an icon has no text to find** (task 11.197).
                  // Derived from the option's own word rather than written out
                  // again, so a rename moves both.
                  key: ValueKey('segment:${options[i].$2}'),
                  label: options[i].$2,
                  icon: iconFor?.call(options[i].$1),
                  isActive: options[i].$1 == selected,
                  isFirst: i == 0,
                  onTap: () {
                    HapticFeedback.selectionClick();
                    onChanged(options[i].$1);
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _Segment extends StatelessWidget {
  const _Segment({
    super.key,
    required this.label,
    required this.icon,
    required this.isActive,
    required this.isFirst,
    required this.onTap,
  });

  final String label;
  final IconData? icon;
  final bool isActive;
  final bool isFirst;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final fg = isActive ? scheme.onPrimary : scheme.onSurface;
    return Semantics(
      button: true,
      selected: isActive,
      // **The word, always** — including on the four segments that are
      // showing nothing but a glyph. `ExcludeSemantics` below drops the
      // painted label so that a segment reads once rather than twice; on an
      // icon-only segment there is nothing under it to read at all, and
      // without this the control would be silent.
      label: label,
      child: ExcludeSemantics(
        child: GestureDetector(
          onTap: onTap,
          behavior: HitTestBehavior.opaque,
          child: Container(
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: isActive ? scheme.primary : null,
              border: !isFirst
                  ? Border(left: BorderSide(color: scheme.onSurface, width: 1))
                  : null,
            ),
            // Scale down rather than ellipsize. A five-option control (the
            // Record screen's, once task 11.33 added Truth) leaves each
            // segment about 70dp on a phone, which clipped "Directional" to
            // "Direct…" — a segment whose label cannot be read is not a
            // choice. Nothing changes where the label already fits.
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: icon == null
                  ? _text(fg)
                  : (isActive
                      // Icon and word, on the segment whose answer is
                      // currently being written. `MainAxisSize.min` so
                      // `FittedBox` still scales the pair down rather than
                      // letting it clip.
                      ? Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(icon, size: 16, color: fg),
                            const SizedBox(width: 5),
                            _text(fg),
                          ],
                        )
                      : Icon(icon, size: 20, color: fg)),
            ),
          ),
        ),
      ),
    );
  }

  Widget _text(Color fg) => Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        textAlign: TextAlign.center,
        style: TextStyle(
          fontSize: 12.5,
          fontWeight: FontWeight.w700,
          color: fg,
        ),
      );
}
