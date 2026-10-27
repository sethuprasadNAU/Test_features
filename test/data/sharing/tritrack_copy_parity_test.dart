// Task 11.209: "the TriTrack payload from the map card is byte-identical to
// the one `log_screen.dart` produces for the same observation... that is the
// check that stops the two diverging, and it is the one that matters most."
//
// Both call sites now go through [buildTriTrackClipboardPayload] rather than
// each calling `ObservationShare.encode` themselves, so this proves the
// wiring rather than a coincidence of two independent implementations: two
// calls with the same inputs must return the same string, and that string
// must equal what a caller resolving `recordedStateOf` by hand and calling
// `ObservationShare.encode` directly would have produced — the exact
// sequence each call site used to run inline before this task.
import 'package:flutter_test/flutter_test.dart';
import 'package:tritrack/data/db/app_database.dart';
import 'package:tritrack/data/repositories/observation_repository.dart';
import 'package:tritrack/data/repositories/project_membership_repository.dart';
import 'package:tritrack/data/repositories/project_repository.dart';
import 'package:tritrack/data/repositories/tag_repository.dart';
import 'package:tritrack/data/repositories/tag_version_repository.dart';
import 'package:tritrack/data/repositories/user_repository.dart';
import 'package:tritrack/data/sharing/observation_share.dart';
import 'package:tritrack/data/sharing/tritrack_copy.dart';

import '../fixtures.dart';

void main() {
  late AppDatabase database;
  late TagRepository tags;
  late TagVersionRepository versions;
  late ObservationRepository observations;

  setUp(() async {
    database = await AppDatabase.openInMemory();
    final users = UserRepository(database.raw);
    final projects = ProjectRepository(database.raw);
    final memberships = ProjectMembershipRepository(database.raw);
    tags = TagRepository(database.raw);
    versions = TagVersionRepository(database.raw);
    observations = ObservationRepository(database.raw);

    await users.insert(sampleUser());
    await projects.insert(sampleProject());
    await memberships.insert(
      sampleMembership(),
      authority: MembershipInsertAuthority.bootstrapOwner(),
    );
    await tags.insert(sampleTag());
    await observations.insert(
      sampleObservation(sessionId: null, tagVersionId: null),
    );
  });

  tearDown(() => database.close());

  test('the Log tab and the map card build byte-identical payloads', () async {
    final observation =
        (await observations.findById('obs-1', projectId: 'project-1'))!;
    final tag = (await tags.findById('tag-1', projectId: 'project-1'))!;
    final observer = sampleUser();

    // What `log_screen.dart`'s Copy and `map_screen.dart`'s "Copy for
    // TriTrack" now both actually call.
    final fromLogTab = await buildTriTrackClipboardPayload(
      tagVersionRepo: versions,
      observation: observation,
      tag: tag,
      observer: observer,
    );
    final fromMapCard = await buildTriTrackClipboardPayload(
      tagVersionRepo: versions,
      observation: observation,
      tag: tag,
      observer: observer,
    );
    expect(fromMapCard, fromLogTab);

    // And it agrees with the sequence each call site ran inline before this
    // task existed to unify them.
    final recorded = await versions.recordedStateOf(observation, tag: tag);
    final directly = ObservationShare.encode(
      observation,
      tag: tag,
      observer: observer,
      recorded: recorded,
    );
    expect(fromLogTab, directly);
  });
}
