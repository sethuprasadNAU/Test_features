/// **The one place that decides what a person sees when a write does not
/// happen.**
///
/// Task 11.137, 2026-09-02, from task 11.94's sweep. Thirteen UI-facing call
/// sites in `lib/` awaited a repository write with no `try`/`catch` at all. A
/// refused delete, save, share, supersede, exclude or export showed **nothing**
/// — no message, no dialog, nothing. **It looks exactly like a tap that did not
/// register**, and a tap that does nothing gets repeated rather than reported.
///
/// ## Why one mechanism rather than thirteen catch blocks
///
/// Thirteen bespoke handlers is thirteen future divergences, which is the
/// hand-maintained-repetition shape this project keeps finding. [runGuardedWrite]
/// is the single seam; the call site supplies the two sentences and nothing
/// else.
///
/// ## Refused is not failed, and they must not be flattened
///
/// - **Refused** — [UnauthorizedMutation]. The write was understood and the
///   person is not permitted to make it. Nothing is wrong with the app or the
///   device; the answer is a role change or a different person. The sentence
///   for it is the [refused] argument, authored at the call site because only
///   the call site knows which right was missing.
/// - **Failed** — anything else: a disk error, a database fault, a bug. The
///   sentence is [describeFailure]'s, which returns an authored message when
///   the app has one for that exception type and the call site's [failed]
///   fallback otherwise.
///
/// Naming the wrong one of those two is the wrong-cause class this project has
/// corrected repeatedly (tasks 11.84, 11.104, 11.122). Telling somebody they
/// lack permission when the disk is full sends them to their project owner for
/// a fault an owner cannot fix.
///
/// ## What it does not do
///
/// It does not decide whether the control should have been offered. That is the
/// pre-check's job (task 11.12), and a refusal reaching here is normally the
/// documented race — the moment between a role change and a rebuild. This is the
/// backstop, and a backstop that says nothing is not one.
library;

import 'package:flutter/material.dart';

import '../../data/repositories/mutation_authorization.dart';
import 'failure_message.dart';

/// The snackbar shown when the person was not permitted to make the write.
const writeRefusedKey = ValueKey<String>('write_refused');

/// The snackbar shown when the write was permitted and went wrong anyway.
const writeFailedKey = ValueKey<String>('write_failed');

/// Runs [write], and says something if it does not happen.
///
/// Returns true when [write] completed. Returns false when it was refused or
/// failed — in which case a message has already been shown, and the caller
/// should stop rather than announce a success or invalidate anything.
///
/// A caller that needs a value out of [write] assigns it inside the closure;
/// the return is deliberately a plain bool so there is exactly one signature to
/// learn.
///
/// [refused] is what a person reads when they were not permitted: say which
/// right was missing and who has it. **It is `required` and nullable rather
/// than defaulted**, so an author has to decide: a sentence, or an explicit
/// `null` meaning *no write right governs this action, and a refusal here would
/// be a bug in the app.* Sharing a record and saving a CSV are the `null` cases
/// — they read data out and write nothing. A `null` that is wrong fails safely:
/// the refusal is reported through [failed], which asserts no cause and ends in
/// something to try, rather than telling somebody they lack a permission the
/// code never checked.
///
/// [failed] is the fallback for everything else: per [describeFailure], name the
/// action, say whether anything was lost, and end with something to try.
Future<bool> runGuardedWrite(
  BuildContext context, {
  required Future<void> Function() write,
  required String? refused,
  required String failed,
}) async {
  try {
    await write();
    return true;
  } on UnauthorizedMutation catch (error) {
    if (!context.mounted) return false;
    final sentence = refused;
    if (sentence == null) {
      _say(context, writeFailedKey, describeFailure(error, fallback: failed));
    } else {
      // Task 11.237: a call site's [refused] is written for a viewer — it
      // names a role and says to ask for a better one. Somebody holding a
      // read-only snapshot of a colleague's project has no role at all, and
      // the one sentence that is true for them names the join code instead.
      // Answered here so every guarded write inherits it rather than each
      // call site remembering a second sentence.
      _say(
        context,
        writeRefusedKey,
        error.refusalSentence(asViewer: sentence),
      );
    }
    return false;
  } catch (error) {
    if (!context.mounted) return false;
    _say(context, writeFailedKey, describeFailure(error, fallback: failed));
    return false;
  }
}

/// Shows [message], or gives up quietly when there is nowhere to show it.
///
/// The give-up branch is real and is not a swallowed error: a widget with no
/// [ScaffoldMessenger] above it has no bottom of a screen to put a bar at, and
/// there is nothing to fall back to — an app-modal dialog needs a navigator,
/// which is the same missing ancestor. The other case, an unmounted context,
/// is checked by the caller: the person has already left the screen.
void _say(BuildContext context, ValueKey<String> key, String message) {
  final messenger = ScaffoldMessenger.maybeOf(context);
  if (messenger == null) return;
  // Otherwise a second refusal queues behind the first instead of replacing it
  // — the same defect the undo bars fixed in task 11.42.
  messenger.clearSnackBars();
  messenger.showSnackBar(
    SnackBar(
      key: key,
      content: Text(message),
      // Long enough to read a sentence that explains a refusal. `persist` is
      // stated rather than left to default (task 11.42): with no action it is
      // already false, and saying so means adding an action later cannot
      // silently strand this duration.
      duration: const Duration(seconds: 8),
      persist: false,
    ),
  );
}
