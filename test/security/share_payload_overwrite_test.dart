import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:tritrack/data/db/app_database.dart';
import 'package:tritrack/data/models/observation.dart';
import 'package:tritrack/data/sharing/observation_share.dart';
import 'package:tritrack/data/sharing/shared_observation_importer.dart';
import 'package:tritrack/data/sync/sync_conflicts.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

import '../data/fixtures.dart';

/// Finding **J-1** (security model §12.2) and the rule that closes it (§4.19).
///
/// A `TT1:` share payload is data from an untrusted party that reaches a real
/// observation with no server, no account and no network — one pasted string.
/// As shipped it moved the record to (0,0), reassigned its author, forged its
/// audit column to name the victim, and NULLed the nine fields that make a
/// bearing re-derivable, while reporting *"updated it to the newer version."*
///
/// The reproduction is kept verbatim as the first group. The rest assert the
/// four rules independently, because the finding's own note is that fixing any
/// one alone leaves it open — and that a fix which simply refuses everything
/// would break sharing, which is why `genuine share` is a group of its own and
/// is deliberately the largest.
void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  const victim = 'user-victim';
  const attacker = 'user-attacker';
  const receivingDevice = 'device-B';
  final now = DateTime.utc(2026, 8, 16, 12);

  late AppDatabase database;
  late Database db;
  late SharedObservationImporter importer;

  setUp(() async {
    database = await AppDatabase.openInMemory();
    db = database.raw;
    importer = SharedObservationImporter(db);
    await db.insert(Tables.users,
        sampleUser(id: victim, email: 'victim@nau.edu').toColumns());
    await db.insert(Tables.projects,
        sampleProject(id: 'project-local', ownerUserId: victim).toColumns());
    await db.insert(
      Tables.tags,
      sampleTag(id: 'tag-local', projectId: 'project-local').toColumns(),
    );
    await db.insert(
        Tables.triangulationSessions,
        sampleSession(
                id: 'session-local',
                projectId: 'project-local',
                tagId: 'tag-local')
            .toColumns());
  });
  tearDown(() async => database.close());

  /// The genuine field record: a fully-populated directional observation with
  /// its whole bearing audit trail, authored by the victim on this device.
  /// Matches §12.2's `BEFORE` line field for field.
  Future<Observation> seedFieldRecord({
    String id = 'obs-field',
    String userId = victim,
    int revision = 4,
  }) async {
    final observation = sampleObservation(
      id: id,
      projectId: 'project-local',
      userId: userId,
      tagId: 'tag-local',
      sessionId: 'session-local',
      latitude: 35.1983,
      longitude: -111.6513,
    ).copyWith(
      sync: sampleSync().copyWith(
        revision: revision,
        updatedAt: DateTime.utc(2026, 7, 20, 9),
        lastModifiedBy: victim,
        originDeviceId: receivingDevice,
      ),
    );
    await db.insert(Tables.observations, observation.toColumns());
    return observation;
  }

  /// Re-encodes a payload's JSON with [overrides] applied — the attacker's
  /// position exactly: they hold a legitimately-formatted payload (anyone the
  /// team ever shared with does) and edit the fields they want.
  String forge(String payload, Map<String, Object?> overrides) {
    final json = jsonDecode(
        utf8.decode(base64Decode(payload.substring('TT1:'.length)))) as Map;
    return 'TT1:${base64Encode(utf8.encode(jsonEncode({...json, ...overrides})))}';
  }

  /// `encode` asserts the observer *is* the row's author, so the observation is
  /// restated under [observerId] here. An attacker forges the difference after
  /// encoding, which is exactly what [forge] models.
  String payloadFrom(
    Observation observation, {
    required String observerId,
    required String observerEmail,
  }) =>
      ObservationShare.encode(
        observation.copyWith(userId: observerId),
        tag: sampleTag(id: 'tag-sender'),
        observer: sampleUser(id: observerId, email: observerEmail),
      );

  Future<SharedObservationImportResult> save(
    String payload, {
    bool confirmChanges = false,
  }) =>
      importer.save(
        ObservationShare.decode(payload, now: now),
        projectId: 'project-local',
        tagId: 'tag-local',
        receivingUserId: victim,
        receivingDeviceId: receivingDevice,
        newId: () => 'minted-id',
        confirmChanges: confirmChanges,
        now: now,
      );

  Future<Observation> onlyObservation() async {
    final rows = await db.query(Tables.observations);
    expect(rows, hasLength(1));
    return Observation.fromRow(rows.single);
  }

  /// The hostile payload from §12.2: same `observation_id` as a record this
  /// device holds, an unbeatable merge clock, the attacker as observer, and
  /// `last_modified_by` forged to name the victim so the row records its own
  /// destruction as the victim's own edit.
  String hostilePayload({int revision = 9223372036854775807}) {
    final base = payloadFrom(
      sampleObservation(id: 'obs-field').copyWith(
        latitude: 0,
        longitude: 0,
        sync: sampleSync().copyWith(lastModifiedBy: victim),
      ),
      observerId: attacker,
      observerEmail: 'attacker@example.com',
    );
    return forge(base, {
      'observation_id': 'obs-field',
      'revision': revision,
      'last_modified_by': victim,
      'latitude': 0.0,
      'longitude': 0.0,
    });
  }

  group('J-1 reproduction', () {
    test('the unbounded revision is refused by the parser, not clamped',
        () async {
      // Clamping would leave the forged clock winning last-write-wins against
      // every honest local edit — the attack succeeding while the bound reports
      // that it worked.
      expect(
        () => ObservationShare.decode(hostilePayload(), now: now),
        throwsA(isA<ObservationShareFormatException>().having(
            (e) => e.message, 'message', contains('implausibly large'))),
      );
    });

    test('a future updated_at is refused', () async {
      final base = payloadFrom(
        sampleObservation(id: 'obs-field'),
        observerId: attacker,
        observerEmail: 'attacker@example.com',
      );
      final forged = forge(base, {
        'created_at': now.toIso8601String(),
        'updated_at': now.add(const Duration(days: 3650)).toIso8601String(),
      });
      expect(
        () => ObservationShare.decode(forged, now: now),
        throwsA(isA<ObservationShareFormatException>()
            .having((e) => e.message, 'message', contains('in the future'))),
      );
    });

    test('the whole attack, with a clock inside the bounds, still refuses and '
        'leaves every field intact', () async {
      final before = await seedFieldRecord(revision: 4);
      // revision 900 is legal, beats 4, and is what an attacker uses once the
      // absurd value stops parsing. The bound is not the defence.
      //
      // It was 4,000,000,000 until task 10.93. That value is now refused at
      // the door — finding L-2: a clock legal to *hold* is not legal to
      // *receive*, because the holder's own next edit takes it past the
      // ceiling and their export never restores again. A smaller legal value
      // keeps this test measuring the clause it is about.
      final result = await save(hostilePayload(revision: 900));

      expect(result.outcome, SharedObservationImportOutcome.refusedNotAuthor);
      expect(result.existingAuthorUserId, victim);
      expect(result.wrote, isFalse);

      final after = await onlyObservation();
      expect(after, before, reason: 'not one column may differ');
    });

    test('a refused payload deposits no Users row for the attacker', () async {
      await seedFieldRecord();
      await save(hostilePayload(revision: 900));

      final users = await db.query(Tables.users);
      expect(users.map((r) => r['user_id']), [victim],
          reason: 'a Users row planted by a refused import is an identity '
              'anchor a later file import can match on');
    });
  });

  group('rule 1 — only columns the payload can express are written', () {
    /// The columns a v2 payload has no way to carry. §12.2 watched every one of
    /// these become NULL on a real record; the first six are what make a
    /// bearing re-derivable rather than merely believed.
    const uncarried = [
      'magnetic_bearing_start',
      'magnetic_bearing_end',
      'true_north_bearing_start',
      'true_north_bearing_end',
      'magnetic_declination',
      'wmm_model_version',
      'bearing_capture_method',
      'bearing_method',
      'antenna_type',
      'receiver_gain',
      'altitude_agl',
      'session_id',
    ];

    test('no field populated before an import is null after one', () async {
      await seedFieldRecord(revision: 4);
      final beforeRow = (await db.query(Tables.observations)).single;
      final populated = [
        for (final entry in beforeRow.entries)
          if (entry.value != null) entry.key
      ];
      expect(populated, isNotEmpty);

      // A genuine authored update from the victim's other device — the case
      // that must still work, driven through the full consent path.
      final genuine = payloadFrom(
        sampleObservation(id: 'obs-field', userId: victim).copyWith(
          latitude: 35.2,
          sync: sampleSync().copyWith(
            revision: 7,
            updatedAt: DateTime.utc(2026, 8, 1),
            originDeviceId: 'device-C',
          ),
        ),
        observerId: victim,
        observerEmail: 'victim@nau.edu',
      );
      final result = await save(genuine, confirmChanges: true);
      expect(result.outcome, SharedObservationImportOutcome.replicaUpdated);

      final afterRow = (await db.query(Tables.observations)).single;
      for (final column in populated) {
        expect(afterRow[column], isNotNull,
            reason: '$column was populated before the import and is null after');
      }
    });

    test('every uncarried column keeps its exact prior value', () async {
      final before = await seedFieldRecord(revision: 4);
      final beforeRow = (await db.query(Tables.observations)).single;
      for (final column in uncarried) {
        expect(beforeRow[column], isNotNull,
            reason: 'the fixture must actually populate $column for this test '
                'to mean anything');
      }

      final genuine = payloadFrom(
        before.copyWith(
          notes: 'corrected on the second device',
          sync: before.sync.copyWith(
            revision: 9,
            updatedAt: DateTime.utc(2026, 8, 2),
          ),
        ),
        observerId: victim,
        observerEmail: 'victim@nau.edu',
      );
      await save(genuine, confirmChanges: true);

      final afterRow = (await db.query(Tables.observations)).single;
      for (final column in uncarried) {
        expect(afterRow[column], beforeRow[column], reason: column);
      }
      expect(afterRow['notes'], 'corrected on the second device');
    });

    test('the write set and the wire format cannot drift apart', () {
      // The defect was that `toColumns()` emitted 38 columns while the payload
      // carried ~20. Asserting the declared write set against `encode`'s actual
      // output is what stops the two diverging again the next time a field is
      // added to either.
      final encoded = ObservationShare.encode(
        sampleObservation(id: 'obs-1'),
        tag: sampleTag(),
        observer: sampleUser(id: 'user-1'),
      );
      final json = jsonDecode(
              utf8.decode(base64Decode(encoded.substring('TT1:'.length))))
          as Map<String, Object?>;

      // Wire keys that are not `Observations` columns: the envelope version,
      // the observer block, and the tag *key* (the receiver resolves its own
      // local tag id rather than trusting the sender's).
      const notColumns = {
        'v',
        'observer_user_id',
        'observer_email',
        'observer_name',
        'tag_frequency_mhz',
        'tag_pulse_rate',
        'tag_name',
        // Task 11.32: says whether the three above are what the bearing was
        // recorded against or the sender's present-day tag values. Payload
        // metadata about the tag key, not a column of `Observations` — the
        // receiver's own `tag_version_id` is deliberately never written from a
        // payload, so a pasted record reads "not recorded" rather than
        // inheriting a version id that means nothing on this device.
        'tag_values_recorded',
        // Task 11.187. `pulse_mode` and `pulse_mode_name` travel so the paste
        // screen can say which mode the sender heard this on, in the sender's
        // own words. **Neither is written**, for the reason `tag_version_id`
        // is not: a slot number names a mode on the sender's tag, and the
        // replica is relabelled onto whichever local tag the receiver picked.
        'pulse_mode',
        'pulse_mode_name',
        'observation_id',
      };
      // Written on the receiver's authority rather than carried on the wire —
      // documented on `writableColumns` itself.
      const receiverSupplied = {'user_id', 'tag_id', 'deleted_at'};

      final fromWire = json.keys.toSet().difference(notColumns);
      expect(
        ObservationShare.writableColumns.difference(receiverSupplied),
        fromWire,
        reason: 'writableColumns must be exactly what encode() emits, plus the '
            'three the receiver supplies',
      );

      // And every one of them must be a real column.
      final allColumns = sampleObservation().toColumns().keys.toSet();
      expect(ObservationShare.writableColumns.difference(allColumns), isEmpty);
    });
  });

  group('rule 2 — authorship never comes from a payload', () {
    test('a payload from a non-author may not modify the row, however new its '
        'clock', () async {
      await seedFieldRecord(revision: 4);
      final result = await save(hostilePayload(revision: 900));
      expect(result.outcome, SharedObservationImportOutcome.refusedNotAuthor);
      expect((await onlyObservation()).userId, victim);
    });

    test('authorship is checked before the merge clock, so a forged payload is '
        'never told "your copy is up to date"', () async {
      await seedFieldRecord(revision: 900);
      // Clock loses as well as being forged; the message must name the refusal
      // it actually is, not the benign one.
      final result = await save(hostilePayload(revision: 1));
      expect(result.outcome, SharedObservationImportOutcome.refusedNotAuthor);
    });

    test('last_modified_by is the resolved observer, never the payload claim',
        () async {
      // The payload names the victim as last modifier. On an insert there is no
      // authorship check to catch it, so the column must be restated outright.
      final forged = forge(
        payloadFrom(
          sampleObservation(id: 'obs-new'),
          observerId: attacker,
          observerEmail: 'attacker@example.com',
        ),
        {'observation_id': 'obs-new', 'last_modified_by': victim},
      );
      final result = await save(forged);
      expect(result.outcome, SharedObservationImportOutcome.replicaInserted);

      final saved = await onlyObservation();
      expect(saved.sync.lastModifiedBy, isNot(victim));
      expect(saved.sync.lastModifiedBy, saved.userId);
    });

    test('user_id is never in the update statement for an existing row',
        () async {
      final before = await seedFieldRecord();
      final genuine = payloadFrom(
        before.copyWith(
          notes: 'edited',
          sync: before.sync.copyWith(revision: 12),
        ),
        observerId: victim,
        observerEmail: 'victim@nau.edu',
      );
      await save(genuine, confirmChanges: true);
      expect((await onlyObservation()).userId, victim);
    });
  });

  group('rule 4 — nothing destructive without the user seeing it', () {
    test('a change that would replace held values writes nothing and reports '
        'what it would change', () async {
      final before = await seedFieldRecord();
      final genuine = payloadFrom(
        before.copyWith(
          latitude: 35.9,
          notes: 'moved',
          sync: before.sync.copyWith(
            revision: 20,
            updatedAt: DateTime.utc(2026, 8, 5),
          ),
        ),
        observerId: victim,
        observerEmail: 'victim@nau.edu',
      );

      final result = await save(genuine);
      expect(result.outcome,
          SharedObservationImportOutcome.changeNeedsConfirmation);
      expect(result.wrote, isFalse);
      expect(
        result.destructiveChanges.map((c) => c.column),
        containsAll(<String>['latitude', 'notes']),
      );
      expect(await onlyObservation(), before, reason: 'nothing written');
    });

    /// Finding **K-8** — rule 4's own exemption list, reproduced on the path
    /// rule 4 was written for.
    ///
    /// `clockColumns` exempted five columns from the `was → becomes` diff, and
    /// the justification beside it covered two of them. `created_at` and
    /// `origin_device_id` do not move on an honest edit, are taken verbatim
    /// from the payload, and were exempt anyway — so a payload identical to
    /// the victim's own row in every carried field, differing only in those
    /// two, was written with **no dialog** while the screen reported
    /// *"replaced as you confirmed — 0 values were changed."*
    ///
    /// `origin_device_id` is the documented final last-write-wins tiebreaker
    /// (`postgres_schema.dart`), so a lexically-high forged value wins every
    /// future tie against the victim's genuine edits; `created_at` is
    /// falsified provenance. Neither is cosmetic.
    test('a payload differing only in created_at and origin_device_id is held '
        'at the gate (K-8)', () async {
      final before = await seedFieldRecord();
      final forged = forge(
        payloadFrom(
          before.copyWith(
            sync: before.sync.copyWith(
              revision: 900,
              updatedAt: DateTime.utc(2026, 8, 5),
            ),
          ),
          observerId: victim,
          observerEmail: 'victim@nau.edu',
        ),
        {
          // Moved forward from the row's genuine birth instant, and still
          // inside rule 3's bound — the clause-3 run in this same file shows
          // that an out-of-range value is refused outright, which is exactly
          // why the in-range forgery is the interesting one here.
          'created_at': DateTime.utc(2026, 8, 1).toIso8601String(),
          'origin_device_id': 'zzzz-attacker-wins-every-tie',
        },
      );

      final result = await save(forged);
      expect(result.outcome,
          SharedObservationImportOutcome.changeNeedsConfirmation);
      expect(
        result.destructiveChanges.map((c) => c.column),
        containsAll(<String>['created_at', 'origin_device_id']),
      );
      expect(await onlyObservation(), before, reason: 'nothing written');
    });

    test('filling an empty column is not treated as destructive', () async {
      final bare = sampleObservation(
        id: 'obs-bare',
        projectId: 'project-local',
        userId: victim,
        tagId: 'tag-local',
        sessionId: 'session-local',
      ).copyWith(
        notes: null,
        sync: sampleSync().copyWith(revision: 1, lastModifiedBy: victim),
      );
      await db.insert(Tables.observations, bare.toColumns());

      final genuine = payloadFrom(
        bare.copyWith(
          notes: 'added later',
          sync: bare.sync.copyWith(
            revision: 2,
            updatedAt: DateTime.utc(2026, 8, 5),
          ),
        ),
        observerId: victim,
        observerEmail: 'victim@nau.edu',
      );
      // No `confirmChanges`: an addition needs no consent because it destroys
      // nothing, and prompting for it would train the user to click through the
      // prompt that matters.
      final result = await save(genuine);
      expect(result.outcome, SharedObservationImportOutcome.replicaUpdated);
      expect((await onlyObservation()).notes, 'added later');
    });

    test('the prior version is recoverable after a confirmed overwrite',
        () async {
      final before = await seedFieldRecord();
      final genuine = payloadFrom(
        before.copyWith(
          latitude: 35.9,
          sync: before.sync.copyWith(
            revision: 20,
            updatedAt: DateTime.utc(2026, 8, 5),
          ),
        ),
        observerId: victim,
        observerEmail: 'victim@nau.edu',
      );
      await save(genuine, confirmChanges: true);

      final conflicts =
          await SyncConflictStore(db).unreviewed('project-local');
      expect(conflicts, hasLength(1));
      expect(conflicts.single.rowKey, 'obs-field');
      expect(conflicts.single.localSnapshot['latitude'], 35.1983);
      expect(
        conflicts.single.changedFields.map((f) => f.field),
        contains('latitude'),
      );
    });

    test('a local tombstone is a visible change, not a silent resurrection',
        () async {
      final before = await seedFieldRecord();
      await db.update(
        Tables.observations,
        {'deleted_at': DbCodec.encodeUtc(DateTime.utc(2026, 8, 10))},
        where: 'observation_id = ?',
        whereArgs: ['obs-field'],
      );

      final genuine = payloadFrom(
        before.copyWith(
          sync: before.sync.copyWith(
            revision: 30,
            updatedAt: DateTime.utc(2026, 8, 12),
          ),
        ),
        observerId: victim,
        observerEmail: 'victim@nau.edu',
      );
      final result = await save(genuine);
      expect(result.outcome,
          SharedObservationImportOutcome.changeNeedsConfirmation);
      expect(result.destructiveChanges.map((c) => c.column),
          contains('deleted_at'));
    });

    test('an outcome that wrote nothing says so', () {
      for (final outcome in SharedObservationImportOutcome.values) {
        final wrote = SharedObservationImportResult(
          outcome: outcome,
          observationId: 'x',
          observerUserId: 'y',
        ).wrote;
        expect(
          wrote,
          outcome == SharedObservationImportOutcome.replicaInserted ||
              outcome == SharedObservationImportOutcome.replicaUpdated ||
              outcome == SharedObservationImportOutcome.legacyCopyCreated,
          reason: '$outcome',
        );
      }
    });
  });

  group('rule 5 — RowValidator runs on this path', () {
    test('a row the server would refuse is refused here first', () async {
      // Bounded by `decode` only for the fields it happens to check; this one
      // (a negative accuracy is rejected, but an out-of-range *uncertainty* is
      // not) is exactly the kind that reached the database before.
      final forged = forge(
        payloadFrom(
          sampleObservation(id: 'obs-new'),
          observerId: attacker,
          observerEmail: 'attacker@example.com',
        ),
        {'observation_id': 'obs-new', 'bearing_uncertainty': -5.0},
      );
      final result = await save(forged);
      expect(result.outcome, SharedObservationImportOutcome.refusedInvalid);
      expect(result.issues, isNotEmpty);
      expect(await db.query(Tables.observations), isEmpty);
    });
  });

  group('genuine share — the fix must not be "refuse everything"', () {
    test('a colleague\'s observation this device has never seen imports',
        () async {
      final alice = payloadFrom(
        sampleObservation(id: 'obs-alice', userId: 'user-alice'),
        observerId: 'user-alice',
        observerEmail: 'alice@example.com',
      );
      final result = await save(alice);

      expect(result.outcome, SharedObservationImportOutcome.replicaInserted);
      final saved = await onlyObservation();
      expect(saved.observationId, 'obs-alice');
      expect(saved.userId, 'user-alice',
          reason: 'the replica is still attributed to the original observer');
      expect(saved.sync.revision, sampleSync().revision);
      expect(saved.projectId, 'project-local');
      expect(saved.tagId, 'tag-local');
    });

    test('a re-share after the author edited it updates, with consent',
        () async {
      // Alice's row as this device holds it — arrived by server sync, so it has
      // the full bearing audit trail a share payload cannot carry. That is the
      // configuration where a column-set overwrite does its damage.
      await db.insert(Tables.users,
          sampleUser(id: 'user-alice', email: 'alice@example.com').toColumns());
      final alice = await seedFieldRecord(id: 'obs-alice', userId: 'user-alice');
      expect((await onlyObservation()).trueNorthBearing, 155.2);

      final corrected = payloadFrom(
        alice.copyWith(
          trueNorthBearing: 161.4,
          notes: 'bearing re-derived after declination correction',
          sync: alice.sync.copyWith(
            revision: 9,
            updatedAt: DateTime.utc(2026, 8, 4),
          ),
        ),
        observerId: 'user-alice',
        observerEmail: 'alice@example.com',
      );

      final held = await save(corrected);
      expect(held.outcome,
          SharedObservationImportOutcome.changeNeedsConfirmation);

      final applied = await save(corrected, confirmChanges: true);
      expect(applied.outcome, SharedObservationImportOutcome.replicaUpdated);

      final saved = await onlyObservation();
      expect(saved.trueNorthBearing, 161.4);
      expect(saved.notes, 'bearing re-derived after declination correction');
      expect(saved.sync.revision, 9);
      expect(saved.userId, 'user-alice');
      // The bearing audit trail the payload cannot carry is still there.
      expect(saved.wmmModelVersion, 'WMM2025');
      expect(saved.magneticDeclination, 10.2);
      expect(saved.trueNorthBearingStart, 150.2);
    });

    test('pasting the same genuine payload twice is still "already current"',
        () async {
      final alice = payloadFrom(
        sampleObservation(id: 'obs-alice', userId: 'user-alice'),
        observerId: 'user-alice',
        observerEmail: 'alice@example.com',
      );
      await save(alice);
      final second = await save(alice);
      expect(second.outcome,
          SharedObservationImportOutcome.replicaAlreadyCurrent);
    });

    test('a v1 payload still creates a receiver-owned copy', () async {
      final v1 = forge(
        payloadFrom(
          sampleObservation(id: 'obs-alice', userId: 'user-alice'),
          observerId: 'user-alice',
          observerEmail: 'alice@example.com',
        ),
        {'v': 1},
      );
      final result = await save(v1);
      expect(result.outcome, SharedObservationImportOutcome.legacyCopyCreated);
      expect((await onlyObservation()).observationId, 'minted-id');
    });
  });
}
