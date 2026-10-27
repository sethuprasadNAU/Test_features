import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// A vertical scroll-wheel selector with haptic tick feedback — the app-wide
/// replacement for dropdowns on categorical fields (design doc: "scroll
/// wheels, not dropdowns, with haptic tick feedback on scroll"). The
/// selected item is centered, enlarged, and brand-colored; neighbors fade by
/// distance, matching the tag-picker treatment in the hi-fi handoff.
class WheelPicker<T> extends StatefulWidget {
  const WheelPicker({
    super.key,
    required this.items,
    required this.selected,
    required this.labelBuilder,
    required this.onChanged,
    this.onSettled,
    this.colorBuilder,
    this.leadingBuilder,
    this.height = 168,
    this.itemExtent = 34,
    this.selectedFontSize = 16,
  });

  final List<T> items;
  final T selected;
  final String Function(T item) labelBuilder;
  final ValueChanged<T> onChanged;

  /// Fired once scrolling comes to rest on an item — i.e. the user has
  /// "released" onto a choice, as opposed to [onChanged] which fires
  /// continuously as items pass under the center marker while flinging/
  /// dragging. Use this for actions that should only happen on a settled
  /// selection (e.g. opening a dialog), never mid-scroll.
  final ValueChanged<T>? onSettled;

  /// Optional per-item color (e.g. a red→green severity gradient). When
  /// null (the default), items keep the plain brand-color-on-select /
  /// fade-by-distance look every other picker in the app uses.
  final Color Function(T item)? colorBuilder;

  /// Optional small leading widget per item (e.g. a tag color swatch),
  /// shown to the left of the label text. Return null for a given item to
  /// render it with no leading (e.g. a "add new" sentinel row). Fades with
  /// the label by selection distance, same as the text.
  final Widget? Function(T item)? leadingBuilder;

  final double height;
  final double itemExtent;

  /// The size of the centred item's label.
  ///
  /// **16 everywhere except the Record screen's tag wheel, which is 18**
  /// (Michael, 2026-09-07). That wheel is the only one on this screen that
  /// carries an identity rather than a category — a frequency, a pulse rate
  /// and an animal's name — and it is the line somebody checks before saving
  /// a record against the wrong collar. It also has the whole width of the
  /// screen, where the three category wheels beside each other have a third
  /// of it each and are already abbreviating to fit.
  ///
  /// **What it costs, said so nobody re-discovers it as a defect:** a long
  /// tag name ellipsises a little sooner. The name is not the identifying
  /// part of that line — the frequency is, and it is at the front.
  final double selectedFontSize;

  @override
  State<WheelPicker<T>> createState() => _WheelPickerState<T>();
}

class _WheelPickerState<T> extends State<WheelPicker<T>> {
  late FixedExtentScrollController _controller;
  late int _lastIndex;

  @override
  void initState() {
    super.initState();
    _lastIndex = widget.items.indexOf(widget.selected).clamp(
          0,
          widget.items.length - 1,
        );
    _controller = FixedExtentScrollController(initialItem: _lastIndex);
  }

  @override
  void didUpdateWidget(covariant WheelPicker<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    final index = widget.items.indexOf(widget.selected);
    if (index >= 0 && index != _controller.selectedItem) {
      _lastIndex = index;
      // Deferred to next frame rather than jumping synchronously here:
      // didUpdateWidget runs mid-build/reconciliation, and jumpToItem
      // immediately mutates the ListWheelScrollView's ScrollPosition and
      // forces its own nested rebuild — that re-entrant mutation while an
      // ancestor scrollable (e.g. the form's outer ListView) is still
      // mid-layout for the same frame is exactly what trips Flutter's
      // "!_doingMountOrUpdate" / sliver child-index assertions (and the
      // "Duplicate GlobalKey" that cascades from the resulting partial
      // unwind/re-inflate). This was hit in practice when saving an
      // observation reset the draft's tag mid-frame, snapping the tag
      // wheel's selected index.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _controller.hasClients) {
          _controller.jumpToItem(index);
        }
      });
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Container(
      height: widget.height,
      decoration: BoxDecoration(
        border: Border.all(color: scheme.onSurface, width: 1.5),
        borderRadius: BorderRadius.circular(12),
      ),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        alignment: Alignment.center,
        children: [
          NotificationListener<ScrollNotification>(
            onNotification: (notification) {
              if (notification is ScrollUpdateNotification) {
                final index = _controller.selectedItem;
                if (index != _lastIndex) {
                  _lastIndex = index;
                  HapticFeedback.selectionClick();
                }
              } else if (notification is ScrollEndNotification) {
                if (widget.onSettled != null && _controller.hasClients) {
                  final index = _controller.selectedItem;
                  if (index >= 0 && index < widget.items.length) {
                    widget.onSettled!(widget.items[index]);
                  }
                }
              }
              return false;
            },
            child: ListWheelScrollView.useDelegate(
              controller: _controller,
              itemExtent: widget.itemExtent,
              diameterRatio: 1.8,
              physics: const FixedExtentScrollPhysics(),
              onSelectedItemChanged: (index) {
                widget.onChanged(widget.items[index]);
              },
              childDelegate: ListWheelChildBuilderDelegate(
                childCount: widget.items.length,
                builder: (context, index) {
                  final item = widget.items[index];
                  final distance = (index - _controller.selectedItem).abs();
                  final isSelected = item == widget.selected;
                  final baseColor = widget.colorBuilder?.call(item) ??
                      (isSelected ? scheme.secondary : scheme.onSurface);
                  final fadeOpacity =
                      isSelected ? 1.0 : (distance == 1 ? 0.55 : 0.3);
                  final label = Text(
                    widget.labelBuilder(item),
                    textAlign: TextAlign.center,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: isSelected
                          ? widget.selectedFontSize
                          : (distance == 1 ? 12.5 : 10.5),
                      fontWeight: isSelected ? FontWeight.w800 : FontWeight.w500,
                      color: isSelected
                          ? baseColor
                          : baseColor.withValues(alpha: fadeOpacity),
                    ),
                  );
                  final leading = widget.leadingBuilder?.call(item);
                  return Center(
                    child: leading == null
                        ? label
                        : Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Opacity(opacity: fadeOpacity, child: leading),
                              const SizedBox(width: 6),
                              // Flexible, not bare: with a leading swatch the
                              // row is `min` and the label is unconstrained,
                              // so a long tag name overflowed the wheel at
                              // phone width. Nothing noticed because every
                              // test that renders this screen pumps it 1200
                              // logical pixels wide (task 11.110).
                              Flexible(child: label),
                            ],
                          ),
                  );
                },
              ),
            ),
          ),
          IgnorePointer(
            child: Container(
              height: widget.itemExtent,
              margin: const EdgeInsets.symmetric(horizontal: 8),
              decoration: BoxDecoration(
                border: Border.symmetric(
                  horizontal: BorderSide(color: scheme.outline, width: 1),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
