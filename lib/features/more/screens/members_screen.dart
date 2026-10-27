import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/providers/app_context_provider.dart';
import '../../../widgets/load_failure.dart';
import 'project_members_screen.dart';

/// **Members, on the More screen for the open project** — task 11.313.
///
/// An owner manages members more often than animals, yet `AnimalsScreen` sat
/// on the More menu while this screen was two taps behind it: Projects, then
/// the project's own row, then its ⋮ menu. This puts it beside Animals,
/// the same way — a thin wrapper that resolves the open project and hands it
/// to [ProjectMembersScreen], which does everything else exactly as it did.
///
/// **Widens nothing.** Every gate on who may see the join code, change a
/// role, or remove somebody still lives in [ProjectMembersScreen] and the
/// server routes behind it; this file adds a second door to the same room,
/// not a new room. The existing route,
/// `/more/projects/:projectId/members`, is untouched — this is
/// `/more/members`, reached from the More menu instead of a project's row.
class MembersScreen extends ConsumerWidget {
  const MembersScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final projectAsync = ref.watch(currentProjectProvider);
    return projectAsync.when(
      loading: () => Scaffold(
        appBar: AppBar(title: const Text('Members')),
        body: const Center(child: CircularProgressIndicator()),
      ),
      error: (e, _) => Scaffold(
        appBar: AppBar(title: const Text('Members')),
        body: LoadFailure('the current project', error: e),
      ),
      data: (project) => project == null
          ? Scaffold(
              appBar: AppBar(title: const Text('Members')),
              body: const _NoProject(),
            )
          : ProjectMembersScreen(projectId: project.projectId),
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
        'No project is active. Choose one under More → Projects, and who is '
        'on it is listed here.',
        textAlign: TextAlign.center,
      ),
    ),
  );
}
