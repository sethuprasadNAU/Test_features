import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// **Task 11.28: keeping the one door narrow, by counting it.**
///
/// `BaseRepository.updateByKeyUnderNarrowerRule` writes a row without applying
/// the table's [MutationRule], on the strength of the calling repository having
/// applied a *narrower* rule itself. That is a real hole in the app's advisory
/// authorization layer, and it exists because task 11.28 needed exactly one:
/// `Project_Memberships` is owner-only to write, and a person leaving a project
/// must be able to end their own row.
///
/// Its doc comment says there is one caller and one is intended. **A comment is
/// not a control** — this project has paid for that sentence repeatedly, most
/// recently in task 11.27, where a comment asserted a session revocation that
/// did not exist. So the claim is a test: the method may be *defined* once and
/// *called* once, and adding a second call site fails here with a message
/// saying what to do instead.
///
/// The failure is not "you may never add one". It is "come and say why", which
/// is the same shape as `MembershipInsertAuthority`'s named doors and
/// `MutationActor.replication`'s required reason string.
void main() {
  test('exactly one repository calls updateByKeyUnderNarrowerRule', () {
    const method = 'updateByKeyUnderNarrowerRule';
    // The declaration itself, plus the doc comment's own mentions of the name,
    // all live in this file and are not call sites.
    const declaration = 'lib/data/repositories/base_repository.dart';
    const permitted = {
      'lib/data/repositories/project_membership_repository.dart':
          'task 11.28 — ProjectMembershipRepository.leaveProject, where a '
              'person ends their own membership row under isSelfDeparture',
    };

    final callers = <String, int>{};
    for (final entity in Directory('lib').listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      if (entity.path.endsWith('.g.dart')) continue;
      if (entity.path.endsWith('.freezed.dart')) continue;
      final path = entity.path;
      if (path == declaration) continue;
      final calls = '$method('.allMatches(entity.readAsStringSync()).length;
      if (calls > 0) callers[path] = calls;
    }

    expect(
      callers.keys.toSet(),
      permitted.keys.toSet(),
      reason:
          'Every use of $method disables this table\'s MutationRule for one '
          'write. Adding one is allowed, but it has to be deliberate: apply a '
          'rule that is *narrower* than the table\'s (not merely different, '
          'and never broader), state it in the `because` argument, make the '
          'server enforce the same one at the boundary, and add the new file '
          'to this test with a sentence saying which rule it applies. The '
          'permitted set today is:\n'
          '${permitted.entries.map((e) => '  ${e.key}: ${e.value}').join('\n')}',
    );
    expect(
      callers.values,
      everyElement(1),
      reason: '$method is called more than once in a permitted file; each '
          'call is a separate write to justify.',
    );
  });
}
