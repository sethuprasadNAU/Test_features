import 'dart:convert';

/// Thrown by a `DbCodec.decode*` function when the value it was handed is
/// present but not the type that column is supposed to hold.
///
/// Task 10.67: every `decode*` here used a naked `as` cast (`value! as
/// String`, `value as int`, `(decoded as List).cast&lt;String&gt;()`), so a
/// wrong-typed column — from a synced row this build didn't validate as
/// strictly as it should have, or a hand-edited/corrupt backup archive —
/// threw a raw, unlabeled `TypeError` instead of something a caller could
/// recognize and handle (`BackupManifest.fromJson` promises callers it only
/// ever throws [BackupFormatException]; before this it silently didn't, for
/// exactly this reason). Reached from every model's `fromRow` across
/// `lib/data/models/**` (44 call sites, 10 files) and from
/// `backup_format.dart`'s manifest parser, so fixing the type check once
/// here — rather than adding a guard at each call site — closes the same gap
/// everywhere it's reachable, per task 10.66's "fix the class" rule.
class DbCodecFormatException implements Exception {
  const DbCodecFormatException(this.message);
  final String message;
  @override
  String toString() => 'DbCodecFormatException: $message';
}

/// Encode/decode helpers shared by the app's SQLite storage layer and the
/// server's Postgres storage layer.
///
/// Neither side has a native datetime, boolean, or list type that the other
/// agrees with byte-for-byte, so every model's `toColumns`/`fromRow` (app) and
/// the server's row (de)serialization both funnel through these to keep
/// coercion consistent. Rules (see the technical doc's global conventions):
/// - Record-audit and UTC domain timestamps are stored as ISO-8601 with a
///   `Z` designator (parsed back as UTC). This is the part that must match
///   exactly between client and server: `MergeResolver` compares `updated_at`
///   values across the two, so both must agree on the same encoding.
/// - Local wall-clock timestamps are stored as ISO-8601 *without* forcing a
///   zone; the paired `*_offset` column preserves the original offset.
/// - Booleans are stored as INTEGER 0/1.
/// - JSON-array columns are stored as JSON text.
abstract final class DbCodec {
  // --- UTC timestamps (created_at, updated_at, deleted_at, timestamp_utc) ---

  static String encodeUtc(DateTime dt) => dt.toUtc().toIso8601String();

  static String? encodeUtcOrNull(DateTime? dt) => dt?.toUtc().toIso8601String();

  static DateTime decodeUtc(Object? value) =>
      _decodeDateTime(value, field: 'a UTC timestamp').toUtc();

  static DateTime? decodeUtcOrNull(Object? value) =>
      value == null ? null : decodeUtc(value);

  // --- Local wall-clock timestamps (timestamp_local, started_at_local) ---
  //
  // Stored verbatim so the recorded local time is preserved regardless of the
  // device's current zone; the accompanying offset column carries the zone.

  static String encodeLocal(DateTime dt) => dt.toIso8601String();

  static DateTime decodeLocal(Object? value) =>
      _decodeDateTime(value, field: 'a local timestamp');

  /// Formats a [Duration] offset as an ISO-8601 zone string, e.g. `-07:00`.
  /// Use when persisting `timezone_offset` from a known offset.
  static String encodeOffset(Duration offset) {
    final sign = offset.isNegative ? '-' : '+';
    final abs = offset.abs();
    final h = abs.inHours.toString().padLeft(2, '0');
    final m = (abs.inMinutes % 60).toString().padLeft(2, '0');
    return '$sign$h:$m';
  }

  // --- Booleans ---

  static int encodeBool(bool value) => value ? 1 : 0;

  static int? encodeBoolOrNull(bool? value) =>
      value == null ? null : (value ? 1 : 0);

  static bool decodeBool(Object? value) {
    if (value is! int) {
      throw DbCodecFormatException(
        'expected a boolean stored as INTEGER 0/1, got ${_describe(value)}.',
      );
    }
    return value != 0;
  }

  static bool? decodeBoolOrNull(Object? value) =>
      value == null ? null : decodeBool(value);

  // --- JSON string arrays (tag_ids_listened_for, observation_ids_used) ---

  static String encodeStringList(List<String> values) => jsonEncode(values);

  static List<String> decodeStringList(Object? value) {
    if (value == null) return const [];
    if (value is! String) {
      throw DbCodecFormatException(
        'expected a JSON-encoded string list, got ${_describe(value)}.',
      );
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(value);
    } on FormatException catch (e) {
      throw DbCodecFormatException('not valid JSON: $e');
    }
    if (decoded is! List || decoded.any((e) => e is! String)) {
      throw DbCodecFormatException(
        'expected a JSON array of strings, got ${_describe(decoded)}.',
      );
    }
    return decoded.cast<String>();
  }

  static DateTime _decodeDateTime(Object? value, {required String field}) {
    if (value is! String) {
      throw DbCodecFormatException(
        'expected $field as an ISO-8601 string, got ${_describe(value)}.',
      );
    }
    try {
      return DateTime.parse(value);
    } on FormatException catch (e) {
      throw DbCodecFormatException(
        'expected $field as an ISO-8601 string: $e',
      );
    }
  }

  static String _describe(Object? value) =>
      value == null ? 'null' : '${value.runtimeType} ($value)';
}
