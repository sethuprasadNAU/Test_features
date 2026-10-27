import 'package:test/test.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

void main() {
  group('syncTables', () {
    test('has exactly one descriptor per table in Tables.all, same order', () {
      expect(syncTables.map((t) => t.name).toList(), Tables.all);
    });

    test('syncTablesByName covers every table with no duplicates', () {
      expect(syncTablesByName.keys.toSet(), Tables.all.toSet());
      expect(syncTablesByName, hasLength(Tables.all.length));
    });

    test('every descriptor has a non-empty primary key', () {
      for (final t in syncTables) {
        expect(
          t.primaryKey,
          isNotEmpty,
          reason: '${t.name} has no primary key',
        );
      }
    });

    test('a key is composite exactly when the table is project-scoped', () {
      // Task 10.35 (schema major 2) turned this from "one junction table is
      // special" into a rule: a row that lives inside a project is identified
      // by its id *and* that project, because the same id may legitimately
      // appear in another project — which is what makes a shared observation
      // importable into the receiver's own project.
      //
      // The exception is `Projects` itself: its id *is* the scope, so scoping
      // it to itself would be circular. `Users`, `User_Emails` and `Tags` are
      // global — they carry no project column at all — and stay single-keyed.
      for (final t in syncTables) {
        final projectScoped =
            t.projectScopeColumn != null && t.name != Tables.projects;
        expect(t.isComposite, projectScoped, reason: t.name);
        if (projectScoped) {
          // Position differs — `Project_Tags` leads with it, the six re-keyed
          // tables trail with it (see the next test) — but every scoped key
          // contains it.
          expect(
            t.primaryKey,
            contains('project_id'),
            reason: '${t.name}: the scope column completes the key',
          );
        }
      }
    });

    test('the id leads the key and the scope follows', () {
      // Deliberate, and the opposite of how it reads. The leading column of a
      // key is the one its index can be searched on alone, and by-id lookup is
      // the query this schema runs most — every by-id repository helper does
      // exactly that. `Project_Tags` is the one genuine pair, where neither
      // half is "the id", so it is exempt.
      for (final t in syncTables) {
        if (!t.isComposite || t.name == Tables.projectTags) continue;
        expect(t.primaryKey.first, isNot('project_id'), reason: t.name);
        expect(t.primaryKey, hasLength(2), reason: t.name);
      }
    });

    test('every user column list includes last_modified_by', () {
      for (final t in syncTables) {
        expect(t.userColumns, contains('last_modified_by'));
      }
    });

    test('every identity email column has exactly one subject', () {
      // The server resolves a pushed address to a `user_id` before asking
      // whether it ever authenticated it (task 10.55). A table with two
      // subjects, or none, leaves that unanswerable — and the runtime answer is
      // a refusal, which would show up as an unexplained sync failure rather
      // than as this.
      expect(assertEveryEmailColumnHasASubject, returnsNormally);
    });

    test('the identity email columns are the two identity tables', () {
      // Pinned rather than derived: adding a third is a decision about what the
      // client's dedup will believe, and it should be made here deliberately.
      expect(
        {
          for (final t in syncTables)
            if (t.emailColumns.isNotEmpty) t.name: t.emailColumns,
        },
        {
          Tables.users: ['email'],
          Tables.userEmails: ['email'],
        },
      );
    });

    test('the tables where creating a row is itself a grant are the two '
        'that carry a permission', () {
      // Task 11.3. Pinned rather than derived, for the same reason the email
      // columns above are: adding a table here, or failing to, is a decision
      // about who may hand out access. `SyncTable.insertIsAGrant` is required
      // on every descriptor so the decision cannot be made by omission, and
      // this is where the answers are reviewable as a set.
      //
      // - `Projects` — creating one makes you its owner.
      // - `Project_Memberships` — the insert *is* the grant.
      //
      // **`Project_Tags` was the third and left with the wire (task
      // 11.219).** It was the link that made a *global* tag readable by
      // everyone in a project; under copy-on-add adding a tag creates a row
      // inside a project the caller is already in, which widens nothing.
      expect(
        {
          for (final t in syncTables)
            if (t.insertIsAGrant) t.name,
        },
        {Tables.projects, Tables.projectMemberships},
      );
    });

    group('every global table declares how it narrows to a project '
        '(task 11.32)', () {
      test('the real descriptors pass', () {
        expect(assertEveryGlobalTableDeclaresItsScope, returnsNormally);
      });

      test('a reach set maps to exactly one column list (task 11.41)', () {
        // `reachColumnsFor` is now the single answer to "which columns fill
        // this reachable-id set", read by the server's `ProjectReachability`
        // on the way out and by the client's push selection on the way in. If
        // the two ever disagreed, the client would offer rows the server is
        // bound to refuse — and every refusal becomes a record the device
        // holds and reports as "not on the server" forever, which is exactly
        // what task 11.41 was opened for.
        //
        // Pinned against the underlying column lists, so this also stands as
        // the check on the server edit that replaced them with this call.
        for (final table in syncTables) {
          expect(
            reachColumnsFor(table, GlobalReachSet.users),
            table.identityUserColumns,
            reason: '${table.name}: the user reach set must exclude '
                '$auditUserColumn — an audit column any caller may set is not '
                'a reachability edge',
          );
        }
      });

      test('no reach set is filled by no column at all', () {
        // A reach set nothing feeds would narrow every global table using it
        // to nothing — on the server a table that silently never delivers, on
        // the client a table that silently never uploads. Both are the failure
        // this group exists for, one level up from a missing declaration.
        for (final reach in GlobalReachSet.values) {
          final columns = [
            for (final table in syncTables)
              if (table.projectScopeColumn != null)
                ...reachColumnsFor(table, reach),
          ];
          expect(
            columns,
            isNotEmpty,
            reason: 'no project-scoped table feeds $reach',
          );
        }
      });

      test('and the two global tables are the ones that declare one', () {
        // Pinned rather than derived: a third global table is a decision about
        // what a project may see of it, and should be made deliberately here.
        //
        // **There were four until task 11.219.** `Tags` and `Tag_Versions`
        // were the other two; copy-on-add gave both a `project_id`, so they
        // narrow by scope like the other nine and reachability is not asked
        // about them at all.
        expect(
          {
            for (final t in syncTables)
              if (t.globalScope != null)
                t.name: (t.globalScope!.column, t.globalScope!.reach),
          },
          {
            Tables.users: ('user_id', GlobalReachSet.users),
            Tables.userEmails: ('user_id', GlobalReachSet.users),
          },
        );
      });

      test('a global table with no scope fails — the silent-never-syncs case',
          () {
        // The positive control, and the failure it exists to catch. Before
        // task 11.32 this lived in a hand-written map on the server whose miss
        // branch was `continue`, so a global table nobody had added was never
        // delivered by pull at all: no error, no log, nothing to notice.
        expect(
          () => assertEveryGlobalTableDeclaresItsScope(
            tables: const [
              SyncTable(
                name: Tables.users,
                primaryKey: ['user_id'],
                insertIsAGrant: false,
                archiveDisclosure: ArchiveDisclosure.carried,
                userColumns: ['user_id'],
              ),
            ],
          ),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              contains('never delivered by pull'),
            ),
          ),
        );
      });

      test('declaring both scopes fails, and so does naming a column the '
          'table does not have', () {
        expect(
          () => assertEveryGlobalTableDeclaresItsScope(
            tables: const [
              SyncTable(
                name: Tables.users,
                primaryKey: ['user_id'],
                insertIsAGrant: false,
                archiveDisclosure: ArchiveDisclosure.carried,
                projectScopeColumn: 'project_id',
                globalScope: GlobalScope(
                  column: 'user_id',
                  reach: GlobalReachSet.users,
                ),
              ),
            ],
          ),
          throwsStateError,
        );
        expect(
          () => assertEveryGlobalTableDeclaresItsScope(
            tables: const [
              SyncTable(
                name: Tables.users,
                primaryKey: ['user_id'],
                insertIsAGrant: false,
                archiveDisclosure: ArchiveDisclosure.carried,
                globalScope: GlobalScope(
                  // A typo would narrow every page to nothing and read
                  // exactly like a table with no rows in it.
                  column: 'userid',
                  reach: GlobalReachSet.users,
                ),
              ),
            ],
          ),
          throwsStateError,
        );
      });
    });

    test('no sealed column feeds reachability', () {
      // The tripwire on Security Model §5.9(b)'s acceptance. Those two columns
      // are free-text delimited id lists with no foreign key on either side,
      // accepted **on the condition** that nothing computed from them decides
      // which rows a pull delivers. Folding one into a declared column set
      // would turn every value ever written into a cross-project disclosure
      // vector on the day that computation shipped. Whoever trips this owes
      // the column a real reachability check first.
      //
      // Task 11.219 widened the same assertion to the **provenance** columns
      // it added — `Tags.lineage_id` and `Tags.copied_at`. Different reason,
      // identical mechanism: §2.3 of `TAG_COPY_ON_ADD_DESIGN.md` requires that
      // nothing live ever reads a tag's lineage, and the one-line edit that
      // would make that false is the same one-line edit — putting the column
      // name in a declared set.
      expect(assertSealedColumnsFeedNoReachability, returnsNormally);
    });

    test('and the tripwire actually fires', () {
      // A positive control, in the same run. An assertion nobody has watched
      // fail is an assertion nobody knows works — eight consecutive security
      // gates found the instruments to be the most dangerous thing in the room,
      // and the last one caught three of its own probes measuring nothing.
      expect(unvalidatedIdListColumns, {
        Tables.nonDetections: 'tag_ids_listened_for',
        Tables.estimatedPositions: 'observation_ids_used',
      });
      // The columns it names have to be real ones, or it is watching a name
      // that no longer exists and will never fire again.
      for (final entry in unvalidatedIdListColumns.entries) {
        final spec = tableSpecsByName[entry.key]!;
        expect(
          spec.columns.map((c) => c.name),
          contains(entry.value),
          reason: '${entry.key}.${entry.value} is not a real column',
        );
      }
      // And the failure it exists to catch: the day somebody declares one of
      // them as a tag column so a "which tags did this depend on" feature can
      // read it project-scoped.
      expect(
        () => assertSealedColumnsFeedNoReachability(
          tables: const [
            SyncTable(
              name: Tables.nonDetections,
              primaryKey: ['non_detection_id', 'project_id'],
              insertIsAGrant: false,
              archiveDisclosure: ArchiveDisclosure.carried,
              projectScopeColumn: 'project_id',
              tagColumns: ['tag_ids_listened_for'],
            ),
          ],
        ),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('§5.9(b)'),
          ),
        ),
      );
    });

    test('the lineage half of the tripwire fires too, and says so', () {
      // Task 11.219's positive control, in the same run as the assertion it
      // guards — the brief's requirement, and this project's standing one.
      //
      // The columns it names have to be real ones, or it is watching a name
      // that no longer exists and will never fire again.
      expect(provenanceColumns, {
        Tables.tags: ['lineage_id', 'copied_at'],
        // Task 11.240: an individual's lineage is sealed for the same reason.
        Tables.individuals: ['lineage_id', 'copied_at'],
        // Task 11.56: and a project's, which says which projects are seasons
        // of one study.
        Tables.projects: ['lineage_id', 'copied_at'],
      });
      for (final entry in provenanceColumns.entries) {
        final spec = tableSpecsByName[entry.key]!;
        for (final column in entry.value) {
          expect(
            spec.columns.map((c) => c.name),
            contains(column),
            reason: '${entry.key}.$column is not a real column',
          );
        }
      }
      // And they are declared `provenance`, which is what says a version row
      // never carries them and no screen resolves one.
      for (final column in provenanceColumns[Tables.tags]!) {
        expect(tagColumnKinds[column], TagColumnKind.provenance);
        expect(versionedTagColumnNames, isNot(contains(column)));
      }
      // The failure it exists to catch: somebody wiring lineage into a reach
      // set so that "find this collar in my other projects" can be a query.
      expect(
        () => assertSealedColumnsFeedNoReachability(
          tables: const [
            SyncTable(
              name: Tables.tags,
              primaryKey: ['tag_id', 'project_id'],
              insertIsAGrant: false,
              archiveDisclosure: ArchiveDisclosure.carried,
              projectScopeColumn: 'project_id',
              tagColumns: ['tag_id', 'lineage_id'],
            ),
          ],
        ),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            allOf(
              contains('lineage_id'),
              // It has to say what to do instead, not only that this is
              // wrong: an instrument's last words must be a finding.
              contains('belongs in an export'),
            ),
          ),
        ),
      );
    });
  });
}
