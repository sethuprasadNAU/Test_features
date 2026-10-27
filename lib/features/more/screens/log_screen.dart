import 'dart:math' show max;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/providers/app_context_provider.dart';
import '../../../core/providers/device_id_provider.dart';
import '../../../core/providers/gps_provider.dart';
import '../../../core/providers/recordings_revision_provider.dart';
import '../../../core/format/observation_quality_display.dart' as quality;
import '../../../core/theme/app_theme.dart';
import '../../../core/theme/design_tokens.dart';
import 'package:tritrack_sync/tritrack_sync.dart';
import 'package:uuid/uuid.dart';

import '../../../core/errors/guarded_write.dart';
import '../../../widgets/disabled_reason.dart';

import '../../../data/analysis/analysis_eligibility.dart';
import '../../../data/models/actual_tag_location.dart';
import '../../../data/models/non_detection.dart';
import '../../../data/models/observation_exclusion.dart';
import '../../../data/models/sync_meta.dart';
import '../../../data/models/observation.dart';
import '../../../data/models/project.dart';
import '../../../data/models/deployment.dart';
import '../../../data/models/individual.dart';
import '../../../data/models/tag.dart';
import '../../../data/models/user.dart';
import '../../../data/repositories/deployment_repository.dart';
import '../../../data/repositories/repository_providers.dart';
import '../../../data/sharing/tritrack_copy.dart';
import '../../../localization/coordinate_projection.dart';
import '../../../widgets/load_failure.dart';
import '../../../widgets/tag_color_swatch.dart';
import '../../map/screens/map_screen.dart' show contestedLegendLabel;
import '../../map/services/geo_math.dart';
import '../../observations/widgets/observation_edit_dialog.dart';
import '../../observations/widgets/truth_point_edit_dialog.dart';
import '../../../data/repositories/mutation_authorization.dart';

/// Log: the sortable list of every observation this project has recorded —
/// filter by tag/date range/observer, sort by tag name, frequency, time, or
/// distance to the current position, edit permitted only for observations
/// the current user created, share button per row.
///
/// (Was "Observation History"; renamed when the bottom-tab "Log" — actually
/// the recording form — was renamed to "Record", freeing up "Log" for this
/// sortable browse view instead of burying it under More.)
///
/// "Edit" here is intentionally narrow: the recording form has no edit mode
/// (it only creates new observations — building full bearing/GPS re-capture
/// editing into a list like this is a much larger feature than this phase
/// scopes), so edit lets the owner amend the safe, non-recapture fields —
/// notes, signal strength, bearing quality — the same "quick-fix" fields the
/// recording form itself treats as low-stakes.
class LogScreen extends ConsumerWidget {
  const LogScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final projectAsync = ref.watch(currentProjectProvider);
    return projectAsync.when(
      loading: () => Scaffold(
        appBar: AppBar(title: const Text('Log')),
        body: const Center(child: CircularProgressIndicator()),
      ),
      error: (e, _) => Scaffold(
        appBar: AppBar(title: const Text('Log')),
        body: LoadFailure('this project', error: e),
      ),
      data: (project) => project == null
          ? Scaffold(
              appBar: AppBar(title: const Text('Log')),
              body: const Center(child: Text('Set up a project first.')),
            )
          : DefaultTabController(
              length: 2,
              child: Builder(
                builder: (context) {
                  final tabHeight = _logTabHeight(context);
                  return Scaffold(
                    appBar: AppBar(
                      title: const Text('Log'),
                      bottom: PreferredSize(
                        preferredSize: Size.fromHeight(tabHeight + 2),
                        child: TabBar(
                          tabs: [
                            Tab(
                              text: 'Log',
                              icon: const Icon(Icons.person_outline),
                              height: tabHeight,
                            ),
                            Tab(
                              text: 'Team',
                              icon: const Icon(Icons.groups_outlined),
                              height: tabHeight,
                            ),
                          ],
                        ),
                      ),
                    ),
                    // The personal Log tab (`_HistoryBody`) is unchanged from
                    // before this tab existed — same filters, same sorts,
                    // same tests. `_TeamBody` is new: same project-wide data
                    // (it already included every member's rows via Phase 6
                    // replica import), but sorted by member/tag/time/distance
                    // instead.
                    body: TabBarView(
                      children: [
                        _HistoryBody(project: project),
                        _TeamBody(project: project),
                      ],
                    ),
                  );
                },
              ),
            ),
    );
  }
}

/// Task 11.168: `Tab`'s own icon+text height (`_kTextAndIconTabHeight` in the
/// framework) is a fixed 72.0 logical pixels that does not grow with the
/// ambient text scale, while the label inside it does — so the tab row
/// overflows its own budget starting at AX3 (2.35x) and grows from there.
/// Same shape 11.165/11.167 already met twice on this screen: a fixed box
/// around text that grows. The fix here is 11.164's answer, not 11.167's —
/// there is no second line to wrap into, so there is nothing to grow
/// sideways. Instead this measures what the tab's own icon + label actually
/// need at the current scale and gives `Tab.height` (and the `PreferredSize`
/// wrapping the `TabBar`) exactly that, mirroring `Tab.build`'s layout: an
/// icon, [_tabIconMargin] below it, then the label — see
/// `_TabsPrimaryDefaultsM3.iconMargin` and `Tab.build` in the framework's
/// `tabs.dart`.
///
/// Costs, measured at every stop on the iOS ladder (see
/// `log_screen_tab_row_test.dart`): the row grows from 72px at the default
/// size to roughly 116px at AX5 — taller, never clipped or striped.
const _tabIconSize = 24.0;
const _tabIconMarginBottom = 2.0;

double _logTabHeight(BuildContext context) {
  final style = Theme.of(context).textTheme.titleSmall ??
      const TextStyle(fontSize: 14, fontWeight: FontWeight.w500);
  final scaler = MediaQuery.textScalerOf(context);
  final direction = Directionality.of(context);
  double labelHeight(String s) {
    final painter = TextPainter(
      text: TextSpan(text: s, style: style),
      textScaler: scaler,
      textDirection: direction,
      maxLines: 1,
    )..layout();
    return painter.height;
  }

  final tallestLabel = max(labelHeight('Log'), labelHeight('Team'));
  // A one-pixel margin for the same rounding reason as `_SortFilterLabel`
  // (task 11.167): the painter and the real `RenderParagraph` round
  // sub-pixel heights independently.
  return _tabIconSize + _tabIconMarginBottom + tallestLabel + 1;
}

/// **Both tabs get [animal]** (task 11.272; `_TeamSort` carries the same
/// case below) — Michael asked for it on the Log tab specifically, but the
/// Team tab shows the identical rows sorted a different way, and nothing
/// about "which animal was this" stops being the thing a person is scanning
/// for just because the sort is by member instead of by tag.
enum _LogSort { time, tagName, frequency, distance, animal }

class _HistoryFilters {
  const _HistoryFilters({this.subject, this.userId, this.dateRange});

  /// What the tag chip is filtering to — one collar, or one animal and so
  /// every collar it has worn (task 11.241). Null is "all".
  final _SubjectFilter? subject;
  final String? userId;
  final DateTimeRange? dateRange;

  _HistoryFilters copyWith({
    _SubjectFilter? Function()? subject,
    String? Function()? userId,
    DateTimeRange? Function()? dateRange,
  }) {
    return _HistoryFilters(
      subject: subject != null ? subject() : this.subject,
      userId: userId != null ? userId() : this.userId,
      dateRange: dateRange != null ? dateRange() : this.dateRange,
    );
  }

  bool matches(_LogEntry e) {
    final filter = subject;
    if (filter != null) {
      final nd = e.nonDetection;
      // A "no signal" entry names the collars somebody listened for, so it
      // is matched by collar whichever kind of filter this is — see
      // [_SubjectFilter] for why that reading is the right one.
      final matchesTag = nd != null
          ? nd.tagIdsListenedFor.any(filter.ids.contains)
          : filter.admits(tagId: e.soleTagId, at: e.time);
      if (!matchesTag) return false;
    }
    // **Task 11.93: a truth point now records who found it**, so an observer
    // filter matches one exactly as it matches a bearing. What it still cannot
    // match is a point written before schema v11, whose author is genuinely
    // not recorded — those drop out, and both tabs say so under the filter bar
    // rather than letting the rows vanish silently. See
    // [unattributedTruthPointsHidden].
    if (userId != null && e.userId != userId) return false;
    final range = dateRange;
    if (range != null) {
      final t = e.time;
      final day = DateTime(t.year, t.month, t.day);
      if (day.isBefore(range.start) || day.isAfter(range.end)) return false;
    }
    return true;
  }

  /// How many of [truthPoints] this filter set drops **because they record no
  /// finder**, rather than because they did not match.
  ///
  /// Zero unless an observer filter is on. Before task 11.93 this was every
  /// truth point in the project — the table had no author column at all — and
  /// it is now only the rows written before schema v11, which is a number that
  /// shrinks to zero on a device recording new points. Counting the rows
  /// rather than reporting "some are hidden" is what makes the notice honest
  /// on a project that has both kinds.
  int unattributedTruthPointsHidden(List<ActualTagLocation> truthPoints) =>
      userId == null
          ? 0
          : truthPoints.where((t) => t.userId == null).length;
}

/// A collar, or an animal — the two things the Log can be filtered to since
/// task 11.241.
///
/// **A tag filter is a set of collar ids. An animal filter is a question
/// about time**, and task 11.244 made that difference real.
///
/// *"Show me Marie"* used to mean *"every collar Marie has ever worn"*, which
/// **over-selects**: a collar she wore in 2026 may have been on a different
/// bird in 2025, and those bearings are not hers. Since collars became
/// equipment that gets redeployed (task 11.243) that is not a corner case, it
/// is the point of the whole table. So an animal filter asks the derivation —
/// *which animal was this bearing about* — of each row, by its own timestamp:
/// `DeploymentRepository.animalForObservationIn`, design §7.
///
/// **A "no signal" entry is still matched by collar**, and cannot be matched
/// any other way: it lists the collars somebody listened for and is not a
/// record *of* any one of them, so there is no single timestamped tag to ask
/// the derivation about. Listening for Marie's collar and hearing nothing is
/// hers whether or not she was wearing it, which is the reading that keeps
/// the entry visible to the person who made it.
class _SubjectFilter {
  _SubjectFilter.tag(Tag tag)
      : label = 'Tag: ${tag.tagName}',
        name = tag.tagName,
        ids = {tag.tagId},
        individualId = null,
        deployments = const [];
  _SubjectFilter.animal(
    Individual animal,
    Set<String> collars,
    this.deployments,
  )   : label = 'Animal: ${animal.name}',
        name = animal.name,
        ids = Set.unmodifiable(collars),
        individualId = animal.individualId;

  /// What the chip reads.
  final String label;
  final String name;

  /// The collar ids this filter admits — every collar the animal has worn,
  /// for a "no signal" entry and for the picker's own count.
  final Set<String> ids;

  /// Null for a tag filter; the animal for an animal filter.
  final String? individualId;

  /// The project's live links, for the interval derivation. Empty for a tag
  /// filter, which needs none.
  final List<Deployment> deployments;

  /// Whether [tagId] was on this filter's animal at [at].
  ///
  /// For a tag filter this is plain membership — a bearing on that collar is
  /// a bearing on that collar, whoever was wearing it.
  ///
  /// For an animal filter it is `mayBe`, not equality (task 11.251): a
  /// moment two deployments both cover is **contested** rather than
  /// resolved, and a contested record is listed under every animal it might
  /// belong to. "Show me Marie" showing a bearing that might be Marie's is
  /// the honest answer; dropping it from both animals' lists would be the
  /// silent loss the derivation was changed to stop.
  bool admits({required String? tagId, required DateTime at}) {
    if (tagId == null) return false;
    final animal = individualId;
    if (animal == null) return ids.contains(tagId);
    return DeploymentRepository.animalForObservationIn(
      deployments,
      tagId: tagId,
      at: at,
    ).mayBe(animal);
  }
}

/// **A row's animal name and swatch colour — the moment, never the collar's
/// current owner** (task 11.272, the third instance of the filter-fixed
/// colour-not-fixed pattern this app's rule names: 11.247/11.248 on the Map,
/// then this screen). Asks the same load-bearing derivation the filter above
/// already uses, `animalForObservationIn`, rather than adding a seventh one
/// (task 11.251 counted six and unified them).
///
/// **Mirrors `map_screen.dart`'s `_attributionOf`** for the two cases that
/// must render identically on both screens: a moment two deployments both
/// cover is *contested* (design §4a) and draws the neutral swatch, labelled
/// with [contestedLegendLabel] — the exact sentence the Map's legend uses, so
/// the two screens can never disagree in wording either; a moment no live
/// deployment covers belongs to nobody and says so rather than leaving the
/// row blank, which would read as a rendering fault.
///
/// **Unlike the Map's legend, a sole candidate that names a since-tombstoned
/// animal is still named here** — [individuals] is expected to be
/// `_HistoryData.allIndividuals`, which task 11.258's doc comment on
/// `animalForObservationIn` says is exactly this caller's job: the question
/// is a fact about the moment the bearing was taken, and deleting the animal
/// afterwards does not unmake it. A candidate this device holds no row for at
/// all (a partial sync, never a state this app's own writers can produce) is
/// the one case with no name to give, and that reads as a deleted animal too
/// — there is nothing else honest to call it.
(String label, String colorHex) _animalAttributionFor(
  String tagId,
  DateTime at,
  List<Individual> individuals,
  List<Deployment> deployments,
) {
  final attribution = DeploymentRepository.animalForObservationIn(
    deployments,
    tagId: tagId,
    at: at,
  );
  Individual? byId(String id) {
    for (final a in individuals) {
      if (a.individualId == id) return a;
    }
    return null;
  }

  final sole = attribution.sole;
  if (sole != null) {
    final animal = byId(sole);
    return animal == null
        ? ('a deleted animal', TagColorPalette.noIndividual)
        : (animal.name, animal.colorHex);
  }
  if (attribution.isContested) {
    final names = [
      for (final id in attribution.candidates) byId(id)?.name ?? 'a deleted animal',
    ]..sort();
    return (contestedLegendLabel(names), TagColorPalette.noIndividual);
  }
  return (_noAnimalAtThisMomentLabel, TagColorPalette.noIndividual);
}

/// What a row says when no live deployment covers its own moment — a collar
/// in the box, or one that fell off and kept transmitting (design §2). Named
/// rather than left blank: a blank space on a row reads as a rendering
/// fault, not as an honest answer.
const _noAnimalAtThisMomentLabel = 'No animal at this time';

class _HistoryBody extends ConsumerStatefulWidget {
  const _HistoryBody({required this.project});
  final Project project;

  @override
  ConsumerState<_HistoryBody> createState() => _HistoryBodyState();
}

class _HistoryBodyState extends ConsumerState<_HistoryBody>
    with _LogEntryActionsMixin<_HistoryBody>, _ObservationMarkActionsMixin<_HistoryBody> {
  _HistoryFilters _filters = const _HistoryFilters();
  _LogSort _sort = _LogSort.time;

  @override
  String get logProjectId => widget.project.projectId;

  @override
  Widget build(BuildContext context) {
    final dataAsync = ref.watch(historyDataProvider(widget.project.projectId));
    final currentUserAsync = ref.watch(currentUserProvider);
    final gps = ref.watch(gpsPositionProvider).value;
    // Task 11.12: whether the role gradient (not just authorship) permits
    // editing/deleting here — see `authorEditVerdict`. The standing rather
    // than the bare bool since task 11.237, because *why* a write is refused
    // decides which sentence is true: a viewer's, or a snapshot's.
    final standingAsync = ref.watch(myProjectStandingProvider(widget.project.projectId));
    // Task 11.7: excluding is owner-only, superseding is not. Both controls
    // need the answer before they render — see `exclusionVerdict`.
    final isOwner =
        ref.watch(isProjectOwnerProvider(widget.project.projectId)).value ?? false;

    return dataAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => LoadFailure("this project's records", error: e),
      data: (data) => standingAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) =>
            LoadFailure('what you are allowed to do here', error: e),
        data: (standing) {
          final currentUser = currentUserAsync.value;
          final entries = <_LogEntry>[
            for (final o in data.observations) _LogEntry.observation(o),
            for (final nd in data.nonDetections) _LogEntry.nonDetection(nd),
            for (final t in data.truthPoints) _LogEntry.truthPoint(t),
          ].where(_filters.matches).toList();
          // Task 11.92, narrowed by 11.93: an observer filter used to hide
          // every truth point, because the table recorded no observer. It now
          // hides only the points written before that column existed. Said out
          // loud rather than left as an unexplained absence.
          final hiddenTruthPoints =
              _filters.unattributedTruthPointsHidden(data.truthPoints);
          double? distanceMeters(_LogEntry e) => gps == null
              ? null
              : distanceAndBearing(
                  GeoPoint(gps.latitude, gps.longitude),
                  GeoPoint(e.latitude, e.longitude),
                ).distanceMeters;
          _sortEntries(
            entries,
            data.tags,
            data.allIndividuals,
            data.deployments,
            distanceMeters,
          );

          return Column(
            children: [
              _FilterBar(
                filters: _filters,
                tags: data.tags,
                individuals: data.individuals,
                collarsByAnimal: data.collarsByAnimal,
                deployments: data.deployments,
                users: data.users,
                onChanged: (f) => setState(() => _filters = f),
              ),
              _SortBar(
                sort: _sort,
                distanceEnabled: gps != null,
                onChanged: (s) => setState(() => _sort = s),
              ),
              if (hiddenTruthPoints > 0)
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: DesignTokens.spacingScreenHorizontal,
                    vertical: 2,
                  ),
                  child: Text(
                    '$hiddenTruthPoints truth '
                    '${hiddenTruthPoints == 1 ? 'point is' : 'points are'} '
                    'hidden: recorded before this app stored who found a '
                    'point, so filtering by observer leaves '
                    '${hiddenTruthPoints == 1 ? 'it' : 'them'} out.',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                  ),
                ),
              Expanded(
                child: entries.isEmpty
                    ? const Center(child: Text('No records match these filters.'))
                    : ListView.separated(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        itemCount: entries.length,
                        separatorBuilder: (_, _) => const Divider(height: 1),
                        itemBuilder: (context, i) {
                          final e = entries[i];
                          final truth = e.truthPoint;
                          if (truth != null) {
                            final truthVerdict = truthPointEditVerdict(
                              standing: standing,
                            );
                            final (animalLabel, animalColorHex) = _animalAttributionFor(
                              truth.tagId,
                              truth.timestampLocal,
                              data.allIndividuals,
                              data.deployments,
                            );
                            return _TruthPointTile(
                              truthPoint: truth,
                              tag: data.tags[truth.tagId],
                              finder: data.users[truth.userId],
                              distanceMeters: distanceMeters(e),
                              animalLabel: animalLabel,
                              animalColorHex: animalColorHex,
                              canEdit: truthVerdict.canEdit,
                              disabledReason: truthVerdict.reason,
                              onEdit: () => editTruthPoint(context, truth),
                              onDelete: () => deleteTruthPoint(context, truth),
                            );
                          }
                          final nd = e.nonDetection;
                          if (nd != null) {
                            final ndVerdict = nonDetectionEditVerdict(
                              standing: standing,
                              actorUserId: currentUser?.userId,
                              rowUserId: nd.userId,
                            );
                            return _NonDetectionTile(
                              nonDetection: nd,
                              tags: data.tags,
                              individuals: data.allIndividuals,
                              deployments: data.deployments,
                              observer: data.users[nd.userId],
                              distanceMeters: distanceMeters(e),
                              canEdit: ndVerdict.canEdit,
                              disabledReason: ndVerdict.reason,
                              onDelete: () => deleteNonDetection(context, nd),
                            );
                          }
                          final o = e.observation!;
                          final verdict = authorEditVerdict(
                            standing: standing,
                            actorUserId: currentUser?.userId,
                            rowUserId: o.userId,
                          );
                          final mark = data.marks[o.observationId];
                          final marking = exclusionVerdict(
                            standing: standing,
                            isOwner: isOwner,
                          );
                          // Task 11.15: withdrawing is not "whatever making
                          // the mark needed" — it also depends on *whose* mark
                          // it is, which the menu had no way to know.
                          final withdrawal = mark == null
                              ? null
                              : withdrawMarkVerdict(
                                  standing: standing,
                                  isOwner: isOwner,
                                  actorUserId: currentUser?.userId,
                                  markUserId: mark.userId,
                                  markKind: mark.kind,
                                );
                          // Task 11.18: independent of the live mark above —
                          // an observation can have both a current mark and a
                          // past one that was withdrawn.
                          final withdrawnMark =
                              data.withdrawnMarks[o.observationId];
                          final oTagId = o.tagId;
                          final oAttribution = oTagId == null
                              ? null
                              : _animalAttributionFor(
                                  oTagId,
                                  o.timestampLocal,
                                  data.allIndividuals,
                                  data.deployments,
                                );
                          return _ObservationTile(
                            observation: o,
                            tag: o.tagId == null ? null : data.tags[o.tagId],
                            observer: data.users[o.userId],
                            distanceMeters: distanceMeters(e),
                            animalLabel: oAttribution?.$1,
                            animalColorHex: oAttribution?.$2,
                            canEdit: verdict.canEdit,
                            disabledReason: verdict.reason,
                            onEdit: () => editLogEntryNotes(context, o),
                            onShare: () => shareLogEntry(context, o, data),
                            onDelete: () => deleteLogEntry(context, o),
                            mark: mark,
                            markedBy: mark == null
                                ? null
                                : data.users[mark.userId],
                            withdrawnMark: withdrawnMark,
                            withdrawnMarkedBy: withdrawnMark == null
                                ? null
                                : data.users[withdrawnMark.userId],
                            withdrawnBy: withdrawnMark?.sync.lastModifiedBy == null
                                ? null
                                : data.users[withdrawnMark!.sync.lastModifiedBy!],
                            canSupersede: marking.canSupersede,
                            supersedeReason: marking.supersedeReason,
                            canExclude: marking.canExclude,
                            excludeReason: marking.excludeReason,
                            onSupersede: () =>
                                supersedeLogEntry(context, o, data),
                            onExclude: () => excludeLogEntry(context, o),
                            canRestore: withdrawal?.canWithdraw ?? false,
                            restoreReason: withdrawal?.reason,
                            onRestoreToEstimates: () =>
                                restoreToEstimates(context, mark!),
                          );
                        },
                      ),
              ),
            ],
          );
        },
      ),
    );
  }

  /// Sorts [observations] in place per [_sort]. Distance sort falls back to
  /// leaving unsorted-by-distance observations (no GPS fix) at the end
  /// rather than crashing or silently mis-ordering them.
  void _sortEntries(
    List<_LogEntry> entries,
    Map<String, Tag> tags,
    List<Individual> allIndividuals,
    List<Deployment> deployments,
    double? Function(_LogEntry) distanceMeters,
  ) {
    // A single-tag key for tag/frequency sorts; entries without one exact tag
    // (non-detections, tagless notes) sort to the end. A truth point always
    // names exactly one tag, so it sorts with the bearings rather than to the
    // end (task 11.92).
    Tag? soleTag(_LogEntry e) {
      final id = e.soleTagId;
      return id == null ? null : tags[id];
    }

    switch (_sort) {
      case _LogSort.time:
        entries.sort((a, b) => b.time.compareTo(a.time));
      case _LogSort.tagName:
        entries.sort((a, b) => (soleTag(a)?.tagName ?? '~')
            .compareTo(soleTag(b)?.tagName ?? '~'));
      case _LogSort.frequency:
        entries.sort((a, b) => (soleTag(a)?.frequencyMhz ?? double.infinity)
            .compareTo(soleTag(b)?.frequencyMhz ?? double.infinity));
      case _LogSort.distance:
        entries.sort((a, b) {
          final da = distanceMeters(a);
          final db = distanceMeters(b);
          if (da == null && db == null) return 0;
          if (da == null) return 1;
          if (db == null) return -1;
          return da.compareTo(db);
        });
      case _LogSort.animal:
        entries.sort((a, b) => _animalSortKey(a, allIndividuals, deployments)
            .compareTo(_animalSortKey(b, allIndividuals, deployments)));
    }
  }

}

/// The key [_LogSort.animal]/`_TeamSort.animal` sort by — a plain animal
/// name where the row's own moment resolves to exactly one, and `~` (sorting
/// last, matching the tag/frequency sorts' own fallback) for anything a
/// person could not alphabetise honestly: no tag at all, nobody covering the
/// moment, or a contested one with more than one candidate. **This is a
/// different question from the row's displayed label**, which says
/// [_noAnimalAtThisMomentLabel] or names every contested candidate rather
/// than falling silent — sorting those next to real names would scatter them
/// through the list instead of collecting them at the end, where "nothing
/// crisp to sort by" belongs.
String _animalSortKey(
  _LogEntry e,
  List<Individual> allIndividuals,
  List<Deployment> deployments,
) {
  final id = e.soleTagId;
  if (id == null) return '~';
  final sole = DeploymentRepository.animalForObservationIn(
    deployments,
    tagId: id,
    at: e.time,
  ).sole;
  if (sole == null) return '~';
  for (final a in allIndividuals) {
    if (a.individualId == sole) return a.name;
  }
  return '~';
}

/// Share/edit/delete on a single log entry — identical for the personal Log
/// tab and the Team tab, so both `_HistoryBodyState` and `_TeamBodyState`
/// mix this in rather than each carrying their own copy.
mixin _LogEntryActionsMixin<T extends ConsumerStatefulWidget> on ConsumerState<T> {
  String get logProjectId;

  Future<void> shareLogEntry(BuildContext context, Observation o, _HistoryData data) async {
    final tag = data.tags[o.tagId];
    final observer = data.users[o.userId];
    if (tag == null || observer == null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Missing tag or observer info.')));
      return;
    }
    // Task 11.137: `refused: null` — sharing reads a record out and writes
    // nothing, so no permission governs it and a refusal here would be a bug.
    final copied = await runGuardedWrite(
      context,
      write: () async {
        final tagVersionRepo = await ref.read(tagVersionRepositoryProvider.future);
        final payload = await buildTriTrackClipboardPayload(
          tagVersionRepo: tagVersionRepo,
          observation: o,
          tag: tag,
          observer: observer,
        );
        await Clipboard.setData(ClipboardData(text: payload));
      },
      refused: null,
      failed: 'Could not copy this observation. Try again, and report it if '
          'this keeps happening.',
    );
    if (!copied || !context.mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('Copied — paste into any messaging app')));
  }

  /// Task 11.92: correct a truth point's precision or what was found. The
  /// precision is the field that gets corrected — it is prefilled from the
  /// device's GPS accuracy — so the dialog opens focused on it.
  Future<void> editTruthPoint(BuildContext context, ActualTagLocation t) async {
    final updated = await showEditTruthPointDialog(context, ref, t);
    if (updated == null || !mounted) return;
    ref.invalidate(historyDataProvider(logProjectId));
  }

  /// Task 11.92: delete a truth point — confirm, tombstone, offer an undo. The
  /// whole of that behaviour lives in [confirmAndDeleteTruthPoint] so the map's
  /// info panel and this list cannot come to warn about different things.
  Future<void> deleteTruthPoint(BuildContext context, ActualTagLocation t) async {
    await confirmAndDeleteTruthPoint(
      context,
      ref,
      t,
      onChanged: () {
        if (mounted) ref.invalidate(historyDataProvider(logProjectId));
      },
    );
  }

  Future<void> editLogEntryNotes(BuildContext context, Observation o) async {
    final updated = await showEditObservationDialog(context, ref, o);
    if (updated == null || !mounted) return;
    ref.invalidate(historyDataProvider(logProjectId));
  }

  /// Destructive-action confirm + undo (design doc's Interaction Patterns
  /// Summary: "Destructive actions... require confirm + undo"). The confirm
  /// dialog guards against a misclick; the post-delete SnackBar undo (backed
  /// by the soft-delete tombstone — [restoreById] just clears it) guards
  /// against a change of mind seconds later. Deliberately gated to the same
  /// `canEdit` (own-observations-only) rule as editing, for consistency.
  Future<void> deleteLogEntry(BuildContext context, Observation o) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete this observation?'),
        content: const Text('You can undo this from the confirmation that follows.'),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('Delete')),
        ],
      ),
    );
    // Guard every subsequent `ref`/`context` use: the dialog await can span
    // an arbitrarily long real-world gap (backgrounding the app, navigating
    // away), and `ref` throws — not just a silent no-op — if this State has
    // been disposed by the time it resolves.
    if (confirmed != true || !mounted) return;

    final user = await ref.read(currentUserProvider.future);
    if (!mounted) return;
    final deviceId = await ref.read(deviceIdProvider.future);
    if (!mounted) return;
    final repo = await ref.read(observationRepositoryProvider.future);
    if (!context.mounted) return;
    final deleted = await runGuardedWrite(
      context,
      write: () => repo.softDelete(o,
          actor: MutationActor.user(user.userId), deviceId: deviceId),
      refused: 'You can only delete an observation you recorded yourself. For '
          'somebody else\'s, a project owner can take it out of estimates '
          'instead.',
      failed: 'Could not delete this observation; it is still in the Log. Try '
          'again, and report it if this keeps happening.',
    );
    if (!deleted || !mounted) return;
    ref.invalidate(historyDataProvider(logProjectId));
    ref.read(recordingsRevisionProvider.notifier).bump();

    if (!context.mounted) return;
    // Clear any still-showing snackbar first — otherwise deleting a second
    // observation shortly after the first queues its undo bar behind the
    // first instead of replacing it.
    ScaffoldMessenger.of(context).clearSnackBars();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: const Text('Observation deleted'),
        duration: const Duration(seconds: 6),
        // Task 11.42: an action makes this default to `persist: true`
        // (Material 3), which leaves `duration` dead — see
        // `projects_screen.dart`'s delete-project undo bar for the finding.
        persist: false,
        action: SnackBarAction(
          label: 'UNDO',
          onPressed: () async {
            if (!context.mounted) return;
            final restored = await runGuardedWrite(
              context,
              write: () => repo.restore(o,
                  actor: MutationActor.user(user.userId), deviceId: deviceId),
              refused: 'You may no longer change this observation, so it '
                  'could not be brought back. Ask a project owner.',
              failed: 'Could not bring this observation back; it is still '
                  'deleted. Try again, and report it if this keeps happening.',
            );
            if (!restored || !mounted) return;
            ref.invalidate(historyDataProvider(logProjectId));
            ref.read(recordingsRevisionProvider.notifier).bump();
          },
        ),
      ),
    );
  }

  /// Delete a "no signal" record (task 11.252). Same confirm + tombstone +
  /// undo shape as [deleteLogEntry] — soft delete, syncable, reversible from
  /// the SnackBar — because a "no signal" is a [NonDetectionRepository] row
  /// under the same `MutationRule.author` rule an observation is, and two
  /// destructive controls on this screen behaving differently would be worse
  /// than the missing one Michael found.
  ///
  /// The confirmation names what disappears — how many tags were listened for
  /// — rather than a bare "delete this entry?", because a "no signal" record
  /// names several collars at once and the plain-English rule this project's
  /// reports already follow ("say what breaks for a person") applies to a
  /// confirmation dialog as much as to a report.
  Future<void> deleteNonDetection(BuildContext context, NonDetection nd) async {
    final count = nd.tagIdsListenedFor.length;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete this "no signal" record?'),
        content: Text(
          'This removes the record that you listened for $count '
          '${count == 1 ? 'collar' : 'collars'} and heard nothing. You can '
          'undo it straight after.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('Delete')),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    final user = await ref.read(currentUserProvider.future);
    if (!mounted) return;
    final deviceId = await ref.read(deviceIdProvider.future);
    if (!mounted) return;
    final repo = await ref.read(nonDetectionRepositoryProvider.future);
    if (!context.mounted) return;
    final deleted = await runGuardedWrite(
      context,
      write: () => repo.softDelete(nd,
          actor: MutationActor.user(user.userId), deviceId: deviceId),
      refused: 'You can only delete a "no signal" record you recorded '
          'yourself. This one is somebody else\'s.',
      failed: 'Could not delete this "no signal" record; it is still in the '
          'Log. Try again, and report it if this keeps happening.',
    );
    if (!deleted || !mounted) return;
    ref.invalidate(historyDataProvider(logProjectId));
    ref.read(recordingsRevisionProvider.notifier).bump();

    if (!context.mounted) return;
    ScaffoldMessenger.of(context).clearSnackBars();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: const Text('"No signal" record deleted'),
        duration: const Duration(seconds: 6),
        persist: false,
        action: SnackBarAction(
          label: 'UNDO',
          onPressed: () async {
            if (!context.mounted) return;
            final restored = await runGuardedWrite(
              context,
              write: () => repo.restore(nd,
                  actor: MutationActor.user(user.userId), deviceId: deviceId),
              refused: 'You may no longer change this record, so it could '
                  'not be brought back. Ask a project owner.',
              failed: 'Could not bring this record back; it is still '
                  'deleted. Try again, and report it if this keeps '
                  'happening.',
            );
            if (!restored || !mounted) return;
            ref.invalidate(historyDataProvider(logProjectId));
            ref.read(recordingsRevisionProvider.notifier).bump();
          },
        ),
      ),
    );
  }
}


/// Task 11.7's supersede/exclude actions, shared by the Log and Team tabs.
///
/// **None of these ever writes the observation row.** Superseding and
/// excluding both insert (or tombstone) an `Observation_Exclusions` row
/// authored by the person doing it; the observation's `user_id`,
/// `last_modified_by` and every measurement column are left exactly as its
/// author recorded them. That is the invariant Phases 6 and 8 exist to protect
/// and the reason this feature is not simply "let owners edit the row" — see
/// `Tables.observationExclusions`.
mixin _ObservationMarkActionsMixin<T extends ConsumerStatefulWidget>
    on ConsumerState<T> {
  String get logProjectId;

  Future<void> _writeMark(
    BuildContext context,
    ObservationExclusionKind kind,
    Observation o,
    String? replacementId,
    String? reason,
  ) async {
    final user = await ref.read(currentUserProvider.future);
    if (!mounted) return;
    final deviceId = await ref.read(deviceIdProvider.future);
    if (!mounted) return;
    final repo = await ref.read(observationExclusionRepositoryProvider.future);
    if (!mounted) return;
    final now = DateTime.now();
    final superseding = kind == ObservationExclusionKind.superseded;
    if (!context.mounted) return;
    final wrote = await runGuardedWrite(
      context,
      write: () => repo.insert(
        ObservationExclusion(
          exclusionId: const Uuid().v4(),
          projectId: o.projectId,
          observationId: o.observationId,
          userId: user.userId,
          kind: kind,
          supersededByObservationId: replacementId,
          reason: reason,
          sync: SyncMeta.initial(
            now: now,
            modifiedBy: user.userId,
            originDeviceId: deviceId,
          ),
        ),
      ),
      refused: superseding
          ? 'You may not supersede this bearing: your own needs a contributor '
              'role, and somebody else\'s needs an owner. Ask a project owner.'
          : 'Only a project owner can exclude a bearing from estimates. If it '
              'is your own, supersede it with a better one instead.',
      failed: superseding
          ? 'Could not supersede this bearing; it still counts toward '
              'estimates. Try again, and report it if this keeps happening.'
          : 'Could not exclude this bearing; it still counts toward '
              'estimates. Try again, and report it if this keeps happening.',
    );
    if (!wrote || !mounted) return;
    ref.invalidate(historyDataProvider(logProjectId));
    ref.read(recordingsRevisionProvider.notifier).bump();
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).clearSnackBars();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          kind == ObservationExclusionKind.superseded
              ? 'Superseded — this bearing no longer counts toward estimates'
              : 'Excluded — this bearing no longer counts toward estimates',
        ),
      ),
    );
  }

  /// Marks [o] as replaced by another record of the same event. The
  /// replacement is picked from the project's other observations rather than
  /// recorded here: the two-people-one-observation case the plan names is
  /// exactly the one where the better record already exists, and belongs to
  /// somebody else.
  Future<void> supersedeLogEntry(
    BuildContext context,
    Observation o,
    _HistoryData data,
  ) async {
    final choice = await showDialog<(String, String?)>(
      context: context,
      builder: (context) => _SupersedeDialog(observation: o, data: data),
    );
    if (choice == null || !mounted || !context.mounted) return;
    await _writeMark(
      context,
      ObservationExclusionKind.superseded,
      o,
      choice.$1,
      choice.$2,
    );
  }

  /// Takes [o] out of position estimation with no replacement — the owner-only
  /// data-quality action.
  Future<void> excludeLogEntry(BuildContext context, Observation o) async {
    final reason = await showDialog<String?>(
      context: context,
      builder: (context) => const _ExcludeDialog(),
    );
    if (reason == null || !mounted || !context.mounted) return;
    await _writeMark(
      context,
      ObservationExclusionKind.excluded,
      o,
      null,
      reason.isEmpty ? null : reason,
    );
  }

  /// Undoes a supersede or an exclusion by tombstoning the mark, so the
  /// reversal merges to other devices instead of resurrecting on the next
  /// sync. Reversibility is 11.7's explicit requirement for exclusion; it
  /// costs nothing to give supersede the same treatment, and a correction
  /// somebody made in error should not be permanent either.
  Future<void> restoreToEstimates(
    BuildContext context,
    ObservationExclusion mark,
  ) async {
    final user = await ref.read(currentUserProvider.future);
    if (!mounted) return;
    final deviceId = await ref.read(deviceIdProvider.future);
    if (!mounted) return;
    final repo = await ref.read(observationExclusionRepositoryProvider.future);
    if (!mounted) return;
    if (!context.mounted) return;
    final withdrew = await runGuardedWrite(
      context,
      write: () => repo.withdraw(
        mark,
        actor: MutationActor.user(user.userId),
        deviceId: deviceId,
      ),
      refused: 'Only the person who made this mark, or a project owner, can '
          'undo it.',
      failed: 'Could not undo this mark; the bearing is still out of '
          'estimates. Try again, and report it if this keeps happening.',
    );
    if (!withdrew || !mounted) return;
    ref.invalidate(historyDataProvider(logProjectId));
    ref.read(recordingsRevisionProvider.notifier).bump();
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).clearSnackBars();
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Restored — this bearing counts again')),
    );
  }
}

/// Picks the record that replaces the one being superseded.
///
/// Candidates are the project's other observations of the same tag that are
/// not themselves out of analysis. Anyone's — superseding a colleague's
/// bearing with your own, or your own with theirs, are both ordinary.
class _SupersedeDialog extends StatefulWidget {
  const _SupersedeDialog({required this.observation, required this.data});

  final Observation observation;
  final _HistoryData data;

  @override
  State<_SupersedeDialog> createState() => _SupersedeDialogState();
}

class _SupersedeDialogState extends State<_SupersedeDialog> {
  String? _replacementId;
  final _reason = TextEditingController();

  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final o = widget.observation;
    final candidates = [
      for (final c in widget.data.observations)
        if (c.observationId != o.observationId &&
            c.tagId == o.tagId &&
            !widget.data.marks.containsKey(c.observationId))
          c,
    ];
    return AlertDialog(
      title: const Text('Superseded by which record?'),
      content: SizedBox(
        width: 420,
        child: candidates.isEmpty
            ? const Text(
                'There is no other record of this tag to point at. Record the '
                'corrected observation first, then supersede this one.',
              )
            : Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text(
                    'The original is kept as recorded. Only the replacement '
                    'counts in position estimates.',
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String>(
                    initialValue: _replacementId,
                    isExpanded: true,
                    decoration: const InputDecoration(labelText: 'Replacement'),
                    items: [
                      for (final c in candidates)
                        DropdownMenuItem(
                          value: c.observationId,
                          child: _CandidateRow(c, widget.data),
                        ),
                    ],
                    onChanged: (v) => setState(() => _replacementId = v),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _reason,
                    decoration: const InputDecoration(
                      labelText: 'Reason (optional)',
                      hintText: 'e.g. bearing re-read from the field sheet',
                    ),
                  ),
                ],
              ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _replacementId == null
              ? null
              : () => Navigator.of(context).pop((
                  _replacementId!,
                  _reason.text.trim().isEmpty ? null : _reason.text.trim(),
                )),
          child: const Text('Supersede'),
        ),
      ],
    );
  }
}

/// A supersede candidate, as `<when> · <who> · <bearing or record type>` —
/// but laid out so only the first two fields ellipsise.
///
/// Task 11.211: a single `Text(..., overflow: ellipsis)` truncated from the
/// right, so on the smallest phone this app supports the third field — the
/// one thing that actually tells two candidates by the same observer apart —
/// was cut before the observer's name was. The date is the least identifying
/// of the three and the most predictable to read truncated, so it is what
/// shrinks: `<when> · <who>` sits in an [Expanded] that ellipsises, and the
/// distinguishing field is appended unconstrained, after it, so it is never
/// the one that goes missing.
class _CandidateRow extends StatelessWidget {
  const _CandidateRow(this.observation, this.data);

  final Observation observation;
  final _HistoryData data;

  @override
  Widget build(BuildContext context) {
    final observer = data.users[observation.userId];
    final who = observer == null
        ? observation.userId
        : '${observer.firstName} ${observer.lastName}';
    final when = observation.timestampLocal.toLocal().toString().substring(0, 16);
    final distinguishing = observation.trueNorthBearing == null
        ? quality.observationTypeLabel(observation.observationType)
        : '${observation.trueNorthBearing!.toStringAsFixed(0)}°';
    return Row(
      children: [
        Expanded(
          child: Text('$when · $who', maxLines: 1, overflow: TextOverflow.ellipsis),
        ),
        Text(' · $distinguishing'),
      ],
    );
  }
}

/// Confirms an owner-only exclusion, with an optional reason. The reason is
/// shown on the row afterwards: a data-quality decision nobody can account for
/// later is a provenance hole of its own.
class _ExcludeDialog extends StatefulWidget {
  const _ExcludeDialog();

  @override
  State<_ExcludeDialog> createState() => _ExcludeDialogState();
}

class _ExcludeDialogState extends State<_ExcludeDialog> {
  final _reason = TextEditingController();

  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Exclude from position estimates?'),
    content: SizedBox(
      width: 420,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            'The observation stays in the Log as recorded, but stops counting '
            "toward this tag's position. You can undo this at any time.",
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _reason,
            decoration: const InputDecoration(
              labelText: 'Reason (optional)',
              hintText: 'e.g. suspected bounce off the ridge',
            ),
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: () => Navigator.of(context).pop(_reason.text.trim()),
        child: const Text('Exclude'),
      ),
    ],
  );
}

enum _TeamSort { member, tagName, time, distance, animal }

/// The Team tab: the same project-wide observations the personal Log tab
/// already shows (every member's rows, via Phase 6 replica import), sorted
/// by member/tag/time/distance instead of the personal tab's
/// time/tag/frequency/distance. Reuses `_HistoryFilters`/`_FilterBar`, the
/// same tiles, and `_LogEntryActionsMixin` for edit/share/delete — only the
/// sort logic and sort bar are Team-specific.
class _TeamBody extends ConsumerStatefulWidget {
  const _TeamBody({required this.project});
  final Project project;

  @override
  ConsumerState<_TeamBody> createState() => _TeamBodyState();
}

class _TeamBodyState extends ConsumerState<_TeamBody>
    with _LogEntryActionsMixin<_TeamBody>, _ObservationMarkActionsMixin<_TeamBody> {
  _HistoryFilters _filters = const _HistoryFilters();
  _TeamSort _sort = _TeamSort.time;

  @override
  String get logProjectId => widget.project.projectId;

  @override
  Widget build(BuildContext context) {
    final dataAsync = ref.watch(historyDataProvider(widget.project.projectId));
    final currentUserAsync = ref.watch(currentUserProvider);
    final gps = ref.watch(gpsPositionProvider).value;
    final distanceAvailable = gps != null;
    // Task 11.12: whether the role gradient (not just authorship) permits
    // editing/deleting here — see `authorEditVerdict`. The standing rather
    // than the bare bool since task 11.237, because *why* a write is refused
    // decides which sentence is true: a viewer's, or a snapshot's.
    final standingAsync = ref.watch(myProjectStandingProvider(widget.project.projectId));
    // Task 11.7: excluding is owner-only, superseding is not. Both controls
    // need the answer before they render — see `exclusionVerdict`.
    final isOwner =
        ref.watch(isProjectOwnerProvider(widget.project.projectId)).value ?? false;

    return dataAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => LoadFailure("this project's records", error: e),
      data: (data) => standingAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) =>
            LoadFailure('what you are allowed to do here', error: e),
        data: (standing) {
          final currentUser = currentUserAsync.value;
          final entries = <_LogEntry>[
            for (final o in data.observations) _LogEntry.observation(o),
            for (final nd in data.nonDetections) _LogEntry.nonDetection(nd),
            for (final t in data.truthPoints) _LogEntry.truthPoint(t),
          ].where(_filters.matches).toList();
          // Task 11.92, narrowed by 11.93: an observer filter used to hide
          // every truth point, because the table recorded no observer. It now
          // hides only the points written before that column existed. Said out
          // loud rather than left as an unexplained absence.
          final hiddenTruthPoints =
              _filters.unattributedTruthPointsHidden(data.truthPoints);
          double? distanceMeters(_LogEntry e) => gps == null
              ? null
              : distanceAndBearing(
                  GeoPoint(gps.latitude, gps.longitude),
                  GeoPoint(e.latitude, e.longitude),
                ).distanceMeters;

          // Distance sort must never silently reorder by something else when
          // there is no GPS fix — that would look sorted while lying about
          // what it was sorted by. Fall back to a clearly-labelled time order
          // instead, and say so.
          final usingDistanceFallback = _sort == _TeamSort.distance && !distanceAvailable;
          _sortTeamEntries(
            entries,
            data.tags,
            data.users,
            data.allIndividuals,
            data.deployments,
            distanceMeters,
            usingDistanceFallback ? _TeamSort.time : _sort,
          );

          return Column(
            children: [
              _FilterBar(
                filters: _filters,
                tags: data.tags,
                individuals: data.individuals,
                collarsByAnimal: data.collarsByAnimal,
                deployments: data.deployments,
                users: data.users,
                onChanged: (f) => setState(() => _filters = f),
              ),
              _TeamSortBar(
                sort: _sort,
                distanceEnabled: distanceAvailable,
                onChanged: (s) => setState(() => _sort = s),
              ),
              if (usingDistanceFallback)
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: DesignTokens.spacingScreenHorizontal,
                    vertical: 2,
                  ),
                  child: Text(
                    'No GPS fix — distance unavailable, showing time order instead.',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                  ),
                ),
              if (hiddenTruthPoints > 0)
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: DesignTokens.spacingScreenHorizontal,
                    vertical: 2,
                  ),
                  child: Text(
                    '$hiddenTruthPoints truth '
                    '${hiddenTruthPoints == 1 ? 'point is' : 'points are'} '
                    'hidden: recorded before this app stored who found a '
                    'point, so filtering by observer leaves '
                    '${hiddenTruthPoints == 1 ? 'it' : 'them'} out.',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                  ),
                ),
              Expanded(
                child: entries.isEmpty
                    ? const Center(child: Text('No records match these filters.'))
                    : ListView.separated(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        itemCount: entries.length,
                        separatorBuilder: (_, _) => const Divider(height: 1),
                        itemBuilder: (context, i) {
                          final e = entries[i];
                          final truth = e.truthPoint;
                          if (truth != null) {
                            final truthVerdict = truthPointEditVerdict(
                              standing: standing,
                            );
                            final (animalLabel, animalColorHex) = _animalAttributionFor(
                              truth.tagId,
                              truth.timestampLocal,
                              data.allIndividuals,
                              data.deployments,
                            );
                            return _TruthPointTile(
                              truthPoint: truth,
                              tag: data.tags[truth.tagId],
                              finder: data.users[truth.userId],
                              distanceMeters: distanceMeters(e),
                              animalLabel: animalLabel,
                              animalColorHex: animalColorHex,
                              canEdit: truthVerdict.canEdit,
                              disabledReason: truthVerdict.reason,
                              onEdit: () => editTruthPoint(context, truth),
                              onDelete: () => deleteTruthPoint(context, truth),
                            );
                          }
                          final nd = e.nonDetection;
                          if (nd != null) {
                            final ndVerdict = nonDetectionEditVerdict(
                              standing: standing,
                              actorUserId: currentUser?.userId,
                              rowUserId: nd.userId,
                            );
                            return _NonDetectionTile(
                              nonDetection: nd,
                              tags: data.tags,
                              individuals: data.allIndividuals,
                              deployments: data.deployments,
                              observer: data.users[nd.userId],
                              distanceMeters: distanceMeters(e),
                              canEdit: ndVerdict.canEdit,
                              disabledReason: ndVerdict.reason,
                              onDelete: () => deleteNonDetection(context, nd),
                            );
                          }
                          final o = e.observation!;
                          final verdict = authorEditVerdict(
                            standing: standing,
                            actorUserId: currentUser?.userId,
                            rowUserId: o.userId,
                          );
                          final mark = data.marks[o.observationId];
                          final marking = exclusionVerdict(
                            standing: standing,
                            isOwner: isOwner,
                          );
                          // Task 11.15: withdrawing is not "whatever making
                          // the mark needed" — it also depends on *whose* mark
                          // it is, which the menu had no way to know.
                          final withdrawal = mark == null
                              ? null
                              : withdrawMarkVerdict(
                                  standing: standing,
                                  isOwner: isOwner,
                                  actorUserId: currentUser?.userId,
                                  markUserId: mark.userId,
                                  markKind: mark.kind,
                                );
                          // Task 11.18: independent of the live mark above —
                          // an observation can have both a current mark and a
                          // past one that was withdrawn.
                          final withdrawnMark =
                              data.withdrawnMarks[o.observationId];
                          final oTagId = o.tagId;
                          final oAttribution = oTagId == null
                              ? null
                              : _animalAttributionFor(
                                  oTagId,
                                  o.timestampLocal,
                                  data.allIndividuals,
                                  data.deployments,
                                );
                          return _ObservationTile(
                            observation: o,
                            tag: o.tagId == null ? null : data.tags[o.tagId],
                            observer: data.users[o.userId],
                            distanceMeters: distanceMeters(e),
                            animalLabel: oAttribution?.$1,
                            animalColorHex: oAttribution?.$2,
                            canEdit: verdict.canEdit,
                            disabledReason: verdict.reason,
                            onEdit: () => editLogEntryNotes(context, o),
                            onShare: () => shareLogEntry(context, o, data),
                            onDelete: () => deleteLogEntry(context, o),
                            mark: mark,
                            markedBy: mark == null
                                ? null
                                : data.users[mark.userId],
                            withdrawnMark: withdrawnMark,
                            withdrawnMarkedBy: withdrawnMark == null
                                ? null
                                : data.users[withdrawnMark.userId],
                            withdrawnBy: withdrawnMark?.sync.lastModifiedBy == null
                                ? null
                                : data.users[withdrawnMark!.sync.lastModifiedBy!],
                            canSupersede: marking.canSupersede,
                            supersedeReason: marking.supersedeReason,
                            canExclude: marking.canExclude,
                            excludeReason: marking.excludeReason,
                            onSupersede: () =>
                                supersedeLogEntry(context, o, data),
                            onExclude: () => excludeLogEntry(context, o),
                            canRestore: withdrawal?.canWithdraw ?? false,
                            restoreReason: withdrawal?.reason,
                            onRestoreToEstimates: () =>
                                restoreToEstimates(context, mark!),
                          );
                        },
                      ),
              ),
            ],
          );
        },
      ),
    );
  }

  void _sortTeamEntries(
    List<_LogEntry> entries,
    Map<String, Tag> tags,
    Map<String, User> users,
    List<Individual> allIndividuals,
    List<Deployment> deployments,
    double? Function(_LogEntry) distanceMeters,
    _TeamSort sort,
  ) {
    Tag? soleTag(_LogEntry e) {
      final id = e.soleTagId;
      return id == null ? null : tags[id];
    }

    // Task 11.93: a truth point sorts under whoever found it, like any other
    // row. Only a point written before that column existed still sorts to the
    // end under `~` — which is the honest place for "not recorded", and better
    // than attributing it to whoever last touched the row (task 11.92).
    String memberLabel(_LogEntry e) {
      final id = e.userId;
      if (id == null) return '~';
      final u = users[id];
      return u == null ? id : '${u.firstName} ${u.lastName}';
    }

    switch (sort) {
      case _TeamSort.time:
        entries.sort((a, b) => b.time.compareTo(a.time));
      case _TeamSort.tagName:
        entries.sort((a, b) => (soleTag(a)?.tagName ?? '~')
            .compareTo(soleTag(b)?.tagName ?? '~'));
      case _TeamSort.member:
        entries.sort((a, b) => memberLabel(a).compareTo(memberLabel(b)));
      case _TeamSort.distance:
        entries.sort((a, b) {
          final da = distanceMeters(a);
          final db = distanceMeters(b);
          if (da == null && db == null) return 0;
          if (da == null) return 1;
          if (db == null) return -1;
          return da.compareTo(db);
        });
      case _TeamSort.animal:
        entries.sort((a, b) => _animalSortKey(a, allIndividuals, deployments)
            .compareTo(_animalSortKey(b, allIndividuals, deployments)));
    }
  }
}

// The filter row and the two sort rows below it stack vertically and their
// chips must start at the same x position, but "Sort" and "Filter" aren't
// the same width. A fixed 52-pixel box kept that alignment until text
// scaling made the word wrap inside it and the box grow downward instead
// (task 11.167) -- sizing the box to the wider of the two words, measured
// in the ambient text scale, keeps the alignment without ever wrapping:
// the label grows sideways with the rest of the row's scroll room instead
// of pushing the chips down.
class _SortFilterLabel extends StatelessWidget {
  const _SortFilterLabel(this.text);

  final String text;

  static const _style = TextStyle(fontSize: 12, fontWeight: FontWeight.w700);

  // Task 11.148's rule: `Text` merges its style onto the ambient
  // `DefaultTextStyle` rather than rendering `_style` bare, so a measurement
  // that skips that merge is quietly wrong in the same direction everywhere
  // — here it undercounted "Filter"'s width and silently clipped it at
  // larger text sizes (caught by AX2 while watching this fail).
  static double _widthFor(BuildContext context) {
    final style = DefaultTextStyle.of(context).style.merge(_style);
    final scaler = MediaQuery.textScalerOf(context);
    final direction = Directionality.of(context);
    double measure(String s) {
      final painter = TextPainter(
        text: TextSpan(text: s, style: style),
        textScaler: scaler,
        textDirection: direction,
        maxLines: 1,
      )..layout();
      return painter.width;
    }

    // A one-pixel margin: the painter and the real `RenderParagraph` round
    // sub-pixel widths independently, and a box exactly as wide as its text
    // is one rounding error from clipping it.
    return max(measure('Sort'), measure('Filter')) + 1;
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: _widthFor(context),
      child: Text(text, style: _style, softWrap: false, overflow: TextOverflow.visible),
    );
  }
}

class _TeamSortBar extends StatelessWidget {
  const _TeamSortBar({required this.sort, required this.distanceEnabled, required this.onChanged});

  final _TeamSort sort;
  final bool distanceEnabled;
  final ValueChanged<_TeamSort> onChanged;

  static const _options = [
    (_TeamSort.animal, 'Animal', Icons.pets),
    (_TeamSort.member, 'Member', Icons.person_outline),
    (_TeamSort.tagName, 'Tag', Icons.podcasts),
    (_TeamSort.time, 'Time', Icons.schedule),
    (_TeamSort.distance, 'Distance', Icons.social_distance),
  ];

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: DesignTokens.spacingScreenHorizontal,
        vertical: 4,
      ),
      child: Row(
        children: [
          const _SortFilterLabel('Sort'),
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  for (final (value, label, icon) in _options) ...[
                    // The distance chip must present as unavailable with a
                    // reason when there's no GPS fix — never just silently
                    // vanish or (worse) stay selectable and lie about order.
                    //
                    // Task 11.137: the reason was in a `Tooltip`, which a
                    // touchscreen never shows. It is in the chip's own label
                    // instead — this row scrolls horizontally, so a longer
                    // label costs nothing, and there is no second line to be
                    // had inside a chip.
                    if (value == _TeamSort.distance && !distanceEnabled)
                      ChoiceChip(
                        visualDensity: VisualDensity.compact,
                        avatar: Icon(icon, size: 15),
                        label: Text('$label — no GPS fix'),
                        selected: sort == value,
                        onSelected: null,
                      )
                    else
                      ChoiceChip(
                        visualDensity: VisualDensity.compact,
                        avatar: Icon(icon, size: 15),
                        label: Text(label),
                        selected: sort == value,
                        onSelected: (_) => onChanged(value),
                      ),
                    const SizedBox(width: 6),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SortBar extends StatelessWidget {
  const _SortBar({required this.sort, required this.distanceEnabled, required this.onChanged});

  final _LogSort sort;
  final bool distanceEnabled;
  final ValueChanged<_LogSort> onChanged;

  static const _options = [
    (_LogSort.animal, 'Animal', Icons.pets),
    (_LogSort.time, 'Time', Icons.schedule),
    (_LogSort.tagName, 'Tag', Icons.podcasts),
    (_LogSort.frequency, 'Frequency', Icons.graphic_eq),
    (_LogSort.distance, 'Distance', Icons.social_distance),
  ];

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: DesignTokens.spacingScreenHorizontal,
        vertical: 4,
      ),
      child: Row(
        children: [
          const _SortFilterLabel('Sort'),
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  for (final (value, label, icon) in _options) ...[
                    ChoiceChip(
                      visualDensity: VisualDensity.compact,
                      avatar: Icon(icon, size: 15),
                      label: Text(label),
                      selected: sort == value,
                      onSelected: value == _LogSort.distance && !distanceEnabled
                          ? null
                          : (_) => onChanged(value),
                    ),
                    const SizedBox(width: 6),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _FilterBar extends StatelessWidget {
  const _FilterBar({
    required this.filters,
    required this.tags,
    required this.individuals,
    required this.collarsByAnimal,
    required this.deployments,
    required this.users,
    required this.onChanged,
  });

  final _HistoryFilters filters;
  final Map<String, Tag> tags;

  /// The project's live animals, for the filter picker (task 11.241).
  final List<Individual> individuals;

  /// Every collar each animal has worn — see `_HistoryData` (task 11.243).
  final Map<String, Set<String>> collarsByAnimal;

  /// The project's live links — see `_HistoryData` (task 11.244).
  final List<Deployment> deployments;
  final Map<String, User> users;
  final ValueChanged<_HistoryFilters> onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: DesignTokens.spacingScreenHorizontal,
        vertical: 4,
      ),
      child: Row(
        children: [
          const _SortFilterLabel('Filter'),
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  ActionChip(
                    visualDensity: VisualDensity.compact,
                    avatar: const Icon(Icons.podcasts, size: 16),
                    label: Text(filters.subject?.label ?? 'Tag: All'),
                    onPressed: () => _pickTag(context),
                  ),
                  const SizedBox(width: 6),
                  ActionChip(
                    visualDensity: VisualDensity.compact,
                    avatar: const Icon(Icons.person_outline, size: 16),
                    label: Text(filters.userId == null
                        ? 'Observer: All'
                        : 'Observer: ${_userLabel(users[filters.userId])}'),
                    onPressed: () => _pickUser(context),
                  ),
                  const SizedBox(width: 6),
                  ActionChip(
                    visualDensity: VisualDensity.compact,
                    avatar: const Icon(Icons.date_range, size: 16),
                    label: Text(filters.dateRange == null ? 'Date: All' : 'Date: ${_rangeLabel(filters.dateRange!)}'),
                    onPressed: () => _pickDateRange(context),
                  ),
                  if (filters.subject != null || filters.userId != null || filters.dateRange != null) ...[
                    const SizedBox(width: 6),
                    ActionChip(
                      visualDensity: VisualDensity.compact,
                      avatar: const Icon(Icons.clear, size: 16),
                      label: const Text('Clear'),
                      onPressed: () => onChanged(const _HistoryFilters()),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _userLabel(User? u) => u == null ? '?' : '${u.firstName} ${u.lastName}';

  String _rangeLabel(DateTimeRange r) {
    String d(DateTime t) => '${t.month}/${t.day}';
    return '${d(r.start)}–${d(r.end)}';
  }

  /// Animals first — each one covering every collar it has worn — then the
  /// collars, so *"show me Marie"* is one tap and *"show me the 160.321
  /// collar only"* is still there (task 11.241). An animal with no collar is
  /// not offered: there is nothing recorded against nobody's collar.
  Future<void> _pickTag(BuildContext context) async {
    final byAnimal = collarsByAnimal;
    final animalOptions = [
      for (final animal in individuals)
        if (byAnimal.containsKey(animal.individualId))
          _SubjectFilter.animal(
            animal,
            byAnimal[animal.individualId]!,
            deployments,
          ),
    ];
    final selected = await showDialog<_SubjectFilter?>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('Filter by animal or tag'),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('All'),
          ),
          if (animalOptions.isNotEmpty) const _PickerSectionLabel('Animals'),
          for (final option in animalOptions)
            SimpleDialogOption(
              onPressed: () => Navigator.of(context).pop(option),
              child: Text(
                '${option.name} · '
                '${option.ids.length == 1 ? '1 tag' : '${option.ids.length} tags'}',
              ),
            ),
          const _PickerSectionLabel('Tags'),
          for (final tag in tags.values)
            SimpleDialogOption(
              onPressed: () => Navigator.of(context).pop(_SubjectFilter.tag(tag)),
              child: Text('${tag.frequencyMhz.toStringAsFixed(3)} MHz · ${tag.tagName}'),
            ),
        ],
      ),
    );
    onChanged(filters.copyWith(subject: () => selected));
  }

  Future<void> _pickUser(BuildContext context) async {
    final selected = await showDialog<String?>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('Filter by observer'),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('All observers'),
          ),
          for (final user in users.values)
            SimpleDialogOption(
              onPressed: () => Navigator.of(context).pop(user.userId),
              child: Text(_userLabel(user)),
            ),
        ],
      ),
    );
    onChanged(filters.copyWith(userId: () => selected));
  }

  Future<void> _pickDateRange(BuildContext context) async {
    final now = DateTime.now();
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(now.year - 10),
      lastDate: DateTime(now.year + 1),
      initialDateRange: filters.dateRange,
    );
    if (picked == null) return;
    onChanged(filters.copyWith(dateRange: () => picked));
  }
}

class _ObservationTile extends StatelessWidget {
  const _ObservationTile({
    required this.observation,
    required this.tag,
    required this.observer,
    this.distanceMeters,
    this.animalLabel,
    this.animalColorHex,
    required this.canEdit,
    this.disabledReason,
    required this.onEdit,
    required this.onShare,
    required this.onDelete,
    this.mark,
    this.markedBy,
    this.withdrawnMark,
    this.withdrawnMarkedBy,
    this.withdrawnBy,
    this.canSupersede = false,
    this.supersedeReason,
    this.canExclude = false,
    this.excludeReason,
    this.canRestore = false,
    this.restoreReason,
    required this.onSupersede,
    required this.onExclude,
    required this.onRestoreToEstimates,
  });

  final Observation observation;
  final Tag? tag;
  final User? observer;
  final double? distanceMeters;

  /// The animal this bearing was actually about, resolved at its own
  /// timestamp by `_animalAttributionFor` — never the collar's current
  /// owner (task 11.272). Null only when the observation names no tag at
  /// all (a tagless note), the one case with nothing to attribute.
  final String? animalLabel;

  /// [animalLabel]'s colour, paired with it so the swatch and the text can
  /// never disagree about which animal a row names.
  final String? animalColorHex;
  final bool canEdit;
  /// Why Edit/Delete are disabled, or null when [canEdit]. Shown as a second
  /// line on the menu entry itself rather than leaving the icons merely absent
  /// (task 11.12) — "explain, don't just hide" applies here exactly as it did
  /// to the project-settings controls in task 11.1. **It was a `Tooltip` until
  /// task 11.137**, which is a control a touchscreen never shows: the reason
  /// existed and nobody using a phone could read it.
  final String? disabledReason;
  final VoidCallback onEdit;
  final VoidCallback onShare;
  final VoidCallback onDelete;

  /// Task 11.7's live mark on this observation, or null when it counts
  /// normally. An observation with one is **still shown** — greyed and
  /// labelled, never hidden.
  final ObservationExclusion? mark;

  /// Who made [mark], for the row's explanation. Often not the observer.
  final User? markedBy;

  /// Task 11.18. The most recent mark on this observation that was later
  /// withdrawn — independent of [mark]: an observation can be un-marked and
  /// then marked again, so both a live [mark] and a [withdrawnMark] can be
  /// non-null at once, and the row shows both. Null when this observation
  /// has never had a mark withdrawn.
  final ObservationExclusion? withdrawnMark;

  /// Who made [withdrawnMark] originally — not the same person as
  /// [withdrawnBy] in the case this feature exists for (task 11.15): an
  /// owner withdrawing a contributor's mark.
  final User? withdrawnMarkedBy;

  /// Who withdrew [withdrawnMark] ([ObservationExclusion.sync]'s
  /// `lastModifiedBy` after the tombstone).
  final User? withdrawnBy;
  final bool canSupersede;
  final String? supersedeReason;
  final bool canExclude;
  final String? excludeReason;

  /// Task 11.15: whether this user may withdraw [mark] specifically — the
  /// person who made it, or a current project owner, subject to the rung the
  /// mark's own kind sits on. Not derivable from [canSupersede]/[canExclude],
  /// which is what the menu used to guess from.
  final bool canRestore;
  final String? restoreReason;
  final VoidCallback onSupersede;
  final VoidCallback onExclude;
  final VoidCallback onRestoreToEstimates;

  @override
  Widget build(BuildContext context) {
    final o = observation;
    final distance = distanceMeters == null
        ? ''
        : ' · ${distanceMeters! >= 1000 ? '${(distanceMeters! / 1000).toStringAsFixed(1)} km' : '${distanceMeters!.round()} m'}';
    final isNote = o.observationType == ObservationType.note;
    final who = observer == null ? o.userId : '${observer!.firstName} ${observer!.lastName}';
    final when = o.timestampLocal.toLocal().toString().substring(0, 16);

    // Task 11.272, corrected the same day on Michael's read: the animal
    // belongs on the title line with the collar and frequency — full
    // strength, not grey on a second line — because that is the one line
    // that is never greyed or wrapped away, and it is "mainly what users
    // will want to see." Empty for a tagless note, which has nothing for
    // the derivation to ask about.
    final animalPrefix = animalLabel == null ? '' : '$animalLabel · ';

    final String title;
    final String subtitle;
    if (isNote) {
      title = tag == null
          ? '📝 Note'
          : '📝 Note · $animalPrefix${tag!.tagName} · ${tag!.frequencyMhz.toStringAsFixed(3)} MHz';
      final noteText = (o.notes == null || o.notes!.isEmpty) ? '(no text)' : o.notes!;
      subtitle = '$when · $who$distance\n$noteText';
    } else {
      title = '$animalPrefix${tag?.tagName ?? o.tagId ?? '—'} · ${tag?.frequencyMhz.toStringAsFixed(3) ?? '?'} MHz';
      subtitle = '$when · $who · '
          '${o.observationType == ObservationType.directional ? '${o.trueNorthBearing?.toStringAsFixed(0) ?? '?'}°' : quality.observationTypeLabel(o.observationType)} · '
          '${quality.signalStrengthLabel(o.signalStrength)}'
          // Task 11.194: this was the raw database token (`good`,
          // `suspected_bounce`, underscore and all) — the same defect task
          // 11.193 fixed on the Position screen, still live here. Read from
          // the one owner of these words rather than reintroducing a third
          // copy.
          '${o.bearingQuality != null ? ' · ${quality.bearingQualityLabel(o.bearingQuality!)}' : ''}'
          '$distance';
    }
    // Task 11.7. The row stays put and stays legible; what changes is that it
    // says, in words, that it is not counting toward this tag's position and
    // who decided that. Struck-through text alone would be a single visual cue
    // carrying the whole meaning, which this project's redundant-cue rule
    // rejects — so the state is spelled out on its own line as well.
    final withheld = mark == null
        ? null
        : AnalysisEligibility.withheldReason(o, {o.observationId: mark!});
    final markedByWho = markedBy == null
        ? mark?.userId ?? ''
        : '${markedBy!.firstName} ${markedBy!.lastName}';

    // Task 11.18. An owner can withdraw a contributor's mark (task 11.15)
    // and the contributor is never told directly, so the row has to say so
    // for anyone who looks — both halves, since either alone misleads: "was
    // excluded" alone hides that it no longer is, and a bare "restored to
    // estimates" hides that someone else's judgment was the one overridden.
    final withdrawn = withdrawnMark;
    String? withdrawnSentence;
    if (withdrawn != null) {
      final verb = withdrawn.kind == ObservationExclusionKind.superseded
          ? 'Superseded'
          : 'Excluded';
      final because = (withdrawn.reason?.trim().isEmpty ?? true)
          ? ''
          : ' — ${withdrawn.reason!.trim()}';
      final originalWho = withdrawnMarkedBy == null
          ? withdrawn.userId
          : '${withdrawnMarkedBy!.firstName} ${withdrawnMarkedBy!.lastName}';
      final withdrawnByWho = withdrawnBy == null
          ? (withdrawn.sync.lastModifiedBy ?? '')
          : '${withdrawnBy!.firstName} ${withdrawnBy!.lastName}';
      final withdrawnWhen =
          withdrawn.sync.deletedAt!.toLocal().toString().substring(0, 16);
      withdrawnSentence = '$verb by $originalWho$because, then withdrawn by '
          '$withdrawnByWho on $withdrawnWhen';
    }

    final signalIrregular = o.signalIrregular ?? false;

    return ListTile(
      isThreeLine: isNote || withheld != null || withdrawnSentence != null ||
          signalIrregular,
      // Task 11.272: the animal this bearing was about at its own moment,
      // never `tag.colorHex` — since schema v16 that column is the collar's
      // *current* owner, which repaints an old bearing the moment the collar
      // changes hands.
      leading: animalColorHex == null ? null : TagColorSwatch(colorHex: animalColorHex!),
      title: Text(title),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(subtitle),
          // Task 11.194. Michael: "add it to the log list." A word, not a
          // bare mark — this app's colour rule is that colour never carries
          // meaning alone, and the Position row's bare triangle is the one
          // argued exception; a second bare mark here would need the same
          // argument and there is room on this row for the word.
          if (signalIrregular)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Row(
                children: [
                  Icon(
                    Icons.warning_amber_rounded,
                    size: 14,
                    color: Theme.of(context).extension<TriTrackColors>()!.bounceRed,
                  ),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      quality.irregularSignalLabel,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                ],
              ),
            ),
          if (withheld != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Row(
                children: [
                  const Icon(Icons.block_outlined, size: 14),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      '$withheld (by $markedByWho)',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                ],
              ),
            ),
          if (withdrawnSentence != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Row(
                children: [
                  const Icon(Icons.history, size: 14),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      withdrawnSentence,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
      // Task 11.100 item 4: one labelled overflow menu, not four bare icons.
      //
      // This row used to carry Edit, Delete, Share and the supersede/exclude
      // menu as separate icon buttons, while the truth-point row three
      // classes down already had a single ⋯ — so the two kinds of record on
      // the same screen offered their controls in two different shapes, and
      // the user guide had to warn a reader away from looking for a pencil
      // on a truth-point row that has none. Task 11.99 made exactly this
      // move on the projects screen (four bare icons → one labelled menu),
      // which settles which of the two shapes is the house style: the
      // bearing rows were the ones out of step.
      //
      // Every entry keeps task 11.12's rule — shown disabled with the
      // reason, never hidden — which reads better in a menu than it did as
      // a greyed-out icon whose tooltip a touchscreen never shows.
      trailing: _ObservationMenu(
        canEdit: canEdit,
        disabledReason: disabledReason,
        onEdit: onEdit,
        onDelete: onDelete,
        onShare: onShare,
        marked: mark != null,
        canSupersede: canSupersede,
        supersedeReason: supersedeReason,
        canExclude: canExclude,
        excludeReason: excludeReason,
        onSupersede: onSupersede,
        onExclude: onExclude,
        canRestore: canRestore,
        restoreReason: restoreReason,
        onRestore: onRestoreToEstimates,
      ),
    );
  }
}

/// Every control on an observation row, in one ⋯ menu.
///
/// **Task 11.100 item 4 folded Edit, Delete and Share in here** alongside the
/// supersede / exclude / restore entries that already lived in a menu. Before
/// that the row carried four bare icon buttons whose only labels were
/// tooltips — and a touchscreen never shows a tooltip, so on the device this
/// app is used on they had no labels at all.
///
/// Entries a role may not use are **shown disabled with the reason** rather
/// than omitted — task 11.12's standing rule, applied here because 11.12 could
/// not sweep the supersede feature (it did not exist yet) and recorded that
/// 11.7 must carry the treatment itself.
class _ObservationMenu extends StatelessWidget {
  const _ObservationMenu({
    required this.canEdit,
    required this.disabledReason,
    required this.onEdit,
    required this.onDelete,
    required this.onShare,
    required this.marked,
    required this.canSupersede,
    required this.supersedeReason,
    required this.canExclude,
    required this.excludeReason,
    required this.canRestore,
    required this.restoreReason,
    required this.onSupersede,
    required this.onExclude,
    required this.onRestore,
  });

  final bool canEdit;
  final String? disabledReason;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  final VoidCallback onShare;

  final bool marked;
  final bool canSupersede;
  final String? supersedeReason;
  final bool canExclude;
  final String? excludeReason;
  final bool canRestore;
  final String? restoreReason;
  final VoidCallback onSupersede;
  final VoidCallback onExclude;
  final VoidCallback onRestore;

  @override
  Widget build(BuildContext context) {
    // Task 11.15: the restore entry used to be offered on
    // `canExclude || canSupersede` — the rights *making* a mark needs, which
    // is not the question. Withdrawing also depends on whose mark it is, and
    // that answer now arrives from [withdrawMarkVerdict] so the screen and
    // the repository cannot disagree. The old guess was wrong in both
    // directions: it offered a contributor a live control for a colleague's
    // supersede that the repository then refused, and it read `canSupersede`
    // as enough to undo an exclusion.
    // Task 11.94/11.101 exemption: the ⋮ trigger is labelled only by
    // `tooltip:`. Adopted line: `more_vert` is the one glyph this project
    // treats as a universal platform convention (task 11.99 itself shipped
    // this exact pattern for `projects_screen.dart`'s row menu, unlabelled
    // trigger and all) — opening it is non-destructive, and every entry
    // inside carries a real text label.
    return PopupMenuButton<String>(
      tooltip: 'Observation actions',
      // Task 11.137: the reason a row is unavailable is on the row, not in a
      // `Tooltip` — a phone has no hover, so five of these reasons had never
      // been readable by anybody. Same helper as `projects_screen.dart`'s row
      // menu (task 11.99), so the two menus cannot drift into two shapes.
      itemBuilder: (context) => [
        reasonedMenuItem(
          context,
          value: 'edit',
          label: 'Edit observation…',
          enabled: canEdit,
          note: canEdit ? null : disabledReason,
        ),
        reasonedMenuItem(
          context,
          value: 'delete',
          label: 'Delete observation…',
          enabled: canEdit,
          note: canEdit ? null : disabledReason,
        ),
        // Sharing reads a record out; it needs no write right, so it is never
        // the disabled entry.
        reasonedMenuItem(
          context,
          value: 'share',
          label: 'Share observation…',
        ),
        if (marked)
          reasonedMenuItem(
            context,
            value: 'restore',
            label: 'Count in estimates again',
            enabled: canRestore,
            note: canRestore ? null : restoreReason,
          )
        else ...[
          reasonedMenuItem(
            context,
            value: 'supersede',
            label: 'Superseded by another record…',
            enabled: canSupersede,
            note: canSupersede ? null : supersedeReason,
          ),
          reasonedMenuItem(
            context,
            value: 'exclude',
            label: 'Exclude from estimates…',
            enabled: canExclude,
            note: canExclude ? null : excludeReason,
          ),
        ],
      ],
      onSelected: (value) => switch (value) {
        'edit' => onEdit(),
        'delete' => onDelete(),
        'share' => onShare(),
        'supersede' => onSupersede(),
        'exclude' => onExclude(),
        _ => onRestore(),
      },
    );
  }
}

/// A "no signal" entry lists several collars for one moment — the one row
/// shape [_animalAttributionFor] cannot answer with a single name. **Task
/// 11.272's decision, in writing:** each collar's own colour is resolved
/// separately, at the row's moment, and shown in its own position in the
/// stack. **When two collars in the stack disagree — one on an animal, one
/// on nobody, or two different animals — the stack simply shows two
/// different colours.** That is not a rendering fault to paper over: it is
/// the honest fact that this "no signal" listened for two collars that were
/// not, at that moment, the same story. A row that forced one colour onto
/// the whole stack would be manufacturing an agreement that the data does
/// not have.
class _NonDetectionTile extends StatelessWidget {
  const _NonDetectionTile({
    required this.nonDetection,
    required this.tags,
    required this.individuals,
    required this.deployments,
    required this.observer,
    required this.canEdit,
    required this.disabledReason,
    required this.onDelete,
    this.distanceMeters,
  });

  final NonDetection nonDetection;
  final Map<String, Tag> tags;

  /// Every animal this project has ever held — see `_HistoryData
  /// .allIndividuals`'s doc comment for why this is not the live-only list.
  final List<Individual> individuals;
  final List<Deployment> deployments;
  final User? observer;
  final bool canEdit;
  final String? disabledReason;
  final VoidCallback onDelete;
  final double? distanceMeters;

  @override
  Widget build(BuildContext context) {
    final nd = nonDetection;
    final distance = distanceMeters == null
        ? ''
        : ' · ${distanceMeters! >= 1000 ? '${(distanceMeters! / 1000).toStringAsFixed(1)} km' : '${distanceMeters!.round()} m'}';
    final when = nd.timestampLocal.toLocal().toString().substring(0, 16);
    final who = observer == null ? nd.userId : '${observer!.firstName} ${observer!.lastName}';
    final freqs = nd.tagIdsListenedFor
        .map((id) => tags[id]?.frequencyMhz)
        .whereType<double>()
        .map((f) => f.toStringAsFixed(3))
        .join(', ');
    // Task 11.272: each collar's colour at *this* moment, never the
    // collar's current owner — see the class doc comment for what happens
    // when two collars in the stack disagree.
    final colorHexes = [
      for (final id in nd.tagIdsListenedFor)
        if (tags.containsKey(id))
          _animalAttributionFor(id, nd.timestampLocal, individuals, deployments).$2,
    ];
    final scheme = Theme.of(context).colorScheme;
    return ListTile(
      isThreeLine: true,
      leading: colorHexes.isEmpty ? null : TagColorSwatchStack(colorHexes: colorHexes),
      title: Text('🚫 No signal · ${nd.tagIdsListenedFor.length} '
          '${nd.tagIdsListenedFor.length == 1 ? 'tag' : 'tags'}'),
      subtitle: Text(
        '$when · $who$distance\n'
        '${freqs.isEmpty ? 'no tags recorded' : '$freqs MHz'}'
        '${nd.notes != null && nd.notes!.isNotEmpty ? ' · ${nd.notes}' : ''}',
        style: TextStyle(color: scheme.onSurfaceVariant),
      ),
      // Task 11.252: the row had no control at all — this matches the truth
      // point row's menu shape (task 11.12's rule: shown disabled with the
      // reason, never hidden).
      trailing: PopupMenuButton<String>(
        tooltip: 'No signal record actions',
        itemBuilder: (context) => [
          reasonedMenuItem(
            context,
            value: 'delete',
            label: 'Delete "no signal" record…',
            enabled: canEdit,
            note: canEdit ? null : disabledReason,
          ),
        ],
        onSelected: (_) => onDelete(),
      ),
    );
  }
}

/// A truth point in the Log — where somebody physically found the animal, the
/// collar, or both (task 11.33's record; listed at all by task 11.92).
///
/// **The precision and what-was-found are on the row, not behind a tap.** They
/// are what decide whether the point can be used: a position known to ±3 m with
/// the animal in front of you and a position known to ±40 m from a shed collar
/// are different facts, and a list that showed only tag, place and time made
/// them look identical.
class _TruthPointTile extends StatelessWidget {
  const _TruthPointTile({
    required this.truthPoint,
    required this.tag,
    required this.finder,
    required this.animalLabel,
    required this.animalColorHex,
    required this.canEdit,
    required this.disabledReason,
    required this.onEdit,
    required this.onDelete,
    this.distanceMeters,
  });

  final ActualTagLocation truthPoint;
  final Tag? tag;

  /// Whoever found this point, resolved to a `Users` row — null both when the
  /// point records no finder (before schema v11) and when it records one this
  /// device does not hold. [truthFoundByLabel] tells those two apart; nothing
  /// here should collapse them.
  final User? finder;

  /// The animal this point was actually about, resolved at its own moment —
  /// task 11.272, `_animalAttributionFor`. A truth point always names one
  /// tag, so unlike [_ObservationTile] this is never null.
  final String animalLabel;
  final String animalColorHex;
  final bool canEdit;
  final String? disabledReason;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  final double? distanceMeters;

  @override
  Widget build(BuildContext context) {
    final t = truthPoint;
    final scheme = Theme.of(context).colorScheme;
    final distance = distanceMeters == null
        ? ''
        : ' · ${distanceMeters! >= 1000 ? '${(distanceMeters! / 1000).toStringAsFixed(1)} km' : '${distanceMeters!.round()} m'}';
    final when = t.timestampLocal.toLocal().toString().substring(0, 16);
    final tagLabel = tag == null
        ? t.tagId
        : '${tag!.tagName} · ${tag!.frequencyMhz.toStringAsFixed(3)} MHz';
    return ListTile(
      isThreeLine: true,
      // Task 11.272: the animal at this point's own moment, never
      // `tag.colorHex`'s current owner.
      leading: TagColorSwatch(colorHex: animalColorHex),
      // Task 11.272, corrected the same day: the animal reads on the title
      // line with the collar, full strength — not grey on the subtitle.
      title: Text('📍 Truth point · $animalLabel · $tagLabel'),
      subtitle: Text(
        '$when$distance\n'
        '${truthFoundLabel(t.foundKind)} · '
        'precision ±${_precisionLabel(t.uncertaintyRadius)} m\n'
        // Task 11.93. Both read "not recorded" rather than blank on a point
        // written before schema v11 — a blank is a gap the reader fills in.
        '${truthFoundByLabel(t, finder)} · '
        '${truthPositionSourceLabel(t.positionSource)}'
        '${t.notes != null && t.notes!.isNotEmpty ? ' · ${t.notes}' : ''}',
        style: TextStyle(color: scheme.onSurfaceVariant),
      ),
      trailing: PopupMenuButton<String>(
        // Same shape as the observation row's menu: the entries a person may
        // not use are shown disabled with the reason, rather than hidden, so
        // "why can I not do this" has an answer on the screen.
        itemBuilder: (context) => [
          reasonedMenuItem(
            context,
            value: 'edit',
            // Task 11.100: this used to read "Edit precision / what was
            // found…", which named two of the three things the dialog it
            // opens can change. Moving the point is the headline of task
            // 11.93, and somebody wanting to nudge a position read the old
            // label and concluded they could not.
            label: 'Edit position / precision / what was found…',
            enabled: canEdit,
            note: canEdit ? null : disabledReason,
          ),
          reasonedMenuItem(
            context,
            value: 'delete',
            label: 'Delete truth point…',
            enabled: canEdit,
            note: canEdit ? null : disabledReason,
          ),
        ],
        onSelected: (value) => value == 'edit' ? onEdit() : onDelete(),
      ),
    );
  }

  /// `12.0` → `12` — a whole number of metres must not read as a claim of
  /// decimal precision.
  static String _precisionLabel(double metres) {
    final text = metres.toString();
    return text.endsWith('.0') ? text.substring(0, text.length - 2) : text;
  }
}

class _HistoryData {
  const _HistoryData({
    required this.observations,
    required this.nonDetections,
    required this.truthPoints,
    required this.tags,
    required this.individuals,
    required this.allIndividuals,
    required this.collarsByAnimal,
    required this.deployments,
    required this.users,
    required this.marks,
    required this.withdrawnMarks,
  });
  final List<Observation> observations;
  final List<NonDetection> nonDetections;

  /// Task 11.92: where somebody physically found the animal or the collar.
  /// These are the yardstick the position estimates get measured against, and
  /// until this task they appeared in no list on any screen.
  final List<ActualTagLocation> truthPoints;
  final Map<String, Tag> tags;

  /// The project's live animals, by name — what the filter picker offers
  /// above the collars (task 11.241).
  final List<Individual> individuals;

  /// Every animal this project has ever held, live or tombstoned — task
  /// 11.272. A row's swatch and animal name are resolved against this list,
  /// never [individuals]: the filter only ever offers a *live* animal to
  /// pick (task 11.258's rule, so a tombstoned one is never selectable), but
  /// a bearing recorded while a since-deleted animal wore the collar still
  /// happened, and the row that names it is the caller [animalForObservationIn]'s
  /// own doc comment says is responsible for handling that name.
  final List<Individual> allIndividuals;

  /// Every collar each animal has worn, from the dated links (task 11.243).
  /// Read from `Deployments` rather than from a column on the tag, which is
  /// what lets one collar appear under two animals in turn.
  final Map<String, Set<String>> collarsByAnimal;

  /// The project's live links (task 11.244) — what the animal filter asks
  /// the interval derivation of. See `_SubjectFilter`.
  final List<Deployment> deployments;
  final Map<String, User> users;

  /// Task 11.7's live supersede/exclude marks, keyed by the observation each
  /// takes out of position estimation. An observation carrying one still
  /// appears in both tabs, with its state shown on the row — 11.7 requires
  /// exclusion to be visible, not a disappearance.
  final Map<String, ObservationExclusion> marks;

  /// Task 11.18's withdrawn-mark history, keyed by observation — see
  /// [ObservationExclusionRepository.withdrawnByObservation]. An owner can
  /// withdraw a contributor's mark (task 11.15); the contributor is not
  /// notified, so the row itself has to say so for anyone who looks.
  final Map<String, ObservationExclusion> withdrawnMarks;
}

/// A single Log row: an [Observation] (directional/omni/note), a multi-tag
/// [NonDetection] ("no signal"), or an [ActualTagLocation] — a truth point,
/// where somebody physically found the animal or the collar. Lets the Log list,
/// filters and sorts treat all three uniformly.
class _LogEntry {
  const _LogEntry.observation(Observation this.observation)
      : nonDetection = null,
        truthPoint = null;
  const _LogEntry.nonDetection(NonDetection this.nonDetection)
      : observation = null,
        truthPoint = null;

  /// Task 11.92. Truth points were written from the Record screen and then
  /// appeared in no list at all — the map drew a dot and the Log did not know
  /// they existed.
  const _LogEntry.truthPoint(ActualTagLocation this.truthPoint)
      : observation = null,
        nonDetection = null;

  final Observation? observation;
  final NonDetection? nonDetection;
  final ActualTagLocation? truthPoint;

  DateTime get time =>
      observation?.timestampLocal ??
      nonDetection?.timestampLocal ??
      truthPoint!.timestampLocal;

  /// Who recorded it — and for a truth point, **who walked in and found the
  /// collar** (task 11.93's `user_id`).
  ///
  /// Still null for a truth point written before schema v11. It is deliberately
  /// **not** filled from `sync.last_modified_by`, which names whoever last
  /// *touched* the row: presenting the second as the first is the class of
  /// defect this project keeps finding, so where the app does not know it says
  /// so.
  String? get userId =>
      observation?.userId ?? nonDetection?.userId ?? truthPoint?.userId;

  double get latitude =>
      observation?.latitude ?? nonDetection?.latitude ?? truthPoint!.latitude;
  double get longitude =>
      observation?.longitude ?? nonDetection?.longitude ?? truthPoint!.longitude;

  /// The one tag this row is about, if it is about exactly one — the key both
  /// tabs' tag and frequency sorts use.
  String? get soleTagId => observation?.tagId ?? truthPoint?.tagId;
}

/// Not private (unlike this screen's other module-level state) so tests can
/// pre-resolve it directly with `tester.runAsync` before pumping, the same
/// treatment `allTagsProvider` needs — see `log_screen_test.dart`.
final historyDataProvider = FutureProvider.family<_HistoryData, String>((ref, projectId) async {
  // Refresh whenever anything anywhere adds/edits/deletes a recording — so a
  // new observation, note, or non-detection saved from the Record screen shows
  // up live without leaving and re-entering the Log.
  ref.watch(recordingsRevisionProvider);
  final obsRepo = await ref.watch(observationRepositoryProvider.future);
  final markRepo = await ref.watch(observationExclusionRepositoryProvider.future);
  final ndRepo = await ref.watch(nonDetectionRepositoryProvider.future);
  final tagRepo = await ref.watch(tagRepositoryProvider.future);
  final userRepo = await ref.watch(userRepositoryProvider.future);

  final observations = await obsRepo.findByProject(projectId);
  final nonDetections = await ndRepo.findByProject(projectId);
  final truthRepo = await ref.watch(actualTagLocationRepositoryProvider.future);
  final truthPoints = await truthRepo.findByProject(projectId);
  final marks = await markRepo.activeByObservation(projectId);
  // Task 11.18: an owner can withdraw a contributor's mark and the
  // contributor is never told directly — this is what lets the row itself
  // say so.
  final withdrawnMarks = await markRepo.withdrawnByObservation(projectId);
  final userIds = <String>{
    ...observations.map((o) => o.userId),
    ...nonDetections.map((nd) => nd.userId),
    // Task 11.93: who found each truth point, so the row can name them rather
    // than showing an id. Null on a point written before schema v11, which is
    // "not recorded" and contributes nobody to look up.
    ...truthPoints.map((t) => t.userId).whereType<String>(),
    // Whoever superseded or excluded a row, who is often *not* its author —
    // the tile has to be able to name them.
    ...marks.values.map((m) => m.userId),
    // Task 11.18: a withdrawn mark names two people — its original author
    // and whoever withdrew it (`sync.lastModifiedBy` after the tombstone).
    ...withdrawnMarks.values.map((m) => m.userId),
    ...withdrawnMarks.values.map((m) => m.sync.lastModifiedBy).whereType<String>(),
  };

  // **One read of the project's tags since task 11.219**, where this looked
  // each referenced id up in a global table one at a time. Deleted ones
  // included: a tag removed from the project still names the collar an
  // earlier bearing was taken against, and the Log's whole job is to say
  // what was recorded.
  final tags = {
    for (final tag in await tagRepo.findByProject(
      projectId,
      includeDeleted: true,
    ))
      tag.tagId: tag,
  };
  final users = <String, User>{};
  for (final id in userIds) {
    final user = await userRepo.findById(id, includeDeleted: true);
    if (user != null) users[id] = user;
  }

  final individualRepo = await ref.watch(individualRepositoryProvider.future);
  // **Every animal, live or tombstoned** (task 11.272) — a swatch or a name
  // resolved against a live-only list would go blank the moment somebody
  // merges or deletes an animal a past bearing was actually about, which is
  // the same silent loss task 11.219 fixed for tags. The picker still only
  // ever offers a live one to filter by, so [individuals] stays live-only.
  final allIndividuals = await individualRepo.findByProject(
    projectId,
    includeDeleted: true,
  );
  final individuals = [
    for (final a in allIndividuals)
      if (!a.sync.isDeleted) a,
  ];
  // Task 11.243: which animals each collar has worn. **Every** deployment,
  // not only the current one — filtering by Marie has to reach bearings taken
  // on a collar she has since stopped wearing.
  //
  // **Task 11.244 carries the deployments themselves as well**, because the
  // animal filter asks the interval derivation of each row rather than
  // matching a set of collar ids. The set survives for the picker (which
  // animals have worn anything) and for a "no signal" entry, which has no
  // single timestamped collar to ask about.
  final deploymentRepo = await ref.watch(deploymentRepositoryProvider.future);
  final deployments = await deploymentRepo.findByProject(projectId);
  final collarsByAnimal = <String, Set<String>>{};
  for (final d in deployments) {
    (collarsByAnimal[d.individualId] ??= <String>{}).add(d.tagId);
  }

  return _HistoryData(
    observations: observations,
    nonDetections: nonDetections,
    truthPoints: truthPoints,
    tags: tags,
    individuals: individuals,
    allIndividuals: allIndividuals,
    collarsByAnimal: collarsByAnimal,
    deployments: deployments,
    users: users,
    marks: marks,
    withdrawnMarks: withdrawnMarks,
  );
});


/// A small heading inside the filter picker, separating animals from tags
/// (task 11.241).
class _PickerSectionLabel extends StatelessWidget {
  const _PickerSectionLabel(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(24, 8, 24, 2),
        child: Text(
          text.toUpperCase(),
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.8,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      );
}
