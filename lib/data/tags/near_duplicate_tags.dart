/// Finding the existing tag a tag about to be created would duplicate
/// (task 11.11).
///
/// **This warns; it never refuses, and the distinction is the whole point.**
/// Two collars can legitimately share a nominal frequency if they are never in
/// range of each other — uncommon, but real. Refusing the second one would
/// block honest field data to prevent untidiness, which is the trade task 11.11
/// exists to avoid: a field tech who cannot create a tag cannot record the
/// observation at all, and a lost bearing is worse than a duplicate tag.
///
/// **Duplicates that get through are Phase 12's merge tool.** Nothing here
/// tries to reconcile two tags; it only makes the person creating the second
/// one able to see the first.
library;

import '../models/tag_fields.dart';

/// What about an existing tag matched the one being created.
enum TagMatchKind {
  /// The same frequency, to the kilohertz — **the one that matters.** Two tags
  /// on one frequency in one project make triangulation ambiguous: a bearing
  /// carries the frequency and nothing else, so the app cannot say which collar
  /// it came from.
  frequency,

  /// The same name, ignoring case and surrounding whitespace. Softer, and
  /// matched exactly on purpose — `F12` beside `F12b` is often two real
  /// collars, so a fuzzy rule here would cry wolf and train the habit of
  /// dismissing the warning unread.
  name,
}

/// One existing tag that resembles the tag being created.
class NearDuplicateTag {
  const NearDuplicateTag({
    required this.existing,
    required this.matched,
    required this.sharesProject,
  });

  /// The tag already on this device — a project's own tag, or an entry in
  /// the personal library. See `TagFields`.
  final TagFields existing;

  /// Which fields matched. Never empty.
  final Set<TagMatchKind> matched;

  /// Whether [existing] is a tag of the project this one is being created
  /// in. False when no project was named, or when the match is an entry in
  /// this device's personal tag library rather than a project's tag.
  final bool sharesProject;

  /// The single line the warning shows for this match.
  ///
  /// It names the tag and says what matched, because **a warning the reader
  /// cannot evaluate gets dismissed every time** — and a control that trains
  /// the habit of dismissing it is worse than no control, since it also teaches
  /// people to ignore the next one.
  String get summary {
    final what = switch ((
      matched.contains(TagMatchKind.frequency),
      matched.contains(TagMatchKind.name),
    )) {
      (true, true) => 'same frequency and same name',
      (true, false) =>
        'same frequency (${existing.frequencyMhz.toStringAsFixed(3)} MHz)',
      _ => 'same name ("${existing.tagName}")',
    };
    // **Task 11.219 changed the second phrase and it is not cosmetic.** It
    // used to read *"in the tag database, not on this project"*, which was
    // true when there was one global tag table. There is no such thing now:
    // the match is either a tag of this project, or an entry in the person's
    // own library, and those are different objects with different
    // consequences. Saying so is what lets somebody decide whether the
    // warning matters.
    final where = sharesProject
        ? 'already on this project'
        : 'in your tag library';
    return '${existing.frequencyMhz.toStringAsFixed(3)} MHz · '
        '${existing.tagName} — $what, $where';
  }
}

/// Matches a tag about to be created against the tags already on the device.
abstract final class NearDuplicateTags {
  /// Whether two frequencies are the same tag's frequency.
  ///
  /// Equal once rounded to the kilohertz, which is deliberately the same
  /// precision every screen in the app *displays* (`toStringAsFixed(3)`). The
  /// rule is therefore one the reader can check by eye — "these two show the
  /// same number" — rather than a tolerance they would have to be told about.
  /// 150.001 and 150.002 MHz are two different collars and do not match.
  static bool sameFrequency(double a, double b) {
    if (a.isNaN || b.isNaN) return false;
    return (a * 1000).round() == (b * 1000).round();
  }

  static String _normalizeName(String name) => name.trim().toLowerCase();

  /// Every tag in [existing] that resembles the (frequency, name) being
  /// created, most concerning first.
  ///
  /// [projectTagIds] is the set of tag ids linked to the project the new tag is
  /// being created in — pass an empty set when no project is involved. Matches
  /// inside that project sort first, and a frequency match sorts above a name
  /// match, because that is the order of how much trouble each one causes.
  ///
  /// [excludeTagId] drops one id from consideration, so editing a tag does not
  /// report the tag as a duplicate of itself.
  ///
  /// [excludeLineageIds] is the same idea one level up, and **task 11.219's
  /// trap.** Copying a library entry into a project produces, by definition,
  /// a tag with the same frequency and the same name as the entry it came
  /// from: run that through this check unchanged and *every single copy
  /// warns*. A warning that always fires is one people learn to dismiss —
  /// the exact failure this check's own doc comment says it exists to avoid,
  /// caused by the check itself. **A copy whose lineage matches its source is
  /// not a near-duplicate.**
  ///
  /// Two copies of one lineage *inside one project* is a different matter and
  /// a real defect — there is no legitimate reason for a project to hold the
  /// same collar twice — and it is refused at the point of copying rather
  /// than warned about here.
  static List<NearDuplicateTag> find({
    required double frequencyMhz,
    required String tagName,
    required Iterable<TagFields> existing,
    Set<String> projectTagIds = const {},
    String? excludeTagId,
    Set<String> excludeLineageIds = const {},
  }) {
    final name = _normalizeName(tagName);
    final matches = <NearDuplicateTag>[];
    for (final tag in existing) {
      if (tag.tagId == excludeTagId) continue;
      if (excludeLineageIds.contains(tag.lineageId)) continue;
      final matched = <TagMatchKind>{
        if (sameFrequency(tag.frequencyMhz, frequencyMhz))
          TagMatchKind.frequency,
        if (name.isNotEmpty && _normalizeName(tag.tagName) == name)
          TagMatchKind.name,
      };
      if (matched.isEmpty) continue;
      matches.add(
        NearDuplicateTag(
          existing: tag,
          matched: matched,
          sharesProject: projectTagIds.contains(tag.tagId),
        ),
      );
    }
    matches.sort((a, b) => _rank(a).compareTo(_rank(b)));
    return matches;
  }

  /// Lower sorts first: in-project frequency collisions are the ones that
  /// actually break triangulation.
  static int _rank(NearDuplicateTag m) {
    final frequency = m.matched.contains(TagMatchKind.frequency);
    if (m.sharesProject && frequency) return 0;
    if (m.sharesProject) return 1;
    return frequency ? 2 : 3;
  }
}
