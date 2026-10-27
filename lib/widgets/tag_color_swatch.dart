import 'package:flutter/material.dart';

/// Parses a [Tag.colorHex] value (`"#RRGGBB"`, validated at the data layer —
/// see `TagColorPalette`) into a [Color]. Shared by every place on the Main
/// Map and elsewhere that needs a tag's color as a `Color` rather than a
/// swatch widget, so the hex-parsing logic lives in exactly one place.
Color tagColorFromHex(String colorHex) =>
    Color(int.parse(colorHex.substring(1), radix: 16) + 0xFF000000);

/// Small filled circle rendering a [Tag.colorHex] value. Always paired with
/// the tag's existing text label wherever it's used; color is never the only
/// cue a row carries (Phase 4, "Tag Color Coding").
class TagColorSwatch extends StatelessWidget {
  const TagColorSwatch({super.key, required this.colorHex, this.size = 14});

  final String colorHex;
  final double size;

  @override
  Widget build(BuildContext context) {
    final color = tagColorFromHex(colorHex);
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        border: Border.all(color: Theme.of(context).colorScheme.outline, width: 1),
      ),
    );
  }
}

/// A compact overlapping stack of up to [maxShown] tag-color swatches, for
/// rows that reference *multiple* tags (e.g. a non-detection's
/// `tagIdsListenedFor`) rather than the single-swatch treatment used for a
/// 1:1 tag reference. Overflow beyond [maxShown] collapses into a "+N"
/// label rather than growing unbounded.
class TagColorSwatchStack extends StatelessWidget {
  const TagColorSwatchStack({
    super.key,
    required this.colorHexes,
    this.maxShown = 4,
    this.swatchSize = 14,
    this.overlap = 8,
  });

  final List<String> colorHexes;
  final int maxShown;
  final double swatchSize;
  final double overlap;

  @override
  Widget build(BuildContext context) {
    final shown = colorHexes.take(maxShown).toList();
    final extra = colorHexes.length - shown.length;
    final stackWidth = shown.isEmpty
        ? 0.0
        : swatchSize + (shown.length - 1) * overlap;
    return SizedBox(
      width: stackWidth + (extra > 0 ? 16 : 0),
      height: swatchSize,
      child: Stack(
        children: [
          for (var i = 0; i < shown.length; i++)
            Positioned(
              left: i * overlap,
              child: TagColorSwatch(colorHex: shown[i], size: swatchSize),
            ),
          if (extra > 0)
            Positioned(
              left: shown.length * overlap + 2,
              top: 1,
              child: Text(
                '+$extra',
                style: TextStyle(
                  fontSize: 9,
                  fontWeight: FontWeight.w700,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ),
        ],
      ),
    );
  }
}
