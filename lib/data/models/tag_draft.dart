import 'package:tritrack_sync/tritrack_sync.dart';

import 'sync_meta.dart';
import 'tag_fields.dart';
import 'tag.dart';
import 'tag_library_entry.dart';

/// **What a person typed into the tag form, before anybody decides which row
/// it becomes** — task 11.219.
///
/// Copy-on-add gave the app two places a transmitter's details can live: a
/// project's own [Tag], and this device's [TagLibraryEntry]. The **form** is
/// the same in both — frequency, name, pulse modes, status, notes, colour —
/// and it is a large, carefully-measured piece of UI with a pulse-mode
/// editor, a colour grid and a unit toggle inside it.
///
/// **It held three dates until task 11.243** and no longer does: the form
/// describes a piece of equipment, and when that equipment went on an animal
/// is a `Deployment`, recorded by a different act on a different screen (task
/// 11.244).
///
/// So the form edits this, and the screen that opened it decides what to
/// write. The alternative was a second copy of the form, or a form that
/// builds a `Tag` with an invented `project_id` and lets the caller unpick it
/// — the second is the shape that would have shipped, and it is a lie in a
/// column that is half the primary key.
///
/// **It deliberately holds nothing about identity.** No `tag_id`, no
/// `project_id`, no `lineage_id`, no `copied_at` and no sync metadata: those
/// are the four facts a form has no business inventing, and every one of them
/// is supplied by the caller below.
class TagDraft {
  const TagDraft({
    required this.frequencyMhz,
    this.pulseRate,
    this.pulsePattern,
    required this.tagName,
    required this.status,
    this.notes,
    required this.colorHex,
    this.pulseMode1Name,
    this.pulseMode2Name,
    this.pulseMode2RateBpm,
    this.pulseMode3Name,
    this.pulseMode3RateBpm,
  });

  /// The draft of an existing row, so the form starts where the row is and a
  /// field nobody touched round-trips unchanged.
  factory TagDraft.of(TagFieldsSource source) => TagDraft(
    frequencyMhz: source.frequencyMhz,
    pulseRate: source.pulseRate,
    pulsePattern: source.pulsePattern,
    tagName: source.tagName,
    status: source.status,
    notes: source.notes,
    colorHex: source.colorHex,
    pulseMode1Name: source.pulseMode1Name,
    pulseMode2Name: source.pulseMode2Name,
    pulseMode2RateBpm: source.pulseMode2RateBpm,
    pulseMode3Name: source.pulseMode3Name,
    pulseMode3RateBpm: source.pulseMode3RateBpm,
  );

  final double frequencyMhz;
  final double? pulseRate;
  final String? pulsePattern;
  final String tagName;
  final TagStatus status;
  final String? notes;
  final String colorHex;
  final String? pulseMode1Name;
  final String? pulseMode2Name;
  final double? pulseMode2RateBpm;
  final String? pulseMode3Name;
  final double? pulseMode3RateBpm;

  /// This draft written onto an existing project tag, keeping its identity,
  /// its lineage, its copy date and its sync metadata.
  Tag onto(Tag existing) => existing.copyWith(
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
  );

  /// This draft written onto an existing library entry.
  TagLibraryEntry ontoEntry(TagLibraryEntry existing) => existing.copyWith(
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
  );

  /// A brand-new library entry from this draft.
  ///
  /// **[lineageId] defaults to [tagId] and that is not laziness.** A collar
  /// entered here for the first time has no earlier copy to inherit a lineage
  /// from, and the row's own id is already unique and already unguessable —
  /// which is exactly the reasoning schema v14's migration used for every tag
  /// that existed before lineages did.
  TagLibraryEntry newEntry({
    required String tagId,
    String? lineageId,
    required SyncMeta sync,
  }) => TagLibraryEntry(
    tagId: tagId,
    lineageId: lineageId ?? tagId,
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

  /// A brand-new tag created straight into [projectId] — the record screen's
  /// quick-add and the paste screen's relabelling, where nobody went via the
  /// library.
  ///
  /// `copied_at` stays null: nothing was copied. See [Tag.copiedAt].
  Tag newTag({
    required String tagId,
    required String projectId,
    String? lineageId,
    required SyncMeta sync,
  }) => Tag(
    tagId: tagId,
    projectId: projectId,
    lineageId: lineageId ?? tagId,
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
}

/// What [TagDraft.of] can be built from — satisfied by both [Tag] and
/// [TagLibraryEntry] through `TagFields`.
typedef TagFieldsSource = TagFields;
