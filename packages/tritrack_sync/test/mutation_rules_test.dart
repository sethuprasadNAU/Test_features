import 'package:test/test.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

/// The rule table is shared between the app's advisory checks and the server's
/// enforced ones (task 10.10), so these run with no database and no Flutter —
/// a disagreement about *which* rule governs *which* table is exactly the
/// class of bug moving it here was meant to make impossible.
void main() {
  test('every table has a declared rule', () {
    // No default exists on purpose: a table added without a rule must fail
    // loudly rather than quietly inherit the most permissive behaviour.
    expect(assertEveryTableHasAMutationRule, returnsNormally);
  });

  test('the rule table covers exactly the sync tables, no strays', () {
    expect(tableMutationRules.keys.toSet(), Tables.all.toSet());
  });

  group('permits', () {
    test('author singles out exactly one user', () {
      expect(MutationRule.author.permits('u1', 'u1'), isTrue);
      expect(MutationRule.author.permits('u2', 'u1'), isFalse);
    });

    test('the ownership rules refuse to answer the single-value question', () {
      // Task 11.1: `owner` used to compare against `Projects.owner_user_id`
      // here, and this test used to assert it did. It cannot any more —
      // ownership is a set of membership rows, and a call site still asking
      // the old question is a place ownership transfer silently would not
      // apply. Throwing is what turns those into failing tests instead of
      // stale behaviour; the two UI call sites 11.1 inherited were exactly
      // that shape.
      expect(() => MutationRule.owner.permits('u1', 'u1'), throwsStateError);
      expect(
        () => MutationRule.projectOwner.permits('u1', 'p1'),
        throwsStateError,
      );
      // Task 11.15: `authorOrOwner` refuses for the mirror-image reason. It
      // *could* answer the author half from the row alone, and answering it
      // would silently drop the owner half — leaving a mark whose author has
      // left the project unwithdrawable, which is the exact bug the rule was
      // added to end.
      expect(
        () => MutationRule.authorOrOwner.permits('u1', 'u1'),
        throwsStateError,
      );
    });

    test('anyUser permits everyone, including an unidentified caller', () {
      expect(MutationRule.anyUser.permits('u1', 'u2'), isTrue);
      expect(MutationRule.anyUser.permits(null, null), isTrue);
    });

    test('a null governing value permits', () {
      // Documented behaviour with a sharp edge: callers that map "row not
      // found" onto null must decide for themselves whether that is
      // permitted, because this cannot tell the two apart. The server's
      // RowAuthorizer resolves projectOwner by query rather than passing null
      // for "not the owner" precisely because of this.
      expect(MutationRule.author.permits('u1', null), isTrue);
    });

    test('the ownership rules name the project whose owners govern', () {
      expect(MutationRule.owner.resolvesProjectOwners, isTrue);
      expect(MutationRule.projectOwner.resolvesProjectOwners, isTrue);
      expect(MutationRule.authorOrOwner.resolvesProjectOwners, isTrue);
      // Both spell it `project_id`: for `Projects` that column is the primary
      // key, so "the project this row is" and "the project this row belongs
      // to" are the same lookup.
      expect(MutationRule.owner.projectColumn, 'project_id');
      expect(MutationRule.projectOwner.projectColumn, 'project_id');
      expect(MutationRule.authorOrOwner.projectColumn, 'project_id');
      // `owner_user_id` survives as the creator/audit record — still the
      // column whose type is checked and whose value may not be rewritten.
      expect(MutationRule.owner.governingColumn, 'owner_user_id');
      expect(MutationRule.projectOwner.governingColumn, 'project_id');
    });

    test('author and anyUser are not owner-set rules', () {
      expect(MutationRule.author.resolvesProjectOwners, isFalse);
      expect(MutationRule.anyUser.resolvesProjectOwners, isFalse);
      expect(MutationRule.author.projectColumn, isNull);
      expect(
        () => MutationRule.author.permittedByOwners(
          'u1',
          owners: {'u1'},
          authorUserId: 'u1',
        ),
        throwsStateError,
      );
    });

    test('only the author-naming rules name a user this rule permits', () {
      // `userColumn` is not `governingColumn`: for `owner` that column is the
      // creator/audit record and for `projectOwner` it is a project, neither
      // of which is a user the rule lets write. Task 11.15's disjunction
      // reads the author off `userColumn` specifically, so conflating the two
      // would have made it compare the actor against a project id.
      expect(MutationRule.author.userColumn, 'user_id');
      expect(MutationRule.authorOrOwner.userColumn, 'user_id');
      expect(MutationRule.owner.userColumn, isNull);
      expect(MutationRule.projectOwner.userColumn, isNull);
      expect(MutationRule.anyUser.userColumn, isNull);

      expect(MutationRule.author.namesRowAuthor, isTrue);
      expect(MutationRule.authorOrOwner.namesRowAuthor, isTrue);
      expect(MutationRule.anyUser.namesRowAuthor, isFalse);
      expect(MutationRule.owner.namesRowAuthor, isFalse);
    });

    test('authorOrOwner is field data, not authorization state', () {
      // The line the server's replication and naming exemptions are drawn on.
      // A mark is a field judgement; `Projects` and `Project_Memberships` are
      // somebody's rights. Putting `authorOrOwner` on the wrong side would
      // have made replicating a teammate's mark an escalation-shaped refusal.
      expect(MutationRule.owner.isAuthorizationState, isTrue);
      expect(MutationRule.projectOwner.isAuthorizationState, isTrue);
      expect(MutationRule.authorOrOwner.isAuthorizationState, isFalse);
      expect(MutationRule.author.isAuthorizationState, isFalse);
      expect(MutationRule.anyUser.isAuthorizationState, isFalse);
    });
  });

  group('permittedByOwners', () {
    test('every owner is permitted, and only owners', () {
      const rule = MutationRule.projectOwner;
      Set<String> owners() => {'a', 'b'};
      expect(
        rule.permittedByOwners('a', owners: owners(), authorUserId: null),
        isTrue,
      );
      expect(
        rule.permittedByOwners('b', owners: owners(), authorUserId: null),
        isTrue,
      );
      expect(
        rule.permittedByOwners('c', owners: owners(), authorUserId: null),
        isFalse,
      );
      expect(
        rule.permittedByOwners(null, owners: owners(), authorUserId: null),
        isFalse,
      );
      // And the pure ownership rules ignore the author argument entirely —
      // naming `c` on the row does not make `c` an owner.
      expect(
        rule.permittedByOwners('c', owners: owners(), authorUserId: 'c'),
        isFalse,
      );
    });

    test('an unresolvable project permits; a project with no owners does not', () {
      // The distinction the whole bootstrap story rests on. Null is "there is
      // no such project here yet" — a first publish authorizes every row of
      // its batch before writing any of them, so the `Projects` row is not
      // stored when its `Project_Memberships` row is judged. Empty is "the
      // project resolved and named nobody", which must deny.
      expect(
        MutationRule.projectOwner.permittedByOwners(
          'a',
          owners: null,
          authorUserId: null,
        ),
        isTrue,
      );
      expect(
        MutationRule.projectOwner.permittedByOwners(
          'a',
          owners: const {},
          authorUserId: null,
        ),
        isFalse,
      );
    });
  });

  /// Task 11.15 — the rule table's first disjunction, unit-tested here on its
  /// own before the two enforcement layers exercise it against a database.
  group('authorOrOwner (task 11.15)', () {
    const rule = MutationRule.authorOrOwner;

    test('the mark\'s own author is permitted, owner or not', () {
      expect(
        rule.permittedByOwners(
          'author',
          owners: const {'owner'},
          authorUserId: 'author',
        ),
        isTrue,
      );
    });

    test('any current project owner is permitted', () {
      expect(
        rule.permittedByOwners(
          'owner',
          owners: const {'owner', 'co-owner'},
          authorUserId: 'author',
        ),
        isTrue,
      );
      expect(
        rule.permittedByOwners(
          'co-owner',
          owners: const {'owner', 'co-owner'},
          authorUserId: 'author',
        ),
        isTrue,
      );
    });

    test('a third party who is neither is refused', () {
      expect(
        rule.permittedByOwners(
          'stranger',
          owners: const {'owner'},
          authorUserId: 'author',
        ),
        isFalse,
      );
      expect(
        rule.permittedByOwners(
          null,
          owners: const {'owner'},
          authorUserId: 'author',
        ),
        isFalse,
      );
    });

    test('an author who has left the project is still not a way in for others',
        () {
      // The case that motivates the rule, stated from the other side: the
      // author leaving widens *nothing*. It is the owner arm that lets the
      // mark be withdrawn, and a stranger gains nothing from the author being
      // gone.
      expect(
        rule.permittedByOwners(
          'owner',
          owners: const {'owner'},
          authorUserId: 'departed',
        ),
        isTrue,
      );
      expect(
        rule.permittedByOwners(
          'stranger',
          owners: const {'owner'},
          authorUserId: 'departed',
        ),
        isFalse,
      );
    });

    test('a project with no owners still lets the author withdraw', () {
      // Empty owners denies for the pure ownership rules. Here the author arm
      // survives it: a project that somehow resolved to no owners must not
      // strand the one person who is unambiguously entitled.
      expect(
        rule.permittedByOwners(
          'author',
          owners: const {},
          authorUserId: 'author',
        ),
        isTrue,
      );
      expect(
        rule.permittedByOwners(
          'stranger',
          owners: const {},
          authorUserId: 'author',
        ),
        isFalse,
      );
    });

    test('an unresolvable project permits, exactly as for the other rules', () {
      expect(
        rule.permittedByOwners(
          'stranger',
          owners: null,
          authorUserId: 'author',
        ),
        isTrue,
      );
    });

    test('a row naming nobody permits, on permits\' stated contract', () {
      expect(
        rule.permittedByOwners(
          'stranger',
          owners: const {'owner'},
          authorUserId: null,
        ),
        isTrue,
      );
    });
  });

  test('the tables holding personal data are author-governed', () {
    // Users and User_Emails are global (no project_id), so they are the rows
    // most exposed to a cross-tenant write. If one of these ever becomes
    // anyUser, any authenticated caller could rewrite anyone's profile.
    expect(tableMutationRules[Tables.users], MutationRule.author);
    expect(tableMutationRules[Tables.userEmails], MutationRule.author);
    expect(tableMutationRules[Tables.observations], MutationRule.author);
    // Task 11.15: the marks that take an observation out of analysis are the
    // one table where the author is not the only legitimate authority — an
    // owner must be able to undo a mark whose author has left.
    expect(
      tableMutationRules[Tables.observationExclusions],
      MutationRule.authorOrOwner,
    );
    expect(tableMutationRules[Tables.nonDetections], MutationRule.author);
  });

  // **Task 11.93 was explicitly forbidden to tighten this, so it is asserted
  // rather than left to the next reader's judgement.**
  //
  // That task gave `Actual_Tag_Locations` a `user_id` — who walked in and found
  // the collar. Every other table with an identity column is author-governed,
  // so the obvious next step is to make editing a truth point author-only, and
  // it is wrong. Michael settled it on 2026-08-31: **the person who saw the
  // pride and the person driving the truck may not be the same person**, and a
  // point nobody but the finder can correct is a point the finder cannot get
  // corrected from the passenger seat. `user_id` is a fact about the record,
  // not a permission.
  test('recording who found a truth point did not make editing author-only',
      () {
    expect(
      tableMutationRules[Tables.actualTagLocations],
      MutationRule.anyUser,
      reason: 'a truth point names its finder and is still writable by any '
          'contributor on the project — see task 11.93, and '
          'truth_point_lifecycle_test.dart, which asserts the same thing '
          'against a real database',
    );
  });

  test('membership rows are projectOwner-governed', () {
    // Anything weaker is privilege escalation: a contributor could grant
    // themselves a different role (task 8.4).
    expect(
      tableMutationRules[Tables.projectMemberships],
      MutationRule.projectOwner,
    );
  });

  group('an edited-by name replicates where an authored-by name does not '
      '(task 11.47)', () {
    // **This group asserts the *premise* of task 11.47's argument, not its
    // conclusion.** The conclusion — "these six tables are relaxed" — is a
    // list, and a list is what this project keeps finding as the defect. The
    // premise is what makes the relaxation safe, and it is checkable:
    //
    //   a table whose audit name may be replicated has no identity column at
    //   all, so the relaxation cannot reach a column that says who a record
    //   is *about*.
    //
    // A future table that breaks that premise fails here, and whoever added
    // it has to re-read the argument rather than inherit its conclusion.

    // **This tripwire fired on 2026-08-31, exactly as it was built to.**
    //
    // Task 11.47's premise was "a table whose audit name may be replicated has
    // no identity column at all", asserted as `identityUserColumns` being
    // empty on every relaxed table. Task 11.93 gave `Actual_Tag_Locations` a
    // `user_id` — who walked in and found the collar — while Michael
    // explicitly forbade tightening its `anyUser` write rule, so that table is
    // relaxed *and* names somebody, and the old assertion was red.
    //
    // Whoever changed it re-read the argument rather than inheriting its
    // conclusion, which is what the reason string asked for. The conclusion
    // survives; the premise moved one level down. What made the relaxation
    // safe was never "the table has no identity column" — it was "the
    // relaxation cannot reach an identity column", and that is now enforced
    // per column by `SyncTable.vouchesForAForeignNameIn` instead of being an
    // accident of which tables existed.
    //
    // So this test asserts the *property*, on every table, rather than the
    // shape of the table set: the audit column may be replicated where the
    // rule says so, and an identity column may never be.
    test('the audit relaxation can never reach a column naming a person', () {
      final relaxed = [
        for (final table in syncTables)
          if (tableMutationRules[table.name]!.replicatesAForeignAuditName)
            table,
      ];
      // Not an empty set — a guard that passes because it measures nothing is
      // the failure mode this project names explicitly.
      expect(relaxed, isNotEmpty);
      // Nor is the interesting case absent: at least one relaxed table does
      // name somebody, so the per-column line below is being exercised rather
      // than being vacuously true the way the old table-level one was.
      expect(
        relaxed.where((t) => t.identityUserColumns.isNotEmpty),
        isNotEmpty,
        reason:
            'No relaxed table names anybody, so this test proves only what '
            'the old table-level assertion did. Task 11.93 put '
            'Actual_Tag_Locations in that set; if it has left, check whether '
            'this test still measures the property it claims to.',
      );
      for (final table in relaxed) {
        // The audit column is the relaxation, on every relaxed table.
        expect(table.vouchesForAForeignNameIn(auditUserColumn), isTrue);
        for (final column in table.identityUserColumns) {
          expect(
            table.vouchesForAForeignNameIn(column),
            isFalse,
            reason:
                '${table.name}.$column says who a record is *about*, and this '
                'table may replicate a foreign audit name. If clause 2 could '
                'vouch for it, a contributor could sign a colleague\'s name '
                'to a record that person never made — finding N-1, which task '
                '11.24 closed.',
          );
        }
      }
    });

    test('no identity column vouches for a foreign name, on any table', () {
      // The same property stated over the whole schema rather than over the
      // relaxed subset, so a future table inherits it by declaring an identity
      // column rather than by anybody noticing.
      for (final table in syncTables) {
        for (final column in table.identityUserColumns) {
          expect(
            table.vouchesForAForeignNameIn(column),
            isFalse,
            reason: '${table.name}.$column may name somebody who is not the '
                'caller. A record that names an author must name the caller '
                '(task 11.24).',
          );
        }
      }
    });

    test('no table that names an author relaxes its audit column', () {
      // The half that keeps task 11.24 (finding N-1) intact, and with it
      // task 11.18's "...then withdrawn by name" sentence: a record naming
      // its author must still name the caller, audit column included.
      for (final table in syncTables) {
        final rule = tableMutationRules[table.name]!;
        if (!rule.namesRowAuthor) continue;
        expect(
          rule.replicatesAForeignAuditName,
          isFalse,
          reason:
              '${table.name} names an author, so its audit column must stay '
              'checked — an unforgeable "who changed this" is what task '
              '11.24 bought.',
        );
      }
    });

    test('no authorization-state table relaxes its audit column', () {
      for (final table in syncTables) {
        final rule = tableMutationRules[table.name]!;
        if (!rule.isAuthorizationState) continue;
        expect(rule.replicatesAForeignAuditName, isFalse);
      }
    });

    test('field-data tables are untouched, which is the accepted outcome', () {
      // Michael's decision of 2026-08-28: a record restored from a
      // colleague's archive keeps their name. These three are where that
      // decision bites, and task 11.47 deliberately does not move them.
      for (final name in [
        Tables.observations,
        Tables.nonDetections,
        Tables.observationExclusions,
      ]) {
        expect(
          tableMutationRules[name]!.replicatesAForeignAuditName,
          isFalse,
          reason: '$name is field data; 11.47 must not have widened it',
        );
      }
    });
  });
}
