import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/providers/app_context_provider.dart';
import '../../../core/providers/device_id_provider.dart';
import '../../../core/providers/pulse_rate_unit_provider.dart';
import '../../../core/providers/tag_view_refresh.dart';
import '../../../core/text/tag_status_labels.dart';
import 'package:tritrack_sync/tritrack_sync.dart';
import '../../../data/models/tag.dart';
import '../../../data/models/tag_library_entry.dart';
import '../../../data/repositories/mutation_authorization.dart';
import '../../../data/repositories/repository_providers.dart';
import '../../../data/repositories/tag_version_repository.dart';
import '../../../core/providers/tag_sort_provider.dart';
import '../../../data/tags/library_groups.dart';
import '../../../widgets/disabled_reason.dart';
import '../../../widgets/load_failure.dart';
import '../../../widgets/tag_edit_intent_dialog.dart';
import '../../../widgets/tag_form.dart';

/// **This project's tags — task 11.245.**
///
/// Moved here from Project Setup, which is settings again (design §3,
/// Michael, 2026-09-14). A tag is equipment, so this is where a person on
/// the More menu thinks to look for it, beside `More → Animals`.
///
/// ## Flat, not grouped
///
/// Task 11.241 grouped these rows under the animal wearing each collar; task
/// 11.244 gave the animals a screen of their own with the fuller version of
/// that story (every deployment, dated, with link/close/withdraw), so the
/// grouping here would be a second, weaker rendering of the same fact. **A
/// flat list, tag ID first, the linked animal's name as a subtitle where
/// there is one** — Michael: *"I want the add tags to live primarily in the
/// tags database manager"* — is the whole of what this screen shows.
///
/// ## "+ New tag" is gone
///
/// A tag is created on the Tag Library screen (`More → Tag Library`, the
/// device's own inventory) and copied in here with **Copy from library**.
/// Nothing on this screen mints a new tag id.
///
/// ## A tag with no animal is the normal starting state (design §1)
///
/// Nothing here hides it, lists it last, or marks it incomplete — it is an
/// ordinary row with no second line, exactly like one with an animal has a
/// second line naming it.
class TagsScreen extends ConsumerWidget {
  const TagsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final projectAsync = ref.watch(currentProjectProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Tags')),
      body: projectAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => LoadFailure('the current project', error: e),
        data: (project) => project == null
            ? const _NoProject()
            : _TagsBody(projectId: project.projectId),
      ),
    );
  }
}

class _NoProject extends StatelessWidget {
  const _NoProject();

  @override
  Widget build(BuildContext context) => const Padding(
    padding: EdgeInsets.all(24),
    child: Center(
      child: Text(
        'No project is active. Choose one under More → Projects, and the '
        'tags it holds are listed here.',
        textAlign: TextAlign.center,
      ),
    ),
  );
}

class _TagsBody extends ConsumerWidget {
  const _TagsBody({required this.projectId});
  final String projectId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tagsAsync = ref.watch(projectTagsProvider(projectId));
    // Task 11.12: adding (copying one in, or putting a removed one back) is
    // contributor-level (task 11.11's `anyUser` rung) — additive, it
    // unblocks field work.
    //
    // The standing rather than the bare bool since task 11.237, because the
    // banner's sentence depends on *why*: a viewer's, or a snapshot's.
    final standingAsync = ref.watch(myProjectStandingProvider(projectId));
    // Removing is the opposite case the same decision names: subtractive, it
    // edits shared project configuration every member sees, so it needs the
    // higher rung — a *different* question from `mayWrite` above, not a
    // stricter reading of it. See `TagRepository.removeFromProject`.
    final isOwnerAsync = ref.watch(isProjectOwnerProvider(projectId));

    return tagsAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) =>
          LoadFailure('the tags on this project', error: e, centered: false),
      data: (tags) => standingAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => LoadFailure(
          'what you are allowed to change here',
          error: e,
          centered: false,
        ),
        data: (standing) => isOwnerAsync.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => LoadFailure(
            'what you are allowed to change here',
            error: e,
            centered: false,
          ),
          data: (isOwner) {
            final mayWrite = standing.mayWriteProjectData;
            final writeRefusal = standing.writeRefusal(
              asViewer:
                  'Viewers cannot change a project\'s tags — ask an owner to '
                  'change your role.',
            );
            final sorted = [...tags]
              ..sort((a, b) => a.frequencyMhz.compareTo(b.frequencyMhz));

            // **One scrollable for the whole screen, not one around the list
            // alone.** A `ListView` around only the rows leaves "Copy from
            // library" outside any `Scrollable` when the list is empty (no
            // `ListView` is built at all) — reachable by nothing that scrolls
            // to find it. The rows themselves are built plainly rather than
            // lazily: a person's tag count is dozens at most, never the
            // thousands a `ListView.builder` exists for.
            return SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (writeRefusal != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: Theme.of(
                            context,
                          ).colorScheme.errorContainer.withValues(alpha: 0.4),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Row(
                          children: [
                            const Icon(Icons.lock_outline, size: 18),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                writeRefusal,
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                  color: Theme.of(
                                    context,
                                  ).colorScheme.onErrorContainer,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  if (sorted.isEmpty)
                    const _NoTagsYet()
                  else
                    // Divided like the Tag Library's list, not boxed (task
                    // 11.321: one look for a tag list).
                    Column(
                      children: [
                        for (var i = 0; i < sorted.length; i++) ...[
                          if (i > 0) const Divider(height: 1),
                          _TagRow(
                            tag: sorted[i],
                            projectId: projectId,
                            isOwner: isOwner,
                            mayWrite: mayWrite,
                          ),
                        ],
                      ],
                    ),
                  const SizedBox(height: 8),
                  OutlinedButton(
                    onPressed: mayWrite
                        ? () => _copyFromLibrary(context, ref, sorted)
                        : null,
                    child: const Text('Copy from library'),
                  ),
                  DisabledReasonNote(
                    reason: tagsSectionDisabledReason(
                      mayWrite: mayWrite,
                      isOwner: isOwner,
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  /// Copies a transmitter out of this device's tag library into this
  /// project.
  ///
  /// **A copy, not a link, and the dialog says so** — that is the one moment
  /// the person is definitely reading (§2.5). What lands is a new row with
  /// its own id and the library entry's lineage, so editing it here changes
  /// this project and leaves the library and every other project alone.
  ///
  /// A collar this project already holds is not offered again: two copies of
  /// one lineage inside one project is a real defect with no legitimate use,
  /// and it is refused here rather than warned about (§2.6).
  Future<void> _copyFromLibrary(
    BuildContext context,
    WidgetRef ref,
    List<Tag> projectTags,
  ) async {
    final library = await ref.read(tagLibraryRepositoryProvider.future);
    final candidates =
        libraryEntriesNotOnProject(await library.findAll(), projectTags);

    if (!context.mounted) return;
    final selected = await showDialog<TagLibraryEntry>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('Copy a tag into this project'),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 12),
            child: Text(
              candidates.isEmpty
                  ? 'Every tag in your library is already on this project. '
                        'Add a new one to your library from the Tag Library '
                        'screen.'
                  : 'This project gets its own copy. Changing it here will '
                        'not change your library or any other project.',
            ),
          ),
          for (final entry in candidates)
            SimpleDialogOption(
              onPressed: () => Navigator.of(context).pop(entry),
              child: Text(
                '${entry.frequencyMhz.toStringAsFixed(3)} MHz · '
                '${entry.tagName}',
              ),
            ),
        ],
      ),
    );
    if (selected == null || !context.mounted) return;

    final now = DateTime.now();
    final user = await ref.read(currentUserProvider.future);
    final deviceId = await ref.read(deviceIdProvider.future);
    final tagRepo = await ref.read(tagRepositoryProvider.future);
    // The button that reaches this is disabled for a viewer (task 11.12);
    // this catch is the backstop for the moment between a role change and a
    // rebuild.
    try {
      await tagRepo.copyFromLibrary(
        selected,
        projectId: projectId,
        modifiedBy: user.userId,
        deviceId: deviceId,
        now: now,
      );
    } on UnauthorizedMutation catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              e.refusalSentence(
                asViewer:
                    'Viewers cannot change a project\'s tags — ask an owner to '
                    'change your role.',
              ),
            ),
          ),
        );
      }
      return;
    }
    // Task 11.151: one call, every view of this project's tags.
    refreshTagViews(ref, projectId: projectId);
  }
}

class _NoTagsYet extends StatelessWidget {
  const _NoTagsYet();

  @override
  Widget build(BuildContext context) => const Padding(
    padding: EdgeInsets.all(24),
    child: Center(
      child: Text(
        'No tags on this project yet. Copy one in from your tag library.',
        textAlign: TextAlign.center,
      ),
    ),
  );
}

/// Why "Copy from library" is unavailable, or null when the section needs no
/// line of its own.
///
/// **One sentence for the whole section, not one per control (task 11.138).**
///
/// **A viewer is deliberately not answered here**, and that is not an
/// oversight: the section already opens with a lock banner saying exactly
/// what a viewer cannot do, in the open, a few pixels above these controls. A
/// second copy under them would be the same sentence twice on one screen,
/// which reads as a rendering fault rather than as an explanation.
///
/// What was genuinely unsaid is the **contributor** case. Copying a tag in is
/// contributor-level (task 11.11), but *changing* one the project already
/// holds — removing it, putting a removed one back, editing its frequency or
/// name — is owner-only, because it edits shared configuration every member
/// sees and rewrites what earlier bearings were taken against. So a
/// contributor sees no banner, may copy a tag in, and finds a greyed icon on
/// every row and a greyed "Add back" on every removed one, with nothing
/// anywhere saying why. That is the sentence below.
String? tagsSectionDisabledReason({
  required bool mayWrite,
  required bool isOwner,
}) {
  if (!mayWrite) return null;
  if (!isOwner) {
    return 'You can copy tags into this project. Only a project owner can '
        'change one the project already has, or remove or restore it.';
  }
  return null;
}

class _TagRow extends ConsumerWidget {
  const _TagRow({
    required this.tag,
    required this.projectId,
    required this.isOwner,
    required this.mayWrite,
  });

  /// This project's own copy of the collar. **Not a link row** — task 11.219
  /// retired `Project_Tags`; the project holds the tag.
  final Tag tag;
  final String projectId;

  /// Gates "Remove from project" (task 11.12, decision 2026-08-21) **and,
  /// since task 11.221, "Add back"**: both change a tag the project already
  /// holds, and every change to an existing tag needs the owner rung, not
  /// the coarser `mayWrite` the section resolves for "Copy from library". It
  /// also gates **editing** the tag, which is where task 11.11's owner-only
  /// rule now lands: changing a frequency or a name rewrites what every
  /// bearing already recorded against this tag means. A non-owner still
  /// opens the form and reads all of it — see [TagViewOnlyBanner] and
  /// Michael's 2026-09-06 decision that a refusal must not be the end of the
  /// road.
  final bool isOwner;
  final bool mayWrite;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // "Removed from this project" is a tombstone on this row since task
    // 11.219, where it used to be `Project_Tags.status = inactive`. Nothing
    // is deleted: every bearing naming this tag still resolves.
    final isActive = !tag.sync.isDeleted;
    // §3a: the linked animal's name as a subtitle where there is one. **No
    // second line at all is the ordinary state**, not a gap this row fills
    // with a placeholder — a collar with no animal is design §1's normal
    // starting state.
    final subtitleParts = [
      if (tag.individualName != null) 'Worn by ${tag.individualName}',
      if (!isActive) 'Removed from this project',
      if (tag.status != TagStatus.active) tagStatusLabel(tag.status),
    ];
    // **The Tag Library's row** (task 11.321 — Michael: *"shouldn't the
    // format of the tag list in the project tag list be the same as the nice
    // formatting/size you did for the tag library?"*): one 18-point line,
    // frequency first because this list is in frequency order, and the
    // status icon. What only this list knows stays — who wears the tag, a
    // removed tag struck through, and the remove / Add back button.
    return TagListRow(
      tag: tag,
      sortOrder: TagSortOrder.frequency,
      onTap: () => _openTag(context, ref),
      subtitle: subtitleParts.isEmpty ? null : subtitleParts.join(' · '),
      removed: !isActive,
      // Task 11.94/11.101 exemption: labelled only by `tooltip:`, adopting
      // task 11.99's line (see `_ReadmitButton` in
      // `project_members_screen.dart`) — alone at the end of its row, not
      // beside a destructive twin, and `_remove` confirms before acting.
      //
      // Task 11.138: the tooltip used to swap its *label* for a *reason*
      // when disabled, which meant the reason was unreadable on a phone and
      // the label vanished on a pointer. It is the label again, always, and
      // [tagsSectionDisabledReason] says why once under the section rather
      // than once per tag row.
      action: isActive
          ? Tooltip(
              message: 'Remove from project',
              child: IconButton(
                icon: const Icon(Icons.link_off),
                onPressed: isOwner ? () => _remove(context, ref) : null,
              ),
            )
          : TextButton(
              onPressed: isOwner ? () => _reactivate(context, ref) : null,
              child: const Text('Add back'),
            ),
    );
  }

  /// Opens **this project's copy** of the collar in the shared tag form.
  ///
  /// ## This is where the owner-only tag rule lives now (task 11.219)
  ///
  /// It used to be on the Tag Database screen, because that was where every
  /// tag was edited. That screen shows the device's own tag *library* now,
  /// which no role governs. What an owner-only rule protects is what a
  /// bearing was recorded against, and that is this row.
  ///
  /// **A non-owner opens the form and reads all of it**, under the same
  /// banner, with the same words and the same `tag_edit_not_permitted` key —
  /// Michael's decision of 2026-09-06, that a refusal must not be the end of
  /// the road, applied where the refusal moved to.
  Future<void> _openTag(BuildContext context, WidgetRef ref) async {
    final copies = await ref
        .read(tagLibraryRepositoryProvider.future)
        .then(
          (library) =>
              library.otherProjectCopyCount(tag.lineageId, tag.projectId),
        );
    if (!context.mounted) return;
    final result = await showDialog<TagEditResult>(
      context: context,
      builder: (context) => TagEditDialog(
        existing: tag,
        readOnly: !isOwner,
        initialColorHex: tag.colorHex,
        projectCopyCount: copies,
      ),
    );
    if (result == null) return;
    final edited = result.draft.onto(tag);

    // **Task 11.32.** Editing a frequency, a pulse mode, a pulse pattern or a
    // name changes what every bearing already recorded against this tag was
    // taken against — and whether that is right depends entirely on why the
    // person is editing. Ask, and only when it matters: a recolour, a status
    // change or an edited note leaves this false and goes straight through.
    TagEditIntent? intent;
    if (TagVersionRepository.versionedFieldsChanged(tag, edited)) {
      if (!context.mounted) return;
      intent = await askTagEditIntent(
        context,
        before: tag,
        after: edited,
        unit: ref.read(pulseRateUnitProvider),
      );
      // Dismissed without choosing: the edit does not happen. There is no
      // safe way to proceed — either answer would be a guess about the
      // meaning of every earlier record.
      if (intent == null) return;
    }

    final user = await ref.read(currentUserProvider.future);
    final deviceId = await ref.read(deviceIdProvider.future);
    final tagRepo = await ref.read(tagRepositoryProvider.future);
    try {
      await tagRepo.update(
        edited,
        actor: MutationActor.user(user.userId),
        intent: intent,
        deviceId: deviceId,
      );
    } on UnauthorizedMutation {
      // The form is read-only for a non-owner, so this is the backstop for a
      // role that changed while it was open.
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Only a project owner can change this project\'s tags — ask '
              'an owner.',
            ),
          ),
        );
      }
      return;
    }
    refreshTagViews(ref, projectId: projectId);
  }

  Future<void> _remove(BuildContext context, WidgetRef ref) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Remove ${tag.tagName} from this project?'),
        content: const Text(
          'It stops appearing in this project\'s pickers. The tag stays in '
          'your library, and past records are unaffected. You can undo it '
          'straight after.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;

    final user = await ref.read(currentUserProvider.future);
    if (!context.mounted) return;
    final deviceId = await ref.read(deviceIdProvider.future);
    if (!context.mounted) return;
    final repo = await ref.read(tagRepositoryProvider.future);
    if (!context.mounted) return;
    // The icon that reaches this is disabled for a non-owner (task 11.12);
    // this catch is the backstop for the moment between a role change and a
    // rebuild.
    try {
      await repo.removeFromProject(
        tag.tagId,
        projectId: projectId,
        actor: MutationActor.user(user.userId),
        deviceId: deviceId,
      );
    } on UnauthorizedMutation {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Only a project owner can remove a tag from a project — ask '
              'an owner.',
            ),
          ),
        );
      }
      return;
    }
    // The map's legend and ray colours are keyed by the project's tags, so
    // adding or removing one has to reach it (task 11.45), and since task
    // 11.151 the same call refreshes the list above and the Record screen's
    // tag wheel.
    refreshTagViews(ref, projectId: projectId);

    if (!context.mounted) return;
    ScaffoldMessenger.of(context).clearSnackBars();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('${tag.tagName} removed from project'),
        duration: const Duration(seconds: 6),
        // Task 11.42: an action makes this default to `persist: true`
        // (Material 3), which leaves `duration` dead — see
        // `projects_screen.dart`'s delete-project undo bar for the finding.
        persist: false,
        action: SnackBarAction(
          label: 'UNDO',
          onPressed: () async {
            await repo.restoreToProject(
              tag.tagId,
              projectId: projectId,
              actor: MutationActor.user(user.userId),
              deviceId: deviceId,
            );
            refreshTagViews(ref, projectId: projectId);
          },
        ),
      ),
    );
  }

  Future<void> _reactivate(BuildContext context, WidgetRef ref) async {
    final user = await ref.read(currentUserProvider.future);
    if (!context.mounted) return;
    final deviceId = await ref.read(deviceIdProvider.future);
    if (!context.mounted) return;
    final repo = await ref.read(tagRepositoryProvider.future);
    // Same backstop as `_remove` above.
    try {
      await repo.restoreToProject(
        tag.tagId,
        projectId: projectId,
        actor: MutationActor.user(user.userId),
        deviceId: deviceId,
      );
    } on UnauthorizedMutation {
      // Owner-only since task 11.221, so the person this reaches lost
      // ownership between the row rendering and the tap — a viewer *or* a
      // contributor. The old wording named viewers, which is now the wrong
      // cause for half of them.
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Only a project owner can add a tag back to a project — ask an '
              'owner.',
            ),
          ),
        );
      }
      return;
    }
    refreshTagViews(ref, projectId: projectId);
  }
}
