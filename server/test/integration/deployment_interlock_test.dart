@Tags(['postgres'])
library;

import 'package:postgres/postgres.dart';
import 'package:test/test.dart';
import 'package:tritrack_server/tritrack_server.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

import '../support/database_test_config.dart';

/// **Michael's interlock at the server's boundary** — task 11.243's rule,
/// with its one-day allowance withdrawn by task 11.263 (design §6a), asked
/// of a row arriving over the wire rather than of a row a screen is about to
/// write.
///
/// Until this file existed nothing in `server/test` exercised
/// `SyncService._overlapsAStoredDeployment` at all: the rule was tested in
/// the shared package and the server's call of it was a sentence in a doc
/// comment. **A rule enforced on one device is a rule about that device**
/// (§6); this is the evidence that the server enforces it too.
///
/// **Every date here is a local `DateTime` encoded through `DbCodec`**, the
/// way a device writes one — and this process is both the writer and the
/// reader, so the bare-day sentinel (`deploymentEndHasTime`, local midnight)
/// reads exactly, as it would for a real device that happens to share the
/// server's zone. On the beta server that is usually not so: the container
/// runs in UTC and the phones do not, which is what
/// `DeploymentInterlock`'s doc comment prices and task 11.266's
/// `zonelessEndsAreInstants` flag (hardcoded on in
/// `SyncService._overlapsAStoredDeployment`) exists for. **This file tests
/// the rule; it cannot test a genuine cross-zone mismatch** — but the
/// same-zone case it *can* test is exactly the flag's stated give-up (see
/// the group below), so where the two collide, the test says so rather than
/// asserting the pre-11.266 outcome.
void main() {
  late Connection connection;
  const testSchema = 'tritrack_deployment_interlock_test';
  const projectId = 'proj-1';
  const userId = 'user-1';
  const deviceId = 'device-A';
  const at = '2026-08-01T12:00:00.000Z';

  setUpAll(() async {
    if (testDatabaseConfig == null) return;
    connection = await Connection.open(
      testDatabaseConfig!.endpoint,
      settings: const ConnectionSettings(sslMode: SslMode.disable),
    );
  });

  tearDownAll(() async {
    if (testDatabaseConfig == null) return;
    await connection.execute('DROP SCHEMA IF EXISTS $testSchema CASCADE');
    await connection.close();
  });

  setUp(() async {
    if (testDatabaseConfig == null) return;
    await connection.execute('DROP SCHEMA IF EXISTS $testSchema CASCADE');
    await connection.execute('CREATE SCHEMA $testSchema');
    await connection.execute('SET search_path TO $testSchema');
    await PostgresMigrations.run(connection);
    await _seed(connection);
  });

  /// A bare day, as the app writes one: local midnight.
  DateTime day(int d) => DateTime(2026, 3, d);

  /// A swap time on [d], as the §5a confirmation writes one.
  DateTime swapAt(int d) => DateTime(2026, 3, d, 14, 32, 50);

  Map<String, Object?> deployment(
    String id, {
    required String tagId,
    required String individualId,
    required DateTime attached,
    DateTime? removed,
    int revision = 1,
    String? timeZone,
  }) => {
    'deployment_id': id,
    'project_id': projectId,
    'tag_id': tagId,
    'individual_id': individualId,
    'attached_date': DbCodec.encodeUtc(attached),
    'removed_date': removed == null ? null : DbCodec.encodeUtc(removed),
    'notes': null,
    'created_at': at,
    'updated_at': at,
    'revision': revision,
    'last_modified_by': userId,
    'origin_device_id': deviceId,
    // Task 11.331: absent from a row pushed by a build older than v20.
    if (timeZone != null) 'time_zone': timeZone,
  };

  Future<PushResult> push(SyncRows rows) => connection.runTx(
    (tx) => SyncService(session: tx).applyPush(
      projectId: projectId,
      rows: rows,
      deviceId: deviceId,
      authorizer: RowAuthorizer(
        session: tx,
        projectId: projectId,
        userId: userId,
        access: ProjectAccess.owner,
      ),
    ),
  );

  String key(String id) => '${Tables.deployments}/$id/$projectId';

  Future<int> storedCount() async {
    final result = await connection.execute(
      'SELECT count(*) FROM ${quoted(Tables.deployments)} '
      r'WHERE project_id = $1',
      parameters: [projectId],
    );
    return result.first.first! as int;
  }

  group('task 11.331: a row that carries its zone is read in it — the server '
      'stops guessing', skip: databaseSkipReason, () {
    // Arizona (UTC−7) is never this suite's zone on the VM (UTC) and rarely
    // on the Mac; the rows say where their days were written, so the
    // answer cannot depend on where the server runs.
    const phoenix = 'America/Phoenix';
    DateTime arizonaDay(int d) => fieldDayStart(DateTime(2026, 3, d), phoenix);

    test(
      'WATCHED RED BEFORE THE ZONE COLUMN: a same-day handover recorded as '
      'two bare Arizona days is refused on the server, as on the device',
      () async {
        final first = await push({
          Tables.deployments: [
            deployment(
              'dep-old',
              tagId: 'tag-a',
              individualId: 'ind-marie',
              attached: arizonaDay(1),
              removed: arizonaDay(10),
              timeZone: phoenix,
            ),
          ],
        });
        expect(first.outcomes[key('dep-old')], SyncRowOutcome.inserted);
        final second = await push({
          Tables.deployments: [
            deployment(
              'dep-new',
              tagId: 'tag-b',
              individualId: 'ind-marie',
              attached: arizonaDay(10),
              timeZone: phoenix,
            ),
          ],
        });
        expect(second.outcomes[key('dep-new')], isNot(SyncRowOutcome.inserted));
        expect(await storedCount(), 1);
      },
    );

    test(
      'a timed handover at exactly 17:00 Arizona — 00:00 UTC, the one-in-24 '
      'case tasks 11.264 and 11.266 priced — is accepted, and its zone is '
      'stored',
      () async {
        final swap = fieldInstant(DateTime(2026, 3, 10, 17), phoenix);
        final result = await push({
          Tables.deployments: [
            deployment(
              'dep-old',
              tagId: 'tag-a',
              individualId: 'ind-marie',
              attached: arizonaDay(1),
              removed: swap,
              timeZone: phoenix,
            ),
            deployment(
              'dep-new',
              tagId: 'tag-b',
              individualId: 'ind-marie',
              attached: swap,
              timeZone: phoenix,
            ),
          ],
        });
        expect(result.outcomes[key('dep-old')], SyncRowOutcome.inserted);
        expect(result.outcomes[key('dep-new')], SyncRowOutcome.inserted);
        final zones = await connection.execute(
          'SELECT time_zone FROM ${quoted(Tables.deployments)} '
          r'WHERE project_id = $1',
          parameters: [projectId],
        );
        expect(zones.map((r) => r.first), everyElement(phoenix));
      },
    );
  });

  group('the interlock on a push', skip: databaseSkipReason, () {
    test(
      'TASK 11.266\'S GIVE-UP, WATCHED: a same-day handover as two bare '
      'days is accepted when the writer shares the server\'s own zone',
      () async {
        // This suite cannot simulate a genuine cross-zone device (see the
        // file header) — but it does not need to, to demonstrate the flag's
        // documented cost. This process is both writer and reader, so it
        // stands in for "a device in the server's own zone" exactly: with
        // `zonelessEndsAreInstants` always on, the server no longer asks
        // whether a removal is a bare day at all, so it cannot widen this
        // one to the whole of the 10th even though this process's own
        // sentinel says it is one. Before task 11.266 this pair was refused
        // (that was this test, titled "THE CASE THAT USED TO PASS"); this is
        // the one case `DeploymentInterlock`'s class comment says the flag
        // gives up, reproduced rather than asserted.
        final first = await push({
          Tables.deployments: [
            deployment(
              'dep-old',
              tagId: 'tag-a',
              individualId: 'ind-marie',
              attached: day(1),
              removed: day(10),
            ),
          ],
        });
        expect(first.outcomes[key('dep-old')], SyncRowOutcome.inserted);

        final second = await push({
          Tables.deployments: [
            deployment(
              'dep-new',
              tagId: 'tag-b',
              individualId: 'ind-marie',
              attached: day(10),
            ),
          ],
        });
        expect(
          second.outcomes[key('dep-new')],
          SyncRowOutcome.inserted,
          reason: 'a same-zone legacy device is the one producer the server '
              'can no longer catch — see DeploymentInterlock\'s class '
              'comment, "the day-only sentinel is read in this process\'s '
              'zone, and the server\'s is not the writer\'s"',
        );
        expect(await storedCount(), 2);
      },
    );

    test(
      'a current build never produces this pair to begin with — the device '
      'refuses the same two dates locally (task 11.263), in its own zone, '
      'before this ever reaches the server',
      () {
        expect(
          DeploymentInterlock.conflictFor(
            DeploymentInterlock.intervalFromRow(
              deployment(
                'dep-new',
                tagId: 'tag-b',
                individualId: 'ind-marie',
                attached: day(10),
              ),
            )!,
            [
              DeploymentInterlock.intervalFromRow(
                deployment(
                  'dep-old',
                  tagId: 'tag-a',
                  individualId: 'ind-marie',
                  attached: day(1),
                  removed: day(10),
                ),
              )!,
            ],
            // No flag — this is the device's own local check, which reads
            // the sentinel in its own zone and is exact.
          ),
          isNotNull,
        );
      },
    );

    test(
      'THE CASE THAT MUST STILL PASS: a timed handover at the same instant is '
      'stored',
      () async {
        final first = await push({
          Tables.deployments: [
            deployment(
              'dep-old',
              tagId: 'tag-a',
              individualId: 'ind-marie',
              attached: day(1),
              removed: swapAt(10),
            ),
          ],
        });
        expect(first.outcomes[key('dep-old')], SyncRowOutcome.inserted);

        final second = await push({
          Tables.deployments: [
            deployment(
              'dep-new',
              tagId: 'tag-b',
              individualId: 'ind-marie',
              attached: swapAt(10),
            ),
          ],
        });
        expect(second.outcomes[key('dep-new')], SyncRowOutcome.inserted);
        expect(await storedCount(), 2);
      },
    );

    test('a handover recorded a day apart, as bare days, is stored', () async {
      await push({
        Tables.deployments: [
          deployment(
            'dep-old',
            tagId: 'tag-a',
            individualId: 'ind-marie',
            attached: day(1),
            removed: day(9),
          ),
        ],
      });
      final second = await push({
        Tables.deployments: [
          deployment(
            'dep-new',
            tagId: 'tag-b',
            individualId: 'ind-marie',
            attached: day(10),
          ),
        ],
      });
      expect(second.outcomes[key('dep-new')], SyncRowOutcome.inserted);
    });

    test('one collar on two animals at once is refused — the tag side', () async {
      await push({
        Tables.deployments: [
          deployment(
            'dep-marie',
            tagId: 'tag-a',
            individualId: 'ind-marie',
            attached: day(1),
          ),
        ],
      });
      final second = await push({
        Tables.deployments: [
          deployment(
            'dep-kea',
            tagId: 'tag-a',
            individualId: 'ind-kea',
            attached: day(5),
          ),
        ],
      });
      expect(second.outcomes[key('dep-kea')], SyncRowOutcome.invalid);
      expect(await storedCount(), 1);
      expect(
        second.interlockRefusals[key('dep-kea')],
        DeploymentInterlock.ruleId,
      );
    });

  });

  group('a stored pair the rule would now refuse', skip: databaseSkipReason, () {
    Future<void> plantLegacyPair() => connection.runTx((tx) async {
      for (final row in [
        deployment(
          'dep-old',
          tagId: 'tag-a',
          individualId: 'ind-marie',
          attached: day(1),
          removed: day(10),
        ),
        deployment(
          'dep-new',
          tagId: 'tag-b',
          individualId: 'ind-marie',
          attached: day(10),
        ),
      ]) {
        await _insertStored(tx, row, at);
      }
    });

    test('stays stored — the interlock governs writes, not reads (design §9)',
        () async {
      // What a build with the one-day allowance left on the server. Nothing
      // migrates or deletes it, and a pull would hand both rows back.
      await plantLegacyPair();
      expect(await storedCount(), 2);
    });

    test(
      'an edit that only touches an unrelated field is accepted — task '
      '11.266\'s give-up again, this time on a stored pair rather than an '
      'incoming one',
      () async {
        // Before task 11.266 this edit was refused: the stored `dep-old`
        // (day 1 to a bare day 10) widened to cover through day 11, so
        // `dep-new`'s still-open interval starting on day 10 read as
        // overlapping it. With `zonelessEndsAreInstants` always on, the
        // server can no longer widen `dep-old`'s bare day at all — it reads
        // day 10 as the exact instant it holds, which is where `dep-new`
        // starts, and an instant has no width to share. This is the same
        // same-zone give-up as the group above, reached through an edit
        // instead of a fresh insert. A cross-zone legacy pair — the case
        // this suite cannot simulate — would still be caught, because a
        // genuinely different zone does not collapse to the exact instant.
        await plantLegacyPair();
        final edit = await push({
          Tables.deployments: [
            {
              ...deployment(
                'dep-new',
                tagId: 'tag-b',
                individualId: 'ind-marie',
                attached: day(10),
                revision: 2,
              ),
              'notes': 'refitted',
              'updated_at': '2026-08-02T12:00:00.000Z',
            },
          ],
        });
        expect(edit.outcomes[key('dep-new')], SyncRowOutcome.updated);
        expect(await storedCount(), 2);
      },
    );

    test(
      'a tombstone of either half is accepted — withdrawing a link cannot '
      'create an overlap',
      () async {
        // Found by task 11.263 while writing this file. `conflictFor` skipped
        // a *stored* tombstone and never asked whether the *candidate* was
        // one, so the server refused a withdrawal whenever the row being
        // withdrawn overlapped something — which, for the pair this group is
        // about, is always. The only repair a person has for a legacy pair
        // starts with "Remove record", so this refusal closed the only door.
        await plantLegacyPair();
        final withdraw = await push({
          Tables.deployments: [
            {
              ...deployment(
                'dep-new',
                tagId: 'tag-b',
                individualId: 'ind-marie',
                attached: day(10),
                revision: 2,
              ),
              'deleted_at': '2026-08-02T12:00:00.000Z',
              'updated_at': '2026-08-02T12:00:00.000Z',
            },
          ],
        });
        expect(withdraw.outcomes[key('dep-new')], SyncRowOutcome.updated);
      },
    );
  });

  group('a page is checked in the order the device wrote it', skip: databaseSkipReason,
      () {
    test(
      'THE ORDINARY SWAP, pushed as one page: the old row closed at 14:32 and '
      'the new row opened at 14:32 are both stored',
      () async {
        // What `DeploymentLinking.apply` writes in one transaction and the
        // device then pushes in one page, oldest `updated_at` first. Until
        // task 11.263 the server decided every row against the *stored*
        // rows and wrote afterwards, so the new row was checked against the
        // old row still open in the store — an unbounded overlap — and
        // refused, on every same-day swap anybody synced. Nothing in
        // `server/test` had ever pushed a swap.
        final first = await push({
          Tables.deployments: [
            deployment(
              'dep-old',
              tagId: 'tag-a',
              individualId: 'ind-marie',
              attached: day(1),
            ),
          ],
        });
        expect(first.outcomes[key('dep-old')], SyncRowOutcome.inserted);

        final swap = await push({
          Tables.deployments: [
            deployment(
              'dep-old',
              tagId: 'tag-a',
              individualId: 'ind-marie',
              attached: day(1),
              removed: swapAt(10),
              revision: 2,
            ),
            deployment(
              'dep-new',
              tagId: 'tag-b',
              individualId: 'ind-marie',
              attached: swapAt(10),
            ),
          ],
        });
        expect(swap.outcomes[key('dep-old')], SyncRowOutcome.updated);
        expect(swap.outcomes[key('dep-new')], SyncRowOutcome.inserted,
            reason: 'checked against the old row as this page leaves it — '
                'closed at 14:32 — not as the store held it');
        expect(await storedCount(), 2);
      },
    );

    test(
      'the same page in the other order is refused, because the new row is '
      'checked against what has landed so far — and the device writes the '
      'closing first',
      () async {
        // Recorded so the order-dependence is a stated property rather than
        // a surprise: the page is checked as a sequence, the way the device
        // wrote it, and a page that opens the new collar before closing the
        // old one is a page no build of this app writes.
        await push({
          Tables.deployments: [
            deployment(
              'dep-old',
              tagId: 'tag-a',
              individualId: 'ind-marie',
              attached: day(1),
            ),
          ],
        });
        final swap = await push({
          Tables.deployments: [
            deployment(
              'dep-new',
              tagId: 'tag-b',
              individualId: 'ind-marie',
              attached: swapAt(10),
            ),
            deployment(
              'dep-old',
              tagId: 'tag-a',
              individualId: 'ind-marie',
              attached: day(1),
              removed: swapAt(10),
              revision: 2,
            ),
          ],
        });
        expect(swap.outcomes[key('dep-new')], SyncRowOutcome.invalid);
        expect(swap.outcomes[key('dep-old')], SyncRowOutcome.updated);
      },
    );

    test(
      'a legacy bare-day pair is repaired in one page: withdraw the new half, '
      'time the old half, re-link with the same instant',
      () async {
        // The repair the animal's screen leads a person through, in the
        // order they do it — which is the order the device pushes it. Each
        // row is checked against the store as the rows before it in this
        // page leave it: the timed removal no longer meets the withdrawn
        // bare-day attach, and the re-link at the same instant meets the
        // removal exactly.
        await connection.runTx((tx) async {
          for (final row in [
            deployment(
              'dep-old',
              tagId: 'tag-a',
              individualId: 'ind-marie',
              attached: day(1),
              removed: day(10),
            ),
            deployment(
              'dep-new',
              tagId: 'tag-b',
              individualId: 'ind-marie',
              attached: day(10),
            ),
          ]) {
            await _insertStored(tx, row, at);
          }
        });
        final repair = await push({
          Tables.deployments: [
            {
              ...deployment(
                'dep-new',
                tagId: 'tag-b',
                individualId: 'ind-marie',
                attached: day(10),
                revision: 2,
              ),
              'deleted_at': '2026-08-02T12:00:00.000Z',
              'updated_at': '2026-08-02T12:00:00.000Z',
            },
            deployment(
              'dep-old',
              tagId: 'tag-a',
              individualId: 'ind-marie',
              attached: day(1),
              removed: swapAt(10),
              revision: 2,
            ),
            deployment(
              'dep-new-2',
              tagId: 'tag-b',
              individualId: 'ind-marie',
              attached: swapAt(10),
            ),
          ],
        });
        expect(repair.outcomes[key('dep-new')], SyncRowOutcome.updated);
        expect(repair.outcomes[key('dep-old')], SyncRowOutcome.updated);
        expect(repair.outcomes[key('dep-new-2')], SyncRowOutcome.inserted);
      },
    );
  });
}

Future<void> _insertStored(
  Session tx,
  Map<String, Object?> row,
  String receivedAt,
) => tx.execute(
  'INSERT INTO ${quoted(Tables.deployments)} '
  '(deployment_id, project_id, tag_id, individual_id, '
  'attached_date, removed_date, notes, created_at, updated_at, '
  'revision, last_modified_by, origin_device_id, server_seq, '
  'received_at) '
  r'VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, '
  r'$13, $14)',
  parameters: [
    row['deployment_id'],
    row['project_id'],
    row['tag_id'],
    row['individual_id'],
    row['attached_date'],
    row['removed_date'],
    row['notes'],
    row['created_at'],
    row['updated_at'],
    row['revision'],
    row['last_modified_by'],
    row['origin_device_id'],
    1,
    receivedAt,
  ],
);

Future<void> _seed(Connection connection) async {
  const at = '2026-08-01T12:00:00.000Z';
  await connection.runTx((tx) async {
    await tx.execute(
      'INSERT INTO ${quoted(Tables.users)} '
      '(user_id, first_name, last_name, email, created_at, updated_at, revision) '
      r"VALUES ('user-1', 'Sam', 'Ranger', 'sam@example.com', $1, $1, 0)",
      parameters: [at],
    );
    await tx.execute(
      'INSERT INTO ${quoted(Tables.projects)} '
      '(project_id, project_name, owner_user_id, creation_date, datum, '
      'created_at, updated_at, revision, coordinate_format, '
      'triangulation_window_minutes) '
      r"VALUES ('proj-1', 'Elk', 'user-1', $1, 'WGS84', $1, $1, 0, 'dd', 15)",
      parameters: [at],
    );
    for (final tag in ['tag-a', 'tag-b']) {
      await tx.execute(
        'INSERT INTO ${quoted(Tables.tags)} '
        '(tag_id, project_id, lineage_id, frequency_mhz, tag_name, status, '
        'color_hex, created_at, updated_at, revision, last_modified_by, '
        'origin_device_id) '
        r"VALUES ($1, 'proj-1', $1, 150.1, $1, 'active', '#00FF00', $2, $2, "
        r"1, 'user-1', 'device-A')",
        parameters: [tag, at],
      );
    }
    for (final (id, name) in [('ind-marie', 'Marie'), ('ind-kea', 'Kea')]) {
      await tx.execute(
        'INSERT INTO ${quoted(Tables.individuals)} '
        '(individual_id, project_id, name, color_hex, status, lineage_id, '
        'created_at, updated_at, revision, last_modified_by, '
        'origin_device_id) '
        r"VALUES ($1, 'proj-1', $2, '#FF0000', 'alive', $1, $3, $3, 1, "
        r"'user-1', 'device-A')",
        parameters: [id, name, at],
      );
    }
  });
}
