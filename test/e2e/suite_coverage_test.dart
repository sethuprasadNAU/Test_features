import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

import '../support/dart_source.dart';
import 'support/e2e_harness.dart';

/// **What the end-to-end suite covers, derived from the client it exercises.**
///
/// ## The guard this replaces
///
/// `e2e_coverage_guard_test.dart` used to assert that `test/e2e/` contained
/// exactly nine `*_e2e_test.dart` files. A number is not a property: it says
/// nothing about what those files do, so the suite could keep its count while
/// losing the thing that mattered. Task 11.41 added the first test that ever
/// signed **two different people** in — every earlier multi-device test used
/// one address, which converges on one `user_id`, so no row in any of them
/// named somebody who was not the caller, which is the entire subject of task
/// 11.24's rule. Nothing stopped that regressing to a file that no longer did
/// it. The count would not have moved.
///
/// ## What is asserted instead
///
/// 1. **Every route the client can call is exercised.** The set is read from
///    `SyncTransport` and `AuthClient` — the two classes through which this app
///    talks to a server — so adding a ninth transport method turns this red
///    until some e2e test names it. Nothing here is written down by hand except
///    [_notCoveredYet], which states the gaps that already exist rather than
///    hiding them, and which fails when one is closed as well as when one is
///    opened.
/// 2. **Two different people sign in somewhere in the suite.** Derived from
///    the harness's own API: two devices signing in with `randomEmail()`, which
///    that harness defines as a fresh address per call.
/// 3. **Both answers §4.17 can give a foreign name are provoked.** Task 11.36
///    added this, and the reason is that (1) is the same defect it replaced,
///    one level up: **it counts routes, not authorization causes.** A sweep
///    for task 11.47 found that no app-side test had ever pushed a shared
///    record carrying somebody else's edit stamp — every fixture in the
///    harness stamps its rows with the pusher — so had 11.47 relaxed
///    *authorship* alongside the audit column and undone task 11.24, a plain
///    `flutter test` would still have gone green. Every route was still
///    covered. See [_foreignNameCauses].
///
/// ## Not tagged `e2e`, deliberately
///
/// Both questions are answered by reading source, so they need no server and
/// no network. Tagging this `e2e` would mean the coverage of the suite was
/// only ever checked on the runs where a server happened to be up — which is
/// the same shape as measuring a control in a configuration that disables it
/// (task 10.54). It runs on every plain `flutter test`.
///
/// ## What was given up with the file count, stated plainly
///
/// Deleting an e2e test file that is not the last one covering some route, and
/// not the last one signing two people in, is no longer noticed. The count did
/// notice that — at the price of noticing nothing about what the files were
/// for, and of a number somebody had to remember to change. Coverage is now
/// measured where it can be named; loss that cannot be named is not measured.
void main() {
  final e2eSource = <String, String>{};
  for (final file in dartFilesUnder('test/e2e')) {
    if (file.path.endsWith('suite_coverage_test.dart')) continue;
    e2eSource[_relative(file.path)] = stripComments(file.readAsStringSync());
  }

  /// [e2eSource] without `support/`, which is the harness rather than a test.
  ///
  /// **Written after watching a check fail to fail.** The authorization-cause
  /// group below asks whether some *test* builds a fixture and asserts the
  /// outcome it must get. Scanned over the whole directory, the harness's own
  /// declaration of that fixture satisfied the first half — so renaming every
  /// call site in every test left the guard green. A check that cannot
  /// distinguish success from its own failure is not a check, and this one
  /// could not until it stopped counting the definition as a use.
  final e2eTestSource = {
    for (final entry in e2eSource.entries)
      if (!entry.key.contains('/support/')) entry.key: entry.value,
  };

  group('every route the client can call is exercised end to end', () {
    final clientCalls = {
      ..._publicMethods('lib/data/sync/sync_transport.dart', 'SyncTransport'),
      ..._publicMethods('lib/data/auth/auth_client.dart', 'AuthClient'),
    };

    test('the client surface was actually found', () {
      expect(
        clientCalls,
        containsAll(<String>['push', 'pull', 'ack', 'requestToJoin']),
        reason:
            'The client surface derived from SyncTransport and AuthClient is '
            '$clientCalls. If the parse has stopped finding methods, every '
            'coverage assertion below passes without measuring anything.',
      );
    });

    for (final call in clientCalls) {
      test('$call is called by some e2e test', () {
        final callers = [
          for (final entry in e2eSource.entries)
            if (RegExp('\\.$call\\s*\\(').hasMatch(entry.value)) entry.key,
        ];
        final excuse = _notCoveredYet[call];
        if (excuse != null) {
          expect(
            callers,
            isEmpty,
            reason:
                '$call is listed in _notCoveredYet ("$excuse") but '
                '${callers.join(', ')} now exercises it. Delete the entry — a '
                'stale excuse reads as a decision somebody made.',
          );
          return;
        }
        expect(
          callers,
          isNotEmpty,
          reason:
              'Nothing in test/e2e/ ever calls $call, so this app can talk to '
              'a real server in a way no test has ever tried. Either add a '
              'test that uses it, or add it to _notCoveredYet in this file '
              'with the reason and a task number.',
        );
      });
    }
  });

  group('the suite signs two different people in', () {
    test('the harness still mints a fresh address per call', () {
      final harness = stripComments(
        File('test/e2e/support/e2e_harness.dart').readAsStringSync(),
      );
      expect(
        RegExp(r'String randomEmail\(\) =>.*randomId\(\)').hasMatch(harness),
        isTrue,
        reason:
            'randomEmail() no longer builds an address from randomId(), so '
            '"two devices, each signing in with randomEmail()" no longer '
            'means two different people — and the check below would be '
            'reading a spelling rather than a property. Update both together.',
      );
    });

    test('some test signs two devices in as two different people', () {
      final providers = <String, List<String>>{};
      e2eSource.forEach((path, source) {
        final byReceiver = <String, String>{};
        for (final m
            in RegExp(r'(\w+)\.signIn\(\s*([A-Za-z_][\w.]*(?:\(\))?)')
                .allMatches(source)) {
          byReceiver.putIfAbsent(m.group(1)!, () => m.group(2)!.trim());
        }
        if (byReceiver.length < 2) return;
        final addresses = byReceiver.values.toList();
        final everyoneGetsAFreshAddress =
            addresses.every((a) => a.contains('randomEmail()'));
        final theyAreDifferentAddresses = addresses.toSet().length > 1;
        if (everyoneGetsAFreshAddress || theyAreDifferentAddresses) {
          providers[path] = byReceiver.keys.toList();
        }
      });
      expect(
        providers,
        isNotEmpty,
        reason:
            'No test in test/e2e/ signs two devices in under two different '
            'addresses any more. Every multi-device test is then one person '
            'on two devices — the same user_id, so no row anywhere names '
            'somebody who is not the caller, which is the whole subject of '
            'task 11.24\'s rule and the reason a defect visible the moment '
            'two people share a project survived a full phase of testing.\n\n'
            'A qualifying test has two E2eDevices whose signIn() addresses '
            'are each randomEmail(), or are two different values.',
      );
    });
  });

  group('both answers a foreign name can get are provoked, not just routes', () {
    // **Derived, not listed.** The cross product of every synced table and
    // every user column on it, classified by what `RowAuthorizer` will do with
    // a *foreign* name in that column on an insert. A thirteenth table, or a
    // new user column on an existing one, lands in one of these buckets by
    // definition rather than by somebody remembering to add it.
    final causes = _foreignNameCauses();

    test('the scan can still see the tests it is scanning', () {
      // The definition of a fixture is not a use of it, and the harness is not
      // a test. Without this, renaming every call site left the group below
      // green because `support/e2e_harness.dart` still declared the name.
      expect(
        e2eTestSource.keys,
        isNotEmpty,
        reason:
            'No files left to scan once test/e2e/support is excluded, so every '
            'coverage requirement in this group passes over nothing.',
      );
      expect(
        e2eTestSource.keys,
        everyElement(isNot(contains('/support/'))),
      );
    });

    test('the classification found both answers, on real tables', () {
      // Without this the two assertions below could both pass while measuring
      // nothing: an empty bucket has nothing to require coverage of.
      expect(
        causes[_ForeignName.accepted],
        isNotEmpty,
        reason:
            'No table anywhere accepts a foreign audit name, so task 11.47 has '
            'been undone or MutationRule.replicatesAForeignAuditName no longer '
            'means what this guard reads it as. Either way the coverage '
            'requirement below has stopped requiring anything.',
      );
      expect(
        causes[_ForeignName.refused],
        isNotEmpty,
        reason:
            'No table anywhere refuses a foreign name, which would mean task '
            '11.24 is gone — a contributor could sign a bearing with a '
            "colleague's name.",
      );
      // The two fixtures below are only meaningful on these two tables.
      expect(causes[_ForeignName.accepted], contains('Tags/last_modified_by'));
      expect(causes[_ForeignName.refused], contains('Observations/user_id'));
    });

    // The fixtures are **called**, not read. A fixture that quietly started
    // stamping its rows with the pusher would still satisfy a source scan that
    // only looked for its name.
    final now = DateTime.utc(2026, 8, 29, 12);
    const someoneElse = 'not-the-pusher';

    test('the accepted-cause fixture really carries a foreign audit name', () {
      final tag = tagLastEditedByAFormerColleague(
        tagId: 'coverage-guard-tag',
        projectId: 'coverage-guard-project',
        formerColleagueUserId: someoneElse,
        deviceId: 'coverage-guard-device',
        now: now,
      );
      expect(
        tag[auditUserColumn],
        someoneElse,
        reason:
            'the fixture no longer puts a foreign name in the audit column, so '
            'the test that uses it is pushing an ordinary row and proving '
            'nothing about task 11.47',
      );
      final table = _syncTable(Tables.tags);
      expect(
        table.identityUserColumns.map((c) => tag[c]),
        everyElement(isNot(someoneElse)),
        reason:
            'the fixture has started naming that person in a column that says '
            'who a record is *about*, which is a different claim entirely and '
            'one the server must refuse',
      );
    });

    test('the refused-cause fixture really carries a foreign author name', () {
      final bearing = bearingAuthoredByAColleague(
        'coverage-guard-obs',
        projectId: 'coverage-guard-project',
        colleagueUserId: someoneElse,
        deviceId: 'coverage-guard-device',
        now: now,
      );
      expect(
        bearing['user_id'],
        someoneElse,
        reason:
            'the fixture no longer names somebody else as the author, so the '
            "test that uses it can't tell task 11.24 from its absence",
      );
      expect(
        tableMutationRules[Tables.observations]!.namesRowAuthor,
        isTrue,
        reason:
            'Observations no longer names its author, so `user_id` on it is '
            'not the column task 11.24 is about and this fixture is aimed at '
            'the wrong place',
      );
    });

    for (final entry in _causeFixtures.entries) {
      test('${entry.key.name}: some e2e test pushes it and says so', () {
        final (fixture, outcome) = entry.value;
        final callers = [
          for (final e in e2eTestSource.entries)
            if (e.value.contains('$fixture(') && e.value.contains(outcome))
              e.key,
        ];
        expect(
          callers,
          isNotEmpty,
          reason:
              'No e2e test both builds a $fixture(...) row and asserts '
              '$outcome for it. That pair is what makes the test a check on '
              'the authorization cause rather than on the route it travels '
              'over: the row carries the foreign name, and the expectation '
              'names the answer §4.17 must give it.',
        );
      });
    }
  });
}


/// What §4.17 does with a **foreign** name in one column of one table, on an
/// insert.
enum _ForeignName { accepted, refused }

/// Every `table/column` pair that can carry a user's name, bucketed by what the
/// server does when that name is not the caller's.
///
/// Read off [tableMutationRules] and [SyncTable.userColumns] — the two
/// declarations a new table cannot be added without making — rather than
/// listed, per task 10.66's standing criterion.
///
/// ## What this deliberately does not model, said plainly
///
/// §4.17 clause 2 — *"this project already reaches them"* — can accept a
/// foreign name that this classification calls refused, and **that is not a
/// hole in the model, it is the thing that made the first version of task
/// 11.36's test vacuous.** Written with a *current member's* id on the tag,
/// that test passed against a build with task 11.47 deliberately reverted:
/// clause 2 vouched for the name and the relaxation was never consulted. The
/// fix was to stamp the row with somebody who has never been on the project.
///
/// A source-reading guard cannot tell those two apart — whether the id a test
/// passes belongs to a member is a fact about a live server, not about this
/// file. **So it is not checked here, and here is where it is checked
/// instead:** each fixture's doc comment states which of the two it requires
/// and why, and both halves of that test were watched failing against a build
/// with the control removed, which is the only thing that can establish it.
/// This guard's job is the one it can do — that the causes exist, that the
/// fixtures carry the names they claim to, and that some test both pushes one
/// and asserts the answer it must get.
Map<_ForeignName, Set<String>> _foreignNameCauses() {
  final causes = {
    _ForeignName.accepted: <String>{},
    _ForeignName.refused: <String>{},
  };
  for (final table in syncTables) {
    final rule = tableMutationRules[table.name];
    if (rule == null) continue;
    for (final column in table.userColumns) {
      final accepted =
          column == auditUserColumn && rule.replicatesAForeignAuditName;
      causes[accepted ? _ForeignName.accepted : _ForeignName.refused]!
          .add('${table.name}/$column');
    }
  }
  return causes;
}

/// The harness fixture that provokes each cause, and the outcome an e2e test
/// must assert for it.
///
/// Both spellings are required in one file: the fixture is what puts the
/// foreign name on the wire, and the outcome is what makes the test an
/// assertion about §4.17 rather than about the push route.
const _causeFixtures = <_ForeignName, (String, String)>{
  _ForeignName.accepted: (
    'tagLastEditedByAFormerColleague',
    'SyncRowOutcome.inserted',
  ),
  _ForeignName.refused: (
    'bearingAuthoredByAColleague',
    'SyncRowOutcome.unauthorized',
  ),
};

SyncTable _syncTable(String name) =>
    syncTables.firstWhere((t) => t.name == name);

/// Client calls with no end-to-end test, each with why and what would fix it.
///
/// This is a statement of what is **not** covered, which is the opposite of a
/// coverage list: an entry cannot make anything pass that would otherwise
/// fail, and a new client method is red until somebody decides which of the
/// two lists it belongs on.
const _notCoveredYet = <String, String>{
  // **Empty as of task 11.36, and that is the whole of what it means.** It
  // held three entries — `linkStatus`, `signOut` and `revokeAllSessions` — and
  // each is now exercised against a real server by
  // `auth_routes_e2e_test.dart`. Kept rather than deleted: an entry cannot
  // make anything pass that would otherwise fail, so the empty map costs
  // nothing, and the next client method that lands without coverage needs
  // somewhere to declare itself rather than a mechanism to reinvent.
};

String _relative(String path) =>
    path.startsWith('./') ? path.substring(2) : path;

/// The public method names declared on [className] in [path].
Set<String> _publicMethods(String path, String className) {
  final source = stripComments(File(path).readAsStringSync());
  final at = source.indexOf('class $className');
  if (at == -1) {
    throw StateError(
      'No `class $className` in $path. This guard reads that class to learn '
      'what the client can ask a server for; it is blind until the parse is '
      'updated.',
    );
  }
  final block = source.substring(at, _endOfClass(source, at));
  final names = {
    for (final m in RegExp(r'\n  (?:Future<[^;]*?>|void)\s+([a-z]\w*)\s*\(')
        .allMatches(block))
      m.group(1)!,
  };
  return names..removeWhere((name) => name.startsWith('_'));
}

int _endOfClass(String source, int from) {
  final next = source.indexOf('\nclass ', from + 1);
  return next == -1 ? source.length : next;
}
