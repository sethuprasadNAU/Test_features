import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:tritrack/data/auth/auth_client.dart';
import 'package:tritrack/data/db/app_database.dart';
import 'package:tritrack/data/sync/server_identity_adopter.dart';
import 'package:tritrack/data/sync/sync_state_store.dart';
import 'package:tritrack/data/sync/sync_transport.dart';
import 'package:tritrack_sync/tritrack_sync.dart';
import 'package:uuid/uuid.dart';

import 'e2e_env.dart';
import 'magic_link_reader.dart';

/// One device's worth of client-side state for the e2e suite: its own
/// database, its own device id, its own `http.Client`, and (after
/// [signIn]) its own session token and adopted `user_id`.
///
/// Deliberately mirrors what a real device is — a fresh
/// `AppDatabase.openInMemory()` per instance, never shared, so two
/// [E2eDevice]s in the same test genuinely exercise cross-process
/// convergence rather than two references to one database.
///
/// [SyncStateStore] is backed by `SharedPreferencesAsync`, which has no
/// platform-channel here (`flutter test` under the Dart VM), and captures
/// whatever `SharedPreferencesAsyncPlatform.instance` happens to be set to
/// **at construction time** — it is read once in the constructor, not on
/// every call. That makes swapping the global instance to a fresh
/// `InMemorySharedPreferencesAsync` immediately before each device's
/// `SyncStateStore` is built enough to give every device its own
/// independent backing store, without `SyncStateStore` itself gaining a
/// per-instance override it has no reason to carry in production.
class E2eDevice {
  E2eDevice._(this.db, this.deviceId, this.httpClient, this.state);

  static Future<E2eDevice> create() async {
    final db = await AppDatabase.openInMemory();
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
    final state = SyncStateStore(prefs: SharedPreferencesAsync());
    final device = E2eDevice._(
      db,
      'e2e-device-${randomId()}',
      http.Client(),
      state,
    );
    // **The device closes itself.** Registered here rather than left to each
    // test's `tearDown`, and the reason is a measured one: on 2026-08-27 an
    // unconfigured run failed in `setUp` at the *second* device's `signIn`,
    // so the second `late E2eDevice` was never assigned — and the `tearDown`
    // that closed it threw `LateInitializationError: Local 'stranger' has not
    // been initialized`, which was then printed alongside every real failure.
    // Half the output of that run was a cleanup error about a variable, on
    // top of the actual message.
    //
    // A tear-down registered by the thing being created cannot fire for a
    // thing that was not created. It also means a test that makes a device
    // mid-body inherits the cleanup instead of having to remember it.
    addTearDown(device.close);
    return device;
  }

  final AppDatabase db;
  final String deviceId;
  final http.Client httpClient;
  final SyncStateStore state;

  String? _sessionToken;
  String? _userId;
  String? _email;
  String? _firstName;
  String? _lastName;

  String get userId =>
      _userId ?? (throw StateError('signIn() has not completed'));
  String get sessionToken =>
      _sessionToken ?? (throw StateError('signIn() has not completed'));
  String get signedInEmail =>
      _email ?? (throw StateError('signIn() has not completed'));
  String get firstName => _firstName ?? 'E2E';
  String get lastName => _lastName ?? 'Tester';

  SyncTransport transport() => HttpSyncTransport(
    httpClient: httpClient,
    baseUrl: E2eEnv.requireBaseUrl,
    sessionToken: sessionToken,
  );

  /// Requests a real magic link, reads the real token back off disk, redeems
  /// it against the real server, and adopts the resulting `user_id` — the
  /// exact sequence `CurrentSession.completeSignIn` performs, replicated here
  /// because that method lives behind Riverpod providers this bare harness
  /// doesn't construct. See `auth_provider.dart`'s doc comment for why the
  /// order (redeem, then adopt, then keep the session) is load-bearing.
  /// **Puts [joiner] onto [projectId] the way the product actually does it**
  /// (task 11.81) — this device is the owner, [joiner] asks with the code, and
  /// this device approves.
  ///
  /// **Never a membership row seeded straight into the table.** The point of
  /// running this against a real server is that the membership under test is
  /// the one the product produces, through the routes it produces it with; a
  /// seeded row would pass just as well against a build where approval had
  /// stopped working.
  ///
  /// Shared here rather than copied into each file, because before this every
  /// e2e test wrote its own two-call sequence inline and they were already
  /// drifting.
  Future<void> admit(
    E2eDevice joiner, {
    required String projectId,
    ProjectRole role = ProjectRole.contributor,
    String? claimedName,
  }) async {
    // Switching joining on is what mints the first code.
    final settings = await transport().updateJoinSettings(
      projectId: projectId,
      joiningEnabled: true,
    );
    await joiner.transport().requestToJoin(
      code: settings.code!,
      claimedName: claimedName,
    );
    final pending = (await transport().joinRequests(
      projectId,
    )).where((r) => r.isPending).toList();
    await transport().approveJoinRequest(
      projectId: projectId,
      requestId: pending.single.requestId,
      role: role,
    );
  }

  Future<void> signIn(
    String email, {
    String firstName = 'E2E',
    String lastName = 'Tester',
  }) async {
    final auth = AuthClient(httpClient: httpClient, baseUrl: E2eEnv.requireBaseUrl);
    // Captured *before* the request, so the link this run is waiting for is
    // distinguishable from the one a previous run left in the same file
    // (task 11.37, item 4).
    final requestedAt = DateTime.now().toUtc();
    await auth.requestMagicLink(email);
    final token = await waitForMagicLinkToken(email, issuedAfter: requestedAt);
    final redeemed = await auth.redeem(token: token, deviceId: deviceId);

    await ServerIdentityAdopter(db.raw).adopt(
      serverUserId: redeemed.userId,
      email: redeemed.email,
      firstName: firstName,
      lastName: lastName,
      deviceId: deviceId,
      now: DateTime.now().toUtc(),
    );

    _sessionToken = redeemed.token;
    _userId = redeemed.userId;
    _email = redeemed.email;
    _firstName = firstName;
    _lastName = lastName;
  }

  /// Pushes this device's own `Users` row, standing in for the step
  /// `ProjectExporter.collect` performs automatically for any real publish.
  /// Needed before any raw, hand-crafted push that references [userId] as a
  /// foreign key and does not go through `ProjectPublisher` — see
  /// [userRow]'s doc comment.
  ///
  /// [projectId] only matters for the project-level access check (`Users`
  /// itself has no project scope) — pass whichever project this device
  /// already owns, or is about to publish.
  Future<void> pushOwnUserRow({
    required String projectId,
    required DateTime now,
  }) => transport().push(
    SyncPushRequest(
      projectId: projectId,
      deviceId: deviceId,
      rows: {
        Tables.users: [userRow(this, now: now)],
      },
    ),
  );

  /// Pushes this device's own `Users` row and a fresh `Projects` row it
  /// owns, in one request — the minimal server-side state a raw,
  /// hand-crafted push test needs before it can push anything that
  /// references [projectId] (an `Observations` row's `project_id` foreign
  /// key needs the `Projects` row to exist, same reasoning as
  /// [pushOwnUserRow]). Both land in the same push; the server processes
  /// rows in FK-safe order internally regardless of this map's iteration
  /// order (`SyncService.applyPush`), so putting Users before Projects here
  /// is for a human reader, not a requirement.
  Future<void> pushOwnUserAndProject({
    required String projectId,
    required DateTime now,
  }) => transport().push(
    SyncPushRequest(
      projectId: projectId,
      deviceId: deviceId,
      rows: {
        Tables.users: [userRow(this, now: now)],
        Tables.projects: [
          projectRow(
            projectId: projectId,
            ownerId: userId,
            deviceId: deviceId,
            now: now,
          ),
        ],
      },
    ),
  );

  bool _closed = false;

  /// Safe to call more than once — [create] registers this, and a test that
  /// also closes explicitly must not fail on the second call.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await db.close();
    httpClient.close();
  }
}

/// A short, collision-resistant suffix for building per-test emails, project
/// ids, and device ids. The real server's Postgres persists across test runs
/// (unlike the server's own test suite, which drops and recreates its schema
/// per test) — every identifier this suite mints must therefore be unique
/// across runs, not just within one.
String randomId() => const Uuid().v4().substring(0, 8);

String randomEmail() => 'e2e-${randomId()}@example.invalid';

/// A `Projects` row owned by [ownerId].
///
/// **Authorization does not depend on a membership row existing at all** —
/// `ProjectAuthorizer`/`RowAuthorizer` resolve ownership from
/// `Projects.owner_user_id` directly, never by trusting a membership row's
/// `role` (a membership row claiming `owner` proves nothing on its own; see
/// `RowAuthorizer`'s `projectOwner` handling). But the real app still
/// *creates* one at project-creation time regardless
/// (`project_setup_screen.dart`, task 8.4: "every project gets an owner
/// membership row at creation time"), and `/projects/mine`
/// (`ProjectDirectoryService`) is driven entirely off that table — so a
/// project with no membership row publishes fine but never appears in its
/// own owner's join-from-a-second-device list. [seedLocalProject] creates
/// both rows to match.
Map<String, Object?> projectRow({
  required String projectId,
  required String ownerId,
  required String deviceId,
  required DateTime now,
  String name = 'E2E Project',
}) {
  final stamp = DbCodec.encodeUtc(now);
  return {
    'project_id': projectId,
    'project_name': name,
    'owner_user_id': ownerId,
    'creation_date': stamp,
    'datum': 'WGS84',
    'created_at': stamp,
    'updated_at': stamp,
    'revision': 0,
    'last_modified_by': ownerId,
    'origin_device_id': deviceId,
    'coordinate_format': 'dd',
    'triangulation_window_minutes': 15,
  };
}

/// The owner's own `Project_Memberships` row — see [projectRow]'s doc
/// comment for why this exists alongside `owner_user_id` rather than instead
/// of it.
Map<String, Object?> ownerMembershipRow({
  required String projectId,
  required String ownerId,
  required String deviceId,
  required DateTime now,
}) {
  final stamp = DbCodec.encodeUtc(now);
  return {
    'membership_id': 'e2e-mem-${randomId()}',
    'project_id': projectId,
    'user_id': ownerId,
    'join_date': stamp,
    'end_date': null,
    'role': 'owner',
    'created_at': stamp,
    'updated_at': stamp,
    'revision': 0,
    'last_modified_by': ownerId,
    'origin_device_id': deviceId,
  };
}

/// Inserts [projectRow]'s and [ownerMembershipRow]'s output into [db] — the
/// local-only half of what a real "create a project" screen action does
/// (task 8.4 creates both rows; see [projectRow]'s doc comment) — **and, by
/// default, one tag with its `Tag_Versions` row.**
///
/// ## Why the tag is on by default (task 11.118)
///
/// A project with a tag is not an elaborate fixture. It is the **ordinary**
/// project: task 11.32 gives every tag a `Tag_Versions` row the moment it is
/// created, so the first tag somebody adds produces all three rows, and a
/// project with none of them is one nobody has started using yet.
///
/// This defaulted to *off* until task 11.118, and the cost is measured rather
/// than supposed. **Seventeen of this repository's nineteen publish fixtures
/// published a project with no tag**, so for a month the entire end-to-end
/// suite was green while every real first publish refused a `Tag_Versions`
/// row and showed the person a red banner saying this "is not a case the app
/// expects" — on the first thing they ever did with a server. Task 11.43
/// found it by hand, and closed it by adding **one** case
/// (`publish_and_join_e2e_test.dart`) that opted *in*. Opting in is the wrong
/// polarity: it leaves the ordinary case as the one a fixture has to
/// remember to ask for, which is exactly how the population got this way.
///
/// **So the rule this builder encodes: the default fixture is the ordinary
/// field project, and a simpler one is what a test asks for explicitly.**
/// [withTag] is the opt-out, and a caller passing `false` should say why —
/// "this test is about membership and a tag would only add rows" is a good
/// reason, and a deliberately minimal fixture is a fine thing. What is not
/// fine is a *systematically* minimal population, which is what this had.
///
/// **What it does not do**, said rather than left to be discovered: it seeds
/// one tag, not a season of them, and every row still carries the single
/// [now] instant. See `test/e2e/publish_corpus_test.dart`, which measures the
/// gap that remains and names the tables no publish fixture has ever carried.
Future<void> seedLocalProject(
  Database db, {
  required String projectId,
  required String ownerId,
  required String deviceId,
  required DateTime now,
  String name = 'E2E Project',
  bool withTag = true,
  String tagName = 'Collar 7',
}) async {
  await db.insert(
    Tables.projects,
    projectRow(
      projectId: projectId,
      ownerId: ownerId,
      deviceId: deviceId,
      now: now,
      name: name,
    ),
  );
  await db.insert(
    Tables.projectMemberships,
    ownerMembershipRow(
      projectId: projectId,
      ownerId: ownerId,
      deviceId: deviceId,
      now: now,
    ),
  );
  if (withTag) {
    await seedLocalTag(
      db,
      projectId: projectId,
      ownerId: ownerId,
      deviceId: deviceId,
      now: now,
      name: tagName,
    );
  }
}

/// One tag, its `Tag_Versions` row, and the `Individuals` row it names —
/// the three rows the app writes when somebody adds a tag to a project
/// (tasks 11.32 and 11.240).
///
/// Returns the new `tag_id`, so a caller can hang a bearing off it.
///
/// **All three, always.** A `Tags` row without its version is a shape the
/// app cannot produce, and since task 11.240 `TagRepository.insert` names an
/// animal for every tag handed in without one, so a tag with nobody named
/// is the opt-out rather than the default; a fixture that produced either
/// would be testing a state no device is ever in. Colour lives on the
/// animal and the tag's own `color_hex` is written null, as the app does.
///
/// **It was three rows until task 11.219, two after it, and three again
/// since 11.240.** The row 11.219 removed was the `Project_Tags` link, gone
/// with the wire: a tag carries its own `project_id` now. That also retired
/// the ordering constraint the version row used to be the reason for — see
/// `offer_order.dart`, which keeps the guard and has nothing left to order.
/// The row 11.240 added is the parent the tag's foreign key wants, offered
/// before `Tags` in `Tables.all`.
Future<String> seedLocalTag(
  Database db, {
  required String projectId,
  required String ownerId,
  required String deviceId,
  required DateTime now,
  String name = 'Collar 7',
  double frequencyMhz = 150.123,
}) async {
  final stamp = DbCodec.encodeUtc(now);
  final tagId = 'e2e-tag-${randomId()}';
  final individualId = 'e2e-ind-${randomId()}';
  await db.insert(Tables.individuals, {
    'individual_id': individualId,
    'project_id': projectId,
    'name': name,
    'color_hex': '#4C72B0',
    'status': 'alive',
    'species': null,
    'sex': null,
    'notes': null,
    'lineage_id': individualId,
    'copied_at': null,
    'created_at': stamp,
    'updated_at': stamp,
    'revision': 0,
    'last_modified_by': ownerId,
    'origin_device_id': deviceId,
  });
  await db.insert(Tables.tags, {
    'tag_id': tagId,
    'project_id': projectId,
    'lineage_id': tagId,
    'frequency_mhz': frequencyMhz,
    'pulse_rate': null,
    'pulse_pattern': null,
    'tag_name': name,
    'status': 'active',
    'notes': null,
    'created_at': stamp,
    'updated_at': stamp,
    'revision': 0,
    'last_modified_by': ownerId,
    'origin_device_id': deviceId,
    'color_hex': null,
  });
  // **Task 11.243: the dated link is its own row.** The collar named its
  // animal on the tag row until schema v17; it is a `Deployments` row now,
  // and the e2e corpus needs one so the publish fixtures carry the join a
  // real project has.
  await db.insert(Tables.deployments, {
    'deployment_id': 'e2e-dep-${randomId()}',
    'project_id': projectId,
    'tag_id': tagId,
    'individual_id': individualId,
    'attached_date': stamp,
    'removed_date': null,
    'notes': null,
    'created_at': stamp,
    'updated_at': stamp,
    'revision': 0,
    'last_modified_by': ownerId,
    'origin_device_id': deviceId,
  });
  await db.insert(Tables.tagVersions, {
    'tag_version_id': 'e2e-ver-${randomId()}',
    'project_id': projectId,
    'tag_id': tagId,
    'effective_from': stamp,
    'frequency_mhz': frequencyMhz,
    'pulse_rate': null,
    'pulse_pattern': null,
    'tag_name': name,
    'created_at': stamp,
    'updated_at': stamp,
    'revision': 0,
    'last_modified_by': ownerId,
    'origin_device_id': deviceId,
  });
  return tagId;
}

/// A `Users` row for an already-signed-in [device].
///
/// Needed by any test that pushes a hand-crafted row referencing
/// `owner_user_id`/`user_id`/`last_modified_by` directly through
/// `HttpSyncTransport`, bypassing `ProjectPublisher`. `ProjectPublisher`
/// (via `ProjectExporter.collect`) always gathers and uploads every `Users`
/// row a project's data references, so this never comes up through the
/// normal client path — but `signIn()` only creates the row **locally**;
/// nothing pushes it to the server until something does. A raw push of a
/// `Projects`/`Observations`/etc. row naming this device's `userId` before
/// its `Users` row exists server-side fails Postgres's foreign key, same as
/// the fixture bug task 10.9's own test suite hit for the same reason.
Map<String, Object?> userRow(E2eDevice device, {required DateTime now}) {
  final stamp = DbCodec.encodeUtc(now);
  return {
    'user_id': device.userId,
    'first_name': device.firstName,
    'last_name': device.lastName,
    'email': normalizeEmail(device.signedInEmail),
    'created_at': stamp,
    'updated_at': stamp,
    'revision': 0,
    'last_modified_by': device.userId,
    'origin_device_id': device.deviceId,
  };
}

Map<String, Object?> observationRow(
  String id, {
  required String projectId,
  required String userId,
  required String deviceId,
  required DateTime now,
  int revision = 1,
  String? notes,
  String? tagId,
}) {
  final stamp = DbCodec.encodeUtc(now);
  return {
    'observation_id': id,
    'tag_id': tagId,
    'project_id': projectId,
    'user_id': userId,
    'timestamp_local': stamp,
    'timestamp_utc': stamp,
    'timezone_offset': '+00:00',
    'latitude': 35.1983,
    'longitude': -111.6513,
    'position_source': 'gps_fix',
    'elevation': 2106.4,
    'altitude_agl': 1.5,
    'observation_type': 'directional',
    'signal_type': 'regular_pulse',
    'signal_strength': 'strong',
    'notes': notes,
    'created_at': stamp,
    'updated_at': stamp,
    'revision': revision,
    'last_modified_by': userId,
    'origin_device_id': deviceId,
  };
}

/// A `Tags` row whose **edit stamp names somebody the project does not reach**
/// (task 11.36, the gap task 11.47 left behind).
///
/// `last_modified_by` records *who last edited this*, not who the record is
/// about, and `Tags` is shared project vocabulary that names no author at all
/// ([MutationRule.anyUser]). Task 11.47 decided that a foreign name in such a
/// column may be replicated — because the alternative was measured and it is
/// worse: a tag refused for naming the colleague who last renamed it makes
/// every bearing **of the pusher's own** that uses that tag point at something
/// the server does not hold, so a note about somebody else's rename blocked a
/// person's own field data from ever reaching the server.
///
/// **[formerColleagueUserId] must name somebody who is not a member of the
/// project, and that is the whole load-bearing part of this fixture.** Written
/// first with a *current* member, this fixture proved nothing: the server has a
/// second, older reason to accept a foreign name — §4.17 clause 2, *"this
/// project already reaches them"* — and a member satisfies it, so the row
/// landed with 11.47's relaxation deliberately reverted and the test went green
/// against the build it existed to catch. Caught by watching it fail and seeing
/// it pass. The person 11.47 is actually about is the colleague who handed over
/// an archive and moved on: clause 2 can never come true for them, so their
/// name on a tag held the pusher's own bearings **forever** rather than pending
/// anything.
///
/// **Every other fixture in this file stamps its rows with the pusher**, which
/// is why no app-side test had ever exercised that decision — and why, had
/// 11.47 relaxed *authorship* along with the audit column and undone task
/// 11.24, a plain `flutter test` would still have gone green. This is the
/// fixture that makes that impossible; see [bearingAuthoredByAColleague],
/// which is the other half and must be refused.
///
/// Deliberately a pure function of ids rather than of [E2eDevice]s: the
/// coverage guard (`suite_coverage_test.dart`) calls it with two invented ids
/// and checks against [tableMutationRules] that the row it returns really does
/// carry a foreign name in the audit column of a table whose rule permits one.
/// A fixture that stopped doing so would otherwise still satisfy a test that
/// merely called it.
Map<String, Object?> tagLastEditedByAFormerColleague({
  required String tagId,
  required String projectId,
  required String formerColleagueUserId,
  required String deviceId,
  required DateTime now,
  double frequencyMhz = 150.123,
  String name = 'Renamed by a colleague',
}) {
  final stamp = DbCodec.encodeUtc(now);
  return {
    'tag_id': tagId,
    // A tag belongs to a project since task 11.219 — which is also what
    // retired the `Project_Tags` row this fixture used to travel with.
    'project_id': projectId,
    'lineage_id': tagId,
    'frequency_mhz': frequencyMhz,
    'pulse_rate': null,
    'pulse_pattern': null,
    'tag_name': name,
    'status': 'active',
    'notes': null,
    'created_at': stamp,
    'updated_at': stamp,
    'revision': 0,
    // The whole point of this fixture.
    'last_modified_by': formerColleagueUserId,
    'origin_device_id': deviceId,
    'color_hex': '#4C72B0',
  };
}

/// An `Observations` row **authored by somebody who is not the pusher** — the
/// boundary [tagLastEditedByAColleague] must not be allowed to cross.
///
/// `Observations` is [MutationRule.author]: the row names who made the
/// measurement, and task 11.24's rule is that such a row is only accepted from
/// that person's own device. Michael's decision of 2026-08-28 — a record
/// restored from a colleague's archive keeps their name — is what makes that
/// permanent, so this row is expected to come back `unauthorized` and that is
/// an accepted outcome rather than a defect.
///
/// **Pushed in the same request as the tag, deliberately.** A test that only
/// showed the audit stamp being accepted would pass just as well against a
/// build that had wrongly relaxed identity columns too; the two claims are
/// only pinned by being made of one server, at one moment, over one push.
///
/// **[colleagueUserId] must name a *current member* of the project — the
/// opposite requirement from [tagLastEditedByAFormerColleague], and for the
/// same underlying reason.** If it named a stranger the row would be refused by
/// §4.17 clause 2 (*"this project already reaches them"*) whatever task 11.24
/// said, so a build that had wrongly relaxed authorship would still refuse it
/// and this fixture would stop being able to detect the thing it exists for.
/// Each half isolates its own cause: the tag's stamp names somebody clause 2
/// cannot vouch for, this row's author is somebody it can.
Map<String, Object?> bearingAuthoredByAColleague(
  String observationId, {
  required String projectId,
  required String colleagueUserId,
  required String deviceId,
  required DateTime now,
  String? tagId,
}) => observationRow(
  observationId,
  projectId: projectId,
  userId: colleagueUserId,
  deviceId: deviceId,
  now: now,
  tagId: tagId,
);

/// A truth point — `Actual_Tag_Locations`, where somebody found the collar.
///
/// **No publish fixture in this repository had ever carried one** until task
/// 11.118 counted them: six of the thirteen synced tables had never been
/// through a publish in any test, and this is the one whose *shape* makes
/// that matter rather than merely being a gap.
///
/// It is the table task 11.47 predicted a tripwire for and task 11.93 then
/// built: `MutationRule.anyUser` — so §4.17 permits a foreign edit stamp —
/// **and** an identity column (`user_id`, who walked in and found it) — so
/// `RowAuthorizer._authorizeNaming` applies to the same row. Nothing else in
/// `syncTables` has both. It also carries a `tag_id`, which puts it under
/// `_authorizeTagReferences` and therefore under `offer_order.dart`'s
/// establish-reach-before-it-is-needed constraint.
///
/// A row combining all three had never been on the wire from a publish.
Map<String, Object?> truthPointRow(
  String id, {
  required String projectId,
  required String tagId,
  required String userId,
  required String deviceId,
  required DateTime now,
  String? notes,
}) {
  final stamp = DbCodec.encodeUtc(now);
  return {
    'location_id': id,
    'project_id': projectId,
    'tag_id': tagId,
    'user_id': userId,
    'timestamp_local': stamp,
    'timestamp_utc': stamp,
    'timezone_offset': '+00:00',
    'latitude': 35.2011,
    'longitude': -111.6489,
    'uncertainty_radius': 12.5,
    'notes': notes,
    'created_at': stamp,
    'updated_at': stamp,
    'revision': 0,
    'last_modified_by': userId,
    'origin_device_id': deviceId,
  };
}
