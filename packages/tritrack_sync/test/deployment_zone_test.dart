import 'package:test/test.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

/// Task 11.331 — a deployment day is the field site's day, wherever the
/// person (or the server) reading it is.
///
/// **Every fixture here names its zone**, and none depends on the zone this
/// process runs in: the nightly check runs the suite in three zones, and a
/// test that passes only where it was written is the defect this task fixes.
/// `DateTime.utc` is used for every literal instant so that the arithmetic in
/// the comments is the arithmetic in the code.
void main() {
  const phoenix = 'America/Phoenix'; // UTC−7 all year
  const denver = 'America/Denver'; // UTC−7, UTC−6 in summer (and Navajo)
  const london = 'Europe/London';
  const auckland = 'Pacific/Auckland';

  /// The start of [y]-[m]-[day] in [zone] — what the app writes for a day.
  DateTime day(String zone, int y, int m, int day) =>
      fieldDayStart(DateTime(y, m, day), zone);

  DeploymentInterval interval({
    String id = 'd1',
    String tag = 'tagA',
    String animal = 'marie',
    DateTime? attached,
    DateTime? removed,
    String? zone,
  }) => DeploymentInterval(
    deploymentId: id,
    tagId: tag,
    individualId: animal,
    attachedDate: attached,
    removedDate: removed,
    timeZone: zone,
  );

  group('a day in a named zone', () {
    test('an Arizona day starts at 07:00 UTC, wherever this runs', () {
      expect(
        day(phoenix, 2026, 10, 4).isAtSameMomentAs(DateTime.utc(2026, 10, 4, 7)),
        isTrue,
      );
    });

    test(
      'the instant 2026-10-05 03:00 UTC is the 4th in Arizona and the 5th in '
      'London — the same row, read in its own zone, is one day everywhere',
      () {
        final at = DateTime.utc(2026, 10, 5, 3);
        expect(fieldCalendarDate(at, phoenix), DateTime(2026, 10, 4));
        expect(fieldCalendarDate(at, london), DateTime(2026, 10, 5));
        expect(
          deploymentDateFor(at, phoenix).isAtSameMomentAs(day(phoenix, 2026, 10, 4)),
          isTrue,
        );
      },
    );

    test(
      'a New Zealand morning is that New Zealand day, not the UTC day before',
      () {
        // 9 a.m. on 1 March in Auckland (UTC+13) is 20:00 UTC on 28 February.
        final collaring = DateTime.utc(2026, 2, 28, 20);
        expect(fieldCalendarDate(collaring, auckland), DateTime(2026, 3, 1));
      },
    );

    test('deploymentDateFor is idempotent in every zone tried', () {
      for (final zone in [phoenix, denver, london, auckland, 'America/Havana']) {
        for (var h = 0; h < 48; h += 5) {
          final at = DateTime.utc(2026, 3, 7, h);
          final once = deploymentDateFor(at, zone);
          expect(
            deploymentDateFor(once, zone).isAtSameMomentAs(once),
            isTrue,
            reason: '$zone $at',
          );
          expect(deploymentEndHasTime(once, zone), isFalse, reason: zone);
        }
      }
    });

    test(
      'a day with no midnight (Havana springs forward at 00:00) starts at '
      '01:00 and is still that day',
      () {
        final start = day('America/Havana', 2026, 3, 8);
        expect(fieldCalendarDate(start, 'America/Havana'), DateTime(2026, 3, 8));
        expect(fieldWallClock(start, 'America/Havana').hour, 1);
      },
    );

    test('fieldInstant and fieldWallClock are inverses for a swap time', () {
      final swap = fieldInstant(DateTime(2026, 7, 10, 14, 32), phoenix);
      expect(swap.isAtSameMomentAs(DateTime.utc(2026, 7, 10, 21, 32)), isTrue);
      expect(fieldWallClock(swap, phoenix), DateTime(2026, 7, 10, 14, 32));
    });

    test('an unknown zone name reads as no zone at all', () {
      expect(FieldTimeZone.isKnown('Mars/Olympus_Mons'), isFalse);
      expect(FieldTimeZone.isKnown(null), isFalse);
      final at = DateTime(2026, 3, 7, 15);
      expect(
        deploymentDateFor(at, 'Mars/Olympus_Mons'),
        deploymentDateFor(at),
      );
    });
  });

  group('bare day or swap time — asked in the row\'s zone', () {
    test(
      'a swap at exactly 17:00 in Arizona is 00:00 UTC and is a TIME, on '
      'every reader — the one-in-24 hole tasks 11.264 and 11.266 priced',
      () {
        final swap = fieldInstant(DateTime(2026, 7, 10, 17), phoenix);
        expect(swap.isAtSameMomentAs(DateTime.utc(2026, 7, 11)), isTrue);
        expect(deploymentEndHasTime(swap, phoenix), isTrue);
      },
    );

    test('Arizona midnight is a bare day in Arizona and a time in Denver '
        'in summer', () {
      final arizonaDay = day(phoenix, 2026, 7, 10);
      expect(deploymentEndHasTime(arizonaDay, phoenix), isFalse);
      expect(deploymentEndHasTime(arizonaDay, denver), isTrue);
    });
  });

  group('the interlock reads each row in its own zone', () {
    test(
      'THE SERVER STOPS GUESSING: a same-day handover recorded as two bare '
      'Arizona days is refused with the server\'s flag on, as on the device',
      () {
        final old = interval(
          id: 'old',
          attached: day(phoenix, 2026, 7, 1),
          removed: day(phoenix, 2026, 7, 10),
          zone: phoenix,
        );
        final fresh = interval(
          id: 'new',
          tag: 'tagB',
          attached: day(phoenix, 2026, 7, 10),
          zone: phoenix,
        );
        for (final flag in [false, true]) {
          expect(
            DeploymentInterlock.conflictFor(
              fresh,
              [old],
              zonelessEndsAreInstants: flag,
            ),
            isNotNull,
            reason: 'zonelessEndsAreInstants: $flag',
          );
        }
      },
    );

    test(
      'a timed handover at 17:00 Arizona (00:00 UTC) overlaps by nothing, on '
      'the device and on the server',
      () {
        final swap = fieldInstant(DateTime(2026, 7, 10, 17), phoenix);
        final old = interval(
          id: 'old',
          attached: day(phoenix, 2026, 7, 1),
          removed: swap,
          zone: phoenix,
        );
        final fresh = interval(
          id: 'new',
          tag: 'tagB',
          attached: swap,
          zone: phoenix,
        );
        for (final flag in [false, true]) {
          expect(
            DeploymentInterlock.overlaps(
              old,
              fresh,
              zonelessEndsAreInstants: flag,
            ),
            isFalse,
            reason: 'zonelessEndsAreInstants: $flag',
          );
        }
      },
    );

    test(
      'a day entered from another zone: a London phone writing an Arizona '
      'project\'s 4 October stores Arizona\'s 4 October, and it meets the '
      '3rd without overlapping it',
      () {
        // The phone's own zone is irrelevant: the day is built from the
        // picked calendar date and the PROJECT's zone.
        final picked = DateTime(2026, 10, 4);
        final attached = fieldDayStart(picked, phoenix);
        expect(fieldCalendarDate(attached, phoenix), DateTime(2026, 10, 4));
        final previous = interval(
          id: 'old',
          attached: day(phoenix, 2026, 9, 1),
          removed: day(phoenix, 2026, 10, 3),
          zone: phoenix,
        );
        final fresh = interval(
          id: 'new',
          tag: 'tagB',
          attached: attached,
          zone: phoenix,
        );
        expect(DeploymentInterlock.overlaps(previous, fresh), isFalse);
        // And read in London's zone instead, the stored Arizona start
        // would be 08:00 on the 4th — a time — which is what used to happen.
        expect(deploymentEndHasTime(attached, london), isTrue);
      },
    );

    group('a zone change mid-season — recorded days stay the same days', () {
      // The project moved from Arizona time to Denver time in July. Arizona
      // midnight is 07:00 UTC; Denver's, in summer, is 06:00 UTC.
      final oldRow = interval(
        id: 'old',
        attached: day(phoenix, 2026, 6, 1),
        removed: day(phoenix, 2026, 7, 15),
        zone: phoenix,
      );

      test('removed the 15th (Arizona), attached the 16th (Denver): no '
          'overlap, though as instants the two share an hour', () {
        final fresh = interval(
          id: 'new',
          tag: 'tagB',
          attached: day(denver, 2026, 7, 16),
          zone: denver,
        );
        // The hour: Arizona's 15th ends at 07:00 UTC on the 16th; Denver's
        // 16th began at 06:00 UTC.
        expect(
          DeploymentInterlock.coverageEnd(oldRow)!.isAfter(fresh.attachedDate!),
          isTrue,
        );
        expect(DeploymentInterlock.overlaps(oldRow, fresh), isFalse);
        expect(
          DeploymentInterlock.overlaps(
            oldRow,
            fresh,
            zonelessEndsAreInstants: true,
          ),
          isFalse,
        );
      });

      test('removed the 15th (Arizona), attached the 15th (Denver): the same '
          'day, so refused as any same-day bare handover is', () {
        final fresh = interval(
          id: 'new',
          tag: 'tagB',
          attached: day(denver, 2026, 7, 15),
          zone: denver,
        );
        expect(DeploymentInterlock.overlaps(oldRow, fresh), isTrue);
      });

      test('the other way, Denver to Arizona, the 16th still follows the '
          '15th', () {
        final denverRow = interval(
          id: 'old',
          attached: day(denver, 2026, 6, 1),
          removed: day(denver, 2026, 7, 15),
          zone: denver,
        );
        final fresh = interval(
          id: 'new',
          tag: 'tagB',
          attached: day(phoenix, 2026, 7, 16),
          zone: phoenix,
        );
        expect(DeploymentInterlock.overlaps(denverRow, fresh), isFalse);
      });
    });

    group('both daylight-saving transitions (Denver, 2026)', () {
      test('8 March is 23 hours long: a bare day ends at the next day\'s '
          'start, not 24 hours later', () {
        final row = interval(
          attached: day(denver, 2026, 3, 1),
          removed: day(denver, 2026, 3, 8),
          zone: denver,
        );
        final end = DeploymentInterlock.coverageEnd(row)!;
        expect(end.isAtSameMomentAs(day(denver, 2026, 3, 9)), isTrue);
        expect(end.difference(day(denver, 2026, 3, 8)), const Duration(hours: 23));
        expect(end.isAtSameMomentAs(DateTime.utc(2026, 3, 9, 6)), isTrue);
      });

      test('1 November is 25 hours long', () {
        final row = interval(
          attached: day(denver, 2026, 10, 1),
          removed: day(denver, 2026, 11, 1),
          zone: denver,
        );
        final end = DeploymentInterlock.coverageEnd(row)!;
        expect(end.difference(day(denver, 2026, 11, 1)), const Duration(hours: 25));
        expect(end.isAtSameMomentAs(DateTime.utc(2026, 11, 2, 7)), isTrue);
      });

      test('across each transition, the next bare day does not overlap and a '
          'late swap on the day itself does', () {
        for (final (m, d) in [(3, 8), (11, 1)]) {
          final row = interval(
            id: 'old',
            attached: day(denver, 2026, m - 1, 1),
            removed: day(denver, 2026, m, d),
            zone: denver,
          );
          final nextDay = interval(
            id: 'new',
            tag: 'tagB',
            attached: day(denver, 2026, m, d + 1),
            zone: denver,
          );
          final lateSwap = interval(
            id: 'new',
            tag: 'tagB',
            attached: fieldInstant(DateTime(2026, m, d, 23, 30), denver),
            zone: denver,
          );
          for (final flag in [false, true]) {
            expect(
              DeploymentInterlock.overlaps(
                row,
                nextDay,
                zonelessEndsAreInstants: flag,
              ),
              isFalse,
              reason: '$m/$d next day, flag $flag',
            );
            expect(
              DeploymentInterlock.overlaps(
                row,
                lateSwap,
                zonelessEndsAreInstants: flag,
              ),
              isTrue,
              reason: '$m/$d 23:30, flag $flag',
            );
          }
        }
      });
    });

    group('an Arizona/Navajo pair — an hour apart in summer, one collar', () {
      // The Navajo Nation keeps daylight saving inside Arizona (Denver's
      // rules), so in July its clock is an hour ahead of Phoenix's.
      test('off one animal on the 10th (Arizona row), onto another on the '
          '11th (Navajo row): no overlap', () {
        final off = interval(
          id: 'a',
          animal: 'marie',
          attached: day(phoenix, 2026, 6, 1),
          removed: day(phoenix, 2026, 7, 10),
          zone: phoenix,
        );
        final on = interval(
          id: 'b',
          animal: 'sage',
          attached: day(denver, 2026, 7, 11),
          zone: denver,
        );
        expect(DeploymentInterlock.conflictFor(on, [off]), isNull);
        expect(
          DeploymentInterlock.conflictFor(
            on,
            [off],
            zonelessEndsAreInstants: true,
          ),
          isNull,
        );
      });

      test('a timed handover at 14:00 Arizona = 15:00 Navajo is one instant '
          'and overlaps by nothing; a minute later on the Navajo clock does', () {
        final swap = fieldInstant(DateTime(2026, 7, 10, 14), phoenix);
        expect(
          swap.isAtSameMomentAs(fieldInstant(DateTime(2026, 7, 10, 15), denver)),
          isTrue,
        );
        final off = interval(
          id: 'a',
          animal: 'marie',
          attached: day(phoenix, 2026, 6, 1),
          removed: swap,
          zone: phoenix,
        );
        final on = interval(
          id: 'b',
          animal: 'sage',
          attached: fieldInstant(DateTime(2026, 7, 10, 15), denver),
          zone: denver,
        );
        expect(DeploymentInterlock.conflictFor(on, [off]), isNull);
        final early = interval(
          id: 'b',
          animal: 'sage',
          attached: fieldInstant(DateTime(2026, 7, 10, 14, 59), denver),
          zone: denver,
        );
        expect(DeploymentInterlock.conflictFor(early, [off]), isNotNull);
      });
    });

    test('a zoneless row still gets the 11.266 reading on the server', () {
      // Written by a build older than v20: no zone, so the server cannot
      // know whose midnight it is and reads the end as the instant it holds.
      final end = DateTime.utc(2026, 7, 10, 7);
      final row = interval(attached: DateTime.utc(2026, 7, 1, 7), removed: end);
      expect(
        DeploymentInterlock.coverageEnd(row, zonelessEndsAreInstants: true),
        end,
      );
      // An unknown zone name is read the same way.
      final unknown = interval(
        attached: DateTime.utc(2026, 7, 1, 7),
        removed: end,
        zone: 'Mars/Olympus_Mons',
      );
      expect(
        DeploymentInterlock.coverageEnd(unknown, zonelessEndsAreInstants: true),
        end,
      );
    });

    test('intervalFromRow reads the row\'s zone off the wire', () {
      final interval = DeploymentInterlock.intervalFromRow({
        'deployment_id': 'd1',
        'tag_id': 't',
        'individual_id': 'i',
        'attached_date': '2026-07-01T07:00:00.000Z',
        'removed_date': null,
        'deleted_at': null,
        'time_zone': phoenix,
      });
      expect(interval!.timeZone, phoenix);
    });
  });
}
