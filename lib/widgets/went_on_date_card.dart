import 'package:flutter/material.dart';

import '../data/repositories/deployment_linking.dart' show formatLinkDate;

/// **The date a tag went on — in a colored card, with a Change button.**
///
/// Quick add built this (task 11.321) because every bearing's animal is worked
/// out from the date, so it must not look like one field among fields. Task
/// 11.322 reuses it on the *Link a tag* confirmation, at Michael's request
/// ("the same as Quick add's 'Tags went on'"): one control, one look, so a
/// person who learned it in one place knows it in the other.
///
/// The widget only shows the date and reports a tap on Change; the caller owns
/// the picker and every rule about which dates are allowed.
class WentOnDateCard extends StatelessWidget {
  const WentOnDateCard({
    super.key,
    required this.label,
    required this.date,
    required this.isToday,
    required this.onChange,
    this.textKey,
    this.buttonKey,
    this.timeZone,
  });

  /// "Tags went on" for many, "Tag went on" for one.
  final String label;
  final DateTime date;
  final bool isToday;
  final VoidCallback onChange;

  /// Keys for the date text and the Change button, for the tests of whichever
  /// screen uses this.
  final Key? textKey;
  final Key? buttonKey;

  /// The zone [date] is a day in — the project's (task 11.331). The card
  /// prints the field's date, never the reading phone's.
  final String? timeZone;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Card(
      color: scheme.secondaryContainer,
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
        child: Row(
          children: [
            Icon(Icons.event, color: scheme.onSecondaryContainer),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: theme.textTheme.labelLarge?.copyWith(
                      color: scheme.onSecondaryContainer,
                    ),
                  ),
                  Text(
                    isToday
                        ? '${formatLinkDate(date, timeZone)} (today)'
                        : formatLinkDate(date, timeZone),
                    key: textKey,
                    style: theme.textTheme.titleLarge?.copyWith(
                      color: scheme.onSecondaryContainer,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
            TextButton(
              key: buttonKey,
              onPressed: onChange,
              child: const Text('Change'),
            ),
          ],
        ),
      ),
    );
  }
}
