import 'package:test/test.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

/// Task 11.43, reopened. The order a device offers tables in is a property of
/// `Tables.all`, and this is where it is checked rather than commented.
///
/// **Task 11.219 took the rule's only real subject away.** Tags were the one
/// reach set with a link table — `Project_Tags`, whose committed row was the
/// only thing that vouched for a tag in a later HTTP request — and copy-on-add
/// made tags project-scoped, so nothing in `syncTables` has that shape today.
///
/// So this file now has two halves, and the split is deliberate:
///
/// 1. **What is true of the shipped declarations** — which is that the rule
///    constrains nothing, said out loud rather than left to be discovered.
/// 2. **That the rule still refuses the thing it is for**, exercised against a
///    deliberately doctored corpus carrying the shape the real one has lost.
///    A guard nobody has watched fail is not a guard, and a guard whose
///    subject has gone away cannot be watched failing against the real corpus
///    at all — which is exactly why `assertOfferOrderEstablishesReachBeforeIt
///    IsNeeded` takes a `tables` parameter.
void main() {
  /// A minimal reconstruction of the shape the rule exists for: a reach set
  /// with a subject, a link table keyed `(project, id)`, and a third table
  /// that merely *names* the id and therefore has to wait for the link.
  ///
  /// Built out of the `users` reach set because that is the only one left —
  /// the point is the *shape*, not which id kind fills it.
  const subject = SyncTable(
    name: Tables.users,
    primaryKey: ['user_id'],
    insertIsAGrant: false,
    archiveDisclosure: ArchiveDisclosure.carried,
    globalScope: GlobalScope(column: 'user_id', reach: GlobalReachSet.users),
    userColumns: ['user_id', auditUserColumn],
  );
  const link = SyncTable(
    name: Tables.projectMemberships,
    primaryKey: ['project_id', 'user_id'],
    insertIsAGrant: true,
    archiveDisclosure: ArchiveDisclosure.carried,
    projectScopeColumn: 'project_id',
    userColumns: ['user_id', auditUserColumn],
  );
  const namesTheId = SyncTable(
    name: Tables.observations,
    primaryKey: ['observation_id', 'project_id'],
    insertIsAGrant: false,
    archiveDisclosure: ArchiveDisclosure.carried,
    projectScopeColumn: 'project_id',
    userColumns: ['user_id', auditUserColumn],
  );
  const doctored = [subject, link, namesTheId];

  group('the shipped declarations', () {
    test('no reach set has a link table any more, and that is task 11.219', () {
      // Said as an assertion rather than left implicit: if a link table ever
      // comes back, this fails and whoever added it reads the rest of this
      // file and finds out what ordering it now owes.
      for (final reach in GlobalReachSet.values) {
        expect(
          reachLinkTableFor(reach),
          isNull,
          reason:
              'a link table for ${reach.name} reintroduces the ordering '
              'constraint task 11.43 reopened over — see offer_order.dart',
        );
      }
    });

    test('Tables.all as shipped satisfies the rule', () {
      expect(assertOfferOrderEstablishesReachBeforeItIsNeeded, returnsNormally);
    });

    test('Users is the subject of the user set; User_Emails only names one', () {
      expect(
        isReachSubject(syncTablesByName[Tables.users]!, GlobalReachSet.users),
        isTrue,
      );
      expect(
        isReachSubject(
          syncTablesByName[Tables.userEmails]!,
          GlobalReachSet.users,
        ),
        isFalse,
      );
    });

    test('User_Emails needs no established reach: it only names the caller', () {
      // Not because it is unreachable-proof, but because
      // `namingRequirementsForOffering` already stops the device offering
      // anybody else's — so §4.17 clause 1 vouches for every row it sends.
      expect(
        namingRequirementsForOffering(syncTablesByName[Tables.userEmails]!),
        isNotEmpty,
      );
      expect(
        tableNeedsEstablishedReach(
          syncTablesByName[Tables.userEmails]!,
          GlobalReachSet.users,
        ),
        isFalse,
      );
    });

    test('a colleague\'s bearing still needs reach, and is still offered', () {
      // The refusal §4.17 accepts. Ordering does not change it, which is why
      // the rule constrains only reach sets with a link table.
      expect(
        tableNeedsEstablishedReach(
          syncTablesByName[Tables.observations]!,
          GlobalReachSet.users,
        ),
        isTrue,
      );
      expect(reachLinkTableFor(GlobalReachSet.users), isNull);
    });

    test('a tag-bearing row is nobody\'s ordering problem now', () {
      // The positive statement of what copy-on-add bought: `Tag_Versions` was
      // the row task 11.43 reopened over, and it is project-scoped, so the
      // question "is this tag reachable yet" is not asked of it at all.
      final tagVersions = syncTablesByName[Tables.tagVersions]!;
      expect(tagVersions.projectScopeColumn, 'project_id');
      expect(tagVersions.globalScope, isNull);
      for (final reach in GlobalReachSet.values) {
        expect(tableNeedsEstablishedReach(tagVersions, reach), isFalse);
      }
    });
  });

  group('the rule still refuses what it is for', () {
    test('the doctored corpus really does have a link table', () {
      // The control on the control. If this stopped holding, the two tests
      // below would pass by measuring nothing at all — which is the failure
      // this project keeps finding in its own instruments.
      expect(
        reachLinkTableFor(GlobalReachSet.users, tables: doctored)?.name,
        Tables.projectMemberships,
      );
      expect(
        tableNeedsEstablishedReach(
          namesTheId,
          GlobalReachSet.users,
          tables: doctored,
        ),
        isTrue,
      );
    });

    test('a correct order passes', () {
      expect(
        () => assertOfferOrderEstablishesReachBeforeItIsNeeded(
          order: const [
            Tables.users,
            Tables.projectMemberships,
            Tables.observations,
          ],
          tables: doctored,
        ),
        returnsNormally,
      );
    });

    test('the row that names the id before the link that vouches is refused',
        () {
      expect(
        () => assertOfferOrderEstablishesReachBeforeItIsNeeded(
          order: const [
            Tables.users,
            Tables.observations,
            Tables.projectMemberships,
          ],
          tables: doctored,
        ),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            allOf(
              contains(Tables.observations),
              contains(Tables.projectMemberships),
              // The message has to say what to do, not only that something is
              // wrong — five lines of CI tail is enough exactly when the last
              // thing an instrument says is what it found.
              contains('Move'),
            ),
          ),
        ),
      );
    });
  });
}
