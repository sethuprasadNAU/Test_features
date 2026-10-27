import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';

import '../core/errors/failure_message.dart';

/// **What a screen shows when the thing it was loading did not load.**
///
/// Task 11.105 follow-up, 2026-08-31. Twenty-nine `.when(error: …)` branches
/// rendered `Text('Error: $e')` or a near-relative. What a person actually met,
/// when a repository failed to open, was a screen containing the word "Error"
/// and then a database exception carrying an SQL statement and their own field
/// data — with no indication of whether anything had been lost, and nothing to
/// do next.
///
/// **These twenty-nine were not twenty-nine judgment calls.** They are one
/// situation — *a provider this screen needs did not resolve* — so they get one
/// answer, in one place, and a screen that wants to say something better than
/// the default says it by passing a better [what].
///
/// ## What it says, and why
///
/// - **Names the thing, not the mechanism.** "Could not load the tag list"
///   rather than an exception. [what] is a noun phrase that completes *"Could
///   not load ___"* — "the tag list", "this project", "your profile".
/// - **Says whether anything was lost**, because that is the question somebody
///   in the field actually has, and for a failed *read* the answer is always
///   no. A screen where that is not true must not use this widget.
/// - **Ends with something to try.** The standing rule from task 11.104.
/// - **Shows the real error in a debug build only.** Not behind a tap: a
///   "Details" expander is still showing it, and the text can carry the
///   person's own data. A developer running a debug build is a different
///   audience with a different need, and `kDebugMode` is the line between them.
///   The raw text is not lost to diagnosis — it still reaches the console.
class LoadFailure extends StatelessWidget {
  const LoadFailure(
    this.what, {
    super.key,
    this.error,
    this.centered = true,
  });

  /// A noun phrase completing "Could not load ___" — *"the tag list"*, *"this
  /// project"*. Lower case, no trailing full stop.
  final String what;

  /// The caught error. Used only to look for a message this app authored for a
  /// person ([describeFailure]); it is never rendered raw in a release build.
  final Object? error;

  /// Whether to centre in the available space. False for the cases that sit
  /// inline in a list or column, where centring would push the text away from
  /// the thing it is about.
  final bool centered;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final message = describeFailure(
      error,
      fallback:
          'Could not load $what; nothing has been lost. Open this screen '
          'again to retry, and report it if this keeps happening.',
    );

    final content = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: centered
          ? CrossAxisAlignment.center
          : CrossAxisAlignment.start,
      children: [
        Text(
          message,
          textAlign: centered ? TextAlign.center : TextAlign.start,
          style: theme.textTheme.bodyMedium,
        ),
        // Debug builds only — see this class's doc for why this is not an
        // expander a user could open.
        if (kDebugMode && error != null) ...[
          const SizedBox(height: 12),
          Text(
            '$error',
            textAlign: centered ? TextAlign.center : TextAlign.start,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.error,
              fontFamily: 'monospace',
            ),
          ),
        ],
      ],
    );

    final padded = Padding(
      padding: const EdgeInsets.all(24),
      child: content,
    );
    return centered ? Center(child: padded) : padded;
  }
}
