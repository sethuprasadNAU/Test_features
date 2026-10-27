import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../../core/errors/guarded_write.dart';

import '../../../core/format/pulse_rate_format.dart';
import '../../../core/providers/active_selection_provider.dart';
import '../../../core/providers/app_context_provider.dart';
import '../../../core/providers/database_provider.dart';
import '../../../core/providers/device_id_provider.dart';
import '../../../core/providers/pulse_rate_unit_provider.dart';
import '../../../core/providers/tag_library_project_order_provider.dart';
import '../../../core/providers/tag_sort_provider.dart';
import '../../../core/providers/tag_view_refresh.dart';
import '../../../core/theme/design_tokens.dart';
import '../../../core/utils/natural_sort.dart';
import '../../../data/csv/tag_csv_commit.dart';
import '../../../data/csv/tag_csv_export.dart';
import '../../../data/csv/tag_csv_import.dart';
import '../../../data/models/project.dart';
import '../../../data/models/sync_meta.dart';
import '../../../data/models/tag_draft.dart';
import '../../../data/models/tag_fields.dart';
import '../../../data/models/tag_library_entry.dart';
import '../../../data/repositories/repository_providers.dart';
import '../../../data/repositories/tag_library_repository.dart';
import '../../../data/repositories/tag_repository.dart';
import '../../../data/repositories/tag_version_repository.dart';
import '../../../data/tags/library_groups.dart';
import '../../../widgets/load_failure.dart';
import '../../../widgets/near_duplicate_tag_dialog.dart';
import '../../../widgets/tag_edit_intent_dialog.dart';
import '../../../widgets/tag_form.dart';
import '../../../core/errors/failure_message.dart';
import '../../../data/repositories/mutation_authorization.dart';

/// What a person is told when the tag form cannot be opened (task 11.235).
/// Nothing was being saved yet, so nothing is lost; the sentence says so,
/// names a next step, and asserts no cause.
const String kTagFormCouldNotOpenMessage =
    'Could not open the tag form. Try again, and report it if this keeps '
    'happening.';

/// **This device's personal tag library** (design doc §8): view, add and edit
/// the transmitters this person has, plus bulk CSV import with a
/// preview/dry-run before commit (technical doc TC:265).
///
/// **On screen it is "Tag Library", not "Tag Database" (task 11.245)** —
/// the More menu also carries `More → Tags`, this project's own copies (task
/// 11.219), and two names that both said "database" read as one set to a
/// person scanning the menu. The class and file keep their old names; only
/// the words a person reads changed.
///
/// ## It is the library, not a project's tags — task 11.219
///
/// It used to list every `Tags` row on the device, because a tag was a global
/// record several projects pointed at. Since copy-on-add a project holds its
/// **own copy** of a collar, so "every tag row on the device" is a list with
/// one line per project per collar — a list of copies, which is not a list of
/// anything a person owns. What this screen shows instead is
/// `Tag_Library`: one row per transmitter, device-local, never synced.
///
/// **Two consequences worth stating, because both look like defects.**
///
/// 1. **Nothing here is role-gated.** A library entry is this device's own
///    record of its own equipment: it is in no project, it reaches no server,
///    and no archive carries it, so there is no role to resolve and nobody to
///    be advisory towards. A `viewer` on somebody else's project may keep
///    their own transmitter list, and always could have — what they could not
///    do was edit *a project's* tag, and that is still true. The owner-only
///    refusal moved to where the project's copy is edited, on `More → Tags`,
///    with the same words and the same `tag_edit_not_permitted` key.
/// 2. **Editing here reaches no project.** That is the whole point of
///    copy-on-add and it is the direction that surprises people, so the form
///    says so whenever any project on this device holds a copy — a count,
///    never the projects' names (§2.5: a device can hold a project the person
///    is only a viewer on, and naming it would disclose that it exists).
///
/// Adding a tag here still offers to put it straight into a project, which is
/// a **copy** rather than a link.
class TagDatabaseScreen extends ConsumerStatefulWidget {
  const TagDatabaseScreen({super.key});

  @override
  ConsumerState<TagDatabaseScreen> createState() => _TagDatabaseScreenState();
}

class _TagDatabaseScreenState extends ConsumerState<TagDatabaseScreen> {
  /// **Task 11.288.** The entries currently checked for a batch delete.
  /// Empty means "not selecting" — there is no separate mode flag, so the
  /// screen can never disagree with itself about whether it is one.
  final Set<String> _selected = {};

  bool get _selectionMode => _selected.isNotEmpty;

  /// **Task 11.321.** The project groups the person has opened. Every group
  /// starts closed (Michael: he does not want to see every tag at once).
  final Set<String> _expanded = {};

  /// **Task 11.322: the search box.** Matching rows show under every heading
  /// and those headings open; clearing it puts back what was open, because
  /// [_expanded] is not touched while searching.
  final TextEditingController _searchController = TextEditingController();
  String _query = '';

  bool get _searching => _query.trim().isNotEmpty;

  /// Headings the person closed again while searching. A search opens every
  /// heading it finds something in; this is the way to close one anyway, and
  /// it starts over with each new search.
  final Set<String> _searchClosed = {};

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  void _setQuery(String value) => setState(() {
    _query = value;
    _searchClosed.clear();
  });

  void _toggleSelected(String tagId) {
    setState(() {
      if (!_selected.remove(tagId)) _selected.add(tagId);
    });
  }

  void _startSelecting(String tagId) {
    setState(() => _selected.add(tagId));
  }

  void _clearSelection() => setState(_selected.clear);

  /// **Select-all — the dangerous control in this task, and the one Michael
  /// actually asked for.** Selects every row currently on screen (whatever
  /// [sortTags] produced), not the raw unsorted provider value, so it can
  /// never select a row the person cannot see.
  void _selectAll(List<TagLibraryEntry> visible) {
    setState(() {
      _selected
        ..clear()
        ..addAll(visible.map((e) => e.tagId));
    });
  }

  bool _allSelected(List<TagLibraryEntry> visible) =>
      visible.isNotEmpty && visible.every((e) => _selected.contains(e.tagId));

  @override
  Widget build(BuildContext context) {
    final tagsAsync = ref.watch(tagLibraryProvider);
    final holdersAsync = ref.watch(tagLibraryHoldersProvider);
    // Name order until the saved arrangement has been read — a moment.
    final projectOrder =
        ref.watch(tagLibraryProjectOrderProvider).value ?? const <String>[];
    final sortOrder = ref.watch(tagSortOrderSettingProvider).value ?? TagSortOrder.frequency;
    // The export button below reads this same sorted list, not `tagsAsync`
    // directly — task 11.178 settled that the CSV should follow whatever
    // order is on screen rather than silently keeping its own.
    final sortedTags = tagsAsync.value == null ? null : sortTags(tagsAsync.value!, sortOrder);
    final pulseRateUnit =
        ref.watch(pulseRateUnitSettingProvider).value ?? PulseRateUnit.bpm;
    return Scaffold(
      appBar: _selectionMode
          ? _selectionAppBar(
              context,
              [
                for (final tag in sortedTags ?? const <TagLibraryEntry>[])
                  if (tagMatchesSearch(tag, _query)) tag,
              ],
            )
          : AppBar(
        title: const Text('Tag Library'),
        actions: [
          // Task 11.191: a second control over the same
          // `pulseRateUnitSettingProvider` Tag details already reads/writes —
          // one device preference, two places to change it, kept in step by
          // both watching the same provider. A `PopupMenuButton`, not the
          // segmented toggle Tag details uses: that toggle's two text labels
          // overflowed this app bar's action row on a real phone width at a
          // large text scale (task 11.191 measured it), where the sort
          // control beside it — the same shape this one now copies — does
          // not, because a popup's contents float over the screen rather
          // than widening the bar that opens it.
          PopupMenuButton<PulseRateUnit>(
            key: const ValueKey('pulse_rate_unit_menu_app_bar'),
            tooltip: 'Pulse rate unit (${pulseRateUnit.label})',
            icon: const Icon(Icons.speed),
            initialValue: pulseRateUnit,
            onSelected: (unit) =>
                ref.read(pulseRateUnitSettingProvider.notifier).set(unit),
            itemBuilder: (context) => [
              for (final option in PulseRateUnit.values)
                PopupMenuItem(value: option, child: Text(option.label)),
            ],
          ),
          // Task 11.178: only two orders, no ascending/descending — nobody
          // asked for a direction choice, and it would double this menu for
          // no requested benefit.
          PopupMenuButton<TagSortOrder>(
            tooltip: 'Sort tags',
            icon: const Icon(Icons.sort),
            initialValue: sortOrder,
            onSelected: (order) => ref.read(tagSortOrderSettingProvider.notifier).set(order),
            itemBuilder: (context) => const [
              PopupMenuItem(value: TagSortOrder.frequency, child: Text('Sort by frequency')),
              PopupMenuItem(value: TagSortOrder.name, child: Text('Sort by name')),
            ],
          ),
          IconButton(
            tooltip: 'Export tags CSV',
            icon: const Icon(Icons.download),
            onPressed: sortedTags == null || sortedTags.isEmpty
                ? null
                : () => _exportCsv(context, sortedTags),
          ),
          // Task 11.14: a bulk import writes tags through the same
          // `TagRepository.insert` the create FAB below already gates on
          // `mayCreateTagProvider` — this button reached that same write with
          // no pre-check at all, so a viewer picked a file, watched the
          // preview screen, and only then hit the raw refusal.
          //
          // Task 11.94/11.101: the refusal used to live only in this button's
          // `tooltip:`, which a touchscreen never shows — so a viewer saw a
          // greyed-out icon with no way to find out why. The button now stays
          // tappable and explains itself with the same dialog `_showEditDialog`
          // uses for the create FAB below, reachable by the tap somebody
          // actually makes.
          IconButton(
            tooltip: 'Bulk import CSV',
            icon: const Icon(Icons.upload_file),
            onPressed: () => _importCsv(context, ref),
          ),
        ],
      ),
      body: tagsAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => LoadFailure('the tag list', error: e),
        // **Keeps the last grouping while it re-reads.** It rebuilds whenever
        // the library does, and without this every edit, delete and undo
        // flashed the whole list to a spinner (found by task 11.288's UNDO
        // test, which then never settled).
        data: (tags) => holdersAsync.when(
          skipLoadingOnReload: true,
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => LoadFailure('which projects use each tag', error: e),
          data: (grouping) {
            final sorted = sortTags(tags, sortOrder);
            if (sorted.isEmpty) {
              return const Center(
                child: Text('No tags yet — add one or import a CSV.'),
              );
            }
            // Task 11.322: what the search leaves. Export still writes the
            // whole library (`sortedTags` above); this only decides what is
            // shown, and so what select-all and delete can reach.
            final shown = [
              for (final tag in sorted)
                if (tagMatchesSearch(tag, _query)) tag,
            ];
            // **Task 11.321, item 1: grouped by project, collapsed.** One
            // group is shown open, because collapsing the only heading
            // hides everything and chooses between nothing. While selecting,
            // every group is open, so select-all can never check a row the
            // person cannot see (task 11.288's rule, kept).
            //
            // Every project has a heading, empty or not, so a tag can be
            // dragged onto it (task 11.321): "the only heading" is the only
            // one with tags in it.
            final groups = [
              for (final g in groupLibraryByProject(
                shown,
                grouping.holders,
                projects: grouping.projects,
                order: projectOrder,
              ))
                // A search shows only the headings it found something under.
                if (!_searching || g.entries.isNotEmpty) g,
            ];
            final withTags = groups.where((g) => g.entries.isNotEmpty);
            final projectGroups = [
              for (final g in groups)
                if (g.projectId != null) g,
            ];
            // **Task 11.321: the headings can be dragged into any order** by
            // the ≡ handle on each project heading. Only by the handle —
            // holding a row already starts selecting, and headings already
            // take dropped tags. "Not on any project" has no handle and stays
            // last: it is not a project.
            final list = ReorderableListView(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
              buildDefaultDragHandles: false,
              onReorderItem: (from, to) {
                if (from >= projectGroups.length) return;
                if (to >= projectGroups.length) to = projectGroups.length - 1;
                final ids = [for (final g in projectGroups) g.projectId!];
                ids.insert(to, ids.removeAt(from));
                ref.read(tagLibraryProjectOrderProvider.notifier).set(ids);
              },
              children: [
                for (var i = 0; i < groups.length; i++)
                  _LibraryGroupSection(
                    key: ValueKey('tag_library_group_${groups[i].key}'),
                    // Not while searching: the handles reorder the project
                    // headings, and a search shows only some of them.
                    reorderIndex:
                        groups[i].projectId == null ||
                            _selectionMode ||
                            _searching
                        ? null
                        : i,
                    group: groups[i],
                    expanded: _selectionMode
                        ? true
                        : _searching
                        ? !_searchClosed.contains(groups[i].key)
                        : (withTags.length == 1 &&
                                  withTags.single == groups[i]) ||
                              _expanded.contains(groups[i].key),
                    onToggle: () => setState(() {
                      final open = _searching ? _searchClosed : _expanded;
                      if (!open.remove(groups[i].key)) open.add(groups[i].key);
                    }),
                    rowFor: (entry) =>
                        _row(context, entry, sortOrder, groups[i].projectId),
                    onDrop: groups[i].projectId == null || _selectionMode
                        ? null
                        : (dragged) => _assignToProject(
                            context,
                            dragged,
                            groups[i],
                            grouping.holders,
                          ),
                  ),
              ],
            );
            return Column(
              children: [
                // Hidden while selecting: the search then stays as it was, so
                // select-all and delete can only reach rows that are shown.
                if (!_selectionMode)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                    child: TextField(
                      key: const ValueKey('tag_library_search'),
                      controller: _searchController,
                      onChanged: _setQuery,
                      textInputAction: TextInputAction.search,
                      decoration: InputDecoration(
                        hintText: 'Search by frequency or name',
                        prefixIcon: const Icon(Icons.search),
                        suffixIcon: _query.isEmpty
                            ? null
                            : IconButton(
                                key: const ValueKey('tag_library_search_clear'),
                                tooltip: 'Clear search',
                                icon: const Icon(Icons.close),
                                onPressed: () {
                                  _searchController.clear();
                                  _setQuery('');
                                },
                              ),
                        border: const OutlineInputBorder(),
                        isDense: true,
                      ),
                    ),
                  ),
                Expanded(
                  child: shown.isEmpty
                      ? const Center(child: Text('No tags match.'))
                      : list,
                ),
              ],
            );
          },
        ),
      ),
      // Task 11.12: explained for a viewer of the active project, rather than
      // a control that opens the whole create form only to refuse it at the
      // end — the gap `_showEditDialog`'s existing try/catch already
      // backstops but does not, by itself, satisfy "explain, don't just hide"
      // up front.
      //
      // Task 11.94/11.101: this used to disable the FAB and put the reason in
      // a `Tooltip`, which a touchscreen never shows — a viewer got a greyed
      // circle with no way to find out why. It stays tappable and explains
      // itself instead.
      //
      // **Task 11.288: hidden while selecting**, so a stray tap while
      // choosing tags to delete cannot open the create form on top of it.
      floatingActionButton: _selectionMode
          ? null
          : FloatingActionButton(
        // **No role gate since task 11.219**, and its absence is the change
        // rather than an oversight: this writes a device-local library row in
        // no project, so nothing can refuse it and a control that explained a
        // refusal that cannot happen would be a lie. What a viewer still
        // cannot do is put the new tag into the project they are a viewer on;
        // the form's "Also add to" choice is where that is answered.
        // Its own hero tag: every tab's "+" is built at once (task 11.323).
        heroTag: 'fab-tag-library',
        onPressed: () => _showEditDialog(context, ref),
        child: const Icon(Icons.add),
      ),
    );
  }

  /// One library entry, swipeable to delete. A collar on two projects is
  /// built once under each — its key is unique within its own group, which
  /// is all a [Dismissible] needs.
  Widget _row(
    BuildContext context,
    TagLibraryEntry entry,
    TagSortOrder sortOrder,
    String? fromProjectId,
  ) {
    // **Task 11.288: swipe-to-delete — one entry, no selection mode.** This
    // is the common case Michael described, and it costs the row nothing the
    // rest of the time: the delete affordance is not drawn, it is revealed
    // by the gesture. Disabled entirely while selecting, so the two ways to
    // delete never fight each other over the same tap.
    return Dismissible(
      key: ValueKey(entry.tagId),
      direction: _selectionMode
          ? DismissDirection.none
          : DismissDirection.endToStart,
      background: Container(
        color: Theme.of(context).colorScheme.errorContainer,
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.symmetric(horizontal: 20),
        child: Icon(
          Icons.delete_outline,
          color: Theme.of(context).colorScheme.onErrorContainer,
        ),
      ),
      confirmDismiss: (_) => _confirmDelete(context, [entry]),
      onDismissed: (_) => _performDelete(context, ref, [entry]),
      child: TagListRow(
        tag: entry,
        sortOrder: sortOrder,
        selectionMode: _selectionMode,
        selected: _selected.contains(entry.tagId),
        onTap: _selectionMode
            ? () => _toggleSelected(entry.tagId)
            : () => _showEditDialog(context, ref, entry: entry),
        onLongPress:
            _selectionMode ? null : () => _startSelecting(entry.tagId),
        // **Task 11.321: drag a tag onto a project's heading to add it
        // there.** A handle rather than a long press, because a long press
        // already starts selecting (task 11.288) and a sideways swipe
        // already deletes; the handle is the one gesture nothing else uses,
        // and it shows that dragging is possible at all.
        leading: _selectionMode
            ? null
            : Draggable<_DraggedTag>(
                key: ValueKey('tag_library_drag_${entry.tagId}'),
                data: _DraggedTag(entry, fromProjectId),
                feedback: _DragFeedback(entry: entry),
                childWhenDragging: const Opacity(
                  opacity: 0.3,
                  child: Icon(Icons.drag_indicator),
                ),
                child: Semantics(
                  label: 'Drag ${entry.tagName} to a project',
                  child: const SizedBox(
                    width: DesignTokens.minTouchTarget,
                    height: DesignTokens.minTouchTarget,
                    child: Icon(Icons.drag_indicator),
                  ),
                ),
              ),
      ),
    );
  }

  /// **A tag dropped on a project's heading is added to that project** —
  /// Michael, 2026-09-30: *"click and drag a tag … from the not on any
  /// project category to an actual project."*
  ///
  /// **A copy, never a move.** The project it was dragged from keeps its
  /// copy: taking a tag off a project is owner-only (T3), because it changes
  /// what that project's bearings were recorded against, and a drag must not
  /// do an owner's job by accident. Adding is contributor-level (T2), the
  /// same rule and the same write — `TagRepository.copyFromLibrary` — as
  /// More → Tags's "Copy from library".
  ///
  /// **Confirmed first**, because a contributor cannot take it back off: a
  /// mis-drop must be stoppable before it is written.
  Future<void> _assignToProject(
    BuildContext context,
    _DraggedTag dragged,
    LibraryGroup target,
    Map<String, Map<String, String>> holders,
  ) async {
    final entry = dragged.entry;
    final projectId = target.projectId!;
    final messenger = ScaffoldMessenger.of(context);
    void say(String text) => messenger
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(text)));
    if (holders[entry.lineageId]?.containsKey(projectId) ?? false) {
      say('${entry.tagName} is already on ${target.title}.');
      return;
    }
    final standing = await ref.read(
      myProjectStandingProvider(projectId).future,
    );
    final refusal = standing.writeRefusal(
      asViewer:
          'Viewers cannot add a tag to a project — ask a project owner to '
          'change your role to contributor.',
    );
    if (refusal != null) {
      say(refusal);
      return;
    }
    if (!context.mounted) return;
    final from = dragged.fromProjectId == null
        ? null
        : holders[entry.lineageId]?[dragged.fromProjectId];
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Add ${entry.tagName} to ${target.title}?'),
        content: Text(
          [
            'The project gets its own copy of the tag.',
            if (from != null) '$from keeps its copy.',
          ].join(' '),
        ),
        actions: [
          TextButton(
            key: const ValueKey('tag_library_assign_cancel'),
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const ValueKey('tag_library_assign_confirm'),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Add'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    final user = await ref.read(currentUserProvider.future);
    final deviceId = await ref.read(deviceIdProvider.future);
    final tagRepo = await ref.read(tagRepositoryProvider.future);
    try {
      await tagRepo.copyFromLibrary(
        entry,
        projectId: projectId,
        modifiedBy: user.userId,
        deviceId: deviceId,
      );
    } on UnauthorizedMutation catch (e) {
      say(
        e.refusalSentence(
          asViewer:
              'Viewers cannot add a tag to a project — ask a project owner '
              'to change your role to contributor.',
        ),
      );
      return;
    } catch (e) {
      say(
        describeFailure(
          e,
          fallback: 'Could not add the tag; nothing has changed. Try again.',
        ),
      );
      return;
    }
    refreshTagViews(ref, projectId: projectId);
    if (mounted) setState(() => _expanded.add(projectId));
    say('${entry.tagName} added to ${target.title}.');
  }

  /// **Task 11.288.** The app bar shown while one or more rows are checked —
  /// a count, "select all" (or "deselect all" once every visible row is
  /// checked), the delete action, and a close button that leaves the
  /// selection rather than deleting anything.
  PreferredSizeWidget _selectionAppBar(
    BuildContext context,
    List<TagLibraryEntry> visible,
  ) {
    final allSelected = _allSelected(visible);
    return AppBar(
      leading: IconButton(
        key: const ValueKey('tag_library_selection_close'),
        icon: const Icon(Icons.close),
        tooltip: 'Cancel selection',
        onPressed: _clearSelection,
      ),
      title: Text('${_selected.length} selected'),
      actions: [
        IconButton(
          key: const ValueKey('tag_library_select_all'),
          icon: Icon(allSelected ? Icons.deselect : Icons.select_all),
          tooltip: allSelected ? 'Deselect all' : 'Select all',
          onPressed: () =>
              allSelected ? _clearSelection() : _selectAll(visible),
        ),
        IconButton(
          key: const ValueKey('tag_library_delete_selected'),
          icon: const Icon(Icons.delete_outline),
          tooltip: 'Delete selected',
          onPressed: () => _deleteSelected(context, ref, visible),
        ),
      ],
    );
  }

  /// **Task 11.288.** How many of [entries] are still held by at least one
  /// of this device's projects — read from `libraryCopyCount`, once per
  /// entry, never a second count of its own.
  Future<int> _entriesStillInUseCount(
    TagLibraryRepository library,
    List<TagLibraryEntry> entries,
  ) async {
    var inUse = 0;
    for (final entry in entries) {
      if (await library.libraryCopyCount(entry.lineageId) > 0) inUse++;
    }
    return inUse;
  }

  /// **Task 11.288.** Names how many of [entries] projects still hold a
  /// copy of, and says those copies stay — the one thing a person clearing
  /// out test tags is likely to get wrong (§ the plan entry's "the thing a
  /// person will get wrong").
  Future<bool> _confirmDelete(
    BuildContext context,
    List<TagLibraryEntry> entries,
  ) async {
    final library = await ref.read(tagLibraryRepositoryProvider.future);
    final inUse = await _entriesStillInUseCount(library, entries);
    if (!context.mounted) return false;

    final n = entries.length;
    final copyLine = inUse == 0
        ? null
        : n == 1
            ? "This collar is still in use by ${inUse == 1 ? 'a project' : '$inUse projects'} "
                'on this device — deleting it from your library does not '
                'touch that copy.'
            : '$inUse of the $n selected tags ${inUse == 1 ? 'is' : 'are'} '
                'still in use by a project on this device — deleting them '
                'from your library does not touch those copies.';

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(n == 1 ? 'Delete this tag?' : 'Delete $n tags?'),
        content: Text([
          'You can undo this from the confirmation that follows.',
          ?copyLine,
        ].join('\n\n')),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const ValueKey('tag_library_delete_confirm'),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    return confirmed ?? false;
  }

  /// **Task 11.288.** The write and its undo — assumes [entries] have
  /// already been confirmed; [_confirmDelete] and [_deleteSelected] are the
  /// only callers.
  ///
  /// **This does not rewind the auto-colour sequence.** A soft-deleted row
  /// still counts toward `TagLibraryRepository.entryCount` (see that
  /// method's own doc comment for why), so deleting fifty test tags and
  /// adding one new one does not repeat a colour a project's map may still
  /// be showing for a live collar. That is correct, not a leftover bug from
  /// this delete.
  Future<void> _performDelete(
    BuildContext context,
    WidgetRef ref,
    List<TagLibraryEntry> entries,
  ) async {
    final library = await ref.read(tagLibraryRepositoryProvider.future);
    final ids = entries.map((e) => e.tagId).toList();
    if (!context.mounted) return;
    final deleted = await runGuardedWrite(
      context,
      write: () => library.softDelete(ids),
      refused: null,
      failed: 'Could not delete ${ids.length == 1 ? 'this tag' : 'these tags'}; '
          'nothing has changed. Try again, and report it if this keeps '
          'happening.',
    );
    if (!deleted) return;
    ref.invalidate(tagLibraryProvider);
    if (mounted) setState(() => _selected.removeAll(ids));

    if (!context.mounted) return;
    ScaffoldMessenger.of(context).clearSnackBars();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          ids.length == 1 ? 'Tag deleted' : '${ids.length} tags deleted',
        ),
        duration: const Duration(seconds: 6),
        persist: false,
        action: SnackBarAction(
          label: 'UNDO',
          onPressed: () async {
            if (!context.mounted) return;
            final restored = await runGuardedWrite(
              context,
              write: () => library.restore(ids),
              refused: null,
              failed: 'Could not bring '
                  '${ids.length == 1 ? 'this tag' : 'these tags'} back. Try '
                  'the same undo again, and report it if it keeps happening.',
            );
            if (!restored) return;
            ref.invalidate(tagLibraryProvider);
          },
        ),
      ),
    );
  }

  /// **Task 11.288.** The selection app bar's delete action: confirm, then
  /// perform, over whatever is currently checked.
  Future<void> _deleteSelected(
    BuildContext context,
    WidgetRef ref,
    List<TagLibraryEntry> visible,
  ) async {
    final entries = visible.where((e) => _selected.contains(e.tagId)).toList();
    if (entries.isEmpty) return;
    final confirmed = await _confirmDelete(context, entries);
    if (!confirmed || !context.mounted) return;
    await _performDelete(context, ref, entries);
  }

  /// Opens the tag form on a **library entry** — a new one when [entry] is
  /// null, otherwise that one.
  ///
  /// ## Nothing here is refused, and that is the model rather than a gap
  ///
  /// A library entry is device-local: it is in no project, so no role
  /// governs it. The read-only banner that used to head this form for a
  /// non-owner is gone from this screen and lives on Project Setup, where a
  /// **project's copy** is edited and where the owner-only rule genuinely
  /// applies. Michael's 2026-09-06 decision — that a refusal must not be the
  /// end of the road, and that a viewer must still be able to read
  /// everything about a tag — is stronger here than it was: on your own
  /// device's list you may also change it.
  ///
  /// ## No correction-or-change question
  ///
  /// Task 11.32's question exists because editing a tag rewrites what every
  /// bearing already recorded against it claims. **Nothing is ever recorded
  /// against a library entry** — bearings name a project's copy — so there is
  /// no history to reinterpret and nothing to ask. Editing the project's copy
  /// still asks, on Project Setup.
  Future<void> _showEditDialog(
    BuildContext context,
    WidgetRef ref, {
    TagLibraryEntry? entry,
  }) async {
    final creating = entry == null;
    final TagLibraryRepository library;
    final List<Project> projects;
    final String? activeProjectId;
    final String initialColorHex;
    final int copies;
    // Task 11.235: everything the form needs before it can open, gathered
    // under one catch. **For ten days a tap on + did nothing on Michael's
    // phone** — an auto-disposing provider threw on the way to this dialog,
    // the exception went unhandled, and the person had nothing to report but
    // "it doesn't work". The provider is fixed; this is the part that makes
    // the *next* failure on this path say so. The sentence names what was
    // being attempted and what to try, and asserts no cause, because the
    // branch reached when the code does not know why must not claim to.
    try {
      library = await ref.read(tagLibraryRepositoryProvider.future);
      // Only offered when creating, and only for projects this person may
      // write to: putting a copy into a project is a project write, and a
      // viewer's project must not be on the menu.
      projects = creating
          ? await _projectsThisPersonMayAddTo(ref)
          : const <Project>[];
      activeProjectId =
          creating ? await ref.read(activeProjectIdProvider.future) : null;
      initialColorHex = entry?.colorHex ?? await library.nextColorHex();
      // §2.5's count: how many of this device's projects hold a copy of this
      // collar. Zero when creating — there is nothing to have copied yet.
      copies = creating ? 0 : await library.libraryCopyCount(entry.lineageId);
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              describeFailure(e, fallback: kTagFormCouldNotOpenMessage),
            ),
          ),
        );
      }
      return;
    }
    if (!context.mounted) return;

    final result = await showDialog<TagEditResult>(
      context: context,
      builder: (context) => TagEditDialog(
        existing: entry,
        projects: projects,
        initialProjectId:
            projects.any((p) => p.projectId == activeProjectId)
                ? activeProjectId
                : null,
        initialColorHex: initialColorHex,
        // **No colour section on a library entry** (task 11.244): its colour
        // is read by nothing now. See `TagEditDialog.showColor`.
        showColor: false,
        projectCopyCount: copies,
      ),
    );
    if (result == null) return;

    final now = DateTime.now();
    final deviceId = await ref.read(deviceIdProvider.future);
    final user = await ref.read(currentUserProvider.future);

    if (creating) {
      if (!context.mounted) return;
      // Task 11.11's warning, at the last moment before the row exists.
      final decision = await checkNewTagAgainstExisting(
        context,
        ref,
        frequencyMhz: result.draft.frequencyMhz,
        tagName: result.draft.tagName,
        projectId: result.projectId,
      );
      switch (decision) {
        case CreateNewTag():
          break;
        case GoBackFromNewTag():
          return;
        case UseExistingTag(:final tag):
          // Task 11.324: the project already has this Tag ID, and the person
          // kept it. Nothing to write; say so, so the Save does not look lost.
          if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(
                  'Tag ${tag.tagName} is already on this project, so nothing '
                  'new was added.',
                ),
              ),
            );
          }
          return;
      }
      final newEntry = result.draft.newEntry(
        tagId: const Uuid().v4(),
        sync: SyncMeta.initial(
          now: now,
          modifiedBy: user.userId,
          originDeviceId: deviceId,
        ),
      );
      await library.insert(newEntry);
      if (result.projectId != null) {
        final tagRepo = await ref.read(tagRepositoryProvider.future);
        // A copy, not a link. The project's row takes a fresh id and keeps
        // this entry's lineage — see `TagRepository.copyFromLibrary`.
        //
        // The refusal is still possible: a role can change between the
        // moment the menu was built and the moment Save is pressed, which is
        // the gap every pre-check in this app leaves and backstops.
        try {
          await tagRepo.copyFromLibrary(
            newEntry,
            projectId: result.projectId!,
            modifiedBy: user.userId,
            deviceId: deviceId,
            now: now,
          );
        } on UnauthorizedMutation catch (e) {
          if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(
                  'The tag is in your library. '
                  '${e.refusalSentence(
                    asViewer:
                        'Viewers cannot add a tag to a project — ask a '
                        'project owner to change your role to contributor.',
                  )}',
                ),
              ),
            );
          }
        }
      }
    } else {
      final updatedEntry = result.draft.ontoEntry(entry);
      await library.update(updatedEntry, now: now);
      // **Task 11.250.** A library edit reaches no project by construction
      // (`TagLibraryRepository.update`'s own doc comment says so), so the
      // form offers the one route that fixes it everywhere — never
      // automatic, and only when there is something for it to reach and
      // something for it to change.
      if (copies > 0 &&
          TagRepository.libraryEditChangedPushableFields(
            entry,
            updatedEntry,
          )) {
        if (!context.mounted) return;
        await _offerPushToProjects(
          context,
          ref,
          before: entry,
          entry: updatedEntry,
          copies: copies,
          actor: MutationActor.user(user.userId),
          deviceId: deviceId,
          now: now,
        );
      }
    }
    refreshTagViews(ref, projectId: result.projectId);
  }

  /// Offers to apply a library edit to every project that holds a copy of
  /// the same collar — task 11.250. Always asked, never automatic.
  ///
  /// Task 11.32's correction-or-change question is asked **once**, not once
  /// per project — correcting a typo or recording a drift is a statement
  /// about the physical transmitter, and the answer is the same for every
  /// copy of it. Whether it needs asking at all is decided across *every*
  /// target row rather than off [entry] alone, so a project whose copy had
  /// already drifted from the library in a versioned field cannot reach
  /// `TagRepository.update` with no answer to give it.
  Future<void> _offerPushToProjects(
    BuildContext context,
    WidgetRef ref, {
    required TagLibraryEntry before,
    required TagLibraryEntry entry,
    required int copies,
    required MutationActor actor,
    required String? deviceId,
    required DateTime now,
  }) async {
    final apply = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Apply this to your projects?'),
        content: Text(
          copies == 1
              ? 'The 1 project that uses this tag can be updated to '
                  'match — its own history stays intact either way.'
              : 'The $copies projects that use this tag can be updated '
                  'to match — their own histories stay intact either way.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Not now'),
          ),
          FilledButton(
            key: const ValueKey('tag_library_push_confirm'),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Apply to my projects'),
          ),
        ],
      ),
    );
    if (apply != true || !context.mounted) return;

    final tagRepo = await ref.read(tagRepositoryProvider.future);
    final targets = await tagRepo.findByLineage(entry.lineageId);
    // **Decided across every target row, not off the library edit alone.**
    // A project's copy can already have drifted from the library in a
    // versioned field before this edit; if it has, that project needs the
    // question asked even when the library-level diff alone would not have
    // raised it — see `TagRepository.pushToProjects`.
    final draft = TagDraft.of(entry);
    final needsIntent = targets.any(
      (tag) => TagVersionRepository.versionedFieldsChanged(
        tag,
        draft.onto(tag),
      ),
    );

    TagEditIntent? intent;
    if (needsIntent) {
      if (!context.mounted) return;
      intent = await askTagEditIntent(
        context,
        before: before,
        after: entry,
        unit: ref.read(pulseRateUnitProvider),
      );
      // Dismissed without choosing: no safe default exists, so the push does
      // not happen at all rather than happening for some projects and not
      // others.
      if (intent == null) return;
    }

    final result = await tagRepo.pushToProjects(
      entry,
      intent: intent,
      actor: actor,
      deviceId: deviceId,
      now: now,
    );
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          result.refused == 0
              ? 'Updated ${result.updated} '
                  '${result.updated == 1 ? 'project' : 'projects'}.'
              : 'Updated ${result.updated} '
                  '${result.updated == 1 ? 'project' : 'projects'}. '
                  '${result.refused} could not be changed — you are not an '
                  'owner there.',
        ),
      ),
    );
  }

  /// The projects this person may put a copy of a tag into — every project on
  /// the device they are not merely a viewer on, and not a read-only snapshot
  /// of somebody else's (task 11.237).
  ///
  /// **Filtered rather than offered-and-refused.** Adding a tag to a project
  /// is a project write, and the pre-check has to be at least as permissive
  /// as the write and never stricter (the invariant task 11.126 recorded): a
  /// standing this device cannot resolve is *offered*, because the server is
  /// the authority and this file legitimately holds projects with no
  /// membership row. A project the device can see this person is **not on**
  /// is withheld, because the write would refuse it — same answer, same
  /// rows, asked a moment earlier.
  Future<List<Project>> _projectsThisPersonMayAddTo(WidgetRef ref) async {
    final projects = await ref.read(allProjectsProvider.future);
    final allowed = <Project>[];
    for (final project in projects) {
      if (await ref.read(
        mayWriteProjectDataProvider(project.projectId).future,
      )) {
        allowed.add(project);
      }
    }
    return allowed;
  }

  Future<void> _importCsv(BuildContext context, WidgetRef ref) async {
    final result = await FilePicker.pickFiles(type: FileType.custom, allowedExtensions: ['csv']);
    final path = result?.files.single.path;
    if (path == null) return;

    final String text;
    try {
      text = await File(path).readAsString();
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              describeFailure(
                e,
                fallback:
                    'Could not read that file. Nothing has been imported. '
                    'Check the file is still on this device and try again.',
              ),
            ),
          ),
        );
      }
      return;
    }

    // Read the live library count before building the preview so the colours
    // shown here are the colours that actually get saved — an import into a
    // library that already has tags should continue the round-robin from
    // where those left off, not restart it at palette index 0.
    final library = await ref.read(tagLibraryRepositoryProvider.future);
    final autoAssignStartIndex = await library.entryCount();

    // Task 11.13: the same near-duplicate check 11.11 runs before a
    // hand-typed tag is created, applied per row here — a CSV import is the
    // largest single source of duplicates in the app.
    //
    // **What it compares against is the library and the destination project,
    // in that order** (§2.6). A row is matched against every entry the person
    // already has; the ones that are also tags of the project this import is
    // going into sort first, because an in-project frequency collision is the
    // one that breaks triangulation.
    final existingTags = await library.findAll();
    final activeProjectId = await ref.read(activeProjectIdProvider.future);
    var projectTagIds = const <String>{};
    if (activeProjectId != null) {
      final tagRepo = await ref.read(tagRepositoryProvider.future);
      final projectTags = await tagRepo.findByProject(activeProjectId);
      // Matched by lineage rather than by id: the project's tag is a *copy*
      // of the library entry, so their ids differ by construction and an
      // id comparison would never fire.
      final lineages = {for (final tag in projectTags) tag.lineageId};
      projectTagIds = {
        for (final entry in existingTags)
          if (lineages.contains(entry.lineageId)) entry.tagId,
      };
    }

    final preview = TagCsvImport.preview(
      text,
      autoAssignStartIndex: autoAssignStartIndex,
      existingTags: existingTags,
      projectTagIds: projectTagIds,
    );
    if (preview.hasFatalHeaderError) {
      if (context.mounted) {
        await showDialog<void>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Missing required columns'),
            content: Text(
              'The file is missing: ${preview.missingRequiredColumns.join(', ')}.\n\n'
              'Required: frequency (MHz), tag name, date put on.',
            ),
            actions: [
              TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('OK')),
            ],
          ),
        );
      }
      return;
    }

    if (!context.mounted) return;
    // Task 11.13: null means the user backed out; an empty (or partial) set
    // means they confirmed, having chosen to skip that many duplicate rows.
    final skipped = await Navigator.of(context).push<Set<int>>(
      MaterialPageRoute(builder: (context) => TagImportPreviewScreen(preview: preview)),
    );
    if (skipped == null) return;

    final now = DateTime.now();
    final deviceId = await ref.read(deviceIdProvider.future);
    final user = await ref.read(currentUserProvider.future);

    final database = await ref.read(appDatabaseProvider.future);

    // Finding M-2: this was a bare `for` loop here, with no transaction and no
    // try/catch, so one row the database rejected mid-way left a partial
    // import behind and threw past the success snackbar — the user was told
    // nothing at all. [TagCsvCommit] owns the all-or-nothing property; this
    // screen owns saying what happened.
    final int written;
    try {
      written = await TagCsvCommit.commit(
        database.raw,
        preview,
        projectId: activeProjectId,
        modifiedBy: user.userId,
        deviceId: deviceId,
        now: now,
        skippedRowNumbers: skipped,
      );
    } catch (e) {
      // **Task 11.46's defect, in the second of its two places.** This used to
      // interpolate `$e`, and the exceptions reachable here include sqflite's,
      // whose `toString()` carries the INSERT statement and its bound values —
      // which for a tag import is the biologist's own tag names and
      // frequencies. 11.46 removed exactly this from the publish path and left
      // a comment saying it must never return; nobody swept for this one.
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              describeFailure(
                e,
                fallback:
                    'Import failed; your tags are unchanged. Try again, and '
                    'report it if this keeps happening.',
              ),
            ),
          ),
        );
      }
      return;
    }

    // A CSV import links every row it writes to the project it was imported
    // into (task 11.151).
    refreshTagViews(ref, projectId: activeProjectId);
    if (context.mounted) {
      // Finding L-15: a recoloured tag used to be reported as nothing at all,
      // over copy that read "(0 skipped)" — and Phase 4.4 made tag colour the
      // map legend key.
      final recoloured = preview.warnedRows.length;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Imported $written tags '
            '(${preview.invalidRows.length} invalid'
            '${skipped.isEmpty ? '' : ', ${skipped.length} skipped as duplicates'}'
            '${recoloured == 0 ? '' : ', $recoloured recolored'})')),
      );
    }
  }

  Future<void> _exportCsv(BuildContext context, List<TagFields> tags) async {
    // Task 11.137: writing a file can fail for reasons that have nothing to do
    // with this app — a full disk, a folder the OS will not let it write to, a
    // removable card pulled out mid-save — and every one of them used to end
    // with the Export button doing nothing visible. `refused: null`: an export
    // reads the tag list out and writes no record, so no permission governs it.
    String? path;
    final exported = await runGuardedWrite(
      context,
      write: () async {
        final csvText = TagCsvExport.export(tags);
        final dateStamp = DateTime.now().toIso8601String().substring(0, 10);
        path = await FilePicker.saveFile(
          fileName: 'tags_$dateStamp.csv',
          type: FileType.custom,
          allowedExtensions: ['csv'],
          bytes: Uint8List.fromList(utf8.encode(csvText)),
        );
      },
      refused: null,
      failed: 'Could not save the tag CSV; your tags are unchanged. Check '
          'there is room on the device, try a different folder, and report it '
          'if this keeps happening.',
    );
    if (!exported) return;
    if (context.mounted && path != null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Exported ${tags.length} tags')));
    }
  }
}

/// Not private (unlike this screen's other module-level state) so tests can
/// pre-resolve it directly — it unconditionally touches the database (the
/// library is device-local, so there is no "no active project" short-circuit
/// the way `currentProjectProvider` has), which needs the same
/// `tester.runAsync` pre-resolution treatment as the tiled DEM store.
///
/// **Task 11.178 deliberately left this a plain provider rather than a
/// family keyed on sort order.** `arrival_refresh.dart` and
/// `tag_view_refresh.dart` name this provider explicitly to enumerate what a
/// sync round must refresh (task 11.154); a family would turn "add a sort
/// order" into a change to that enumeration for a list that is tens of rows.
/// The screen sorts the loaded list in Dart instead — see [sortTags].
final tagLibraryProvider = FutureProvider<List<TagLibraryEntry>>((ref) async {
  final repo = await ref.watch(tagLibraryRepositoryProvider.future);
  return repo.findAll();
});

/// **Which projects on this device hold each collar** — task 11.321's
/// grouping, as `TagLibraryRepository.projectsHoldingEachLineage` reads it.
///
/// It watches [tagLibraryProvider], so everything that refreshes the library
/// (every tag write, through `refreshTagViews`) refreshes this too, with no
/// second list of invalidation sites. **Auto-disposing**, so opening the
/// screen always reads it fresh: a project deleted or renamed elsewhere
/// writes no tag, and a cached copy would keep its old heading.
final tagLibraryHoldersProvider = FutureProvider.autoDispose<
    ({Map<String, Map<String, String>> holders, Map<String, String> projects})>(
  (ref) async {
    // Both watched before the first await (task 11.236's shape).
    final repo = ref.watch(tagLibraryRepositoryProvider.future);
    final entries = ref.watch(tagLibraryProvider.future);
    await entries;
    final library = await repo;
    return (
      holders: await library.projectsHoldingEachLineage(),
      // Every project gets a heading, so an empty one can be dropped onto.
      projects: await library.liveProjectNames(),
    );
  },
);

/// What is being dragged on the Tag Library: a collar, and the heading it
/// was picked up from (null for "Not on any project").
class _DraggedTag {
  const _DraggedTag(this.entry, this.fromProjectId);
  final TagLibraryEntry entry;
  final String? fromProjectId;
}

/// One project's heading on the Tag Library, and its rows when open.
///
/// **A project's heading is also where a dragged tag is dropped** (task
/// 11.321) — [onDrop] is null for "Not on any project", which is not a
/// place a tag can be put. While a tag hovers over it the band darkens and
/// gains a border, so the person can see which project they are about to
/// pick before letting go.
class _LibraryGroupSection extends StatelessWidget {
  const _LibraryGroupSection({
    super.key,
    required this.group,
    required this.expanded,
    required this.onToggle,
    required this.rowFor,
    this.onDrop,
    this.reorderIndex,
  });

  /// This heading's place in the reorderable list, or null when it cannot
  /// be moved ("Not on any project", or while selecting).
  final int? reorderIndex;

  final LibraryGroup group;
  final bool expanded;
  final VoidCallback onToggle;
  final Widget Function(TagLibraryEntry entry) rowFor;
  final void Function(_DraggedTag dragged)? onDrop;

  @override
  Widget build(BuildContext context) {
    final count = group.entries.length;
    final drop = onDrop;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 8),
        if (drop == null)
          _header(context, hovering: false)
        else
          DragTarget<_DraggedTag>(
            onAcceptWithDetails: (details) => drop(details.data),
            builder: (context, candidates, _) =>
                _header(context, hovering: candidates.isNotEmpty),
          ),
        if (expanded)
          for (var i = 0; i < count; i++) ...[
            if (i > 0) const Divider(height: 1),
            rowFor(group.entries[i]),
          ],
      ],
    );
  }

  Widget _header(BuildContext context, {required bool hovering}) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final count = group.entries.length;
    final empty = count == 0;
    // **A heading must not read as a row** — Michael's phone, 2026-09-30:
    // *"The project names are smaller than the tags and the same color."*
    // They were 14 points against the rows' 18. Now larger and bolder than a
    // row, on a tinted band, so the shape says "heading" before the words do.
    final foreground = scheme.onSecondaryContainer;
    return Semantics(
      button: !empty,
      expanded: empty ? null : expanded,
      header: true,
      child: Container(
        key: ValueKey('tag_library_group_band_${group.key}'),
        decoration: BoxDecoration(
          color: scheme.secondaryContainer,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: hovering ? scheme.primary : Colors.transparent,
            width: 2,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            key: ValueKey('tag_library_group_header_${group.key}'),
            // An empty heading has nothing to open; it is there to be
            // dropped on.
            onTap: empty ? null : onToggle,
            child: ConstrainedBox(
              constraints: const BoxConstraints(
                minHeight: DesignTokens.minTouchTarget,
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 8,
                  vertical: 6,
                ),
                child: Row(
                  children: [
                    Icon(
                      hovering
                          ? Icons.add_circle_outline
                          : empty
                          ? Icons.folder_outlined
                          : expanded
                          ? Icons.expand_more
                          : Icons.chevron_right,
                      color: foreground,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        group.title,
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontSize: 20,
                          fontWeight: FontWeight.w700,
                          color: foreground,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      count == 1 ? '1 tag' : '$count tags',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: foreground,
                      ),
                    ),
                    if (reorderIndex != null)
                      ReorderableDragStartListener(
                        key: ValueKey('tag_library_reorder_${group.key}'),
                        index: reorderIndex!,
                        child: Semantics(
                          label: 'Move ${group.title}',
                          child: SizedBox(
                            width: DesignTokens.minTouchTarget,
                            height: DesignTokens.minTouchTarget,
                            child: Icon(Icons.drag_handle, color: foreground),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// What follows the finger while a tag is dragged: its line, on a card.
class _DragFeedback extends StatelessWidget {
  const _DragFeedback({required this.entry});
  final TagLibraryEntry entry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      elevation: 6,
      borderRadius: BorderRadius.circular(8),
      color: theme.colorScheme.surface,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 280),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Text(
            '${entry.frequencyMhz.toStringAsFixed(3)} MHz · ${entry.tagName}',
            style: theme.textTheme.titleMedium,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ),
    );
  }
}

/// Orders [tags] for display and export (task 11.178).
///
/// [TagSortOrder.name] uses [naturalCompare] rather than a plain string sort:
/// this project's tag names are frequently numeric-ish (`"148.123"`,
/// `"Tag 7"`, `"Tag 10"`), and a plain sort would put `"Tag 10"` before
/// `"Tag 7"`. Ties within a name break on frequency, matching
/// [TagRepository.findAll]'s own tiebreak.
List<T> sortTags<T extends TagFields>(List<T> tags, TagSortOrder order) {
  final sorted = List<T>.of(tags);
  switch (order) {
    case TagSortOrder.frequency:
      sorted.sort((a, b) {
        final cmp = a.frequencyMhz.compareTo(b.frequencyMhz);
        return cmp != 0 ? cmp : naturalCompare(a.tagName, b.tagName);
      });
    case TagSortOrder.name:
      sorted.sort((a, b) {
        final cmp = naturalCompare(a.tagName, b.tagName);
        return cmp != 0 ? cmp : a.frequencyMhz.compareTo(b.frequencyMhz);
      });
  }
  return sorted;
}

/// Whether the signed-in user may put a copy of a library tag into the
/// **active project** — the pre-check for the create form's "Also add to"
/// choice, asking the same question `TagRepository.insert` asks so the
/// control and the write can never disagree (task 11.12).
///
/// **It no longer gates the create button itself (task 11.219).** Creating a
/// library entry writes a device-local row in no project, so there is no
/// role to refuse it with — see this screen's own doc comment. What a
/// `viewer` still cannot do is put a copy into the project they are a viewer
/// on, which is exactly what this answers.
final mayCopyTagIntoActiveProjectProvider = FutureProvider<bool>((ref) async {
  final projectId = await ref.watch(activeProjectIdProvider.future);
  if (projectId == null) return false;
  return ref.watch(mayWriteProjectDataProvider(projectId).future);
});

/// How many of this device's projects hold a copy of the collar [lineageId]
/// identifies — §2.5's count, and **a count is all it is**.
///
/// Naming the projects would tell somebody a project exists that they may
/// only be a viewer on, which is the disclosure cancelled task 11.29 left a
/// standing rule against. See [TagLibraryRepository.libraryCopyCount].
final tagCopyCountProvider =
    FutureProvider.family<int, String>((ref, lineageId) async {
  final repo = await ref.watch(tagLibraryRepositoryProvider.future);
  return repo.libraryCopyCount(lineageId);
});
/// **Public only so a test can pump it.** Reaching this screen through the
/// app means going through a file picker, which a widget test cannot drive,
/// and §2.8's sentence about lineage is the kind of copy this project has
/// twice shipped wrong and found later. Nothing outside this file constructs
/// it.
class TagImportPreviewScreen extends StatefulWidget {
  const TagImportPreviewScreen({super.key, required this.preview});
  final TagCsvPreview preview;

  @override
  State<TagImportPreviewScreen> createState() => _TagImportPreviewScreenState();
}

class _TagImportPreviewScreenState extends State<TagImportPreviewScreen> {
  /// Row numbers of duplicate-flagged rows the user has chosen to drop from
  /// the import rather than commit — task 11.13's per-row "skip this one",
  /// offered because editing three duplicate rows out of a forty-row file is
  /// otherwise a re-export-and-re-import round trip.
  final Set<int> _skipped = {};

  @override
  Widget build(BuildContext context) {
    final preview = widget.preview;
    final toImport = preview.validRows.length - _skipped.length;
    return Scaffold(
      appBar: AppBar(title: const Text('Import preview')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(DesignTokens.spacingScreenHorizontal),
            child: Text(
              '${preview.validRows.length} valid · '
              '${preview.invalidRows.length} with issues'
              '${preview.warnedRows.isEmpty ? '' : ' · '
                  '${preview.warnedRows.length} changed on import'}'
              '${preview.duplicateRows.isEmpty ? '' : ' · '
                  '${preview.duplicateRows.length} look like existing tags'}',
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
          ),
          // **§2.8, in words, at the one moment the person is reading.** A
          // spreadsheet cannot say which collar a row *is*: a `lineage_id`
          // is what says two projects hold one animal, and a file that
          // could assert one could assert that two unrelated collars are
          // the same — a claim about the primary scientific record. So the
          // import mints one per row and the loss is stated rather than
          // discovered. The archive is the artefact that preserves lineage;
          // the CSV is for people and spreadsheets.
          Padding(
            padding: const EdgeInsets.fromLTRB(
              DesignTokens.spacingScreenHorizontal,
              0,
              DesignTokens.spacingScreenHorizontal,
              DesignTokens.spacingScreenHorizontal,
            ),
            child: Text(
              'These become new tags in your library. A row for a tag you '
              'already have makes a second, separate tag.',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(
            child: ListView.separated(
              itemCount: preview.rows.length,
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (context, i) {
                final row = preview.rows[i];
                final skippable = row.isValid && row.hasDuplicates;
                final isSkipped = _skipped.contains(row.rowNumber);
                return ListTile(
                  leading: Icon(
                    row.isValid ? Icons.check_circle_outline : Icons.error_outline,
                    color: row.isValid ? Colors.green : Colors.red,
                  ),
                  title: Text(
                    'Row ${row.rowNumber}: '
                    '${row.raw['tag_name'] ?? '?'} · ${row.raw['frequency_mhz'] ?? '?'} MHz',
                    style: isSkipped
                        ? const TextStyle(decoration: TextDecoration.lineThrough)
                        : null,
                  ),
                  // Warnings and duplicate matches render on a *valid* row,
                  // which is the whole of finding L-15: the row is kept and
                  // something about it needs a look, and the preview is where
                  // the user is deciding. Same basis as task 11.11's dialog —
                  // frequency first, name second, naming the existing tag
                  // that matched — never a refusal, since two collars can
                  // legitimately share a nominal frequency.
                  subtitle: row.isValid
                      ? (row.warnings.isEmpty && row.duplicates.isEmpty
                            ? null
                            : Text(
                                [
                                  ...row.warnings,
                                  ...row.duplicates.map((d) => 'Looks like ${d.summary}'),
                                ].join('\n'),
                              ))
                      : Text(row.issues.join('; ')),
                  trailing: skippable
                      ? Tooltip(
                          message: 'Skip this row',
                          child: Checkbox(
                            value: isSkipped,
                            onChanged: (value) => setState(() {
                              if (value ?? false) {
                                _skipped.add(row.rowNumber);
                              } else {
                                _skipped.remove(row.rowNumber);
                              }
                            }),
                          ),
                        )
                      : null,
                );
              },
            ),
          ),
          SafeArea(
            minimum: const EdgeInsets.fromLTRB(20, 0, 20, 12),
            child: SizedBox(
              width: double.infinity,
              height: 48,
              child: FilledButton(
                onPressed: toImport == 0
                    ? null
                    : () => Navigator.of(context).pop(_skipped),
                child: Text('Import $toImport tags'),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
