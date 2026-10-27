// **A configured, signed-in, joined and syncing device — without a server.**
//
// `/w-02` photographed the app with no server address set, which is its
// default and a fully supported state. But the guide's flagship section is
// *joining a project*, and a page explaining how to join illustrated by a
// device that never joined one is worse than a page with no pictures. So this
// file adds the other half: it drives the app's own fake sync transport — the
// one every client sync test already runs against — through a whole join.
//
// **Nothing here starts a server, and that is the point rather than a
// shortcut.** A real server would make every image depend on what some
// machine happened to be holding that afternoon; `FakeSyncTransport` is
// deterministic and already models the rules that matter, including the one
// the owner's screen depends on: the email on a join request comes from the
// authenticated session and never from the request body.
//
// ## What is faked, and what is not
//
// Three seams are replaced, all of them ones the app's own tests already
// replace, and each stays inert until [activateJoinedDevice] is called:
//
//  * `sessionStoreProvider` — a signed-in session for the invented owner. It
//    reads as signed *out* until a server address exists, because
//    `CurrentSession` refuses to touch the keychain on an unconfigured device.
//  * `serverTransportProvider` — **the app's one construction of a connection
//    to its server** (task 11.97). Overriding it reaches the membership
//    surface, the join/publish controller **and the sync engine**, which is
//    three call sites that used to build their own.
//  * `serverConfigProvider` — not overridden at all. The real notifier is
//    given a real address through its real setter, so the images are of the
//    app in the state a person's device is genuinely in.
//
// **Two things this file used to say and no longer may**, both corrected by
// `/w-10` after task 11.97 removed the mechanisms under them. It said the
// override was `membershipTransportProvider`; that provider is now one line
// forwarding to `serverTransportProvider`, so the narrower seam is a
// distinction without a difference here. And it said `ProjectLinkController`
// *"builds its own transport and so cannot be redirected by the seam above"*,
// which is why this file carried a subclass of it. That controller now reads
// the same provider through `requireServerTransport`, so the subclass was
// deleted: every join in this run is the app's own controller, unmodified.
//
// ## Which captures actually run the sync engine
//
// **The old sentence here — "the sync engine is not faked and is never run" —
// was true of the narrow override and is false of this one**, and a claim
// that is true of some captures and false of others is worse than the stale
// sentence it replaced. So it is said per capture instead:
//
// | capture | what the fake server does |
// |---|---|
// | every state before [activateJoinedDevice] | nothing — the override answers null, exactly as the real provider does on a device with no server |
// | `joined-*`, `join-*`, `owner-*`, `project-tags-viewer`, `tag-details-readonly` | membership and join calls only. No sync round is run; the map's status icon and the sync status screen are drawn from the local database and the durable sync bookkeeping, both written directly below |
// | `sync-offline`, `sync-records-missing`, `sync-records-held`, `sync-removed` | **a real round, against the fake server** (`/w-10`). Each is a full `SyncEngine` push/pull through [screenshotTransport], made to fail in one specific way. These four are the only captures in the run that call `syncNow` |
//
// **Nothing in this file reaches the network in any of those rows.** That was
// previously guaranteed by the engine never running; it is now guaranteed by
// the engine's only connection being an in-memory object.

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:tritrack/core/providers/database_provider.dart';
import 'package:tritrack/core/providers/server_config_provider.dart';
import 'package:tritrack/core/providers/server_transport_provider.dart';
import 'package:tritrack/core/providers/sync_provider.dart';
import 'package:tritrack/data/auth/session_store.dart';
import 'package:tritrack/data/models/observation.dart';
import 'package:tritrack/data/models/project.dart';
import 'package:tritrack/data/models/sync_meta.dart';
import 'package:tritrack/core/providers/active_selection_provider.dart';
import 'package:tritrack/data/models/tag.dart';
import 'package:tritrack/data/repositories/repository_providers.dart';
import 'package:tritrack/data/sync/sync_dropped_rows.dart';
import 'package:tritrack/data/sync/sync_held_rows.dart';
import 'package:tritrack/data/sync/sync_transport.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

import '../../test/data/sync/fake_sync_transport.dart';
import 'seed.dart';

/// The invented server address. `example.org` is a reserved documentation
/// domain, so it can never belong to anybody — the same rule the invented
/// people in `seed.dart` are held to. Nothing ever connects to it.
const String screenshotServerUrl = 'https://tritrack.example.org';

/// The Owyhee project's join code, as its owner would read it off this screen.
///
/// Invented, and legal in the real alphabet (Crockford Base32 without `I`, `L`,
/// `O` and `U`) so the picture shows a code the app would really issue rather
/// than one it would refuse.
const String owyheeJoinCode = 'HAWK9F3T';

/// The second project, the one the person holding the phone is asking to join.
const String steensProjectId = 'seed-project-steens';
const String steensJoinCode = 'SAGE7742';
/// **Owned by somebody already on this device**, and that is a constraint
/// rather than a flourish. The pulled `Projects` row carries an
/// `owner_user_id` and a `last_modified_by`, both of which are foreign keys
/// into `Users`; an invented stranger there makes the download fail with a
/// raw constraint error, which is exactly what the first run of this file did.
const String steensOwnerUserId = memberUserId;

/// The one tag seeded on the Steens project's server row, so the joined
/// device's Tag Database has something a non-owner's view can show (`/w-13`,
/// item 5).
const String steensTagId = 'seed-tag-steens-east-rim';

/// The invented person waiting in the owner's approval queue.
///
/// **Two separate strings on purpose, and the guide must show them as two.**
/// [pendingRequesterEmail] is what the server authenticated and is the only
/// thing about a stranger an owner can rely on; [pendingRequesterClaimedName]
/// is text that person typed about themselves. The owner's screen renders the
/// address as the heading and the name as *"Says they are …"*, and that
/// distinction is a security property rather than a matter of layout — so the
/// fixture makes the difference visible by having the claimed name be
/// something the address does not say.
const String pendingRequesterEmail = 'priya.raman@example.org';
const String pendingRequesterClaimedName = 'Priya R. — Malheur crew';

/// When the Owyhee project last synced, as the sync status screen reports it.
///
/// (It used to be read off the sync bar as well; task 11.189 removed the bar,
/// and the icon that replaced it carries the same sentence as a tooltip.)
///
/// **Fixed rather than "just now", and the trade is worth stating.** A stamp of
/// the present renders as *"Synced just now"* — which is what an ordinary
/// device says, and which changes to *"1 min ago"* if a run crosses a minute
/// boundary, and to an absolute timestamp on the status screen on every single
/// run. That is a screenshot that reports a difference on every regeneration,
/// which trains people to accept differences. So the fixture's clock is used,
/// the same one every observation in `seed.dart` is stamped with, and the
/// status screen reads *"Synced on 2026-02-11"*.
final DateTime seedLastSyncedAt = seedUtc.add(const Duration(minutes: 95));

/// The in-memory server every joined-device screenshot is taken against.
///
/// A subclass of the app's own test fake rather than a second implementation:
/// the only thing added is the ability to hold a pull open, which is what makes
/// the "downloading now" state photographable at all — it is otherwise on
/// screen for as long as an in-memory pull takes, which is not long enough to
/// point a camera at.
class ScreenshotSyncTransport extends FakeSyncTransport {
  /// Set to make the next pull wait until it is completed. The spinner state
  /// the guide needs is the interval this holds open.
  Completer<void>? holdPull;

  @override
  Future<SyncPullResponse> pull(SyncPullRequest request) async {
    final hold = holdPull;
    if (hold != null) {
      holdPull = null;
      await hold.future;
    }
    return super.pull(request);
  }
}

/// The one instance, shared by the overrides and the capture sequence.
final ScreenshotSyncTransport screenshotTransport = ScreenshotSyncTransport();

/// Whether [activateJoinedDevice] has run.
///
/// **Every override below reads this rather than being installed later**,
/// because a `ProviderContainer`'s overrides are fixed when it is built and the
/// run needs both states in one app session: the unconfigured screens first,
/// with pixels identical to what `/w-02` committed, then the joined ones.
bool _activated = false;

/// The session the app believes it is signed in with.
///
/// The token is a visibly fake string and is never rendered on any screen the
/// harness photographs; the expiry is far enough out that no run can reach it.
StoredSession screenshotSession() => StoredSession(
      token: 'screenshot-harness-not-a-token',
      userId: ownerUserId,
      email: 'robin.alvarez@example.org',
      expiresAt: DateTime.utc(2099, 1, 1),
    );

/// The transport the membership seam should hand out right now.
///
/// Null until [activateJoinedDevice] — which is exactly what the real provider
/// answers on a device with no server, so the first half of the run sees the
/// unconfigured app rather than a half-configured one.
SyncTransport? joinedTransportOrNull() =>
    _activated ? screenshotTransport : null;

/// The second project, as the server holds it. Invented, and deliberately
/// somewhere else again: the Steens are a hundred miles west of the Owyhee
/// uplands and, like them, are nowhere anybody on this project works. It is
/// run by the invented colleague who is already a contributor on the first
/// one, which is both a plausible field arrangement and the thing that keeps
/// the download's foreign keys satisfiable.
Project _steensProject() => Project(
      projectId: steensProjectId,
      projectName: 'Steens Rim Raptor Survey — Spring 2026',
      description: 'Golden eagle occupancy, east face',
      ownerUserId: steensOwnerUserId,
      creationDate: DateTime.utc(2026, 2, 2, 16, 0, 0),
      sync: SyncMeta.initial(
        now: seedUtc,
        modifiedBy: steensOwnerUserId,
        originDeviceId: 'seed-device-B',
      ),
    );

/// Fills the in-memory server: the two projects, who is on the first one, and
/// one stranger waiting to be let in.
void _seedFakeServer() {
  final transport = screenshotTransport
    ..sessionUserId = ownerUserId
    ..sessionEmail = 'robin.alvarez@example.org';

  // The Owyhee project and its three members, as the server would hold them.
  // The member rows are what the owner's "3 members, out of 50" line counts,
  // so seeding the project without them would show a team size of zero beside
  // a members list of three.
  transport.seedServerRow(Tables.projects, seedProject().toColumns());
  for (final membership in seedMemberships()) {
    transport.seedServerRow(
      Tables.projectMemberships,
      membership.toColumns(),
    );
  }
  transport.enableJoining(seedProjectId, code: owyheeJoinCode);

  // Somebody the owner has never met, asking to join. Written straight onto
  // the server rather than made through `requestToJoin`, because that call
  // stamps the request with the wall clock and the owner's screen prints the
  // date — which would put a different day on the image every time somebody
  // regenerated it.
  transport.serverJoinRequests.add(
    JoinRequestSummary(
      requestId: 'seed-request-priya',
      projectId: seedProjectId,
      email: pendingRequesterEmail,
      claimedName: pendingRequesterClaimedName,
      requestedAt: seedUtc.add(const Duration(days: 3)).toIso8601String(),
    ),
  );
  transport.joinRequestUserIds['seed-request-priya'] = 'seed-user-priya';

  // **Five more, so the pending section is long enough to need a scroll on
  // every profile** (`/w-13`, item 3). With one request the section fit
  // above the fold on `ipad-13` once task 11.189 gave the screen its height
  // back, and `owner-members-and-code` and `owner-pending-request`
  // photographed the same pixels — the harness's own duplicate detector said
  // so on every `ipad-13` run, and `/w-14` and `/w-16` both reported it
  // without it ever being fixed. These carry no name this run reads back —
  // `owner-pending-request`'s readiness condition still scrolls to and
  // asserts [pendingRequesterEmail] alone — so they exist only to make the
  // list tall.
  for (var i = 0; i < 5; i++) {
    final requestId = 'seed-request-filler-$i';
    transport.serverJoinRequests.add(
      JoinRequestSummary(
        requestId: requestId,
        projectId: seedProjectId,
        email: 'filler-requester-$i@example.org',
        claimedName: 'Filler Requester $i',
        requestedAt:
            seedUtc.add(Duration(days: 4, hours: i)).toIso8601String(),
      ),
    );
    transport.joinRequestUserIds[requestId] = 'seed-user-filler-$i';
  }

  // The second project, with joining switched on — the one this device asks
  // to join. No membership row for the person holding the phone: that is the
  // whole point, and `requestToJoin` refuses a code for a project you are
  // already on.
  transport.seedServerRow(Tables.projects, _steensProject().toColumns());
  transport.enableJoining(steensProjectId, code: steensJoinCode);

  // **One tag, so the joined project this device is a contributor on has
  // something to show on its Project Setup tag list** (`/w-13`, item 5).
  // Without this the screen downloads to an empty list, and the status badge
  // a non-owner sees on a row they cannot edit has nowhere to be
  // photographed.
  //
  // **Task 11.219 moved that row's read-only handling and this fixture with
  // it.** It used to be photographed with a padlock on the Tag Database
  // screen; that screen shows this device's own tag *library* now, which no
  // role governs and which never held this tag at all, and the padlock is
  // gone from every row everywhere. A project's copy is still read-only for
  // a non-owner, and is listed and edited on Project Setup instead —
  // `project-tags-viewer` and `tag-details-readonly` are shot there.
  // `steensTagId` is named rather than reused from the Owyhee fixture: this
  // row belongs to the *other* project, on the *other* owner's account.
  transport.seedServerRow(
    Tables.tags,
    Tag(
      tagId: steensTagId,
      projectId: steensProjectId,
      lineageId: steensTagId,
      frequencyMhz: 149.980,
      pulseRate: 40,
      pulsePattern: 'steady',
      tagName: 'East Rim',
      status: TagStatus.active,
      notes: 'Adult golden eagle, east face nest',
      colorHex: TagColorPalette.colorForIndex(4),
      sync: SyncMeta.initial(
        now: seedUtc,
        modifiedBy: steensOwnerUserId,
        originDeviceId: 'seed-device-B',
      ),
    ).toColumns(),
  );
  // What `listMyProjects` answers. Owyhee is on it and is filtered straight
  // back out by `ProjectDirectoryClient`, because this device already holds it
  // and is syncing it — which is the real behaviour the "No projects to join"
  // line on the join screen is reporting, rather than an empty fixture.
  transport.serverProjects.add(
    ProjectSummary(
      projectId: seedProjectId,
      projectName: seedProject().projectName,
      ownerUserId: ownerUserId,
      role: ProjectRole.owner.db,
    ),
  );
}

/// Turns this device into a configured, signed-in, syncing one.
///
/// Called **after** the unconfigured screens have been photographed, in the
/// same app session: a device with no server shows no sync surface at all —
/// no dot on the More tab, no icon on the map — so doing this first would
/// move pixels on every image `/w-02` committed.
Future<void> activateJoinedDevice(ProviderContainer container) async {
  _seedFakeServer();

  final store = container.read(syncStateStoreProvider);
  // The active project is one this device has published and synced. Without
  // the linked flag `SyncController` reports "never published", which is a
  // real state but not the ordinary one the guide is illustrating.
  await store.markProjectLinked(seedProjectId);
  await store.setLastSuccessAt(seedProjectId, seedLastSyncedAt);
  // **This is what keeps the harness off the network.** The app syncs by
  // itself when the app is foregrounded and the interval has elapsed (task
  // 11.59), and that round would build a real HTTP transport aimed at an
  // invented hostname. Recording an attempt *now* puts the next automatic one
  // fifteen minutes away, which is longer than any capture run.
  await store.setLastAttemptAt(DateTime.now().toUtc());

  _activated = true;
  await container.read(serverConfigProvider.notifier).setUrl(screenshotServerUrl);
  // The override above reads a plain variable rather than watching anything,
  // so it has to be told; everything downstream of it rebuilds on its own.
  container.invalidate(serverTransportProvider);
  container.invalidate(syncControllerProvider);
  await container.read(syncControllerProvider.future);
}

/// Whether the second project actually landed on this device.
///
/// **Asked because `JoinRequestWatcher` swallows a failed download by
/// design** — an unreachable server is the ordinary field condition, not an
/// error — so the card says "the download hasn't started" and nothing else
/// says anything at all. Without this, a harness would happily file that
/// picture under the name `join-arrived`, which is a screenshot claiming
/// something the run did not achieve.
Future<bool> joinedProjectIsOnDevice(ProviderContainer container) async {
  final db = await container.read(appDatabaseProvider.future);
  final rows = await db.raw.query(
    Tables.projects,
    where: 'project_id = ? AND deleted_at IS NULL',
    whereArgs: [steensProjectId],
  );
  return rows.isNotEmpty;
}

// ---------------------------------------------------------------------------
// **The sync bar's failure states** (`/w-10`, `/w-12`) — all four, now that
// task 11.144 fixed the defect that let a completed round end this run.
//
// Task 11.97 gave the app one construction of its connection to the server, so
// a substituted server can drive eleven of the fourteen things the sync bar can
// say. `/w-10` set out to photograph four of them — *offline*, *records
// refused*, *records the server sent that this build could not read*, and *no
// longer on this project* — and drove all four successfully, but every one of
// them ended the run: the first `SyncEngine` round to change what the bar says
// tripped *"setState() or markNeedsBuild() called during build"* and stopped
// the test body there. Task 11.144 found the actual cause (a provider deriving
// from another provider on the Position screen, not task 11.95's class as both
// the plan entry and `/w-10`'s report guessed) and fixed it. `/w-12` drives all
// four states below.
//
// **The order below is load-bearing, not cosmetic.** `SyncStatus.health` ranks
// these fixed conditions — a held record outranks a merely-missing one, and
// losing membership outranks everything, including a held record. Captured
// lowest-ranked first, each later round's higher-ranked condition wins the
// bar without anything having to be cleared first:
//
//  1. **offline** — every call fails, so no round can rank above it.
//  2. **records missing** — a row the server holds that this build's
//     validator cannot parse; dropped on arrival.
//  3. **records held** — a row this device holds that the server refuses;
//     ranks above records-missing, so this picture wins even though the
//     unreadable server row from step 2 is still sitting there uncleared.
//  4. **removed** — this device's own membership closes; ranks above
//     everything above it, which is also why it goes last.

/// Silences the 24-hour staleness warning for the rest of the run.
///
/// **Why anything is needed here at all.** The fixture's last successful sync
/// is stamped in February ([seedLastSyncedAt]) so that every picture of it is
/// the same picture on every regeneration. `SyncStatus.health` ranks *"not
/// synced in over 24 hours"* above both *healthy* and *offline*, so a device
/// carrying a seven-month-old stamp reports [SyncHealth.staleRecordsPending]
/// — **a fault** — and every joined capture drew the staleness rather than
/// the state it was taken for. The map's status icon came out a red
/// exclamation in a picture whose whole subject is the calm one.
///
/// ## Why a dismissal rather than a fresh timestamp (`/w-14`)
///
/// This replaced `markRecentlySynced`, which wrote `DateTime.now()` into the
/// last-success stamp. That worked, and its reasoning was explicit: *"the
/// banner prints `just now` for anything under a minute, so the words in the
/// photograph do not depend on when it was taken."*
///
/// **That was true of the sync bar and is false of the screen that replaced
/// it.** Task 11.189 removed the bar; `/w-14` moved the four failure captures
/// onto `SyncStatusScreen`, and that screen prints an **absolute** timestamp
/// — *"Last successful sync: 2026-09-07 13:41"*. A wall-clock stamp there is
/// a picture that reports a difference on every single regeneration, which is
/// the one thing this whole fixture is arranged to prevent.
///
/// A dismissal reaches the same place from the other side: the February stamp
/// stays, so the printed line is fixed, and the staleness that stamp would
/// otherwise trigger is the thing suppressed.
///
/// **It cannot silence anything else, and that is a property of the app
/// rather than of this file.** `SyncStatus.health` returns for a held record,
/// a dropped record, an ended membership, a refused address and the rest
/// *before* it reaches the staleness branch, so a dismissal can only ever
/// turn the answer into [SyncHealth.healthy] or [SyncHealth.offline] — task
/// 11.114's own acceptance criterion. All four failure captures below are
/// therefore unaffected by it except the offline one, which is the only one
/// that needs it.
Future<void> dismissStaleWarning(ProviderContainer container) async {
  // Re-arms at the next 04:00 after this moment, which is always later than
  // the run, so it holds for the whole of it.
  await container
      .read(syncStateStoreProvider)
      .setStaleDismissedAt(DateTime.now().toUtc());
  // **Invalidated afterwards, and an earlier run said why it had to be.**
  // Writing the store alone changed nothing: `SyncController` had already
  // read the old value into its state, so the round still reported staleness
  // and the surface still drew it. `activateJoinedDevice` above invalidates
  // for exactly the same reason.
  container.invalidate(syncControllerProvider);
  await container.read(syncControllerProvider.future);
}

/// **Pins the wall-clock stamps a real sync round writes, back to the
/// fixture's own moment** (`/w-13`).
///
/// `SyncEngine.sync()` calls `setLastSuccessAt(projectId, DateTime.now())`
/// whenever a round actually reaches the server — which every round in this
/// run does except the offline one — so the round `seedRefusedObservation`
/// and `seedUnreadableServerRecord` drive to produce `sync-records-missing`,
/// `sync-records-held` and `sync-removed` **overwrites the February stamp
/// [dismissStaleWarning] set**, with today's date. The same round stamps
/// `Sync_Held_Rows.last_refused_at_utc` and
/// `Sync_Dropped_Rows.last_dropped_at_utc` with `DateTime.now()` too, and
/// both are printed verbatim on the cards those screens show — *"Last tried
/// …"*, *"Last happened …"*. All three are `DateTime.now()` inside
/// `sync_engine.dart` and `project_publisher.dart`, neither injectable nor
/// editable from this lane, so this cannot make the round itself
/// deterministic. What it can do — and what actually keeps the picture
/// fixed — is write the store and the two tables straight back to a moment
/// in the fixture's own timeline immediately after each round, before the
/// screen that reads them is shot.
///
/// **Measured, not assumed.** The committed `ipad-13/sync-records-held.png`
/// carries *"Last successful sync: 2026-09-08 00:49"*, *"Last tried
/// 2026-09-08 00:49"* and *"Last happened 2026-09-08 00:49"* — the date this
/// baseline happened to be captured on, not February — which is `/w-13`'s
/// item 2 in a single frame and the reason none of these three can be left
/// alone.
///
/// Pinned to [seedLastSyncedAt] rather than to `DateTime.now()` at capture
/// time, so the picture stays fixed on the next run too: a held row "last
/// tried" after the project "last successfully synced" would be a fixture
/// describing an impossible order of events, so all three stamps share one
/// moment.
///
/// **Patched in [SyncController]'s own `state`, not invalidated.** The first
/// version of this function invalidated `syncControllerProvider` and awaited
/// a rebuild the way [dismissStaleWarning] does — and it broke
/// `sync-removed`: rebuilding calls `SyncController.build()`, which derives
/// its state from what is *persisted*, and `SyncHealth.membershipEnded` is
/// deliberately not persisted (`_forgetFailure`, task 11.116's own choice —
/// leaving a project is not a failure to remember). So the rebuild produced
/// an ordinary healthy status, `sync-removed`'s readiness condition (*"You're
/// not on this project"*) never became true, and the run correctly reported
/// the capture as unfinished. **Watched failing**, which is what caught it.
/// Writing `state` directly changes only [SyncStatus.lastSuccessAt] and
/// leaves every field the round just computed — including that transient
/// health — exactly as the round left it.
Future<void> pinLiveSyncStamps(ProviderContainer container) async {
  final db = await container.read(appDatabaseProvider.future);
  final stamp = seedLastSyncedAt.toIso8601String();
  await db.raw.update(
    SyncHeldRowStore.table,
    {'last_refused_at_utc': stamp},
    where: 'project_id = ?',
    whereArgs: [seedProjectId],
  );
  await db.raw.update(
    SyncDroppedRowStore.table,
    {'last_dropped_at_utc': stamp},
    where: 'project_id = ?',
    whereArgs: [seedProjectId],
  );

  final store = container.read(syncStateStoreProvider);
  await store.setLastSuccessAt(seedProjectId, seedLastSyncedAt);

  final notifier = container.read(syncControllerProvider.notifier);
  final current = container.read(syncControllerProvider).value;
  if (current != null) {
    notifier.state =
        AsyncData(current.copyWith(lastSuccessAt: seedLastSyncedAt));
  }
}

/// Makes [projectId] the active project, the way `More > Projects` does when
/// somebody taps into one (`/w-13`, item 5). Screens scoped to "the active
/// project" — Tag Database among them — read this rather than "whichever
/// project this device happens to hold", so photographing one as a
/// non-owner needs it set explicitly to the project this device only
/// contributes to.
Future<void> setActiveProject(ProviderContainer container, String projectId) =>
    container.read(activeProjectIdProvider.notifier).set(projectId);

/// Makes every call to the invented server fail until [restoreTheServer].
///
/// **Every call, not the next one.** `failNextCalls = 1` fails the push and
/// lets the pull through behind it, and a pull that succeeds is exactly what
/// this run cannot survive — see the note above. A permanent failure for the
/// duration of one round is what makes "the request never arrived" the whole
/// of what happened.
void breakEveryCall() => screenshotTransport.permanentFailure =
    const SyncTransportException(SyncTransportException.unreachable);

/// Puts the invented server back, so nothing after this inherits the failure.
void restoreTheServer() => screenshotTransport.permanentFailure = null;

/// One real round: a push and a pull through [screenshotTransport].
///
/// **The only call in the whole capture run that reaches `SyncEngine`.** It
/// reaches an in-memory object rather than a network, for the reason the header
/// of this file gives.
///
/// **Returns what the round produced, and the run prints it** — the first
/// attempt at this capture reported *"the offline bar is not on screen"* after
/// twenty seconds and left nobody able to say whether the round had failed the
/// wrong way, succeeded, or never happened. It had failed, and the bar was
/// drawing something else. A readiness condition can only report what is
/// missing from a screen; this reports what the thing behind the screen
/// decided, which is the other half of the same question.
Future<String> runSyncRound(ProviderContainer container) async {
  try {
    await container.read(syncControllerProvider.notifier).syncNow();
  } catch (error) {
    return 'the round threw — ${error.toString().split('\n').first}';
  }
  final status = container.read(syncControllerProvider).value;
  if (status == null) return 'the round finished and left no status at all';
  return '${status.health.name}: ${status.pendingCount} pending, '
      '${status.heldCount} held, ${status.droppedOnArrivalCount} dropped';
}

/// Seeds a row on [screenshotTransport] this build's validator cannot parse —
/// the likeliest real cause, per task 11.41: a teammate on a newer build sends
/// an enum this one has never heard of.
///
/// **Written straight onto the server, not pushed.** `seedServerRow` bypasses
/// the fake's own `RowValidator` pass — which a real device's own push never
/// could — so the invalid value survives to be pulled, exactly as a newer
/// build's row would arrive on this one.
void seedUnreadableServerRecord() {
  final row = Observation(
    observationId: 'screenshot-obs-unreadable',
    projectId: seedProjectId,
    userId: ownerUserId,
    timestampLocal: seedLocal.add(const Duration(hours: 4)),
    timestampUtc: seedUtc.add(const Duration(hours: 4)),
    timezoneOffset: seedOffset,
    latitude: seedLat,
    longitude: seedLon,
    positionSource: PositionSource.gpsFix,
    elevation: 1300.0,
    observationType: ObservationType.omnidirectional,
    signalType: SignalType.regularPulse,
    signalStrength: SignalStrength.medium,
    sync: SyncMeta.initial(
      now: seedUtc,
      modifiedBy: steensOwnerUserId,
      originDeviceId: 'seed-device-B',
    ),
  ).toColumns();
  // Not a real `SignalStrength` value — the whole point.
  row['signal_strength'] = 'blisteringly_loud';
  screenshotTransport.seedServerRow(Tables.observations, row);
}

/// Inserts one unsynced local observation and tells [screenshotTransport] to
/// refuse it — a record only this device holds (finding D-3, task 10.28).
Future<void> seedRefusedObservation(ProviderContainer container) async {
  final observations = await container.read(observationRepositoryProvider.future);
  const id = 'screenshot-obs-refused';
  await observations.insert(Observation(
    observationId: id,
    projectId: seedProjectId,
    userId: ownerUserId,
    timestampLocal: seedLocal.add(const Duration(hours: 5)),
    timestampUtc: seedUtc.add(const Duration(hours: 5)),
    timezoneOffset: seedOffset,
    latitude: seedLat,
    longitude: seedLon,
    positionSource: PositionSource.gpsFix,
    elevation: 1300.0,
    observationType: ObservationType.omnidirectional,
    signalType: SignalType.regularPulse,
    signalStrength: SignalStrength.medium,
    sync: SyncMeta.initial(
      now: DateTime.now().toUtc(),
      modifiedBy: ownerUserId,
      originDeviceId: seedDeviceId,
    ),
  ));
  screenshotTransport.refuseRows['${Tables.observations}/$id/$seedProjectId'] =
      SyncRowOutcome.unauthorized;
}

/// Closes this device's own membership on [screenshotTransport] and makes it
/// answer as a real removal would (tasks 11.54, 11.60): push and ack refused
/// with a `403`, and the pull answering with the closed membership row on its
/// own, in an otherwise ordinary `200`.
void closeOwnerMembership() {
  screenshotTransport.seedServerRow(Tables.projectMemberships, {
    'membership_id': 'seed-membership-owner',
    'project_id': seedProjectId,
    'user_id': ownerUserId,
    'join_date': DbCodec.encodeUtc(seedUtc),
    'end_date': DbCodec.encodeUtc(seedUtc.add(const Duration(hours: 6))),
    'role': ProjectRole.owner.db,
    'created_at': DbCodec.encodeUtc(seedUtc),
    'updated_at': DbCodec.encodeUtc(seedUtc.add(const Duration(hours: 6))),
    'revision': 2,
    'last_modified_by': ownerUserId,
    'origin_device_id': 'seed-device-B',
  });
  screenshotTransport.closedMembershipProjects.add(seedProjectId);
}

/// **Makes [projectId] the open project and lets the sync controller rebuild
/// for it, with a last-sync stamp from the fixture's own timeline** (`/w-32`).
///
/// A round run straight after switching the active project asks the controller
/// about the project it *was* on: the first attempt at the *Project deleted*
/// picture ran its round against Owyhee's leftover ended-membership state, did
/// nothing, and photographed Steens reading "Synced" with the real date in it.
/// The controller is invalidated and awaited, as [activateJoinedDevice] does,
/// and the stamp is written first so the one date the screen prints is the same
/// on every regeneration.
Future<void> openProjectForRound(
  ProviderContainer container,
  String projectId,
) async {
  await setActiveProject(container, projectId);
  final store = container.read(syncStateStoreProvider);
  await store.setLastSuccessAt(projectId, seedLastSyncedAt);
  container.invalidate(syncControllerProvider);
  await container.read(syncControllerProvider.future);
}
