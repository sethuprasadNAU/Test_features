import 'package:test/test.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

/// Task 11.243 — Michael's interlock, as the shared rule both sides call;
/// the one-day tolerance withdrawn by task 11.263 (design §6a).
///
/// **Every date here is a local `DateTime`**, the way `deploymentDateFor`
/// writes a bare day — local midnight is a day only in the zone that wrote
/// it, so `DateTime.utc(2026, 3, 10)` would read as 17:00 the evening before
/// on the machine in Arizona this suite mostly runs on, and every "bare day"
/// fixture would silently be a timed one.
///
/// The two counter-intuitive cases have tests of their own and say in their
/// names that they are deliberate, because both look like defects: a null
/// attached date conflicts with nothing, and a tombstoned deployment
/// constrains nothing.
void main() {
  /// A bare day — local midnight, which is what the app writes for a date.
  DateTime d(int day) => DateTime(2026, 3, day);

  /// A timed value on [day] — what a swap confirmed at 14:32 writes.
  DateTime t(int day, [int hour = 14, int minute = 32]) =>
      DateTime(2026, 3, day, hour, minute);

  DeploymentInterval interval({
    String id = 'd1',
    String tag = 'tagA',
    String animal = 'marie',
    DateTime? attached,
    DateTime? removed,
    bool deleted = false,
  }) => DeploymentInterval(
    deploymentId: id,
    tagId: tag,
    individualId: animal,
    attachedDate: attached,
    removedDate: removed,
    deleted: deleted,
  );

  group('the change task 11.263 made — watched red against the old body', () {
    test(
      'THE CASE THAT USED TO PASS: a same-day handover with two bare days is '
      'refused, because both rows cover the whole of that day',
      () {
        // Removed the 10th, attached the 10th, neither with a time. Under
        // the one-day tolerance this was "two intervals touching at
        // midnight" and went through; a bearing at 2 p.m. on the 10th was
        // then inside both rows with nothing to say which animal it was
        // about. Michael, 2026-09-16: "can't have more than one tag with
        // removal times that overlap or the same."
        final conflict = DeploymentInterlock.conflictFor(
          interval(id: 'new', tag: 'tagB', attached: d(10)),
          [interval(id: 'old', tag: 'tagA', attached: d(1), removed: d(10))],
        );
        expect(conflict, isNotNull);
        expect(conflict!.subject, DeploymentConflictSubject.animal);
        expect(conflict.other.deploymentId, 'old');
      },
    );

    test(
      'THE CASE THAT MUST STILL PASS: a timed handover at the same instant '
      'overlaps by nothing',
      () {
        // The old collar ends at 14:32 and the new one starts at 14:32 —
        // what the §5a confirmation writes since task 11.251. An instant has
        // no width to share; each bearing that day is inside exactly one.
        expect(
          DeploymentInterlock.conflictFor(
            interval(id: 'new', tag: 'tagB', attached: t(10)),
            [interval(id: 'old', tag: 'tagA', attached: d(1), removed: t(10))],
          ),
          isNull,
        );
      },
    );
  });

  group('overlaps — some moment inside both, read as coversMoment reads it', () {
    test('a bare day ending where the next bare day begins does not overlap', () {
      // Removed the 9th, attached the 10th: the 9th covers itself and stops
      // where the 10th starts. This is the handover recorded a day apart.
      expect(
        DeploymentInterlock.overlaps(
          interval(attached: d(1), removed: d(9)),
          interval(id: 'd2', attached: d(10)),
        ),
        isFalse,
      );
    });

    test('a bare day and a same-day bare day overlap — the whole day', () {
      expect(
        DeploymentInterlock.overlaps(
          interval(attached: d(1), removed: d(10)),
          interval(id: 'd2', attached: d(10)),
        ),
        isTrue,
      );
    });

    test('a timed end and a timed start at the same instant do not overlap', () {
      expect(
        DeploymentInterlock.overlaps(
          interval(attached: d(1), removed: t(10)),
          interval(id: 'd2', attached: t(10)),
        ),
        isFalse,
      );
    });

    test('a timed end after a timed start, by one minute, overlaps', () {
      expect(
        DeploymentInterlock.overlaps(
          interval(attached: d(1), removed: t(10, 14, 33)),
          interval(id: 'd2', attached: t(10, 14, 32)),
        ),
        isTrue,
      );
    });

    test('a bare-day end and a timed start on that day overlap', () {
      // Removed "the 10th" covers 2 p.m. on the 10th; a collar attached at
      // 14:32 that day covers it too. This is the mixed pair task 11.263's
      // "Day only" narrowing exists to keep from being written.
      expect(
        DeploymentInterlock.overlaps(
          interval(attached: d(1), removed: d(10)),
          interval(id: 'd2', attached: t(10)),
        ),
        isTrue,
      );
    });

    test('a timed end and a bare-day start on that day overlap', () {
      // The morning of the 10th is inside the bare-day start (from midnight)
      // and before the 14:32 end.
      expect(
        DeploymentInterlock.overlaps(
          interval(attached: d(1), removed: t(10)),
          interval(id: 'd2', attached: d(10)),
        ),
        isTrue,
      );
    });

    test('a timed end and a bare-day start the NEXT day do not overlap', () {
      expect(
        DeploymentInterlock.overlaps(
          interval(attached: d(1), removed: t(10)),
          interval(id: 'd2', attached: d(11)),
        ),
        isFalse,
      );
    });

    test('two deployments that are both still on overlap', () {
      // The case the rule is most obviously for. A reading that treated "no
      // end" as "no overlap" would permit exactly what Michael described.
      expect(
        DeploymentInterlock.overlaps(
          interval(attached: d(1)),
          interval(id: 'd2', attached: d(5)),
        ),
        isTrue,
      );
    });

    test('one still on, one ended before it started, do not overlap', () {
      expect(
        DeploymentInterlock.overlaps(
          interval(attached: d(1), removed: d(5)),
          interval(id: 'd2', attached: d(10)),
        ),
        isFalse,
      );
    });

    test('disjoint closed intervals do not overlap', () {
      expect(
        DeploymentInterlock.overlaps(
          interval(attached: d(1), removed: d(5)),
          interval(id: 'd2', attached: d(10), removed: d(20)),
        ),
        isFalse,
      );
    });

    test('a nested interval overlaps', () {
      expect(
        DeploymentInterlock.overlaps(
          interval(attached: d(1), removed: d(20)),
          interval(id: 'd2', attached: d(5), removed: d(10)),
        ),
        isTrue,
      );
    });

    test('an interval with no attached date overlaps nothing', () {
      expect(
        DeploymentInterlock.overlaps(
          interval(removed: d(20)),
          interval(id: 'd2', attached: d(5), removed: d(10)),
        ),
        isFalse,
      );
    });
  });

  group('zonelessEndsAreInstants — the server\'s flag (task 11.266)', () {
    test(
      'without the flag, a same-zone bare day is widened and a still-open '
      'deployment starting on it reads as overlapping — this is the bug: '
      'a swap picked at exactly this process\'s own midnight is '
      'indistinguishable from a bare day and gets the wrong answer',
      () {
        expect(
          DeploymentInterlock.overlaps(
            interval(attached: d(1), removed: d(10)),
            interval(id: 'd2', attached: d(10)),
          ),
          isTrue,
        );
      },
    );

    test(
      'with the flag, the same pair does not overlap — every end is the '
      'instant it holds, never widened to the whole of its day',
      () {
        expect(
          DeploymentInterlock.overlaps(
            interval(attached: d(1), removed: d(10)),
            interval(id: 'd2', attached: d(10)),
            zonelessEndsAreInstants: true,
          ),
          isFalse,
        );
      },
    );

    test(
      'the flag changes nothing for an end that already carries a time',
      () {
        expect(
          DeploymentInterlock.overlaps(
            interval(attached: d(1), removed: t(10, 14, 33)),
            interval(id: 'd2', attached: t(10, 14, 32)),
            zonelessEndsAreInstants: true,
          ),
          isTrue,
        );
        expect(
          DeploymentInterlock.overlaps(
            interval(attached: d(1), removed: t(10)),
            interval(id: 'd2', attached: t(10)),
            zonelessEndsAreInstants: true,
          ),
          isFalse,
        );
      },
    );

    test('conflictFor threads the flag through to overlaps', () {
      expect(
        DeploymentInterlock.conflictFor(
          interval(id: 'new', tag: 'tagB', attached: d(10)),
          [interval(id: 'old', tag: 'tagA', attached: d(1), removed: d(10))],
          zonelessEndsAreInstants: true,
        ),
        isNull,
      );
    });
  });

  group('coverageEnd — the boundary coversMoment implies', () {
    test('still on has no end', () {
      expect(DeploymentInterlock.coverageEnd(interval(attached: d(1))), isNull);
    });

    test('a timed end is that instant', () {
      expect(
        DeploymentInterlock.coverageEnd(interval(attached: d(1), removed: t(10))),
        t(10),
      );
    });

    test('a bare day ends where the next local day begins', () {
      expect(
        DeploymentInterlock.coverageEnd(interval(attached: d(1), removed: d(10))),
        d(11),
      );
    });

    test('a bare day at the end of a month ends on the first of the next', () {
      expect(
        DeploymentInterlock.coverageEnd(
          interval(attached: d(1), removed: DateTime(2026, 3, 31)),
        ),
        DateTime(2026, 4, 1),
      );
    });

    test(
      'with zonelessEndsAreInstants, a bare day is not widened at all — it '
      'is the instant it holds',
      () {
        expect(
          DeploymentInterlock.coverageEnd(
            interval(attached: d(1), removed: d(10)),
            zonelessEndsAreInstants: true,
          ),
          d(10),
        );
      },
    );
  });

  group('conflictFor', () {
    test('one animal cannot wear two collars at once', () {
      final conflict = DeploymentInterlock.conflictFor(
        interval(id: 'new', tag: 'tagB', attached: d(1)),
        [interval(id: 'old', tag: 'tagA', attached: d(1))],
      );
      expect(conflict, isNotNull);
      expect(conflict!.subject, DeploymentConflictSubject.animal);
      expect(conflict.other.deploymentId, 'old');
    });

    test('one collar cannot be on two animals at once', () {
      final conflict = DeploymentInterlock.conflictFor(
        interval(id: 'new', animal: 'kea', attached: d(1), removed: d(20)),
        [interval(id: 'old', animal: 'marie', attached: d(1), removed: d(20))],
      );
      expect(conflict, isNotNull);
      expect(conflict!.subject, DeploymentConflictSubject.tag);
    });

    test('a handover recorded a day apart is permitted', () {
      expect(
        DeploymentInterlock.conflictFor(
          interval(id: 'new', tag: 'tagB', attached: d(11)),
          [interval(id: 'old', tag: 'tagA', attached: d(1), removed: d(10))],
        ),
        isNull,
      );
    });

    test('an overlap of exactly one bare day is refused — the withdrawn '
        'tolerance', () {
      // Attached the 9th, the other removed the 10th: the 9th and the 10th
      // are inside both. Permitted until task 11.263; refused since.
      expect(
        DeploymentInterlock.conflictFor(
          interval(id: 'new', tag: 'tagB', attached: d(9)),
          [interval(id: 'old', tag: 'tagA', attached: d(1), removed: d(10))],
        ),
        isNotNull,
      );
    });

    test('an overlap of two days is refused', () {
      expect(
        DeploymentInterlock.conflictFor(
          interval(id: 'new', tag: 'tagB', attached: d(8)),
          [interval(id: 'old', tag: 'tagA', attached: d(1), removed: d(10))],
        ),
        isNotNull,
      );
    });

    test('two deployments sharing neither end never conflict', () {
      expect(
        DeploymentInterlock.conflictFor(
          interval(id: 'new', tag: 'tagB', animal: 'kea', attached: d(1)),
          [interval(id: 'old', tag: 'tagA', animal: 'marie', attached: d(1))],
        ),
        isNull,
      );
    });

    test('a row does not conflict with its own stored self', () {
      // Editing a deployment re-checks it against the project, and the
      // project still contains the version being replaced.
      expect(
        DeploymentInterlock.conflictFor(
          interval(id: 'd1', attached: d(1), removed: d(30)),
          [interval(id: 'd1', attached: d(1))],
        ),
        isNull,
      );
    });

    test(
      'DELIBERATE: a deployment with no attached date conflicts with nothing',
      () {
        // Design §4, and Michael named it as the thing that will look like a
        // bug the first time he meets it. A deployment with no attached date
        // covers no interval, so there is nothing for it to overlap — in
        // either direction.
        expect(
          DeploymentInterlock.conflictFor(
            interval(id: 'new', tag: 'tagB'),
            [interval(id: 'old', tag: 'tagA', attached: d(1))],
          ),
          isNull,
          reason: 'the candidate covers no interval',
        );
        expect(
          DeploymentInterlock.conflictFor(
            interval(id: 'new', tag: 'tagB', attached: d(1)),
            [interval(id: 'old', tag: 'tagA')],
          ),
          isNull,
          reason: 'the stored row covers no interval',
        );
      },
    );

    test('DELIBERATE: a tombstoned deployment constrains nothing', () {
      // Withdrawing a link is how both ends are freed; a tombstone that went
      // on refusing would make the withdrawal do nothing a person could see.
      expect(
        DeploymentInterlock.conflictFor(
          interval(id: 'new', tag: 'tagB', attached: d(1)),
          [interval(id: 'old', tag: 'tagA', attached: d(1), deleted: true)],
        ),
        isNull,
      );
    });

    test(
      'DELIBERATE: a tombstoned CANDIDATE conflicts with nothing either — '
      'withdrawing a link cannot create an overlap',
      () {
        // Task 11.263. The stored-tombstone case above has been here since
        // 11.243; this direction had no test and no code, so the server
        // refused a withdrawal whenever the row being withdrawn overlapped
        // something — exactly when somebody needs to withdraw it.
        expect(
          DeploymentInterlock.conflictFor(
            interval(id: 'gone', tag: 'tagB', attached: d(1), deleted: true),
            [interval(id: 'old', tag: 'tagA', attached: d(1))],
          ),
          isNull,
        );
      },
    );

    test('it names the first conflict rather than all of them', () {
      final conflict = DeploymentInterlock.conflictFor(
        interval(id: 'new', tag: 'tagC', attached: d(1)),
        [
          interval(id: 'first', tag: 'tagA', attached: d(1)),
          interval(id: 'second', tag: 'tagB', attached: d(1)),
        ],
      );
      expect(conflict!.other.deploymentId, 'first');
    });
  });

  group('intervalFromRow', () {
    test('reads a row off the wire', () {
      final parsed = DeploymentInterlock.intervalFromRow({
        'deployment_id': 'd1',
        'project_id': 'p1',
        'tag_id': 'tagA',
        'individual_id': 'marie',
        'attached_date': DbCodec.encodeUtc(d(1)),
        'removed_date': null,
        'deleted_at': null,
      });
      expect(parsed!.attachedDate!.isAtSameMomentAs(d(1)), isTrue);
      expect(parsed.removedDate, isNull);
      expect(parsed.deleted, isFalse);
    });

    test('a row missing an end is not guessed at', () {
      // `RowValidator` has already refused such a row. Inventing a value here
      // would make the interlock's answer depend on a parse nobody checked.
      expect(
        DeploymentInterlock.intervalFromRow({
          'deployment_id': 'd1',
          'tag_id': 'tagA',
        }),
        isNull,
      );
    });

    test('a bare day survives the wire round trip as a bare day', () {
      // The codec encodes as UTC and decodes as UTC; the sentinel converts
      // back to local before asking whether it is midnight. If either step
      // lost that, every stored date would read as a time on the way back.
      final parsed = DeploymentInterlock.intervalFromRow({
        'deployment_id': 'd1',
        'tag_id': 'tagA',
        'individual_id': 'marie',
        'attached_date': DbCodec.encodeUtc(d(1)),
        'removed_date': DbCodec.encodeUtc(d(10)),
      });
      expect(deploymentEndHasTime(parsed!.removedDate!), isFalse);
      expect(DeploymentInterlock.coverageEnd(parsed)!.isAtSameMomentAs(d(11)), isTrue);
    });
  });
}
