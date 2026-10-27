import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:tritrack_sync/tritrack_sync.dart';
import 'package:uuid/uuid.dart';

import '../../../core/providers/app_context_provider.dart';
import '../../../core/providers/deployments_provider.dart';
import '../../../core/providers/device_id_provider.dart';
import '../../../core/providers/individuals_provider.dart';
import '../../../core/providers/tag_view_refresh.dart';
import '../../../core/text/tag_status_labels.dart';
import '../../../data/models/individual.dart';
import '../../../data/models/sync_meta.dart';
import '../../../data/repositories/mutation_authorization.dart';
import '../../../data/repositories/repository_providers.dart';
import '../../../widgets/disabled_reason.dart';
import '../../../widgets/load_failure.dart';
import '../../../widgets/tag_color_swatch.dart';
import 'quick_add_screen.dart';

/// **The animals this project is tracking** — task 11.244.
///
/// Michael, reviewing task 11.241: *"Seems like the animal's list should be
/// on that menu as well."* It was behind Project Setup, grouped under the
/// collars; the animals are the **subject** of the study and the collars are
/// equipment (design §1), so the list gets a place of its own on More.
///
/// **An animal with no collar is listed exactly like one wearing three.**
/// A chick identified before it is collared is an ordinary row here, not a
/// half-finished one — the same rule §1 states for a tag with no animal, from
/// the other side.
class AnimalsScreen extends ConsumerWidget {
  const AnimalsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final projectAsync = ref.watch(currentProjectProvider);
    return projectAsync.when(
      loading: () => Scaffold(
        appBar: AppBar(title: const Text('Animals')),
        body: const Center(child: CircularProgressIndicator()),
      ),
      error: (e, _) => Scaffold(
        appBar: AppBar(title: const Text('Animals')),
        body: LoadFailure('the current project', error: e),
      ),
      data: (project) => project == null
          ? Scaffold(
              appBar: AppBar(title: const Text('Animals')),
              body: const _NoProject(),
            )
          : _AnimalsScaffold(projectId: project.projectId),
    );
  }
}

/// **The `+` in the lower right** — task 11.248 matched the rest of the app
/// (`projects_screen.dart`, `tag_database_screen.dart`), which is why this is
/// its own widget: the button belongs to the [Scaffold], not to the list
/// underneath it, and only this layer knows [mayWrite] to gate it with.
class _AnimalsScaffold extends ConsumerWidget {
  const _AnimalsScaffold({required this.projectId});
  final String projectId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final standingAsync = ref.watch(myProjectStandingProvider(projectId));
    final mayWrite = standingAsync.value?.mayWriteProjectData ?? false;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Animals'),
        actions: [
          // **Task 11.321: many animals and their tags at once.** Gated
          // exactly as the + is; a viewer's reason is the note at the top of
          // the list, never a tooltip.
          TextButton.icon(
            key: const ValueKey('quick_add'),
            icon: const Icon(Icons.playlist_add),
            label: const Text('Quick add'),
            onPressed: mayWrite
                ? () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (context) =>
                          QuickAddScreen(projectId: projectId),
                    ),
                  )
                : null,
          ),
        ],
      ),
      body: _AnimalsBody(projectId: projectId),
      floatingActionButton: standingAsync.maybeWhen(
        data: (standing) => FloatingActionButton(
          key: const ValueKey('add_animal'),
          // Its own hero tag: every tab's "+" is built at once (task 11.323).
          heroTag: 'fab-animals',
          onPressed: standing.mayWriteProjectData
              ? () => _addAnimal(context, ref, projectId)
              : null,
          child: const Icon(Icons.add),
        ),
        orElse: () => null,
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
        'animals it is tracking are listed here.',
        textAlign: TextAlign.center,
      ),
    ),
  );
}

class _AnimalsBody extends ConsumerWidget {
  const _AnimalsBody({required this.projectId});
  final String projectId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final animalsAsync = ref.watch(projectIndividualsProvider(projectId));
    // The tags each animal has worn, for the count on its row. On the
    // same refresh list as the animals, so a link written anywhere moves
    // both together.
    final deploymentsAsync = ref.watch(projectDeploymentsProvider(projectId));
    final standingAsync = ref.watch(myProjectStandingProvider(projectId));

    return animalsAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => LoadFailure('the animals on this project', error: e),
      data: (animals) => deploymentsAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) =>
            LoadFailure('which tags are on which animals', error: e),
        data: (deployments) => standingAsync.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) =>
              LoadFailure('what you are allowed to change here', error: e),
          data: (standing) {
            final counts = <String, int>{};
            for (final d in deployments) {
              counts[d.individualId] = (counts[d.individualId] ?? 0) + 1;
            }
            // **The `+` moved to the Scaffold's FloatingActionButton** (task
            // 11.248, matching `projects_screen.dart` and
            // `tag_database_screen.dart`), so a refusal has nowhere on the
            // button to say why — it goes here instead, at the top of the
            // list, exactly the sentence `DisabledReasonNote` would have put
            // under the old button. Never a tooltip (`disabled_reason.dart`).
            final refusal = standing.writeRefusal(
              asViewer:
                  'Viewers cannot add an animal — ask an owner to change '
                  'your role.',
            );
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (refusal != null)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                    child: DisabledReasonNote(reason: refusal),
                  ),
                Expanded(
                  child: animals.isEmpty
                      ? const _NoAnimalsYet()
                      : ListView.separated(
                          itemCount: animals.length,
                          separatorBuilder: (_, _) =>
                              const Divider(height: 1),
                          itemBuilder: (context, i) => _AnimalRow(
                            animal: animals[i],
                            collarCount: counts[animals[i].individualId] ?? 0,
                          ),
                        ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// Adds a new, unknown-status animal to [projectId] — the `+`'s action,
/// shared by [_AnimalsScaffold]'s FAB.
Future<void> _addAnimal(
  BuildContext context,
  WidgetRef ref,
  String projectId,
) async {
  final controller = TextEditingController();
  final name = await showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('New animal'),
      content: TextField(
        key: const ValueKey('new_animal_name'),
        controller: controller,
        autofocus: true,
        decoration: const InputDecoration(labelText: 'Name'),
        onSubmitted: (v) => Navigator.of(context).pop(v.trim()),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const ValueKey('new_animal_add'),
          onPressed: () => Navigator.of(context).pop(controller.text.trim()),
          child: const Text('Add'),
        ),
      ],
    ),
  );
  if (name == null || name.isEmpty || !context.mounted) return;

  final user = await ref.read(currentUserProvider.future);
  final deviceId = await ref.read(deviceIdProvider.future);
  final repo = await ref.read(individualRepositoryProvider.future);
  final id = const Uuid().v4();
  try {
    await repo.insert(
      Individual(
        individualId: id,
        projectId: projectId,
        name: name,
        // The round-robin over this project's animals, so two entered in a
        // row are distinguishable on the map's legend.
        colorHex: await repo.nextColorHex(projectId: projectId),
        // **`unknown`, not `alive`.** Nothing has been observed about this
        // animal yet, and `unknown` is the honest default (design §5) —
        // the one place a tag's status ever seeds an animal's is
        // `Individual.statusSeededFrom`, and there is no tag here.
        status: IndividualStatus.unknown,
        lineageId: id,
        sync: SyncMeta.initial(
          now: DateTime.now(),
          modifiedBy: user.userId,
          originDeviceId: deviceId,
        ),
      ),
    );
  } on UnauthorizedMutation catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            e.refusalSentence(
              asViewer:
                  'Viewers cannot add an animal — ask an owner to change '
                  'your role.',
            ),
          ),
        ),
      );
    }
    return;
  }
  refreshTagViews(ref, projectId: projectId);
}

class _NoAnimalsYet extends StatelessWidget {
  const _NoAnimalsYet();

  @override
  Widget build(BuildContext context) => const Padding(
    padding: EdgeInsets.all(24),
    child: Center(
      child: Text(
        'No animals on this project yet. Add the animals you are studying, '
        'then link a tag to each one.',
        textAlign: TextAlign.center,
      ),
    ),
  );
}

class _AnimalRow extends StatelessWidget {
  const _AnimalRow({required this.animal, required this.collarCount});

  final Individual animal;
  final int collarCount;

  @override
  Widget build(BuildContext context) {
    final tags = collarCount == 1 ? '1 tag' : '$collarCount tags';
    return ListTile(
      key: ValueKey('animals_row_${animal.individualId}'),
      leading: TagColorSwatch(colorHex: animal.colorHex, size: 18),
      title: Text(animal.name),
      subtitle: Text('${individualStatusLabel(animal.status)} · $tags'),
      trailing: const Icon(Icons.chevron_right),
      onTap: () => context.push('/more/animals/${animal.individualId}'),
    );
  }
}
