import 'row_validator.dart';
import 'table_columns.dart';

/// Why the server would not store one row — **as a code the client can map to
/// a sentence, never as a sentence the server writes** (task 11.124).
///
/// ## What this is for
///
/// Before it, `SyncPushResponse.outcomes` carried a bare outcome string per
/// row and nothing else, so a device holding a refused record genuinely could
/// not tell *"your value is malformed"* from *"this app and this server are on
/// different versions"*. Task 11.122 made the screen honest about that — it
/// says the server did not say which part was wrong, and it names no cause.
/// This is the detail that lets it say which part, in the cases where the
/// server actually knows.
///
/// ## Three bounds this type exists to hold
///
/// **1. The code is derived from the column's declared bound, never typed at
/// the site that refuses the row.** [TextShape] declares its own
/// [RowIssueCode], [NumericLimit] declares its own, and `RowValidator` reads
/// them; nothing in `sync_service.dart` chooses one. Task 11.136 widened this
/// type to cover numbers, and **the widening was done by declaring the bounds
/// rather than by labelling the twenty-nine inline checks** — for exactly
/// this reason. A code picked by hand at each refusal
/// site is a hand-maintained list, and a hand-maintained list is wrong as
/// soon as somebody adds a shape and updates four of the five places.
///
/// **2. No server prose reaches a client screen** (security model §4.13).
/// A code is a closed vocabulary both sides ship; the message is written on
/// the device, in the device's own words. `RowIssue.message` stays
/// server-side, for server logs.
///
/// **3. An unrecognised code must read as no code at all.** [fromWire]
/// returns null rather than throwing or inventing a value, so a server that
/// is newer than this build falls back to task 11.122's honest default —
/// which is correct for every reason nobody has invented yet. That fallback
/// is the thing this task most had to avoid breaking, so it is the parse
/// itself that guarantees it rather than a check somewhere downstream.
enum RowIssueCode {
  /// A text column held something that is not text at all.
  textWrongType('text_wrong_type'),

  /// A text column's value was longer than [TextBound.maxLength].
  textTooLong('text_too_long'),

  /// A [TextShape.identifier] column's value is not a usable identifier.
  textNotAnIdentifier('text_not_an_identifier'),

  /// A [TextShape.personName] column's value is not a usable person's name —
  /// the case task 11.84 measured and 11.122 could not name.
  textNotAName('text_not_a_name'),

  /// A [TextShape.hexColor] column's value is not a `#RRGGBB` colour
  /// (task 11.136).
  textNotAColor('text_not_a_color'),

  /// A numeric column held something that is not a number at all — a
  /// latitude of `"north"`, a bearing of `true`, an accuracy radius that
  /// arrived as an array (task 11.158). [textWrongType]'s counterpart, and
  /// the last of the four numeric refusals to exist: until 11.158 such a
  /// value was refused by nothing and stored as it arrived.
  ///
  /// **A numeric string is not this.** `"42"` is read as 42 and then ranged;
  /// what this names is a value no reading can turn into a number.
  numberWrongType('number_wrong_type'),

  /// A numeric column held `NaN` or an infinity — finding M-1's case, which
  /// had a check and no code (task 11.136). See [NumericLimit].
  numberNotARealNumber('number_not_a_real_number'),

  /// A numeric column's value is below the minimum its [NumericBound]
  /// declares — a latitude of -999, a frequency under the VHF window, an
  /// uncertainty of zero (task 11.136).
  numberBelowMinimum('number_below_minimum'),

  /// A numeric column's value is above the maximum its [NumericBound]
  /// declares — a latitude of 999, a bearing of 400 (task 11.136).
  numberAboveMaximum('number_above_maximum');

  const RowIssueCode(this.wire);

  /// The string that crosses the wire. **Stable**: it is stored on the
  /// device, in `Sync_Held_Rows`, and read back by a later build. Never the
  /// enum's `name` — renaming a value in Dart would then silently orphan
  /// every stored code.
  final String wire;

  /// Parses a code off the wire, or **null for anything this build does not
  /// recognise** — see bound 3 in this file's header. Null is not an error
  /// here: a newer server naming a refusal this build has never heard of is
  /// the expected case, and the honest default is the right answer for it.
  static RowIssueCode? fromWire(Object? value) {
    if (value is! String) return null;
    for (final code in values) {
      if (code.wire == value) return code;
    }
    return null;
  }
}

/// One row's refusal detail, as it crosses the wire beside its outcome.
///
/// Carries the code and **the name of the column on the row the client itself
/// sent**. The field name is not a disclosure: the client composed that row
/// and already knows every column in it, so naming one back tells it nothing
/// about what the server holds. It is still treated as untrusted on arrival —
/// the client checks it against its own declared columns for that table before
/// putting it in a sentence, and falls back to the honest default when it does
/// not match. See `HeldRowDetails`.
///
/// **Rides only on [SyncRowOutcome.invalid].** `unauthorized` stays one opaque
/// answer for every reason it could be refused (§4.13) — attaching a code to
/// it would let a push be used to probe what the server holds, which is the
/// existence oracle this project has closed twice. That bound is enforced when
/// the response is built *and* again when it is parsed, so a server that gets
/// it wrong cannot make a client render it.
class RowRefusal {
  const RowRefusal({required this.code, this.field});

  final RowIssueCode code;

  /// The offending column's name, or null when the refusal is not about one
  /// named column.
  final String? field;

  Map<String, Object?> toJson() => {
    'code': code.wire,
    if (field != null) 'field': field,
  };

  /// Parses one detail, or null when the code is unrecognised — the honest
  /// default's entry point. See [RowIssueCode.fromWire].
  static RowRefusal? fromJson(Object? json) {
    if (json is! Map) return null;
    final code = RowIssueCode.fromWire(json['code']);
    if (code == null) return null;
    final field = json['field'];
    return RowRefusal(code: code, field: field is String ? field : null);
  }

  /// The one detail to report for a row [RowValidator] refused, or null when
  /// nothing in [issues] can name a cause.
  ///
  /// **The first issue that carries a code, not the first issue.** Every
  /// bound-derived refusal carries one since task 11.136, but the checks a
  /// schema cannot supply still do not — a closed enum's membership, an
  /// email's presence — and a row can fail one of those and a coded bound at
  /// once. Reporting "no detail" because the uncoded one came first would
  /// throw away the only thing the device could have used.
  ///
  /// Lives here rather than at the call site because the real server and the
  /// suite's fake server both have to answer this identically. A second
  /// implementation of a rule both sides depend on is what this whole package
  /// exists to prevent, and a fake that derived a detail differently would let
  /// a client test pass against behaviour the real server does not have.
  static RowRefusal? fromIssues(Iterable<RowIssue> issues) {
    for (final issue in issues) {
      final code = issue.code;
      if (code != null) return RowRefusal(code: code, field: issue.field);
    }
    return null;
  }

  @override
  String toString() => field == null ? code.wire : '${code.wire}:$field';
}
