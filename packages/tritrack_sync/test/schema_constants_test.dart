import 'package:test/test.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

void main() {
  group('Tables', () {
    // **Twelve since task 11.219 retired `Project_Tags` from the wire**;
    // thirteen from 11.32, which added `Tag_Versions`. The count is asserted
    // rather than derived on purpose: adding a synced table is a decision with
    // a migration, a mutation rule, a global scope, a server schema, a
    // validator case, an existence-oracle probe and a permissions-matrix row
    // attached, and this test is the reminder that all of them are owed —
    // and **removing** one owes exactly the same list in reverse, which is
    // why the number moves down rather than the assertion being relaxed. It
    // is also the tripwire for the drift task 11.21 found the hard way — a
    // stale table count that four documents and two gate instruments had
    // copied.
    test('all lists exactly the fourteen schema tables', () {
      // Twelve until task 11.240 added `Individuals`; thirteen until 11.243
      // added `Deployments`.
      expect(Tables.all, hasLength(14));
      expect(Tables.all.toSet(), hasLength(14), reason: 'no duplicate names');
    });

    test('Individuals is created before the tables that name it', () {
      // Task 11.240, narrowed by 11.243. `Tags.individual_id` is gone; the
      // reference into `Individuals` is `Deployments.individual_id` now, and
      // this order is what the merger inserts in and what the publisher
      // offers in — so an animal named in the same push as the deployment
      // that links it is already there when the deployment arrives.
      expect(
        Tables.all.indexOf(Tables.individuals),
        lessThan(Tables.all.indexOf(Tables.deployments)),
      );
      expect(
        Tables.all.indexOf(Tables.individuals),
        greaterThan(Tables.all.indexOf(Tables.projects)),
        reason: 'and after the project it is scoped to',
      );
    });

    test('Deployments is created after both rows it joins', () {
      // Task 11.243. Its foreign keys are composite into `Tags` and
      // `Individuals`; the merger inserts parents first.
      expect(
        Tables.all.indexOf(Tables.deployments),
        greaterThan(Tables.all.indexOf(Tables.tags)),
      );
      expect(
        Tables.all.indexOf(Tables.deployments),
        greaterThan(Tables.all.indexOf(Tables.individuals)),
      );
    });

    test('Tag_Versions is created after the Tags it references', () {
      expect(
        Tables.all.indexOf(Tables.tagVersions),
        greaterThan(Tables.all.indexOf(Tables.tags)),
        reason:
            'Tag_Versions.tag_id has a foreign key into Tags, and this '
            'order is what the merger inserts in — and what RowAuthorizer '
            'authorizes a push in, so a tag created in the same push is '
            'already established when its first version is looked at',
      );
    });

    test('no table is offered before the row that vouches for it', () {
      // Task 11.43, reopened. FK-safety alone put `Tag_Versions` right after
      // `Tags`, which was FK-correct and offer-wrong: a publish sends one
      // table per HTTP request, so the only thing that vouched for a tag in a
      // later request was a *committed* `Project_Tags` link.
      //
      // **Task 11.219 removed the constraint by removing global tags**, so
      // the concrete `Project_Tags` assertion that used to stand here has
      // nothing left to say. The derived property does, and it is the one
      // worth keeping where somebody editing this list will read it — see
      // `offer_order_test.dart`, which also watches it refuse a bad order.
      expect(assertOfferOrderEstablishesReachBeforeItIsNeeded, returnsNormally);
      expect(Tables.all, isNot(contains(Tables.projectTags)));
    });

    test('Users is created before every table that references it', () {
      // Cheap FK-order sanity check: Users has no dependency and must sort
      // first among tables that reference user rows.
      expect(Tables.all.indexOf(Tables.users), 0);
    });
  });

  group('latestSchemaVersion', () {
    test('is a positive, single authoritative value', () {
      expect(latestSchemaVersion, greaterThan(0));
    });
  });

  group('schemaMajorFirstMinor', () {
    // Task 11.242. The history of the compatibility boundary as data, so the
    // shell scripts that must name a major without a compiler can be checked
    // against it (`server/test/security/shipped_defaults_test.dart`) instead
    // of carrying it as thresholds somebody types — which is how all three
    // of them were still saying "2" a week after major 3 shipped.
    test('names every major from 1 to the current one, consecutively', () {
      expect(
        schemaMajorFirstMinor.keys.toList(),
        List.generate(schemaMajorVersion, (i) => i + 1),
      );
    });

    test('majors begin at strictly increasing minors, within the schema', () {
      final starts = schemaMajorFirstMinor.values.toList();
      for (var i = 1; i < starts.length; i++) {
        expect(starts[i], greaterThan(starts[i - 1]));
      }
      expect(starts.first, 1, reason: 'major 1 is where the schema begins');
      expect(starts.last, lessThanOrEqualTo(latestSchemaVersion));
    });

    test('schemaMajorFor is the lookup the scripts perform', () {
      expect(schemaMajorFor(1), 1);
      expect(schemaMajorFor(5), 1);
      expect(schemaMajorFor(6), 2, reason: 'task 10.35');
      expect(schemaMajorFor(13), 2);
      expect(schemaMajorFor(14), 3, reason: 'task 11.219');
      expect(schemaMajorFor(15), 3);
      expect(schemaMajorFor(16), 4, reason: 'task 11.242, for 11.240');
      expect(
        schemaMajorFor(latestSchemaVersion),
        schemaMajorVersion,
        reason: 'the current schema is on the current major',
      );
    });
  });
}
