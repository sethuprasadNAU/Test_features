import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:tritrack_server/tritrack_server.dart';

/// Task 11.129. **The property under test is not "the file is written".** It is
/// that the record can still answer *"was sign-in broken on Tuesday"* after the
/// database that would normally answer it is gone — and that it answers with a
/// count and a date and **nothing that names a person**, because the one place
/// §4.7's retention, purge and never-log machinery cannot reach is a file.
void main() {
  late Directory dir;
  late String path;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('tritrack_degradation');
    path = '${dir.path}/degradation.json';
  });

  tearDown(() => dir.deleteSync(recursive: true));

  Future<DegradationRecord> open({DateTime? startedAt}) async {
    final record = await DegradationRecord.open(
      path,
      onWriteFailure: (type) => fail('unexpected write failure: $type'),
      startedAt: startedAt,
    );
    return record!;
  }

  group('the record exists before anything has failed', () {
    // The distinguishing property. A reader finding no file must be able to
    // conclude "this could not be written", not "nothing has failed" — the
    // check-that-cannot-distinguish-success-from-its-own-failure shape, which
    // is the same family as the defect this task closes.
    test('opening on a healthy start writes the file straight away', () async {
      await open();

      expect(File(path).existsSync(), isTrue);
      final reading = readDegradationRecord(path);
      expect(reading, isA<DegradationRecordRead>());
      expect((reading as DegradationRecordRead).snapshot.auditWritesLost, 0);
    });

    test('a report on a file that was never written says so, and does NOT '
        'say nothing failed', () {
      final text = describeDegradationRecord(
        readDegradationRecord('${dir.path}/never-written.json'),
      );

      expect(text, contains('does NOT mean nothing has failed'));
      expect(text, contains(degradationPathVariable));
    });

    test('open returns null rather than throwing when the path is '
        'unwritable', () async {
      final failures = <String>[];
      // A path *under an existing file*, so the parent directory cannot be
      // created and the write cannot succeed.
      File(path).writeAsStringSync('not a directory');
      final record = await DegradationRecord.open(
        '$path/nested/record.json',
        onWriteFailure: failures.add,
      );

      expect(record, isNull);
      expect(failures, isNotEmpty);
    });
  });

  group('what it records', () {
    test('a loss survives the process that recorded it', () async {
      final record = await open();
      record.auditWriteLost(at: DateTime.utc(2026, 9, 2, 18, 44));
      await record.close();

      final reading = readDegradationRecord(path) as DegradationRecordRead;
      expect(reading.snapshot.auditWritesLost, 1);
      expect(reading.snapshot.firstLossAt, DateTime.utc(2026, 9, 2, 18, 44));
      expect(reading.snapshot.lostByDay, {'2026-09-02': 1});
    });

    test('history accumulates across restarts', () async {
      final first = await open();
      first.auditWriteLost(at: DateTime.utc(2026, 9, 2, 8));
      await first.close();

      final second = await open();
      second.auditWriteLost(at: DateTime.utc(2026, 9, 3, 9));
      second.auditWriteLost(at: DateTime.utc(2026, 9, 3, 10));
      await second.close();

      final snapshot =
          (readDegradationRecord(path) as DegradationRecordRead).snapshot;
      expect(snapshot.auditWritesLost, 3);
      expect(snapshot.firstLossAt, DateTime.utc(2026, 9, 2, 8));
      expect(snapshot.lastLossAt, DateTime.utc(2026, 9, 3, 10));
      expect(snapshot.lostByDay, {'2026-09-02': 1, '2026-09-03': 2});
    });

    // The first loss of a burst is the one that has to be on disk if the
    // process dies a second later, so it is never coalesced.
    test('the first loss is on disk before anything is closed', () async {
      final record = await open();
      record.auditWriteLost(at: DateTime.utc(2026, 9, 2, 18, 44));

      expect(
        (readDegradationRecord(path) as DegradationRecordRead)
            .snapshot
            .auditWritesLost,
        1,
      );
      await record.close();
    });

    test('the file is fixed-size: days age out and the total stays true',
        () async {
      final record = await open();
      for (var day = 1; day <= keptDays + 5; day++) {
        record.auditWriteLost(at: DateTime.utc(2026, 1, 1).add(Duration(days: day)));
      }
      await record.close();

      final snapshot =
          (readDegradationRecord(path) as DegradationRecordRead).snapshot;
      expect(snapshot.lostByDay.length, keptDays);
      expect(snapshot.lostBeforeKeptDays, 5);
      expect(
        snapshot.auditWritesLost,
        keptDays + 5,
        reason: 'the total must reconcile with the per-day counts plus the '
            'ones that aged out, or a reader sees two numbers that disagree',
      );
    });
  });

  group('it names nobody, and that is the decision this task made', () {
    // **The load-bearing test.** §4.7's retention window, the audit-retention
    // sweep and the never-log list are all properties of `auth_audit_log` and
    // reach nothing on a filesystem. An address written here would have no
    // window, nothing sweeping it, and would outlive the account it names. So
    // the shape of the file is what enforces the decision, exactly as
    // `auth_audit_log` has no token column — and this asserts the shape rather
    // than trusting a comment.
    test('every key the file can hold is non-identifying', () async {
      final record = await open();
      record.auditWriteLost(at: DateTime.utc(2026, 9, 2));
      await record.close();

      final decoded =
          jsonDecode(File(path).readAsStringSync()) as Map<String, Object?>;

      expect(decoded.keys.toSet(), {
        'schema',
        'audit_writes_lost',
        'first_loss_at',
        'last_loss_at',
        'lost_by_day',
        'lost_before_kept_days',
        'last_started_at',
      }, reason:
          'a new key here is a decision to put something outside §4.7\'s '
          'reach; adding one must be deliberate enough to fail this test '
          'first');
    });

    test('the API offers nowhere to put an identity', () async {
      final record = await open();
      // `auditWriteLost` takes a timestamp and nothing else. If this stops
      // compiling because somebody added an `email:` or `userId:` parameter,
      // that is the change this test exists to stop being silent.
      record.auditWriteLost(at: DateTime.utc(2026, 9, 2));
      await record.close();

      expect(File(path).readAsStringSync(), isNot(contains('@')));
    });
  });

  group('what a reader is told', () {
    test('an unreadable file reports history lost, never zero losses', () {
      File(path).writeAsStringSync('{"schema": 999}');

      final reading = readDegradationRecord(path);
      expect(reading, isA<DegradationRecordUnreadable>());
      expect(
        describeDegradationRecord(reading),
        contains('Treat the history as lost, not as empty'),
      );
    });

    test('a report with losses says what happened to a person, not only a '
        'count', () async {
      final record = await open();
      record.auditWriteLost(at: DateTime.utc(2026, 9, 2, 18, 44));
      await record.close();

      final text = describeDegradationRecord(readDegradationRecord(path));
      expect(text, contains('no link was sent'));
      expect(text, contains('not of people'));
      expect(text, contains('2026-09-02  1'));
    });

    // The honest-default rule, applied to a clean record: "no losses" is a
    // fact about audit writes reaching the database, and it is not evidence
    // that anybody could sign in. A report that quietly implied the second
    // would be a confident sentence covering a guess.
    test('a clean report does not claim sign-in has always worked', () async {
      await (await open()).close();

      expect(
        describeDegradationRecord(readDegradationRecord(path)),
        contains('it means every audit write this server attempted reached '
            'the database'),
      );
    });
  });

  group('the sentence the healthcheck appends', () {
    test('is present inside the recent window', () async {
      final record = await open();
      final now = DateTime.utc(2026, 9, 2, 18);
      record.auditWriteLost(at: now.subtract(const Duration(hours: 2)));
      await record.close();

      expect(
        recentDegradationSentence(readDegradationRecord(path), now: now),
        allOf(contains('audit log lost 1'), contains('--degradation-report')),
      );
    });

    test('stops nagging once the window has passed', () async {
      final record = await open();
      final now = DateTime.utc(2026, 9, 2, 18);
      record.auditWriteLost(at: now.subtract(recentWindow * 2));
      await record.close();

      expect(
        recentDegradationSentence(readDegradationRecord(path), now: now),
        isNull,
      );
    });

    test('says nothing at all when nothing has been lost', () async {
      await (await open()).close();

      expect(recentDegradationSentence(readDegradationRecord(path)), isNull);
    });
  });
}
