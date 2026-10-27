import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// **Task 11.154 — every place in the app that invalidates a provider by name,
/// and what each one was checked against.**
///
/// Task 11.153 found `refreshProjectViews` invalidating `myProjectRole` and not
/// `projectRoleForUser`, **the single line `myProjectRole` consists of**.
/// Invalidating a provider does not re-run the providers it reads (measured,
/// riverpod 3.3.2), so a list can be complete-looking and still hand a screen
/// its old answer — which is what an owner saw when a role change updated the
/// members list and not the "Your role" card beside it.
///
/// 11.153 audited the two lists it owned. **This is the rest of the app.** The
/// two refresh lists have a derived guard of their own
/// (`test/core/providers/refresh_lists_test.dart`, which reads the lists
/// themselves and follows what their providers read); the sites below are
/// single lines scattered across notifiers and screens, with no list to read,
/// so what is written here is the **inverted** form `CLAUDE.md`'s guard rule
/// allows: each site is declared with the verdict it was given, and **a site
/// nobody has declared fails the run.**
///
/// **What a verdict means.** For each site the question asked was: *what did
/// the write change, and does anything the invalidated provider reads still
/// hold the old answer?* A provider that watches an invalidated provider does
/// rebuild — that direction works. The hole is downward, into what the
/// invalidated provider reads.
///
/// **This is a declaration, not a derivation, and the difference matters.** It
/// cannot tell you a verdict has gone stale; it can only tell you a site is new
/// or has moved to a different provider. That is the honest limit of it, and it
/// is still the difference between a new invalidation getting a moment's
/// thought and getting none.
void main() {
  /// Keyed `<file under lib/>::<provider invalidated>`. The value is the
  /// verdict from the 2026-09-04 audit.
  const declared = <String, String>{
    // ---- The two refresh lists. Guarded by derivation, not by this file. ----
    'core/providers/project_view_refresh.dart::p':
        'The project-view list itself, invalidating whatever the visitor hands '
        'it. Its contents and their read-sets are checked by '
        'test/core/providers/refresh_lists_test.dart.',
    'core/providers/tag_view_refresh.dart::p':
        'The tag-view list itself — same guard as the project-view list.',

    // ---- Identity ----
    'core/providers/auth_provider.dart::currentUserProvider':
        'Signing in adopts this device\'s server identity, which rewrites the '
        'user column of every synced row and hard-deletes the old Users row. '
        'currentUser itself reads activeUserId — just set through its own '
        'notifier — and repositories, so nothing below it is stale. **The rows '
        'under every other screen have changed, and this line does not cover '
        'them**; ServerIdentityAdopter announces through DataArrival at the '
        'end of adopt() and that is what refreshes them (task 11.45, which '
        'names this as its sixth inbound path). Checked in the code on '
        '2026-09-04 rather than assumed: the announcement is after the '
        'transaction commits, so what the refresh reads is the rewritten '
        'rows.',
    'features/splash/splash_screen.dart::currentUserProvider':
        'Re-reads the user row after the identity gate wrote a real name onto '
        'it. Nothing below currentUser holds a copy of that row.',
    'features/identity/screens/identity_setup_screen.dart::currentUserProvider':
        'Same as the splash gate: the Users row was just written and only '
        'currentUser caches it.',
    'features/more/screens/profile_screen.dart::currentUserProvider':
        'An edit to this person\'s own name or email. Same row, same single '
        'cache.',

    // ---- Project selection and the projects list ----
    'features/more/screens/projects_screen.dart::allProjectsProvider':
        'A pull-to-refresh, a delete and a restore. ownedProjectIds and '
        'departedProjectIds both *watch* allProjects, so they rebuild with it '
        '— that direction is not the hole.',
    'features/more/screens/projects_screen.dart::currentProjectProvider':
        'The active project was switched, deleted or restored, and '
        'activeProjectId was set through its own notifier first. currentProject '
        'reads that notifier and the project repository, neither of which '
        'holds a stale answer.',
    'features/more/screens/projects_screen.dart::departedProjectIdsProvider':
        'Explicit after a delete. Redundant — it watches allProjects, which is '
        'invalidated on the same path — and harmless.',
    'features/more/screens/project_setup_screen.dart::currentProjectProvider':
        'A project\'s own fields were edited. Reads the repository directly.',
    'features/more/screens/project_setup_screen.dart::allProjectsProvider':
        'Same edit, so the list rows carrying the name change with it.',
    'features/more/screens/project_setup_screen.dart::projectByIdProvider':
        'Same edit, for the by-id view of the project just saved.',
    'features/more/screens/new_season_screen.dart::currentProjectProvider':
        'Task 11.56. A new project was just created and made active — '
        'activeProjectId was set through its own notifier first, exactly as '
        'the setup screen does on save. Same reasoning as its entry.',
    'features/more/screens/new_season_screen.dart::allProjectsProvider':
        'Same creation, so the projects list grows a row. The clone itself '
        'already announced through DataArrival for every per-project reader; '
        'these two are the list and the active project, which that '
        'announcement does not refresh.',
    'features/more/screens/project_setup_screen.dart::locationProblemProvider':
        'Re-asks the operating system whether location is available after the '
        'person has been sent to settings. It reads no provider at all.',
    'features/more/screens/join_project_screen.dart::allProjectsProvider':
        'A project was just joined and its rows written by ProjectJoiner. The '
        'merger underneath announces through DataArrival, which is what '
        'refreshes the membership and tag views; this line is the local list.',
    'features/more/screens/data_export_screen.dart::currentProjectProvider':
        'A restored backup, and a switch to the project just imported. The '
        'merger announces the rows it wrote (task 11.45), so the screens that '
        'show them are refreshed by that rather than from here.',
    'core/providers/join_request_watcher.dart::allProjectsProvider':
        'A join the watcher completed on the person\'s behalf. Same shape as '
        'the join screen: the merger announces the rows.',

    // ---- Membership ----
    'core/providers/membership_provider.dart::allProjectsProvider':
        'joinApprovedProject, after ProjectJoiner has written a whole '
        'project. The merger announces, so the membership and tag views are '
        'refreshed by ArrivalRefresh rather than from here.',
    'core/providers/membership_provider.dart::syncControllerProvider':
        'A project became linked or unlinked, which SyncController reads once '
        'at build and then holds. It is a notifier rebuilt from the sync state '
        'store, not from a cached provider.',
    'core/providers/membership_provider.dart::isProjectLinkedProvider':
        'Same fact, per project. It reads syncStateStore directly — a store, '
        'not a cached answer.',
    'core/providers/membership_provider.dart::projectMembershipsProvider':
        'A pull before leaving, so the members list reflects what the server '
        'says before this device writes its departure. projectMemberships '
        'reads two repositories and nothing else.',
    'core/providers/membership_provider.dart::leaveProjectVerdictForProvider':
        'Explicit after leaving, on top of the refreshProjectViews call in '
        '_afterMembershipChange, which covers it as well.',
    'core/providers/membership_provider.dart::projectJoinSettingsProvider':
        'The join code, the switch and the team limit, all server state. The '
        'provider is one call to a transport; it caches nothing local.',
    'core/providers/membership_provider.dart::projectJoinRequestsProvider':
        'The pending queue, server state, same shape as the join settings.',

    // ---- Sync surfaces ----
    'core/providers/sync_provider.dart::isProjectLinkedProvider':
        'Linking and unlinking, read straight from the sync state store.',
    'core/providers/sync_provider.dart::syncConflictsProvider':
        'A conflict was reviewed or a round wrote new ones. The provider reads '
        'the conflict store through the database handle; syncConflictCount '
        'watches it and follows.',
    'core/providers/sync_provider.dart::syncHeldRowsProvider':
        'Rows the server refused. Reads the held-row store directly; '
        'syncHeldRowDetails watches it and follows.',
    'core/providers/sync_provider.dart::syncDroppedRowsProvider':
        'Rows this device gave up on, same store, same shape.',
    'core/providers/sync_conflicts_provider.dart::syncConflictsProvider':
        'The same store after a conflict is resolved from its own screen.',
    'core/providers/project_link_provider.dart::allProjectsProvider':
        'A join wrote a new local project. The merger announces the rows '
        'inside it; this is the list.',
    'core/providers/project_link_provider.dart::syncControllerProvider':
        'Publishing or joining changes whether the project is linked, which '
        'the controller holds from its own build.',
    'core/providers/project_link_provider.dart::isProjectLinkedProvider':
        'Same fact per project, read from the sync state store.',

    // ---- Destroying a project on a schedule (task 11.290) ----
    'core/providers/project_deletion_provider.dart::isProjectLinkedProvider':
        'A destroyed project is unlinked, through the same store.clear the '
        'sign-out path uses; same fact, same store.',
    'core/providers/sync_provider.dart::undeliveredProjectDeletionsProvider':
        'A stranded project row was delivered, or its round was refused. The '
        'provider reads the Projects table, the sync state store and the '
        'held-row store directly, and *watches* projectChangeRefusals — the '
        'one thing it derives from another provider — which the same code '
        'path writes through its own notifier first.',
    'features/more/screens/projects_screen.dart::undeliveredProjectDeletionsProvider':
        'A pull-to-refresh, and an undo of a local delete the server had '
        'not accepted. Same reads as above; the undo wrote the project row '
        'and forgot the refusal through the notifier before this runs.',
    'features/more/screens/projects_screen.dart::unsyncedMemberProjectIdsProvider':
        'The owner scheduled, canceled or destroyed from the list. It '
        'watches allProjects and reads the membership repository and the '
        'link store per project; the link store is what markDestroyed just '
        'changed, and nothing it reads holds a stale answer.',
    'features/more/screens/projects_screen.dart::trashedOnThisDeviceProvider':
        'Task 11.339. A project moved to the Trash, its six-second undo, and '
        'a Restore or Delete permanently on a row the provider listed. Each '
        'wrote the Projects table (or removed the project) before this runs. '
        'The provider watches the database, currentUser and the sync state '
        'store and reads the Projects table, the link flags and the row '
        'receipts directly on every build — none of which those writes leave '
        'stale — so invalidating it is the whole refresh.',
    'features/more/screens/projects_screen.dart::projectDeletionNoticesProvider':
        'Task 11.339. Delete permanently on a project in the Trash that this '
        'phone does not sync removes that project\'s deletion notice from the '
        'sync state store. The notifier\'s build reads exactly that store, '
        'and nothing else, so a rebuild reads the new answer.',
    'features/more/screens/projects_screen.dart::deletedOnServerListingProvider':
        'Task 11.313. A restore, a delete-from-server or a cancel on a row '
        'in the Trash section (task 11.324\'s name for it) — '
        'each one is a request straight to the server, with no local write '
        'in between. The provider itself makes a fresh '
        'listDeletedOnServer() call on every rebuild and reads no other '
        'provider\'s cache, so there is nothing downstream that could hold '
        'a stale answer; invalidating it just asks the server again.',

    // ---- Screen-local views ----
    'features/more/screens/log_screen.dart::historyDataProvider':
        'The Log\'s own query, re-run after an edit, exclusion or deletion '
        'made on that screen. It reads five repositories and the recordings '
        'revision counter; no provider under it caches a row.',
    'features/more/screens/manage_offline_maps_screen.dart::offlineRegionsProvider':
        'Offline map regions after a download, delete or rename. The notifier '
        'rebuilds from the region store and the download manager.',
    'features/more/screens/offline_data_map_screen.dart::offlineRegionsProvider':
        'The same store from the map view of it.',
    'features/map/widgets/offline_region_actions.dart::offlineRegionsProvider':
        'Task 11.230: the shared delete and rename for one downloaded area, '
        'called from both offline screens. Delete removes files and the '
        'manifest entry, then reconciles; rename rewrites the manifest. The '
        'notifier re-reads the store and reconciles against the disk, so it '
        'holds nothing older than the write; the storage-totals provider '
        'on the list screen watches it and so re-reads the disk too. '
        'Checked in the code 2026-09-12.',
    'features/position_estimation/screens/position_estimation_screen.dart::_pastEstimatesProvider':
        'That screen\'s own private list of past estimates, re-read after one '
        'is saved or deleted. It reads a repository.',
    'features/more/screens/tag_database_screen.dart::tagLibraryProvider':
        'Task 11.288: a library entry soft-deleted or restored. '
        'tagLibraryProvider reads tagLibraryRepositoryProvider (a stable '
        'device/db handle) and re-queries findAll(); nothing below it caches '
        'a row. Unlike the copy-into-a-project writes on this same screen, a '
        'library delete reaches no project — refreshTagViews\'s wider list is '
        'not needed here, and this is a plain, direct invalidation rather than '
        'a self-invalidation.',
  };

  /// A site whose *self*-invalidation needs no read-set analysis: a notifier
  /// rebuilding itself reads whatever it read before, freshly.
  const selfInvalidations = <String>{
    'core/providers/sync_provider.dart',
    // Task 11.290: ProjectDeletionNotices re-reads its own store after it
    // writes a notice, the same shape as the controller above.
    'core/providers/project_deletion_provider.dart',
  };

  test('every by-name provider invalidation in lib/ has a declared verdict', () {
    final found = <String, List<String>>{};
    final selfFound = <String>{};
    final lib = Directory('lib');
    for (final entity in lib.listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      // Generated code invalidates nothing of its own; it mirrors what the
      // annotated source already says.
      if (entity.path.endsWith('.g.dart')) continue;
      final relative = entity.path.substring('lib/'.length);
      final lines = entity.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        final line = lines[i];
        final trimmed = line.trimLeft();
        // Prose about invalidation is not an invalidation.
        if (trimmed.startsWith('//') || trimmed.startsWith('*')) continue;
        if (RegExp(r'\binvalidateSelf\s*\(').hasMatch(line)) {
          selfFound.add(relative);
        }
        for (final match in RegExp(
          r'\.invalidate\(\s*([A-Za-z_][A-Za-z0-9_]*)',
        ).allMatches(line)) {
          found
              .putIfAbsent('$relative::${match.group(1)}', () => [])
              .add('line ${i + 1}');
        }
      }
    }

    // The scan reached the source it is about. A guard that can pass by
    // finding nothing is not a guard — `CLAUDE.md`, 2026-09-04, about a secret
    // scan that walked one commit and stayed green.
    expect(
      found.length,
      greaterThanOrEqualTo(declared.length),
      reason:
          'The scan found ${found.length} invalidation sites and ${declared.length} '
          'are declared. Fewer found than declared means the scan is looking '
          'at the wrong tree, not that the app got tidier.',
    );
    // ignore: avoid_print
    print(
      'Scanned ${lib.listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.dart') && !f.path.endsWith('.g.dart')).length} '
      'source files under lib/ and found ${found.length} by-name provider '
      'invalidations across ${found.keys.map((k) => k.split('::').first).toSet().length} files.',
    );

    final undeclared = found.keys.where((k) => !declared.containsKey(k)).toList()
      ..sort();
    expect(
      undeclared,
      isEmpty,
      reason:
          'These invalidations are not declared in this file: '
          '${undeclared.map((k) => '$k (${found[k]!.join(', ')})').join('; ')}. '
          'Before adding one, ask what task 11.153 found the hard way: the '
          'write changed something — does anything the invalidated provider '
          '*reads* still hold the old answer? Invalidating a provider does not '
          're-run what it reads (riverpod 3.3.2), so a provider built on a '
          'second provider needs both. Write the verdict here, in the same '
          'plain terms as its neighbours.',
    );

    final gone = declared.keys.where((k) => !found.containsKey(k)).toList()
      ..sort();
    expect(
      gone,
      isEmpty,
      reason:
          'These sites are declared here and no longer exist in lib/: $gone. '
          'A declaration outliving the code it describes is how a status '
          'document comes to send every future reader to the wrong place; '
          'delete the entry with the line.',
    );

    expect(
      selfFound,
      equals(selfInvalidations),
      reason:
          'invalidateSelf() sites changed. A notifier rebuilding itself needs '
          'no read-set analysis, but the set of them is worth knowing.',
    );
  });
}
