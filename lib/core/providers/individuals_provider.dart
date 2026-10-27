import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models/individual.dart';
import '../../data/repositories/repository_providers.dart';

/// The animals one project holds, live ones only, by name — task 11.241.
///
/// The list Project Setup groups a project's collars under, and the list the
/// Log and Map filters offer beside the collars. **Refreshed by
/// `refreshTagViews`**, on the same list as the project's tags: creating,
/// merging or re-pointing anything changes both, and a screen that saw the
/// collars move but not the animal they moved to would be showing a grouping
/// that is no longer true.
///
/// `autoDispose`, like every family on that list, for the reason
/// `refresh_lists_test.dart` gives: a keepAlive family invalidated mid-build
/// hangs a screen for good, an autoDispose one throws loudly and rebuilds.
final projectIndividualsProvider =
    FutureProvider.autoDispose.family<List<Individual>, String>(
  (ref, projectId) async {
    final repo = await ref.watch(individualRepositoryProvider.future);
    return repo.findByProject(projectId);
  },
  name: 'projectIndividualsProvider',
);
