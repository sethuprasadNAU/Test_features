import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tritrack/core/providers/app_context_provider.dart';
import 'package:tritrack/core/providers/database_provider.dart';
import 'package:tritrack/core/providers/membership_provider.dart';
import 'package:tritrack/core/providers/retry_policy.dart';
import 'package:tritrack/core/providers/server_transport_provider.dart';
import 'package:tritrack/data/db/app_database.dart';
import 'package:tritrack/data/models/project_membership.dart';
import 'package:tritrack/data/models/sync_meta.dart';
import 'package:tritrack/data/sync/sync_transport.dart';
import 'package:tritrack/features/more/screens/project_members_screen.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

import '../../data/fixtures.dart';
import '../../support/app_shell_harness.dart';
import '../../support/fake_shared_preferences.dart';

/// **Task 11.142 — what the Members screen says when there is no server.**
///
/// A device with no server is this app's default and fully supported state
/// (task 10.2), so it is what somebody sees the first time they open the app.
/// Both server-only sections of this screen used to answer it with the same
/// sentence they answer a dead server with — *"this needs a connection"* — and
/// `/w-11`'s screenshot harness photographed both of them spinning.
///
/// **Two facts worth writing down, because the brief inherited a cause that
/// turned out to be wrong.** The providers *do* resolve: they throw
/// `not_configured`, and under the app's own retry policy
/// ([appRetryPolicy], 1.6 s) the error branch renders. The "spins forever" in
/// the picture is the screenshot harness's container running Riverpod's
/// 38-second default retry instead of the app's. What was genuinely wrong in
/// the app is the *sentence*: three different situations, one answer, and for
/// the commonest of them it named a cause that does not exist.
void main() {
  const projectId = 'project-1';
  const owner = 'user-owner';

  setUp(installFakeSharedPreferences);

  Future<ProviderContainer> boot({NoServerReason? noServer}) async {
    final container = ProviderContainer(
      // The policy that ships. Without it this test measures Riverpod's
      // default — which is the very difference this file exists to pin.
      retry: appRetryPolicy,
      overrides: [
        appDatabaseProvider.overrideWith((ref) => AppDatabase.openInMemory()),
        currentUserProvider.overrideWith(
          (ref) async => sampleUser(id: owner, email: 'o@x.com'),
        ),
        if (noServer != null)
          noServerReasonProvider.overrideWith((ref) async => noServer),
      ],
    );
    final db = (await container.read(appDatabaseProvider.future)).raw;
    await db.insert(
      Tables.users,
      sampleUser(id: owner, email: 'o@x.com').toColumns(),
    );
    await db.insert(
      Tables.projects,
      sampleProject(id: projectId, ownerUserId: owner).toColumns(),
    );
    await db.insert(
      Tables.projectMemberships,
      ProjectMembership(
        membershipId: 'm-owner',
        projectId: projectId,
        userId: owner,
        joinDate: DateTime.utc(2026, 8, 1),
        role: ProjectRole.owner,
        sync: SyncMeta.initial(
          now: DateTime.utc(2026, 8, 1),
          modifiedBy: owner,
        ),
      ).toColumns(),
    );
    container.listen(isProjectOwnerProvider(projectId), (_, _) {});
    container.listen(projectMembershipsProvider(projectId), (_, _) {});
    container.listen(myProjectRoleProvider(projectId), (_, _) {});
    container.listen(noServerReasonProvider, (_, _) {});
    await container.read(isProjectOwnerProvider(projectId).future);
    await container.read(projectMembershipsProvider(projectId).future);
    await container.read(myProjectRoleProvider(projectId).future);
    await container.read(noServerReasonProvider.future);
    return container;
  }

  /// **Pumped inside the real tab shell at 6.1-inch phone geometry**, which is
  /// what task 11.109's guard asks for and is also the sharper instrument here:
  /// `pumpInAppShell` fails the test if a spinner is still on screen after
  /// fifteen seconds, so "neither section spins" is asserted by the harness
  /// before any expectation below runs.
  Future<void> pump(WidgetTester tester, ProviderContainer container) async {
    await pumpInAppShell(
      tester,
      container: container,
      screen: const ProjectMembersScreen(projectId: projectId),
      tabIndex: 4, // Map / Record / Compass / Position / **More**
    );
    await tester.pumpAndSettle();
  }

  Future<void> scrollTo(WidgetTester tester, Finder finder) async {
    await tester.scrollUntilVisible(
      finder,
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
  }

  testWidgets('with nothing configured, neither section spins and each says '
      'why it is empty', (tester) async {
    late ProviderContainer container;
    await tester.runAsync(() async => container = await boot());
    addTearDown(container.dispose);
    await pump(tester, container);

    // The state under test really is "no server address", reached through the
    // app's own providers rather than asserted by an override.
    expect(container.read(noServerReasonProvider).value, NoServerReason.noAddress);

    await scrollTo(tester, find.text('Waiting to join'));
    expect(find.byType(CircularProgressIndicator), findsNothing);

    for (final subject in ['The join code', 'A request to join']) {
      expect(
        find.text(
          noServerSectionText(NoServerReason.noAddress, subject: subject),
        ),
        findsOneWidget,
        reason: 'the $subject section has to say why it is empty',
      );
    }
  });

  testWidgets('"no server" does not read as "the server did not answer"', (
    tester,
  ) async {
    final notConfigured = noServerSectionText(
      NoServerReason.noAddress,
      subject: 'The join code',
    );
    final signedOut = noServerSectionText(
      NoServerReason.notSignedIn,
      subject: 'The join code',
    );
    final refused = noServerSectionText(
      NoServerReason.addressRefused,
      subject: 'The join code',
    );
    expect({notConfigured, signedOut, refused}, hasLength(3));
    // None of the three may be read as a network problem, because none of them
    // is one — no request was made in any of them.
    for (final text in [notConfigured, signedOut, refused]) {
      expect(text, contains('More → Server Connection'));
    }

    // And the server-did-not-answer branch is a different sentence again,
    // reached only when this device could have asked.
    final withServer = ProviderContainer(
      retry: appRetryPolicy,
      overrides: [
        appDatabaseProvider.overrideWith((ref) => AppDatabase.openInMemory()),
        currentUserProvider.overrideWith(
          (ref) async => sampleUser(id: owner, email: 'o@x.com'),
        ),
        noServerReasonProvider.overrideWith((ref) async => null),
        projectJoinSettingsProvider(projectId).overrideWith(
          (ref) async => throw const SyncTransportException('unreachable'),
        ),
        projectJoinRequestsProvider(projectId).overrideWith(
          (ref) async => throw const SyncTransportException('unreachable'),
        ),
      ],
    );
    addTearDown(withServer.dispose);
    await tester.runAsync(() async {
      // **Never awaited from the test body** — a widget test runs on a fake
      // clock the database does not, and awaiting one outside `runAsync`
      // kills the pump loop (the trap that cost task 11.97 most of a day).
      final db = (await withServer.read(appDatabaseProvider.future)).raw;
      await db.insert(
        Tables.users,
        sampleUser(id: owner, email: 'o@x.com').toColumns(),
      );
      await db.insert(
        Tables.projects,
        sampleProject(id: projectId, ownerUserId: owner).toColumns(),
      );
      await db.insert(
        Tables.projectMemberships,
        ProjectMembership(
          membershipId: 'm-owner',
          projectId: projectId,
          userId: owner,
          joinDate: DateTime.utc(2026, 8, 1),
          role: ProjectRole.owner,
          sync: SyncMeta.initial(
            now: DateTime.utc(2026, 8, 1),
            modifiedBy: owner,
          ),
        ).toColumns(),
      );
      withServer.listen(isProjectOwnerProvider(projectId), (_, _) {});
      withServer.listen(projectMembershipsProvider(projectId), (_, _) {});
      withServer.listen(myProjectRoleProvider(projectId), (_, _) {});
      withServer.listen(projectJoinSettingsProvider(projectId), (_, _) {});
      withServer.listen(projectJoinRequestsProvider(projectId), (_, _) {});
      await withServer.read(isProjectOwnerProvider(projectId).future);
      await withServer.read(projectMembershipsProvider(projectId).future);
      await withServer.read(myProjectRoleProvider(projectId).future);
      try {
        await withServer.read(projectJoinSettingsProvider(projectId).future);
      } catch (_) {}
      try {
        await withServer.read(projectJoinRequestsProvider(projectId).future);
      } catch (_) {}
    });
    await pump(tester, withServer);
    await scrollTo(tester, find.text('Waiting to join'));
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.textContaining('the server did not answer'), findsNWidgets(2));
    expect(find.text(notConfigured), findsNothing);
  });
}
