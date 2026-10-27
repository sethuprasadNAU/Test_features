import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:tritrack/data/db/app_database.dart';
import 'package:tritrack_sync/tritrack_sync.dart';
import 'package:tritrack/data/models/observation.dart';
import 'package:tritrack/data/models/user.dart';
import 'package:tritrack/data/sharing/observation_share.dart';
import 'package:tritrack/data/sharing/shared_observation_importer.dart';

import '../fixtures.dart';

/// The receiving device: a different user and device from the sender in every
/// test, since that is the only configuration where the duplication bug this
/// code exists to fix can occur.
const _receivingUserId = 'user-bob';
const _receivingDeviceId = 'device-B';

void main() {
  late AppDatabase database;
  late Database db;
  late SharedObservationImporter importer;

  final now = DateTime.utc(2026, 7, 31, 12, 0, 0);

  setUp(() async {
    database = await AppDatabase.openInMemory();
    db = database.raw;
    importer = SharedObservationImporter(db);
    // The receiving device's own graph: itself as a user, a project, and a
    // local tag that the payload's "tag key" resolves to.
    await db.insert(Tables.users,
        sampleUser(id: _receivingUserId, email: 'bob@example.com').toColumns());
    await db.insert(Tables.projects,
        sampleProject(id: 'project-local', ownerUserId: _receivingUserId).toColumns());
    await db.insert(
      Tables.tags,
      sampleTag(id: 'tag-local', projectId: 'project-local').toColumns(),
    );
  });
  tearDown(() async => database.close());

  /// A payload from Alice on device-A, encoded exactly as the sender would.
  String alicePayload({
    String observationId = 'obs-alice',
    String observerId = 'user-alice',
    String email = 'alice@example.com',
    int revision = 3,
    DateTime? updatedAt,
    PositionSource positionSource = PositionSource.manualPin,
    double? accuracy = 8.5,
    String? notes = 'clear signal',
    bool? signalIrregular,
  }) {
    final observation = sampleObservation(
      id: observationId,
      userId: observerId,
      sessionId: 'session-alice',
    ).copyWith(
      positionSource: positionSource,
      positionAccuracyM: accuracy,
      notes: notes,
      signalIrregular: signalIrregular,
      sync: sampleSync().copyWith(
        revision: revision,
        updatedAt: updatedAt ?? DateTime.utc(2026, 7, 20, 9, 0, 0),
        lastModifiedBy: observerId,
        originDeviceId: 'device-A',
      ),
    );
    return ObservationShare.encode(
      observation,
      tag: sampleTag(id: 'tag-alice'),
      observer: sampleUser(id: observerId, email: email),
    );
  }

  Future<SharedObservationImportResult> save(
    String payload, {
    bool confirmChanges = false,
  }) =>
      importer.save(
        ObservationShare.decode(payload, now: now),
        projectId: 'project-local',
        tagId: 'tag-local',
        receivingUserId: _receivingUserId,
        receivingDeviceId: _receivingDeviceId,
        newId: () => 'minted-id',
        confirmChanges: confirmChanges,
        now: now,
      );

  Future<List<Observation>> allObservations() async {
    final rows = await db.query(Tables.observations);
    return rows.map(Observation.fromRow).toList();
  }

  Future<Observation> onlyObservation() async {
    final all = await allObservations();
    expect(all, hasLength(1));
    return all.single;
  }

  group('v2 payload saves as a faithful replica', () {
    test('reuses the sender primary key instead of minting a new one', () async {
      final result = await save(alicePayload());
      expect(result.outcome, SharedObservationImportOutcome.replicaInserted);
      expect(result.isReplica, isTrue);
      expect((await onlyObservation()).observationId, 'obs-alice');
    });

    test('attributes the observation to the original observer, not the receiver', () async {
      await save(alicePayload());
      final saved = await onlyObservation();
      expect(saved.userId, 'user-alice');
      expect(saved.userId, isNot(_receivingUserId));
    });

    test('copies the sender sync clock verbatim rather than starting a fresh one', () async {
      await save(alicePayload(revision: 3));
      final saved = await onlyObservation();
      // A fresh clock (revision 0, updated_at = now) would let this copy look
      // newer than Alice's original and overwrite her later edits on merge.
      expect(saved.sync.revision, 3);
      expect(saved.sync.updatedAt, DateTime.utc(2026, 7, 20, 9, 0, 0));
      expect(saved.sync.createdAt, sampleSync().createdAt);
      expect(saved.sync.originDeviceId, 'device-A');
      expect(saved.sync.lastModifiedBy, 'user-alice');
    });

    test('preserves position_source and position_accuracy_m', () async {
      await save(alicePayload(positionSource: PositionSource.manualPin, accuracy: 8.5));
      final saved = await onlyObservation();
      expect(saved.positionSource, PositionSource.manualPin);
      expect(saved.positionAccuracyM, 8.5);
    });

    test('keeps the sender notes intact, with no "Shared by" prefix', () async {
      await save(alicePayload(notes: 'clear signal'));
      expect((await onlyObservation()).notes, 'clear signal');
    });

    test('null notes stay null rather than becoming a provenance string', () async {
      await save(alicePayload(notes: null));
      expect((await onlyObservation()).notes, isNull);
    });

    test('binds to the local project and tag, not the sender ids', () async {
      await save(alicePayload());
      final saved = await onlyObservation();
      expect(saved.projectId, 'project-local');
      expect(saved.tagId, 'tag-local');
    });

    test('drops the sender session_id, which names a row this device never had', () async {
      await save(alicePayload());
      expect((await onlyObservation()).sessionId, isNull);
    });

    /// **Task 11.193.** The sender heard the tag sounding wrong; that is very
    /// often why the record is being shared at all. It is written, unlike
    /// `tag_version_id` and `pulse_mode` — those name rows and slots in the
    /// *sender's* database and cannot survive being relabelled onto the
    /// receiver's tag, while this is what a person heard at a time and a
    /// place and means the same thing here.
    test('carries the flag saying the signal itself sounded wrong', () async {
      await save(alicePayload(signalIrregular: true));
      expect((await onlyObservation()).signalIrregular, isTrue);
    });

    test("carries the sender's 'nothing wrong with it' as well, and their "
        'silence as silence', () async {
      await save(alicePayload(signalIrregular: false));
      expect(
        (await onlyObservation()).signalIrregular,
        isFalse,
        reason: 'The sender listened and did not tick it. That is an answer, '
            'and it is the common one.',
      );

      await db.delete(Tables.observations);
      await save(alicePayload(signalIrregular: null));
      expect(
        (await onlyObservation()).signalIrregular,
        isNull,
        reason: 'And a payload that carried no answer must not acquire one on '
            'the way in.',
      );
    });
  });

  group('observer resolution by normalized email', () {
    test('creates a local Users row with the payload user_id when unknown', () async {
      await save(alicePayload(observerId: 'user-alice', email: 'alice@example.com'));
      final rows = await db.query(Tables.users, where: 'user_id = ?', whereArgs: ['user-alice']);
      final created = User.fromRow(rows.single);
      expect(created.email, 'alice@example.com');
      expect(created.firstName, 'Sam');
      expect(created.lastName, 'Ranger');
    });

    test('two differently-cased emails resolve to one local user row', () async {
      await save(alicePayload(observationId: 'obs-1', email: 'Alice@Example.com'));
      await save(alicePayload(observationId: 'obs-2', email: 'alice@EXAMPLE.COM'));
      final rows = await db.query(Tables.users, where: 'email = ?', whereArgs: ['alice@example.com']);
      expect(rows, hasLength(1));
      final saved = await allObservations();
      expect(saved.map((o) => o.userId).toSet(), {'user-alice'});
    });

    test('an existing local user with the same email but a different id wins', () async {
      await db.insert(Tables.users,
          sampleUser(id: 'user-alice-local', email: 'alice@example.com').toColumns());

      final result = await save(alicePayload(observerId: 'user-alice-remote'));

      // The local row is preferred: rewriting its id would break every FK
      // already pointing at it, and a second row would defeat email dedup.
      expect(result.observerUserId, 'user-alice-local');
      expect(result.observerIdMismatch, 'user-alice-remote');
      expect((await onlyObservation()).userId, 'user-alice-local');
      final aliceRows =
          await db.query(Tables.users, where: 'email = ?', whereArgs: ['alice@example.com']);
      expect(aliceRows, hasLength(1), reason: 'must not create a duplicate user');
    });

    test('a payload current email matching a local prior email resolves via that local user',
        () async {
      // The local device recorded that Alice used to have this address.
      await db.insert(Tables.users,
          sampleUser(id: 'user-alice-local', email: 'alice-new@example.com').toColumns());
      await db.insert(Tables.userEmails,
          sampleUserEmail(id: 'ue-1', userId: 'user-alice-local', email: 'alice@example.com')
              .toColumns());

      final result = await save(alicePayload(observerId: 'user-alice-remote', email: 'alice@example.com'));

      expect(result.observerUserId, 'user-alice-local');
      expect(result.observerMatchedViaPriorEmail, isTrue);
      expect((await onlyObservation()).userId, 'user-alice-local');
    });

    test('a prior email claimed by two distinct local users is ambiguous and does not match',
        () async {
      await db.insert(
          Tables.users, sampleUser(id: 'user-student-1', email: 'student1@example.com').toColumns());
      await db.insert(
          Tables.users, sampleUser(id: 'user-student-2', email: 'student2@example.com').toColumns());
      await db.insert(Tables.userEmails,
          sampleUserEmail(id: 'ue-1', userId: 'user-student-1', email: 'lab@example.com').toColumns());
      await db.insert(Tables.userEmails,
          sampleUserEmail(id: 'ue-2', userId: 'user-student-2', email: 'lab@example.com').toColumns());

      final result = await save(alicePayload(observerId: 'user-lab', email: 'lab@example.com'));

      // Falls through to creating a new user rather than guessing which
      // student the address now belongs to.
      expect(result.observerMatchedViaPriorEmail, isFalse);
      expect(result.observerUserId, 'user-lab');
      final created = await db.query(Tables.users, where: 'user_id = ?', whereArgs: ['user-lab']);
      expect(created, hasLength(1));
    });

    test('a single-word observer name does not break the NOT NULL last_name', () async {
      final payload = ObservationShare.encode(
        sampleObservation(id: 'obs-mono', userId: 'user-mono'),
        tag: sampleTag(),
        observer: User(
          userId: 'user-mono',
          firstName: 'Prince',
          lastName: '',
          email: 'prince@example.com',
          sync: sampleSync(),
        ),
      );
      await save(payload);
      final rows = await db.query(Tables.users, where: 'user_id = ?', whereArgs: ['user-mono']);
      expect(User.fromRow(rows.single).firstName, 'Prince');
      expect(User.fromRow(rows.single).lastName, '');
    });
  });

  group('already-have-this-row: MergeResolver decides, nothing throws', () {
    test('pasting the same payload twice yields one row, not a duplicate', () async {
      final payload = alicePayload();
      final first = await save(payload);
      final second = await save(payload);

      expect(first.outcome, SharedObservationImportOutcome.replicaInserted);
      expect(second.outcome, SharedObservationImportOutcome.replicaAlreadyCurrent);
      expect(await allObservations(), hasLength(1));
    });

    test('an incoming newer revision updates the local row, once confirmed',
        () async {
      await save(alicePayload(revision: 3, notes: 'first look'));

      // Since task 10.61 an import that would replace a value this device
      // already holds writes nothing until the user has seen what changes.
      final held = await save(alicePayload(revision: 4, notes: 'corrected bearing'));
      expect(held.outcome, SharedObservationImportOutcome.changeNeedsConfirmation);
      expect(held.destructiveChanges.map((c) => c.column), contains('notes'));
      expect((await onlyObservation()).notes, 'first look');

      final result =
          await save(alicePayload(revision: 4, notes: 'corrected bearing'),
              confirmChanges: true);
      expect(result.outcome, SharedObservationImportOutcome.replicaUpdated);
      final saved = await onlyObservation();
      expect(saved.notes, 'corrected bearing');
      // The update must carry the incoming clock, not a locally bumped one.
      expect(saved.sync.revision, 4);
    });

    test('an incoming older revision does not clobber a newer local row', () async {
      await save(alicePayload(revision: 5, notes: 'newer local copy'));
      final result = await save(alicePayload(revision: 2, notes: 'stale copy'));

      expect(result.outcome, SharedObservationImportOutcome.replicaAlreadyCurrent);
      final saved = await onlyObservation();
      expect(saved.notes, 'newer local copy');
      expect(saved.sync.revision, 5);
    });

    test('same revision, later updated_at wins (the MergeResolver tiebreak)', () async {
      await save(alicePayload(revision: 3, updatedAt: DateTime.utc(2026, 7, 20, 9, 0, 0)));
      final result = await save(
          alicePayload(
              revision: 3, updatedAt: DateTime.utc(2026, 7, 22, 9, 0, 0), notes: 'later'),
          confirmChanges: true);

      expect(result.outcome, SharedObservationImportOutcome.replicaUpdated);
      expect((await onlyObservation()).notes, 'later');
    });

    test('a locally-deleted row is compared, not ignored — no resurrection by insert', () async {
      await save(alicePayload(revision: 3));
      await db.update(
        Tables.observations,
        {'deleted_at': '2026-07-30T00:00:00.000Z', 'revision': 4},
        where: 'observation_id = ?',
        whereArgs: ['obs-alice'],
      );

      // Re-pasting the same (now older) payload must not insert a second row
      // over the tombstone, nor clear it.
      final result = await save(alicePayload(revision: 3));
      expect(result.outcome, SharedObservationImportOutcome.replicaAlreadyCurrent);
      final rows = await db.query(Tables.observations);
      expect(rows, hasLength(1));
      expect(rows.single['deleted_at'], isNotNull);
    });

    test('the duplication regression: two devices saving one shared observation converge', () async {
      // Alice shares the same observation with Bob (this DB) and Carol; Carol
      // forwards her copy on. Both arrivals must land on one row.
      final payload = alicePayload(observationId: 'obs-alice');
      await save(payload);
      await save(payload);

      final all = await allObservations();
      expect(all, hasLength(1),
          reason: 'the Phase 6 bug: two primary keys for one real observation');
      expect(all.single.observationId, 'obs-alice');
    });
  });

  group('v1 fallback', () {
    /// A v1 payload as an older build would have produced it: no identity block.
    String legacyPayload() {
      final v2 = ObservationShare.decode(alicePayload());
      expect(v2.canReplicate, isTrue);
      return _downgradeToV1(alicePayload());
    }

    test('decodes as unreplicable and creates a receiver-owned observation', () async {
      final shared = ObservationShare.decode(legacyPayload());
      expect(shared.canReplicate, isFalse);

      final result = await save(legacyPayload());
      expect(result.outcome, SharedObservationImportOutcome.legacyCopyCreated);
      expect(result.isReplica, isFalse);

      final saved = await onlyObservation();
      expect(saved.observationId, 'minted-id');
      expect(saved.userId, _receivingUserId);
      expect(saved.sync.revision, 0);
      expect(saved.sync.originDeviceId, _receivingDeviceId);
    });

    test('keeps the "Shared by" notes prefix, the only attribution left', () async {
      await save(legacyPayload());
      expect((await onlyObservation()).notes, 'Shared by Sam Ranger — clear signal');
    });

    test('records manual_entry, since no position_source travelled', () async {
      await save(legacyPayload());
      expect((await onlyObservation()).positionSource, PositionSource.manualEntry);
    });
  });
}

/// Rewrites a v2 payload as the v1 equivalent by stripping the identity block —
/// the only way to get a genuine v1 payload now that `encode` always emits v2.
String _downgradeToV1(String payload) {
  final json = _decodeJson(payload)
    ..['v'] = 1
    ..remove('observation_id')
    ..remove('observer_user_id')
    ..remove('observer_email')
    ..remove('position_source')
    ..remove('position_accuracy_m')
    ..remove('created_at')
    ..remove('updated_at')
    ..remove('revision')
    ..remove('last_modified_by')
    ..remove('origin_device_id');
  return 'TT1:${base64Encode(utf8.encode(jsonEncode(json)))}';
}

Map<String, Object?> _decodeJson(String payload) =>
    jsonDecode(utf8.decode(base64Decode(payload.substring('TT1:'.length))))
        as Map<String, Object?>;
