import 'package:tritrack_sync/tritrack_sync.dart';

/// **What this device knows about the signed-in person's place in a project**
/// (task 11.237).
///
/// Until this type existed the answer was a `ProjectRole?`, and its `null`
/// meant two different things that every caller then treated as one:
///
/// - **This device cannot say** — no `Projects` row here at all, no signed-in
///   user, or a membership row whose `role` this build does not recognise.
///   Every write gate defers to the server on that, and rightly: a phone
///   restoring last season's archive holds no rows to answer with.
/// - **This device *can* say, and the answer is no** — the project's own row
///   is here, its membership rows are here, and none of them names this
///   person. That is a colleague's archive imported by somebody who is not on
///   the team, and until 11.237 the app treated it exactly like the first
///   case: every edit permitted, and no edit ever able to leave the device.
///
/// Michael's decision (2026-09-13): the second case is a **read-only snapshot,
/// and the app says so.** An edit on it is refused, and the refusal names the
/// way in — the join code. The type below is what makes the two cases
/// distinguishable at every gate that used to read the `null`.
///
/// **Derived on every read, never stored.** A person holding a snapshot may be
/// approved onto the project tomorrow; the moment their open membership row
/// arrives by sync, [readProjectStanding] answers [MemberStanding] and the
/// snapshot is a live project with no re-import. A cached "read-only" flag is
/// a hand-maintained list with a nicer name.
sealed class ProjectStanding {
  const ProjectStanding();

  /// The rung this person holds — an open membership row here names them, or
  /// they are the project's fallback creator (see `resolveProjectRole`).
  const factory ProjectStanding.member(ProjectRole role) = MemberStanding;

  /// The project is on this device, its membership rows are on this device,
  /// and none of them is this person's. **A read-only snapshot.**
  static const ProjectStanding notAMember = NotAMemberStanding();

  /// This device holds nothing it could answer with. Every gate defers to the
  /// server, which is the only party that can decide.
  static const ProjectStanding unknown = UnknownStanding();

  /// The role, where one is held; null for both other standings — which is
  /// exactly the ambiguity this type exists to remove, so prefer the pattern
  /// match wherever the difference matters.
  ProjectRole? get role;

  /// Whether this person may create or change the project's data here — the
  /// gradient's write gate, with the snapshot answer folded in.
  ///
  /// [UnknownStanding] permits, on the same *defer to the server* contract
  /// `BaseRepository.assertRoleMayWrite` has always stated. [NotAMemberStanding]
  /// refuses: the device has grounds, and Michael chose the refusal over an
  /// edit that looks like contributing and is not.
  bool get mayWriteProjectData;

  /// Whether this project is a read-only snapshot on this device.
  bool get isSnapshot => this is NotAMemberStanding;

  /// The sentence a screen shows instead of a working control, or null when
  /// the control should work.
  ///
  /// [asViewer] is the screen's own wording for a `viewer` — those sentences
  /// name the verb (*"Viewers cannot record observations"*), and they are
  /// still the right words for a viewer. For a snapshot the answer is the one
  /// shared [notAMemberWriteRefusal], whatever the verb, so a person meets the
  /// same explanation and the same directions on every surface.
  String? writeRefusal({required String asViewer}) => switch (this) {
    MemberStanding(:final role) => role.mayWriteProjectData ? null : asViewer,
    NotAMemberStanding() => notAMemberWriteRefusal,
    UnknownStanding() => null,
  };
}

/// See [ProjectStanding.member].
final class MemberStanding extends ProjectStanding {
  const MemberStanding(this.role);

  @override
  final ProjectRole role;

  @override
  bool get mayWriteProjectData => role.mayWriteProjectData;

  @override
  bool operator ==(Object other) =>
      other is MemberStanding && other.role == role;

  @override
  int get hashCode => Object.hash(MemberStanding, role);

  @override
  String toString() => 'ProjectStanding.member(${role.name})';
}

/// See [ProjectStanding.notAMember].
final class NotAMemberStanding extends ProjectStanding {
  const NotAMemberStanding();

  @override
  ProjectRole? get role => null;

  @override
  bool get mayWriteProjectData => false;

  @override
  String toString() => 'ProjectStanding.notAMember';
}

/// See [ProjectStanding.unknown].
final class UnknownStanding extends ProjectStanding {
  const UnknownStanding();

  @override
  ProjectRole? get role => null;

  @override
  bool get mayWriteProjectData => true;

  @override
  String toString() => 'ProjectStanding.unknown';
}

/// **The one refusal for an edit on a snapshot**, reached from every surface
/// that can make one (task 11.237).
///
/// Short, and it names the mechanism that exists rather than gesturing at one:
/// an owner hands out the project's join code (Project Members → *Join code*),
/// the person enters it under Projects → *Join a project* (*"Have a join
/// code?"*), and the owner approves the request — having the code only lets
/// somebody ask. The words are those two screens' own, so the sentence a person
/// is given matches the buttons they will then look for.
///
/// **What it deliberately does not say: "this is a copy of someone else's
/// project."** The same standing is reached by a member who left, or was
/// removed — their project is not somebody else's copy, and a sentence that
/// asserted so would be the wrong-cause class. *"You are not on this project"*
/// is true of both people, and the way back in is the same for both.
const String notAMemberWriteRefusal =
    'You are not on this project, so it cannot be changed here. To join, ask '
    'an owner for the join code and enter it under Projects → Join a '
    'project; the owner then approves your request.';

/// **What a snapshot says about itself where a person meets it** — on the
/// projects list, not only in a dialog at import time (task 11.237).
///
/// *"Read-only until you join it"* rather than the plan's *"changes here stay
/// on this device"*: Michael decided the edit is refused, so nothing stays
/// anywhere, and copy describing a mechanism the code does not have is the
/// defect task 11.54 exists to catch.
const String snapshotProjectDescription =
    "A copy of someone else's project — read-only on this device until you "
    'join it.';

/// **What an adopted-but-unlinked project says about itself, on the same
/// shelf as [snapshotProjectDescription]** (task 11.238).
///
/// `ImportCase.adopt` — a member importing a project this device has never
/// held — lands the project live (writes are allowed) without linking it to
/// any server, and until this the app said nothing about it anywhere: a
/// person could record a week of bearings on a new device and never see a
/// line explaining why none of it had left the phone. **The behaviour is
/// unchanged; only the silence is fixed.** Marking a project linked because
/// an archive claimed membership would trust the file one step further than
/// anything else does, and the path that links properly already exists —
/// Projects → Join a project, or a pull-to-refresh after approval.
///
/// **Also shown for an ordinary local project nobody has published yet, and
/// that is deliberate rather than a false positive.** Nothing in the database
/// distinguishes "adopted from an archive, not yet linked" from "created here
/// and never published" — `ImportCase` is a report about one import
/// transaction, never stored, exactly the way [ProjectStanding] itself is
/// never stored. The sentence is true of both: neither project is syncing,
/// and the same step starts it either way. Telling the two apart would need a
/// second, stored mechanism this task was told not to invent.
///
/// **Shown for an owner, who can act on it directly.** [notSyncingYetMemberDescription]
/// is the same fact for somebody who holds a role that cannot publish.
const String notSyncingYetOwnerDescription =
    'Not syncing yet. Publish it (⋮ → Publish to server) to start.';

/// See [notSyncingYetOwnerDescription] — the same fact, worded for a member
/// who is not an owner and so cannot publish it themselves.
const String notSyncingYetMemberDescription =
    'Not syncing yet. Ask a project owner to publish it, or join it '
    'properly to link this device.';
