/// The wire contract for the project join code and the owner's approval
/// (task 11.81, from task 11.74's design).
///
/// **What replaced what.** Until this task, joining a project meant redeeming a
/// per-address invitation: holding the code *was* membership, and the code was
/// bound to one email address, which was the only thing making an 8-character
/// code safe. That does not scale to a real field crew — one code per person,
/// typed by the owner, each expiring in 14 days. Now there is **one code per
/// project**, and holding it buys only **the right to ask**; the owner sees the
/// request and decides. A leaked code stops being a key and becomes an address.
///
/// A sibling of `project_directory.dart` and shaped the same way: the server
/// builds these, the app parses them, and every field goes through
/// [requireSyncString] so a present-but-wrong-typed field draws a typed
/// [SyncProtocolException] rather than an uncaught `TypeError` (task 10.64's
/// rule, and 10.67's sweep of the response side).
///
/// **Nothing here carries prose.** Per §4.13 no server-supplied text ever
/// becomes user-facing copy, so a refusal on any of these routes is a code the
/// app switches on — see `joinRefusal*` below — and the sentence the user reads
/// is written in the app. **Every refusal code added here needs app copy
/// written for it in the same change**, or the user gets a generic "something
/// went wrong" for a refusal the server took care to make actionable.
library;

import 'sync_protocol.dart';

// ---- Refusal codes: the contract -------------------------------------------

/// The one refusal every failed join request draws, whatever went wrong.
///
/// A wrong code, an unknown code, a code for a project whose owner has switched
/// joining off, and a code for a project that has been deleted are **one
/// answer**, deliberately. Splitting them would let somebody sweeping codes
/// learn which guesses named a real project, which is the existence oracle
/// §4.13 exists to close.
const String joinRefusalCodeNotValid = 'join_code_not_valid';

/// The caller already holds an open membership in the project this code names.
///
/// Distinct from [joinRefusalCodeNotValid] on purpose, and it discloses nothing:
/// only somebody holding a live code for a project they are already on can
/// reach it, and they are being told a fact about themselves. Answering the
/// uniform refusal here would tell a member their code was broken and send them
/// to the owner for a new one that would do nothing.
const String joinRefusalAlreadyMember = 'already_a_member';

/// The caller already has an undecided request on this project.
///
/// Discloses nothing for the same reason: it is a fact about the caller's own
/// request. Without it, somebody who tapped twice would be told their code was
/// invalid and would go and ask the owner for a new one.
const String joinRefusalAlreadyRequested = 'already_requested';

/// The project has reached its team-size limit.
///
/// **The app's copy for this must say that pending requests count toward the
/// limit** (task 11.81). They do — the count is open memberships of every role,
/// the owner included, plus undecided requests — and without that sentence an
/// owner looking at 40 members against a limit of 50 has no way to understand
/// the refusal, and neither does the person who was refused.
const String joinRefusalTeamFull = 'team_is_full';

/// The claimed name on a join request is not a usable name.
///
/// Length, control characters, or Unicode bidirectional-override characters —
/// exactly the bounds `Users.first_name` carries, through the same
/// `RowValidator.isWellFormedPersonName` (Michael's decision 1). The app should
/// never let a person reach this, since it bounds the field itself; it exists
/// because a bound enforced only by a text field is not a bound.
const String joinRefusalInvalidName = 'invalid_name';

/// A request id that is not this project's, or has already been decided.
///
/// **One answer for both**, so an owner of project A cannot use approve/reject
/// to discover whether a request id they have seen belongs to project B. It is
/// also the honest answer for the ordinary race: two owners approving the same
/// request, or approving one that was cleared by a rotation a moment earlier.
const String joinRefusalRequestNotOpen = 'request_not_open';

/// `POST /projects/<id>/members/readmit` was given somebody who is not a past
/// member of this project.
///
/// The route exists only to reverse a removal the owner themselves made, so the
/// named person must already hold a **closed** membership row here and no open
/// one. That bound is what stops re-admission being a way to add a stranger,
/// and this is what a caller sees when it is not met. It discloses nothing an
/// owner cannot already read off their own members screen.
const String joinRefusalNotAPastMember = 'not_a_past_member';

/// Joining is switched off for this project, answered to the **owner** asking
/// for their own settings — never to a requester, who gets
/// [joinRefusalCodeNotValid] instead.
const String joinRefusalJoiningDisabled = 'joining_disabled';

/// Every refusal code a join-or-approval route can answer with — never a sync
/// round's push or pull.
///
/// `SyncTransportException`'s decode is one shared vocabulary
/// (`knownSyncRefusals`) for every route this client calls, so nothing stops
/// this set's codes from being *decodable* out of a pull or push response.
/// What keeps them off the Sync Status screen is that the server never
/// answers push or pull with one — a fact about the routes, not the decode.
/// This set exists so a test can say that precisely, rather than a comment
/// asserting it (task 11.303).
const Set<String> joinRefusalCodes = {
  joinRefusalCodeNotValid,
  joinRefusalAlreadyMember,
  joinRefusalAlreadyRequested,
  joinRefusalTeamFull,
  joinRefusalInvalidName,
  joinRefusalRequestNotOpen,
  joinRefusalNotAPastMember,
};

// ---- The owner's view -------------------------------------------------------

/// A project's join settings, as its owner sees them.
class JoinSettings {
  const JoinSettings({
    required this.projectId,
    required this.joiningEnabled,
    required this.teamSizeLimit,
    required this.memberCount,
    required this.pendingCount,
    this.code,
    this.rotatedAt,
  });

  final String projectId;
  final bool joiningEnabled;

  /// Open memberships of every role, the owner included, **plus** undecided
  /// requests, may not exceed this. Owner-changeable; 50 by default.
  final int teamSizeLimit;

  /// Open memberships only. Rendered next to [pendingCount] rather than summed
  /// into one number, because "48 of 50" with no breakdown is what makes the
  /// team-full refusal unreadable.
  final int memberCount;

  /// Undecided requests. Counts toward [teamSizeLimit].
  final int pendingCount;

  /// **The join code, in readable form** — present for the owner, null when
  /// joining has never been switched on.
  ///
  /// **This is Security Model §4.2.1, the one named exception to "never store a
  /// token in plaintext", and it is written down there rather than only here.**
  /// The short version: §4.2 forbids plaintext storage so a database read
  /// yields no working credentials, and a join code is no longer a credential —
  /// it buys the right to ask and the owner is the gate. What it buys in return
  /// is that an owner can re-read the code after closing the screen, instead of
  /// rotating and re-broadcasting to a whole crew because they lost their
  /// phone.
  final String? code;

  final String? rotatedAt;

  /// Whether admitting one more person would exceed the limit.
  ///
  /// Computed here rather than at each call site so the screen and the server
  /// cannot disagree about what "full" means — the same reason
  /// `leaveProjectVerdict` is shared.
  bool get isFull => memberCount + pendingCount >= teamSizeLimit;

  Map<String, Object?> toJson() => {
    'project_id': projectId,
    'joining_enabled': joiningEnabled,
    'team_size_limit': teamSizeLimit,
    'member_count': memberCount,
    'pending_count': pendingCount,
    'code': code,
    'rotated_at': rotatedAt,
  };

  static JoinSettings fromJson(Map<String, Object?> json) => JoinSettings(
    projectId: requireSyncString(json, 'project_id'),
    joiningEnabled: _requireBool(json, 'joining_enabled'),
    teamSizeLimit: _requireInt(json, 'team_size_limit'),
    memberCount: _requireInt(json, 'member_count'),
    pendingCount: _requireInt(json, 'pending_count'),
    code: _optionalString(json, 'code'),
    rotatedAt: _optionalString(json, 'rotated_at'),
  );
}

/// One pending or recently-decided join request, as an owner sees it.
///
/// **The two identity fields are not equally trustworthy and the screen must
/// not present them as if they were** (Michael's decision 1, 2026-08-31).
/// [email] is what the **server** authenticated — copied from `auth_accounts`
/// at the moment the request was made, never from the request body. [claimedName]
/// is **what the requester says they are called**: bounded exactly as
/// `Users.first_name` is, but caller-supplied.
class JoinRequestSummary {
  const JoinRequestSummary({
    required this.requestId,
    required this.projectId,
    required this.email,
    required this.requestedAt,
    this.claimedName,
    this.decision,
    this.decidedAt,
  });

  final String requestId;
  final String projectId;

  /// **Server-authenticated.** The address this account proved mailbox control
  /// of at sign-in (§4.2). No path exists by which a caller can supply it.
  final String email;

  /// **Caller-supplied.** Null when the requester gave no name, which must
  /// render as *absent* — never as a placeholder somebody could mistake for a
  /// name that was typed.
  final String? claimedName;

  final String requestedAt;

  /// `approved`, `rejected`, `cleared`, or null while undecided.
  final String? decision;
  final String? decidedAt;

  bool get isPending => decision == null;

  Map<String, Object?> toJson() => {
    'request_id': requestId,
    'project_id': projectId,
    'email': email,
    'claimed_name': claimedName,
    'requested_at': requestedAt,
    'decision': decision,
    'decided_at': decidedAt,
  };

  static JoinRequestSummary fromJson(Map<String, Object?> json) =>
      JoinRequestSummary(
        requestId: requireSyncString(json, 'request_id'),
        projectId: requireSyncString(json, 'project_id'),
        email: requireSyncString(json, 'email'),
        claimedName: _optionalString(json, 'claimed_name'),
        requestedAt: requireSyncString(json, 'requested_at'),
        decision: _optionalString(json, 'decision'),
        decidedAt: _optionalString(json, 'decided_at'),
      );
}

/// Response to `GET /projects/<id>/join-requests`.
class JoinRequestListResponse {
  const JoinRequestListResponse({required this.requests});

  final List<JoinRequestSummary> requests;

  Map<String, Object?> toJson() => {
    'requests': [for (final r in requests) r.toJson()],
  };

  static JoinRequestListResponse fromJson(Map<String, Object?> json) {
    final raw = json['requests'];
    return JoinRequestListResponse(
      requests: [
        if (raw is List)
          for (final entry in raw)
            if (entry is Map<String, Object?>) JoinRequestSummary.fromJson(entry),
      ],
    );
  }
}

/// Response to `POST /projects/<id>/join-code/rotate`.
class RotateJoinCodeResponse {
  const RotateJoinCodeResponse({
    required this.code,
    required this.clearedPending,
  });

  /// The new code, in canonical form (no hyphen); render it with
  /// [formatJoinCode]. **Unlike an invite code it is not the only copy** — the
  /// owner can read it again from `GET /projects/<id>/join-settings` (§4.2.1).
  final String code;

  /// How many undecided requests the rotation cleared. **Zero unless the owner
  /// asked**: pending requests survive a rotation by default, and only the
  /// rotation sequence offers to clear them.
  final int clearedPending;

  Map<String, Object?> toJson() => {
    'code': code,
    'cleared_pending': clearedPending,
  };

  static RotateJoinCodeResponse fromJson(Map<String, Object?> json) =>
      RotateJoinCodeResponse(
        code: requireSyncString(json, 'code'),
        clearedPending: _requireInt(json, 'cleared_pending'),
      );
}

// ---- The requester's view ---------------------------------------------------

/// Response to a successful `POST /projects/join-requests`.
///
/// **Carries no membership, because none was granted.** All it says is that the
/// request now exists and who has to act on it. The project's name is here
/// because a person who has just typed a code needs to know which project they
/// asked to join — and it is the disclosure inventory entry 24 names as
/// inherent to the design rather than accidental.
class JoinRequestCreatedResponse {
  const JoinRequestCreatedResponse({
    required this.requestId,
    required this.projectName,
  });

  final String requestId;
  final String projectName;

  Map<String, Object?> toJson() => {
    'request_id': requestId,
    'project_name': projectName,
  };

  static JoinRequestCreatedResponse fromJson(Map<String, Object?> json) =>
      JoinRequestCreatedResponse(
        requestId: requireSyncString(json, 'request_id'),
        projectName: requireSyncString(json, 'project_name'),
      );
}

/// The three decisions a join request can carry, and the absence of all three
/// (`null`) means still pending.
///
/// **Named once, here, because both sides compare against them** — the server
/// writes the value and the app decides what to do about it, and a decision
/// string spelled out twice is a decision string that eventually disagrees
/// with itself.
const String joinDecisionApproved = 'approved';
const String joinDecisionRejected = 'rejected';

/// Written when a code rotation clears the queue, so the person's own status
/// read says their request is gone rather than leaving them on "pending".
const String joinDecisionCleared = 'cleared';

/// One of the caller's own requests, from `GET /projects/join-requests/mine`.
///
/// **This route is why a rejected person is told rather than left waiting** —
/// the class task 11.60 found for removed members, answered here before it
/// could happen again. It carries the decision and the project's name and
/// nothing else about the project, and nothing at all about who decided.
class MyJoinRequest {
  const MyJoinRequest({
    required this.requestId,
    required this.projectName,
    required this.requestedAt,
    this.decision,
    this.decidedAt,
    this.projectId,
  });

  final String requestId;
  final String projectName;
  final String requestedAt;

  /// **Set only when [decision] is `approved`, and null otherwise** (task
  /// 11.83).
  ///
  /// The requester's device needs it to link and sync the project by itself,
  /// which is the whole of task 11.83: until this field existed, the news
  /// "you are in" arrived carrying no way to act on it, and somebody had to
  /// find the project on another screen and tap Join — which nothing told them
  /// to do.
  ///
  /// **Approved-only, and that is the whole of the disclosure argument.** An
  /// approved requester is a member, and `GET /projects/mine` already hands
  /// them this exact id; so this field tells them nothing they could not
  /// already read. A pending or rejected requester is not a member and gets
  /// null, so the route still discloses no project identifier to anybody the
  /// owner has not admitted.
  final String? projectId;

  /// `approved`, `rejected`, `cleared`, or null while still pending.
  ///
  /// **`cleared` exists so that a request removed by a rotation says so**,
  /// instead of leaving somebody staring at "pending" forever.
  final String? decision;
  final String? decidedAt;

  bool get isPending => decision == null;

  /// **Approved *and* actionable** — an approval this device can complete by
  /// itself, which needs [projectId] as well as the decision (task 11.83). A
  /// server older than that task sends the decision without the id, and this
  /// is the difference the app has to be able to see: it can tell somebody
  /// they are in either way, but it can only *make it true* when it knows
  /// which project to pull.
  bool get isApprovedAndNamed =>
      decision == joinDecisionApproved && projectId != null;

  Map<String, Object?> toJson() => {
    'request_id': requestId,
    'project_name': projectName,
    'requested_at': requestedAt,
    'decision': decision,
    'decided_at': decidedAt,
    'project_id': projectId,
  };

  static MyJoinRequest fromJson(Map<String, Object?> json) => MyJoinRequest(
    requestId: requireSyncString(json, 'request_id'),
    projectName: requireSyncString(json, 'project_name'),
    requestedAt: requireSyncString(json, 'requested_at'),
    decision: _optionalString(json, 'decision'),
    decidedAt: _optionalString(json, 'decided_at'),
    // Absent on a server older than task 11.83, which is a state the app has
    // to survive rather than crash on: the card then says the project is
    // approved and points at the join list, instead of downloading by itself.
    projectId: _optionalString(json, 'project_id'),
  );
}

/// Response to `GET /projects/join-requests/mine`.
class MyJoinRequestsResponse {
  const MyJoinRequestsResponse({required this.requests});

  final List<MyJoinRequest> requests;

  Map<String, Object?> toJson() => {
    'requests': [for (final r in requests) r.toJson()],
  };

  static MyJoinRequestsResponse fromJson(Map<String, Object?> json) {
    final raw = json['requests'];
    return MyJoinRequestsResponse(
      requests: [
        if (raw is List)
          for (final entry in raw)
            if (entry is Map<String, Object?>) MyJoinRequest.fromJson(entry),
      ],
    );
  }
}

/// Absent means null; present-but-not-a-string throws, per task 10.64's rule
/// that "the caller said nothing" and "the caller sent something unusable" are
/// different failures.
String? _optionalString(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value == null) return null;
  if (value is! String) {
    throw SyncProtocolException('"$key" must be a string.');
  }
  return value;
}

bool _requireBool(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! bool) {
    throw SyncProtocolException('"$key" must be a boolean.');
  }
  return value;
}

int _requireInt(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! int) {
    throw SyncProtocolException('"$key" must be an integer.');
  }
  return value;
}
