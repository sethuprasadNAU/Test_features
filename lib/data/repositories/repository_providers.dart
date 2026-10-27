import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../core/providers/database_provider.dart';
import 'actual_tag_location_repository.dart';
import 'deployment_repository.dart';
import 'estimated_position_repository.dart';
import 'individual_repository.dart';
import 'non_detection_repository.dart';
import 'observation_exclusion_repository.dart';
import 'observation_repository.dart';
import 'project_membership_repository.dart';
import 'project_repository.dart';
import 'tag_library_repository.dart';
import 'tag_repository.dart';
import 'tag_version_repository.dart';
import 'triangulation_session_repository.dart';
import 'user_email_repository.dart';
import 'user_repository.dart';

part 'repository_providers.g.dart';

/// One provider per repository, each layered on [appDatabaseProvider]. They
/// resolve once the database has opened and migrated; screens/controllers
/// `await ref.watch(xRepositoryProvider.future)` (or use `.requireValue`
/// inside an already-resolved async scope). `keepAlive` matches the database
/// provider so repositories aren't rebuilt on every listen.

@Riverpod(keepAlive: true)
Future<UserRepository> userRepository(Ref ref) async {
  final db = await ref.watch(appDatabaseProvider.future);
  return UserRepository(db.raw);
}

@Riverpod(keepAlive: true)
Future<UserEmailRepository> userEmailRepository(Ref ref) async {
  final db = await ref.watch(appDatabaseProvider.future);
  return UserEmailRepository(db.raw);
}

@Riverpod(keepAlive: true)
Future<ProjectRepository> projectRepository(Ref ref) async {
  final db = await ref.watch(appDatabaseProvider.future);
  return ProjectRepository(db.raw);
}

@Riverpod(keepAlive: true)
Future<ProjectMembershipRepository> projectMembershipRepository(
  Ref ref,
) async {
  final db = await ref.watch(appDatabaseProvider.future);
  return ProjectMembershipRepository(db.raw);
}

/// **The animals a project tracks** — task 11.240. Separate from
/// [tagRepository] because a collar and the animal wearing it are different
/// rows with different lifetimes; colour lives here, and the link between
/// the two is [deploymentRepository].
@Riverpod(keepAlive: true)
Future<IndividualRepository> individualRepository(Ref ref) async {
  final db = await ref.watch(appDatabaseProvider.future);
  return IndividualRepository(db.raw);
}

/// **Which collar was on which animal, and when** — task 11.243. The third
/// row in the triple, and the one that carries the dates: see
/// `Tables.deployments`. It is also where Michael's interlock is enforced on
/// this side of the wire.
@Riverpod(keepAlive: true)
Future<DeploymentRepository> deploymentRepository(Ref ref) async {
  final db = await ref.watch(appDatabaseProvider.future);
  return DeploymentRepository(db.raw);
}

@Riverpod(keepAlive: true)
Future<TagRepository> tagRepository(Ref ref) async {
  final db = await ref.watch(appDatabaseProvider.future);
  return TagRepository(db.raw);
}

/// **This device's personal tag library** — task 11.219. Separate from
/// [tagRepository] because the two answer different questions: this one is
/// "what transmitters do I have", that one is "what tags does this project
/// hold". A library entry is device-local and reaches no server.
@Riverpod(keepAlive: true)
Future<TagLibraryRepository> tagLibraryRepository(Ref ref) async {
  final db = await ref.watch(appDatabaseProvider.future);
  return TagLibraryRepository(db.raw);
}

/// Task 11.32's `Tag_Versions` — what a tag read when a record was taken.
/// Separate from [tagRepository] because the two answer different questions
/// and must keep answering them differently: this one is "what was this
/// bearing recorded against?", that one is "what is this tag now?".
@Riverpod(keepAlive: true)
Future<TagVersionRepository> tagVersionRepository(Ref ref) async {
  final db = await ref.watch(appDatabaseProvider.future);
  return TagVersionRepository(db.raw);
}

@Riverpod(keepAlive: true)
Future<TriangulationSessionRepository> triangulationSessionRepository(
  Ref ref,
) async {
  final db = await ref.watch(appDatabaseProvider.future);
  return TriangulationSessionRepository(db.raw);
}

@Riverpod(keepAlive: true)
Future<ObservationRepository> observationRepository(Ref ref) async {
  final db = await ref.watch(appDatabaseProvider.future);
  return ObservationRepository(db.raw);
}

/// Task 11.7's supersede/exclude marks. Separate from
/// [observationRepository] on purpose: nothing that marks an observation ever
/// writes the observation.
@Riverpod(keepAlive: true)
Future<ObservationExclusionRepository> observationExclusionRepository(
  Ref ref,
) async {
  final db = await ref.watch(appDatabaseProvider.future);
  return ObservationExclusionRepository(db.raw);
}

@Riverpod(keepAlive: true)
Future<NonDetectionRepository> nonDetectionRepository(Ref ref) async {
  final db = await ref.watch(appDatabaseProvider.future);
  return NonDetectionRepository(db.raw);
}

@Riverpod(keepAlive: true)
Future<EstimatedPositionRepository> estimatedPositionRepository(
  Ref ref,
) async {
  final db = await ref.watch(appDatabaseProvider.future);
  return EstimatedPositionRepository(db.raw);
}

@Riverpod(keepAlive: true)
Future<ActualTagLocationRepository> actualTagLocationRepository(
  Ref ref,
) async {
  final db = await ref.watch(appDatabaseProvider.future);
  return ActualTagLocationRepository(db.raw);
}
