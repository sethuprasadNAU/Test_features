import 'package:tritrack_sync/tritrack_sync.dart';

import 'pulse_mode.dart';
import 'sync_meta.dart';

/// **What a transmitter reads, wherever the row happens to live** — task
/// 11.219.
///
/// Copy-on-add split one table in two. A [Tag] is one project's copy of a
/// collar; a [TagLibraryEntry] is the same collar in this device's personal
/// library. They differ in exactly three columns — the project, the copy
/// date, and which of the two carries a version chain — and are identical in
/// the sixteen a person actually reads.
///
/// Everything that *displays* or *compares* a transmitter is written against
/// this rather than against either class: the tag row widget, the sort order,
/// the CSV export, the near-duplicate check. **The alternative was two copies
/// of each**, which is the hand-maintained-list defect this project has found
/// often enough to have a rule about — and it would fail in the worst
/// direction here, because the copy that drifts is the one nobody is looking
/// at.
///
/// It carries no behaviour of its own on purpose. Both implementers are
/// `freezed` classes and this is the shape they already had; adding a method
/// here would mean writing it twice, which is the thing being avoided.
abstract interface class TagFields {
  /// The row's own identifier. **Not a stable identity for the collar** — two
  /// projects' copies of one transmitter have different ids. What identifies
  /// the collar is [lineageId].
  String get tagId;

  /// Which physical collar this row is about, shared unchanged by every copy
  /// of it — see `Tag.lineageId`.
  ///
  /// **Two reads of it are permitted and both are on this interface for a
  /// reason.** §2.3 of the design requires that nothing live read a lineage
  /// into a decision about *which rows travel*, and
  /// `assertSealedColumnsFeedNoReachability` enforces exactly that. Counting
  /// how many of this device's own projects hold a copy (§2.5) and refusing
  /// to warn that a copy duplicates the entry it was copied from (§2.6) are
  /// neither of those things: both are local, both are about rows the person
  /// already holds, and both are required by the design rather than
  /// tolerated by it.
  String get lineageId;

  double get frequencyMhz;
  double? get pulseRate;
  String? get pulsePattern;
  String get tagName;

  /// The equipment's state, not the deployment's — task 11.243. The three
  /// dates that used to sit beside this are `Deployment`'s now.
  TagStatus get status;
  String? get notes;
  String get colorHex;
  String? get pulseMode1Name;
  String? get pulseMode2Name;
  double? get pulseMode2RateBpm;
  String? get pulseMode3Name;
  double? get pulseMode3RateBpm;

  /// The modes this collar has right now, never fewer than one.
  List<PulseMode> get pulseModes;

  SyncMeta get sync;
}
