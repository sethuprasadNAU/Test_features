/// **The one place a project role is spelled for a person** (task 11.99).
///
/// Until this file existed, seven places in the app wrote a role onto a screen
/// and every one of them wrote `ProjectRole.db` — the string stored in the
/// database column. Two spellings resulted, one screen apart: the members list
/// and each member's summary line printed *owner*, *contributor*, *viewer*,
/// while the sheet an owner reads when admitting somebody wrote *Owner — also
/// manages members* and its two siblings. `/w-06` found it while writing the
/// user guide, which had to spend a sentence explaining that these are the same
/// three roles.
///
/// **The defect is the coupling, not the glyphs.** `ProjectRole.db` is a
/// *storage* spelling — it is what goes in a SQLite column, travels on the
/// wire, and is checked by the database's own `CHECK` constraint. It happens to
/// read as an English word today, which is exactly why nobody noticed that the
/// screens had no written label at all. The day somebody stores `co_owner` or
/// `read_only`, every one of those screens starts printing an identifier at a
/// biologist. A label nobody chose is a label that changes when the schema
/// does.
///
/// So: `db` for storage and the wire, this file for anything a person reads,
/// and `test/documentation/role_vocabulary_test.dart` fails the build if
/// `.db` ever reaches a string a screen renders again.
///
/// **The wording is the admission sheet's**, not a fourth invention. A person
/// meets *Contributor — records their own* at the moment an owner lets them
/// in; that is the wording to keep, and it is now what the members screen, the
/// "your role" card and the refusal messages all draw from.
library;

import 'package:tritrack_sync/tritrack_sync.dart';

/// How each rung of the role gradient is written for a person to read.
///
/// Four spellings, because a role appears in four grammatical positions and
/// forcing one string into all of them is how "you are a Owner" gets shipped:
///
/// - [label] — the bare name, as a heading or a chip: *Contributor*.
/// - [inSentence] — lower case, mid-sentence, article supplied by the caller.
/// - [withArticle] — lower case with the right article: *an owner*, *a
///   contributor*. Use this wherever the sentence would otherwise hard-code
///   "a", which is wrong for exactly one of the three values.
/// - [withRights] — the name and what it permits, in one line: *Owner — also
///   manages members*. This is the admission sheet's wording and the reason
///   this extension exists at all.
extension ProjectRoleLabels on ProjectRole {
  /// The role's written name. Capitalised, because it names a thing.
  String get label => switch (this) {
    ProjectRole.owner => 'Owner',
    ProjectRole.contributor => 'Contributor',
    ProjectRole.viewer => 'Viewer',
  };

  /// The role's name mid-sentence — "your role on this project is viewer".
  String get inSentence => switch (this) {
    ProjectRole.owner => 'owner',
    ProjectRole.contributor => 'contributor',
    ProjectRole.viewer => 'viewer',
  };

  /// The role with the article the English actually needs.
  ///
  /// "a owner" is the failure this exists to make unwriteable: every message
  /// that names a role today hard-codes "a", and each is correct only because
  /// the owner branch happens to be unreachable in that particular refusal. A
  /// fourth caller with a different reachability would ship the mistake.
  String get withArticle => switch (this) {
    ProjectRole.owner => 'an owner',
    ProjectRole.contributor => 'a contributor',
    ProjectRole.viewer => 'a viewer',
  };

  /// The role and what it permits, in one line.
  ///
  /// **The admission sheet's wording**, kept identical rather than paraphrased:
  /// the sheet is where an owner picks a role and where the person being let in
  /// is described, so it is the wording somebody meets first. The user guide
  /// quotes all three of these strings.
  String get withRights => switch (this) {
    ProjectRole.owner => 'Owner — also manages members',
    ProjectRole.contributor => 'Contributor — records their own',
    ProjectRole.viewer => 'Viewer — read only',
  };

  /// What this role may do, addressed to the person who holds it.
  ///
  /// Written in the second person because its one caller is the card that tells
  /// somebody their *own* role — the answer task 11.99 exists to make reachable
  /// without failing at something first. [withRights] describes a role in the
  /// third person for an owner choosing one; this describes it to its holder.
  ///
  /// Each says what the person can do *and* what they cannot, because "you are
  /// a contributor" answers nothing on its own — the field tech reading it is
  /// there because something was refused, and needs to know whether that was
  /// their role or a fault.
  String get whatYouMayDo => switch (this) {
    ProjectRole.owner =>
      'You can record and correct anything here, and manage the project: its '
          'members, their roles and the join code.',
    ProjectRole.contributor =>
      'You can record bearings, no-signals, notes and position estimates, and '
          'correct your own. Only an owner can take a record out of the '
          'analysis or manage the project.',
    ProjectRole.viewer =>
      'You can see and export everything, but you cannot record or change '
          'anything. To record, ask an owner to make you a contributor.',
  };
}

/// The gradient in the order a person should read it: fewest rights first.
///
/// **One order, for the same reason as one spelling** (task 11.99). The
/// admission sheet listed viewer, contributor, owner; the members screen's role
/// dropdown listed them in `ProjectRole.values` order, which is the reverse.
/// Two orders on one screen family is the same class of defect as two
/// spellings, and this is the order to keep: a role picker that opens on the
/// least permissive choice makes over-granting a deliberate act rather than a
/// default.
const List<ProjectRole> rolesLeastPermissiveFirst = [
  ProjectRole.viewer,
  ProjectRole.contributor,
  ProjectRole.owner,
];
