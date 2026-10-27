/// Shared field validation for identity capture/edit (`IdentitySetupScreen`,
/// `ProfileScreen`) — kept in one place so the two screens' "malformed input
/// is rejected inline" behavior can never drift apart.
library;

import 'package:tritrack_sync/tritrack_sync.dart';

/// A reasonable-not-strict email shape check: local-part@domain.tld.
final _emailPattern = RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$');

/// Whether a name may be typed here — **asked of the same declaration the
/// server enforces**, not restated (task 11.122, item 1).
///
/// ## Why this stopped being "is it empty"
///
/// Until this task the check was `trim().isEmpty` and nothing else. So a name
/// carrying a control character or a bidirectional override — the two things
/// `RowValidator.isWellFormedPersonName` exists to refuse (task 11.81) —
/// saved without complaint, and the person found out one sync later, when the
/// server refused their whole `Users` row. The row is held once and not
/// retried, and the screen that reports the hold could not tell them why.
/// Checking it where it is typed is the cheap half of closing that.
///
/// **This is a courtesy, not a control.** The bound that matters is still the
/// one at the boundary: `RowValidator` on every write, and the server's own
/// validation on the pushed row. Nothing here weakens or duplicates that —
/// it asks the same two questions of the same two declarations
/// (`RowValidator.isWellFormedPersonName` for shape,
/// `TextBound.personName.maxLength` for length), so a rule widened in one
/// place, as task 11.89 is about to widen it, is widened here too without
/// anybody remembering to come back.
///
/// [value] is checked **trimmed**, because trimmed is what both screens store.
String? validateRequiredName(String? value, String fieldLabel) {
  final trimmed = value?.trim() ?? '';
  if (trimmed.isEmpty) return '$fieldLabel is required';
  if (trimmed.length > TextBound.personName.maxLength) {
    return '$fieldLabel must be '
        '${TextBound.personName.maxLength} characters or fewer';
  }
  final refused = RowValidator.firstDisallowedPersonNameRune(trimmed);
  if (refused != null) {
    return '$fieldLabel $_cannotContain ${_describeRune(refused)}.';
  }
  return null;
}

const _cannotContain = 'cannot contain';

/// Describes the character a name was refused for, in words the person reading
/// it can act on (task 11.89).
///
/// **Why this stopped being one sentence.** Until this task the message said
/// the name *"contains hidden formatting characters"* and told the person to
/// retype rather than paste. That was true of everything the old rule refused,
/// because the old rule was two denylists of invisible characters. Task 11.89
/// replaced it with an allowlist, so a name can now be refused for `(` or `@`
/// or an emoji — none of which is hidden, and for which "delete it and type it
/// again" is advice that does not work.
///
/// **That is `CLAUDE.md`'s standing rule applied where the code actually
/// knows.** The rule is that a branch reached without knowing the cause must
/// not assert one; the corollary is that a branch which *does* know should say
/// so rather than fall back on a shrug. `RowValidator` reports which character
/// it objected to, so this names it, and the two cases get the two different
/// remedies that are true of them.
String _describeRune(int rune) {
  final codePoint =
      'U+${rune.toRadixString(16).toUpperCase().padLeft(4, '0')}';
  // Anything a person can see, they can find and delete. Quoting it is more
  // use than naming its code point, which nobody outside this file reads.
  if (_isVisible(rune)) {
    return '"${String.fromCharCode(rune)}" — a name may have letters, '
        'digits, spaces, hyphens, apostrophes, full stops and commas, and '
        'nothing else';
  }
  // Invisible: the person cannot see it, so quoting it would print nothing
  // and telling them to delete "it" would be telling them to find something
  // that has no appearance. These arrive by pasting, essentially always, so
  // the remedy is the one that works without knowing what the character is.
  return 'a hidden character ($codePoint), which is usually picked up by '
      'pasting. Delete the whole field and type it again';
}

/// Whether [rune] is something the person can actually see on screen.
///
/// Deliberately conservative — anything in the ranges that carry non-printing
/// characters is treated as invisible, so the worst case is telling somebody to
/// retype a field when they could have found the character themselves. The
/// opposite mistake, telling them to look for something with no appearance, is
/// the one that leaves them stuck.
bool _isVisible(int rune) {
  if (rune < 0x20 || (rune >= 0x7f && rune <= 0xa0)) return false;
  if (rune == 0xad) return false;
  if (rune >= 0x2000 && rune <= 0x200f) return false;
  if (rune >= 0x2028 && rune <= 0x202f) return false;
  if (rune >= 0x2060 && rune <= 0x206f) return false;
  if (rune == 0xfeff) return false;
  return true;
}

String? validateEmail(String? value) {
  final trimmed = value?.trim() ?? '';
  if (trimmed.isEmpty) return 'Email is required';
  if (!_emailPattern.hasMatch(trimmed)) return 'Enter a valid email address';
  return null;
}
