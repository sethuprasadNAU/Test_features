import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tritrack/core/text/role_labels.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

import '../support/dart_source.dart';

/// Task 11.99 — **the guard for the spelling task 11.99 settled.**
///
/// `ProjectRole.db` is the string stored in a database column: `owner`,
/// `contributor`, `viewer`. It is what SQLite's `CHECK` constraint enforces and
/// what travels on the sync wire. It is **not** a label anybody wrote for a
/// person to read — it only looks like one because the three values happen to
/// be ordinary English words.
///
/// That coincidence is why seven call sites printed it at a biologist and
/// nobody noticed. The app ended up spelling the same three roles two ways one
/// screen apart: the members list and each member's summary line wrote *owner*,
/// while the sheet an owner reads when admitting somebody wrote *Owner — also
/// manages members*. `/w-06` found it writing the user guide, which had to
/// spend a sentence saying they are the same three roles.
///
/// **What this checks.** Every `.dart` file under `lib/` has its comments
/// blanked out ([stripComments]) and is scanned for [_storedRoleValue] — any
/// expression ending `role.db` or `Role?.db`. A hit that is not on
/// [_knownStorageUses] fails. The allowlist is short by design: reading the
/// stored value is correct in exactly two places, and both of them are writing
/// it *back* to storage or to the wire.
///
/// **What this would and would not have caught.**
/// - It would have caught this task's own subject. Before the fix,
///   `project_members_screen.dart` wrote `role.db` twice, and four repositories
///   and two more screens interpolated it into refusal copy.
/// - It would **not** catch a screen that hard-codes `'contributor'` as a
///   string literal of its own. That is a different defect — a fourth spelling
///   rather than a stored one — and [_sheetWordingIsInOnePlace] below is the
///   half that covers it for the three labels the user guide quotes.
/// - It would not catch a role written into prose that then goes stale, e.g.
///   "ask an owner" on a screen where the answer is no longer an owner. That
///   needs a human reader, as the invitation-vocabulary sweep says of its own
///   blind spot.
/// - `server/` is out of scope, and deliberately: no server prose is ever shown
///   to a user (§4.13), so the server writes `role.db` into audit reasons and
///   JSON bodies as a matter of course and should keep doing so.
const List<_StorageUse> _knownStorageUses = [
  _StorageUse(
    file: 'lib/data/models/project_membership.dart',
    reason:
        'Serialises a `Project_Memberships` row to its database columns. This '
        'is the value the column stores and the `CHECK` constraint enforces.',
  ),
  _StorageUse(
    file: 'lib/data/sync/sync_transport.dart',
    reason:
        'Puts the role in a request body for the approve and re-admit routes. '
        'The server parses it back with `ProjectRole.fromDb`, so this is the '
        'wire spelling, not a label.',
  ),
];

class _StorageUse {
  const _StorageUse({required this.file, required this.reason});
  final String file;
  final String reason;
}

/// `role.db`, `Role.db`, `role?.db`, `receiverRole?.db`, `membership.role.db`.
final _storedRoleValue = RegExp(r'[Rr]ole\??\.db\b');

void main() {
  test(
    'no user-visible string in lib/ prints a role\'s stored database value, '
    'except the named storage and wire uses',
    () {
      for (final use in _knownStorageUses) {
        final file = File(use.file);
        expect(
          file.existsSync(),
          isTrue,
          reason:
              '${use.file} no longer exists. Remove its entry from '
              '_knownStorageUses in this test, or restore the file.',
        );
        expect(
          _storedRoleValue.hasMatch(stripComments(file.readAsStringSync())),
          isTrue,
          reason:
              '${use.file} no longer reads a role\'s stored value at all. '
              'Remove its entry from _knownStorageUses — an allowlist that '
              'keeps entries nothing needs is a list nobody reads.',
        );
      }

      final offenders = <String>[];
      for (final source in dartFilesUnder('lib')) {
        final stripped = stripComments(source.readAsStringSync());
        if (!_storedRoleValue.hasMatch(stripped)) continue;
        final relative = _relative(source.path);
        if (_knownStorageUses.any((u) => u.file == relative)) continue;
        offenders.add(relative);
      }

      expect(
        offenders,
        isEmpty,
        reason:
            'These files read a project role\'s stored database value '
            '(`role.db`), and none of them is in _knownStorageUses:\n'
            '${offenders.map((f) => '  - $f').join('\n')}\n\n'
            '`ProjectRole.db` is a storage spelling — what goes in the SQLite '
            'column and on the sync wire. It is not a label anybody wrote for '
            'a person to read; it only looks like one because the three '
            'values happen to be English words. Anything a person reads goes '
            'through lib/core/text/role_labels.dart instead: `label` for a '
            'heading, `inSentence` mid-sentence, `withArticle` where the '
            'sentence needs "an owner" rather than "a owner", `withRights` '
            'for the name plus what it permits. If this really is a write to '
            'storage or to the wire, add it to _knownStorageUses with a '
            'one-line reason.',
      );
    },
  );

  test(_sheetWordingIsInOnePlace, () {
    // The three strings the user guide quotes, and the ones a person meets at
    // the moment an owner lets them in. They must live in exactly one file: a
    // second copy is how the two spellings got here in the first place.
    final labels = [
      for (final role in ProjectRole.values) role.withRights,
    ];
    for (final label in labels) {
      final holders = <String>[];
      for (final source in dartFilesUnder('lib')) {
        // Comments stripped: this codebase's doc comments quote its own copy
        // freely — the members screen's dropdown carries a comment naming the
        // very string it renders — and a guard that reads prose as code finds
        // its own subject described and concludes wrongly.
        if (stripComments(source.readAsStringSync()).contains(label)) {
          holders.add(_relative(source.path));
        }
      }
      expect(
        holders,
        ['lib/core/text/role_labels.dart'],
        reason:
            '"$label" should appear in lib/core/text/role_labels.dart and '
            'nowhere else in lib/. A second copy is a second spelling waiting '
            'to drift — which is exactly what task 11.99 was cleaning up. '
            'Screens should read `role.withRights`. (The website quotes all '
            'three of these strings; changing one means changing '
            'website/content/docs/, which is the content stream\'s to do.)',
      );
    }
  });
}

const _sheetWordingIsInOnePlace =
    'the three role labels the admission sheet and the user guide use live in '
    'exactly one file';

String _relative(String path) =>
    path.startsWith('./') ? path.substring(2) : path;
