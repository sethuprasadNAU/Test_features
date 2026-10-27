import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:uuid/uuid.dart';

import '../../../core/errors/guarded_write.dart';
import '../../../data/repositories/project_standing.dart';

import '../../../core/format/coordinate_formatter.dart';
import '../../../core/format/observation_quality_display.dart';
import '../../../core/format/pulse_rate_format.dart';
import '../../../core/providers/app_context_provider.dart';
import '../../../core/providers/database_provider.dart';
import '../../../core/providers/device_id_provider.dart';
import '../../../core/providers/pulse_rate_unit_provider.dart';
import '../../../core/providers/tag_view_refresh.dart';
import '../../../core/providers/shared_observation_preview_provider.dart';
import '../../../core/text/role_labels.dart';
import '../../../core/theme/design_tokens.dart';
import 'package:tritrack_sync/tritrack_sync.dart';
import '../../../data/models/project.dart';
import '../../../data/models/sync_meta.dart';
import '../../../data/models/tag.dart';
import '../../../data/repositories/repository_providers.dart';
import '../../../data/sharing/observation_share.dart';
import '../../../data/sharing/shared_observation_importer.dart';
import '../../../widgets/disabled_reason.dart';
import '../../../widgets/near_duplicate_tag_dialog.dart';

/// Observation Sharing (design doc §10): the paste/preview half — copying is
/// a per-row action on Log. Pasting parses a
/// [SharedObservation], previews it, resolves the "tag key" against the
/// **active project's** tag list (offering to create it if unknown, or
/// continue unlinked), and can push it onto Main Map as a temporary overlay
/// or save it as a real local observation once a tag is resolved.
class ObservationSharingScreen extends ConsumerStatefulWidget {
  const ObservationSharingScreen({super.key});

  @override
  ConsumerState<ObservationSharingScreen> createState() => _ObservationSharingScreenState();
}

class _ObservationSharingScreenState extends ConsumerState<ObservationSharingScreen> {
  final _pasteController = TextEditingController();
  SharedObservation? _parsed;
  String? _parseError;
  Tag? _matchedTag;

  @override
  void dispose() {
    _pasteController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final projectAsync = ref.watch(currentProjectProvider);
    // Task 11.218: this used to match a pasted payload against
    // `localTagsProvider` — every tag on the device, not just this project's
    // — so an imported record could name another project's tag and be held.
    // No active project means nothing to match against.
    final activeProjectId = projectAsync.value?.projectId;
    final tagsAsync = activeProjectId == null
        ? const AsyncValue<List<Tag>>.data(<Tag>[])
        : ref.watch(projectActiveTagsProvider(activeProjectId));
    // Task 11.14: "Create tag" and "Save observation" reached
    // `TagRepository.insert` / the observation importer with no pre-check at
    // all — a viewer pasted a payload, watched the preview, and only then hit
    // the raw refusal.
    //
    // **Both are now the same rung, and that is task 11.219's doing.** A tag
    // created here goes straight into the active project — the collar
    // belongs to whoever sent the bearing, so it is not added to this
    // device's library — so the question is the project write gradient, the
    // same one saving the observation asks.
    //
    // The standing rather than the bare bool since task 11.237, because the
    // sentence under a refused control depends on *why*: a viewer's, or a
    // snapshot's. "Permitted while unresolved" is the unknown standing, which
    // is what `?? true` always meant here.
    final project = projectAsync.value;
    final standing = project == null
        ? const ProjectStanding.member(ProjectRole.viewer)
        : ref.watch(myProjectStandingProvider(project.projectId)).value ??
              ProjectStanding.unknown;
    final mayCreateTag = project != null && standing.mayWriteProjectData;
    final mayWrite = project != null && standing.mayWriteProjectData;

    return Scaffold(
      appBar: AppBar(title: const Text('Observation Sharing')),
      body: ListView(
        padding: const EdgeInsets.all(DesignTokens.spacingScreenHorizontal),
        children: [
          const Text(
            'Paste a payload copied from another device (Log → Share):',
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _pasteController,
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              hintText: 'TT1:...',
            ),
            minLines: 3,
            maxLines: 6,
          ),
          const SizedBox(height: 8),
          // Task 11.126: measured overflowing by 63 logical pixels at
          // 6.1-inch phone width — this screen had only ever been rendered on
          // an 800-pixel-wide test surface, and "Paste from clipboard" was
          // cut off on every phone. A `Wrap` lets the second button drop to
          // its own line instead of running off the edge.
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton(onPressed: () => _parse(tagsAsync.value ?? []), child: const Text('Parse')),
              OutlinedButton(
                onPressed: () async {
                  final data = await Clipboard.getData('text/plain');
                  if (data?.text != null) {
                    _pasteController.text = data!.text!;
                    _parse(tagsAsync.value ?? []);
                  }
                },
                child: const Text('Paste from clipboard'),
              ),
            ],
          ),
          if (_parseError != null) ...[
            const SizedBox(height: 12),
            Text(_parseError!, style: const TextStyle(color: Colors.red)),
          ],
          if (_parsed != null) ...[
            const SizedBox(height: 16),
            _PreviewCard(
              shared: _parsed!,
              coordinateFormat: projectAsync.value?.coordinateFormat ?? CoordinateFormat.dd,
              unit: ref.watch(pulseRateUnitProvider),
            ),
            // Stated before saving, not just after: this is the one case where
            // saving knowingly creates a record that may duplicate the
            // sender's, and the user should be able to decide not to.
            if (!_parsed!.canReplicate) ...[
              const SizedBox(height: 12),
              const Text(
                'This is from an older app version, so saving it creates a new '
                'observation owned by you, not the original observer, and it may '
                'duplicate their record. Ask them to re-share from an updated '
                'app if that matters.',
                style: TextStyle(color: Colors.orange, fontWeight: FontWeight.w700),
              ),
            ],
            const SizedBox(height: 12),
            if (_matchedTag != null)
              Text('Matches local tag: ${_matchedTag!.tagName}',
                  style: const TextStyle(color: Colors.green, fontWeight: FontWeight.w700))
            else ...[
              const Text(
                'Tag not known locally.',
                style: TextStyle(color: Colors.orange, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 8),
              // Same measurement, same fix as the Parse row above: 64
              // logical pixels over at phone width.
              Wrap(
                                spacing: 8,
                runSpacing: 8,
                children: [
                  OutlinedButton(
                    onPressed: mayCreateTag ? () => _createTag() : null,
                    child: const Text('Create tag'),
                  ),
                  TextButton(
                    onPressed: () {}, // "Continue unlinked" — no-op, banner just stays informational.
                    child: const Text('Continue unlinked'),
                  ),
                ],
              ),
              // Task 11.138: this reason was in a `Tooltip` on the button, and
              // a touchscreen never shows one — a viewer saw "Create tag"
              // greyed out and was told nothing. It takes no height at all for
              // somebody who can create a tag.
              DisabledReasonNote(
                reason: mayCreateTag
                    ? null
                    : standing.writeRefusal(
                        asViewer:
                            'Viewers cannot create tags — ask an owner to '
                            'change your role.',
                      ),
              ),
            ],
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () {
                      ref.read(sharedObservationPreviewProvider.notifier).set(_parsed);
                      context.go('/map');
                    },
                    child: const Text('Show on map'),
                  ),
                                ),
                const SizedBox(width: 8),
                Expanded(
                  child: FilledButton(
                    onPressed:
                        _matchedTag == null || project == null || !mayWrite
                        ? null
                        : () => _saveObservation(project.projectId),
                    child: const Text('Save observation'),
                  ),
                ),
              ],
            ),
            // Task 11.138. The `Tooltip` this replaces named only one of the
            // three things that grey this button out, so a person with no
            // active project, or a payload whose tag this device does not
            // know, got a greyed control and a tooltip they could not open
            // saying nothing about their case either way.
            DisabledReasonNote(reason: _saveDisabledReason(project, standing)),
          ],
        ],
      ),
    );
  }

  /// Why "Save observation" is unavailable, or null when it is available.
  ///
  /// Ordered by what the person can act on first: a missing project is fixed
  /// on another screen, a missing tag is fixed by the "Create tag" button a
  /// few pixels above, and a role is fixed by asking somebody. Only the last
  /// of the three was ever said out loud before task 11.138.
  String? _saveDisabledReason(Project? project, ProjectStanding standing) {
    if (project == null) {
      return 'Choose an active project before saving — Projects, then tap one.';
    }
    final refusal = standing.writeRefusal(
      asViewer:
          'Viewers cannot save observations — ask an owner to change your '
          'role.',
    );
    if (refusal != null) return refusal;
    if (_matchedTag == null) {
      return 'This device does not know the tag in this payload. Create it '
          'above, and the observation can be saved against it.';
    }
    return null;
  }

  void _parse(List<Tag> localTags) {
    setState(() {
      _parseError = null;
      _parsed = null;
      _matchedTag = null;
    });
    try {
      final shared = ObservationShare.decode(_pasteController.text);
      Tag? match;
      for (final tag in localTags) {
        if (shared.matchesTag(tag)) {
          match = tag;
          break;
        }
      }
      setState(() {
        _parsed = shared;
        _matchedTag = match;
      });
    } on ObservationShareFormatException catch (e) {
      setState(() => _parseError = e.message);
    }
  }

  Future<void> _createTag() async {
    final shared = _parsed;
    if (shared == null) return;
    final now = DateTime.now();
    final deviceId = await ref.read(deviceIdProvider.future);
    final user = await ref.read(currentUserProvider.future);
    final tagRepo = await ref.read(tagRepositoryProvider.future);

    final project = ref.read(currentProjectProvider).value;
    if (project == null) return;
    final tagId = const Uuid().v4();
    final tag = Tag(
      tagId: tagId,
      projectId: project.projectId,
      // **Its own id is its lineage, and the collar is not added to this
      // device's library** (task 11.219). A shared bearing describes
      // somebody else's transmitter: recording it as one of *yours* would
      // claim their equipment, and asserting a lineage the payload does not
      // carry would claim their collar is one you already hold. The payload
      // carries a tag *key* — frequency, rate, name — and deliberately no
      // identifier, which is exactly why.
      lineageId: tagId,
      frequencyMhz: shared.tagFrequencyMhz,
      pulseRate: shared.tagPulseRate,
      tagName: shared.tagName,
      status: TagStatus.active,
      // **No animal** (task 11.243). This collar is somebody else's
      // equipment, met through one shared bearing; the payload says nothing
      // about what was wearing it, and naming an animal here would invent a
      // fact about a colleague's study. The value is never stored or read
      // back — see `Tag.colorHex`.
      colorHex: TagColorPalette.noIndividual,
      sync: SyncMeta.initial(now: now, modifiedBy: user.userId, originDeviceId: deviceId),
      // Task 11.187: a tag created from a payload gets the same two default
      // modes a tag created by hand gets, keeping the payload's rate on the
      // primary one. **The sender's mode name is deliberately not copied in.**
      // A payload carries the name of the one mode the shared bearing was
      // heard on and says nothing about the collar's other modes, so building
      // a mode set out of it would assert something nobody sent.
    ).withDefaultPulseModes();

    // The same pasted string reaches this write as reaches the observation
    // importer, and this half had no bound check at all while CSV import — the
    // less exposed of the two — has had one since Phase 4. §4.19 rule 5 is
    // about the path, not about which screen it starts on.
    final issues = RowValidator.validate(Tables.tags, tag.toColumns());
    if (issues.isNotEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Tag not created — ${issues.first}')),
      );
      return;
    }
    // Task 11.11. `_parse` already looked for an exact match and only offers
    // this button when it found none, but its rule is stricter than the
    // duplicate one (it compares pulse rate too), so a tag on the same
    // frequency under a different name reaches here unremarked.
    if (!mounted) return;
    switch (await checkNewTagAgainstExisting(
      context,
      ref,
      frequencyMhz: tag.frequencyMhz,
      tagName: tag.tagName,
      projectId: project.projectId,
    )) {
      case GoBackFromNewTag():
        return;
      // Task 11.324: the project already has this Tag ID and the person
      // kept it, so the shared bearing is saved on that tag.
      case UseExistingTag(tag: final existing):
        if (mounted) setState(() => _matchedTag = existing);
        return;
      case CreateNewTag():
        break;
    }
    // Task 11.14: the pre-check on the button already turns a viewer away
    // before this ever runs; this catch is only the backstop for the moment
    // between a role change and a rebuild — same two-layer defense as
    // `tag_database_screen.dart` and the observation-logging quick-add.
    if (!mounted) return;
    // Task 11.137 moved this onto the shared mechanism. The refusal sentence is
    // unchanged; what it did not have before is the other branch — a database
    // fault here wrote no tag and said nothing, so the Create button looked
    // dead.
    Tag stored = tag;
    final created = await runGuardedWrite(
      context,
      write: () async {
        stored = await tagRepo.insert(tag, recordInLibrary: false);
        // A tag created here to receive a shared bearing is a legend entry and
        // a ray colour on the map (task 11.45), and it has just joined this
        // project's tag set as well (task 11.151). The import itself announces
        // separately, from inside `SharedObservationImporter` — but the tag is
        // written first and stays even if the import is then refused.
        refreshTagViews(ref, projectId: project.projectId);
      },
      refused: 'Viewers cannot create tags — ask a project owner to change '
          'your role to contributor.',
      failed: 'Could not create this tag, so the bearing was not saved '
          'either. The pasted text is still in the box — try again, and '
          'report it if this keeps happening.',
    );
    if (!created || !mounted) return;
    setState(() => _matchedTag = stored);
  }

  Future<void> _saveObservation(String projectId) async {
    final shared = _parsed;
    final tag = _matchedTag;
    if (shared == null || tag == null) return;

    final deviceId = await ref.read(deviceIdProvider.future);
    final user = await ref.read(currentUserProvider.future);
    final db = await ref.read(appDatabaseProvider.future);

    // The importer owns identity/merge semantics: a v2 payload becomes a
    // faithful replica of the sender's row (same primary key, observer, and
    // sync clock), a v1 payload falls back to a receiver-owned copy.
    //
    // `confirmChanges` is left at its default. If the payload would replace
    // anything this device already holds, the importer writes nothing and hands
    // back the list — which is shown below and re-submitted only if the user
    // says yes. The record is not the app's to overwrite on a stranger's say-so.
    // Task 11.137. The importer decides for itself what to do with a payload
    // and reports the outcome in words below; what it had no answer for was the
    // import *throwing* — which wrote nothing, said nothing, and left the Save
    // button looking unresponsive with the pasted text still on screen.
    if (!mounted) return;
    late SharedObservationImportResult result;
    final imported = await runGuardedWrite(
      context,
      write: () async {
        result = await SharedObservationImporter(db.raw).save(
          shared,
          projectId: projectId,
          tagId: tag.tagId,
          receivingUserId: user.userId,
          receivingDeviceId: deviceId,
          newId: () => const Uuid().v4(),
        );
      },
      refused: 'You may not add records to this project, so this bearing was '
          'not saved. Ask an owner to make you a contributor.',
      failed: 'Could not save this bearing. The pasted text is still in the '
          'box — try again, and report it if this keeps happening.',
    );
    if (!imported || !mounted) return;

    if (result.outcome == SharedObservationImportOutcome.changeNeedsConfirmation) {
      if (!mounted) return;
      final accepted = await _confirmChanges(result);
      if (accepted != true) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Nothing changed — your copy was kept as it was.'),
          ),
        );
        return;
      }
      if (!mounted) return;
      final confirmedWrite = await runGuardedWrite(
        context,
        write: () async {
          result = await SharedObservationImporter(db.raw).save(
            shared,
            projectId: projectId,
            tagId: tag.tagId,
            receivingUserId: user.userId,
            receivingDeviceId: deviceId,
            newId: () => const Uuid().v4(),
            confirmChanges: true,
          );
        },
        refused: 'You may not change records in this project, so your copy '
            'is unchanged. Ask an owner to make you a contributor.',
        failed: 'Could not apply the pasted copy; your own record is '
            'unchanged. Try again, and report it if this keeps happening.',
      );
      if (!confirmedWrite || !mounted) return;
    }

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(sharedObservationOutcomeMessage(result)),
        duration: const Duration(seconds: 8),
      ),
    );
    if (!result.wrote) return;
    // An imported replica is a bearing that arrived from somebody else's
    // device; `SharedObservationImporter` tells the map when it writes one.
    // See `DataArrival` (task 11.45).
    setState(() {
      _parsed = null;
      _matchedTag = null;
      _pasteController.clear();
    });
  }

  /// Shows exactly which values the pasted payload would replace, and asks.
  ///
  /// The field list is the point. "This will update your copy" is the message
  /// finding J-1 shipped with, and it was true of a payload that moved an
  /// observation to (0,0) — a user cannot consent to a change they have not
  /// been shown.
  Future<bool?> _confirmChanges(SharedObservationImportResult result) {
    final destructive = result.destructiveChanges;
    final additions = result.changes.length - destructive.length;
    return showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('This would change your existing record'),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'You already hold this observation. Saving the pasted copy would '
                'replace ${destructive.length} '
                '${destructive.length == 1 ? 'value' : 'values'} you have now:',
              ),
              const SizedBox(height: 12),
              for (final change in destructive)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Text(
                    '${_columnLabel(change.column)}\n'
                    '${_valueLabel(change.was)}  →  ${_valueLabel(change.becomes)}',
                    style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                  ),
                ),
              if (additions > 0) ...[
                const SizedBox(height: 4),
                Text('$additions further ${additions == 1 ? 'field' : 'fields'} '
                    'currently empty would be filled in.'),
              ],
              const SizedBox(height: 12),
              const Text(
                'Your current version is kept and can be reviewed afterwards. '
                'Only accept this if you know where the payload came from.',
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Keep my copy'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Replace my copy'),
          ),
        ],
      ),
    );
  }

  static String _columnLabel(String column) =>
      column.replaceAll('_', ' ');

  static String _valueLabel(Object? value) =>
      value == null ? '(empty)' : '$value';

}

/// The sentence shown for one import outcome.
///
/// A top-level function rather than a method so it can be asserted directly:
/// real sqflite hangs inside `testWidgets` on this project (see
/// `app_context_provider_test.dart`), so a full paste-and-save widget test is
/// not available, and the wording is not a detail that can go untested.
/// Finding J-1's fourth and worst property was that the app reported a hostile
/// overwrite as *"updated it to the newer version"* — a correct-looking message
/// hiding harm, which 10.25's checklist has demanded be checked at every gate
/// since the first. `observation_sharing_messages_test.dart` asserts that no
/// outcome which wrote nothing borrows a success sentence.
String sharedObservationOutcomeMessage(SharedObservationImportResult result) {
    final mismatch = result.observerMatchedViaPriorEmail
        ? ' Matched via a previous email address on record for this observer.'
        : result.observerIdMismatch == null
            ? ''
            : ' Matched an existing local record for this observer.';
    switch (result.outcome) {
      case SharedObservationImportOutcome.replicaInserted:
        return 'Observation saved, attributed to the original observer.$mismatch';
      case SharedObservationImportOutcome.replicaUpdated:
        // Three sentences, because there are three genuinely different things
        // that can have happened and finding K-8 is what saying one of them
        // for all three costs. The old wording claimed *"replaced as you
        // confirmed — 0 values were changed"* on an update that destroyed
        // nothing and asked nothing: both halves false in the same breath, and
        // J-1's fourth property (a correct-looking message hiding harm)
        // reproduced inside J-1's own fix.
        final destroyed = result.destructiveChanges.length;
        if (result.confirmedByUser) {
          return 'Your copy was replaced as you confirmed — $destroyed '
              '${destroyed == 1 ? 'value was' : 'values were'} changed. Your '
              'previous version is kept and can be reviewed.$mismatch';
        }
        final added = result.changes.length;
        if (added == 0) {
          return 'Your copy was brought up to date — the newer version carries '
              'the same details, so nothing you had was changed. Your previous '
              'version is kept and can be reviewed.$mismatch';
        }
        return 'Your copy was updated — $added '
            '${added == 1 ? 'detail it was missing was' : 'details it was missing were'} '
            'filled in, and nothing you already had was replaced. Your previous '
            'version is kept and can be reviewed.$mismatch';
      case SharedObservationImportOutcome.replicaAlreadyCurrent:
        return 'You already have this observation, and your copy is up to date. '
            'Nothing changed.$mismatch';
      case SharedObservationImportOutcome.changeNeedsConfirmation:
        return 'Nothing changed — this payload would replace values in the copy '
            'you already hold.';
      case SharedObservationImportOutcome.refusedNotAuthor:
        return 'Not saved. Your copy of this observation was recorded by '
            'someone other than the observer this payload names, so the '
            'payload may not change it. Your copy is untouched.';
      case SharedObservationImportOutcome.refusedNotPermitted:
        // Task 11.237: somebody holding a read-only snapshot of a colleague's
        // project has no rung to name, and "your role is viewer" would be the
        // wrong-cause class. They get the one shared refusal instead.
        if (result.receiverIsNotAMember) {
          return 'Not saved. $notAMemberWriteRefusal The payload was not read '
              'and nothing was written.';
        }
        // Names the rung the device actually resolved rather than assuming
        // `viewer`, so that if the gradient ever grows another read-only role
        // this sentence stays true instead of quietly becoming wrong.
        //
        // **Written label, not the stored value** (task 11.99): `role.db` is
        // what goes in the database column, and a column value is a label
        // nobody chose. See `lib/core/text/role_labels.dart`.
        final article =
            result.receiverRole?.withArticle ?? ProjectRole.viewer.withArticle;
        return 'Not saved: $article may not add or change records here. Ask '
            'an owner to make you a contributor.';
      case SharedObservationImportOutcome.refusedInvalid:
        final first = result.issues.isEmpty ? '' : ' ${result.issues.first}';
        return 'Not saved — the payload does not describe a valid '
            'observation.$first';
      case SharedObservationImportOutcome.legacyCopyCreated:
        return 'Saved as a new observation owned by you. This payload is from an '
            'older app version, so the original observer could not be preserved '
            'and this may duplicate their record.';
    }
}

/// The `· 60 bpm` clause on the preview's tag line, in whichever unit the
/// person chose (task 11.187), or nothing when the payload carries no rate.
String _rateClause(double? bpm, PulseRateUnit unit) {
  final rate = formatPulseRate(bpm, unit);
  return rate == null ? '' : ' · $rate';
}

class _PreviewCard extends StatelessWidget {
  const _PreviewCard({
    required this.shared,
    required this.coordinateFormat,
    required this.unit,
  });

  /// How to print a pulse rate — the device preference, passed in so this stays
  /// a plain [StatelessWidget].
  final PulseRateUnit unit;
  final SharedObservation shared;
  final CoordinateFormat coordinateFormat;

  @override
  Widget build(BuildContext context) {
    final s = shared;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        border: Border.all(color: Theme.of(context).colorScheme.outline),
        borderRadius: BorderRadius.circular(DesignTokens.radiusCard),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('${s.tagName} · ${s.tagFrequencyMhz.toStringAsFixed(3)} MHz'
              '${_rateClause(s.tagPulseRate, unit)}'),
          // Task 11.187. **The mode the sender heard it on, in the sender's
          // words**, because that is the half a person can act on — and a
          // plain statement when the payload does not carry them, rather than
          // this device's own mode names, which nobody who took the bearing
          // ever saw.
          Text(
            'Pulse mode: ${s.pulseModeDescription}',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          // Task 11.199. **The legacy field, and only when it is the only
          // answer there is.** A payload that carries the sender's mode name
          // has already said the true thing on the line above; `signal_type`
          // is the two-valued projection kept for older readers, it is lossy
          // on a tag's third mode, and repeating it there would offer a second
          // description of one fact — with the wrong word available.
          //
          // Where the name is absent (a v1/v2 payload, or a sender whose own
          // device had no slot for the record) this column is genuinely all
          // the mode information the record has, so it is transcribed rather
          // than guessed at — and the sentence says which field it came from,
          // because "Mortality" and "the older signal field says Mortality"
          // are different claims.
          if (s.pulseModeName == null)
            Text(
              'The record\'s older signal field says '
              '${legacySignalTypeLabel(s.signalType)}.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          // Task 11.193. **Shown only when the sender said something**, and
          // both of their answers are worth showing: "the signal sounded
          // irregular" is often the reason the record was sent at all, and
          // "nothing wrong with the signal" is a statement the sender made
          // rather than an absence. A payload from an older build says
          // neither, and this line is then not there — which is the honest
          // rendering of a payload that could not carry it.
          if (s.signalIrregular != null)
            Text(
              s.signalIrregular!
                  // Task 11.194: Michael's word, read from
                  // `observation_quality_display.dart` so this cannot drift
                  // from the Record chip and the Position row's triangle.
                  ? 'The sender flagged this signal as $irregularSignalLabel '
                      '— they thought the tag might be faulty.'
                  : 'The sender heard nothing wrong with the signal itself.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          // Task 11.32. The payload carries what the sender's bearing was
          // recorded against when the sender's copy knew — but an older
          // bearing, or one from a build before this existed, can only send
          // the tag's present-day values. Saying which is on offer matters
          // here more than anywhere: this is the one screen where a person
          // decides which local tag a stranger's record belongs to, and
          // "150.325 MHz" meaning "then" and meaning "now" lead to different
          // answers.
          Text(
            s.tagValuesRecorded
                ? 'Tag values as recorded when the bearing was taken.'
                : 'Tag values as they read on the sender\'s device now — this '
                    'record does not say what the tag read when it was taken.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 4),
          Text('Observer: ${s.observerName}'),
          Text('Time: ${s.timestampLocal.toString().substring(0, 16)} (local)'),
          Text('Position: ${CoordinateFormatter.format(s.latitude, s.longitude, coordinateFormat)}'),
          Text('Elevation: ${s.elevation.toStringAsFixed(0)} m'),
          Text('Type: ${observationTypeLabel(s.observationType)}'),
          if (s.observationType == ObservationType.directional && s.trueNorthBearing != null)
            Text('Bearing: ${s.trueNorthBearing!.toStringAsFixed(0)}°'
                '${s.bearingUncertainty != null ? ' ± ${s.bearingUncertainty!.toStringAsFixed(0)}°' : ''}'),
          // Task 11.199: `signalType` came off this line. It was printing
          // `regular_pulse` raw, and the mode it names is the *pulse mode*
          // shown above — one fact, described twice, in a field this build no
          // longer reads when a slot is known.
          Text('Signal: ${signalStrengthLabel(s.signalStrength)}'
              '${s.bearingQuality != null ? ' · ${bearingQualityLabel(s.bearingQuality!)}' : ''}'),
          if (s.notes != null) Text('Notes: ${s.notes}'),
        ],
      ),
    );
  }
}
