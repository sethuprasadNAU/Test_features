import 'dart:convert';

import 'package:tritrack_sync/tritrack_sync.dart';
import '../models/observation.dart';
import '../models/sync_meta.dart';
import '../models/tag.dart';
import '../models/tag_version.dart';
import '../models/user.dart';
import '../repositories/user_repository.dart';

/// Thrown when a pasted share payload isn't a TriTrack observation payload,
/// or is truncated/corrupted (e.g. a messaging app mangled it) — the paste
/// flow catches this and shows a clear error rather than crashing or
/// half-populating a preview.
class ObservationShareFormatException implements Exception {
  const ObservationShareFormatException(this.message);
  final String message;
  @override
  String toString() => 'ObservationShareFormatException: $message';
}

/// Envelope marker (design doc §10: "a short format-version prefix").
///
/// Deliberately stays `TT1:` across payload versions: the *envelope* format
/// (marker + base64 + JSON object with a `v` field) has not changed, and the
/// inner [_kPayloadVersion] is what carries version semantics. Keeping the
/// marker stable means an older build recognizes the envelope and can report
/// "this payload is newer than the app" instead of the far less useful "not a
/// TriTrack payload". Bump the marker only if the envelope itself changes
/// (different encoding or a non-JSON body), which older builds could not
/// parse far enough to produce a version error.
const String _kSharePrefix = 'TT1:';

/// Current payload version. v2 adds the identity/provenance/sync-clock block
/// ([SharedObservationIdentity]) needed to save a shared observation as a
/// faithful replica instead of a new row. **v3 (task 11.187) adds the pulse
/// mode** — the slot the sender heard it on and, more usefully, what that mode
/// was called on the sender's tag. **v4 (task 11.193) adds the
/// signal-sounded-irregular flag.**
///
/// **v4 is a bump rather than a quietly-added key, and the cost is deliberate.**
/// A v3 build refuses a v4 payload by name instead of parsing the fields it
/// recognises — so somebody on an older build cannot paste a bearing from a
/// newer one until they update, which is a real cost to a field team mid-season.
/// The alternative is worse: the flag says *the tag may be failing*, and a
/// reader that silently dropped it would show the receiver an ordinary-looking
/// bearing while the sender was trying to tell them something. A refusal that
/// names itself is recoverable; a silently weaker record is not.
///
/// **Both directions of skew are already honest and stay that way.** A payload
/// newer than this build is refused by name in [ObservationShare.decode] —
/// *"Payload format v4 is newer than this app supports"* — rather than being
/// parsed for the fields it recognises, which is what would silently drop a
/// mode. A v1 or v2 payload read here carries no mode fields at all and reads
/// as "not recorded"; it is never completed from the local tag, because the
/// sender's collar and the receiver's are different rows.
const int _kPayloadVersion = 4;

/// The v2 identity/provenance block: everything the receiving device needs to
/// write the shared observation as a *replica* of the sender's row rather than
/// a new observation of its own.
///
/// Absent (null on [SharedObservation.identity]) for v1 payloads, which
/// predate these fields — a v1 payload can only ever become a new,
/// receiver-owned observation, and callers must say so rather than pretending
/// they replicated.
class SharedObservationIdentity {
  const SharedObservationIdentity({
    required this.observationId,
    required this.observerUserId,
    required this.observerEmail,
    required this.positionSource,
    this.positionAccuracyM,
    required this.sync,
  });

  /// The original row's primary key. Reusing it is what lets two devices'
  /// copies of one real observation converge under last-write-wins instead of
  /// silently duplicating.
  final String observationId;

  /// The observer's `user_id` *on the sending device*. Carried so the receiver
  /// can create its local `Users` row with the same id, keeping the replica's
  /// `user_id` identical on both devices — otherwise the row we are trying to
  /// converge would differ in a column and conflict forever.
  final String observerUserId;

  /// Normalized (trimmed + lowercased) observer email — the documented
  /// cross-device identity anchor, and the dedup key the receiver looks up by.
  final String observerEmail;

  final PositionSource positionSource;
  final double? positionAccuracyM;

  /// The sender's sync clock, copied verbatim. Writing a replica with
  /// `SyncMeta.initial` instead would make the copy look newer than the
  /// original and could overwrite the original author's later edits on merge.
  ///
  /// [SyncMeta.deletedAt] is always null here: only live observations are
  /// shareable, so the tombstone is not part of the wire format.
  final SyncMeta sync;
}

/// A lightweight, versioned snapshot of one observation for cross-device
/// sharing (design doc §10 Observation Sharing / §214: "carries observer,
/// timestamp, uncertainty, pulse rate, tag key... not a fragile human-readable
/// string... versioned JSON, optionally base64-wrapped so messaging apps
/// don't mangle it").
///
/// Deliberately NOT a full [Observation]: the receiving device has no matching
/// `tag_id` (those are per-device UUIDs), so this carries the "tag key"
/// (frequency + pulse rate + name — the fields a field biologist actually uses
/// to recognize "that's the same tag") instead of an id. It is a preview
/// payload — "not stored unless explicitly saved" (doc) — turning it into a
/// real [Observation] row (with a real local `tag_id`) is the receiving
/// screen's job, not this module's.
///
/// Observer *identity*, by contrast, does travel as of v2 (see [identity]):
/// faithful replication requires it.
class SharedObservation {
  const SharedObservation({
    required this.payloadVersion,
    this.identity,
    required this.observerName,
    required this.timestampUtc,
    required this.timestampLocal,
    required this.timezoneOffset,
    required this.latitude,
    required this.longitude,
    required this.elevation,
    required this.tagFrequencyMhz,
    this.tagPulseRate,
    required this.tagName,
    this.tagValuesRecorded = false,
    required this.observationType,
    this.magneticBearing,
    this.trueNorthBearing,
    this.bearingUncertainty,
    required this.signalType,
    this.signalIrregular,
    this.pulseModeSlot,
    this.pulseModeName,
    required this.signalStrength,
    this.bearingQuality,
    this.notes,
  });

  /// The `v` the payload declared. Retained so callers can explain *why*
  /// [identity] is missing rather than guessing.
  final int payloadVersion;

  /// Identity, provenance, and sync clock of the original row — null for v1
  /// payloads, which carry none of it. Null means "this cannot be saved as a
  /// replica"; a caller falling back to creating a new, receiver-owned
  /// observation must warn the user that provenance is lost and the record may
  /// duplicate the sender's.
  final SharedObservationIdentity? identity;

  /// Whether this payload can be saved as a faithful replica of the sender's
  /// row (v2+) rather than as a new receiver-owned observation (v1).
  bool get canReplicate => identity != null;

  final String observerName;
  final DateTime timestampUtc;
  final DateTime timestampLocal;
  final String timezoneOffset;
  final double latitude;
  final double longitude;
  final double elevation;

  final double tagFrequencyMhz;
  final double? tagPulseRate;
  final String tagName;

  /// Whether [tagFrequencyMhz], [tagPulseRate] and [tagName] are what the
  /// sender's receiver was actually tuned to when the bearing was taken
  /// (task 11.32), or the sender's present-day tag values standing in.
  ///
  /// False on every payload written before this field existed, and on one whose
  /// bearing predates schema v9 and so does not know. **Never assume true**:
  /// the distinction is the whole of what a pasted record can honestly claim
  /// about the tag, and the receiving screen says which it has.
  final bool tagValuesRecorded;

  final ObservationType observationType;
  final double? magneticBearing;
  final double? trueNorthBearing;
  final double? bearingUncertainty;
  final SignalType signalType;

  /// **Whether the sender heard the signal itself as wrong** (task 11.193), or
  /// null when the payload does not say.
  ///
  /// **This one is written, unlike [pulseModeSlot] beside it, and the
  /// difference is what the value is about.** A slot number names a mode on the
  /// *sender's* tag, and the replica is relabelled onto whichever local tag the
  /// receiver picked, so it cannot survive the move. This is not relative to
  /// any tag row: it is what a person standing in a particular place at a
  /// particular time heard, and it means the same thing on the receiving device
  /// as it did on the sending one. Dropping it would lose the sender's whole
  /// reason for sharing the record.
  ///
  /// Null on a v1, v2 or v3 payload, and on any record the sender's own device
  /// has no answer for. **Never completed to `false`** — see
  /// `Observation.signalIrregular` for why the two are different answers.
  final bool? signalIrregular;

  /// The slot the sender heard this bearing on (task 11.187), or null on a v1
  /// or v2 payload — and on any record the sender's own device had no slot
  /// for.
  ///
  /// **It is shown, not written.** A slot number names a mode on the *sender's*
  /// tag, while the imported record is relabelled onto whichever local tag the
  /// receiver picked, so writing it would produce a bearing pointing at a mode
  /// that may mean something else entirely — the identical reason
  /// [ObservationShare.writableColumns] excludes `tag_version_id`.
  final int? pulseModeSlot;

  /// What that mode was **called** on the sender's tag, when the sender's
  /// device knew — the part a person can actually act on, since "Mortality"
  /// means the same thing on both devices and "slot 2" does not.
  ///
  /// Null on a v1/v2 payload, and on a record whose tag version had not reached
  /// the sender's device.
  final String? pulseModeName;

  /// The mode as the paste screen should say it: the sender's words, or a
  /// plain statement that this payload does not carry them.
  ///
  /// **Never the receiving device's own mode names.** Completing the sentence
  /// from the local tag would put a name on the record that nobody who took it
  /// ever saw — the same falsehood [tagValuesRecorded] exists to keep out of
  /// the tag fields.
  String get pulseModeDescription =>
      pulseModeName ?? 'not recorded in this payload';

  final SignalStrength signalStrength;
  final BearingQuality? bearingQuality;
  final String? notes;

  /// Whether [tag] is plausibly "the same tag" this payload refers to — the
  /// doc's "tag key" match used to decide "known locally" vs. "offer to
  /// create it or show unlinked". Frequency is compared with a small epsilon
  /// (float round-trip through JSON/text) and the name case-insensitively;
  /// pulse rate is not required to match (it can be re-measured slightly
  /// differently session to session) but must not *conflict* if both sides
  /// have one.
  bool matchesTag(Tag tag) {
    final freqMatches = (tag.frequencyMhz - tagFrequencyMhz).abs() < 0.001;
    final nameMatches = tag.tagName.trim().toLowerCase() == tagName.trim().toLowerCase();
    if (!freqMatches || !nameMatches) return false;
    if (tag.pulseRate != null && tagPulseRate != null) {
      return (tag.pulseRate! - tagPulseRate!).abs() < 0.5;
    }
    return true;
  }
}

abstract final class ObservationShare {
  /// The `Observations` columns a v2 payload can express, and therefore the
  /// only ones an import is permitted to write (security model §4.19 rule 1).
  ///
  /// Declared here, beside [encode], because the wire format and the write set
  /// have to be the same list — the harm in finding J-1 was that they weren't.
  /// `toColumns()` emits all 41 columns; the payload carries these, and writing
  /// the difference is what NULLed a real observation's sweep endpoints,
  /// declination and WMM version. `test/security/share_payload_overwrite_test.dart`
  /// asserts this set against [encode]'s own output so the two cannot drift.
  ///
  /// Three entries are here without being *on the wire*, because the import
  /// nonetheless has an authoritative value for them:
  ///
  /// - `user_id` — the resolved observer, never the payload's claim, and only
  ///   ever on an insert (rule 2).
  /// - `tag_id` — the local tag the *receiving user* picked on the paste
  ///   screen. The payload carries a tag key, not an id.
  /// - `deleted_at` — a v2 payload asserts the row is live: only live
  ///   observations are shareable. Carrying it as a fixed `null` is what makes
  ///   "the shared copy would undo your delete" a visible change rather than
  ///   either a silent resurrection or a silent no-op.
  ///
  /// The primary key (`observation_id`, `project_id`) is deliberately absent:
  /// it identifies the row rather than being written to it.
  ///
  /// **`tag_version_id` is absent too, and must stay absent (task 11.32).** A
  /// version id names a row in the *sender's* tag history, while the imported
  /// record is relabelled onto whichever local tag the receiver picked — so
  /// storing it would produce a bearing whose version describes a different
  /// tag. Leaving it out means an inserted replica reads "not recorded", which
  /// is exactly true of this device, and — because the import writes only the
  /// columns in this set — it also means re-importing a payload over a bearing
  /// this device recorded itself does **not** wipe the version that bearing
  /// legitimately has.
  /// **`pulse_mode` is absent too, for the same reason, and the cost is
  /// stated rather than hidden (task 11.187).** A slot number names a mode on
  /// the *sender's* tag; the replica is relabelled onto whichever local tag the
  /// receiver picked, whose slot 3 may be an entirely different mode. So an
  /// imported replica records no slot and is read through `signal_type`, which
  /// can say two things — meaning **a bearing the sender heard on a third mode
  /// arrives reading as their first.** The sender's own words for it are on the
  /// wire (`pulse_mode_name`) and the paste screen shows them, so the person
  /// deciding whether to import sees what they are importing; what the saved
  /// row cannot carry, it does not claim.
  /// **`signal_irregular` *is* here, and the contrast with the two above is the
  /// reason it is worth a paragraph (task 11.193).** Both exclusions are about
  /// values that name something in the *sender's* database — a version row, a
  /// slot on their tag — which the replica cannot carry because it is relabelled
  /// onto the receiver's tag. This flag names nothing on any tag: it is what a
  /// person heard at a time and a place, it means the same thing on both
  /// devices, and it is very often the reason the record is being shared at all.
  /// So it travels, and an import writes it.
  static const Set<String> writableColumns = {
    'user_id',
    'tag_id',
    'timestamp_local',
    'timestamp_utc',
    'timezone_offset',
    'latitude',
    'longitude',
    'position_accuracy_m',
    'position_source',
    'elevation',
    'observation_type',
    'magnetic_bearing',
    'true_north_bearing',
    'bearing_uncertainty',
    'signal_type',
    'signal_strength',
    'signal_irregular',
    'bearing_quality',
    'notes',
    'created_at',
    'updated_at',
    'revision',
    'last_modified_by',
    'origin_device_id',
    'deleted_at',
  };

  /// Columns exempt from rule 4's `was → becomes` consent diff, because they
  /// move on every honest edit — [UntrustedImportRules.columnsMovedByEveryEdit],
  /// shared verbatim with the archive-restore path so the two can never
  /// disagree about what a user is entitled to see.
  ///
  /// **This used to be a longer, locally-defined list**, and finding K-8 is
  /// what the extra entries cost: `created_at` and `origin_device_id` do not
  /// move on an honest edit, are taken verbatim from the payload, and were
  /// exempt anyway — so a payload identical to the victim's own row in every
  /// carried field, differing only in those two, was written with no dialog
  /// while the screen reported *"replaced as you confirmed — 0 values were
  /// changed."* The criterion, and why `last_modified_by` still qualifies, is
  /// documented once on the shared set.
  ///
  /// **Finding L-2 narrowed it again**, and the narrowing is now a derivation
  /// rather than an edit: `revision` and `updated_at` are read by the merge, so
  /// they are not exempt. What they get instead is
  /// [UntrustedImportRules.isUnexplainedRevisionAdvance] — see
  /// `SharedObservationImporter._changesAgainst`.
  static Set<String> get clockColumns =>
      UntrustedImportRules.consentDiffExempt;

  /// Encodes one observation as a copy-ready `TT1:`+base64 payload at the
  /// current version ([_kPayloadVersion]).
  ///
  /// [observer] must be the observation's *author* (the `Users` row for
  /// `observation.userId`), not whoever happens to be sharing it — the payload
  /// attributes the record to this person, and a mismatch would misattribute
  /// the replica on every receiving device.
  /// [tag] is the observation's tag row, used **only** as the fallback when the
  /// observation does not know what it was recorded against. [recorded] is
  /// what it *was* recorded against (task 11.32) — pass
  /// `TagVersionRepository.recordedStateOf`'s answer.
  ///
  /// **The payload carries the recorded values when they are known**, so a
  /// payload copied today and one copied after somebody renames the tag
  /// describe the same bearing the same way. Before this the three tag fields
  /// were read straight off the live tag row, which made the pasted copy claim
  /// a frequency the sender's receiver was never tuned to.
  ///
  /// When nothing was recorded — a bearing older than schema v9 — the current
  /// tag values travel instead, and that is a deliberate exception rather than
  /// an oversight: the payload's tag fields are the receiver's *only* way to
  /// recognise which collar this is ([SharedObservation.matchesTag]), and
  /// sending three empty fields would make the record unmatchable rather than
  /// honest. It is a lossy fallback with a real cost, so `tag_values_recorded`
  /// travels beside them and the paste screen says which it is looking at.
  static String encode(
    Observation observation, {
    required Tag tag,
    required User observer,
    RecordedTagState? recorded,
  }) {
    assert(
      observer.userId == observation.userId,
      'encode() must be given the observation author, not the sharing user.',
    );
    final asRecorded = recorded != null && recorded.isRecorded;
    final json = jsonEncode({
      'v': _kPayloadVersion,
      'observation_id': observation.observationId,
      'observer_user_id': observer.userId,
      'observer_email': UserRepository.normalizeEmail(observer.email),
      'observer_name': '${observer.firstName} ${observer.lastName}',
      'position_source': observation.positionSource.db,
      'position_accuracy_m': observation.positionAccuracyM,
      'created_at': observation.sync.createdAt.toUtc().toIso8601String(),
      'updated_at': observation.sync.updatedAt.toUtc().toIso8601String(),
      'revision': observation.sync.revision,
      'last_modified_by': observation.sync.lastModifiedBy,
      'origin_device_id': observation.sync.originDeviceId,
      'timestamp_utc': observation.timestampUtc.toIso8601String(),
      'timestamp_local': observation.timestampLocal.toIso8601String(),
      'timezone_offset': observation.timezoneOffset,
      'latitude': observation.latitude,
      'longitude': observation.longitude,
      'elevation': observation.elevation,
      'tag_frequency_mhz':
          asRecorded ? recorded.recordedFrequencyMhz : tag.frequencyMhz,
      'tag_pulse_rate': asRecorded ? recorded.recordedPulseRate : tag.pulseRate,
      'tag_name': asRecorded ? recorded.recordedTagName : tag.tagName,
      // Whether the three fields above are what the sender's receiver was
      // actually tuned to, or the tag's present-day values standing in. Absent
      // from a payload written before this field existed, which decodes as
      // false — the honest reading of a payload that could not say.
      'tag_values_recorded': asRecorded,
      'observation_type': observation.observationType.db,
      'magnetic_bearing': observation.magneticBearing,
      'true_north_bearing': observation.trueNorthBearing,
      'bearing_uncertainty': observation.bearingUncertainty,
      'signal_type': observation.signalType.db,
      // v3 (task 11.187). The slot and, when the version row is on this
      // device, the words that went with it. `asRecorded` decides the same way
      // it does for the three tag fields above: the recorded name if the
      // bearing knows what it was heard on, and nothing rather than today's
      // name if it does not.
      'pulse_mode': observation.pulseModeSlot,
      'pulse_mode_name': asRecorded
          ? recorded.recordedPulseModeName(
              storedSlot: observation.pulseMode,
              legacy: observation.signalType,
            )
          : null,
      'signal_strength': observation.signalStrength.db,
      // v4 (task 11.193). Present on every v4 payload, carrying JSON `null`
      // when the sender has no answer — so "nobody was asked" and "the person
      // listened and did not tick it" stay different values on the wire, the
      // same way NULL and 0 are different in the column. A key that is always
      // emitted is also what lets `share_payload_overwrite_test.dart` compare
      // [writableColumns] against this map as a set.
      'signal_irregular': observation.signalIrregular,
      'bearing_quality': observation.bearingQuality?.db,
      'notes': observation.notes,
    });
    return '$_kSharePrefix${base64Encode(utf8.encode(json))}';
  }

  /// Parses a pasted payload. Robust to surrounding whitespace (a common
  /// artifact of copy/paste through messaging apps). Throws
  /// [ObservationShareFormatException] on anything that isn't a valid,
  /// current-or-older-version TriTrack payload — never partially populates
  /// a result.
  /// §4.19 rule 3's bounds, shared with every other untrusted-import path —
  /// see [UntrustedImportRules], which is where they and their justifications
  /// now live. Kept as names on this class because the decoder below reads
  /// them per-field, with format-specific messages, before an identity block
  /// exists to hand to the table-agnostic checker.
  static const int maxRevision = UntrustedImportRules.maxRevision;
  static const Duration maxClockLead = UntrustedImportRules.maxClockLead;
  static DateTime get plausibleFloor => UntrustedImportRules.plausibleFloor;

  /// Parses a pasted payload. [now] is this device's clock, injectable for
  /// tests; the payload's timestamps are bounded against it (rule 3).
  static SharedObservation decode(String payload, {DateTime? now}) {
    final clockCeiling = (now ?? DateTime.now()).toUtc().add(maxClockLead);
    final trimmed = payload.trim();
    if (!trimmed.startsWith(_kSharePrefix)) {
      throw const ObservationShareFormatException(
        'Not a TriTrack share payload (missing "TT1:" prefix).',
      );
    }
    final b64 = trimmed.substring(_kSharePrefix.length);

    final Map<String, Object?> json;
    try {
      final decodedBytes = base64Decode(b64);
      final decoded = jsonDecode(utf8.decode(decodedBytes));
      if (decoded is! Map<String, Object?>) {
        throw const ObservationShareFormatException('Payload is not a JSON object.');
      }
      json = decoded;
    } on ObservationShareFormatException {
      rethrow;
    } catch (e) {
      throw ObservationShareFormatException('Could not decode payload ($e).');
    }

    final version = json['v'];
    if (version is! int || version < 1) {
      throw const ObservationShareFormatException('Missing or invalid format version.');
    }
    if (version > _kPayloadVersion) {
      throw ObservationShareFormatException(
        'Payload format v$version is newer than this app supports '
        '(this build reads up to v$_kPayloadVersion) — update TriTrack to '
        'open it.',
      );
    }

    double reqDouble(String key) {
      final v = json[key];
      if (v is num) return v.toDouble();
      throw ObservationShareFormatException('Missing or invalid "$key".');
    }

    String reqString(String key) {
      final v = json[key];
      if (v is String && v.isNotEmpty) return v;
      throw ObservationShareFormatException('Missing or invalid "$key".');
    }

    double? optDouble(String key) {
      final v = json[key];
      return v is num ? v.toDouble() : null;
    }

    String? optString(String key) {
      final v = json[key];
      return v is String ? v : null;
    }

    final latitude = reqDouble('latitude');
    final longitude = reqDouble('longitude');
    if (latitude < -90 || latitude > 90) {
      throw const ObservationShareFormatException('Latitude out of range.');
    }
    if (longitude < -180 || longitude > 180) {
      throw const ObservationShareFormatException('Longitude out of range.');
    }

    ObservationType observationType;
    try {
      observationType = ObservationType.fromDb(reqString('observation_type'));
    } catch (_) {
      throw const ObservationShareFormatException('Unknown observation_type.');
    }
    SignalType signalType;
    try {
      signalType = SignalType.fromDb(reqString('signal_type'));
    } catch (_) {
      throw const ObservationShareFormatException('Unknown signal_type.');
    }
    SignalStrength signalStrength;
    try {
      signalStrength = SignalStrength.fromDb(reqString('signal_strength'));
    } catch (_) {
      throw const ObservationShareFormatException('Unknown signal_strength.');
    }
    BearingQuality? bearingQuality;
    final bqRaw = optString('bearing_quality');
    if (bqRaw != null) {
      try {
        bearingQuality = BearingQuality.fromDb(bqRaw);
      } catch (_) {
        throw const ObservationShareFormatException('Unknown bearing_quality.');
      }
    }

    for (final bearingKey in ['magnetic_bearing', 'true_north_bearing']) {
      final v = optDouble(bearingKey);
      if (v != null && (v < 0 || v > 360)) {
        throw ObservationShareFormatException('$bearingKey out of range.');
      }
    }

    DateTime parseTimestampFrom(String key, String raw) {
      final parsed = DateTime.tryParse(raw);
      if (parsed == null) {
        throw ObservationShareFormatException('Invalid timestamp "$key".');
      }
      return parsed;
    }

    DateTime parseTimestamp(String key) {
      final raw = reqString(key);
      final parsed = DateTime.tryParse(raw);
      if (parsed == null) {
        throw ObservationShareFormatException('Invalid timestamp "$key".');
      }
      return parsed;
    }

    // v1 payloads predate every identity field, so identity stays null and the
    // caller is responsible for saying so. v2+ requires the whole block — a
    // half-populated identity is worse than none, because it would be written
    // as an authoritative replica.
    SharedObservationIdentity? identity;
    if (version >= 2) {
      final positionSourceRaw = reqString('position_source');
      final PositionSource positionSource;
      try {
        positionSource = PositionSource.fromDb(positionSourceRaw);
      } catch (_) {
        throw const ObservationShareFormatException('Unknown position_source.');
      }

      final accuracy = optDouble('position_accuracy_m');
      if (accuracy != null && (accuracy < 0 || !accuracy.isFinite)) {
        throw const ObservationShareFormatException('position_accuracy_m out of range.');
      }

      final revisionRaw = json['revision'];
      if (revisionRaw is! int || revisionRaw < 0) {
        throw const ObservationShareFormatException('Missing or invalid "revision".');
      }
      if (revisionRaw > maxRevision) {
        throw const ObservationShareFormatException(
          'Sync clock is out of range ("revision" is implausibly large).',
        );
      }
      // Finding L-2's ceiling arm, on this path too. A value legal to *hold*
      // is not legal to *receive*: admitted at the ceiling, the row goes past
      // it on the holder's next honest edit and their own export will never
      // restore it again. See [UntrustedImportRules.maxImportedRevision].
      if (revisionRaw > UntrustedImportRules.maxImportedRevision) {
        throw const ObservationShareFormatException(
          'Sync clock leaves no room for this device\'s own edits '
          '("revision" is too close to the maximum).',
        );
      }

      final createdAt = parseTimestampFrom('created_at', reqString('created_at')).toUtc();
      final updatedAt = parseTimestampFrom('updated_at', reqString('updated_at')).toUtc();
      if (updatedAt.isBefore(createdAt)) {
        throw const ObservationShareFormatException(
          'Sync clock is inconsistent (updated_at precedes created_at).',
        );
      }
      // Refused rather than clamped. Clamping a hostile clock to "now" would
      // leave it winning last-write-wins against every honest local edit — the
      // attack succeeds and the bound reports that it worked.
      for (final entry in {'created_at': createdAt, 'updated_at': updatedAt}.entries) {
        if (entry.value.isAfter(clockCeiling)) {
          throw ObservationShareFormatException(
            'Sync clock is out of range ("${entry.key}" is in the future).',
          );
        }
        if (entry.value.isBefore(plausibleFloor)) {
          throw ObservationShareFormatException(
            'Sync clock is out of range ("${entry.key}" predates TriTrack).',
          );
        }
      }

      identity = SharedObservationIdentity(
        observationId: _requireRecordId('observation_id', reqString('observation_id')),
        observerUserId: _requireRecordId('observer_user_id', reqString('observer_user_id')),
        observerEmail: _requireEmail(reqString('observer_email')),
        positionSource: positionSource,
        positionAccuracyM: accuracy,
        sync: SyncMeta(
          createdAt: createdAt,
          updatedAt: updatedAt,
          revision: revisionRaw,
          lastModifiedBy: _optionalRecordId('last_modified_by', optString('last_modified_by')),
          originDeviceId: _optionalRecordId('origin_device_id', optString('origin_device_id')),
        ),
      );
    }

    return SharedObservation(
      payloadVersion: version,
      identity: identity,
      observerName: reqString('observer_name'),
      timestampUtc: parseTimestamp('timestamp_utc'),
      timestampLocal: parseTimestamp('timestamp_local'),
      timezoneOffset: reqString('timezone_offset'),
      latitude: latitude,
      longitude: longitude,
      elevation: reqDouble('elevation'),
      tagFrequencyMhz: reqDouble('tag_frequency_mhz'),
      tagPulseRate: optDouble('tag_pulse_rate'),
      tagName: reqString('tag_name'),
      // Absent on any payload written before task 11.32, and on anything a
      // sender chose not to include — both of which read as "these are not
      // known to be the recorded values", which is the honest default. Never
      // trusted for anything but the sentence the paste screen shows.
      tagValuesRecorded: json['tag_values_recorded'] == true,
      observationType: observationType,
      magneticBearing: optDouble('magnetic_bearing'),
      trueNorthBearing: optDouble('true_north_bearing'),
      bearingUncertainty: optDouble('bearing_uncertainty'),
      signalType: signalType,
      // Absent on v1 and v2, which is read as "not recorded" and never
      // completed from the local tag. A slot outside 1..maxPulseModes is
      // dropped rather than refused: it is display-only (see [pulseModeSlot]),
      // so a nonsense value costs a sentence on one screen, and refusing the
      // whole payload over a field nothing is written from would lose a real
      // bearing to a cosmetic fault.
      pulseModeSlot: switch (json['pulse_mode']) {
        final int slot when slot >= 1 && slot <= maxPulseModes => slot,
        _ => null,
      },
      pulseModeName: optString('pulse_mode_name'),
      // Absent on v1, v2 and v3, and on a v4 payload whose sender had no
      // answer — all of which read as "not recorded" rather than as "the
      // signal was fine". Anything that is not a JSON boolean is treated as
      // absent rather than refusing the payload: this field is one bit of
      // context on a record whose bearing, position and time are the reason it
      // was sent, and losing all of that to a malformed flag would be the
      // wrong trade. `NumericBound.flag` is what refuses a bad value on the
      // sync wire, where the column is written directly.
      signalIrregular: switch (json['signal_irregular']) {
        final bool flagged => flagged,
        _ => null,
      },
      signalStrength: signalStrength,
      bearingQuality: bearingQuality,
      notes: optString('notes'),
    );
  }

  /// Ids from a payload are written straight into primary-key and foreign-key
  /// columns, so they are bounded here rather than trusted. The check is
  /// deliberately "opaque id" shaped, not strict UUID-v4: ids are opaque
  /// identifiers on the wire, production writes them as `Uuid().v4()`, and a
  /// v4-only rule would reject legitimately-formed ids from fixtures, seeded
  /// data, or a future id scheme. What it does reject is the hostile shape —
  /// quotes, wildcards, path or SQL punctuation, whitespace, and absurd
  /// lengths.
  static String _requireRecordId(String key, String value) {
    if (value.length > 64 || !RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(value)) {
      throw ObservationShareFormatException('Invalid "$key" (not a valid id).');
    }
    return value;
  }

  static String? _optionalRecordId(String key, String? value) =>
      value == null ? null : _requireRecordId(key, value);

  /// The email is the cross-device identity anchor and the receiver's dedup
  /// key, so a malformed one would silently create a junk `Users` row that
  /// nothing ever matches again. Validated loosely (one `@`, non-empty local
  /// part, dotted domain, no whitespace) and returned normalized so both sides
  /// agree on the anchor's exact form.
  static String _requireEmail(String value) {
    final normalized = UserRepository.normalizeEmail(value);
    final valid = normalized.length <= 254 &&
        RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(normalized);
    if (!valid) {
      throw const ObservationShareFormatException('Invalid "observer_email".');
    }
    return normalized;
  }
}
