@Tags(['postgres'])
library;

import 'package:postgres/postgres.dart';
import 'package:test/test.dart';
import 'package:tritrack_server/tritrack_server.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

import '../support/database_test_config.dart';

/// **Task 11.72 — the refusal that says the same words and takes a different
/// time** (Security Model §4.13, §20.6; trust-boundary inventory entry 28).
///
/// ## What went wrong, and why four security gates did not see it
///
/// §4.13 requires that "wrong project, wrong user, and nonexistent are
/// indistinguishable from outside." Task 10.21 made the *status code and body*
/// identical and task 11.60 made the *query count* identical. Neither made the
/// *work* identical, and a clean Linux runner can see the difference:
/// `scripts/verify_11_49_server_reads.py` probe 7 measured the refusal for a
/// project that really exists running **about 54 microseconds slower** than the
/// refusal for a fabricated id — sign positive in 9 of 9 trials on each of
/// three separate runs, while its own null pair of two fabricated ids flipped
/// sign every run. A developer's Mac cannot resolve 54 microseconds over HTTP;
/// the beta server is a Linux machine.
///
/// ## Why this file exists rather than only the HTTP probe
///
/// **The probe is roughly a hundred times less sensitive than it needs to be,
/// because it measures through a socket.** Its own comment records
/// per-request spread of 8–24 ms, so it can only see effects that survive
/// that; the difference it found was one twentieth of a millisecond and it
/// took 900 requests per trial to see it at all.
///
/// This measures [ProjectAuthorizer.resolve] directly, against a real
/// Postgres. That removes HTTP, the router, session validation and the audit
/// writes from the measurement, and with them almost all of the noise: on a
/// developer's Mac this resolves single-digit-microsecond differences that
/// the HTTP probe cannot see at all. It is the right instrument for a
/// property about *how much work a branch does*.
///
/// ## What is actually asserted, and the control that makes it evidence
///
/// A check that measures timing can fail for the machine rather than for the
/// code, so this borrows the probe's design and adds one thing:
///
/// - **A null pair** — two ids that both name nothing, whose true difference
///   is exactly zero. It is not a pass/fail gate: it is **the run's own
///   resolution floor**, and on a GitHub runner it came out unanimous at 4.1
///   microseconds, because two fabricated ids land on different pages of the
///   same index and no amount of rotation removes that. What it earns is the
///   right to say "this run cannot attribute anything smaller than about five
///   microseconds," which is the honest version of the claim.
/// - **A positive control, which the HTTP probe has no equivalent of.** The
///   *old* whole-table formulation is measured in the same run, on the same
///   host, in the same interleaved pass. It has a known, real difference, so
///   its sign must come out unanimous. If it does not, this host cannot
///   resolve the effect being looked for and **the test fails rather than
///   passes** — because "all quiet" and "deaf" must not look the same from
///   here. That is task 11.71's finding, applied before it could recur.
///
/// **Watched to fail, and watched again after the assertions were rewritten.**
/// Pointed at the pre-11.72 whole-table formulation this file goes red on both
/// property pairs — most recently **+210.0 microseconds on the existence pair
/// and +199.0 on the membership-count pair, both 9/9**, against a bound of 28
/// derived from that run's own floor of 7. So it has been seen to distinguish
/// the defect from its absence, which is the only thing that makes a green run
/// from it mean anything (task 10.66's standing criterion). **The re-watch
/// matters as much as the first one**: the assertions changed after the first,
/// and a "watched to fail" note that describes an earlier version of a check is
/// the same defect as a comment describing a mechanism the code does not have.
///
/// ## And the leak was never one bit
///
/// The measurement that closed this found the cost **rising with the number of
/// membership rows on the project**: roughly +7 microseconds at one member,
/// +17 at three, +71 at twenty, sign unanimous at the last two. So a caller
/// with no access to a project could read off not just "this id is real" but a
/// monotone function of *how many people are on it*. Equalising only the
/// absent-versus-forbidden pair would have turned the HTTP probe green and
/// left that untouched — the instance rather than the class (task 10.66). Both
/// pairs are measured below.
void main() {
  late Connection connection;
  const schema = 'tritrack_authorization_timing_test';
  const at = '2026-08-01T00:00:00.000Z';

  String id(int n) =>
      '00000000-0000-4000-8000-${n.toRadixString(16).padLeft(12, '0')}';

  Future<void> insertUser(String userId, String label) => connection.execute(
    'INSERT INTO ${quoted(Tables.users)} '
    '(user_id, first_name, last_name, email, created_at, updated_at, '
    'revision, last_modified_by) '
    r'VALUES ($1, $2, $2, $3, $4, $4, 1, $1)',
    parameters: [userId, label, '$label@example.org', at],
  );

  Future<void> insertProject(String projectId, String creatorUserId) =>
      connection.execute(
        'INSERT INTO ${quoted(Tables.projects)} '
        '(project_id, project_name, owner_user_id, creation_date, datum, '
        'coordinate_format, triangulation_window_minutes, '
        'created_at, updated_at, revision, last_modified_by) '
        r"VALUES ($1, $2, $3, $4, 'WGS84', 'dd', 30, $4, $4, 1, $3)",
        parameters: [projectId, 'project ${projectId.substring(24)}',
          creatorUserId, at],
      );

  Future<void> insertMembership(
    String membershipId,
    String projectId,
    String userId,
    String role, {
    String? endDate,
    String? deletedAt,
  }) => connection.execute(
    'INSERT INTO ${quoted(Tables.projectMemberships)} '
    '(membership_id, project_id, user_id, role, join_date, end_date, '
    'created_at, updated_at, deleted_at, revision, last_modified_by) '
    r'VALUES ($1, $2, $3, $4, $5, $6, $5, $5, $7, 1, $3)',
    parameters: [membershipId, projectId, userId, role, at, endDate, deletedAt],
  );

  setUpAll(() async {
    if (testDatabaseConfig == null) return;
    connection = await Connection.open(
      testDatabaseConfig!.endpoint,
      settings: const ConnectionSettings(sslMode: SslMode.disable),
    );
    await connection.execute('DROP SCHEMA IF EXISTS $schema CASCADE');
    await connection.execute('CREATE SCHEMA $schema');
    await connection.execute('SET search_path TO $schema');
    await PostgresMigrations.run(connection);
  });

  tearDownAll(() async {
    if (testDatabaseConfig == null) return;
    await connection.execute('DROP SCHEMA IF EXISTS $schema CASCADE');
    await connection.close();
  });

  // ======================================================== equivalence ===
  // Narrowing the read is only safe if it returns the same answer. This is
  // the argument in [ProjectAuthorizer]'s comment, checked instead of
  // asserted: the old whole-table formulation is written out here as the
  // reference, and the two must agree on every shape of membership the
  // gradient can be in.
  group('the narrowed read answers exactly what reading the whole table did',
      () {
    /// `ProjectAuthorizer.resolve` as it stood before task 11.72: both
    /// statements unconditional, but the second one returning **every**
    /// membership row of the project.
    Future<ProjectAccess> readingTheWholeTable(
      Session session, {
      required String projectId,
      required String userId,
    }) async {
      final project = await session.execute(
        'SELECT owner_user_id FROM ${quoted(Tables.projects)} '
        r'WHERE project_id = $1',
        parameters: [projectId],
      );
      final memberships = await session.execute(
        'SELECT user_id, role, end_date, deleted_at '
        'FROM ${quoted(Tables.projectMemberships)} '
        r'WHERE project_id = $1',
        parameters: [projectId],
      );
      if (project.isEmpty) return ProjectAccess.absent;
      final role = resolveProjectRole(
        membershipRows: memberships.map((row) => row.toColumnMap()).toList(),
        creatorUserId: project.first.first as String?,
        userId: userId,
      );
      return switch (role) {
        ProjectRole.owner => ProjectAccess.owner,
        ProjectRole.contributor => ProjectAccess.contributor,
        ProjectRole.viewer => ProjectAccess.viewer,
        null => ProjectAccess.none,
      };
    }

    // The caller under test, and a second person whose rows exist only to be
    // ignored — the whole point of narrowing is that they no longer travel.
    final caller = id(1);
    final other = id(2);
    var nextProject = 100;
    var nextMembership = 10000;

    /// One project shaped by [rows], each `(userId, role, endDate, deletedAt)`.
    Future<String> project({
      required String creator,
      required List<(String, String, String?, String?)> rows,
    }) async {
      final projectId = id(nextProject++);
      await insertProject(projectId, creator);
      for (final (userId, role, endDate, deletedAt) in rows) {
        await insertMembership(id(nextMembership++), projectId, userId, role,
            endDate: endDate, deletedAt: deletedAt);
      }
      return projectId;
    }

    setUpAll(() async {
      if (testDatabaseConfig == null) return;
      await insertUser(caller, 'caller');
      await insertUser(other, 'other');
    });

    /// Every shape the two formulations could disagree about. The three that
    /// matter most are the last three: they are the cases where the caller's
    /// own rows alone are **not** the whole answer, because the creator
    /// fallback depends on whether anybody else holds an open owner row.
    final cases = <String, Future<String> Function()>{
      'the caller is an open owner':
          () => project(creator: other, rows: [(caller, 'owner', null, null)]),
      'the caller is a contributor':
          () => project(creator: other, rows: [
                (other, 'owner', null, null),
                (caller, 'contributor', null, null),
              ]),
      'the caller is a viewer':
          () => project(creator: other, rows: [
                (other, 'owner', null, null),
                (caller, 'viewer', null, null),
              ]),
      "the caller's stint has ended":
          () => project(creator: other, rows: [
                (other, 'owner', null, null),
                (caller, 'contributor', at, null),
              ]),
      "the caller's membership is tombstoned":
          () => project(creator: other, rows: [
                (other, 'owner', null, null),
                (caller, 'contributor', null, at),
              ]),
      'the caller holds a role this build cannot interpret':
          () => project(creator: other, rows: [
                (other, 'owner', null, null),
                (caller, 'archivist', null, null),
              ]),
      'the caller was never on it':
          () => project(creator: other,
              rows: [(other, 'owner', null, null)]),
      'the caller holds both an ended and an open row':
          () => project(creator: other, rows: [
                (other, 'owner', null, null),
                (caller, 'contributor', at, null),
                (caller, 'viewer', null, null),
              ]),
      // --- the creator-fallback cases -------------------------------------
      'the caller created it and the membership table names no owner at all':
          () => project(creator: caller, rows: const []),
      'the caller created it, and somebody else now holds the open owner row':
          () => project(creator: caller, rows: [
                (other, 'owner', null, null),
              ]),
      'the caller created it and their own owner row has been ended':
          () => project(creator: caller, rows: [
                (caller, 'owner', at, null),
                (other, 'owner', null, null),
              ]),
      'the caller created it, every owner row is ended, and the fallback is '
          'therefore live': () => project(creator: caller, rows: [
                (caller, 'owner', at, null),
                (other, 'owner', at, null),
              ]),
      'somebody else created it, every owner row is ended, and the fallback '
          'names them': () => project(creator: other, rows: [
                (other, 'owner', at, null),
                (caller, 'contributor', at, null),
              ]),
    };

    cases.forEach((description, build) {
      test(description, () async {
        final projectId = await build();
        expect(
          await ProjectAuthorizer.resolve(connection,
              projectId: projectId, userId: caller),
          await readingTheWholeTable(connection,
              projectId: projectId, userId: caller),
          reason: 'the narrowed read disagrees with reading the whole table',
        );
      });
    });

    test('a project id that names nothing', () async {
      expect(
        await ProjectAuthorizer.resolve(connection,
            projectId: id(999999), userId: caller),
        ProjectAccess.absent,
      );
      expect(
        await readingTheWholeTable(connection,
            projectId: id(999999), userId: caller),
        ProjectAccess.absent,
      );
    });
  }, skip: databaseSkipReason);

  // ============================================================= timing ===
  group('a refusal takes the same time whatever the project is', () {
    // The prober: signed in, on none of these projects.
    final prober = id(500);
    final owner = id(501);
    final absentA = id(800001);
    final absentB = id(800002);
    final small = id(600);
    final big = id(601);
    const bigMembers = 50;

    setUpAll(() async {
      if (testDatabaseConfig == null) return;
      await insertUser(prober, 'prober');
      await insertUser(owner, 'owner');
      for (var i = 0; i < bigMembers; i++) {
        await insertUser(id(700 + i), 'member$i');
      }
      await insertProject(small, owner);
      await insertMembership(id(20000), small, owner, 'owner');
      await insertProject(big, owner);
      for (var i = 0; i < bigMembers; i++) {
        await insertMembership(id(21000 + i), big, id(700 + i),
            i == 0 ? 'owner' : 'contributor');
      }
      // The planner should be choosing index scans on real statistics, not on
      // an empty table's defaults — otherwise this measures the planner.
      await connection.execute('ANALYZE');
    });

    /// The old formulation, kept alive **only** as this instrument's positive
    /// control: it has a difference that is known to be real, so if its sign
    /// does not come out unanimous, this host cannot resolve the effect and
    /// nothing else measured here is evidence.
    Future<void> wholeTableRead(String projectId) async {
      await connection.execute(
        'SELECT owner_user_id FROM ${quoted(Tables.projects)} '
        r'WHERE project_id = $1',
        parameters: [projectId],
      );
      await connection.execute(
        'SELECT user_id, role, end_date, deleted_at '
        'FROM ${quoted(Tables.projectMemberships)} '
        r'WHERE project_id = $1',
        parameters: [projectId],
      );
    }

    Future<void> narrowedRead(String projectId) =>
        ProjectAuthorizer.resolve(connection,
            projectId: projectId, userId: prober);

    // Nine trials of a hundred rounds, the four ids **rotated within each
    // round** so none is systematically last, and the median taken per trial.
    // A real difference is slower in nearly every trial; drift is slower in
    // about half. That is the same design as the HTTP probe, and it is what
    // makes the sign — not the magnitude — the thing asserted on.
    // Two hundred rounds rather than one hundred, decided by measurement:
    // at a hundred, a per-trial median on a developer's Mac still moved by
    // about 14 microseconds run to run, which is most of the way to the bound
    // below. Median noise falls as the square root of the sample count, so
    // this buys about a third of it back and costs about twenty seconds.
    const trials = 9, rounds = 200;

    Future<Map<String, List<double>>> measure(
      Future<void> Function(String) unit,
    ) async {
      final ids = [absentA, absentB, small, big];
      for (var warm = 0; warm < 200; warm++) {
        for (final projectId in ids) {
          await unit(projectId);
        }
      }
      final medians = {for (final projectId in ids) projectId: <double>[]};
      for (var trial = 0; trial < trials; trial++) {
        final samples = {for (final projectId in ids) projectId: <double>[]};
        for (var round = 0; round < rounds; round++) {
          final rotation = round % ids.length;
          for (final projectId in [
            ...ids.sublist(rotation),
            ...ids.sublist(0, rotation),
          ]) {
            final stopwatch = Stopwatch()..start();
            await unit(projectId);
            stopwatch.stop();
            samples[projectId]!.add(stopwatch.elapsedMicroseconds.toDouble());
          }
        }
        for (final projectId in ids) {
          final sorted = [...samples[projectId]!]..sort();
          medians[projectId]!.add(sorted[sorted.length ~/ 2]);
        }
      }
      return medians;
    }

    /// `(typical difference in microseconds, trials in which it was positive)`.
    ///
    /// The **median** of the nine per-trial differences rather than their mean:
    /// one trial that lands during a garbage collection or a noisy neighbour
    /// moves a mean by more than the whole effect being bounded, and this
    /// number is compared against a bound.
    (double, int) delta(
      Map<String, List<double>> medians,
      String slower,
      String faster,
    ) {
      final differences = [
        for (var i = 0; i < trials; i++)
          medians[slower]![i] - medians[faster]![i],
      ];
      final sorted = [...differences]..sort();
      return (
        sorted[sorted.length ~/ 2],
        differences.where((d) => d > 0).length,
      );
    }

    String say(String what, (double, int) d) =>
        '$what ${d.$1 >= 0 ? '+' : ''}${d.$1.toStringAsFixed(1)}us, '
        'sign positive in ${d.$2}/$trials trials';

    test('measured directly, and with a control that proves it can still see '
        'a difference', () async {
      final old = await measure(wholeTableRead);
      final now = await measure(narrowedRead);

      final control = delta(old, big, absentA);
      final oldNull = delta(old, absentB, absentA);
      final existence = delta(now, big, absentA);
      final gradient = delta(now, big, small);
      final newNull = delta(now, absentB, absentA);

      // **The instrument's last words are a finding, not a name** — CI keeps
      // only the tail of a log, and twice in two days the fact that was
      // missing was one an instrument already had (`CLAUDE.md`, task 11.69).
      final report = [
        'measured $trials trials x $rounds rotated rounds, four project ids, '
            'against a real Postgres',
        'positive control, the pre-11.72 whole-table read: '
            '${say('$bigMembers-member project minus a fictional id', control)}'
            ' — this is the difference that must still be visible',
        'control null pair (two fictional ids, true difference zero): '
            '${say('', oldNull)}',
        'PROPERTY existence: '
            '${say('real project minus fictional id', existence)}',
        'PROPERTY membership count: '
            '${say('$bigMembers-member minus 1-member project', gradient)}',
        'null pair on the same measurement: ${say('', newNull)}',
      ].join('\n  ');
      // Printed on every run, not only a failing one: a green line reading
      // "the refusal takes the same time" tells nobody *how much* the same,
      // and the number is what a future change gets compared against.
      print('  $report');

      // **The bound, and where its number comes from.** This is the part
      // that must not be a threshold picked to make a run quiet.
      //
      // The first version of this test asserted that neither property pair
      // has a stable sign, and required the null pair's sign to flip. On a
      // GitHub runner the null pair came out **unanimous at 4.1
      // microseconds** — two ids that both name nothing, one consistently
      // faster than the other. That is real and it is not the code: two
      // fabricated ids land on different pages of the same index, and the
      // machine has a per-id offset of a few microseconds that no amount of
      // rotation removes. **So a sign test alone cannot say anything below
      // about five microseconds on that host**, and neither can the property
      // assertions.
      //
      // What the run can therefore say honestly:
      //
      // - the **positive control** fixes the ceiling — the old formulation's
      //   difference is unmissable, so the instrument is not deaf;
      // - the **null pair's magnitude** fixes the floor — it is the smallest
      //   difference this host can attribute to anything at all;
      // - and each property pair must sit **under a bound derived from that
      //   floor**, rather than be required to vanish, which is a thing no
      //   measurement can show.
      //
      // **Twenty-five microseconds, or four times the floor if the floor is
      // larger.** Both halves of that are chosen against measurements rather
      // than against a run that would not go quiet:
      //
      // - **Above** the largest honest residual either machine has produced
      //   (5.0 µs on a GitHub runner, 9.3 µs on a developer's Mac) and above
      //   the run-to-run wobble of the statistic itself (about 9 µs on the Mac
      //   at $rounds rounds), so a clean tree does not go red for the weather.
      // - **Far below what it must catch.** The membership pair compares a
      //   $bigMembers-member project against a 1-member one, so *any*
      //   reintroduction of a read whose size follows the project shows up
      //   there at its full size — about 200 µs, an eightfold margin — whether
      //   the offending project has five members or five hundred.
      //
      // The gap between 25 µs and 200 µs is what this instrument cannot
      // resolve, and saying so is the point of printing the floor.
      final floor = newNull.$1.abs() > oldNull.$1.abs()
          ? newNull.$1.abs()
          : oldNull.$1.abs();
      final bound = floor * 4 > 25.0 ? floor * 4 : 25.0;

      // 1. Can this host see the effect at all? If the known-real difference
      //    does not come out unanimous, this run has measured nothing and
      //    must not be read as "all quiet."
      expect(
        control.$2,
        anyOf(trials, 0),
        reason:
            'This host cannot resolve the difference this test exists to look '
            'for, so its other assertions are not evidence. The pre-11.72 '
            'whole-table read has a real, known cost difference between a '
            '$bigMembers-member project and an id that names nothing, and its '
            'sign came out ${control.$2}/$trials rather than unanimous.\n  '
            '$report',
      );

      // 2. ...and is the floor small enough for the bound to mean anything?
      //    If the machine's own per-id offset were as large as the difference
      //    being bounded, the bound would be measuring the machine.
      expect(
        floor,
        lessThan(bound / 2),
        reason:
            'The null pair — two ids that both name nothing, whose true '
            'difference is exactly zero — differs by '
            '${floor.toStringAsFixed(1)}us on this host, which is too close '
            'to the ${bound.toStringAsFixed(1)}us bound below for that bound '
            'to be evidence about the code.\n  $report',
      );

      // 3. The property, on both pairs. §4.13: a caller who is refused must
      //    not be able to tell a real project from a fabricated one — and
      //    task 11.72 adds: nor one real project from another by its size.
      //
      //    **The existence pair carries an accepted residual and the
      //    membership pair does not.** An index probe that finds a row does a
      //    heap fetch and one that finds nothing does not, and no shaping of
      //    the read removes that; it is written up and accepted in Security
      //    Model §4.13. What is not accepted is its *growth*, which is what
      //    this bound is.
      expect(
        existence.$1.abs(),
        lessThan(bound),
        reason:
            'The refusal for a real project now differs from the refusal for '
            'a fabricated id by more than the accepted residual. §4.13 '
            'accepts a few microseconds — one index probe that finds a row '
            'against one that does not — and nothing larger. Something on '
            'this path has started doing work that depends on what the server '
            'holds.\n  $report',
      );
      expect(
        gradient.$1.abs(),
        lessThan(bound),
        reason:
            'A caller with no access can tell a $bigMembers-member project '
            'from a 1-member one by how long the refusal takes, which reads '
            'off how many people are on a project they cannot see. This is '
            'the finding task 11.72 closed, and closing it is the reason '
            'neither statement on this path may read rows whose number '
            'depends on the project.\n  $report',
      );

    }, timeout: const Timeout(Duration(minutes: 10)));
  }, skip: databaseSkipReason);
}
