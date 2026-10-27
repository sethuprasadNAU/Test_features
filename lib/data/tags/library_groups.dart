import '../../core/utils/natural_sort.dart';
import '../models/tag.dart';
import '../models/tag_fields.dart';
import '../models/tag_library_entry.dart';

/// One heading on the Tag Library screen — task 11.321, item 1.
///
/// Michael, 2026-09-30: the library is in practice project-specific, and he
/// does not want to see every tag at once. So it is **grouped automatically
/// by the projects each collar is on**, with no folders anybody makes.
class LibraryGroup {
  const LibraryGroup({
    required this.projectId,
    required this.title,
    required this.entries,
  });

  /// The project this group is, or null for "Not on any project".
  final String? projectId;
  final String title;

  /// In the order the screen's sort chose — [groupLibraryByProject] keeps
  /// the order it was handed.
  final List<TagLibraryEntry> entries;

  /// Stable across rebuilds, and distinct from every project id.
  String get key => projectId ?? '';
}

/// The heading for collars no project on this device holds.
const kNotOnAnyProjectTitle = 'Not on any project';

/// Groups [entries] by the projects that hold a copy of each, read from
/// [holders] (lineage → project id → project name, as
/// `TagLibraryRepository.projectsHoldingEachLineage` returns it).
///
/// - **A collar on two projects is under both.** The groups are views of one
///   list, not a partition of it.
/// - Projects are ordered by name (natural order, so "Site 2" precedes
///   "Site 10"), and "Not on any project" comes last.
/// - **Every project in [projects] gets a heading, even an empty one** (task
///   11.321's drag-to-assign: a tag is dragged onto a project's heading, and
///   the commonest case is a project with no tags yet). [projects] is id →
///   name; a project named only in [holders] is listed too.
/// - **[order] puts the person's own arrangement first** (task 11.321:
///   headings can be dragged into any order). Projects in it come first, in
///   its order; the rest follow by name. An id in [order] with no project is
///   ignored, so a deleted project leaves no gap.
List<LibraryGroup> groupLibraryByProject(
  List<TagLibraryEntry> entries,
  Map<String, Map<String, String>> holders, {
  Map<String, String> projects = const {},
  List<String> order = const [],
}) {
  final byProject = <String, List<TagLibraryEntry>>{
    for (final id in projects.keys) id: [],
  };
  final names = <String, String>{...projects};
  final loose = <TagLibraryEntry>[];
  for (final entry in entries) {
    final held = holders[entry.lineageId];
    if (held == null || held.isEmpty) {
      loose.add(entry);
      continue;
    }
    for (final MapEntry(key: id, value: name) in held.entries) {
      (byProject[id] ??= []).add(entry);
      names[id] = name;
    }
  }
  final placed = {for (var i = 0; i < order.length; i++) order[i]: i};
  final ids = byProject.keys.toList()
    ..sort((a, b) {
      final pa = placed[a], pb = placed[b];
      if (pa != null || pb != null) {
        if (pa == null) return 1;
        if (pb == null) return -1;
        return pa.compareTo(pb);
      }
      final byName = naturalCompare(names[a]!, names[b]!);
      return byName != 0 ? byName : a.compareTo(b);
    });
  return [
    for (final id in ids)
      LibraryGroup(projectId: id, title: names[id]!, entries: byProject[id]!),
    if (loose.isNotEmpty)
      LibraryGroup(
        projectId: null,
        title: kNotOnAnyProjectTitle,
        entries: loose,
      ),
  ];
}

/// The Tag Library entries [projectTags] does not already hold, by
/// frequency — what may be copied into that project.
///
/// **One derivation, two screens** (task 11.321): More → Tags's "Copy from
/// library" and the animal's "Link a tag" both offer this list. A collar the
/// project already holds is matched by lineage, not id — the project's row is
/// a copy, so its id differs by construction — and is not offered again: two
/// copies of one collar in one project has no legitimate use (§2.6).
List<TagLibraryEntry> libraryEntriesNotOnProject(
  Iterable<TagLibraryEntry> library,
  Iterable<Tag> projectTags,
) {
  final held = {for (final tag in projectTags) tag.lineageId};
  return [
    for (final entry in library)
      if (!held.contains(entry.lineageId)) entry,
  ]..sort((a, b) => a.frequencyMhz.compareTo(b.frequencyMhz));
}

/// **Whether [tag] is found by the Tag Library's search box** — task 11.322.
/// Michael, 2026-09-30: search "by frequency or name".
///
/// The name is matched anywhere in it, ignoring case. The frequency is matched
/// as the row writes it (three decimals, `150.325`), so what a person types is
/// what they can see; `150.3` and `325` both find it. An empty search matches
/// everything, and spaces around it are ignored.
bool tagMatchesSearch(TagFields tag, String query) {
  final q = query.trim().toLowerCase();
  if (q.isEmpty) return true;
  return tag.tagName.toLowerCase().contains(q) ||
      tag.frequencyMhz.toStringAsFixed(3).contains(q);
}
