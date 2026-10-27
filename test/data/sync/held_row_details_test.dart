import 'package:flutter_test/flutter_test.dart';
import 'package:tritrack/data/db/app_database.dart';
import 'package:tritrack/data/sync/held_row_details.dart';
import 'package:tritrack/data/sync/sync_held_rows.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

import '../fixtures.dart';

/// Task 11.41 — the screen the banner promises a reason and points at.
///
/// Everything here is an assertion about what a **person** can read off one
/// held record. The tests deliberately assert on the text, not on a shape:
/// the defect was that the text said nothing, and a test that only checked
/// "some string is produced" would have passed against the screen that cost
/// the diagnosis.
void main() {
  late AppDatabase appDb;

  const projectId = 'proj-1';
  // A second project this device also holds — where a tag *this* project
  // has not added lives, now that a tag has to live somewhere (task 11.219).
  const otherProjectId = 'proj-2';
  const meId = 'user-me';
  const themId = 'user-them';
  final now = DateTime.utc(2026, 8, 27, 9, 30);
  final stamp = DbCodec.encodeUtc(now);

  setUp(() async {
    appDb = await AppDatabase.openInMemory();
    await appDb.raw.insert(Tables.users, {
      'user_id': meId,
      'first_name': 'Michael',
      'last_name': 'Shafer',
      'email': 'michael@example.com',
      'created_at': stamp,
      'updated_at': stamp,
      'revision': 0,
      'last_modified_by': meId,
      'origin_device_id': 'device-A',
    });
    await appDb.raw.insert(Tables.users, {
      'user_id': themId,
      'first_name': 'Kim',
      'last_name': 'Reynolds',
      'email': 'kim@example.com',
      'created_at': stamp,
      'updated_at': stamp,
      'revision': 0,
      'last_modified_by': themId,
      'origin_device_id': 'device-B',
    });
    await appDb.raw.insert(Tables.projects, {
      'project_id': projectId,
      'project_name': 'Elk Winter Range',
      'owner_user_id': meId,
      'creation_date': stamp,
      'datum': 'WGS84',
      'created_at': stamp,
      'updated_at': stamp,
      'revision': 0,
      'last_modified_by': meId,
      'origin_device_id': 'device-A',
      'coordinate_format': 'dd',
      'triangulation_window_minutes': 15,
    });
    await appDb.raw.insert(Tables.projects, {
      'project_id': otherProjectId,
      'project_name': 'Another Range',
      'owner_user_id': meId,
      'creation_date': stamp,
      'datum': 'WGS84',
      'created_at': stamp,
      'updated_at': stamp,
      'revision': 0,
      'last_modified_by': meId,
      'origin_device_id': 'device-A',
      'coordinate_format': 'dd',
      'triangulation_window_minutes': 15,
    });
  });

  tearDown(() => appDb.close());

  HeldRow hold(
    String table,
    String key, {
    HeldRowReason reason = HeldRowReason.notPermitted,
    RowIssueCode? issueCode,
    String? issueField,
    String? interlockRule,
  }) => HeldRow(
    id: 1,
    tableName: table,
    rowKey: key,
    reason: reason,
    heldUpdatedAt: stamp,
    firstHeldAtUtc: now,
    lastRefusedAtUtc: now,
    refusalCount: 1,
    issueCode: issueCode,
    issueField: issueField,
    interlockRule: interlockRule,
  );

  Future<HeldRowDetail> resolveOne(
    HeldRow row, {
    String? currentUserId = meId,
  }) async => (await HeldRowDetails.resolve(
    appDb.raw,
    projectId: projectId,
    currentUserId: currentUserId,
    held: [row],
  )).single;

  Future<void> insertTag(
    String id, {
    required String name,
    required double mhz,
    String by = meId,
    bool addToProject = true,
  }) async {
    // **A tag belongs to a project since task 11.219**, so
    // [addToProject] chooses *which* project rather than whether to write a
    // link: false puts the collar in a second project this device also
    // holds, which is the case "a record uses a tag this project has not
    // added" is about.
    await appDb.raw.insert(Tables.tags, {
      'tag_id': id,
      'project_id': addToProject ? projectId : otherProjectId,
      'lineage_id': id,
      'frequency_mhz': mhz,
      'tag_name': name,
      'status': 'active',
      'created_at': stamp,
      'updated_at': stamp,
      'revision': 0,
      'last_modified_by': by,
      'origin_device_id': 'device-A',
    });
  }

  group('which record', () {
    test('a held Users row names the person, not the table', () async {
      final detail = await resolveOne(hold(Tables.users, themId));
      expect(detail.recordLabel, contains('Kim Reynolds'));
      expect(detail.recordLabel, isNot(equals('Users')));
    });

    test('a held Tags row names the tag and its frequency', () async {
      await insertTag('tag-1', name: 'Elk 12', mhz: 150.22);
      final detail = await resolveOne(hold(Tables.tags, 'tag-1/$projectId'));
      expect(detail.recordLabel, contains('Elk 12'));
      expect(detail.recordLabel, contains('150.220 MHz'));
    });

    test('a held bearing names its tag and when it was taken', () async {
      await insertTag('tag-1', name: 'Elk 12', mhz: 150.22);
      await appDb.raw.insert(Tables.observations, {
        'observation_id': 'obs-1',
        'project_id': projectId,
        'user_id': themId,
        'tag_id': 'tag-1',
        'timestamp_local': stamp,
        'timestamp_utc': stamp,
        'timezone_offset': '+00:00',
        'latitude': 35.19,
        'longitude': -111.65,
        'position_source': 'gps_fix',
        'elevation': 2100.0,
        'altitude_agl': 0.0,
        'observation_type': 'directional',
        'signal_type': 'regular_pulse',
        'signal_strength': 'strong',
        'created_at': stamp,
        'updated_at': stamp,
        'revision': 0,
        'last_modified_by': themId,
        'origin_device_id': 'device-B',
      });

      final detail = await resolveOne(
        hold(Tables.observations, 'obs-1/$projectId'),
      );
      expect(detail.recordLabel, contains('Elk 12'));
      expect(detail.recordLabel, contains('2026-08-27'));
    });
  });

  group('which rule held it', () {
    test(
      'a record naming somebody else says who, and that it is not you',
      () async {
        final detail = await resolveOne(hold(Tables.users, themId));
        expect(detail.heldBy, contains('Kim Reynolds'));
        expect(detail.heldBy, contains('Michael Shafer'));
        expect(detail.heldBy, contains('only accepted from that person'));
      },
    );

    test(
      'a record using a tag the project has not added says which tag',
      () async {
        await insertTag(
          'tag-outside',
          name: 'Deer 4',
          mhz: 151.5,
          addToProject: false,
        );
        final detail = await resolveOne(hold(Tables.tags, 'tag-outside/$otherProjectId'));
        expect(detail.heldBy, contains('Deer 4'));
        expect(detail.heldBy, contains('has not added'));
        expect(detail.whatYouCanDo, contains('Ask an owner'));
      },
    );

    test(
      'when nothing readable explains it, it says so rather than guessing',
      () async {
        // The case the old screen produced for *everything*. A control that
        // cannot tell one cause from another has to say which it is — that is
        // the defect class this whole task is about, and it applies to this
        // file too.
        await insertTag('tag-1', name: 'Elk 12', mhz: 150.22);
        final detail = await resolveOne(hold(Tables.tags, 'tag-1/$projectId'));
        expect(detail.heldBy, contains('did not say why'));
        expect(detail.whatYouCanDo, contains('worth reporting'));
      },
    );

    test('a record whose row is gone says so and cannot be retried', () async {
      final detail = await resolveOne(hold(Tables.tags, 'tag-vanished/$projectId'));
      expect(detail.recordExists, isFalse);
      expect(detail.heldBy, contains('no longer on this device'));
    });

    test('a rejected record is not described as a naming problem', () async {
      await insertTag('tag-1', name: 'Elk 12', mhz: 150.22, by: themId);
      final detail = await resolveOne(
        hold(Tables.tags, 'tag-1/$projectId', reason: HeldRowReason.rejected),
      );
      expect(detail.heldBy, isNot(contains('Kim Reynolds')));
      expect(detail.recordLabel, contains('Elk 12'));
    });

    test('no identity yet is handled rather than crashing', () async {
      final detail = await resolveOne(
        hold(Tables.users, themId),
        currentUserId: null,
      );
      expect(detail.heldBy, contains('Kim Reynolds'));
      expect(detail.heldBy, contains('nobody yet'));
    });
  });

  /// **Task 11.46.** A record held behind another record must name the record
  /// it is waiting on. Before this, the bearing — the record that matters —
  /// got the "the server did not say why" ending, while the cause sat one
  /// card away on the same screen.
  ///
  /// **What task 11.47 changed here, and what it deliberately did not.** The
  /// scenario this group was written from was "a project built from a
  /// colleague's archive publishes, and the rows a colleague last *edited*
  /// are refused." That particular cause is gone: an audit name on shared
  /// vocabulary no longer refuses anything (see
  /// `MutationRule.replicatesAForeignAuditName`), and the server-side proof
  /// of it lives in `publish_and_join_test.dart`.
  ///
  /// These tests are kept, and kept with a colleague's stamp on the referent,
  /// because **they are about the resolver, not about the server's rule.**
  /// `HeldRowDetails` never learns why a row was refused — the server answers
  /// one opaque `unauthorized` for every reason (§4.13) — so what it does is
  /// describe the local record and the holds around it. That behaviour is
  /// unchanged, and cascades are still reachable: a referent can be held for
  /// a role refusal, a dangling reference, a malformed row, or simply a hold
  /// recorded before this change and not yet resolved. What would be wrong is
  /// a *comment* here claiming the server refuses a tag for its audit name,
  /// so those have been corrected rather than the assertions relaxed.
  group('a record held behind another record (task 11.46)', () {
    Future<void> insertBearing(
      String id, {
      required String tagId,
      String? sessionId,
      String by = meId,
    }) async {
      await appDb.raw.insert(Tables.observations, {
        'observation_id': id,
        'project_id': projectId,
        'user_id': by,
        'tag_id': tagId,
        'session_id': ?sessionId,
        'timestamp_local': stamp,
        'timestamp_utc': stamp,
        'timezone_offset': '+00:00',
        'latitude': 35.19,
        'longitude': -111.65,
        'position_source': 'gps_fix',
        'elevation': 2100.0,
        'altitude_agl': 0.0,
        'observation_type': 'directional',
        'signal_type': 'regular_pulse',
        'signal_strength': 'strong',
        'created_at': stamp,
        'updated_at': stamp,
        'revision': 0,
        'last_modified_by': by,
        'origin_device_id': 'device-A',
      });
    }

    test("my own bearing held behind a colleague's tag names the tag, "
        'instead of saying the server would not say why', () async {
      // The tag is held — for whatever reason the server gave, which it
      // never says — and the project *has* added it, which is why every
      // other rule here reads this bearing as ordinary. The colleague's
      // stamp is what makes the tag's own card say something specific; it
      // is no longer what causes the refusal (task 11.47).
      await insertTag('tag-1', name: 'Elk 12', mhz: 150.22, by: themId);
      await insertBearing('obs-1', tagId: 'tag-1');

      final details = await HeldRowDetails.resolve(
        appDb.raw,
        projectId: projectId,
        currentUserId: meId,
        held: [
          hold(Tables.tags, 'tag-1/$projectId'),
          hold(Tables.observations, 'obs-1/$projectId'),
        ],
      );
      final bearing = details.last;

      expect(bearing.heldBy, contains('Elk 12'));
      expect(bearing.heldBy, contains('also waiting'));
      expect(bearing.whatYouCanDo, contains('Elk 12'));
      // The ending this branch exists to stop reaching field data.
      expect(bearing.heldBy, isNot(contains('did not say why')));
    });

    test(
      'and the tag itself still reports its own reason, not the bearing\'s',
      () async {
        await insertTag('tag-1', name: 'Elk 12', mhz: 150.22, by: themId);
        await insertBearing('obs-1', tagId: 'tag-1');

        final details = await HeldRowDetails.resolve(
          appDb.raw,
          projectId: projectId,
          currentUserId: meId,
          held: [
            hold(Tables.tags, 'tag-1/$projectId'),
            hold(Tables.observations, 'obs-1/$projectId'),
          ],
        );

        // A record does not wait for itself, and the root of a cascade must
        // still say what is actually wrong with it.
        expect(details.first.heldBy, contains('Kim Reynolds'));
        expect(details.first.heldBy, isNot(contains('also waiting')));
      },
    );

    test(
      'a bearing held behind a triangulation session names the session — '
      'the reference that took the whole request down before task 11.46',
      () async {
        await insertTag('tag-1', name: 'Elk 12', mhz: 150.22);
        await appDb.raw.insert(Tables.triangulationSessions, {
          'session_id': 'sess-1',
          'project_id': projectId,
          'tag_id': 'tag-1',
          'label': 'Morning sweep',
          'started_at_local': stamp,
          'started_at_utc': stamp,
          'started_at_offset': '+00:00',
          'created_at': stamp,
          'updated_at': stamp,
          'revision': 0,
          'last_modified_by': themId,
          'origin_device_id': 'device-B',
        });
        await insertBearing('obs-1', tagId: 'tag-1', sessionId: 'sess-1');

        final details = await HeldRowDetails.resolve(
          appDb.raw,
          projectId: projectId,
          currentUserId: meId,
          held: [
            hold(Tables.triangulationSessions, 'sess-1/$projectId'),
            hold(Tables.observations, 'obs-1/$projectId'),
          ],
        );

        expect(details.last.heldBy, contains('also waiting'));
        expect(details.last.heldBy, isNot(contains('did not say why')));
      },
    );

    test('a bearing whose referents are all fine is not told it is waiting on '
        'something', () async {
      // The negative control. Two bearings of my own, both held, neither
      // referring to the other — sharing a project id must not be read as a
      // reference, which is what requiring the *whole* primary key buys.
      await insertTag('tag-1', name: 'Elk 12', mhz: 150.22);
      await insertBearing('obs-1', tagId: 'tag-1');
      await insertBearing('obs-2', tagId: 'tag-1');

      final details = await HeldRowDetails.resolve(
        appDb.raw,
        projectId: projectId,
        currentUserId: meId,
        held: [
          hold(Tables.observations, 'obs-1/$projectId'),
          hold(Tables.observations, 'obs-2/$projectId'),
        ],
      );

      for (final detail in details) {
        expect(detail.heldBy, isNot(contains('also waiting')));
      }
    });
  });

  group('what you can do', () {
    test("a colleague's record says there is nothing to do, and why", () async {
      final detail = await resolveOne(hold(Tables.users, themId));
      expect(detail.whatYouCanDo, startsWith('Nothing'));
      expect(detail.whatYouCanDo, contains('Kim Reynolds'));
    });
  });

  group('no table can go back to showing a bare table name', () {
    test('every synced table has a record label of its own', () {
      // Task 10.66's standing criterion applied to this file. The label
      // builders are keyed by table name — exactly the shape that silently
      // exempts a new table — and the exemption would put that table's records
      // back to being described by the bare words "Tags" or "Users", which is
      // the state this task was opened for.
      //
      // Asserted against `recordLabelBuilders` itself rather than against a
      // list kept beside it, because that map *is* the dispatch: there is no
      // second copy for this to drift from.
      final missing = [
        for (final table in syncTables)
          if (!HeldRowDetails.recordLabelBuilders.containsKey(table.name))
            table.name,
      ];
      expect(
        missing,
        isEmpty,
        reason:
            'these synced tables would be shown to a person as their bare '
            'table name on the sync status screen: ${missing.join(', ')}',
      );
    });

    test('the guard cannot pass by measuring nothing', () {
      // The instrument's own self-check. A `syncTables` this test could not
      // see would make the assertion above vacuous, which is the failure mode
      // the assertion exists to catch one level down.
      expect(syncTables.length, greaterThanOrEqualTo(12));
      expect(
        HeldRowDetails.recordLabelBuilders.keys,
        containsAll([Tables.users, Tables.tags, Tables.observations]),
      );
    });
  });

  /// **Task 11.122, item 2 — what the app says when it does not know why.**
  ///
  /// The `rejected` branch used to say *"That is a fault in the app or a
  /// version mismatch, not something wrong with what you recorded"* and
  /// *"nothing you can do in the app will change the answer."* Task 11.84
  /// measured a case where both were false: a name carrying a bidirectional
  /// override **is** something about what the person recorded, and editing it
  /// in Profile fixes it and re-offers the row by itself.
  ///
  /// **The defect was not a missing case.** It was that the branch reached
  /// when this device has no information stated a cause as fact. The push
  /// response carries an outcome and no issue detail, so this device cannot
  /// tell a malformed value from version skew — and the old copy resolved
  /// that uncertainty by picking one.
  ///
  /// These tests read the copy so that nobody has to. They are written as
  /// properties of *the branch reached when nobody knows why* rather than as
  /// a match on today's wording, so they still hold for refusal reasons
  /// nobody has invented yet — which is the test of whether the fix was aimed
  /// at the class or the instance.
  group('the honest default (task 11.122)', () {
    /// Phrases that assert a cause this device cannot know, or tell somebody
    /// to stop trying. **The second kind is the one that matters most:** it
    /// is unrecoverable when it is wrong, because the person stops trying and
    /// a person who stops trying files no report.
    const forbidden = <String, String>{
      'nothing you can do':
          'tells the person to stop trying, in the one branch where this '
          'device does not know whether there is something they can do',
      'will change the answer':
          'the tail of the same sentence, so a reworded first half cannot '
          'sneak it back',
      'fault in the app':
          'asserts a cause. The push response carries no issue detail, so '
          'this device cannot know that',
      'version mismatch':
          'asserts a cause, and it is the wrong one for the case 11.84 '
          'measured',
      'not something wrong with what you recorded':
          'asserts the negative of the cause that was actually true',
    };

    void mustBeHonest(String label, String copy) {
      final lower = copy.toLowerCase();
      for (final entry in forbidden.entries) {
        expect(
          lower,
          isNot(contains(entry.key)),
          reason: '$label "${entry.key}" — ${entry.value}',
        );
      }
    }

    test('the constants the rejected branch renders claim no cause', () {
      mustBeHonest(
        'HeldRowDetails.rejectedWithoutADetail says',
        HeldRowDetails.rejectedWithoutADetail,
      );
      mustBeHonest(
        'HeldRowDetails.rejectedRemedy says',
        HeldRowDetails.rejectedRemedy,
      );
    });

    test('it says the refusal happened, and offers something to do', () async {
      await insertTag('tag-1', name: 'Elk 12', mhz: 150.22);
      final detail = await resolveOne(
        hold(Tables.tags, 'tag-1/$projectId', reason: HeldRowReason.rejected),
      );

      mustBeHonest('the rejected branch says', detail.heldBy);
      mustBeHonest('the rejected branch says', detail.whatYouCanDo);

      // What is known: the server refused it, this device does not know
      // which part, the copy is safe, and there are steps to take.
      expect(detail.heldBy, contains('did not say'));
      expect(detail.heldBy, contains('cannot tell'));
      expect(detail.whatYouCanDo, contains('safe'));
      expect(detail.whatYouCanDo, contains('Try again'));
      expect(
        detail.whatYouCanDo,
        contains('reporting'),
        reason:
            'A refusal this device cannot explain is exactly the one worth '
            'hearing about. Telling somebody to stop is what stops the '
            'report arriving.',
      );
    });

    test(
      'the other branch that does not know why is held to the same rule',
      () async {
        // `notPermitted` on a record where nothing readable on this device
        // explains the refusal — the file's final fallback. Same class, same
        // rule: it is a branch reached when nobody knows.
        await insertTag('tag-1', name: 'Elk 12', mhz: 150.22);
        final detail = await resolveOne(hold(Tables.tags, 'tag-1/$projectId'));

        mustBeHonest('the unexplained-refusal fallback says', detail.heldBy);
        mustBeHonest(
          'the unexplained-refusal fallback says',
          detail.whatYouCanDo,
        );
      },
    );
  });

  /// **Task 11.124 — the true sentence, and the honest default underneath it.**
  ///
  /// 11.122 made the refusal branch honest about not knowing. This is the
  /// detail that lets it know, in the cases the server can actually name — and
  /// the tests that matter most here are the ones checking it *still* does not
  /// know when it does not: a code this build has never seen, a field name
  /// that is not a column of the table, and no detail at all must each reach
  /// 11.122's default rather than the nearest specific answer.
  group('which part was refused (task 11.124)', () {
    Future<HeldRowDetail> rejectedTag({
      RowIssueCode? issueCode,
      String? issueField,
    }) async {
      await insertTag('tag-1', name: 'Elk 12', mhz: 150.22);
      return resolveOne(
        hold(
          Tables.tags,
          'tag-1/$projectId',
          reason: HeldRowReason.rejected,
          issueCode: issueCode,
          issueField: issueField,
        ),
      );
    }

    test('a name the server will not store is named, in words about the '
        'record rather than about the protocol', () async {
      final detail = await resolveOne(
        hold(
          Tables.users,
          meId,
          reason: HeldRowReason.rejected,
          issueCode: RowIssueCode.textNotAName,
          issueField: 'first_name',
        ),
      );

      expect(detail.heldBy, contains('the first name'));
      expect(detail.heldBy, contains('will not accept'));
      // The remedy is the one that actually works for this cause, and it
      // says so rather than offering the general list.
      expect(detail.whatYouCanDo, contains('retype the first name'));
      expect(detail.whatYouCanDo, contains('Try again'));
      // It is still not the honest default.
      expect(detail.heldBy, isNot(HeldRowDetails.rejectedWithoutADetail));
    });

    test(
      'an over-long value says which value and says to shorten it',
      () async {
        final detail = await rejectedTag(
          issueCode: RowIssueCode.textTooLong,
          issueField: 'tag_name',
        );
        expect(detail.heldBy, contains('the tag name'));
        expect(detail.heldBy, contains('too long'));
        expect(detail.whatYouCanDo, contains('shorten'));
      },
    );

    test('a cause the person cannot have caused says so, and still does not '
        'tell them to stop', () async {
      final detail = await rejectedTag(
        issueCode: RowIssueCode.textNotAnIdentifier,
        issueField: 'tag_id',
      );
      expect(detail.heldBy, contains('not a usable identifier'));
      expect(detail.whatYouCanDo, contains('Try again'));
      expect(detail.whatYouCanDo, contains('reporting'));
      expect(
        detail.whatYouCanDo.toLowerCase(),
        isNot(contains('nothing you can do')),
        reason:
            'The one sentence that is unrecoverable when it is wrong. Task '
            '11.122 removed it from this branch and no specific case may '
            'bring it back.',
      );
    });

    test('every code this build knows produces a sentence, so a code can '
        'never arrive with nothing to say', () async {
      // Derived from the enum. A code added without copy would otherwise be
      // invisible until somebody hit it in the field.
      for (final code in RowIssueCode.values) {
        final detail = await resolveOne(
          hold(
            Tables.tags,
            'tag-1/$projectId',
            reason: HeldRowReason.rejected,
            issueCode: code,
            issueField: 'tag_name',
          ),
        );
        expect(
          detail.heldBy,
          isNot(HeldRowDetails.rejectedWithoutADetail),
          reason: '$code produced no sentence of its own',
        );
        expect(detail.heldBy, isNotEmpty, reason: '$code');
        expect(detail.whatYouCanDo, isNotEmpty, reason: '$code');
      }
    });

    group('and everything else still reaches the honest default', () {
      test('a refusal with no detail — the ordinary case', () async {
        final detail = await rejectedTag();
        expect(detail.heldBy, HeldRowDetails.rejectedWithoutADetail);
        expect(detail.whatYouCanDo, HeldRowDetails.rejectedRemedy);
      });

      test('a code this build has never seen — the case that decides whether '
          '11.122 survived this task', () async {
        // A code cannot be typed here, because the whole point is that this
        // build does not have one: it arrives as an unrecognised string and
        // `RowIssueCode.fromWire` turns it into null on the way out of the
        // database. `sync_held_rows` proves that half; this proves the screen
        // then behaves as though nothing was ever said.
        expect(RowIssueCode.fromWire('text_not_a_haiku'), isNull);
        final detail = await rejectedTag();
        expect(detail.heldBy, HeldRowDetails.rejectedWithoutADetail);
        expect(detail.whatYouCanDo, HeldRowDetails.rejectedRemedy);
      });

      test('a field name that is not a column of this table is not put in a '
          'sentence, and the code alone still is', () async {
        final detail = await rejectedTag(
          issueCode: RowIssueCode.textTooLong,
          issueField: 'first_name; DROP TABLE Tags',
        );
        expect(detail.heldBy, isNot(contains('DROP TABLE')));
        expect(detail.heldBy, contains('one of the text values'));
        expect(detail.heldBy, contains('too long'));
      });

      test('a numeric refusal with no usable field name names a number '
          'rather than a text value', () async {
        // Task 11.136. The fallback subject used to be "one of the text
        // values in this record" for every code, because every code was about
        // text. A number arriving under it would have sent somebody looking
        // through the record's words for a fault in its figures.
        final detail = await rejectedTag(
          issueCode: RowIssueCode.numberAboveMaximum,
          issueField: 'not_a_column_of_tags',
        );
        expect(detail.heldBy, contains('one of the numbers in this record'));
        expect(detail.heldBy, isNot(contains('text values')));
      });

      test('a range refusal names the column when the server named one this '
          'build declares', () async {
        final detail = await rejectedTag(
          issueCode: RowIssueCode.numberAboveMaximum,
          issueField: 'frequency_mhz',
        );
        expect(detail.heldBy, contains('larger than it allows'));
        expect(
          detail.heldBy,
          isNot(contains('1000')),
          reason:
              'the bound itself lives on the server too, and a sentence '
              'quoting the number this build holds is false the day the '
              'server changes it',
        );
        expect(
          detail.whatYouCanDo.toLowerCase(),
          isNot(contains('nothing you can do')),
        );
      });

      test('a field name that is a real column of a different table is still '
          'refused for this one', () async {
        final detail = await rejectedTag(
          issueCode: RowIssueCode.textTooLong,
          // A real column — on `Users`, not on `Tags`.
          issueField: 'first_name',
        );
        expect(detail.heldBy, isNot(contains('first name')));
        expect(detail.heldBy, contains('one of the text values'));
      });
    });

    test('a detail never reaches a refusal that was not a rejection — '
        'unauthorized stays opaque all the way to the screen', () async {
      // The wire drops a detail beside an `unauthorized` outcome, so this
      // state is unreachable from a real server. Asserted anyway: the screen
      // is the last place the bound could be lost, and a second lock on a
      // security bound costs one test.
      final detail = await resolveOne(
        hold(
          Tables.tags,
          'tag-1/$projectId',
          reason: HeldRowReason.notPermitted,
          issueCode: RowIssueCode.textNotAName,
          issueField: 'first_name',
        ),
      );
      expect(detail.heldBy, isNot(contains('will not accept')));
      expect(detail.heldBy, isNot(contains('the first name')));
    });
  });

  /// **Task 11.267.** An interlock refusal carries no `RowRefusal` code, so
  /// `_rejectionDetail` above always returns null for one — the whole point
  /// of these tests is that this device answers anyway, by re-running
  /// `DeploymentInterlock.conflictFor` on its own stored rows rather than
  /// falling through to the honest default it has no need for here.
  group('an overlapping deployment (task 11.267)', () {
    // Raw inserts, exactly as [insertTag] above does — this file resolves
    // held rows against whatever this device's store contains, not against
    // what a repository would let a signed-in user write, so there is no
    // reason to route through one (or its membership checks) here.
    Future<void> insertIndividual(String id, {String name = 'Marie'}) =>
        appDb.raw.insert(
          Tables.individuals,
          sampleIndividual(id: id, projectId: projectId, name: name)
              .toColumns(),
        );

    /// Writes a deployment straight to the store, bypassing the interlock —
    /// exactly how task 11.263's own history planted a legacy pair: a row
    /// this device never refused locally, because it was written before the
    /// tolerance that allowed it was withdrawn.
    Future<void> plantDeployment(
      String id, {
      required String tagId,
      required String individualId,
      required DateTime attached,
      DateTime? removed,
    }) => appDb.raw.insert(
      Tables.deployments,
      sampleDeployment(
        id: id,
        projectId: projectId,
        tagId: tagId,
        individualId: individualId,
        attachedDate: attached,
        removedDate: removed,
      ).toColumns(),
    );

    test('names the other deployment and its dates, reusing the local '
        'interlock sentence rather than writing a second one', () async {
      await insertIndividual('marie');
      await insertTag('tag-a', name: 'Collar A', mhz: 150.1);
      await insertTag('tag-b', name: 'Collar B', mhz: 150.2);
      await plantDeployment(
        'dep-old',
        tagId: 'tag-a',
        individualId: 'marie',
        attached: DateTime(2026, 3, 1),
        removed: DateTime(2026, 3, 10),
      );
      await plantDeployment(
        'dep-new',
        tagId: 'tag-b',
        individualId: 'marie',
        attached: DateTime(2026, 3, 10),
      );

      final detail = await resolveOne(
        hold(
          Tables.deployments,
          'dep-new/$projectId',
          reason: HeldRowReason.rejected,
          interlockRule: DeploymentInterlock.ruleId,
        ),
      );

      expect(detail.heldBy, contains('Collar A'));
      expect(detail.heldBy, contains('2026-03-01'));
      expect(detail.heldBy, contains('2026-03-10'));
      expect(
        detail.heldBy,
        contains('This animal would be wearing two tags at once'),
        reason: 'the exact sentence OverlappingDeployment.messageFor '
            'produces for a local link refusal — reused, not rewritten',
      );
      expect(detail.whatYouCanDo, contains('set a time'));
      expect(detail.whatYouCanDo, contains('Try again'));
      // A remedy that names a control that exists, not the pasted-text
      // advice `_rejectionDetail`'s default carries.
      expect(detail.whatYouCanDo, isNot(contains('pasted')));
      expect(detail.heldBy, isNot(HeldRowDetails.rejectedWithoutADetail));
    });

    // **Task 11.323 item 7.** The remedy asks for a time on the attached or
    // removed date, so when the other deployment's end *has* a time (a
    // same-day swap) the card must show it — a day alone hides the very time
    // the person is being asked to work around.
    test("a same-day swap shows the other collar's swap time, not only its "
        'day', () async {
      await insertIndividual('marie');
      await insertTag('tag-a', name: 'Collar A', mhz: 150.1);
      await insertTag('tag-b', name: 'Collar B', mhz: 150.2);
      await plantDeployment(
        'dep-old',
        tagId: 'tag-a',
        individualId: 'marie',
        attached: DateTime(2026, 3, 1),
        removed: DateTime(2026, 3, 10, 14, 30),
      );
      await plantDeployment(
        'dep-new',
        tagId: 'tag-b',
        individualId: 'marie',
        attached: DateTime(2026, 3, 10, 10, 15),
      );

      final detail = await resolveOne(
        hold(
          Tables.deployments,
          'dep-new/$projectId',
          reason: HeldRowReason.rejected,
          interlockRule: DeploymentInterlock.ruleId,
        ),
      );

      expect(detail.heldBy, contains('removed 2026-03-10 14:30'));
      // A bare-day end still reads as a day, exactly as before.
      expect(detail.heldBy, contains('attached 2026-03-01,'));
    });

    // **Task 11.326.** The card's title names a held deployment by the day it
    // went on, and that day was written as local midnight by
    // `deploymentDateFor`. Read back through UTC it is the day before
    // anywhere east of UTC; this is red under TZ=Pacific/Auckland without the
    // fix and was never red in Phoenix or UTC, the only zones it had run in.
    test("the card's title gives the deployment's attached day as this "
        'device wrote it, in every zone', () async {
      await insertIndividual('marie');
      await insertTag('tag-a', name: 'Collar A', mhz: 150.1);
      await plantDeployment(
        'dep-new',
        tagId: 'tag-a',
        individualId: 'marie',
        attached: deploymentDateFor(DateTime(2026, 3, 10, 9)),
      );

      final detail = await resolveOne(
        hold(
          Tables.deployments,
          'dep-new/$projectId',
          reason: HeldRowReason.rejected,
          interlockRule: DeploymentInterlock.ruleId,
        ),
      );

      expect(detail.recordLabel, contains('from 2026-03-10'));
    });

    test('a rule this device does not recognise falls through to the '
        'honest default, not to a guess', () async {
      await insertIndividual('marie');
      await insertTag('tag-a', name: 'Collar A', mhz: 150.1);
      await plantDeployment(
        'dep-new',
        tagId: 'tag-a',
        individualId: 'marie',
        attached: DateTime(2026, 3, 10),
      );

      final detail = await resolveOne(
        hold(
          Tables.deployments,
          'dep-new/$projectId',
          reason: HeldRowReason.rejected,
          interlockRule: 'some_future_rule',
        ),
      );
      expect(detail.heldBy, HeldRowDetails.rejectedWithoutADetail);
      expect(detail.whatYouCanDo, HeldRowDetails.rejectedRemedy);
    });

    test('an interlock rule with nothing left on this device to conflict '
        'with falls through to the honest default rather than asserting a '
        'stale cause', () async {
      await insertIndividual('marie');
      await insertTag('tag-a', name: 'Collar A', mhz: 150.1);
      // Only the one row: whatever it once conflicted with is gone —
      // withdrawn or edited since the push that refused this one.
      await plantDeployment(
        'dep-new',
        tagId: 'tag-a',
        individualId: 'marie',
        attached: DateTime(2026, 3, 10),
      );

      final detail = await resolveOne(
        hold(
          Tables.deployments,
          'dep-new/$projectId',
          reason: HeldRowReason.rejected,
          interlockRule: DeploymentInterlock.ruleId,
        ),
      );
      expect(detail.heldBy, HeldRowDetails.rejectedWithoutADetail);
      expect(detail.whatYouCanDo, HeldRowDetails.rejectedRemedy);
    });

    test('the unexplained-refusal branch stays reachable for a rejection '
        'this device genuinely cannot explain — no interlock, no issue '
        'code', () async {
      await insertTag('tag-1', name: 'Elk 12', mhz: 150.22);
      final detail = await resolveOne(
        hold(
          Tables.tags,
          'tag-1/$projectId',
          reason: HeldRowReason.rejected,
        ),
      );
      expect(detail.heldBy, HeldRowDetails.rejectedWithoutADetail);
      expect(detail.whatYouCanDo, HeldRowDetails.rejectedRemedy);
    });
  });
}
