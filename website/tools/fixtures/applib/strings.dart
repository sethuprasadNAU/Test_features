// A stand-in for lib/, used only by website/tools/selftest.sh. Every string
// here exists to be found — or deliberately not found — by
// website/tools/check_app_quotes.dart.

class Strings {
  // A plain label.
  static const join = 'Join a project';

  // Wrapped across two adjacent literals, the way a long message really is.
  static const removed = 'You are no longer a member of this project '
      'and this copy will be removed.';

  // Interpolated: only the fixed halves are quotable.
  static String joined(String name) => 'Joined $name at last';

  // A quote inside a doc comment must not count as app copy:
  /// The "Ask to join" button used to live here.

  // Nor one inside a line comment: 'Retired wording'
  /* Nor a block comment: 'Also retired' */

  static const raw = r'A raw string with a \n in it';
}

// Two enums, because rule 4 turns on the difference between what an enum
// *stores* and what it *shows*. `db` is the string that goes in a database
// column: it is pinned by the schema, so a page quoting it could never go red,
// and quoting it is refused. `label` is what a screen puts in front of a
// person and may be quoted like any other copy.
enum Role {
  owner('owner'),
  helper('helper');

  const Role(this.db);
  final String db;
}

// The same idea with the constructor's arguments the other way round. The
// check has to *read* which parameter is `db` rather than assume the stored
// value comes first — a rule resting on the convention would stop working
// silently the day somebody wrote an enum like this one.
enum Signal {
  strong('Strong signal', 'strong'),
  weak('Weak signal', 'weak');

  const Signal(this.label, this.db);
  final String label;
  final String db;
}
