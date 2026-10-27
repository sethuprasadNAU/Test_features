import 'package:freezed_annotation/freezed_annotation.dart';

import 'package:tritrack_sync/tritrack_sync.dart';
import 'pulse_mode.dart';
import 'sync_meta.dart';
import 'tag_fields.dart';
import 'tag.dart';

part 'tag_library_entry.freezed.dart';

/// One transmitter in **this device's personal tag library** — task 11.219.
///
/// ## What the library is
///
/// The lab's list of collars: everything this person has on hand, whether or
/// not any project is using it. It is what a project's tag is **copied
/// from**, and it is the answer to "what transmitters do I have".
///
/// ## It never leaves the device, and that costs nothing
///
/// The library is not in `syncTables` or `tableSpecs`, so it appears in no
/// push, no pull and no archive. That looks like a loss — the security model
/// §5.9(a) kept a write path open precisely so *"a tag not yet on any project
/// still has to replicate between one person's phone and their laptop"* — and
/// the design measured it: **that flow has never worked in either direction.**
/// A device will not offer an unlinked tag (the offer filter needs the id to
/// appear in a project-scoped row, and an unlinked tag appears in none) and a
/// server will not return one (pull narrows by the same set). Sync is
/// per-project on both sides and an unlinked tag belongs to no project, so
/// there was never a request that could carry it.
///
/// So a device-local library takes nothing away that worked, and it closes
/// §5.9(a)'s residual by construction: after task 11.219 there is no such
/// thing as an unlinked synced tag, because a `Tags` row cannot exist without
/// a project.
///
/// ## Its relationship to a project's [Tag]
///
/// [lineageId] is the whole of it. A library entry and every project copy
/// made from it share one, unchanged, forever — see [Tag.lineageId] for why
/// that is a value rather than a pointer at a row. The library holds **no
/// version history**: a version records what a collar read when a bearing was
/// taken against it, and nothing is ever recorded against a library entry.
@freezed
abstract class TagLibraryEntry with _$TagLibraryEntry implements TagFields {
  const TagLibraryEntry._();

  const factory TagLibraryEntry({
    required String tagId,

    /// Which physical collar this is. Shared, unchanged, with every project
    /// copy ever made from this entry.
    required String lineageId,
    required double frequencyMhz,
    double? pulseRate,
    String? pulsePattern,
    required String tagName,
    required TagStatus status,
    String? notes,

    /// **The library keeps a colour, and it is a seed, not a home** — task
    /// 11.241's decision, after 11.240 moved colour to the animal and left
    /// this one on purpose.
    ///
    /// A library entry is a transmitter in no project, so by the model it has
    /// no animal and no colour of its own. It keeps one for the one moment
    /// nothing else can supply it: when the collar is copied into a project,
    /// the animal created for it starts in this colour, so a collar a person
    /// knows as "the orange one" is orange in the new project too (§2.7's
    /// habit, kept as a starting point). **After the copy, nothing reads it.**
    /// No project row ever joins to it, and changing it here recolours no
    /// project — `tag_repository_test.dart` holds that. It looks exactly like
    /// a second source of truth and it is not one, which is why this sentence
    /// is on the field rather than in a report: the next person to "fix" it
    /// should find the reason first.
    required String colorHex,
    String? pulseMode1Name,
    String? pulseMode2Name,
    double? pulseMode2RateBpm,
    String? pulseMode3Name,
    double? pulseMode3RateBpm,
    required SyncMeta sync,
  }) = _TagLibraryEntry;

  /// The modes this collar has right now, never fewer than one — the same
  /// read [Tag.pulseModes] performs.
  @override
  List<PulseMode> get pulseModes => buildPulseModes([
    (pulseMode1Name, pulseRate),
    (pulseMode2Name, pulseMode2RateBpm),
    (pulseMode3Name, pulseMode3RateBpm),
  ]);

  /// This entry as a project's own tag.
  ///
  /// **[tagId] is the caller's to supply and must be fresh.** A copy is a new
  /// row: it keeps the lineage and takes a new identity, which is what makes
  /// editing one project's tag leave every other project's alone. Passing the
  /// library entry's own id here would put the two rows into the same
  /// identity and undo the whole design.
  ///
  /// [colorHex] is carried across deliberately (§2.7): one collar looks the
  /// same in every project a person holds, which is what makes a screenshot
  /// comparable between them. A tag created *new* inside a project picks its
  /// colour by round-robin instead.
  Tag copyInto(
    String projectId, {
    required String tagId,
    required DateTime copiedAt,
    required SyncMeta sync,
  }) => Tag(
    tagId: tagId,
    projectId: projectId,
    lineageId: lineageId,
    copiedAt: copiedAt.toUtc(),
    frequencyMhz: frequencyMhz,
    pulseRate: pulseRate,
    pulsePattern: pulsePattern,
    tagName: tagName,
    status: status,
    notes: notes,
    colorHex: colorHex,
    pulseMode1Name: pulseMode1Name,
    pulseMode2Name: pulseMode2Name,
    pulseMode2RateBpm: pulseMode2RateBpm,
    pulseMode3Name: pulseMode3Name,
    pulseMode3RateBpm: pulseMode3RateBpm,
    sync: sync,
  );

  /// A library entry recording a tag that was created straight into a
  /// project, so the person's library knows about the collar too.
  ///
  /// It keeps the tag's own [Tag.lineageId], which is what later makes the
  /// two recognisable as one collar.
  factory TagLibraryEntry.of(Tag tag, {required String tagId}) =>
      TagLibraryEntry(
        tagId: tagId,
        lineageId: tag.lineageId,
        frequencyMhz: tag.frequencyMhz,
        pulseRate: tag.pulseRate,
        pulsePattern: tag.pulsePattern,
        tagName: tag.tagName,
        status: tag.status,
        notes: tag.notes,
        colorHex: tag.colorHex,
        pulseMode1Name: tag.pulseMode1Name,
        pulseMode2Name: tag.pulseMode2Name,
        pulseMode2RateBpm: tag.pulseMode2RateBpm,
        pulseMode3Name: tag.pulseMode3Name,
        pulseMode3RateBpm: tag.pulseMode3RateBpm,
        sync: tag.sync,
      );

  factory TagLibraryEntry.fromRow(Map<String, Object?> row) => TagLibraryEntry(
    tagId: row['tag_id'] as String,
    lineageId: row['lineage_id'] as String,
    frequencyMhz: row['frequency_mhz'] as double,
    pulseRate: row['pulse_rate'] as double?,
    pulsePattern: row['pulse_pattern'] as String?,
    tagName: row['tag_name'] as String,
    status: TagStatus.fromDb(row['status'] as String),
    notes: row['notes'] as String?,
    colorHex: row['color_hex'] as String,
    pulseMode1Name: row['pulse_mode_1_name'] as String?,
    pulseMode2Name: row['pulse_mode_2_name'] as String?,
    pulseMode2RateBpm: (row['pulse_mode_2_rate_bpm'] as num?)?.toDouble(),
    pulseMode3Name: row['pulse_mode_3_name'] as String?,
    pulseMode3RateBpm: (row['pulse_mode_3_rate_bpm'] as num?)?.toDouble(),
    sync: SyncMeta.fromRow(row),
  );

  Map<String, Object?> toColumns() => {
    'tag_id': tagId,
    'lineage_id': lineageId,
    'frequency_mhz': frequencyMhz,
    'pulse_rate': pulseRate,
    'pulse_pattern': pulsePattern,
    'tag_name': tagName,
    'status': status.db,
    'notes': notes,
    'color_hex': colorHex,
    'pulse_mode_1_name': pulseMode1Name,
    'pulse_mode_2_name': pulseMode2Name,
    'pulse_mode_2_rate_bpm': pulseMode2RateBpm,
    'pulse_mode_3_name': pulseMode3Name,
    'pulse_mode_3_rate_bpm': pulseMode3RateBpm,
    ...sync.toColumns(),
  };
}
