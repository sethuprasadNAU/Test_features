/// Recognising a secret that isn't one (task 10.14, Security Model §4.6).
library;

/// Values that are set, non-empty, and still not secrets.
///
/// §4.6 requires the server to refuse to start when a required secret "is
/// missing, empty, **or matches a known placeholder**". The third case is the
/// one that actually happens: a missing password fails loudly on the first
/// connection attempt, but `POSTGRES_PASSWORD=changeme` works perfectly, passes
/// every "is it configured?" check, and is the mechanism by which a prototype
/// reaches production with a credential an attacker can guess on the first try.
///
/// Matched case-insensitively after trimming. Deliberately a small, literal
/// list rather than an entropy heuristic: a length-or-entropy rule would reject
/// legitimate passphrases and would need tuning, whereas this catches the
/// specific strings people actually leave in place. It is a backstop for
/// carelessness, not a password-strength policy — §4.2's reasoning about
/// high-entropy random secrets applies to tokens the server generates, not to
/// an operator's Postgres password, and TriTrack has no business grading that.
const Set<String> knownPlaceholderSecrets = {
  'changeme',
  'change_me',
  'change-me',
  'password',
  'passwd',
  'secret',
  'postgres',
  'admin',
  'todo',
  'tbd',
  'xxx',
  'placeholder',
  'example',
  'test',
  'dev',
  'development',
  'your-password-here',
  'your_password_here',
  'yourpasswordhere',
  'setme',
  'set-me',
  'replaceme',
  'replace-me',
  'notset',
  'not-set',
  'none',
  'null',
  'insecure',
  'unsafe',
};

/// **Deliberately absent from the list above: any value a developer chose for
/// their own gitignored `.env`.**
///
/// It is tempting to add whatever weak string the local dev stack happens to
/// use. Don't. Two reasons, and the second is the decisive one:
///
/// 1. §4.6's concern is a credential an attacker can *know* — a working default
///    baked into a committed file or a README. A value that exists only in a
///    gitignored `.env` on one laptop is not known to anybody.
/// 2. **Adding it here would publish it.** This file is committed; the `.env`
///    is not. Listing a real local password as a "placeholder" would put that
///    password into the repository and into its history — the exact outcome
///    §4.6 exists to prevent, arrived at by way of enforcing §4.6.
///
/// The list is for strings that are already public. Keep it that way.

/// Whether [value] is a placeholder rather than a real secret.
///
/// Also rejects a value that is *only* repeated characters (`aaaa`, `1111`) or
/// a trivial ascending run (`1234`, `12345678`), which are the same category of
/// stand-in and would otherwise need a dozen more literal entries.
bool isPlaceholderSecret(String value) {
  final normalized = value.trim().toLowerCase();
  if (normalized.isEmpty) return true;
  if (knownPlaceholderSecrets.contains(normalized)) return true;
  if (_isSingleRepeatedCharacter(normalized)) return true;
  if (_isAscendingDigitRun(normalized)) return true;
  return false;
}

bool _isSingleRepeatedCharacter(String value) {
  if (value.length < 2) return true;
  final first = value.codeUnitAt(0);
  for (var i = 1; i < value.length; i++) {
    if (value.codeUnitAt(i) != first) return false;
  }
  return true;
}

bool _isAscendingDigitRun(String value) {
  if (value.length < 3) return false;
  for (var i = 0; i < value.length; i++) {
    final code = value.codeUnitAt(i);
    if (code < 0x30 || code > 0x39) return false;
    if (i > 0 && code != value.codeUnitAt(i - 1) + 1) return false;
  }
  return true;
}
