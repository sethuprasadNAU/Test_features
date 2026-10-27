/// **The one place a tag's status is spelled for a person** (task 11.199).
///
/// `TagStatus.db` is a storage spelling — `active`, `recovered`, `lost`,
/// `malfunction` — what the SQLite column holds, what the `CHECK` constraint
/// enforces, and what the tag CSV export writes. It is not a label anybody
/// wrote for a person to read; it only looks like one because all four values
/// happen to be ordinary English words, which is exactly the coincidence that
/// let three screens print it raw for months without anybody noticing:
///
/// - the Tag details page printed `_status.db` when the reader may not edit,
/// - the tag-status wheel labelled its four choices `s.db`,
/// - and Project Setup's tag list appended `tag.status.db` to a tag's subtitle.
///
/// A fourth site — the tag row's status icon in `tag_database_screen.dart` —
/// had the words, in its own `switch`, lower-cased. That was the only mapping
/// of this vocabulary in the app and it lived inside one widget. It reads from
/// here now.
///
/// **This is `role_labels.dart`'s argument applied to a second enum**, and the
/// day somebody stores `presumed_dead` or `recovered_intact` is the day every
/// one of those screens starts printing an identifier at a biologist.
library;

import 'package:tritrack_sync/tritrack_sync.dart';

/// How a tag's status is written for a person to read.
///
/// **Capitalised, because these appear as a value on their own** — a wheel
/// item, a printed field, a chip on a subtitle — rather than mid-sentence.
/// `role_labels.dart` needs four grammatical forms because a role is written
/// into sentences; a tag status is not, and inventing forms nothing calls
/// would be a list nobody reads.
///
/// **The words are the stored words, capitalised, and deliberately so.** This
/// app's data is read afterwards in a CSV where the column holds `malfunction`;
/// a friendlier synonym on the phone — *Faulty*, say — would be a mapping
/// nobody wrote down, which is the mistake task 11.194 corrected for signal
/// strength ("Extreme" on the wheel, `very_strong` in the export).
String tagStatusLabel(TagStatus status) => switch (status) {
  TagStatus.active => 'Active',
  TagStatus.recovered => 'Recovered',
  TagStatus.lost => 'Lost',
  TagStatus.malfunction => 'Malfunction',
};

/// How an animal's status is written for a person to read (task 11.241) —
/// the same rule as [tagStatusLabel], one enum over: the stored word,
/// capitalised, so the phone and the CSV agree.
String individualStatusLabel(IndividualStatus status) => switch (status) {
  IndividualStatus.alive => 'Alive',
  IndividualStatus.dead => 'Dead',
  IndividualStatus.unknown => 'Unknown',
};

/// How an animal's sex is written for a person to read (task 11.241). Null —
/// nobody recorded it — is a different fact from [IndividualSex.unknown] and
/// reads as such.
String individualSexLabel(IndividualSex? sex) => switch (sex) {
  null => 'Not recorded',
  IndividualSex.male => 'Male',
  IndividualSex.female => 'Female',
  IndividualSex.unknown => 'Unknown',
};
