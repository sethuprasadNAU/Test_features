import 'package:shared_preferences/shared_preferences.dart';

import 'project_deletion_notice.dart';
import 'remembered_sync_failure.dart';
import 'sync_schedule.dart';

/// Sync bookkeeping this device keeps for itself — per project, except for the
/// two device-wide values noted where they are declared.
///
/// Stored in `SharedPreferences` rather than the database on purpose: none of
/// it is project *data*, none of it syncs, and putting it in a synced table
/// would mean one device's cursor propagating to another — which is precisely
/// the confusion the per-`(user, device)` cursor keying exists to prevent. It
/// also keeps it out of `tableSpecs`, so it cannot drift into the shared
/// schema contract.
///
/// Nothing here is a secret. The session token lives in the keychain
/// (`SessionStore`); a cursor position and a timestamp are not credentials.
class SyncStateStore {
  SyncStateStore({SharedPreferencesAsync? prefs})
    : _prefs = prefs ?? SharedPreferencesAsync();

  final SharedPreferencesAsync _prefs;

  /// **Not per project, unlike everything below it** (task 11.59). "How often
  /// may this app reach out on its own" is a property of the device and the
  /// person's data plan, not of whichever project happens to be open; keying
  /// it per project would mean somebody who turned automatic sync off before a
  /// satellite trip had it back on the moment they switched projects.
  static const _frequencyKey = 'sync_frequency_v1';
  static const _lastAttemptKey = 'sync_last_attempt_v1';

  /// When this device last dismissed the stale-sync warning (task 11.114).
  ///
  /// **Device-wide, beside [_frequencyKey] and [_lastAttemptKey]**, not keyed
  /// per project — the design decided with Michael on 2026-09-01 put it here
  /// rather than per project, matching how those two are already stored. The
  /// dismissal re-arms at the next 04:00 local time after this timestamp; see
  /// `SyncStatus.health`, which is where that arithmetic lives so the rule is
  /// checked in exactly one place.
  static const _staleDismissedAtKey = 'sync_stale_dismissed_at_v1';

  /// Join requests this device has already acted on automatically (task
  /// 11.83). Device-wide, and keyed by request id — which is globally unique,
  /// so a second person signing in on the same device can never collide with
  /// the first one's entries.
  static const _autoJoinedKey = 'join_auto_joined_requests_v1';

  /// How many acted-on request ids to remember.
  ///
  /// Above the server's own `maxJoinRequestsReturned` (200), so this list can
  /// never forget an id the server is still reporting — which is the one way
  /// forgetting would matter: a request that fell off the end here and is
  /// still approved there would be joined a second time, resurrecting a
  /// project somebody had deliberately deleted.
  static const _autoJoinedKeep = 250;

  /// Whether this device has join business that is not finished (task 11.83)
  /// — an undecided request, or an approval whose download stopped partway.
  ///
  /// **This is what keeps the foreground check off every other device.** It is
  /// durable because the question survives a restart and the answer cannot be
  /// derived locally any other way: "have I been approved yet" can only be
  /// answered by asking the server, so a device that could not tell whether it
  /// had anything to ask about would have to ask on every foreground forever.
  static const _joinWorkPendingKey = 'join_work_pending_v1';

  /// What this device last learned about each project's scheduled deletion
  /// (task 11.290) — one JSON map, keyed by project id. See
  /// [ProjectDeletionNotice] for what it is and is not.
  ///
  /// **Not cleared by [clear], deliberately.** Everything [clear] removes
  /// describes *this identity's* relationship with the project — its cursor,
  /// its linked flag, the refusal it was last given. A deletion date is a
  /// fact about the project, true whoever signs in next, and the row that
  /// shows it is the one place a person holding the records is told to
  /// export before they go.
  static const _deletionNoticesKey = 'project_deletion_notices_v1';

  String _cursorKey(String projectId) => 'sync_cursor_v1_$projectId';
  String _failureKey(String projectId) => 'sync_last_failure_v1_$projectId';
  String _lastSuccessKey(String projectId) => 'sync_last_success_v1_$projectId';
  String _linkedKey(String projectId) => 'sync_project_linked_v1_$projectId';
  String _databaseIdKey(String projectId) => 'sync_database_id_v1_$projectId';
  String _databaseChangedAtKey(String projectId) =>
      'sync_database_changed_at_v1_$projectId';

  /// Whether this project has been **explicitly** published or joined
  /// (task 10.9).
  ///
  /// Sync (automatic or manual) only ever operates on a project this returns
  /// true for. Without that gate, tapping "sync now" while an ordinary
  /// offline-only project happened to be active would silently publish it —
  /// the opposite of the deliberate, explicit action "an owner turns a local
  /// project into a server project" describes. Set once, by
  /// `ProjectPublisher.publish` or `ProjectJoiner.join`, and never
  /// automatically.
  Future<bool> isProjectLinked(String projectId) async =>
      await _prefs.getBool(_linkedKey(projectId)) ?? false;

  Future<void> markProjectLinked(String projectId) =>
      _prefs.setBool(_linkedKey(projectId), true);

  /// The highest `server_seq` this device has **committed locally**.
  ///
  /// This is the value sent on every pull, and it is authoritative for what the
  /// server delivers — see the protocol's `SyncPullRequest.cursor`. It advances
  /// only after a page has been merged into the local database, so a crash
  /// mid-page re-receives that page rather than skipping it.
  Future<int> cursor(String projectId) async =>
      await _prefs.getInt(_cursorKey(projectId)) ?? 0;

  Future<void> setCursor(String projectId, int cursor) =>
      _prefs.setInt(_cursorKey(projectId), cursor);

  /// **Which server database the cursor above, and this project's row
  /// receipts, were minted against** (task 11.58) — the identifier the server
  /// returns on every push and pull. Null until the first round against a
  /// server that sends one.
  ///
  /// The cursor is a position in one database's numbering and a receipt is a
  /// statement about what one database holds; until this existed neither said
  /// which, so a device pointed at a restored or rebuilt server kept both and
  /// reported clean syncs that moved nothing. `SyncEngine` compares this with
  /// what each response says and starts the project over when they differ.
  ///
  /// **Kept by [clear], deliberately** — see there.
  Future<String?> databaseId(String projectId) =>
      _prefs.getString(_databaseIdKey(projectId));

  Future<void> setDatabaseId(String projectId, String databaseId) =>
      _prefs.setString(_databaseIdKey(projectId), databaseId);

  /// **When this device last found the server's database had been replaced
  /// under this project** (task 11.58), for the one sentence the sync status
  /// screen says about it. Null if it never has.
  Future<DateTime?> databaseChangedAt(String projectId) async {
    final raw = await _prefs.getString(_databaseChangedAtKey(projectId));
    return raw == null ? null : DateTime.tryParse(raw)?.toUtc();
  }

  Future<void> setDatabaseChangedAt(String projectId, DateTime at) =>
      _prefs.setString(
        _databaseChangedAtKey(projectId),
        at.toUtc().toIso8601String(),
      );

  /// **There is no push watermark here any more** (task 10.33). What to push is
  /// no longer a timestamp comparison against a per-project high-water mark: it
  /// is `SyncRowReceiptStore`, one durable receipt per row the server has
  /// confirmed, kept in SQLite next to the data it describes. A watermark could
  /// only ever approximate the pending set, and it approximated it in the
  /// direction that loses rows — past a row a batch limit never reached, and
  /// past an imported replica carrying its sender's older clock.
  ///
  /// `SyncRowReceiptStore.forgetProject` is what replaced
  /// `resetPushWatermark`'s "re-offer everything" escape hatch.
  Future<DateTime?> lastSuccessAt(String projectId) async {
    final raw = await _prefs.getString(_lastSuccessKey(projectId));
    return raw == null ? null : DateTime.tryParse(raw)?.toUtc();
  }

  Future<void> setLastSuccessAt(String projectId, DateTime at) => _prefs
      .setString(_lastSuccessKey(projectId), at.toUtc().toIso8601String());

  /// **The failure this device was last told about, or null if the last thing
  /// that happened was a success** (task 11.116).
  ///
  /// **Per project, beside [lastSuccessAt] and the cursor, rather than
  /// device-wide beside the frequency.** Half of `SyncFailureCause` is
  /// project-scoped — an ended membership, a refused project — and rendering
  /// project A's refusal on project B's bar would be a fresh instance of
  /// exactly the wrong-cause defect tasks 11.54, 11.104 and 11.113 each closed
  /// one at a time. The device-wide causes (no signal, a rejected certificate)
  /// are simply re-learned on the first attempt under the other project, which
  /// costs one round trip.
  ///
  /// An unreadable value reads as null — see `RememberedSyncFailure.decode`
  /// for why that direction is the safe one.
  Future<RememberedSyncFailure?> rememberedFailure(String projectId) async =>
      RememberedSyncFailure.decode(
        await _prefs.getString(_failureKey(projectId)),
      );

  Future<void> setRememberedFailure(
    String projectId,
    RememberedSyncFailure failure,
  ) => _prefs.setString(_failureKey(projectId), failure.encode());

  /// Forgets the remembered failure — called on a round that succeeded, and on
  /// the one refusal that is not a failure at all (the person is no longer a
  /// member, which has its own state and its own words).
  Future<void> clearRememberedFailure(String projectId) =>
      _prefs.remove(_failureKey(projectId));

  /// How often automatic sync may attempt (task 11.59).
  ///
  /// **Persisted, and that is the point of it being here at all.** Before this
  /// the on/off switch on the sync screen lived only in the controller's
  /// in-memory state, so it survived neither an app restart nor a rebuild of
  /// the provider — somebody who turned automatic sync off for a metered trip
  /// had it back on the next time they opened the app, and nothing said so.
  Future<SyncFrequency> frequency() async =>
      SyncFrequency.fromId(await _prefs.getString(_frequencyKey));

  Future<void> setFrequency(SyncFrequency frequency) =>
      _prefs.setString(_frequencyKey, frequency.id);

  /// When this device last *attempted* a sync — automatic or manual.
  ///
  /// **Also not per project, and it counts manual attempts too**, because it
  /// answers exactly one question: how long has it been since this app talked
  /// to the server. A manual "Sync now" two minutes ago is a reason not to
  /// attempt again on the next foreground, and forgetting it on restart is how
  /// "Hourly" would have meant "every cold launch, plus hourly" — a setting
  /// promising less than the code does, on a phone that is relaunched all day.
  ///
  /// The failure count behind the backoff curve is deliberately *not* kept
  /// here: a device that has been failing all day should make one cheap
  /// attempt when the app is opened afresh rather than staying in a two-hour
  /// backoff it can no longer see the reason for.
  ///
  /// **That is a statement about the backoff, not about the failure** — see
  /// [rememberedFailure], which task 11.116 added because the two are
  /// different questions. *How long to wait before trying again* starts fresh
  /// on a restart, by the decision above; *how much evidence there is that
  /// something is wrong* survives it, because otherwise a week-old refusal
  /// reported as a calm bar every time the app came back.
  Future<DateTime?> lastAttemptAt() async {
    final raw = await _prefs.getString(_lastAttemptKey);
    return raw == null ? null : DateTime.tryParse(raw)?.toUtc();
  }

  Future<void> setLastAttemptAt(DateTime at) =>
      _prefs.setString(_lastAttemptKey, at.toUtc().toIso8601String());

  /// Forgets the last attempt time, so the next `syncIfDue` check finds a
  /// round due immediately (task 11.62).
  ///
  /// Called when a session is established: someone who has just signed in
  /// again wants their data moving now, not after waiting out whatever
  /// interval the last device left behind — this is the persisted half of
  /// [SyncSchedule.resumed], which cannot reach this key on its own because
  /// `lastAttemptAt` lives here, in `SharedPreferences`, rather than in the
  /// in-memory schedule the controller rebuilds each launch.
  Future<void> clearLastAttemptAt() => _prefs.remove(_lastAttemptKey);

  /// When this device last dismissed the stale-sync warning, or `null` if it
  /// never has (task 11.114).
  Future<DateTime?> staleDismissedAt() async {
    final raw = await _prefs.getString(_staleDismissedAtKey);
    return raw == null ? null : DateTime.tryParse(raw)?.toUtc();
  }

  Future<void> setStaleDismissedAt(DateTime at) =>
      _prefs.setString(_staleDismissedAtKey, at.toUtc().toIso8601String());

  /// **Which approved join requests this device has already completed by
  /// itself** (task 11.83).
  ///
  /// The record exists to answer one question: *has this device already turned
  /// this approval into a project?* An approval stays approved on the server
  /// forever — nothing prunes decided requests — so without this, every check
  /// after the person deleted their copy of the project would see the same
  /// approval, find no live local row, and download it again. A project
  /// somebody deliberately deleted must not come back on its own.
  ///
  /// **Not cleared by [clear], and not by sign-out — nothing in this store is
  /// cleared by sign-out** (task 11.304). This list is the only record that
  /// an approval has already been turned into a project; if it were ever
  /// dropped, the next check would silently re-download every project the
  /// person had ever been approved for, the ones they deliberately deleted
  /// included. Choosing what to restore is what the "Join a project" list is
  /// for.
  Future<Set<String>> autoJoinedRequestIds() async =>
      (await _prefs.getStringList(_autoJoinedKey) ?? const <String>[]).toSet();

  /// Records [requestId] as acted on. Idempotent, and oldest-first bounded.
  ///
  /// **Written before the download starts, not after.** A first pull of a
  /// season's data can be interrupted, and a device that only remembered
  /// completed joins would start the whole thing again from the top on every
  /// foreground. Resuming an incomplete pull is decided from whether the
  /// project row is actually here, not from this list — see
  /// `JoinRequestWatcher`.
  Future<void> markRequestAutoJoined(String requestId) async {
    final current = await _prefs.getStringList(_autoJoinedKey) ?? const [];
    if (current.contains(requestId)) return;
    final next = [...current, requestId];
    await _prefs.setStringList(
      _autoJoinedKey,
      next.length <= _autoJoinedKeep
          ? next
          : next.sublist(next.length - _autoJoinedKeep),
    );
  }

  /// Whether this device is waiting on a join request, or on a download that
  /// an approval started and did not finish (task 11.83).
  ///
  /// **False is the state of every device that has never asked to join
  /// anything**, which is nearly all of them nearly all of the time — and that
  /// is the point: `JoinRequestWatcher` makes no automatic request of the
  /// server unless this is true, so the poll costs nothing on a device with no
  /// join business, exactly as the automatic-sync foreground hook costs
  /// nothing on a device with nothing stuck.
  Future<bool> joinWorkPending() async =>
      await _prefs.getBool(_joinWorkPendingKey) ?? false;

  Future<void> setJoinWorkPending(bool pending) =>
      _prefs.setBool(_joinWorkPendingKey, pending);

  /// Every deletion notice this device holds, keyed by project id.
  Future<Map<String, ProjectDeletionNotice>> deletionNotices() async =>
      ProjectDeletionNotice.decodeAll(
        await _prefs.getString(_deletionNoticesKey),
      );

  Future<ProjectDeletionNotice?> deletionNotice(String projectId) async =>
      (await deletionNotices())[projectId];

  /// Replaces [projectId]'s notice, or removes it when [notice] is null —
  /// which is what a `/projects/mine` row with no date means: the owner
  /// canceled, and the countdown comes down.
  Future<void> setDeletionNotice(
    String projectId,
    ProjectDeletionNotice? notice,
  ) async {
    final notices = Map.of(await deletionNotices());
    if (notice == null) {
      notices.remove(projectId);
    } else {
      notices[projectId] = notice;
    }
    await _prefs.setString(
      _deletionNoticesKey,
      ProjectDeletionNotice.encodeAll(notices),
    );
  }

  /// Forgets this device's relationship with one project on the server: the
  /// cursor, the last-success stamp, the linked flag and the remembered
  /// failure.
  ///
  /// **Called when the project has stopped being this person's to sync —
  /// never on sign-out.** Four paths reach it, and each has first established
  /// that the server no longer counts this device as on the project: a
  /// departure the server confirmed (`MembershipController.leave` and
  /// `SyncController.deliverPendingDepartures`), a refused round the device
  /// read as its stint having ended (`SyncController._unlinkIfWeAlreadyLeft`),
  /// and a project the server has destroyed
  /// (`ProjectDeletionNotices.markDestroyed`).
  ///
  /// **Signing out leaves every value in this store exactly where it is**
  /// (task 11.304). Until 2026-09-21 this comment said the opposite — that
  /// sign-out cleared every project so a later sign-in as somebody else would
  /// not inherit a stranger's cursor — and no caller ever did. Measured rather
  /// than argued: the same person signing back in resumes from the cursor they
  /// left, which is the common case and the cheap one; a different person
  /// signing in holds no membership row here, so the push offers nothing of
  /// the first person's and the server refuses the pull before reading
  /// anything — **and that refusal is then misread as the stint having
  /// ended, which brings the round here and unlinks the first person's
  /// project** (the same test's "Finding 3", filed by task 11.304 as a defect
  /// in the refusal's classification, not in this method).
  /// `test/core/providers/sign_out_leaves_sync_state_test.dart` is that
  /// measurement, and it fails if `CurrentSession.signOut` ever starts calling
  /// this.
  ///
  /// Row receipts are deliberately *not* cleared alongside these: a receipt is
  /// a statement about what **one particular server database** holds, which
  /// does not stop being true because this device is off the project.
  /// Dropping them would make a later rejoin re-upload the entire project for
  /// no benefit.
  ///
  /// **That qualifier is task 11.58's, and it is why [databaseId] is kept
  /// here too.** Until then this paragraph said only "what the server holds",
  /// and the reason it held was not the one written: it held because the
  /// server had not changed. A receipt kept across a *different* database
  /// keeps a row off that database's push set, silently and for good. So the
  /// identifier the receipts were minted against stays with them: a rejoin
  /// against the same database keeps them, and a rejoin against a restored or
  /// rebuilt one is noticed on its first round and starts over. Clearing the
  /// identifier while keeping the receipts would be the one combination that
  /// could not tell.
  ///
  /// The notice of a past database change *is* cleared: it describes this
  /// device's syncing of the project, which this ends.
  ///
  /// The frequency setting and the last-attempt stamp are **not** cleared:
  /// neither is about a project.
  Future<void> clear(String projectId) async {
    await _prefs.remove(_cursorKey(projectId));
    await _prefs.remove(_lastSuccessKey(projectId));
    await _prefs.remove(_linkedKey(projectId));
    // The remembered failure goes with them (task 11.116): it describes this
    // device's relationship with this project on this server, and a device
    // that later rejoins the project inheriting "access refused" would be told
    // its sync is broken by a refusal that is over.
    await _prefs.remove(_failureKey(projectId));
    await _prefs.remove(_databaseChangedAtKey(projectId));
  }
}
