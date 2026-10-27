import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/more/screens/tag_database_screen.dart'
    show tagLibraryProvider;
import 'app_context_provider.dart';
import 'deployments_provider.dart';
import 'individuals_provider.dart';
import 'recordings_revision_provider.dart';

/// **Task 11.151. Every view of a project's tags, refreshed together.**
///
/// Michael, on his own device on 2026-09-03: *"If I link a tag up with an
/// existing project, I have to restart the app for it to show up in the
/// project."*
///
/// **Why one function instead of a line at each write site.** Nine writes
/// change which tags a project has — four on Project Setup (link existing,
/// create and link, add back, and the undo on the remove bar), two on the Tag
/// Database screen (the new-tag dialog's "Link to project" and a CSV import),
/// the Record screen's quick-add, the shared-observation importer, and a sync
/// pull carrying a teammate's link. **Three separate providers hold the
/// answer**, and before this every write site picked its own subset by hand:
/// no two sites picked the same one and not one of them picked all three. The
/// Tag Database screen's link — Michael's route — named none of them, so the
/// row was written and every list on the device went on showing the old set
/// until the app was restarted.
///
/// This is the shape `membership_provider.dart`'s `_afterMembershipChange`
/// already uses for the same problem on memberships, and it is deliberately
/// the boring one.
///
/// **Why this is not `ref.watch(recordingsRevisionProvider)` inside the three
/// providers**, which is the tidier-looking fix and was tried first: a
/// provider that watches the counter can have its own in-flight `Future`
/// orphaned when something bumps the counter *during* that provider's build,
/// and it then never completes. `currentUserProvider` announces on
/// `DataArrival` when it auto-creates a user, which is exactly what a first
/// run does, so the hazard is reachable in the running app and not only in a
/// test. `app_context_provider.dart` documents this trap at the top of
/// `currentUser` for the same reason. **Invalidating from here is safe because
/// it runs after a write, from a callback, never from inside a build.**
///
/// [projectId] is the project whose tag set changed. **Pass null for "every
/// project on this device."**
///
/// **Null used to mean "only the global list", and that was measured wrong on
/// 2026-09-04 (task 11.153).** The reasoning behind it was that a rename, a
/// recolour or a retirement touches the tag rather than the link, so no
/// project's tag set has changed — but [projectActiveTags] returns whole `Tag`
/// rows, name and colour included, so it changes every time any of those does.
/// **What that cost, measured:** renaming a collar on the Tag Database screen
/// left the Record screen's tag wheel and the Position screen's selector
/// offering the old name until the app was restarted — and the edit dialog
/// offers no project when editing an existing tag, so that route passes null
/// every time. Colour matters as much as the name: it is the map's legend key
/// (Phase 4.4). `tag_view_refresh_test.dart` holds the case.
void refreshTagViews(WidgetRef ref, {String? projectId}) {
  visitTagViewProviders((p) => ref.invalidate(p), projectId: projectId);
  // The map bakes tag name and colour into its own one-shot provider rather
  // than reading these, so it is told the same way it always was (task 11.45).
  ref.read(recordingsRevisionProvider.notifier).bump();
}

/// [refreshTagViews] for a caller holding a [ProviderContainer] rather than a
/// [WidgetRef] — tests, and any future non-widget caller.
void refreshTagViewsIn(ProviderContainer container, {String? projectId}) {
  visitTagViewProviders((p) => container.invalidate(p), projectId: projectId);
  container.read(recordingsRevisionProvider.notifier).bump();
}

/// **The tag views for every project on this device at once** — task 11.153.
///
/// What a sync pull needs, and the reason it needs something different from
/// [refreshTagViews]: the page the merger just applied can carry tag links for
/// any project this device holds, and the merger reports its counts by table
/// rather than by project. There is no id to pass, so each family is
/// invalidated whole.
///
/// **Not an announcement, a reaction to one.** It deliberately does not bump
/// the revision counter: the writer that triggered this has already announced,
/// which is how [ArrivalRefresh] heard about it in the first place. Bumping
/// here would be a second announcement for one arrival.
void refreshTagViewsEverywhere(Ref ref) =>
    visitTagViewProviders((p) => ref.invalidate(p), projectId: null);

/// **The one list of what "the tag views" means — and the one enumeration of
/// it**, so the three entry points above cannot drift apart and no write site
/// can pick a subset, which is precisely the defect task 11.151 fixed.
///
/// **It takes a visitor rather than invalidating directly** (task 11.154) so
/// that the guard reads this list rather than a transcription of it. See
/// `visitProjectViewProviders` for why that distinction is the whole point,
/// and `test/core/providers/refresh_lists_test.dart` for what reads it.
///
/// [visit] is passed untyped because `ProviderOrFamily`, the type
/// `Ref.invalidate` and `ProviderContainer.invalidate` both take, is not
/// exported by any package this app depends on (riverpod 3.3.2). The dynamic
/// call is checked at runtime and both callers pass a real `invalidate`.
void visitTagViewProviders(
  void Function(dynamic) visit, {
  required String? projectId,
}) {
  // The personal tag library (task 11.219). Creating a tag anywhere records
  // the collar here too, so the Tag Database screen has to hear about it.
  visit(tagLibraryProvider);
  if (projectId == null) {
    // Each family whole. Riverpod 3.3.2 offers no way to enumerate a family's
    // live instances, so "every project" is spelled this way rather than by
    // walking a list of project ids this function would have to fetch.
    visit(projectTagsProvider);
    visit(projectActiveTagsProvider);
    // Task 11.241: the animals the tags are grouped under, on the same list
    // because the same acts move both.
    visit(projectIndividualsProvider);
    // Task 11.243: and the dated link between them. A collar's colour and the
    // animal's name are read through it, so a link written or withdrawn
    // changes what every tag list shows.
    visit(projectDeploymentsProvider);
    return;
  }
  visit(projectTagsProvider(projectId));
  visit(projectActiveTagsProvider(projectId));
  visit(projectIndividualsProvider(projectId));
  visit(projectDeploymentsProvider(projectId));
}
