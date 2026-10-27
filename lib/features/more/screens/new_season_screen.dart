import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/errors/guarded_write.dart';
import '../../../core/providers/active_selection_provider.dart';
import '../../../core/providers/app_context_provider.dart';
import '../../../core/providers/database_provider.dart';
import '../../../core/providers/device_id_provider.dart';
import '../../../data/repositories/deployment_repository.dart';
import '../../../data/repositories/season_clone.dart';
import '../../../widgets/disabled_reason.dart';
import '../../../widgets/load_failure.dart';
import '../../../widgets/saving_filled_button.dart';

/// What a new season started from [projectId] would carry over — counted
/// before the screen says anything, so its sentences carry numbers.
///
/// `autoDispose` and a `family`, and **every `ref.watch` is before the first
/// `await`** (task 11.235's shape): the database is the one thing read, and
/// the counting is done on it.
final newSeasonPlanProvider = FutureProvider.autoDispose
    .family<SeasonClonePlan, String>((ref, projectId) async {
      final database = await ref.watch(appDatabaseProvider.future);
      return SeasonClone(database.raw).plan(projectId);
    });

/// Start next season from last season's project (task 11.56).
///
/// One screen, one button. It says what carries over with the counts, what
/// stays behind, and that the new season has nobody on it yet — because a
/// cloned project has no members until people join, so the person making it
/// is its only owner at the moment it exists, and the screen says so rather
/// than showing a team that is not there (Michael's decision, 2026-08-29).
///
/// Two choices on it. Whether the animals recorded as dead come across —
/// the engine has no opinion; **the default here is to include them**, which
/// is the smaller assumption (nothing is dropped without being asked), and
/// whether that is the right default is Michael's call — see task 11.56's
/// comms entry. And whether each animal's last known position — its most
/// recent estimate and truth point — comes across, so a crew going back out
/// can re-establish where the animals are. **Michael asked for that switch
/// and for it to default to on, 2026-09-16.**
class NewSeasonScreen extends ConsumerStatefulWidget {
  const NewSeasonScreen({super.key, required this.projectId});

  /// Last season — the project to start from.
  final String projectId;

  @override
  ConsumerState<NewSeasonScreen> createState() => _NewSeasonScreenState();
}

class _NewSeasonScreenState extends ConsumerState<NewSeasonScreen> {
  final _nameController = TextEditingController();
  bool _includeDead = true;
  bool _includePositions = true;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _nameController.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final planAsync = ref.watch(newSeasonPlanProvider(widget.projectId));
    return Scaffold(
      appBar: AppBar(title: const Text('New season')),
      body: planAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => LoadFailure('this project', error: e),
        data: (plan) => _body(context, plan),
      ),
    );
  }

  Widget _body(BuildContext context, SeasonClonePlan plan) {
    final theme = Theme.of(context);
    final source = plan.source.projectName;
    final name = _nameController.text.trim();
    final reason = name.isEmpty ? 'Give the new season a name first.' : null;
    final dead = plan.animalsRecordedDead;
    final animalsCopied = _includeDead ? plan.animals : plan.animals - dead;
    // The switch is only shown when there is something to bring, so a
    // source with no positions reads — and clones — as "nothing to bring".
    final hasPositions =
        plan.lastKnownEstimates + plan.lastKnownTruthPoints > 0;
    final bringPositions = _includePositions && hasPositions;

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text(
          'Start a new project from "$source". Its animals, tags and study '
          'area carry over. Its records stay where they are.',
          style: theme.textTheme.bodyMedium,
        ),
        const SizedBox(height: 16),
        TextField(
          key: const ValueKey('new_season_name'),
          controller: _nameController,
          textCapitalization: TextCapitalization.words,
          decoration: const InputDecoration(
            labelText: 'Name for the new season',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 20),
        _Heading('What carries over'),
        _CountLine(animalsCopied, 'animal', 'animals'),
        _CountLine(plan.collars, 'tag', 'tags'),
        _CountLine(
          plan.collarRecords,
          'record of which tag an animal wore, and when',
          'records of which tag each animal wore, and when',
        ),
        if (plan.collarRecordsWithoutBothEnds > 0)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              '${plan.collarRecordsWithoutBothEnds} more cannot come across: '
              'the tag or the animal is no longer on "$source".',
              style: theme.textTheme.bodySmall,
            ),
          ),
        if (dead > 0)
          SwitchListTile(
            key: const ValueKey('new_season_include_dead'),
            contentPadding: EdgeInsets.zero,
            value: _includeDead,
            onChanged: _saving ? null : (v) => setState(() => _includeDead = v),
            title: Text(
              dead == 1
                  ? 'Include the animal recorded as dead'
                  : 'Include the $dead animals recorded as dead',
            ),
            subtitle: const Text('It stays recorded as dead either way.'),
          ),
        if (hasPositions)
          SwitchListTile(
            key: const ValueKey('new_season_include_positions'),
            contentPadding: EdgeInsets.zero,
            value: _includePositions,
            onChanged: _saving
                ? null
                : (v) => setState(() => _includePositions = v),
            title: const Text('Bring over last known positions'),
            subtitle: Text(
              'The most recent position estimate and truth point for each '
              'animal — ${_plural(plan.lastKnownEstimates, 'estimate')} and '
              '${_plural(plan.lastKnownTruthPoints, 'truth point')}.',
            ),
          ),
        const SizedBox(height: 20),
        _Heading('What stays in "$source"'),
        Text(
          bringPositions
              ? 'Every bearing, note and no-signal record, and every position '
                    'estimate and truth point except the most recent one for '
                    'each animal.'
              : 'Every bearing, note, no-signal record, position estimate and '
                    'truth point.',
          style: theme.textTheme.bodyMedium,
        ),
        const SizedBox(height: 20),
        _Heading('Who is on it'),
        Text(
          "Only you, as owner. Nobody from \"$source\" is on the new season "
          'until they join it — publish it and share its join code.',
          style: theme.textTheme.bodyMedium,
        ),
        const SizedBox(height: 28),
        SavingFilledButton(
          key: const ValueKey('new_season_create'),
          label: 'Start the season',
          saving: _saving,
          onPressed: reason == null && !_saving
              ? () => _create(plan, bringPositions: bringPositions)
              : null,
        ),
        DisabledReasonNote(reason: _saving ? null : reason),
      ],
    );
  }

  Future<void> _create(
    SeasonClonePlan plan, {
    required bool bringPositions,
  }) async {
    setState(() => _saving = true);
    try {
      final user = await ref.read(currentUserProvider.future);
      final deviceId = await ref.read(deviceIdProvider.future);
      final database = await ref.read(appDatabaseProvider.future);
      if (!mounted) return;
      SeasonCloneResult? result;
      OverlappingDeployment? overlap;
      final ok = await runGuardedWrite(
        context,
        write: () async {
          try {
            result = await SeasonClone(database.raw).clone(
              sourceProjectId: widget.projectId,
              name: _nameController.text,
              creatorUserId: user.userId,
              includeAnimalsRecordedDead: _includeDead,
              includeLastKnownPositions: bringPositions,
              deviceId: deviceId,
            );
          } on OverlappingDeployment catch (e) {
            overlap = e;
          }
        },
        // A viewer of the source is not refused — the new season is theirs.
        // Left null so an unexpected refusal is reported as what it is.
        refused: null,
        failed: 'Could not start the season. Nothing was created — try again.',
      );
      if (!mounted) return;
      if (overlap != null) {
        // The source holds two links the interlock refuses. Since task
        // 11.263 that includes a same-day handover recorded as two bare
        // days by a build with the one-day allowance — a pair this build's
        // screens cannot write but an older one could, and which still
        // reads fine (the interlock governs writes, and a clone is one).
        // The clone rolled back; nothing was made. Say which dates to fix,
        // and where, in the sentence the interlock already owns.
        ScaffoldMessenger.of(context)
          ..clearSnackBars()
          ..showSnackBar(
            SnackBar(
              key: writeFailedKey,
              content: Text(
                'Could not start the season. In '
                '"${plan.source.projectName}": ${overlap!.message}',
              ),
              duration: const Duration(seconds: 8),
            ),
          );
        return;
      }
      final created = result;
      if (!ok || created == null) return;

      await ref
          .read(activeProjectIdProvider.notifier)
          .set(created.project.projectId);
      ref.invalidate(currentProjectProvider);
      ref.invalidate(allProjectsProvider);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Started "${created.project.projectName}" — it is the active '
            'project now.',
          ),
        ),
      );
      Navigator.of(context).maybePop();
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }
}

String _plural(int n, String noun) => '$n $noun${n == 1 ? '' : 's'}';

class _Heading extends StatelessWidget {
  const _Heading(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 6),
    child: Text(text, style: Theme.of(context).textTheme.titleSmall),
  );
}

class _CountLine extends StatelessWidget {
  const _CountLine(this.count, this.singular, this.plural);
  final int count;
  final String singular;
  final String plural;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 2),
    child: Text(
      '$count ${count == 1 ? singular : plural}',
      style: Theme.of(context).textTheme.bodyMedium,
    ),
  );
}
