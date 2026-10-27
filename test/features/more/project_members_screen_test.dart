import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tritrack/core/providers/app_context_provider.dart';
import 'package:tritrack/data/repositories/project_standing.dart';
import 'package:tritrack/core/providers/database_provider.dart';
import 'package:tritrack/core/providers/membership_provider.dart';
import 'package:tritrack/data/db/app_database.dart';
import 'package:tritrack/data/models/project_membership.dart';
import 'package:tritrack/data/models/sync_meta.dart';
import 'package:tritrack/features/more/screens/project_members_screen.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

import '../../data/fixtures.dart';
import '../../support/fake_shared_preferences.dart';

/// **Tasks 11.2 and 11.81 — the owner's dashboard, the join code, and the
/// disclosure that is a condition of the feature rather than copy.**
///
/// Phase 11 accepted a real tradeoff: removing a member stops their future
/// syncs and blocks server access, and cannot delete the project data already
/// on their device. That was accepted **conditional on the owner being told at
/// the moment somebody is let in** — because for a project tracking a
/// poaching-target species, exact historical locations in a departed member's
/// offline copy are a genuine exposure.
///
/// **Task 11.81 moved where that moment is, and these tests moved with it.**
/// Handing out a join code no longer admits anybody, so the disclosure gates
/// *approval* and *re-admission* instead of the old invite sheet. The
/// assertions below are the same two they always were — the sentence is on
/// screen, and it gates the action — asked of the action that now grants.
void main() {
  const projectId = 'project-1';
  const owner = 'user-owner';

  setUp(installFakeSharedPreferences);

  Future<ProviderContainer> seed({
    required String signedInAs,
    required List<ProjectMembership> memberships,
    Map<String, String> extraUsers = const {},
    JoinSettings? joinSettings,
    List<JoinRequestSummary> joinRequests = const [],
  }) async {
    final project = sampleProject(id: projectId, ownerUserId: owner);
    final container = ProviderContainer(
      overrides: [
        appDatabaseProvider.overrideWith((ref) => AppDatabase.openInMemory()),
        currentUserProvider.overrideWith(
          (ref) async => sampleUser(id: signedInAs, email: '$signedInAs@x.com'),
        ),
        // The join code and the pending list are the two things on this screen
        // that need a server. Overridden here so these cases exercise the
        // offline half, which is the half that has to keep working in a truck.
        projectJoinSettingsProvider(projectId).overrideWith(
          (ref) async =>
              joinSettings ??
              const JoinSettings(
                projectId: projectId,
                // **Off, which is what a project with no settings row
                // reports** — every project that existed before task 11.81.
                joiningEnabled: false,
                teamSizeLimit: 50,
                memberCount: 1,
                pendingCount: 0,
              ),
        ),
        projectJoinRequestsProvider(
          projectId,
        ).overrideWith((ref) async => joinRequests),
      ],
    );
    final db = (await container.read(appDatabaseProvider.future)).raw;
    for (final id in {owner, 'user-second', signedInAs}) {
      await db.insert(
        Tables.users,
        sampleUser(id: id, email: '$id@x.com').toColumns(),
      );
    }
    for (final entry in extraUsers.entries) {
      await db.insert(
        Tables.users,
        sampleUser(id: entry.key, email: entry.value).toColumns(),
      );
    }
    await db.insert(Tables.projects, project.toColumns());
    for (final membership in memberships) {
      await db.insert(Tables.projectMemberships, membership.toColumns());
    }
    // Both are database-backed and the screen shows a spinner until they
    // resolve, which `pumpAndSettle` would never settle.
    container.listen(isProjectOwnerProvider(projectId), (_, _) {});
    container.listen(projectMembershipsProvider(projectId), (_, _) {});
    // Task 11.99's "Your role" card, same treatment and same reason: it is
    // database-backed, and it renders nothing at all until the answer is
    // known rather than flickering a provisional role at somebody who came
    // here to read exactly that.
    container.listen(myProjectRoleProvider(projectId), (_, _) {});
    await container.read(isProjectOwnerProvider(projectId).future);
    await container.read(projectMembershipsProvider(projectId).future);
    await container.read(myProjectRoleProvider(projectId).future);
    return container;
  }

  ProjectMembership membership(
    String id, {
    required String userId,
    ProjectRole role = ProjectRole.owner,
    DateTime? endDate,
  }) => ProjectMembership(
    membershipId: id,
    projectId: projectId,
    userId: userId,
    // **An evening on the device's own clock (task 11.326)**, because a join
    // date is the instant somebody joined, not a day: UTC midnight was the
    // one value whose UTC day and local day agree west of UTC, which is how
    // a screen printing the UTC day passed here for as long as it did.
    joinDate: DateTime(2026, 8, 1, 19),
    endDate: endDate,
    role: role,
    sync: SyncMeta.initial(now: DateTime.utc(2026, 8, 1), modifiedBy: userId),
  );

  JoinRequestSummary request({
    String id = 'req-1',
    String email = 'newcomer@example.org',
    String? claimedName,
  }) => JoinRequestSummary(
    requestId: id,
    projectId: projectId,
    email: email,
    claimedName: claimedName,
    requestedAt: DateTime.utc(2026, 8, 20).toIso8601String(),
  );

  Future<void> pump(WidgetTester tester, ProviderContainer container) async {
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: ProjectMembersScreen(projectId: projectId),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// Scrolls the member list until [finder] is built and on screen.
  ///
  /// `ensureVisible` cannot reach a widget a lazy `ListView` has not built yet,
  /// which since task 11.99's "Your role" card includes the Past members
  /// section on an 800×600 test viewport.
  Future<void> scrollTo(WidgetTester tester, Finder finder) async {
    await tester.scrollUntilVisible(
      finder,
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
  }

  /// Scrolls [finder] into view, then taps it.
  ///
  /// **Needed since task 11.99 put the "Your role" card at the top of this
  /// screen.** The card is a few lines tall, the test viewport is 800×600, and
  /// controls near the bottom of a long member list now start below the fold —
  /// where `tap` silently misses rather than scrolling to reach them. A person
  /// scrolls; the test should too.
  Future<void> tapAfterScroll(WidgetTester tester, Finder finder) async {
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
    await tester.tap(finder);
    await tester.pumpAndSettle();
  }

  /// The action button *inside the admission sheet*.
  ///
  /// `.last` because the sheet is rendered above the list, and the tile that
  /// opened it still has its own button with the same word on it — which is
  /// itself worth having, since the label an owner taps and the label that
  /// commits should read the same.
  FilledButton actionButton(WidgetTester tester, String label) =>
      tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, label).last,
      );

  group('the removal disclosure', () {
    testWidgets('is on screen at the moment somebody is let in', (
      tester,
    ) async {
      late ProviderContainer container;
      await tester.runAsync(() async {
        container = await seed(
          signedInAs: owner,
          memberships: [membership('m-owner', userId: owner)],
          joinRequests: [request()],
        );
      });
      addTearDown(container.dispose);
      await pump(tester, container);

      await tapAfterScroll(tester, find.widgetWithText(FilledButton, 'Approve'));
      await tester.pumpAndSettle();

      expect(find.text(removalDisclosure), findsOneWidget);
      // Not a euphemism: the sentence has to say what actually stays behind.
      expect(removalDisclosure, contains('cannot delete'));
      expect(removalDisclosure, contains('already downloaded to their device'));
      expect(removalDisclosure, contains('locations'));
    });

    testWidgets('gates approval rather than sitting beside it', (tester) async {
      // **This is the part that makes it a control.** An owner who has picked a
      // role still cannot approve until they acknowledge what removal cannot
      // reach.
      late ProviderContainer container;
      await tester.runAsync(() async {
        container = await seed(
          signedInAs: owner,
          memberships: [membership('m-owner', userId: owner)],
          joinRequests: [request()],
        );
      });
      addTearDown(container.dispose);
      await pump(tester, container);

      await tapAfterScroll(tester, find.widgetWithText(FilledButton, 'Approve'));
      await tester.pumpAndSettle();

      expect(
        actionButton(tester, 'Approve').onPressed,
        isNull,
        reason: 'a role is chosen and the disclosure is unacknowledged',
      );

      await tester.tap(find.byType(Checkbox));
      await tester.pumpAndSettle();
      expect(actionButton(tester, 'Approve').onPressed, isNotNull);
    });

    testWidgets('gates re-admission too, which is the other way in', (
      tester,
    ) async {
      // **The reason this test exists.** Re-admission is a second path that
      // puts somebody onto a project, and a disclosure that gates only one of
      // two doors is not a condition of the feature — it is a habit.
      late ProviderContainer container;
      await tester.runAsync(() async {
        container = await seed(
          signedInAs: owner,
          memberships: [
            membership('m-owner', userId: owner),
            membership(
              'm-second',
              userId: 'user-second',
              role: ProjectRole.contributor,
              endDate: DateTime(2026, 9, 1, 8),
            ),
          ],
        );
      });
      addTearDown(container.dispose);
      await pump(tester, container);

      await scrollTo(tester, find.byIcon(Icons.person_add_alt_1));
      await tapAfterScroll(tester, find.byIcon(Icons.person_add_alt_1));
      await tester.pumpAndSettle();

      expect(find.text(removalDisclosure), findsOneWidget);
      expect(actionButton(tester, 'Put them back').onPressed, isNull);
      await tester.tap(find.byType(Checkbox));
      await tester.pumpAndSettle();
      expect(actionButton(tester, 'Put them back').onPressed, isNotNull);
    });

    testWidgets('is repeated when somebody is actually removed', (
      tester,
    ) async {
      // The other end of the lifecycle, and the moment a person is most likely
      // to believe removal took the data back.
      late ProviderContainer container;
      await tester.runAsync(() async {
        container = await seed(
          signedInAs: owner,
          memberships: [
            membership('m-owner', userId: owner),
            membership(
              'm-second',
              userId: 'user-second',
              role: ProjectRole.contributor,
            ),
          ],
        );
      });
      addTearDown(container.dispose);
      await pump(tester, container);

      await tapAfterScroll(tester, find.byIcon(Icons.person_remove_outlined).last);
      await tester.pumpAndSettle();
      expect(find.text('Remove from project?'), findsOneWidget);
      expect(find.text(removalDisclosure), findsOneWidget);
    });
  });

  group('the pending list distinguishes what is proved from what is claimed', () {
    testWidgets(
      'the authenticated email is the title and the name is marked as a claim',
      (tester) async {
        // **Michael's decision 1, made visible.** The email is what the server
        // authenticated; the name is what the requester says they are called.
        // This is the one screen in the app where somebody decides whether to
        // trust a person by reading a string, so the two must not render as
        // equally trustworthy.
        late ProviderContainer container;
        await tester.runAsync(() async {
          container = await seed(
            signedInAs: owner,
            memberships: [membership('m-owner', userId: owner)],
            joinRequests: [
              request(email: 'f.lastname@nau.edu', claimedName: 'Dana Reyes'),
            ],
          );
        });
        addTearDown(container.dispose);
        await pump(tester, container);

        expect(find.text('f.lastname@nau.edu'), findsOneWidget);
        // The name is never rendered bare — it is always framed as a claim.
        expect(find.text('Dana Reyes'), findsNothing);
        expect(find.text('Says they are Dana Reyes'), findsOneWidget);
      },
    );

    testWidgets('a missing name renders as absent, not as a placeholder', (
      tester,
    ) async {
      // A placeholder somebody could mistake for a typed name would be worse
      // than nothing on the screen where trust is decided.
      late ProviderContainer container;
      await tester.runAsync(() async {
        container = await seed(
          signedInAs: owner,
          memberships: [membership('m-owner', userId: owner)],
          joinRequests: [request(claimedName: null)],
        );
      });
      addTearDown(container.dispose);
      await pump(tester, container);

      expect(find.text('No name given'), findsOneWidget);
      expect(find.textContaining('Says they are'), findsNothing);
      // Approval still works with no name — the email is what identifies.
      expect(find.widgetWithText(FilledButton, 'Approve'), findsOneWidget);
    });

    testWidgets('there is no bulk reject', (tester) async {
      // **Michael's reasoning, asserted so nobody adds one later as an obvious
      // convenience.** An accidental "reject all" forces every legitimate
      // requester to ask again and be contacted individually, and that accident
      // is far likelier than the flood it would defend against.
      late ProviderContainer container;
      await tester.runAsync(() async {
        container = await seed(
          signedInAs: owner,
          memberships: [membership('m-owner', userId: owner)],
          joinRequests: [
            request(id: 'req-1', email: 'one@example.org'),
            request(id: 'req-2', email: 'two@example.org'),
          ],
        );
      });
      addTearDown(container.dispose);
      await pump(tester, container);

      expect(find.widgetWithText(TextButton, 'Reject'), findsNWidgets(2));
      expect(find.textContaining('Reject all'), findsNothing);
      expect(find.textContaining('Approve all'), findsNothing);
    });
  });

  group('the join code', () {
    testWidgets('says that holding it is not the same as being on the project', (
      tester,
    ) async {
      // **The sentence the whole redesign turns on.** An owner who thinks the
      // code admits people will treat a leak as a disaster, or — worse, in the
      // other direction — hand out an approval as casually as they hand out
      // the code.
      late ProviderContainer container;
      await tester.runAsync(() async {
        container = await seed(
          signedInAs: owner,
          memberships: [membership('m-owner', userId: owner)],
          joinSettings: const JoinSettings(
            projectId: projectId,
            joiningEnabled: true,
            teamSizeLimit: 50,
            memberCount: 1,
            pendingCount: 0,
            code: 'ABCD0001',
          ),
        );
      });
      addTearDown(container.dispose);
      await pump(tester, container);

      expect(find.text('ABCD-0001'), findsOneWidget);
      expect(
        find.textContaining('only lets someone ask'),
        findsOneWidget,
      );
      // No expiry claim anywhere — a join code does not expire, and saying it
      // does would be copy describing a mechanism the code does not have.
      expect(find.textContaining('expires'), findsNothing);
    });

    testWidgets('switching joining off does not claim to clear the queue', (
      tester,
    ) async {
      // Switching off leaves pending requests alone and they can still be
      // approved. Describing it as a way to clear the queue would leave an
      // owner believing they had dismissed people they had not.
      late ProviderContainer container;
      await tester.runAsync(() async {
        container = await seed(
          signedInAs: owner,
          memberships: [membership('m-owner', userId: owner)],
        );
      });
      addTearDown(container.dispose);
      await pump(tester, container);

      expect(
        find.textContaining('stays in the list below and you can still'),
        findsOneWidget,
      );
    });

    testWidgets('the counts say that waiting people take up a place', (
      tester,
    ) async {
      // Without this, an owner reading a member count of 40 against a limit of
      // 50 cannot understand a "team is full" refusal.
      late ProviderContainer container;
      await tester.runAsync(() async {
        container = await seed(
          signedInAs: owner,
          memberships: [membership('m-owner', userId: owner)],
          joinSettings: const JoinSettings(
            projectId: projectId,
            joiningEnabled: true,
            teamSizeLimit: 50,
            memberCount: 40,
            pendingCount: 10,
            code: 'ABCD0001',
          ),
        );
      });
      addTearDown(container.dispose);
      await pump(tester, container);

      expect(find.textContaining('40 members'), findsOneWidget);
      expect(find.textContaining('10 waiting'), findsOneWidget);
      expect(find.textContaining('take up a place'), findsOneWidget);
    });

    testWidgets('rotation offers to clear pending, defaulted off', (
      tester,
    ) async {
      // **The only bulk operation in the whole design**, and it is here rather
      // than on the list precisely so it cannot be reached by mis-tapping.
      late ProviderContainer container;
      await tester.runAsync(() async {
        container = await seed(
          signedInAs: owner,
          memberships: [membership('m-owner', userId: owner)],
          joinSettings: const JoinSettings(
            projectId: projectId,
            joiningEnabled: true,
            teamSizeLimit: 50,
            memberCount: 1,
            pendingCount: 2,
            code: 'ABCD0001',
          ),
        );
      });
      addTearDown(container.dispose);
      await pump(tester, container);

      await tapAfterScroll(tester, find.widgetWithText(OutlinedButton, 'New code'));
      await tester.pumpAndSettle();

      expect(find.text('Make a new join code?'), findsOneWidget);
      expect(find.text('Also clear everyone waiting'), findsOneWidget);
      expect(
        tester.widget<Checkbox>(find.byType(Checkbox)).value,
        isFalse,
        reason: 'pending requests survive a rotation unless the owner asks',
      );
    });
  });

  group('who can manage membership', () {
    testWidgets(
      'a non-owner sees neither the join code nor the pending list, and no '
      'role control (task 11.12: disabled with a reason, not absent)',
      (tester) async {
        late ProviderContainer container;
        await tester.runAsync(() async {
          container = await seed(
            signedInAs: 'user-second',
            memberships: [
              membership('m-owner', userId: owner),
              membership(
                'm-second',
                userId: 'user-second',
                role: ProjectRole.contributor,
              ),
            ],
          );
        });
        addTearDown(container.dispose);
        await pump(tester, container);

        // **Not merely disabled — absent.** The join code is somebody else's
        // to hand out, and a greyed-out code would still be a code on screen.
        expect(find.text('Join code'), findsNothing);
        expect(find.text('Waiting to join'), findsNothing);

        for (final dropdown in tester.widgetList<DropdownButton<ProjectRole>>(
          find.byType(DropdownButton<ProjectRole>),
        )) {
          expect(dropdown.onChanged, isNull);
        }
        // Explained, not silently missing — the pattern Phase 5.2 established.
        // Task 11.138: the tooltip is the icon's *label* again, always, and
        // the reason is the line above the member list — said once, in the
        // open, where a phone can read it.
        expect(find.byTooltip('Remove from project'), findsWidgets);
        expect(
          find.text(
            'Only an owner can change a role or remove somebody. You '
            'can see who is on the project.',
          ),
          findsOneWidget,
        );
      },
    );
  });

  group('what the list shows', () {
    testWidgets('names a member by their profile, and past stints separately', (
      tester,
    ) async {
      late ProviderContainer container;
      await tester.runAsync(() async {
        container = await seed(
          signedInAs: owner,
          memberships: [
            membership('m-owner', userId: owner),
            membership(
              'm-second',
              userId: 'user-second',
              role: ProjectRole.contributor,
              endDate: DateTime(2026, 9, 1, 8),
            ),
          ],
        );
      });
      addTearDown(container.dispose);
      await pump(tester, container);

      expect(find.text('Current members'), findsOneWidget);
      // A departed member stays listed, with their stint. Their observations
      // stay in the project too, attributed to them — which is what a permit
      // report or a publication needs.
      await scrollTo(tester, find.text('Past members'));
      expect(find.text('Past members'), findsOneWidget);
      expect(find.textContaining('2026-09-01'), findsOneWidget);
      // Not a UUID. `sampleUser` gives every seeded user the same name, so the
      // assertion is that a *name* is rendered rather than the id.
      expect(find.textContaining('m-second'), findsNothing);
      expect(find.textContaining('user-second'), findsNothing);

      expect(find.byIcon(Icons.person_add_alt_1), findsOneWidget);
    });

    testWidgets(
      're-admission puts them straight back and says so, rather than sending '
      'them a code (task 11.55, re-shaped by 11.81)',
      (tester) async {
        // **What changed, and why it is better.** Before this, an owner looking
        // at a departed member's row had to open an invite sheet, retype an
        // address that was on the screen in front of them, and wait for that
        // person to redeem a code — for somebody the owner already trusts and
        // removed themselves.
        //
        // **And the control is no longer disabled when this device has no
        // address for them.** Re-admission names a `user_id`, which the
        // membership row itself carries, so the old "we cannot address an
        // invitation to them" condition simply does not arise any more.
        late ProviderContainer container;
        await tester.runAsync(() async {
          container = await seed(
            signedInAs: owner,
            extraUsers: const {'user-no-address': ''},
            memberships: [
              membership('m-owner', userId: owner),
              membership(
                'm-ghost',
                userId: 'user-no-address',
                role: ProjectRole.contributor,
                endDate: DateTime(2026, 9, 1, 8),
              ),
            ],
          );
        });
        addTearDown(container.dispose);
        await pump(tester, container);

        // Scrolled first: the Past members section is below the fold on an
        // 800×600 viewport since task 11.99's "Your role" card, and a lazy
        // `ListView` has not built a widget nobody has scrolled to.
        await scrollTo(tester, find.byIcon(Icons.person_add_alt_1));
        final button = tester.widget<IconButton>(
          find.widgetWithIcon(IconButton, Icons.person_add_alt_1),
        );
        expect(
          button.onPressed,
          isNotNull,
          reason: 'no address is needed to name a user_id',
        );

        await tapAfterScroll(tester, find.byIcon(Icons.person_add_alt_1));

        // The role they last held, shown rather than applied silently.
        expect(find.text('Contributor — records their own'), findsOneWidget);
        // Says what actually happens — they go back on, they do not get a code.
        expect(find.textContaining('do not need a code'), findsOneWidget);
        expect(find.textContaining('stays on the record'), findsOneWidget);
      },
    );
  });

  group('what a non-owner can find out about themselves (task 11.99)', () {
    // **The finding, in the words of the person it hurts.** A field tech whose
    // position estimate will not save has, before this, no way to tell whether
    // that is their role or a fault in the app — and no way to see who to ask.
    // The route to this screen was rendered only for owners, and the only
    // place TriTrack ever named somebody's own role to them was inside a
    // refusal message, *after* they had already tried something they were not
    // allowed to do. `/w-03` found it while writing the roles page for the
    // user guide, and had to publish a table the app could not show to most of
    // the people it applies to.

    testWidgets('a contributor is told their role and what it permits', (
      tester,
    ) async {
      late ProviderContainer container;
      await tester.runAsync(() async {
        container = await seed(
          signedInAs: 'user-second',
          memberships: [
            membership('m-owner', userId: owner),
            membership(
              'm-second',
              userId: 'user-second',
              role: ProjectRole.contributor,
            ),
          ],
        );
      });
      addTearDown(container.dispose);
      await pump(tester, container);

      expect(find.text('Your role'), findsOneWidget);
      // The admission sheet's wording, not the database's `contributor`.
      expect(find.text('Contributor — records their own'), findsOneWidget);
      // And what that actually means, because the name alone answers nothing
      // to somebody who has just been refused something.
      expect(
        find.textContaining('You can record bearings'),
        findsOneWidget,
      );
      expect(
        find.textContaining('Only an owner can take a record out'),
        findsOneWidget,
        reason: 'the sentence has to say what the role cannot do as well',
      );
    });

    testWidgets('a viewer is told who to ask, by name', (tester) async {
      // "Ask an owner" is not actionable on a crew where nobody knows which of
      // four people that is. The names come off this project's own membership
      // rows, which the screen has already resolved.
      late ProviderContainer container;
      await tester.runAsync(() async {
        container = await seed(
          signedInAs: 'user-second',
          memberships: [
            membership('m-owner', userId: owner),
            membership(
              'm-second',
              userId: 'user-second',
              role: ProjectRole.viewer,
            ),
          ],
        );
      });
      addTearDown(container.dispose);
      await pump(tester, container);

      expect(find.text('Viewer — read only'), findsOneWidget);
      expect(
        find.textContaining('cannot record or change anything'),
        findsOneWidget,
      );
      // `sampleUser` names every seeded user Sam Ranger, so the assertion is
      // that a *name* is offered rather than "ask an owner".
      expect(find.textContaining('Ask Sam Ranger to change it.'), findsOneWidget);
    });

    testWidgets('an owner is told their role too, and not told to ask anybody', (
      tester,
    ) async {
      late ProviderContainer container;
      await tester.runAsync(() async {
        container = await seed(
          signedInAs: owner,
          memberships: [membership('m-owner', userId: owner)],
        );
      });
      addTearDown(container.dispose);
      await pump(tester, container);

      expect(find.text('Owner — also manages members'), findsOneWidget);
      expect(find.textContaining('Ask '), findsNothing);
    });

    testWidgets(
      'a project the rows say you are not on is a snapshot, and the card says '
      'so with the way in (task 11.237)',
      (tester) async {
        // This card used to say *"nothing here stops you recording"* for a
        // null role, which was true when null meant only *this device cannot
        // say*. A project whose own row and membership rows are here and
        // name somebody else — a colleague's archive, imported — is the
        // other thing null meant, and since 11.237 every write on it is
        // refused. The card must not describe a permission the person does
        // not have; it says what the project is and how to join it.
        late ProviderContainer container;
        await tester.runAsync(() async {
          container = await seed(
            signedInAs: 'user-second',
            memberships: [membership('m-owner', userId: owner)],
          );
        });
        addTearDown(container.dispose);
        await pump(tester, container);

        expect(find.text('Not on this project'), findsOneWidget);
        expect(find.textContaining(snapshotProjectDescription), findsOneWidget);
        expect(find.textContaining('join code'), findsOneWidget);
        expect(
          find.textContaining('Nothing here stops you recording'),
          findsNothing,
        );
      },
    );

    testWidgets(
      'the members list and the admission sheet spell a role the same way',
      (tester) async {
        // `/w-06`'s finding: the list and each member's summary line printed
        // the stored database value in lower case while the approval sheet
        // wrote each role out with what it means. Same three roles, two
        // spellings, one screen apart — and the lower-case one was a label
        // nobody chose. `test/documentation/role_vocabulary_test.dart` is the
        // guard for the class; this is the screen it was found on.
        late ProviderContainer container;
        await tester.runAsync(() async {
          container = await seed(
            signedInAs: owner,
            memberships: [
              membership('m-owner', userId: owner),
              membership(
                'm-past',
                userId: 'user-second',
                role: ProjectRole.contributor,
                // A morning, so the end is a different UTC day east of UTC
                // as the evening join is west of it (task 11.326).
                endDate: DateTime(2026, 9, 1, 8),
              ),
            ],
          );
        });
        addTearDown(container.dispose);
        await pump(tester, container);

        // The past-member line, which used to read "contributor · …".
        await scrollTo(
          tester,
          find.textContaining('Contributor · 2026-08-01 to 2026-09-01'),
        );
        expect(
          find.textContaining('Contributor · 2026-08-01 to 2026-09-01'),
          findsOneWidget,
        );
        // The closed role dropdown reads the written name, not `owner`.
        expect(find.text('Owner'), findsWidgets);
        expect(
          find.text('owner'),
          findsNothing,
          reason: 'the stored column value must not reach a screen',
        );
      },
    );
  });
}
