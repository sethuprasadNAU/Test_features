import 'package:flutter_test/flutter_test.dart';
import 'package:tritrack/data/db/app_database.dart';
import 'package:tritrack/data/models/sync_meta.dart';
import 'package:tritrack/data/models/tag.dart';
import 'package:tritrack/data/repositories/deployment_repository.dart';
import 'package:tritrack/data/repositories/individual_repository.dart';
import 'package:tritrack/data/repositories/mutation_authorization.dart';
import 'package:tritrack/data/repositories/observation_repository.dart';
import 'package:tritrack/data/repositories/project_membership_repository.dart';
import 'package:tritrack/data/repositories/project_repository.dart';
import 'package:tritrack/data/repositories/tag_repository.dart';
import 'package:tritrack/data/repositories/tag_version_repository.dart';
import 'package:tritrack/data/repositories/user_repository.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

import '../fixtures.dart';
import '../../support/tag_version_history.dart';

/// **Task 11.32** — what a bearing remembers about its tag.
///
/// The harm, stated once: a bearing recorded which tag it was taken against and
/// nothing more, so the moment anybody edited that tag — which they must be
/// able to do, because VHF transmitters drift and names get corrected — every
/// bearing ever recorded against it retroactively claimed to have been taken at
/// the new values. Nobody did anything wrong and the dataset said something
/// false.
void main() {
  late AppDatabase database;
  late TagRepository tags;
  late TagVersionRepository versions;
  late ObservationRepository observations;

  const owner = MutationActor.user('user-1');
  final at = DateTime.utc(2026, 8, 22, 9, 0, 0);
  final later = DateTime.utc(2026, 10, 4, 9, 0, 0);

  SyncMeta metaFor(MutationActor actor, {DateTime? now}) => SyncMeta.initial(
    now: now ?? at,
    modifiedBy: actor.userId,
    originDeviceId: 'device-A',
  );

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
    await tags.insert(sampleTag().copyWith(sync: metaFor(owner)));
  });

  tearDown(() => database.close());

  /// The bearing under test, pointed at whatever version the tag reads now —
  /// exactly what the record screen does.
  Future<void> recordBearing({String id = 'obs-1'}) async {
    await observations.insert(
      sampleObservation(
        id: id,
        // No triangulation session in this fixture — the composite FK would
        // refuse one that does not exist.
        sessionId: null,
        tagVersionId: await versions.currentVersionIdFor('tag-1'),
      ).copyWith(sync: metaFor(owner)),
    );
  }

  /// What that bearing says it was recorded against, right now.
  Future<({double? frequency, String? name, bool recorded})> asRecorded([
    String id = 'obs-1',
  ]) async {
    final observation = (await observations.findById(id, projectId: 'project-1'))!;
    final state = await versions.recordedStateOf(
      observation,
      tag: await tags.findById('tag-1', projectId: 'project-1'),
    );
    return (
      frequency: state!.recordedFrequencyMhz,
      name: state.recordedTagName,
      recorded: state.isRecorded,
    );
  }

  Future<Tag> storedTag() async => (await tags.findById('tag-1', projectId: 'project-1'))!;

  group('creating a tag gives it a version, at every door', () {
    test('the tag a project starts with has one', () async {
      final history = await tagVersionHistory(versions, 'tag-1');
      expect(history, hasLength(1));
      expect(history.single.frequencyMhz, 150.325);
      expect(history.single.tagName, 'Coco');
    });

    test('a bearing recorded against it points at that version', () async {
      await recordBearing();
      final state = await asRecorded();
      expect(state.recorded, isTrue);
      expect(state.frequency, 150.325);
      expect(state.name, 'Coco');
    });
  });

  group('a change — the transmitter drifted', () {
    test('an earlier bearing keeps the frequency it was taken at', () async {
      await recordBearing();

      await tags.update(
        (await storedTag()).copyWith(frequencyMhz: 150.51),
        actor: owner,
        intent: TagEditIntent.change,
        now: later,
      );

      final state = await asRecorded();
      expect(
        state.frequency,
        150.325,
        reason: 'the receiver was tuned to 150.325 when this bearing was '
            'taken, and editing the tag afterwards cannot change that',
      );
      // …while the tag itself has moved on. The two reads stay different, and
      // the difference *is* the drift record.
      expect((await storedTag()).frequencyMhz, 150.51);
    });

    test('a rename leaves an earlier bearing matchable against the field '
        'notebook', () async {
      // Michael's case, and the sharpest one: two tags may legitimately share
      // a name, so a rename leaves no fallback identity at all.
      await recordBearing();
      await tags.update(
        (await storedTag()).copyWith(tagName: 'F21'),
        actor: owner,
        intent: TagEditIntent.change,
        now: later,
      );
      expect((await asRecorded()).name, 'Coco');
      expect((await storedTag()).tagName, 'F21');
    });

    test('a bearing recorded after the change reads the new value', () async {
      await recordBearing();
      await tags.update(
        (await storedTag()).copyWith(frequencyMhz: 150.51),
        actor: owner,
        intent: TagEditIntent.change,
        now: later,
      );
      await recordBearing(id: 'obs-2');

      expect((await asRecorded('obs-1')).frequency, 150.325);
      expect((await asRecorded('obs-2')).frequency, 150.51);
      // A tag reading one frequency for six weeks and another afterwards is a
      // drift record, which is what a biologist actually wants.
      expect(await tagVersionHistory(versions, 'tag-1'), hasLength(2));
    });
  });

  group('a correction — it was typed in wrong', () {
    test('an earlier bearing shows the corrected value', () async {
      await recordBearing();

      await tags.update(
        (await storedTag()).copyWith(frequencyMhz: 150.326),
        actor: owner,
        intent: TagEditIntent.correction,
        now: later,
      );

      expect(
        (await asRecorded()).frequency,
        150.326,
        reason: 'the bearing was always at 150.326; the record was simply '
            'wrong',
      );
      expect(
        await tagVersionHistory(versions, 'tag-1'),
        hasLength(1),
        reason: 'a correction rewrites the version rather than appending one',
      );
    });

    test('it does not reach back past a genuine earlier change', () async {
      // The case that makes "update every record" mean something precise. A
      // correction to today's frequency says nothing about a drift six weeks
      // ago, and flattening the two would destroy the very history this table
      // exists to keep.
      await recordBearing(); // taken at 150.325
      await tags.update(
        (await storedTag()).copyWith(frequencyMhz: 150.51),
        actor: owner,
        intent: TagEditIntent.change,
        now: later,
      );
      await recordBearing(id: 'obs-2'); // taken at 150.51

      await tags.update(
        (await storedTag()).copyWith(frequencyMhz: 150.515),
        actor: owner,
        intent: TagEditIntent.correction,
        now: later.add(const Duration(days: 1)),
      );

      expect((await asRecorded('obs-1')).frequency, 150.325);
      expect((await asRecorded('obs-2')).frequency, 150.515);
      expect(await tagVersionHistory(versions, 'tag-1'), hasLength(2));
    });
  });

  group('colour is a display key, not a measurement', () {
    test('recolouring changes every record already drawn, immediately',
        () async {
      await recordBearing();
      // **The colour has to have an animal to land on** (task 11.243). It
      // is the animal's, read through the collar's deployment; a collar on
      // nobody has no colour to move and the edit is a no-op. That is
      // asserted in `individuals_test.dart`; this test is about the *record*
      // reading the new colour, so it gives the collar an animal first.
      await IndividualRepository(
        database.raw,
      ).insert(sampleIndividual(id: 'marie'));
      await DeploymentRepository(database.raw).link(
        sampleDeployment(tagId: 'tag-1', individualId: 'marie'),
      );
      await tags.update(
        (await storedTag()).copyWith(colorHex: '#123456'),
        actor: owner,
        // Nothing versioned moved, so nothing was asked.
        intent: null,
        now: later,
      );

      final observation = (await observations.findById('obs-1', projectId: 'project-1'))!;
      final state = await versions.recordedStateOf(
        observation,
        tag: await storedTag(),
      );
      expect(
        state!.tag.colorHex,
        '#123456',
        reason: 'a recolour is meant to apply everywhere and at once, '
            'including to records already on the map',
      );
      // …and the measurement context is untouched.
      expect(state.recordedFrequencyMhz, 150.325);
    });

    test('a colour-only edit asks the person nothing', () async {
      final before = await storedTag();
      expect(
        TagVersionRepository.versionedFieldsChanged(
          before,
          before.copyWith(colorHex: '#123456'),
        ),
        isFalse,
        reason: 'keeping the common case frictionless is part of the '
            'requirement, not a nicety',
      );
    });

    test("so does an edit to the collar's own life", () async {
      final before = await storedTag();
      for (final edited in [
        // Two, not four: `date_removed` and `capture_date` left `Tags` at
        // schema v17 (task 11.243) — they were one deployment's facts, not
        // the collar's, and `Deployments` has no version history because
        // nothing is ever recorded *against* a deployment.
        before.copyWith(status: TagStatus.recovered),
        before.copyWith(notes: 'recovered from a den'),
      ]) {
        expect(
          TagVersionRepository.versionedFieldsChanged(before, edited),
          isFalse,
        );
      }
    });

    test('but a measurement-context edit does ask', () async {
      final before = await storedTag();
      for (final edited in [
        before.copyWith(frequencyMhz: 150.51),
        before.copyWith(tagName: 'F21'),
        before.copyWith(pulseRate: 55),
        before.copyWith(pulsePattern: 'double'),
      ]) {
        expect(
          TagVersionRepository.versionedFieldsChanged(before, edited),
          isTrue,
        );
      }
    });

    test('an edit that moves a versioned field with no stated intent throws '
        'rather than guessing', () async {
      // No default on the prompt: drift and typo are both common, so either
      // default is silently wrong a good share of the time — and silence is
      // the whole harm being fixed. A call site that forgot to ask fails
      // loudly in the first test that touches it.
      await expectLater(
        tags.update(
          (await storedTag()).copyWith(frequencyMhz: 150.51),
          actor: owner,
          intent: null,
          now: later,
        ),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('correction or a change'),
          ),
        ),
      );
    });
  });

  group('nulls mean "not recorded", never "whatever the tag says now"', () {
    test('a bearing with no version stays unresolved after a tag edit',
        () async {
      // The shape of every row that predates schema v9, and of every pasted or
      // imported record.
      await observations.insert(
        sampleObservation(id: 'obs-old', sessionId: null, tagVersionId: null)
            .copyWith(sync: metaFor(owner)),
      );
      await tags.update(
        (await storedTag()).copyWith(frequencyMhz: 150.51),
        actor: owner,
        intent: TagEditIntent.correction,
        now: later,
      );

      final state = await asRecorded('obs-old');
      expect(state.recorded, isFalse);
      expect(state.frequency, isNull);
      expect(state.name, isNull);
    });

    test('a version reference this device cannot resolve is inert, not an '
        'error', () async {
      // Sync legitimately delivers a bearing before the version it names, and
      // an imported record may name one this device will never hold.
      await observations.insert(
        sampleObservation(
          id: 'obs-dangling',
          sessionId: null,
          tagVersionId: 'never-arrived',
        )
            .copyWith(sync: metaFor(owner)),
      );
      final state = await asRecorded('obs-dangling');
      expect(state.recorded, isFalse);
      expect(state.frequency, isNull);
    });

    test('a tag with no version gives a new bearing a null reference rather '
        'than inventing one', () async {
      // A tag that arrived by sync from a build older than schema v9. Nothing
      // mints a version to fill the gap, because a version invented now would
      // be a claim about a past nobody observed.
      await database.raw.delete(
        Tables.tagVersions,
        where: 'tag_id = ?',
        whereArgs: ['tag-1'],
      );
      expect(await versions.currentVersionIdFor('tag-1'), isNull);
    });
  });

  group('the two reads stay different', () {
    test('drift is reported, not reconciled', () async {
      await recordBearing();
      await tags.update(
        (await storedTag()).copyWith(frequencyMhz: 150.51, tagName: 'F21'),
        actor: owner,
        intent: TagEditIntent.change,
        now: later,
      );
      final observation = (await observations.findById('obs-1', projectId: 'project-1'))!;
      final state = await versions.recordedStateOf(
        observation,
        tag: await storedTag(),
      );
      expect(state!.differsFromCurrent, isTrue);
      expect(state.recordedFrequencyMhz, 150.325);
      expect(state.tag.frequencyMhz, 150.51);
    });

    test('an unknown past is not reported as a known disagreement', () async {
      await observations.insert(
        sampleObservation(id: 'obs-old', sessionId: null, tagVersionId: null)
            .copyWith(sync: metaFor(owner)),
      );
      final observation =
          (await observations.findById('obs-old', projectId: 'project-1'))!;
      final state = await versions.recordedStateOf(
        observation,
        tag: await storedTag(),
      );
      expect(state!.differsFromCurrent, isFalse);
      expect(state.isRecorded, isFalse);
    });
  });

  group('batch resolution matches the one-at-a-time answer', () {
    test('recordedStatesFor agrees with recordedStateOf', () async {
      await recordBearing();
      await observations.insert(
        sampleObservation(id: 'obs-null', sessionId: null, tagVersionId: null)
            .copyWith(sync: metaFor(owner)),
      );
      await tags.update(
        (await storedTag()).copyWith(tagName: 'F21'),
        actor: owner,
        intent: TagEditIntent.change,
        now: later,
      );

      final all = await observations.findByProject('project-1');
      final tag = await storedTag();
      final batch = await versions.recordedStatesFor(
        all,
        tagsById: {'tag-1': tag},
      );
      for (final observation in all) {
        final single = await versions.recordedStateOf(observation, tag: tag);
        expect(
          batch[observation.observationId]?.recordedTagName,
          single?.recordedTagName,
          reason: observation.observationId,
        );
      }
      expect(batch['obs-1']!.recordedTagName, 'Coco');
      expect(batch['obs-null']!.isRecorded, isFalse);
    });
  });
}
