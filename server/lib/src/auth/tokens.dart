/// Token generation, hashing, and comparison (task 10.6, per
/// `TriTrack_Security_Model.md` §4.2).
library;

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// Generates and hashes the two kinds of bearer token this system uses:
/// magic-link tokens and session tokens. Both are built identically.
abstract final class Tokens {
  /// 256 bits. Makes guessing irrelevant as an attack for the cost of a longer
  /// string; there is no reason to be economical here.
  static const int entropyBytes = 32;

  static final Random _random = Random.secure();

  /// A fresh 256-bit token, base64url-encoded without padding (43 chars).
  ///
  /// `Random.secure()` is the platform CSPRNG. Never `Random()` — that is
  /// seeded predictably and would make every token in the system guessable.
  static String generate() {
    final bytes = Uint8List(entropyBytes);
    for (var i = 0; i < entropyBytes; i++) {
      bytes[i] = _random.nextInt(256);
    }
    return base64Url.encode(bytes).replaceAll('=', '');
  }

  /// The stored form of a token: SHA-256, hex-encoded.
  ///
  /// **SHA-256 rather than bcrypt/argon2 is deliberate and looks wrong at a
  /// glance.** These are high-entropy random secrets, not user-chosen
  /// passwords: there is no dictionary and no plausible brute force, so a slow
  /// KDF buys nothing while costing latency on the hot path of every
  /// authenticated request. Password hashing is slow specifically to defend
  /// weak inputs; the input here is strong by construction.
  ///
  /// **If a password ever enters this system that reasoning inverts and
  /// argon2id becomes mandatory.** There is no password, by design.
  ///
  /// No pepper: hashing defends against "attacker read the database and now
  /// holds working tokens", and a pepper stored on the same host as the
  /// database credentials adds nothing against that attacker.
  static String hash(String token) =>
      sha256.convert(utf8.encode(token)).toString();

  /// Constant-time comparison of two hex digests.
  ///
  /// Lookups are by hash and Postgres does the matching, so this is not on the
  /// critical path today — it exists so that any code which *does* compare a
  /// secret in Dart has an obviously-correct thing to reach for, rather than
  /// `==` and a comment hoping nobody notices. Length is compared first
  /// because two digests of different lengths cannot match anyway and hex
  /// digests are not themselves secret in length.
  static bool constantTimeEquals(String a, String b) {
    if (a.length != b.length) return false;
    var mismatch = 0;
    for (var i = 0; i < a.length; i++) {
      mismatch |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
    }
    return mismatch == 0;
  }
}
