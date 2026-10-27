import 'package:flutter/material.dart';

/// **The one (i) button in the app.** Task 11.320, 2026-09-30.
///
/// Michael: *"Longer isn't better. Efficient clarity is better. Longer is only
/// better if it is clearer."* So a screen says what a person needs to know or do
/// in a sentence or two, and anything longer that is still genuinely needed — a
/// destructive act, a safety point, a state nobody would guess — sits behind
/// this button rather than in permanent space.
///
/// Before this there was no shared one and several screens hand-rolled an info
/// icon, each with its own size, tooltip and dialog. One widget means one
/// behavior to learn and one place to keep it accessible:
///
/// - **A screen reader reads it** — the [tooltip] is its semantic label, so it
///   is announced as "More about …, button" rather than as an icon.
/// - **At every text size** — the detail opens in a scrolling dialog, so a long
///   explanation at the largest text size scrolls instead of clipping.
/// - **The tap target stays 48 points**, whatever the icon's drawn size.
class InfoButton extends StatelessWidget {
  const InfoButton({
    super.key,
    required this.title,
    required this.detail,
    this.tooltip,
    this.detailKey,
    this.color,
    this.size = 18,
  });

  /// The dialog's title — a short noun phrase naming the topic.
  final String title;

  /// The explanation. Blank lines separate paragraphs.
  final String detail;

  /// What a screen reader and a long press say. Defaults to "More about
  /// [title]".
  final String? tooltip;

  /// A key for the dialog, so a test can find what the button opened.
  final Key? detailKey;

  /// The icon's color. Defaults to the theme's muted foreground.
  final Color? color;

  /// The icon's drawn size. The tap target does not shrink with it.
  final double size;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      icon: Icon(
        Icons.info_outline,
        size: size,
        color: color ?? Theme.of(context).colorScheme.onSurfaceVariant,
      ),
      tooltip: tooltip ?? 'More about ${title.toLowerCase()}',
      constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
      padding: EdgeInsets.zero,
      onPressed: () => showInfoDetail(
        context,
        title: title,
        detail: detail,
        key: detailKey,
      ),
    );
  }
}

/// Opens the dialog [InfoButton] opens — for a caller that already has its own
/// control, such as a text button reading "Why?".
Future<void> showInfoDetail(
  BuildContext context, {
  required String title,
  required String detail,
  Key? key,
}) {
  return showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      key: key,
      scrollable: true,
      title: Text(title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final (i, paragraph) in detail.split('\n\n').indexed)
            Padding(
              padding: EdgeInsets.only(top: i == 0 ? 0 : 12),
              child: Text(paragraph),
            ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('OK'),
        ),
      ],
    ),
  );
}

/// A short line of text with an [InfoButton] after it — the shape most callers
/// want: the one thing to know on screen, the rest one tap away.
class InfoLine extends StatelessWidget {
  const InfoLine({
    super.key,
    required this.text,
    required this.title,
    required this.detail,
    this.style,
    this.detailKey,
    this.buttonKey,
  });

  final String text;
  final String title;
  final String detail;
  final TextStyle? style;
  final Key? detailKey;
  final Key? buttonKey;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(child: Text(text, style: style)),
        InfoButton(
          key: buttonKey,
          title: title,
          detail: detail,
          detailKey: detailKey,
        ),
      ],
    );
  }
}
