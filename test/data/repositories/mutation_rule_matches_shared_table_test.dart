import 'package:flutter_test/flutter_test.dart';
import 'package:tritrack/data/db/app_database.dart';
import 'package:tritrack/data/repositories/actual_tag_location_repository.dart';
import 'package:tritrack/data/repositories/base_repository.dart';
import 'package:tritrack/data/repositories/estimated_position_repository.dart';
import 'package:tritrack/data/repositories/deployment_repository.dart';
import 'package:tritrack/data/repositories/individual_repository.dart';
import 'package:tritrack/data/repositories/non_detection_repository.dart';
import 'package:tritrack/data/repositories/observation_exclusion_repository.dart';
import 'package:tritrack/data/repositories/observation_repository.dart';
import 'package:tritrack/data/repositories/project_membership_repository.dart';
import 'package:tritrack/data/repositories/project_repository.dart';
import 'package:tritrack/data/repositories/tag_repository.dart';
import 'package:tritrack/data/repositories/tag_version_repository.dart';
import 'package:tritrack/data/repositories/triangulation_session_repository.dart';
import 'package:tritrack/data/repositories/user_email_repository.dart';
import 'package:tritrack/data/repositories/user_repository.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

/// Task 11.96. `tableMutationRules` (`package:tritrack_sync`) is supposed to
/// be the single authority for which [MutationRule] governs each table, but
/// every `BaseRepository` subclass passes its own [BaseRepository.rule] as a
/// constructor literal — a second, hand-maintained copy of the same fact.
/// Task 11.93 flipped `Actual_Tag_Locations`'s entry in the shared table and
/// **no client behaviour changed and no test went red**, because nothing
/// compared a repository's literal against it. This file is that comparison,
/// for every repository the app constructs.
void main() {
  late AppDatabase database;

  setUp(() async {
    database = await AppDatabase.openInMemory();
  });

  tearDown(() => database.close());

  /// Every repository the app builds, keyed by class name so a fourteenth
  /// left out of this map is a red length check (below), not a silent gap.
  /// Built lazily (against `database.raw` at test-run time, not collection
  /// time) so the map can also drive `test()` registration, which happens
  /// before `setUp` runs.
  final factories = <String, BaseRepository Function()>{
    'ActualTagLocationRepository': () =>
        ActualTagLocationRepository(database.raw),
    'EstimatedPositionRepository': () =>
        EstimatedPositionRepository(database.raw),
    'NonDetectionRepository': () => NonDetectionRepository(database.raw),
    'ObservationExclusionRepository': () =>
        ObservationExclusionRepository(database.raw),
    'ObservationRepository': () => ObservationRepository(database.raw),
    'ProjectMembershipRepository': () =>
        ProjectMembershipRepository(database.raw),
    'ProjectRepository': () => ProjectRepository(database.raw),
    'IndividualRepository': () => IndividualRepository(database.raw),
    'DeploymentRepository': () => DeploymentRepository(database.raw),
    'TagRepository': () => TagRepository(database.raw),
    'TagVersionRepository': () => TagVersionRepository(database.raw),
    'TriangulationSessionRepository': () =>
        TriangulationSessionRepository(database.raw),
    'UserEmailRepository': () => UserEmailRepository(database.raw),
    'UserRepository': () => UserRepository(database.raw),
  };

  test('one repository per synced table — a table with none, or a '
      'repository for a table that no longer exists, is not a silent gap',
      () {
    expect(
      factories.values.map((build) => build().table).toSet(),
      Tables.all.toSet(),
    );
  });

  for (final entry in factories.entries) {
    test(
      '${entry.key}.rule matches tableMutationRules[${entry.key}\'s table]',
      () {
        final repo = entry.value();
        expect(
          repo.rule,
          tableMutationRules[repo.table],
          reason:
              '${entry.key} passes MutationRule.${repo.rule.name} at '
              'construction — a second copy of '
              'tableMutationRules[\'${repo.table}\'] '
              '(${tableMutationRules[repo.table]}). The two disagreeing is '
              'exactly what task 11.93 found no test caught.',
        );
      },
    );
  }
}
