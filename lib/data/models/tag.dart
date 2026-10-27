import 'package:freezed_annotation/freezed_annotation.dart';

import 'package:tritrack_sync/tritrack_sync.dart';
import 'pulse_mode.dart';
import 'sync_meta.dart';
import 'tag_fields.dart';

part 'tag.freezed.dart';

/// A VHF transmitter, **as one project holds it** (task 11.219) — and since
/// task 11.243 a piece of **equipment** rather than a deployment.
///
/// It used to carry `date_put_on`, `date_removed`, `capture_date` and (for
/// one schema version) `individual_id`, which made a row here a *deployment*:
/// one collar, on one animal, between two dates. It is an inventory row now —
/// a transmitter somebody bought, entered before any animal exists — and the
/// dated link is [Deployment]. `ANIMALS_AND_DEPLOYMENTS_DESIGN.md` §§1–3.
///
/// **`tagName` is the tag's identifier, not an animal's name.** Michael: *"so
/// that there isn't any confusion that a tag identifier and an animal name
/// are different."* The column keeps its name; the words on screen become
/// *"Tag ID"* (task 11.245).
///
/// Adding a tag to a project copies it, so this row is that project's own:
/// editing it changes neither the device's personal tag library
/// ([TagLibraryEntry]) nor any other project's copy. Two projects' copies of
/// the same physical collar are recognisable by an equal [lineageId], and by
/// nothing else — see [lineageId] for why that is a value rather than a
/// pointer.
///
/// `pulseRate`/`pulsePattern` are often the only way to distinguish two tags
/// on the same nominal frequency in the field.
///
/// Lifecycle: tags are "never deleted, only deactivated" — change [status]
/// rather than setting the soft-delete tombstone, preserving the audit
/// trail.
@freezed
abstract class Tag with _$Tag implements TagFields {
  const Tag._();

  const factory Tag({
    required String tagId,

    /// The project this copy of the collar belongs to. Part of the key.
    required String projectId,

    /// **Which physical collar this is, across every project that holds a
    /// copy of it — recorded, exported, and read by nothing live.**
    ///
    /// A random identifier minted when a tag is first created and carried
    /// unchanged by every copy of it, forever. Two projects' tags are the
    /// same transmitter exactly when these are equal.
    ///
    /// It is a value rather than a pointer at the source row for three
    /// reasons (design §2.3): it cannot dangle, because it names nothing; it
    /// is transitive without a project's row ever referring to another
    /// project; and it survives the case a pointer cannot, a tag created
    /// inside a project and later copied elsewhere.
    ///
    /// **Nothing in the app resolves it**, and that is enforced rather than
    /// promised — `assertSealedColumnsFeedNoReachability` fails if it is
    /// ever declared in a set that decides which rows travel. Its use is in
    /// an export: a multi-season analysis that has to know two files are
    /// about one animal.
    required String lineageId,

    /// When this copy was made, or null on a tag created in this project.
    ///
    /// Null is the information, not a gap: a tag that was always here was not
    /// copied, and a date invented for it would be a claim about a past
    /// nobody observed.
    DateTime? copiedAt,
    required double frequencyMhz,
    double? pulseRate,
    String? pulsePattern,
    required String tagName,

    /// The **equipment's** state — working, failed, retired, lost. It is not
    /// "deployed" (task 11.243): whether a collar is currently on an animal
    /// is derived from `Deployments` and is not stored twice.
    required TagStatus status,
    String? notes,

    /// **The colour of the animal currently wearing this collar — derived,
    /// never stored on the tag** (task 11.240, re-routed by 11.243).
    ///
    /// On a tag read back from the database this is `Individuals.color_hex`
    /// for the animal of the collar's **current deployment** — the one with
    /// an attached date and no removed date. A collar on nobody reads
    /// [TagColorPalette.noIndividual], a rendering constant, and **that is
    /// the normal starting state for a tag rather than an exception**
    /// (design §1): equipment is entered before any animal exists.
    ///
    /// It is never written to `Tags.color_hex`, which is retired —
    /// [toColumns] sends null — and [fromRow] does not read that column.
    /// Recolouring is an edit to the *animal*, so it recolours every collar
    /// she has ever worn: Marie is one colour across both her transmitters.
    required String colorHex,

    /// The animal's name, read through the same current deployment that
    /// supplies [colorHex] — never stored on the tag, never sent:
    /// [toColumns] omits it. Null for a collar that is on nobody, and on a
    /// tag built by hand rather than read from the database.
    ///
    /// **`individualId` was a column here for exactly one schema version**
    /// (v16 only) and task 11.243 removed it: the link is dated now, so a tag
    /// cannot answer "whose is this" without being told *when*. See
    /// `DeploymentRepository.animalForObservation`, which is the answer for a
    /// bearing, and `currentAnimalForTag`, which is the answer for a screen.
    String? individualName,

    /// **The tag's pulse modes — task 11.187.** Read them through
    /// [pulseModes]; these five are the raw columns and slot 1's rate is
    /// [pulseRate] above, for the reason `pulse_modes.dart` gives.
    String? pulseMode1Name,
    String? pulseMode2Name,
    double? pulseMode2RateBpm,
    String? pulseMode3Name,
    double? pulseMode3RateBpm,
    required SyncMeta sync,
  }) = _Tag;

  /// The modes this tag has **right now**, never fewer than one.
  ///
  /// This is the *current* read — what the Record screen offers and what the
  /// tag form edits. The question "what mode was this bearing heard on" is a
  /// different one and is answered through the tag *version*
  /// ([RecordedTagState]), because a mode that has since been renamed or
  /// switched off must not rewrite the record that used it.
  @override
  List<PulseMode> get pulseModes => buildPulseModes([
        (pulseMode1Name, pulseRate),
        (pulseMode2Name, pulseMode2RateBpm),
        (pulseMode3Name, pulseMode3RateBpm),
      ]);

  /// This tag with the modes Michael chose for a **newly created** collar:
  /// Normal at 60 bpm and Mortality at 120 bpm (2026-09-07, *"'Normal' at 1
  /// pulse per second and Mortality at 2 pulses per second"*).
  ///
  /// **One place, called from every creation site**, because "the two default
  /// modes" typed out at four call sites is the hand-maintained list this
  /// project keeps finding — and the fourth site is always the one that gets
  /// missed. The tag form does not call it: that form lets somebody edit the
  /// modes before saving, and it starts its own editor from the same two
  /// constants.
  ///
  /// **An existing rate is kept.** A caller that already knows the collar's
  /// primary rate — the paste screen, which has one from the payload — keeps
  /// it and takes only the names and the mortality default.
  Tag withDefaultPulseModes() => copyWith(
        pulseMode1Name: defaultPulseModeNames[0],
        pulseRate: pulseRate ?? defaultPulseModeRatesBpm[0],
        pulseMode2Name: defaultPulseModeNames[1],
        pulseMode2RateBpm: pulseMode2RateBpm ?? defaultPulseModeRatesBpm[1],
      );

  /// The joined column `TagRepository` reads a tag's colour from — the
  /// current deployment's individual's `color_hex`, aliased so it cannot be
  /// confused with the tag's own retired column. A row without it (one built
  /// by hand, or the output of [toColumns]) reads as a collar on nobody,
  /// which is visible rather than stale.
  static const individualColorColumn = 'individual_color_hex';

  /// The joined column the animal's name arrives in — see [individualName].
  static const individualNameColumn = 'individual_name';

  factory Tag.fromRow(Map<String, Object?> row) => Tag(
        tagId: row['tag_id'] as String,
        projectId: row['project_id'] as String,
        lineageId: row['lineage_id'] as String,
        copiedAt: DbCodec.decodeUtcOrNull(row['copied_at']),
        frequencyMhz: row['frequency_mhz'] as double,
        pulseRate: row['pulse_rate'] as double?,
        pulsePattern: row['pulse_pattern'] as String?,
        tagName: row['tag_name'] as String,
        status: TagStatus.fromDb(row['status'] as String),
        notes: row['notes'] as String?,
        // Deliberately not `row['color_hex']`: that column is retired and a
        // value in it is history, not the answer. See [colorHex].
        colorHex: row[individualColorColumn] as String? ??
            TagColorPalette.noIndividual,
        individualName: row[individualNameColumn] as String?,
        pulseMode1Name: row['pulse_mode_1_name'] as String?,
        pulseMode2Name: row['pulse_mode_2_name'] as String?,
        pulseMode2RateBpm: (row['pulse_mode_2_rate_bpm'] as num?)?.toDouble(),
        pulseMode3Name: row['pulse_mode_3_name'] as String?,
        pulseMode3RateBpm: (row['pulse_mode_3_rate_bpm'] as num?)?.toDouble(),
        sync: SyncMeta.fromRow(row),
      );

  Map<String, Object?> toColumns() => {
        'tag_id': tagId,
        'project_id': projectId,
        'lineage_id': lineageId,
        'copied_at': DbCodec.encodeUtcOrNull(copiedAt),
        'frequency_mhz': frequencyMhz,
        'pulse_rate': pulseRate,
        'pulse_pattern': pulsePattern,
        'tag_name': tagName,
        'status': status.db,
        'notes': notes,
        // Retired since schema v16: colour lives on the individual, and a
        // v16 writer sends null so no `Tags.color_hex` anywhere can be
        // mistaken for the current colour. See `TagColumnKind.retired`.
        'color_hex': null,
        'pulse_mode_1_name': pulseMode1Name,
        'pulse_mode_2_name': pulseMode2Name,
        'pulse_mode_2_rate_bpm': pulseMode2RateBpm,
        'pulse_mode_3_name': pulseMode3Name,
        'pulse_mode_3_rate_bpm': pulseMode3RateBpm,
        ...sync.toColumns(),
      };
}
