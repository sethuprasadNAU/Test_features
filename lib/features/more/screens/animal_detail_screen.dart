import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:tritrack_sync/tritrack_sync.dart'
    show DeploymentInterlock, TagColorPalette;
import 'package:uuid/uuid.dart';

import '../../../core/providers/app_context_provider.dart';
import '../../../core/providers/database_provider.dart';
import '../../../core/providers/deployments_provider.dart';
import '../../../core/providers/project_time_zone_provider.dart';
import '../../../core/providers/device_id_provider.dart';
import '../../../core/providers/individuals_provider.dart';
import '../../../core/providers/tag_view_refresh.dart';
import '../../../data/models/deployment.dart';
import '../../../data/models/individual.dart';
import '../../../data/models/observation.dart';
import '../../../data/models/sync_meta.dart';
import '../../../data/models/tag.dart';
import '../../../data/models/tag_library_entry.dart';
import '../../../data/repositories/deployment_linking.dart';
import '../../../data/repositories/deployment_repository.dart';
import '../../../data/repositories/individual_merge.dart';
import '../../../data/repositories/mutation_authorization.dart';
import '../../../data/repositories/repository_providers.dart';
import '../../../data/tags/library_groups.dart';
import '../../../widgets/disabled_reason.dart';
import '../../../widgets/individual_form.dart';
import '../../../widgets/load_failure.dart';
import '../../../widgets/near_duplicate_tag_dialog.dart';
import '../../../widgets/tag_color_swatch.dart';
import '../../../widgets/tag_form.dart';
import '../../../widgets/went_on_date_card.dart';
import 'tag_database_screen.dart' show tagLibraryProvider;

/// **What a person chose when a picked day needed a time** — task 11.261,
/// widened by task 11.265 from the removal editor alone to the attached-date
/// editor and to a past day. `_askDayOrTime`'s three outcomes: [dayOnly]
/// records the date alone, [pickTime] opens the time picker, and a null
/// return abandons the whole edit — *"Cancel for the day only"* read as
/// abandoning the action, which it was not, and this replaces it with a
/// choice that means what it says.
///
/// [dayOnly] is **withheld** whenever recording the bare day would overlap
/// another deployment — today (task 11.263, design §6a) or a past day
/// (task 11.265, design §6b). See `_dayOnlyWouldOverlap` and
/// `_attachedDayWouldOverlap`.
enum _DayOrTimeChoice { dayOnly, pickTime }

/// **Whether [deployment] is the tag on this animal right now** — task
/// 11.248, corrected by Michael's device look on 2026-09-15.
///
/// *"Current" means not yet recorded as off.* No removed date, or a removed
/// date still ahead of [now] — a time that has not passed, or a day after
/// today. Derived from the dates on the row itself, never from where it
/// sits in a list: sorting by `attached_date` and calling the first (or
/// last) row current is the same answer only until somebody back-dates a
/// link, which is exactly the edit task 11.248 added.
///
/// **Not the day-granular `spansDay` this project once had here** (task
/// 11.251, deleted by task 11.260 once the Record wheel stopped using it
/// too) — that asked *can this collar be heard today*, and a collar taken
/// off at 14:32 spanned today, so after a swap both the old and the new
/// collar read "Current" side by side, which is what Michael saw. A collar
/// somebody has recorded as off today is not the one the animal is wearing,
/// whatever the day-granular question said; and a date-only removal dated
/// today reads the same way, because the person who wrote it meant "it is
/// off".
bool isCurrentDeployment(Deployment deployment, DateTime now) {
  final removed = deployment.removedDate;
  if (removed == null) return true;
  if (deployment.endHasTime(removed)) return now.isBefore(removed);
  return deployment.dayOf(now).isBefore(deployment.dayOf(removed));
}

/// This animal's deployments, the current one (if any) first, then **newest
/// first** — Michael, 2026-09-15: *"older tags should go down so most
/// current is on top."* `DeploymentRepository.findByProject` hands them
/// over oldest first, which is the order a table reads well in and the
/// opposite of the order a person does.
///
/// Newest by `attached_date`, then by `created_at` (a same-day pair ties on
/// the date, and the real instant the link was written breaks it — the same
/// tie-break `latestDeploymentsSubquery` uses), then by id so the order is
/// total. A deployment with no attached date sorts last.
List<Deployment> orderedByCurrent(List<Deployment> deployments, DateTime now) {
  int rank(Deployment d) => isCurrentDeployment(d, now) ? 0 : 1;
  return [...deployments]..sort((a, b) {
    final byCurrent = rank(a).compareTo(rank(b));
    if (byCurrent != 0) return byCurrent;
    final aa = a.attachedDate, ba = b.attachedDate;
    if (aa == null || ba == null) {
      if (aa == null && ba == null) {
        return a.deploymentId.compareTo(b.deploymentId);
      }
      return aa == null ? 1 : -1;
    }
    final byDate = ba.compareTo(aa);
    if (byDate != 0) return byDate;
    final byCreated = b.sync.createdAt.compareTo(a.sync.createdAt);
    if (byCreated != 0) return byCreated;
    return a.deploymentId.compareTo(b.deploymentId);
  });
}

/// **One animal: its own record, and every collar it has worn** — task
/// 11.244.
///
/// The fields are `IndividualFields`, extracted from the dialog Project
/// Setup used to open for an animal's header row. What is new here is the
/// **collars**, which is where design §5a lives: linking one, closing one,
/// withdrawing one.
///
/// **Why a screen and not a bigger dialog.** The dialog was already a long
/// scroll with six fields and a merge button; the collar list adds a row per
/// deployment with two actions each, plus link and delete. On a 6.1-inch
/// phone that is a screen. **Task 11.245 removed the dialog and the grouping
/// it opened from** — this screen is the only door to an animal's fields
/// now, reachable from `More → Animals`.
class AnimalDetailScreen extends ConsumerWidget {
  const AnimalDetailScreen({super.key, required this.individualId});

  final String individualId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final projectAsync = ref.watch(currentProjectProvider);
    return projectAsync.when(
      loading: () =>
          const Scaffold(body: Center(child: CircularProgressIndicator())),
      error: (e, _) => Scaffold(
        appBar: AppBar(),
        body: LoadFailure('the current project', error: e),
      ),
      data: (project) => project == null
          ? Scaffold(
              appBar: AppBar(title: const Text('Animal')),
              body: const Center(child: Text('No project is active.')),
            )
          : _Body(projectId: project.projectId, individualId: individualId),
    );
  }
}

class _Body extends ConsumerWidget {
  const _Body({required this.projectId, required this.individualId});

  final String projectId;
  final String individualId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final animalsAsync = ref.watch(projectIndividualsProvider(projectId));
    final deploymentsAsync = ref.watch(projectDeploymentsProvider(projectId));
    final tagsAsync = ref.watch(projectTagsProvider(projectId));
    final standingAsync = ref.watch(myProjectStandingProvider(projectId));
    final isOwnerAsync = ref.watch(isProjectOwnerProvider(projectId));
    // Task 11.321: the Tag Library's tags are offered by "Link a tag", so
    // they are loaded with the rest and the picker opens without a wait.
    final libraryAsync = ref.watch(tagLibraryProvider);
    if (libraryAsync.hasError && !libraryAsync.hasValue) {
      return _error('your Tag Library', libraryAsync.error!);
    }
    final library = libraryAsync.value;
    if (library == null) return _loading();
    // Task 11.331: the project's zone, which a new link's day and this
    // screen's "today" are read in. An error falls back to no zone (this
    // phone's), which is how every day was read before schema v20.
    final zoneAsync = ref.watch(projectTimeZoneProvider(projectId));
    if (zoneAsync.isLoading && !zoneAsync.hasValue) return _loading();
    final fieldZone = zoneAsync.value;

    return animalsAsync.when(
      loading: _loading,
      error: (e, _) => _error('the animals on this project', e),
      data: (animals) => deploymentsAsync.when(
        loading: _loading,
        error: (e, _) => _error('which tags are on which animals', e),
        data: (deployments) => tagsAsync.when(
          loading: _loading,
          error: (e, _) => _error('the tags on this project', e),
          data: (tags) => standingAsync.when(
            loading: _loading,
            error: (e, _) => _error('what you are allowed to change here', e),
            data: (standing) => isOwnerAsync.when(
              loading: _loading,
              error: (e, _) => _error('what you are allowed to change here', e),
              data: (isOwner) {
                final animal = animals
                    .where((a) => a.individualId == individualId)
                    .firstOrNull;
                if (animal == null) {
                  // The animal was deleted, or merged away, under a screen
                  // that is still open. Say so rather than rendering an
                  // empty form.
                  return Scaffold(
                    appBar: AppBar(title: const Text('Animal')),
                    body: const Center(
                      child: Padding(
                        padding: EdgeInsets.all(24),
                        child: Text(
                          'This animal is no longer on the project. It may '
                          'have been deleted, or merged into another.',
                          textAlign: TextAlign.center,
                        ),
                      ),
                    ),
                  );
                }
                return _AnimalForm(
                  projectId: projectId,
                  animal: animal,
                  others: [
                    for (final a in animals)
                      if (a.individualId != individualId) a,
                  ],
                  deployments: [
                    for (final d in deployments)
                      if (d.individualId == individualId) d,
                  ],
                  allDeployments: deployments,
                  tags: tags,
                  library: library,
                  mayWrite: standing.mayWriteProjectData,
                  writeRefusal: standing.writeRefusal(
                    asViewer:
                        'Viewers cannot change an animal — ask an owner to '
                        'change your role.',
                  ),
                  isOwner: isOwner,
                  fieldZone: fieldZone,
                );
              },
            ),
          ),
        ),
      ),
    );
  }

  Widget _loading() =>
      const Scaffold(body: Center(child: CircularProgressIndicator()));

  Widget _error(String what, Object e) => Scaffold(
    appBar: AppBar(),
    body: LoadFailure(what, error: e),
  );
}

class _AnimalForm extends ConsumerStatefulWidget {
  const _AnimalForm({
    required this.projectId,
    required this.animal,
    required this.others,
    required this.deployments,
    required this.allDeployments,
    required this.tags,
    required this.library,
    required this.mayWrite,
    required this.writeRefusal,
    required this.isOwner,
    this.fieldZone,
  });

  final String projectId;
  final Individual animal;

  /// The project's time zone (task 11.331) — what a new link's day and this
  /// screen's "today" are read in. An existing link's dates are read in that
  /// link's own zone instead, which may be an older one.
  final String? fieldZone;

  /// The other animals on this project — the ones "Same animal as…" offers.
  final List<Individual> others;

  /// This animal's links, oldest first.
  final List<Deployment> deployments;

  /// Every link on the project, for working out which collars are free.
  final List<Deployment> allDeployments;
  final List<Tag> tags;

  /// This device's Tag Library — what "Link a tag" can copy in.
  final List<TagLibraryEntry> library;
  final bool mayWrite;
  final String? writeRefusal;
  final bool isOwner;

  @override
  ConsumerState<_AnimalForm> createState() => _AnimalFormState();
}

class _AnimalFormState extends ConsumerState<_AnimalForm> {
  late Individual _edited = widget.animal;

  /// Now — the boundary [isCurrentDeployment] reads. `build` reads it once
  /// rather than at the bottom of a `for`, so every row in one render agrees
  /// on what "now" was.
  ///
  /// **Task 11.271: `clock.now()`, not `DateTime.now()`.** This file has had
  /// three time-of-day defects (tasks 11.269, 11.273) — every one of them
  /// was a same-calendar-day comparison that read differently within an hour
  /// of local midnight. This getter is the one seam every date/time
  /// computation on this screen goes through (directly, or through
  /// [_today]), so it is the one place a test can pin "now" with
  /// `package:clock`'s `withClock` — see the clock-matrix group in
  /// `test/features/more/animals_screen_test.dart`.
  DateTime get _now => clock.now();

  /// The project's zone (task 11.331).
  String? get _zone => widget.fieldZone;

  @override
  void didUpdateWidget(_AnimalForm old) {
    super.didUpdateWidget(old);
    if (old.animal == widget.animal) return;
    // **Colour writes on tap** (task 11.268, item 2) and lands here through
    // the same `refreshTagViews` round trip every other write on this
    // screen does — so a colour-only change to the row underneath this
    // screen (this screen's own write, or another device's) is folded into
    // whatever draft is in progress rather than discarding it. Anything
    // else changing here — a sync or a save elsewhere touching name, status,
    // sex, species or notes — is a real edit of the row this screen is
    // showing, and the draft is stale against it.
    final onlyColorChanged =
        widget.animal.copyWith(colorHex: old.animal.colorHex) == old.animal;
    _edited = onlyColorChanged
        ? _edited.copyWith(colorHex: widget.animal.colorHex)
        : widget.animal;
  }

  /// **Task 11.268, item 1**: the only real defect among the eight. Name,
  /// status, sex, species and notes are a draft — [Individual.colorHex] is
  /// not, because item 2 makes it write immediately, so it is left out of
  /// this comparison on purpose. Read 2026-09-17: there was no guard at all,
  /// so editing the name and tapping back discarded it silently.
  bool get _hasUnsavedFieldEdits =>
      _edited.name != widget.animal.name ||
      _edited.status != widget.animal.status ||
      _edited.sex != widget.animal.sex ||
      _edited.species != widget.animal.species ||
      _edited.notes != widget.animal.notes;

  Future<bool> _confirmDiscardUnsavedEdits() async {
    final discard = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Discard changes?'),
        content: Text(
          'Your unsaved changes to ${widget.animal.name} will be lost.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Keep editing'),
          ),
          FilledButton(
            key: const ValueKey('discard_animal_edit'),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Discard'),
          ),
        ],
      ),
    );
    return discard ?? false;
  }

  Tag? _tagFor(String tagId) =>
      widget.tags.where((t) => t.tagId == tagId).firstOrNull;

  String _tagLabel(String tagId) {
    final tag = _tagFor(tagId);
    if (tag == null) {
      // A tag this project no longer holds — removed from the project
      // after it was worn. The link is still a true record of what happened,
      // so it is listed rather than hidden.
      return 'a tag this project no longer has';
    }
    return '${tag.frequencyMhz.toStringAsFixed(3)} MHz · ${tag.tagName}';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final now = _now;
    return PopScope(
      // **Task 11.268, item 1** — the only real defect among the eight:
      // there was no guard here at all, so editing the name and tapping
      // back silently discarded it. Colour is not part of this check; it
      // writes on tap (item 2) and is never a draft to lose.
      canPop: !_hasUnsavedFieldEdits,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        final discard = await _confirmDiscardUnsavedEdits();
        if (!discard) return;
        if (!context.mounted) return;
        Navigator.of(context).pop();
      },
      child: Scaffold(
        appBar: AppBar(
          title: Row(
            children: [
              TagColorSwatch(colorHex: _edited.colorHex),
              const SizedBox(width: 10),
              Expanded(child: Text(widget.animal.name)),
            ],
          ),
        ),
        body: ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
          children: [
            if (widget.writeRefusal != null) ...[
              DisabledReasonNote(reason: widget.writeRefusal),
              const SizedBox(height: 8),
            ],
            IndividualFields(
              // **`_edited`, not `widget.animal`** — task 11.248 moved colour
              // out of this widget, so this is what keeps a colour change
              // threaded through the next keystroke: `IndividualFields.edited`
              // preserves whatever colour it was handed, and this is the
              // up-to-date one.
              individual: _edited,
              readOnly: !widget.mayWrite,
              onChanged: (edited) => setState(() => _edited = edited),
            ),
            if (widget.mayWrite) ...[
              const SizedBox(height: 12),
              FilledButton(
                key: const ValueKey('animal_save'),
                onPressed: _edited.name.trim().isEmpty ? null : _save,
                child: const Text('Save'),
              ),
            ],
            const SizedBox(height: 24),
            Text('Tags', style: theme.textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(
              widget.deployments.isEmpty
                  ? 'No tag has been on this animal.'
                  : 'Every tag this animal has worn, and when.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 8),
            for (final d in orderedByCurrent(widget.deployments, now))
              _DeploymentRow(
                key: ValueKey('deployment_row_${d.deploymentId}'),
                deployment: d,
                label: _tagLabel(d.tagId),
                isCurrent: isCurrentDeployment(d, now),
                mayWrite: widget.mayWrite,
                onSetAttached: () => _setAttached(d),
                onSetRemoved: () => _setRemoved(d),
                onClearRemoved: () => _clearRemoved(d),
                onUnlink: () => _unlink(d),
              ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              key: const ValueKey('link_tag'),
              icon: const Icon(Icons.link),
              label: const Text('Link a tag'),
              onPressed: widget.mayWrite ? _linkTag : null,
            ),
            const SizedBox(height: 24),
            AnimalColorSection(
              colorHex: _edited.colorHex,
              readOnly: !widget.mayWrite,
              onSelect: _selectColor,
            ),
            const SizedBox(height: 24),
            OutlinedButton.icon(
              key: const ValueKey('individual_merge'),
              icon: const Icon(Icons.call_merge),
              label: const Text('Same animal as…'),
              onPressed: _mergeDisabledReason() == null ? _merge : null,
            ),
            DisabledReasonNote(reason: _mergeDisabledReason()),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              key: const ValueKey('delete_animal'),
              icon: const Icon(Icons.delete_outline),
              label: const Text('Delete animal'),
              style: OutlinedButton.styleFrom(
                foregroundColor: theme.colorScheme.error,
              ),
              onPressed: _deleteDisabledReason() == null ? _delete : null,
            ),
            DisabledReasonNote(reason: _deleteDisabledReason()),
          ],
        ),
      ),
    );
  }

  /// **Colour writes on tap** (task 11.268, item 2): picking a colour is a
  /// single act, not a draft finished with the rest of the fields, and it is
  /// live-read on the map legend. Written against [widget.animal] rather
  /// than [_edited] on purpose — a colour tap must not silently save
  /// whatever unsaved name/status/notes draft happens to be in progress.
  Future<void> _selectColor(String hex) async {
    setState(() => _edited = _edited.copyWith(colorHex: hex));
    final messenger = ScaffoldMessenger.of(context);
    final user = await ref.read(currentUserProvider.future);
    final deviceId = await ref.read(deviceIdProvider.future);
    final repo = await ref.read(individualRepositoryProvider.future);
    try {
      await repo.update(
        widget.animal.copyWith(colorHex: hex),
        actor: MutationActor.user(user.userId),
        deviceId: deviceId,
      );
    } on UnauthorizedMutation catch (e) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            e.refusalSentence(
              asViewer:
                  'Viewers cannot change an animal — ask an owner to change '
                  'your role.',
            ),
          ),
        ),
      );
      return;
    }
    refreshTagViews(ref, projectId: widget.projectId);
  }

  String? _mergeDisabledReason() {
    if (!widget.isOwner) {
      return 'Only a project owner can merge animals — it moves their tags.';
    }
    if (widget.others.isEmpty) {
      return 'There is no other animal on this project to merge with.';
    }
    return null;
  }

  /// **Task 11.255: deleting an animal is an owner's decision.**
  ///
  /// A contributor is not locked out of correcting a mistake — the note says
  /// what they can still do, because 11.244's reasoning (a contributor may
  /// fix an animal made by mistake) survives everywhere short of destroying
  /// its record: renaming and withdrawing its tags are still theirs.
  String? _deleteDisabledReason() {
    if (!widget.isOwner) {
      return 'Only a project owner can delete an animal. You can still rename '
          'it or withdraw its tags.';
    }
    return null;
  }

  Future<void> _save() async {
    final messenger = ScaffoldMessenger.of(context);
    final user = await ref.read(currentUserProvider.future);
    final deviceId = await ref.read(deviceIdProvider.future);
    final repo = await ref.read(individualRepositoryProvider.future);
    try {
      await repo.update(
        _edited,
        actor: MutationActor.user(user.userId),
        deviceId: deviceId,
      );
    } on UnauthorizedMutation catch (e) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            e.refusalSentence(
              asViewer:
                  'Viewers cannot change an animal — ask an owner to change '
                  'your role.',
            ),
          ),
        ),
      );
      return;
    }
    refreshTagViews(ref, projectId: widget.projectId);
  }

  /// **§5a, the whole of it.** The date defaults to today, the animal's open
  /// collar is closed on the same day, and **both changes are named before
  /// either is written.**
  ///
  /// **Task 11.321: one step from any tag.** Michael, 2026-09-30: linking
  /// took three places — add the tag to the Tag Library, copy it into the
  /// project, then link it here. The picker now offers, in order, this
  /// project's free tags, the Tag Library's tags the project does not hold
  /// (copied in as the link is written, in the same write), and *New tag…*.
  /// The date, the confirmation and the deployment rules are the same for
  /// all three.
  Future<void> _linkTag() async {
    // Which collars are free at that date — a collar already on an animal
    // then is not offered, because linking it would be refused by the
    // interlock a moment later. **Offering it and then refusing would be a
    // pre-check stricter than the write in the wrong direction**: it hides
    // nothing, it just wastes the person's time.
    final now = _now;
    final attached = deploymentDateFor(now, _zone);
    // Asked at the instant, not the day: a collar that came off earlier
    // today is free to go on at this moment, and the swap the link writes
    // will carry this moment (design §4a rule 2, task 11.263).
    final busy = tagIdsOnAnAnimalAt(
      widget.allDeployments,
      now,
      zone: _zone,
    );
    final free = [
      for (final t in widget.tags)
        if (!busy.contains(t.tagId)) t,
    ];
    // A library tag the project does not hold has no deployment here, so
    // it is free by construction.
    final fromLibrary = libraryEntriesNotOnProject(widget.library, widget.tags);

    final choice = await showDialog<_LinkChoice>(
      context: context,
      builder: (context) => _LinkTagPicker(
        animalName: widget.animal.name,
        free: free,
        fromLibrary: fromLibrary,
      ),
    );
    if (choice == null || !mounted) return;

    final String tagId;
    final String tagName;
    final TagToAdd? adding;
    switch (choice) {
      case _ProjectTagChoice(:final tag):
        tagId = tag.tagId;
        tagName = tag.tagName;
        adding = null;
      case _LibraryTagChoice(:final entry):
        tagId = const Uuid().v4();
        tagName = entry.tagName;
        adding = LibraryTagToAdd(entry);
      case _NewTagChoice():
        final created = await _newTagForLink();
        if (created == null || !mounted) return;
        tagId = created.tag.tagId;
        tagName = created.tag.tagName;
        // Task 11.324: a Tag ID the project already has links that tag,
        // exactly as if it had been picked from the list, unless the person
        // chose *Create anyway*.
        adding = created.isNew ? NewTagToAdd(created.tag) : null;
    }

    final database = await ref.read(appDatabaseProvider.future);
    if (!mounted) return;
    final linking = DeploymentLinking(database.raw);
    final LinkPlan plan;
    try {
      plan = await linking.plan(
        projectId: widget.projectId,
        tagId: tagId,
        individualId: widget.animal.individualId,
        attachedDate: attached,
        timeZone: _zone,
      );
    } on ArgumentError {
      return;
    }
    if (!mounted) return;

    final closingTag = plan.closing == null
        ? null
        : _tagFor(plan.closing!.tagId);
    final confirmed = await showDialog<LinkPlan>(
      context: context,
      builder: (context) => _LinkConfirmationDialog(
        plan: plan,
        tagName: tagName,
        copied: adding is LibraryTagToAdd,
        animalName: widget.animal.name,
        closingTagName:
            closingTag?.tagName ?? (plan.closing == null ? null : 'other tag'),
        now: _now,
        // Task 11.322: the date can be changed, and what a link does depends
        // on it (whether it is a swap, which collar comes off), so changing it
        // asks the same question again for the new day.
        replan: (day) => linking.plan(
          projectId: widget.projectId,
          tagId: tagId,
          individualId: widget.animal.individualId,
          attachedDate: day,
          timeZone: _zone,
        ),
      ),
    );
    if (confirmed == null || !mounted) return;
    if (!await _confirmLinkReattribution(
      confirmed,
      tagId: tagId,
      tagName: tagName,
      closingTagName: closingTag?.tagName ?? 'the other tag',
    )) {
      return;
    }
    if (!mounted) return;

    final messenger = ScaffoldMessenger.of(context);
    final user = await ref.read(currentUserProvider.future);
    final deviceId = await ref.read(deviceIdProvider.future);
    try {
      await linking.apply(
        confirmed,
        actor: MutationActor.user(user.userId),
        deviceId: deviceId,
        adding: adding,
      );
    } on OverlappingDeployment catch (e) {
      // The interlock, refused. It should not fire on this path — the
      // closing step, stamped with the same instant the new one opens, is
      // what makes the handover overlap by nothing — so reaching here means
      // the collar is on a *different* animal, or a sync delivered
      // something that broke the rule.
      messenger.showSnackBar(SnackBar(content: Text(e.message)));
      return;
    } on UnauthorizedMutation catch (e) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            e.refusalSentence(
              asViewer:
                  'Viewers cannot say which animal wears a tag — ask an '
                  'owner to change your role.',
            ),
          ),
        ),
      );
      return;
    }
    refreshTagViews(ref, projectId: widget.projectId);
  }

  /// *New tag…* from the link picker: the ordinary tag form, without its
  /// project choice (the tag goes on this animal's project) and without
  /// colour (colour is the animal's). The near-duplicate warning runs as it
  /// does everywhere a tag is created. Returns the tag to create, unwritten —
  /// [DeploymentLinking.apply] writes it with the link, or not at all — or,
  /// with `isNew` false, the project's existing tag with that Tag ID, which
  /// the person chose to use instead (task 11.324).
  Future<({Tag tag, bool isNew})?> _newTagForLink() async {
    final result = await showDialog<TagEditResult>(
      context: context,
      builder: (context) => const TagEditDialog(
        initialColorHex: TagColorPalette.noIndividual,
        showColor: false,
        offerProject: false,
      ),
    );
    if (result == null || !mounted) return null;
    final decision = await checkNewTagAgainstExisting(
      context,
      ref,
      frequencyMhz: result.draft.frequencyMhz,
      tagName: result.draft.tagName,
      projectId: widget.projectId,
    );
    if (!mounted) return null;
    switch (decision) {
      case GoBackFromNewTag():
        return null;
      case UseExistingTag(:final tag):
        return (tag: tag, isNew: false);
      case CreateNewTag():
        break;
    }
    final user = await ref.read(currentUserProvider.future);
    final deviceId = await ref.read(deviceIdProvider.future);
    return (
      tag: result.draft.newTag(
        tagId: const Uuid().v4(),
        projectId: widget.projectId,
        sync: SyncMeta.initial(
          now: _now,
          modifiedBy: user.userId,
          originDeviceId: deviceId,
        ),
      ),
      isNew: true,
    );
  }

  /// **§5a's own shape, reused for a handover neither editor can write
  /// alone** — task 11.270, design §6b's noted limit.
  ///
  /// [outgoing]'s removed date and [incoming]'s attached date both get the
  /// *same* instant, asked once and confirmed once, naming both collars —
  /// exactly the way the ordinary same-day swap confirmation does, and never
  /// prefilled with the wall clock, because [day] is a day nobody standing
  /// here now was there for. A refusal from the interlock rolls the whole
  /// write back, so it can never apply one row without the other.
  Future<void> _completeBareDayHandover({
    required Deployment outgoing,
    required Deployment incoming,
    required DateTime day,
    required String question,
    required String? zone,
  }) async {
    final choice = await _askDayOrTime(
      context,
      question: question,
      dayOnlyOffered: false,
      coveredDayLabel: formatLinkDate(day, zone),
    );
    if (choice == null || !mounted) return;
    final time = await showTimePicker(
      context: context,
      initialTime: _noTimeToOffer,
      helpText: question,
    );
    if (!mounted || time == null) return;
    final instant = swapInstantOn(day, time, zone);

    final outgoingTag = _tagFor(outgoing.tagId);
    final incomingTag = _tagFor(incoming.tagId);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Record both ends of this handover?'),
        content: Text(
          handoverConfirmationText(
            animalName: widget.animal.name,
            outgoingTagName: outgoingTag?.tagName ?? 'the other tag',
            incomingTagName: incomingTag?.tagName ?? 'the other tag',
            instant: instant,
            timeZone: zone,
          ),
        ),
        actions: [
          TextButton(
            key: const ValueKey('cancel_handover'),
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const ValueKey('confirm_handover'),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Record'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    final messenger = ScaffoldMessenger.of(context);
    final user = await ref.read(currentUserProvider.future);
    final deviceId = await ref.read(deviceIdProvider.future);
    final database = await ref.read(appDatabaseProvider.future);
    try {
      await DeploymentLinking(database.raw).applyHandover(
        HandoverPlan(outgoing: outgoing, incoming: incoming, instant: instant),
        actor: MutationActor.user(user.userId),
        deviceId: deviceId,
      );
    } on OverlappingDeployment catch (e) {
      // Rolled back whole — neither row was written.
      messenger.showSnackBar(SnackBar(content: Text(e.message)));
      return;
    } on UnauthorizedMutation catch (e) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            e.refusalSentence(
              asViewer:
                  'Viewers cannot change a tag record — ask an owner to '
                  'change your role.',
            ),
          ),
        ),
      );
      return;
    }
    refreshTagViews(ref, projectId: widget.projectId);
  }

  /// **Records, or corrects, the day a tag came off** — task 11.261 gave
  /// this an editor symmetric with [_setAttached]'s; before it, a removal
  /// recorded once could never be changed, and the only route to a
  /// different date was *Remove record*, which says the collar was never on
  /// this animal at all. The date picker starts at the row's own removed
  /// date (or today, for a first-time set) and cannot be set before the tag
  /// went on.
  ///
  /// **When the picked day is today, a choice follows** (design §4a rule 2,
  /// task 11.251, reworked by 11.261): *Day only*, *Set a time*, or *Cancel*
  /// — which now abandons the whole edit rather than meaning "the day
  /// alone", the way it read before. This is the outgoing end of Michael's
  /// swap — tag 2 comes off Kea here, and goes onto Marie through the §5a
  /// confirmation on her screen a few minutes later — and it is the end the
  /// confirmation cannot write, because it is a row on another animal that
  /// somebody has already dated. Without a time here, every bearing tag 2
  /// took today after the link is inside both deployments; with it, the
  /// morning's are Kea's and the afternoon's are Marie's. A past day gets no
  /// time offered: a time for a day nobody is standing in would be invented.
  ///
  /// **That last sentence held until task 11.265.** It was right while a
  /// bare-day pair on one day was tolerated and merely contested; since task
  /// 11.263 such a pair is *refused*. Now: **a time is offered on a past day
  /// exactly where another deployment already covers it** (design §6b) —
  /// never otherwise, and never prefilled with the wall clock, because
  /// nobody standing here now was there. See `_dayOnlyWouldOverlap` and
  /// `_noTimeToOffer`.
  ///
  /// **"Day only" is withheld where it would overlap** (task 11.263, design
  /// §6a). The interlock no longer tolerates any overlap, and a bare day
  /// covers the whole of itself — so if another deployment of this animal or
  /// this tag already covers some of today, recording today as a bare day
  /// would be refused a moment later. Rather than offer a choice that cannot
  /// succeed, the dialog offers only *Set a time* and *Cancel*, and says why.
  /// The time is prefilled with now, so it is a tap rather than a number.
  /// **The person who wanted to abandon still can**: *Cancel* on that dialog
  /// abandons the edit, and so does cancelling the time picker it opens —
  /// there is no bare day to fall back to when the bare day is what would
  /// have been refused. Where *Day only* is offered, cancelling the picker
  /// still falls back to the day, as 11.261 left it.
  ///
  /// **The interlock applies exactly as it does to [_setAttached]**, and so
  /// does the reattribution count — see [_confirmReattribution].
  Future<void> _setRemoved(Deployment deployment) async {
    final attached = deployment.attachedDate;
    final existing = deployment.removedDate;
    final now = _now;
    // Task 11.331: this row's days are read in its own zone — the one it was
    // written in, which a later change to the project's zone does not move.
    final zone = deployment.timeZone;
    final picked = await showDatePicker(
      context: context,
      initialDate: existing != null
          ? fieldCalendarDate(existing, zone)
          : fieldCalendarDate(now, zone),
      firstDate: attached == null
          ? DateTime(2000)
          : fieldCalendarDate(attached, zone),
      lastDate: DateTime(2100),
      // **Task 11.268, item 5**: the floor is correct — a collar cannot
      // come off before it went on — and it was silent about why. Read
      // 2026-09-17: a greyed calendar with no reason reads as a defect.
      helpText: attached == null
          ? 'When did the tag come off?'
          : 'When did the tag come off? Not before it went on, '
                '${formatLinkDate(attached, zone)}',
    );
    if (picked == null || !mounted) return;
    var removed = fieldDayStart(picked, zone);
    final isToday = removed.isAtSameMomentAs(deploymentDateFor(now, zone));
    if (isToday) {
      final dayOnlyOffered = !_dayOnlyWouldOverlap(deployment, removed);
      final choice = await _askDayOrTime(
        context,
        question: 'When did the tag come off?',
        dayOnlyOffered: dayOnlyOffered,
        coveredDayLabel: 'today',
      );
      if (choice == null || !mounted) return;
      if (choice == _DayOrTimeChoice.pickTime) {
        final time = await showTimePicker(
          context: context,
          initialTime: TimeOfDay.fromDateTime(fieldWallClock(now, zone)),
          helpText: 'When did the tag come off?',
        );
        if (!mounted) return;
        if (time == null) {
          // Cancelling the time picker itself (as opposed to the choice
          // above) falls back to the day alone where the day was on offer;
          // where it was not, there is nothing honest to fall back to and
          // the edit is abandoned.
          if (!dayOnlyOffered) return;
        } else {
          // Accepted as offered: the instant to the second, not the minute
          // it started (see [swapInstantNow]). Changed: the minute they
          // chose.
          removed = time == TimeOfDay.fromDateTime(fieldWallClock(now, zone))
              ? swapInstantNow(removed, now, zone)
              : swapInstantOn(removed, time, zone);
        }
      }
    } else if (_dayOnlyWouldOverlap(deployment, removed)) {
      // **The hole task 11.265 closes** (design §6b): a past day that
      // already overlaps another deployment can never be recorded as a bare
      // day, and until now nothing on a past day offered a time either. No
      // "Day only" to fall back to — that is exactly what would be
      // refused — and never prefilled with the wall clock: the person
      // standing here now was not there. See `_noTimeToOffer`.
      //
      // **The deadlock task 11.270 closes**: when the conflict is this
      // animal's own bare-day attach on the same day, a single time on this
      // row alone cannot escape it either — see
      // `DeploymentLinking.bareDayHandoverPartner`.
      final partner = DeploymentLinking.bareDayHandoverPartner(
        widget.allDeployments,
        edited: deployment,
        editingAttached: false,
        day: removed,
      );
      if (partner != null) {
        await _completeBareDayHandover(
          outgoing: deployment,
          incoming: partner,
          day: removed,
          question: 'When did the tag come off?',
          zone: zone,
        );
        return;
      }
      final choice = await _askDayOrTime(
        context,
        question: 'When did the tag come off?',
        dayOnlyOffered: false,
        coveredDayLabel: formatLinkDate(removed, zone),
      );
      if (choice == null || !mounted) return;
      final time = await showTimePicker(
        context: context,
        initialTime: _noTimeToOffer,
        helpText: 'When did the tag come off?',
      );
      if (!mounted) return;
      if (time == null) return;
      removed = swapInstantOn(removed, time, zone);
    }

    if (!mounted) return;
    if (!await _confirmReattribution(deployment, removed)) return;
    if (!mounted) return;
    await _writeRemoved(deployment, removed);
  }

  /// **Whether recording [deployment] as removed on the bare day [day] would
  /// be refused by the interlock** — the pre-check behind withholding *Day
  /// only* on today (task 11.263) and behind offering a time on a past day
  /// (task 11.265).
  ///
  /// Asks the write's own arithmetic, `DeploymentInterlock.conflictFor`, on
  /// the row as it would be written, against every other deployment on the
  /// project — the same list the write reads. A pre-check may be more
  /// permissive than the write it precedes and never stricter; this one is
  /// the write, so it is neither.
  bool _dayOnlyWouldOverlap(Deployment deployment, DateTime day) =>
      DeploymentInterlock.conflictFor(
        deployment.copyWith(removedDate: day).interval,
        widget.allDeployments.map((d) => d.interval),
      ) !=
      null;

  /// **The attached-date sibling of [_dayOnlyWouldOverlap]** — task 11.265.
  /// Correcting a tag's attached date to a bare day is the other half of a
  /// past-day handover: collar 1's removal and collar 2's attach both land
  /// on the same day, and either one alone, checked against the row it
  /// would become, tells whether that day is already spoken for.
  bool _attachedDayWouldOverlap(Deployment deployment, DateTime day) =>
      DeploymentInterlock.conflictFor(
        deployment.copyWith(attachedDate: day).interval,
        widget.allDeployments.map((d) => d.interval),
      ) !=
      null;

  /// **"I recorded it off and it is still on her."** — one of the two edge
  /// cases task 11.261 asks be decided rather than discovered.
  ///
  /// **Decision: clearing is offered.** The only route today was *Remove
  /// record*, which says the collar was never on this animal — a different
  /// and destructive claim from "I was wrong about it coming off." Reopening
  /// the deployment is the honest undo, and the interlock is re-checked the
  /// same as any other edit: an animal may have picked up a different collar
  /// in the meantime, and this would put two open collars on her at once.
  Future<void> _clearRemoved(Deployment deployment) async {
    if (!await _confirmReattribution(deployment, null)) return;
    if (!mounted) return;
    await _writeRemoved(deployment, null);
  }

  /// **The count named before the write, the way §5a names the second row a
  /// link touches** — task 11.261. Moving or clearing a removed date
  /// re-attributes every bearing between the old end and the new one, which
  /// is the point (design §2), but it is a change to records the person did
  /// not open, and it is silent unless something says so first.
  Future<bool> _confirmReattribution(
    Deployment deployment,
    DateTime? newRemoved,
  ) async {
    final observations = await ref.read(observationRepositoryProvider.future);
    if (!mounted) return false;
    final tagObservations = await observations.findByProjectAndTag(
      widget.projectId,
      deployment.tagId,
    );
    if (!mounted) return false;
    final count = countReattributedBearings(
      deployment: deployment,
      newRemoved: newRemoved,
      tagBearingTimes: tagObservations.map((o) => o.timestampUtc),
    );
    if (count == 0) return true;
    final noun = count == 1 ? '1 bearing' : '$count bearings';
    return _askReattribution(
      '$noun taken on ${_tagLabel(deployment.tagId)} between the old and '
      'new dates will now be credited to a different animal.',
    );
  }

  /// **The same warning for a back-dated link** — task 11.322. Michael: reuse
  /// the existing "This changes which animal some bearings belong to" dialog
  /// when a back-date moves bearings. A link dated today asks nothing, as
  /// before; a link dated earlier counts what it moves (see
  /// [countLinkReattributions]) and names both directions in one dialog.
  Future<bool> _confirmLinkReattribution(
    LinkPlan plan, {
    required String tagId,
    required String tagName,
    required String closingTagName,
  }) async {
    if (!deploymentDateFor(
      plan.attachedDate,
      plan.timeZone,
    ).isBefore(deploymentDateFor(_now, plan.timeZone))) {
      return true;
    }
    final observations = await ref.read(observationRepositoryProvider.future);
    if (!mounted) return false;
    final onNew = await observations.findByProjectAndTag(
      widget.projectId,
      tagId,
    );
    final closing = plan.closing;
    final onOld = closing == null
        ? const <Observation>[]
        : await observations.findByProjectAndTag(
            widget.projectId,
            closing.tagId,
          );
    if (!mounted) return false;
    final counts = countLinkReattributions(
      plan: plan,
      newTagBearingTimes: onNew.map((o) => o.timestampUtc),
      closingTagBearingTimes: onOld.map((o) => o.timestampUtc),
    );
    if (counts.credited == 0 && counts.uncredited == 0) return true;
    String bearings(int n) => n == 1 ? '1 bearing' : '$n bearings';
    final since = formatLinkDate(plan.attachedDate, plan.timeZone);
    final animal = widget.animal.name;
    return _askReattribution([
      if (counts.credited > 0)
        '${bearings(counts.credited)} taken on $tagName since $since will '
            'now be credited to $animal.',
      if (counts.uncredited > 0)
        '${bearings(counts.uncredited)} taken on $closingTagName since '
            '$since will no longer be credited to $animal.',
    ].join('\n\n'));
  }

  Future<bool> _askReattribution(String body) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('This changes which animal some bearings belong to'),
        content: Text(body),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const ValueKey('confirm_reattribution'),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Continue'),
          ),
        ],
      ),
    );
    return confirmed ?? false;
  }

  Future<void> _writeRemoved(Deployment deployment, DateTime? removed) async {
    final messenger = ScaffoldMessenger.of(context);
    final user = await ref.read(currentUserProvider.future);
    final deviceId = await ref.read(deviceIdProvider.future);
    final repo = await ref.read(deploymentRepositoryProvider.future);
    final error = await writeRemovedDate(
      repo: repo,
      deployment: deployment,
      removed: removed,
      actor: MutationActor.user(user.userId),
      deviceId: deviceId,
    );
    if (error != null) {
      messenger.showSnackBar(SnackBar(content: Text(error)));
      return;
    }
    refreshTagViews(ref, projectId: widget.projectId);
  }

  /// **Corrects the day a tag went on** — task 11.248. Michael's two cases:
  /// entering a season's links in a batch and dating them afterwards, and a
  /// plain typo. The default at link time still fills in today (§5a); this
  /// is the way to fix it once it is wrong.
  ///
  /// **The interlock applies exactly as it does to a link.** Back-dating can
  /// create an overlap that did not exist a moment ago, and [repo.update]
  /// re-checks it — see [DeploymentRepository.update].
  ///
  /// **A corrected day is a day.** If the row carried a swap time (task
  /// 11.251) the correction replaces it with the picked date at midnight: a
  /// time recorded for one day says nothing about another, and a person
  /// fixing the date has said the row was wrong.
  ///
  /// **Re-picking the *same* day keeps the row's own instant** (task
  /// 11.264). Until then it dropped the time too, on the reasoning that the
  /// day would merely become *contested* against its same-day neighbour —
  /// which was true while the interlock tolerated a day of overlap and
  /// stopped being true with task 11.263: a bare day covers the whole of
  /// itself, so the re-picked start overlapped the outgoing collar's morning
  /// and a correct row was refused for an edit that changed nothing. The
  /// picker offers days, not times, so a person who picks the day the row
  /// already has has said nothing about its time and it is left alone. The
  /// write still goes through the interlock — a row that was already wrong
  /// is still refused, which is what `animals_screen_test.dart` watches.
  ///
  /// **The other half of a past-day handover** (task 11.265, design §6b):
  /// when the picked day is not the row's own and already overlaps another
  /// deployment as a bare day, a time is offered instead of writing a day
  /// that would only be refused — never prefilled, the same as
  /// [_setRemoved]'s own past-day branch. Unchanged for *today* and for any
  /// day that does not overlap: this editor keeps writing a bare day there,
  /// as it always has.
  Future<void> _setAttached(Deployment deployment) async {
    final attached = deployment.attachedDate;
    final removed = deployment.removedDate;
    // Task 11.331: read and written in this row's own zone.
    final zone = deployment.timeZone;
    final picked = await showDatePicker(
      context: context,
      initialDate: fieldCalendarDate(attached ?? _now, zone),
      firstDate: DateTime(2000),
      lastDate: removed == null
          ? DateTime(2100)
          : fieldCalendarDate(removed, zone),
    );
    if (picked == null || !mounted) return;
    final day = fieldDayStart(picked, zone);
    final sameDay =
        attached != null &&
        deploymentDateFor(attached, zone).isAtSameMomentAs(day);

    DateTime newAttached;
    if (sameDay) {
      newAttached = attached;
    } else if (_attachedDayWouldOverlap(deployment, day)) {
      // **The deadlock task 11.270 closes** (design §6b's noted limit): if
      // the conflict is with this animal's own bare-day removal on the same
      // day, a single time on this row alone can never escape it — the
      // other row's bare day still claims the whole 24 hours. Ask for both
      // in one confirmation instead of one that would only be refused.
      final partner = DeploymentLinking.bareDayHandoverPartner(
        widget.allDeployments,
        edited: deployment,
        editingAttached: true,
        day: day,
      );
      if (partner != null) {
        await _completeBareDayHandover(
          outgoing: partner,
          incoming: deployment,
          day: day,
          question: 'When did the tag go on?',
          zone: zone,
        );
        return;
      }
      final choice = await _askDayOrTime(
        context,
        question: 'When did the tag go on?',
        dayOnlyOffered: false,
        coveredDayLabel: formatLinkDate(day, zone),
      );
      if (choice == null || !mounted) return;
      final time = await showTimePicker(
        context: context,
        initialTime: _noTimeToOffer,
        helpText: 'When did the tag go on?',
      );
      if (!mounted) return;
      if (time == null) return;
      newAttached = swapInstantOn(day, time, zone);
    } else {
      newAttached = day;
    }

    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    final user = await ref.read(currentUserProvider.future);
    final deviceId = await ref.read(deviceIdProvider.future);
    final repo = await ref.read(deploymentRepositoryProvider.future);
    try {
      await repo.update(
        deployment.copyWith(attachedDate: newAttached),
        actor: MutationActor.user(user.userId),
        deviceId: deviceId,
      );
    } on OverlappingDeployment catch (e) {
      // Watched red — see `animals_screen_test.dart`: back-dating this row's
      // attached date into another deployment's interval is refused with the
      // same interlock sentence a link gets.
      messenger.showSnackBar(SnackBar(content: Text(e.message)));
      return;
    } on UnauthorizedMutation catch (e) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            e.refusalSentence(
              asViewer:
                  'Viewers cannot change a tag record — ask an owner to '
                  'change your role.',
            ),
          ),
        ),
      );
      return;
    }
    refreshTagViews(ref, projectId: widget.projectId);
  }

  /// **Withdraws a link, which is not the same as taking a collar off.**
  /// The confirmation says which: a removed date records that the collar was
  /// worn and came off; withdrawing says it was never on this animal.
  Future<void> _unlink(Deployment deployment) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('This tag was never on this animal?'),
        content: Text(
          '${_tagLabel(deployment.tagId)} will no longer be recorded as having '
          'been on ${widget.animal.name} at all.\n\n'
          'If it was on and came off, set a removed date instead. Bearings '
          'do not move either way.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const ValueKey('confirm_unlink'),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    final messenger = ScaffoldMessenger.of(context);
    final user = await ref.read(currentUserProvider.future);
    final deviceId = await ref.read(deviceIdProvider.future);
    final repo = await ref.read(deploymentRepositoryProvider.future);
    try {
      await repo.unlink(
        deployment.deploymentId,
        projectId: widget.projectId,
        actor: MutationActor.user(user.userId),
        deviceId: deviceId,
      );
    } on UnauthorizedMutation catch (e) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            e.refusalSentence(
              asViewer:
                  'Viewers cannot change a tag record — ask an owner to '
                  'change your role.',
            ),
          ),
        ),
      );
      return;
    }
    refreshTagViews(ref, projectId: widget.projectId);
  }

  /// **"This animal is the same as…"** — task 11.241's act, re-pointing
  /// deployments since 11.243.
  Future<void> _merge() async {
    final keep = await showDialog<Individual>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text('${widget.animal.name} is the same animal as…'),
        children: [
          for (final other in widget.others)
            SimpleDialogOption(
              key: ValueKey('merge_into_${other.individualId}'),
              onPressed: () => Navigator.of(context).pop(other),
              child: Row(
                children: [
                  TagColorSwatch(colorHex: other.colorHex),
                  const SizedBox(width: 10),
                  Expanded(child: Text(other.name)),
                ],
              ),
            ),
        ],
      ),
    );
    if (keep == null || !mounted) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Merge ${widget.animal.name} into ${keep.name}?'),
        content: Text(
          mergeConfirmationText(
            absorbName: widget.animal.name,
            keepName: keep.name,
            collarsMoving: widget.deployments.length,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const ValueKey('confirm_merge'),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Merge'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    final user = await ref.read(currentUserProvider.future);
    final deviceId = await ref.read(deviceIdProvider.future);
    final database = await ref.read(appDatabaseProvider.future);
    final int moved;
    try {
      moved = await IndividualMerge(database.raw).merge(
        projectId: widget.projectId,
        keepId: keep.individualId,
        absorbId: widget.animal.individualId,
        actor: MutationActor.user(user.userId),
        deviceId: deviceId,
      );
    } on OverlappingDeployment catch (e) {
      // Declaring two animals one can put two open collars on a single
      // animal, which §6 forbids. The merge rolls back whole.
      messenger.showSnackBar(SnackBar(content: Text(e.message)));
      return;
    } on UnauthorizedMutation {
      messenger.showSnackBar(
        const SnackBar(
          content: Text(
            'Only a project owner can merge animals — ask an owner.',
          ),
        ),
      );
      return;
    }
    refreshTagViews(ref, projectId: widget.projectId);
    final tags = moved == 1 ? '1 tag' : '$moved tags';
    messenger.showSnackBar(
      SnackBar(
        content: Text('${keep.name} now has $tags more. No records moved.'),
      ),
    );
    // This animal is gone; the screen it was on has nothing left to show.
    if (navigator.canPop()) navigator.pop();
  }

  /// **Deleting an animal, which task 11.241 refused to offer.**
  ///
  /// That refusal rested on tags not being inventory: a delete would have
  /// left collars with no animal, which was then a question for a person.
  /// A collar with no animal is the ordinary state of a transmitter now
  /// (design §1), so this is an ordinary thing to do.
  Future<void> _delete() async {
    final n = widget.deployments.length;
    final tags = n == 1 ? 'Its 1 tag record' : 'Its $n tag records';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Delete ${widget.animal.name}?'),
        content: Text(
          n == 0
              ? '${widget.animal.name}\'s record — name, color, status, '
                    'species, sex and notes — is removed. That cannot be undone.'
              : '$tags will be removed, and the tags go back to being '
                    'on nobody. No bearing moves.\n\n'
                    '${widget.animal.name}\'s own record — name, color, status, '
                    'species, sex and notes — goes too. That cannot be '
                    'undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const ValueKey('confirm_delete_animal'),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    final user = await ref.read(currentUserProvider.future);
    final deviceId = await ref.read(deviceIdProvider.future);
    final database = await ref.read(appDatabaseProvider.future);
    try {
      await DeploymentLinking(database.raw).deleteAnimal(
        projectId: widget.projectId,
        individualId: widget.animal.individualId,
        actor: MutationActor.user(user.userId),
        deviceId: deviceId,
      );
    } on UnauthorizedMutation {
      // The button is already gated on `isOwner` — this is the race between
      // opening the confirmation and a role change landing mid-dialog, not
      // the ordinary path. Same flat message `_merge` uses for the identical
      // shape.
      messenger.showSnackBar(
        const SnackBar(
          content: Text(
            'Only a project owner can delete an animal — ask an '
            'owner.',
          ),
        ),
      );
      return;
    }
    refreshTagViews(ref, projectId: widget.projectId);
    if (navigator.canPop()) navigator.pop();
  }
}

/// One tag this animal has worn: what it is, when it went on, when it came
/// off, and the things a person can do to that record.
class _DeploymentRow extends StatelessWidget {
  const _DeploymentRow({
    super.key,
    required this.deployment,
    required this.label,
    required this.isCurrent,
    required this.mayWrite,
    required this.onSetAttached,
    required this.onSetRemoved,
    required this.onClearRemoved,
    required this.onUnlink,
  });

  final Deployment deployment;
  final String label;

  /// **The tag on this animal today** — task 11.248. Bold, plus a short word
  /// rather than a colour on its own (Michael's standing rule: colour never
  /// carries meaning alone in this app).
  final bool isCurrent;
  final bool mayWrite;
  final VoidCallback onSetAttached;
  final VoidCallback onSetRemoved;
  final VoidCallback onClearRemoved;
  final VoidCallback onUnlink;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final attached = deployment.attachedDate;
    final removed = deployment.removedDate;
    // **The null attached date is spelled out rather than left blank.** A
    // deployment with no attached date attributes no bearings at all (design
    // §4), and a row that simply showed nothing there would leave somebody to
    // discover that from a map with fewer rays on it than they expected.
    // A swap time shows on the row it decides (task 11.251) — a date-only
    // end reads exactly as it always has.
    final when = attached == null
        ? 'No attached date — this tag is on no bearings'
        : removed == null
        ? 'On since ${formatLinkInstant(attached, deployment.timeZone)}'
        : '${formatLinkInstant(attached, deployment.timeZone)} to '
              '${formatLinkInstant(removed, deployment.timeZone)}';
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    label,
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: isCurrent ? FontWeight.bold : null,
                    ),
                  ),
                ),
                if (isCurrent)
                  Text(
                    'Current',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.primary,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 2),
            Text(
              when,
              style: theme.textTheme.bodySmall?.copyWith(
                color: attached == null
                    ? theme.colorScheme.error
                    : theme.colorScheme.onSurfaceVariant,
              ),
            ),
            // **A `⋮` menu, not an `OverflowBar`** — task 11.268, item 3. Four
            // buttons already did not fit a 6.1-inch phone (task 11.248 had
            // to make the `OverflowBar` wrap; Michael watched the fourth run
            // off the right edge on 2026-09-15). A menu fits at any width and
            // buys the room items 4 and 5 below both need for honest labels.
            // `animals_screen_test.dart` opens it and measures the closed
            // row at phone width.
            if (mayWrite)
              Align(
                alignment: Alignment.centerRight,
                child: PopupMenuButton<void>(
                  key: ValueKey('deployment_menu_${deployment.deploymentId}'),
                  icon: const Icon(Icons.more_vert),
                  itemBuilder: (context) => [
                    PopupMenuItem(
                      key: ValueKey('set_attached_${deployment.deploymentId}'),
                      onTap: onSetAttached,
                      child: Text(
                        attached == null
                            ? 'Set attached date'
                            : 'Edit attached date',
                      ),
                    ),
                    PopupMenuItem(
                      key: ValueKey('set_removed_${deployment.deploymentId}'),
                      onTap: onSetRemoved,
                      child: Text(
                        removed == null
                            ? 'Set removed date'
                            : 'Edit removed date',
                      ),
                    ),
                    if (removed != null)
                      PopupMenuItem(
                        key: ValueKey(
                          'clear_removed_${deployment.deploymentId}',
                        ),
                        onTap: onClearRemoved,
                        child: const Text('Clear removed date'),
                      ),
                    // **The label agrees with its own confirmation** — task
                    // 11.268, item 4. The confirmation says the tag "will no
                    // longer be recorded as having been on [animal] at all",
                    // which is what withdrawing a link means; "Remove
                    // record" read as ambiguous to Michael and "remove tag
                    // from record" no less so.
                    PopupMenuItem(
                      key: ValueKey('unlink_${deployment.deploymentId}'),
                      onTap: onUnlink,
                      child: const Text('This tag was never on this animal'),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// What the person picked in [_LinkTagPicker] — task 11.321.
sealed class _LinkChoice {
  const _LinkChoice();
}

final class _ProjectTagChoice extends _LinkChoice {
  const _ProjectTagChoice(this.tag);
  final Tag tag;
}

final class _LibraryTagChoice extends _LinkChoice {
  const _LibraryTagChoice(this.entry);
  final TagLibraryEntry entry;
}

final class _NewTagChoice extends _LinkChoice {
  const _NewTagChoice();
}

/// **Which tag goes on this animal** — this project's free tags, then the
/// Tag Library's, then *New tag…* (task 11.321, Michael's order). A heading
/// with nothing under it is left out.
class _LinkTagPicker extends StatelessWidget {
  const _LinkTagPicker({
    required this.animalName,
    required this.free,
    required this.fromLibrary,
  });

  final String animalName;
  final List<Tag> free;
  final List<TagLibraryEntry> fromLibrary;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    Widget heading(String text) => Padding(
      padding: const EdgeInsets.fromLTRB(24, 12, 24, 4),
      child: Text(
        text,
        style: theme.textTheme.labelLarge?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
    String label(double mhz, String name) =>
        '${mhz.toStringAsFixed(3)} MHz · $name';
    return SimpleDialog(
      title: Text('Which tag goes on $animalName?'),
      children: [
        if (free.isNotEmpty) heading('On this project'),
        for (final tag in free)
          SimpleDialogOption(
            key: ValueKey('link_tag_${tag.tagId}'),
            onPressed: () => Navigator.of(context).pop(_ProjectTagChoice(tag)),
            child: Text(label(tag.frequencyMhz, tag.tagName)),
          ),
        if (fromLibrary.isNotEmpty) heading('From your Tag Library'),
        for (final entry in fromLibrary)
          SimpleDialogOption(
            key: ValueKey('link_library_${entry.tagId}'),
            onPressed: () =>
                Navigator.of(context).pop(_LibraryTagChoice(entry)),
            child: Text(label(entry.frequencyMhz, entry.tagName)),
          ),
        const Divider(),
        SimpleDialogOption(
          key: const ValueKey('link_new_tag'),
          onPressed: () => Navigator.of(context).pop(const _NewTagChoice()),
          child: const Text('New tag…'),
        ),
      ],
    );
  }
}

/// **The §5a confirmation, and the swap time §4a adds to it** — task 11.251.
///
/// The sentence is [linkConfirmationText], composed from the plan it will
/// write. **On a swap ([LinkPlan.isSwap]) the plan is stamped with a time,
/// prefilled with now**, shown inside the sentence — *"attached 2026-09-15
/// 14:32"* — and changeable with one tap. Michael, 2026-09-15: *"It is extra
/// data entry but honestly this will likely never happen… If asking for a
/// time of the swap is needed to get around this issue so be it."* In the
/// field the swap and the tap are minutes apart, so this is a value to
/// accept rather than to type; the "Change time" button is for the person
/// who got to the truck an hour later.
///
/// **Pops the plan it confirmed**, so the write and the sentence cannot
/// disagree: the same object goes to `DeploymentLinking.apply`.
class _LinkConfirmationDialog extends StatefulWidget {
  const _LinkConfirmationDialog({
    required this.plan,
    required this.tagName,
    required this.animalName,
    required this.closingTagName,
    required this.now,
    required this.replan,
    this.copied = false,
  });

  final LinkPlan plan;
  final String tagName;

  /// Whether the tag comes from the Tag Library and is copied in with the
  /// link — said here because this is the moment the person reads (§2.5).
  final bool copied;
  final String animalName;
  final String? closingTagName;
  final DateTime now;

  /// The plan for the same link on another day (task 11.322).
  final Future<LinkPlan> Function(DateTime day) replan;

  @override
  State<_LinkConfirmationDialog> createState() =>
      _LinkConfirmationDialogState();
}

class _LinkConfirmationDialogState extends State<_LinkConfirmationDialog> {
  /// The plan for the chosen day, before any swap time is put on it.
  late LinkPlan _base;

  /// [_base] with the swap time, if it is a swap — what *Link* returns.
  late LinkPlan _plan;

  @override
  void initState() {
    super.initState();
    _base = widget.plan;
    // Composed from the plan's own day and now's time of day, so the instant
    // can never land on a different date from the one the plan was made for
    // — a confirmation opened at 23:59 and tapped at 00:01 still writes the
    // day it named.
    _plan = _base.isSwap
        ? _base.at(swapInstantNow(_base.attachedDate, widget.now, _zone))
        : _base;
  }

  /// The zone the new link is written in — the project's (task 11.331).
  String? get _zone => _base.timeZone;

  DateTime get _today => deploymentDateFor(widget.now, _zone);

  /// **Task 11.322: the date the tag went on, today unless changed.** Michael,
  /// 2026-09-30: a collar is sometimes entered a day or two after it went on,
  /// and the bearings in between must get the right animal.
  ///
  /// Nothing here is a new rule. The picker stops at today (a tag cannot go on
  /// tomorrow) and, where the animal is wearing a tag, at the day that tag
  /// went on — the same floor and the same reason *Edit removed date* gives,
  /// because the old tag comes off the day this one goes on and cannot come
  /// off before it went on. The interlock still has the last word when the
  /// link is written. **A swap on a past day asks for a time and offers noon,
  /// not the wall clock**: nobody standing here now was there.
  Future<void> _changeDate() async {
    final wearing = widget.plan.closing?.attachedDate;
    final wearingZone = widget.plan.closing?.timeZone;
    final picked = await showDatePicker(
      context: context,
      initialDate: fieldCalendarDate(_base.attachedDate, _zone),
      firstDate: wearing == null
          ? DateTime(2000)
          : fieldCalendarDate(wearing, wearingZone),
      lastDate: fieldCalendarDate(widget.now, _zone),
      helpText: wearing == null
          ? 'When did the tag go on?'
          : 'When did the tag go on? Not before the current tag went on, '
                '${formatLinkDate(wearing, wearingZone)}',
    );
    if (picked == null || !mounted) return;
    final day = fieldDayStart(picked, _zone);
    final plan = await widget.replan(day);
    if (!mounted) return;
    final LinkPlan next;
    if (!plan.isSwap) {
      next = plan;
    } else if (day.isAtSameMomentAs(_today)) {
      next = plan.at(swapInstantNow(day, widget.now, _zone));
    } else {
      final time = await showTimePicker(
        context: context,
        initialTime: _noTimeToOffer,
        helpText: 'When was the tag swapped?',
      );
      if (time == null || !mounted) return;
      next = plan.at(swapInstantOn(day, time, _zone));
    }
    setState(() {
      _base = plan;
      _plan = next;
    });
  }

  Future<void> _changeTime() async {
    final picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(
        fieldWallClock(_plan.attachedDate, _zone),
      ),
      helpText: 'When was the tag swapped?',
    );
    if (picked == null || !mounted) return;
    setState(() {
      _plan = _base.at(swapInstantOn(_base.attachedDate, picked, _zone));
    });
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('Link to ${widget.animalName}?'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            WentOnDateCard(
              key: const ValueKey('link_date'),
              label: 'Tag went on',
              date: _base.attachedDate,
              timeZone: _zone,
              isToday: deploymentDateFor(
                _base.attachedDate,
                _zone,
              ).isAtSameMomentAs(_today),
              onChange: _changeDate,
              buttonKey: const ValueKey('link_change_date'),
            ),
            const SizedBox(height: 12),
            Text(
              linkConfirmationText(
                tagName: widget.tagName,
                animalName: widget.animalName,
                attachedDate: _plan.attachedDate,
                closingTagName: widget.closingTagName,
                closingDate: _plan.closingDate,
                timeZone: _zone,
                closingTimeZone: _plan.closing?.timeZone,
              ),
            ),
            if (widget.copied) ...[
              const SizedBox(height: 12),
              const Text(
                'This project gets its own copy of the tag.',
                key: ValueKey('link_copies_tag'),
              ),
            ],
            if (_base.isSwap)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  key: const ValueKey('change_swap_time'),
                  onPressed: _changeTime,
                  icon: const Icon(Icons.schedule),
                  label: const Text('Change time'),
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          key: const ValueKey('cancel_link'),
          onPressed: () => Navigator.of(context).pop(null),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const ValueKey('confirm_link'),
          onPressed: () => Navigator.of(context).pop(_plan),
          child: const Text('Link'),
        ),
      ],
    );
  }
}

/// [day] at [time], **on the field's clock** ([zone], task 11.331; the
/// device's zone when null) — the instant a swap is recorded at when the
/// person **chose** the time. Whole minutes: that is what a time picker
/// offers and what the row shows.
DateTime swapInstantOn(DateTime day, TimeOfDay time, [String? zone]) {
  final d = fieldCalendarDate(day, zone);
  return fieldInstant(
    DateTime(d.year, d.month, d.day, time.hour, time.minute),
    zone,
  );
}

/// [day] at [now]'s time of day **to the second** — the instant a swap is
/// recorded at when the person accepted the time as offered.
///
/// Michael's device look, 2026-09-15: he took a bearing on B's collar, then
/// swapped B's collar minutes later, and the bearing drew grey. The prefill
/// went through `TimeOfDay`, which has no seconds, so a swap confirmed at
/// 14:32:50 was written as 14:32:00 — **earlier than a bearing taken at
/// 14:32:30**, which then fell after the collar left B and before it reached
/// A, and belonged to nobody. Rounding a swap *down* steals bearings from
/// the outgoing animal on exactly the day the time exists to protect; the
/// value shown on the row is still the minute, and the second is what makes
/// the ordering against the bearings true.
///
/// Read on the field's clock ([zone], task 11.331), like [swapInstantOn].
DateTime swapInstantNow(DateTime day, DateTime now, [String? zone]) {
  final d = fieldCalendarDate(day, zone);
  final t = fieldWallClock(now, zone);
  return fieldInstant(
    DateTime(d.year, d.month, d.day, t.hour, t.minute, t.second),
    zone,
  );
}

/// **"Day only", "Set a time", or abandon the edit** — task 11.261,
/// replacing the old time picker's *"(Cancel for the day only)"* helper
/// text. That wording was honest and backwards: cancelling read as
/// abandoning the action, and a person who genuinely wanted to abandon it
/// had nowhere to go. Here the three outcomes are three buttons, and a null
/// return is the only one that means "abandon".
///
/// **Widened by task 11.265** from the removal editor's own "today" choice
/// to [_setAttached] and to a past day: [question] is the dialog's title
/// ("...come off?" or "...go on?") and [coveredDayLabel] is what the
/// explanation names when [dayOnlyOffered] is false — *"today"*, or the
/// picked date. With [dayOnlyOffered] false the *Day only* button is not
/// built and the sentence says why: another collar already covers part of
/// [coveredDayLabel], so a bare day would overlap it and be refused. Two
/// buttons remain, *Cancel* and *Set a time*, and *Cancel* still abandons.
Future<_DayOrTimeChoice?> _askDayOrTime(
  BuildContext context, {
  required String question,
  required bool dayOnlyOffered,
  required String coveredDayLabel,
}) => showDialog<_DayOrTimeChoice>(
  context: context,
  builder: (context) => AlertDialog(
    title: Text(question),
    content: Text(
      dayOnlyOffered
          ? 'Record today as a whole day, or name the moment if another '
                'collar went on today too.'
          : 'Another collar already covers part of $coveredDayLabel, so '
                'this one needs a time — the moment it happened.',
    ),
    actions: [
      TextButton(
        key: const ValueKey('removed_day_or_time_cancel'),
        onPressed: () => Navigator.of(context).pop(null),
        child: const Text('Cancel'),
      ),
      if (dayOnlyOffered)
        TextButton(
          key: const ValueKey('removed_day_only'),
          onPressed: () => Navigator.of(context).pop(_DayOrTimeChoice.dayOnly),
          child: const Text('Day only'),
        ),
      FilledButton(
        key: const ValueKey('removed_pick_time'),
        onPressed: () => Navigator.of(context).pop(_DayOrTimeChoice.pickTime),
        child: const Text('Set a time'),
      ),
    ],
  ),
);

/// **The time offered when a person is asked to name one on a past day** —
/// task 11.265, design §6b. Midday, chosen only because [showTimePicker]
/// requires *some* initial value — never a stand-in for "now" the way the
/// swap-time picker's prefill is: on a past day there is no wall clock to
/// read, and prefilling one would be the app inventing a measurement.
/// *"Asking is not inventing. Prefilling is."* — the neutral hour is what
/// keeps this an ask.
const TimeOfDay _noTimeToOffer = TimeOfDay(hour: 12, minute: 0);
