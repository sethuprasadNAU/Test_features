/// **The one place that decides what a person is told when something fails.**
///
/// Task 11.105 follow-up, 2026-08-31, at Michael's decision. Sixty places in
/// `lib/` built a message by pasting a caught exception into a string — `'$e'`
/// — and forty-six of them put the result on screen.
///
/// ## What that costs somebody
///
/// A biologist tapping *Import* on a tag CSV and getting:
///
/// > Import failed — nothing was saved. DatabaseException(UNIQUE constraint
/// > failed: Tags.tag_id) sql 'INSERT INTO Tags (tag_id, tag_name,
/// > frequency_mhz) VALUES (?, ?, ?)' args [f4a2-9c1…, Collar 12, 150.520]
///
/// Three separate failures in one sentence. It means nothing to the reader; it
/// says nothing to do about it; and it spills the database's internals and the
/// person's own field data onto a screen that may well be photographed and
/// emailed to somebody for help.
///
/// **This is the project's third instance of it.** Task 11.46 removed exactly
/// this interpolation from the publish path in `projects_screen.dart` and left
/// a twenty-line comment saying it must never come back — and nobody swept for
/// the other forty-five. That is the shape task 11.98 established the checked
/// answer for, and `test/documentation/raw_error_in_ui_test.dart` is the check.
///
/// ## The rule
///
/// **Never show a person an exception whose message you did not write for
/// them.** Not "never show an exception": a few of this app's own exceptions
/// carry a sentence composed for exactly this purpose, and hiding those behind
/// a generic fallback would be the opposite defect — the wrong-cause class task
/// 11.104 exists to correct. [describeFailure] is the seam that tells the two
/// apart, and [_authoredMessages] is the list of types that have earned it.
///
/// **The bar for joining that list** is not "the message reads nicely". It is:
///
/// 1. **Written for a person**, not for a log. No class names, no stack, no
///    nested `toString()` of some other exception.
/// 2. **Carries no identifier and no user data.** A project UUID, a row key,
///    an email, a tag name, an SQL statement or its bound values all
///    disqualify it. This is why `UnauthorizedMutation`, `LastOwnerRemoval`,
///    `NotAProjectMember` and `PublishNotYoursToMake` are *not* on the list
///    despite being this app's own types — every one of them ends in a raw
///    UUID.
/// 3. **Ends with something to try.** The standing rule from task 11.104: a
///    diagnosis somebody cannot act on is not help.
///
/// A type that fails any of the three gets a fallback written at the call site,
/// where the code knows what the person was doing.
library;

import '../providers/provider_error.dart';
import '../../data/sync/sync_transport.dart' show SyncTransportException;

/// **What to tell a person about [error], given what they were doing.**
///
/// [fallback] is the sentence for everything this app cannot explain, and it
/// is required rather than defaulted **because a generic sentence written once
/// and reused everywhere is only marginally better than the raw exception it
/// replaced.** The call site knows what was being attempted; it should say so,
/// say whether anything was lost, and say what to try.
///
/// A good fallback names the action, reassures about the data, and ends with a
/// next step — for example: *"Could not save this observation. Nothing has been
/// lost — it is still on the form. Try again, and report it if it keeps
/// happening."*
String describeFailure(Object? error, {required String fallback}) {
  if (error == null) return fallback;

  // A provider boundary may have wrapped it (see `provider_error.dart` for the
  // measurements — this happens at synchronous reads and `requireValue`, not
  // at an awaited `.future`). Unwrapping first means a type test below works
  // regardless of which read the error came through.
  final cause = unwrapProviderError(error);

  // The one case where the honest answer is "nobody can know": Riverpod
  // destroyed the original when it tore the provider down mid-load. There is
  // nothing to consult, and naming a cause anyway is the defect this whole
  // family of tasks exists to correct.
  if (providerErrorWasDestroyed(cause)) return fallback;

  for (final authored in _authoredMessages) {
    final message = authored(cause);
    if (message != null && message.isNotEmpty) return message;
  }
  return fallback;
}

/// Extractors for the exception types whose message was written for a person.
///
/// Each returns null when it does not recognise the error, so the list is
/// order-independent and adding one cannot break another. **Every entry here
/// is asserted against the three-point bar in
/// `test/core/errors/failure_message_test.dart`** — an entry whose message
/// starts carrying a UUID fails that test rather than quietly reaching a
/// screen.
final List<String? Function(Object)> _authoredMessages = [
  // Its `userMessage` is explicitly the client-authored half — nullable, and
  // null exactly when there is nothing specific to say, which is the fallback's
  // case. See `SyncTransportException.userMessage`.
  (e) => e is SyncTransportException ? e.userMessage : null,
];

// **`InvalidServerUrl` was the second entry here, and it was dead code.**
// Written on the reasoning that its message is exactly the kind this list is
// for — authored, per-fault, ending in what to try. Task 11.105's guard
// (`test/documentation/provider_boundary_catch_test.dart`) rejected it on the
// first full run, correctly: `requireValidServerUrl` is called from exactly
// one place, `serverHttpClient`'s build, which is autoDispose — so the
// exception is destroyed at the provider boundary and no `describeFailure`
// caller can ever be handed one.
//
// Recorded rather than silently dropped, because it is the guard working on
// new code written by somebody who had just spent a day on this exact defect
// and reintroduced it anyway. **The sentence is not lost:** it reaches people
// through `serverUrlRefusalProvider`, which is 11.104's value path, and
// through `SyncTransportException.serverAddressRefused`'s own `userMessage`.

/// The extractors, exposed for the test that holds them to the bar above.
///
/// Not a general-purpose accessor: nothing in `lib/` should be iterating these
/// — call [describeFailure] instead. It is here so the check can be written
/// against the real list rather than a copy of it, because a check keyed on a
/// retyped list is a hand-maintained list wearing a different hat.
List<String? Function(Object)> get authoredMessageExtractorsForTest =>
    List.unmodifiable(_authoredMessages);
