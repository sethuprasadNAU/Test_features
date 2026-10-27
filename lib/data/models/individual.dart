import 'package:freezed_annotation/freezed_annotation.dart';

import 'package:tritrack_sync/tritrack_sync.dart';
import 'sync_meta.dart';

part 'individual.freezed.dart';

/// An animal, **as one project holds it** — task 11.240.
///
/// The thing actually being tracked. A [Tag] is a transmitter on an animal
/// between two dates; before schema v16 the animal existed only as the
/// collar's label, and the moment Marie changed collars the database had two
/// rows and no way to say they were one bird. This is that row.
///
/// **A tag names its individual; an individual never lists its tags.** The
/// link is `Tags.individual_id`, and "Marie's collars" — and "Marie's track"
/// — are queries. Bearings stay attached to the transmitter they were heard
/// from, so a mistake about who wore what is corrected by re-pointing one
/// tag row and never by touching a bearing.
///
/// **Colour lives here and nowhere else.** [colorHex] is the animal's: one
/// colour across every collar she has worn, and last season's bearings
/// recolour with her. A `Tag.colorHex` is this value read through the tag's
/// individual, never the tag's own.
///
/// **[status] is the animal's, not the collar's.** A recovered collar says
/// nothing about whether the bird is alive; a dead bird's collar may be
/// transmitting perfectly. Nothing derives one from the other after
/// creation.
@freezed
abstract class Individual with _$Individual {
  const Individual._();

  const factory Individual({
    required String individualId,

    /// The project this row belongs to. Part of the key.
    required String projectId,

    /// "Marie". Never inferred from a tag's name except once, by the v16
    /// backfill, which says so.
    required String name,

    /// The one home of colour — `#RRGGBB`.
    required String colorHex,
    required IndividualStatus status,

    /// Free text: whatever the project calls the species. Null where nobody
    /// wrote it.
    String? species,

    /// Null where nobody recorded it, which is a different fact from
    /// [IndividualSex.unknown].
    IndividualSex? sex,
    String? notes,

    /// **Which animal this is, across every project that holds a copy —
    /// recorded, exported, and read by nothing live.** The same meaning
    /// `Tag.lineageId` has: two projects' individuals are the same bird
    /// exactly when these are equal, which is what lets Ponui 2025 and Ponui
    /// 2026 be one dataset in an export. Nothing in the app resolves it —
    /// `assertSealedColumnsFeedNoReachability` fails if it is ever declared
    /// in a set that decides which rows travel.
    required String lineageId,

    /// When this copy was made, or null on an individual created in this
    /// project. Null is the information, not a gap.
    DateTime? copiedAt,
    required SyncMeta sync,
  }) = _Individual;

  /// The status a **newly created** individual starts with, given the
  /// collar's — the one place a [TagStatus] ever seeds an [IndividualStatus],
  /// and the same rule the v16 backfill applied to every existing tag
  /// (`schemaV16Statements`): an active collar is on an animal presumed
  /// alive, which is the assumption every screen already made by showing
  /// the tag; every other collar state says nothing about the bird. A
  /// default, not a claim, and edited freely afterwards. Nothing calls this
  /// on an existing individual — a recovered collar must not make a dead
  /// animal read as alive.
  static IndividualStatus statusSeededFrom(TagStatus collar) => switch (collar) {
    TagStatus.active => IndividualStatus.alive,
    TagStatus.recovered ||
    TagStatus.lost ||
    TagStatus.malfunction => IndividualStatus.unknown,
  };

  factory Individual.fromRow(Map<String, Object?> row) => Individual(
    individualId: row['individual_id'] as String,
    projectId: row['project_id'] as String,
    name: row['name'] as String,
    colorHex: row['color_hex'] as String,
    status: IndividualStatus.fromDb(row['status'] as String),
    species: row['species'] as String?,
    sex: switch (row['sex']) {
      final String value => IndividualSex.fromDb(value),
      _ => null,
    },
    notes: row['notes'] as String?,
    lineageId: row['lineage_id'] as String,
    copiedAt: DbCodec.decodeUtcOrNull(row['copied_at']),
    sync: SyncMeta.fromRow(row),
  );

  Map<String, Object?> toColumns() => {
    'individual_id': individualId,
    'project_id': projectId,
    'name': name,
    'color_hex': colorHex,
    'status': status.db,
    'species': species,
    'sex': sex?.db,
    'notes': notes,
    'lineage_id': lineageId,
    'copied_at': DbCodec.encodeUtcOrNull(copiedAt),
    ...sync.toColumns(),
  };
}
