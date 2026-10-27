import 'package:test/test.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

/// Task 11.43 — **what a device may offer the server at all.**
///
/// These run with no database and no Flutter, like the rule table they read,
/// because the whole point of the rule living in the shared package is that
/// the client's "should I send this?" and the server's "will I take this?" are
/// two readings of one declaration and cannot disagree.
void main() {
  group('the classification is derived, and a new table inherits it', () {
    test('every table can be classified', () {
      expect(assertOfferRulesClassifyEveryTable, returnsNormally);
    });

    test('exactly four tables are records the server keeps for itself', () {
      // **Pinned rather than merely computed.** If a fourteenth table lands on
      // this side of the line, that is a decision somebody should have to look
      // at — a table whose rows a device may no longer send is a real change
      // to what publish uploads — so this test exists to make it visible
      // rather than to re-derive the same answer the code just derived.
      final kept = {
        for (final table in syncTables)
          if (serverKeepsItsOwnRecordOf(table)) table.name,
      };
      expect(kept, {
        // Who somebody is: global rows about a person. The server writes a
        // placeholder one when their join request is approved, carrying the address
        // it authenticated and deliberately no invented name, and their real
        // one arrives when their own device pushes it.
        Tables.users,
        Tables.userEmails,
        // What somebody may do: authorization state. The server writes a
        // membership row itself at approval, out of the request's own
        // project and role and the authenticated session's user — no part of
        // it comes from a request body.
        Tables.projects,
        Tables.projectMemberships,
      });
    });

    test('field data and shared vocabulary are the device\'s to send', () {
      // The other side of the line, named explicitly, because withholding one
      // of these would be the silent omission §4.17 built the held-row store
      // to avoid. A colleague's bearing is still offered, still refused, and
      // still held with a reason.
      for (final name in [
        Tables.observations,
        Tables.nonDetections,
        Tables.observationExclusions,
        Tables.tags,
        Tables.tagVersions,
        Tables.triangulationSessions,
        Tables.estimatedPositions,
        Tables.actualTagLocations,
      ]) {
        expect(
          serverKeepsItsOwnRecordOf(syncTablesByName[name]!),
          isFalse,
          reason: '$name is field data or shared vocabulary',
        );
      }
    });

    test('the two questions the classifier asks are both load-bearing', () {
      // Authorization state is never field data — `Projects` is project-scoped
      // and still kept by the server — so scope alone would get it wrong.
      expect(syncTablesByName[Tables.projects]!.projectScopeColumn, isNotNull);
      expect(
        serverKeepsItsOwnRecordOf(syncTablesByName[Tables.projects]!),
        isTrue,
      );

      // And naming an author is not sufficient either: `Observations` names one
      // and is field data. The second question — "does it have a project to be
      // data *of*?" — is what separates them.
      expect(
        tableMutationRules[Tables.observations]!.namesRowAuthor,
        isTrue,
      );
      expect(
        serverKeepsItsOwnRecordOf(syncTablesByName[Tables.observations]!),
        isFalse,
      );
    });
  });

  group('the safety property: nothing withheld could have been accepted', () {
    test(
      'every withheld table refuses a foreign name on an insert '
      'unconditionally',
      () {
        // This is what makes withholding legitimate rather than a guess. §4.17
        // permits a row to name somebody other than the caller on exactly one
        // condition — clause 2, "this project already reaches them" — and that
        // clause applies only where `vouchesForAForeignName` is true. If it
        // were ever true for a table this file withholds rows of, the client
        // would be suppressing a row the server would have taken, and the user
        // would lose data with no warning. It is false for all four.
        //
        // **"On an insert" is task 11.57's correction, and it is not a
        // wording change.** `RowAuthorizer._authorizeNaming` only asks this
        // question when there is no stored row; for an *update* it asks
        // whether the name has changed, which for an owner ending a member's
        // stint it has not. This test read as covering both and covered one,
        // and the half it did not cover is where an owner's removal was
        // withheld for a year of task numbers without ever being refused. The
        // ownership waiver is what covers the update half; see
        // `namingRequirementsForOffering`.
        for (final table in syncTables) {
          if (!serverKeepsItsOwnRecordOf(table)) continue;
          expect(
            tableMutationRules[table.name]!.vouchesForAForeignName,
            isFalse,
            reason:
                '${table.name} is withheld from a push, so the server must '
                'refuse a foreign name on it with no lookup — otherwise '
                'withholding suppresses a row that would have been accepted',
          );
        }
      },
    );

    test('anyUser is the only rule clause 2 still vouches for', () {
      for (final rule in MutationRule.values) {
        expect(
          rule.vouchesForAForeignName,
          rule == MutationRule.anyUser,
          reason: 'MutationRule.${rule.name}',
        );
      }
    });
  });

  group('mayOfferRow', () {
    final users = syncTablesByName[Tables.users]!;
    final observations = syncTablesByName[Tables.observations]!;

    test('my own identity row goes up; a colleague\'s does not', () {
      expect(
        mayOfferRow(
          users,
          {'user_id': 'me', 'last_modified_by': 'me'},
          'me',
          callerOwnsTheProject: false,
          serverAlreadyHoldsThisRow: true,
        ),
        isTrue,
      );
      expect(
        mayOfferRow(
          users,
          {'user_id': 'them', 'last_modified_by': 'them'},
          'me',
          callerOwnsTheProject: false,
          serverAlreadyHoldsThisRow: true,
        ),
        isFalse,
      );
    });

    test('the audit column is governed too, not just the identity column', () {
      // §4.17 is stated over the wider `userColumns` set and the server
      // enforces it over the wider set: a `Users` row whose `last_modified_by`
      // names somebody else is refused just as firmly.
      expect(
        mayOfferRow(
          users,
          {'user_id': 'me', 'last_modified_by': 'them'},
          'me',
          callerOwnsTheProject: false,
          serverAlreadyHoldsThisRow: true,
        ),
        isFalse,
      );
      expect(
        namingRequirementsForOffering(users).map((r) => r.column),
        contains(auditUserColumn),
      );
    });

    test("a colleague's bearing is still this device's to offer", () {
      expect(
        mayOfferRow(
          observations,
          {'user_id': 'them', 'last_modified_by': 'them'},
          'me',
          callerOwnsTheProject: false,
          serverAlreadyHoldsThisRow: true,
        ),
        isTrue,
        reason:
            'withholding it would turn a visible, self-clearing wait into a '
            'silent omission',
      );
      expect(namingRequirementsForOffering(observations), isEmpty);
    });

    test('a null in a governed column permits, as MutationRule.permits does', () {
      expect(
        mayOfferRow(
          users,
          {'user_id': 'me'},
          'me',
          callerOwnsTheProject: false,
          serverAlreadyHoldsThisRow: true,
        ),
        isTrue,
      );
    });

    test('no session denies every governed row, which is the safe direction', () {
      expect(
        mayOfferRow(
          users,
          {'user_id': 'me', 'last_modified_by': 'me'},
          null,
          callerOwnsTheProject: false,
          serverAlreadyHoldsThisRow: true,
        ),
        isFalse,
      );
    });
  });

  /// **Task 11.57: the direction of removal that had never been walked.**
  ///
  /// An owner ending a member's stint writes a row that names the *member*.
  /// Under the flat rule it never left the owner's device, the person stayed a
  /// member on the server for good, and nothing said so — because the pending
  /// count is computed from this same rule.
  group('the ownership waiver', () {
    final memberships = syncTablesByName[Tables.projectMemberships]!;
    final projects = syncTablesByName[Tables.projects]!;
    final users = syncTablesByName[Tables.users]!;

    Map<String, Object?> membershipRow({required String modifiedBy}) => {
      'membership_id': 'm1',
      'project_id': 'p1',
      'user_id': 'them',
      'last_modified_by': modifiedBy,
    };

    test('an owner may offer a membership row that names somebody else', () {
      expect(
        mayOfferRow(
          memberships,
          membershipRow(modifiedBy: 'me'),
          'me',
          callerOwnsTheProject: true,
          serverAlreadyHoldsThisRow: true,
        ),
        isTrue,
      );
    });

    test('a non-owner may not', () {
      expect(
        mayOfferRow(
          memberships,
          membershipRow(modifiedBy: 'me'),
          'me',
          callerOwnsTheProject: false,
          serverAlreadyHoldsThisRow: true,
        ),
        isFalse,
      );
    });

    test(
      'owning the project does not waive the audit column, which is what '
      'keeps task 11.43 closed',
      () {
        // The teammate's membership row on a first publish: written by the
        // teammate (the server stamped it at redemption), so it is still
        // withheld — by this clause, whoever owns the project.
        expect(
          mayOfferRow(
            memberships,
            membershipRow(modifiedBy: 'them'),
            'me',
            callerOwnsTheProject: true,
            serverAlreadyHoldsThisRow: true,
          ),
          isFalse,
        );
      },
    );

    test('owning a project waives nothing on a global identity table', () {
      // Nobody owns `Users`. Without this bound, the waiver would read as
      // "an owner may push a colleague's identity record".
      expect(
        mayOfferRow(
          users,
          {'user_id': 'them', 'last_modified_by': 'me'},
          'me',
          callerOwnsTheProject: true,
          serverAlreadyHoldsThisRow: true,
        ),
        isFalse,
      );
      expect(
        namingRequirementsForOffering(users)
            .every((r) => !r.waivedByOwnership),
        isTrue,
      );
    });

    test(
      'a row the server has never held is withheld even from an owner, which '
      'is what keeps a first publish clean',
      () {
        // The insert half. The server refuses a foreign name on an insert
        // unconditionally, so offering one would put a refused record on the
        // first thing a person does with a server — task 11.43's headline.
        expect(
          mayOfferRow(
            memberships,
            membershipRow(modifiedBy: 'me'),
            'me',
            callerOwnsTheProject: true,
            serverAlreadyHoldsThisRow: false,
          ),
          isFalse,
        );
      },
    );

    test('a co-owner may offer the project row they do not appear on', () {
      // Task 11.1 moved ownership to membership rows, so `owner_user_id` names
      // the *creator*. A second owner's edit to project settings was withheld
      // by the flat rule for exactly the same reason a removal was.
      expect(
        mayOfferRow(
          projects,
          {'project_id': 'p1', 'owner_user_id': 'creator',
            'last_modified_by': 'me'},
          'me',
          callerOwnsTheProject: true,
          serverAlreadyHoldsThisRow: true,
        ),
        isTrue,
      );
    });

    test('the waiver is declared per column, not per table', () {
      final requirements = {
        for (final r in namingRequirementsForOffering(memberships))
          r.column: r.waivedByOwnership,
      };
      expect(requirements[auditUserColumn], isFalse);
      expect(
        requirements.entries
            .where((e) => e.key != auditUserColumn)
            .every((e) => e.value),
        isTrue,
        reason:
            'every identity column of a project-scoped authorization table is '
            'waivable; the audit column never is',
      );
    });
  });
}
