import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../support/dart_source.dart';

/// Task 11.105 — **the guard for the class, not the two instances.**
///
/// ## What went wrong
///
/// Task 11.66 walked a real Android build and found two screens naming the
/// wrong cause for a failure. Both had the right sentence in the code, in a
/// typed `catch` on the far side of `await ref.read(someProvider.future)`, and
/// in both the branch had never once been taken. `@riverpod` generates an
/// autoDispose provider; `ref.read(...future)` holds no listener across the
/// await; the element is torn down while still loading; and the caller gets a
/// `StateError` about the teardown instead of the exception. **The original is
/// destroyed, not wrapped** — see
/// `test/core/providers/provider_boundary_behaviour_test.dart`, which measures
/// all of it against the real package.
///
/// **Nothing about that code looks wrong.** It compiles, it reads correctly,
/// and its tests pass — which is exactly why a sweep is not enough on its own.
/// Task 11.104's brief put it best: nobody knows how many others there are. So
/// this file is the standing answer, in the shape task 11.98 established for
/// the vocabulary of a removed feature: **a checked list, where a survivor has
/// to be argued for rather than merely overlooked.**
///
/// ## The three checks
///
/// 1. **[_cannotCross] is still true.** Each type it names is still thrown
///    from the provider it names. A list that has quietly gone stale is worse
///    than no list.
/// 2. **Nothing in `lib/` type-tests one of those types.** They cannot arrive;
///    a branch testing for one is unreachable by construction, and the fix is
///    a value from a `keepAlive` provider, not a better `catch`.
/// 3. **No autoDispose provider throws without being on the list.** This is
///    the one that catches *new* code — a provider added next month whose
///    build throws, and the first `await …future` written against it.
///
/// ## What this does not catch, stated so nobody reads more into a green run
///
/// Check 3 finds a `throw` written **directly** in a provider's build. It
/// cannot follow a call — `serverHttpClient` throws `InvalidServerUrl` only by
/// way of `requireValidServerUrl`, and no textual scan finds that. That entry
/// is on the list because a person put it there. A new provider that throws
/// indirectly will not be caught by check 3, and check 2 will only catch it
/// once somebody writes the typed `catch` this test then refuses.
///
/// It also says nothing about `server/`, `packages/` or `website/`: Riverpod is
/// only in the app.
const List<_UncrossableType> _cannotCross = [
  _UncrossableType(
    type: 'LocationPermissionDeniedException',
    thrownIn: 'lib/core/providers/gps_provider.dart',
    provider: 'gpsPositionProvider',
    insteadUse: 'locationProblemProvider',
    reason:
        'Thrown inside the autoDispose `gpsPosition` stream. Task 11.66 '
        'reproduced the consequence on a phone: with location refused, '
        'Project Setup told the person to try again outdoors with a clear '
        'sky view. Fixed in task 11.105 by reading the cause as a value.',
  ),
  _UncrossableType(
    type: 'InvalidServerUrl',
    thrownIn: 'lib/core/providers/server_config_provider.dart',
    provider: 'serverHttpClientProvider',
    insteadUse: 'serverUrlRefusalProvider',
    reason:
        'Thrown by `requireValidServerUrl` from inside the autoDispose '
        '`serverHttpClient` build — indirectly, so check 3 cannot see it. '
        'Task 11.66 reproduced the consequence: a release build refused a '
        'plain http:// LAN address and then reported "Offline". Fixed in '
        'task 11.104 by reading the refusal as a value.',
  ),
  _UncrossableType(
    type: null,
    thrownIn: 'lib/core/providers/compass_provider.dart',
    provider: 'compassHeadingProvider',
    insteadUse: 'compassAvailableProvider',
    reason:
        'Throws a bare `StateError` when the OS has no compass. Listed so '
        'check 3 stays quiet, but with no `type` to ban: `StateError` is not '
        'a domain type and banning it across lib/ would be absurd. Nothing '
        'awaits this provider\'s `.future` today — every consumer watches it '
        'as an AsyncValue, which does carry the raw error. If one ever does '
        'await it, this is the entry that explains why it will not work.',
  ),
];

class _UncrossableType {
  const _UncrossableType({
    required this.type,
    required this.thrownIn,
    required this.provider,
    required this.insteadUse,
    required this.reason,
  });

  /// The exception nothing may type-test, or null when the throw is real but
  /// the type is too generic to ban (see the `compassHeading` entry).
  final String? type;
  final String thrownIn;
  final String provider;
  final String insteadUse;
  final String reason;
}

/// Providers annotated `@riverpod` — autoDispose, the shape with the problem.
/// `@Riverpod(keepAlive: true)` is excluded: a keepAlive provider is not torn
/// down mid-load, so its error does reach an awaiting caller (late, after
/// Riverpod's automatic retries, but intact).
final _autoDisposeAnnotation = RegExp(r'@riverpod\s*\n');

/// A `throw` that is not a bare `rethrow`, at the start of a statement.
final _throwStatement = RegExp(r'(^|[{;)]\s*|\s)throw\s+[A-Za-z_(]');

void main() {
  final files = dartFilesUnder('lib');

  group('the list itself is still true', () {
    for (final entry in _cannotCross) {
      test('${entry.provider} still throws where the list says', () {
        final file = File(entry.thrownIn);
        expect(
          file.existsSync(),
          isTrue,
          reason:
              '${entry.thrownIn} is gone. Update or remove this entry in '
              '_cannotCross — a stale list is worse than none.',
        );
        final source = stripComments(file.readAsStringSync());
        expect(
          _throwStatement.hasMatch(source),
          isTrue,
          reason:
              '${entry.thrownIn} no longer throws anything. If ${entry.provider} '
              'has stopped being able to fail, delete its entry from '
              '_cannotCross and the ban in check 2 goes with it.',
        );
        if (entry.type != null) {
          expect(
            source,
            contains('throw'),
            reason: 'sanity: the file still contains a throw',
          );
          expect(
            RegExp('throw (const )?${entry.type}').hasMatch(source),
            isTrue,
            reason:
                '${entry.thrownIn} no longer throws ${entry.type}. Either it '
                'moved — update thrownIn — or the type is retired and this '
                'entry should go.',
          );
        }
      });
    }

    test('every replacement named in the list exists', () {
      // The half of an entry that is advice rather than fact, and therefore
      // the half most likely to rot. "Use serverUrlRefusalProvider instead" is
      // useless if that provider was renamed two tasks ago.
      final allSource = files.map((f) => f.readAsStringSync()).join('\n');
      for (final entry in _cannotCross) {
        expect(
          allSource,
          contains(entry.insteadUse),
          reason:
              '_cannotCross tells the next person to use ${entry.insteadUse} '
              'instead of catching ${entry.type ?? entry.provider}, and no '
              'such name exists in lib/ any more.',
        );
      }
    });
  });

  test('nothing in lib/ type-tests an exception that cannot reach it', () {
    final banned = {
      for (final e in _cannotCross)
        if (e.type != null) e.type!: e,
    };
    final offences = <String>[];

    for (final file in files) {
      // The declaration and the doc comment explaining why the type is
      // uncatchable both mention the name legitimately; only a *test* of it
      // is the defect. Comments are stripped, and the two shapes below are the
      // ways Dart tests a type.
      final source = stripComments(file.readAsStringSync());
      final lines = source.split('\n');
      for (var i = 0; i < lines.length; i++) {
        for (final type in banned.keys) {
          final tested =
              RegExp('\\bon\\s+$type\\b').hasMatch(lines[i]) ||
              RegExp('\\bis\\s+$type\\b').hasMatch(lines[i]);
          if (!tested) continue;
          final entry = banned[type]!;
          offences.add(
            '${file.path}:${i + 1} tests for $type.\n'
            '    It cannot arrive: ${entry.reason}\n'
            '    Read ${entry.insteadUse} instead — it carries the same fact '
            'as a value.',
          );
        }
      }
    }

    expect(
      offences,
      isEmpty,
      reason:
          'A typed catch was added for an exception that a provider boundary '
          'destroys in transit. It will never be taken, and the person gets '
          'the generic message instead:\n\n${offences.join('\n\n')}',
    );
  });

  test('no autoDispose provider throws from its build without being listed',
      () {
    final listedFiles = _cannotCross.map((e) => e.thrownIn).toSet();
    final unlisted = <String>[];

    for (final file in files) {
      if (listedFiles.contains(file.path)) continue;
      final source = stripComments(file.readAsStringSync());
      for (final match in _autoDisposeAnnotation.allMatches(source)) {
        final body = _bodyAfter(source, match.end);
        if (body == null || !_throwStatement.hasMatch(body)) continue;
        final line = '\n'.allMatches(source.substring(0, match.start)).length + 1;
        unlisted.add('${file.path}:$line');
      }
    }

    expect(
      unlisted,
      isEmpty,
      reason:
          'An autoDispose (`@riverpod`) provider throws from its build. '
          'Awaiting its `.future` will not deliver that exception — the '
          'provider is torn down mid-load and the error is destroyed. Either '
          'carry the reason as a value from a keepAlive provider (see '
          'serverUrlRefusalProvider and locationProblemProvider), or add an '
          'entry to _cannotCross in this file saying why it is safe:\n'
          '  ${unlisted.join('\n  ')}',
    );
  });
}

/// The body a provider declaration introduces: a `{…}` block, or everything up
/// to the `;` of an `=>` body.
///
/// Returns null when the shape is not one of those two, so an unrecognised
/// declaration is skipped rather than silently scanned as the *next*
/// declaration's body — which is how a scan of this kind reports a throw in
/// the wrong function. For a Notifier class the block returned is the class
/// body, so a `throw` in any of its methods counts: a method's exception does
/// survive `ref.read(p.notifier).method()`, so that is over-broad rather than
/// blind, and an over-broad hit is fixed by writing an entry.
String? _bodyAfter(String source, int from) {
  final brace = source.indexOf('{', from);
  final arrow = source.indexOf('=>', from);
  final semi = source.indexOf(';', from);
  if (arrow != -1 && (brace == -1 || arrow < brace) && semi > arrow) {
    return source.substring(arrow, semi);
  }
  if (brace == -1) return null;
  // Nothing but a signature may sit between the annotation and the block.
  if (source.substring(from, brace).contains(';')) return null;
  var depth = 0;
  for (var i = brace; i < source.length; i++) {
    if (source[i] == '{') depth++;
    if (source[i] == '}') {
      depth--;
      if (depth == 0) return source.substring(brace, i + 1);
    }
  }
  return null;
}
