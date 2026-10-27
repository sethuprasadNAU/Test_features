/// The shape of a project join code (tasks 11.2, 11.81).
///
/// Shared between app and server because both sides canonicalize the same
/// string: the app before it puts a typed code on the wire, the server before
/// it looks one up. Two implementations of "what counts as the same code" would
/// disagree about exactly the inputs this format exists to tolerate — and the
/// disagreement would surface as a valid code being refused, in the field, with
/// no way to tell it from a code the owner has switched off (the refusal is
/// deliberately uniform; see `JoinService.request`).
///
/// **This file owns the format, never the value.** Generation lives on the
/// server (`JoinCodes.generate`), next to the rest of §4.2's token handling.
///
/// ## Why not a UUID
///
/// The delivery channel for a join code is a person: written on a whiteboard,
/// read over a radio, texted, said out loud in a truck. The constraint is that
/// somebody cold, tired and wearing gloves can transcribe it correctly on the
/// first try. A 36-character UUID fails that badly enough that people
/// photograph it instead.
///
/// ## Why 8 characters is enough — the argument, rewritten (task 11.81)
///
/// **The argument this file used to make is false and was deleted rather than
/// softened.** It said 40 bits was acceptable *because a code redeems only for
/// the address it names*, so "an attacker who guesses a code belonging to
/// somebody else cannot use it." Under a **shared** join code there is no named
/// address and that sentence is simply not true any more. Leaving it in place
/// would have been copy describing a mechanism the code does not have, which is
/// the defect task 11.54 exists to have fixed.
///
/// **The replacement argument is a different one, and it is Michael's.** A
/// guessed code buys **the right to ask**, and the owner is the gate. It grants
/// no membership, discloses no field data, and carries no role — the role is
/// chosen by the owner at approval and is never in the code, so there is no
/// such thing as a leaked *owner* code. What 40 bits now bounds is **nuisance**:
/// how hard it is to make a stranger appear in an owner's pending list. Against
/// that, 8 characters of Crockford Base32 is about a thousand billion
/// possibilities, and a signed-in account may try 10 in 15 minutes and 40 in a
/// day. Michael gave this length a fresh yes under this argument on 2026-08-31,
/// rather than letting it be inherited from the old one.
///
/// **What genuinely got weaker, said here so it is not rediscovered:** a
/// correct guess now confirms that a project exists, where before it confirmed
/// nothing. That is inherent to telling somebody their request was sent, and it
/// is recorded in inventory entry 24 rather than left to a later gate.
library;

/// The 32 characters a join code is generated from.
///
/// Crockford Base32: the digits and the uppercase letters, minus `I`, `L`, `O`
/// and `U`. The first three are dropped because they are the ones people
/// confuse with `1`, `1` and `0` respectively; `U` is dropped so that no
/// generated code spells anything an owner would be embarrassed to read out.
const String joinCodeAlphabet = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';

/// How many characters a code carries. See the library doc for why 8.
const int joinCodeLength = 8;

/// [canonical] rendered for a human to copy — `ABCD-EFGH`.
///
/// The hyphen is presentation only; [canonicalizeJoinCode] strips it, so a
/// code typed with it, without it, or with a space instead all resolve to the
/// same value.
String formatJoinCode(String canonical) => canonical.length == joinCodeLength
    ? '${canonical.substring(0, 4)}-${canonical.substring(4)}'
    : canonical;

/// The canonical form of a code somebody typed, or null if it cannot be one.
///
/// Accepts what a person actually produces from a whiteboard, and this is the
/// whole point of choosing this alphabet:
///
/// - **Case.** Lower-case input is upper-cased.
/// - **Separators.** Spaces, hyphens, en-dashes and underscores are dropped,
///   so `abcd efgh`, `ABCD-EFGH` and `abcdefgh` are one code.
/// - **The confusable glyphs.** `O`/`o` reads as `0`, and `I`/`i`/`L`/`l` read
///   as `1`. This is the direction that works: rather than banning both halves
///   of each pair — which would leave a misread character unrecoverable — the
///   generator never emits the letter, and a reader who types the letter gets
///   folded onto the digit that was actually printed.
///
/// Returns null for anything else, including a `U` (never generated, so its
/// presence means a misread rather than a fixable typo) and any string that is
/// not exactly [joinCodeLength] characters after cleanup. A null result is
/// **not** reported to the user as a distinct failure — see the join-request
/// route, where a malformed code and a wrong one answer identically.
String? canonicalizeJoinCode(String input) {
  final buffer = StringBuffer();
  for (final rune in input.trim().toUpperCase().runes) {
    final char = String.fromCharCode(rune);
    switch (char) {
      case ' ' || '-' || '–' || '—' || '_':
        continue;
      case 'O':
        buffer.write('0');
      case 'I' || 'L':
        buffer.write('1');
      default:
        if (!joinCodeAlphabet.contains(char)) return null;
        buffer.write(char);
    }
  }
  final canonical = buffer.toString();
  return canonical.length == joinCodeLength ? canonical : null;
}
