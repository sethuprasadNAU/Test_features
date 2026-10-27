@Tags(['documentation'])
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Tasks 11.144 and 11.145 — **no screen the tab shell keeps mounted may
/// `ref.watch` a provider that some other provider also watches.**
///
/// ## What went wrong, in one paragraph
///
/// Every completed sync round used to end a debug build with *"setState() or
/// markNeedsBuild() called during build"*, from whichever tab was showing —
/// `StatefulShellRoute.indexedStack` keeps every visited branch mounted, so
/// there was nowhere in the app to stand while a round finished. A round
/// announces the rows it landed, which marks the Position screen's
/// observations provider stale; the next frame's `build` calls `ref.watch` on
/// it, and Riverpod recomputes it there. The recompute notified a *second*
/// provider that watched the first, that provider invalidated itself, and
/// invalidating a provider asks the surrounding `ProviderScope` to schedule a
/// refresh — which is a `setState` on a widget above the one being built. Task
/// 11.144's remedy was to delete the second provider and have the first answer
/// both halves of the question.
///
/// ## Why this is a source check rather than a widget test
///
/// **Because a widget test cannot fail on it, and a check that cannot fail is
/// not a check.** The cascade needs the provider to still be dirty at the
/// moment `build` reads it, and that only happens under the live binding a
/// real device runs on: under `flutter test`'s automated binding Riverpod's
/// scheduled refresh always flushes first, so the pattern is harmless there.
/// Four attempts to reproduce it in `flutter test` — bare screen, real app
/// shell, on-tab and off-tab, with and without an async gap after the arrival
/// — all came back green against the *unfixed* code. The only instrument that
/// has ever seen this defect run is `integration_test` on a simulator.
///
/// So this reads the app's own source instead. It is a proxy for the defect
/// rather than the defect itself, and it is stated as one: what it actually
/// asserts is that **the set of these chains is exactly the set somebody has
/// argued for**, in [_argued] below. A new one is a hard failure; an entry
/// that no longer describes anything is also a hard failure, because a stale
/// allowlist is a hand-maintained list that has stopped being read.
///
/// ## What task 11.145 changed
///
/// 11.144 checked one screen and listed the others in a report. This derives
/// the list instead, over the whole of `lib/`, and covers all five branches —
/// including `/compass`, whose cleanliness was previously a sentence in a
/// report and is now the absence of a row in a derivation that would have
/// found one.
void main() {
  test('every provider chain on a shell branch is one somebody argued for', () {
    final corpus = _Corpus.scan();

    // ------------------------------------------------------------------
    // The scan asserts what it reached, rather than that it reached
    // *something*. A count somebody chose would rule out zero and nothing
    // else; these are facts about this repository that a narrowed or
    // mis-delimited scan gets wrong.
    // ------------------------------------------------------------------
    expect(
      corpus.filesScanned,
      greaterThan(corpus.screensByRoute.length),
      reason: 'the scan reached fewer files than there are screens to check',
    );
    for (final entry in corpus.screensByRoute.entries) {
      expect(
        File(entry.value).existsSync(),
        isTrue,
        reason: '${entry.key} is no longer at ${entry.value}. This check is '
            'about the branches `StatefulShellRoute.indexedStack` keeps '
            'mounted; if one has moved, point this at its new home rather '
            'than dropping it.',
      );
      expect(
        corpus.sitesIn(entry.value),
        isNotEmpty,
        reason: 'no `ref.watch` site at all was found in ${entry.value}, '
            'which means this scan has gone stale rather than that the '
            'screen is clean',
      );
    }

    // The row that caught the first version of this derivation, kept as a
    // fixture. `_mapDataProvider`'s argument list is written one parameter
    // per line, so `ref,` and `) async {` both start at column zero — a
    // parser that delimited declarations by "a line starting at column zero"
    // read the watches inside that provider as widget watches, and reported
    // nine chains on `/map` that do not exist. A derivation is trustworthy
    // because it disagrees with rows you already believe; this is the row.
    expect(
      corpus.watchedFromProviderBodyIn(
        'lib/features/map/screens/map_screen.dart',
        'recordingsRevisionProvider',
      ),
      isTrue,
      reason: "the map screen's `_mapDataProvider` watches "
          '`recordingsRevisionProvider` from inside a provider body. This '
          'scan read it as a widget watch, which means it has lost track of '
          'where declarations begin and every result below is suspect.',
    );
    expect(
      corpus.watchedFromWidgetIn(
        'lib/features/more/screens/more_screen.dart',
        'currentUserProvider',
      ),
      isTrue,
      reason: 'the More screen\'s `build` watches `currentUserProvider`. This '
          'scan read it as a provider-body watch, which means it has lost '
          'track of where declarations begin.',
    );

    // ------------------------------------------------------------------
    // The derivation, and the comparison against what has been argued for.
    // ------------------------------------------------------------------
    final report = StringBuffer();
    final unargued = <String>[];
    final staleEntries = <String>[];

    for (final entry in corpus.screensByRoute.entries) {
      final route = entry.key;
      final path = entry.value;
      final chains = corpus.chainsIn(path);
      final argued = _argued[route]!;

      report.writeln('  $route — ${chains.length} chain(s): '
          '${chains.isEmpty ? 'none' : (chains.toList()..sort()).join(', ')}');

      for (final name in chains) {
        if (!argued.containsKey(name)) {
          unargued.add('$route watches $name, which '
              '${corpus.providerWatchersOf(name).join(', ')} also watches');
        }
      }
      for (final name in argued.keys) {
        if (!chains.contains(name)) {
          staleEntries.add('$route no longer has a chain through $name');
        }
      }
    }

    // An instrument's last words are a finding, not a name: the five-line
    // tail CI keeps has to carry what was derived, every run.
    // ignore: avoid_print
    print('shell provider chains — scanned ${corpus.filesScanned} files under '
        'lib/, ${corpus.totalSites} `ref.watch` sites, '
        '${corpus.providerBodySites} of them inside a provider body:\n'
        '$report');

    expect(
      unargued,
      isEmpty,
      reason:
          'A screen the tab shell keeps mounted watches a provider that some '
          'other provider also watches, and nothing in this file argues for '
          'it:\n  ${unargued.join('\n  ')}\n\n'
          'That is the shape task 11.144 removed from the Position screen. '
          'When the widget watches the upstream one and it is stale, Riverpod '
          'recomputes it inside `build`, the downstream provider invalidates '
          'itself, and the `ProviderScope` above the screen is sent a '
          '`setState` mid-build — which a debug build stops on and a release '
          'build silently runs anyway. Either give the widget the downstream '
          'provider to watch instead of the upstream one, or fold the two '
          'together the way 11.144 did — and if neither is right, add it to '
          '`_argued` with the reason and with what would change the answer.',
    );
    expect(
      staleEntries,
      isEmpty,
      reason:
          'An entry in `_argued` no longer describes anything in the code:\n'
          '  ${staleEntries.join('\n  ')}\n\n'
          'Delete it. An allowlist that keeps entries for chains that are '
          'gone is a hand-maintained list nobody is reading, and the next '
          'person to add a real chain will assume the same of the rest.',
    );
  });
}

/// **Every chain that is deliberately still here, with the reason.**
///
/// Task 11.145's decision, made once and then applied, rather than four times
/// over:
///
///  * **Merging (task 11.144's remedy) needs both ends private to one screen.**
///    It worked there because `_tagObserversProvider` and
///    `_directionalObservationsProvider` were two halves of one question about
///    one screen. Every upstream below is app-wide — the signed-in user, the
///    server's address, this project's write permission, the chosen basemap —
///    and folding any of them into a screen's provider would be a worse defect
///    than the one it fixed.
///  * **Pointing the widget at the downstream provider instead** is the remedy
///    that generalises, and it is available only where the widget does not
///    need the upstream value itself. None of the cases below is that: each
///    widget reads something only the upstream provider has.
///  * **So all of them are left**, and each row says what would change that.
///
/// **The condition that makes a row live is not "a sync round moves it".** It
/// is narrower and it is checkable: the upstream has to be *stale* at the
/// moment `build` reads it, which means something has to `invalidate` it — a
/// notifier whose `state` is only ever assigned is never dirty and cannot
/// start this. **Which providers are invalidated at all is already enumerated**
/// — `test/documentation/invalidation_sites_test.dart` declares every
/// invalidate-by-name site in `lib/`, and the two refresh lists have their own
/// derived guard in `test/core/providers/refresh_lists_test.dart`. Read those
/// rather than grepping afresh.
///
/// `TriTrack_Technical_Context.md`, under *What `flutter test` Cannot See*,
/// holds the recorded fact and the reopen trigger; this file does not restate
/// it.
const Map<String, Map<String, String>> _argued = {
  '/map': {
    'currentUserProvider':
        'The map needs the signed-in `User` itself, for task 11.12\'s '
        '`authorEditVerdict`; no provider downstream of it carries that. '
        '`myProjectStandingProvider` is the downstream half and it is alive '
        'whenever this screen is, because the same `build` watches it. '
        '**`currentUserProvider` is invalidated today** — a Profile save, an '
        'identity setup and a sign-in each do it — so this is the closest of '
        'the five to live. What would change the answer: a downstream '
        'provider that carries the whole `User`, which this screen could then '
        'watch instead.',
    'myProjectStandingProvider':
        'The map asks whether this person may write here — and, since task '
        '11.237, *why not*, because a viewer\'s sentence and a snapshot\'s '
        'differ; the standing is the one provider that carries both. Its '
        'other watchers are `mayWriteProjectDataProvider` and '
        '`myProjectRoleProvider`, both one-line derivations of it: each is '
        '`autoDispose` and alive only while something watches *it* — '
        '`mayCopyTagIntoActiveProjectProvider` in `tag_database_screen.dart` '
        'while that screen is open, the Members screen\'s role card while it '
        'is — so the chain needs one of those screens pushed over the shell. '
        'What would change the answer: a longer-lived watcher of either '
        'derivation.',
    'selectedTileCategoryProvider':
        'The basemap picker shows which category is chosen, and '
        '`selectedTileSourceProvider` — the downstream half, watched by the '
        'same `build` — resolves to a `TileSource` asynchronously, so '
        'watching only that would put a spinner where the picker now has an '
        'answer. **This one cannot fire at all**, for a reason the other rows '
        'do not have: `SelectedTileCategory` is a notifier whose `state` is '
        'only ever assigned, never invalidated, so it is never dirty when '
        '`build` reads it. What would change the answer: any '
        '`invalidate(selectedTileCategoryProvider)`.',
  },
  '/record': {
    'myProjectStandingProvider':
        'As on `/map`, and for the same reason — the screen asks the write '
        'question directly and needs the reason too. Same derivations on the '
        'other end, same condition.',
  },
  '/compass': {},
  '/position': {
    'myProjectStandingProvider':
        'As on `/map`. Note this is a *different* chain from the one task '
        '11.144 fixed on this screen: that one was two private providers and '
        'is gone.',
    'selectedTileCategoryProvider':
        'As on `/map` — this screen draws the same basemap picker, and the '
        'same notifier-is-never-invalidated argument applies.',
  },
  '/more': {
    'currentUserProvider':
        'The hub prints the signed-in person\'s name and email under '
        '"Profile"; nothing downstream carries them. Same invalidation '
        'sources as `/map`\'s row.',
    'serverConfigProvider':
        'The hub prints the configured server\'s address and hides the Sync '
        'Status row when there is none. Its downstream watchers — the '
        'transport, the HTTP client, `CurrentSession` and `SyncController` — '
        'are alive all the time, so the *listener* half of this chain is '
        'always present; what is missing is anything that invalidates '
        '`serverConfigProvider`, which is a notifier assigned in place. What '
        'would change the answer: any `invalidate(serverConfigProvider)`.',
  },
};

/// One pass over `lib/`, classifying every `ref.watch(x` site by whether the
/// top-level declaration containing it is a provider or a widget.
class _Corpus {
  _Corpus._(this._sites, this.filesScanned);

  final List<_Site> _sites;
  final int filesScanned;

  /// The five branches `StatefulShellRoute.indexedStack` keeps mounted.
  final Map<String, String> screensByRoute = const {
    '/map': 'lib/features/map/screens/map_screen.dart',
    '/record':
        'lib/features/observations/screens/observation_logging_screen.dart',
    '/compass': 'lib/features/compass/screens/compass_screen.dart',
    '/position':
        'lib/features/position_estimation/screens/position_estimation_screen.dart',
    '/more': 'lib/features/more/screens/more_screen.dart',
  };

  static _Corpus scan() {
    final sites = <_Site>[];
    var files = 0;
    for (final entity in Directory('lib').listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      // Generated files are a mechanical restatement of the hand-written
      // ones beside them; counting their watches would double every row.
      if (entity.path.endsWith('.g.dart')) continue;
      files++;
      final source = _blankCommentsAndStrings(entity.readAsStringSync());

      // A file that actually compiles has a balanced bracket/brace/paren
      // count once comments and strings are blanked out. If it does not,
      // `_blankCommentsAndStrings` lost track of a quote or a comment
      // boundary — the known cause (task 11.208) is an adjacent
      // string-literal concatenation nested inside a `${...}` interpolation,
      // whose inner quote can be misread as the outer string's terminator.
      // Rather than hand a corrupted declaration-start list to the rest of
      // this derivation — which produced a real, ten-minute-costing wrong
      // answer naming an unrelated screen — this abstains immediately and
      // names the file and line where it lost the count.
      final badLine = _firstUnbalancedLine(source);
      if (badLine != null) {
        fail(
          'This scan abstained rather than reporting a result it does not '
          'trust: after blanking comments and strings, '
          '${entity.path}:$badLine has an unbalanced bracket, brace or '
          'parenthesis count. That means the string blanker lost track of a '
          "quote somewhere at or before that line -- most likely an adjacent "
          'string-literal concatenation nested inside a `\${...}` '
          'interpolation (task 11.208 found this in map_screen.dart). '
          'Every declaration-start offset this file would produce, and '
          'every chain derived from it, is unreliable until that is fixed. '
          'Nothing below this file was derived.',
        );
      }

      final starts = _declarationStarts(source);
      for (final m in RegExp(r'ref\.watch\(\s*([A-Za-z_]\w*)')
          .allMatches(source)) {
        var declStart = 0;
        for (final s in starts) {
          if (s <= m.start) {
            declStart = s;
          } else {
            break;
          }
        }
        final head = source
            .substring(declStart, (declStart + 300).clamp(0, source.length))
            .replaceAll(RegExp(r'\s+'), ' ');
        sites.add(_Site(
          path: entity.path,
          provider: m.group(1)!,
          insideProviderBody: _isProviderDeclaration(head),
        ));
      }
    }
    return _Corpus._(sites, files);
  }

  int get totalSites => _sites.length;
  int get providerBodySites =>
      _sites.where((s) => s.insideProviderBody).length;

  Iterable<_Site> sitesIn(String path) => _sites.where((s) => s.path == path);

  bool watchedFromProviderBodyIn(String path, String provider) => _sites.any(
      (s) => s.path == path && s.provider == provider && s.insideProviderBody);

  bool watchedFromWidgetIn(String path, String provider) => _sites.any(
      (s) => s.path == path && s.provider == provider && !s.insideProviderBody);

  /// Every provider watched from inside some provider's body, anywhere.
  late final Set<String> _watchedByProviders = {
    for (final s in _sites)
      if (s.insideProviderBody) s.provider,
  };

  List<String> providerWatchersOf(String provider) => {
        for (final s in _sites)
          if (s.insideProviderBody && s.provider == provider) s.path,
      }.toList()
        ..sort();

  /// The chains on one screen: providers its *widget* half watches that some
  /// provider also watches.
  Set<String> chainsIn(String path) => {
        for (final s in sitesIn(path))
          if (!s.insideProviderBody && _watchedByProviders.contains(s.provider))
            s.provider,
      };
}

class _Site {
  const _Site({
    required this.path,
    required this.provider,
    required this.insideProviderBody,
  });
  final String path;
  final String provider;
  final bool insideProviderBody;
}

bool _isProviderDeclaration(String head) {
  if (head.startsWith('@riverpod') || head.startsWith('@Riverpod')) return true;
  if (RegExp(r'^(?:final|const|var)\s+\w*[Pp]rovider\w*\s*=').hasMatch(head)) {
    return true;
  }
  // A plain top-level helper taking the provider's own `Ref` runs with that
  // provider's lifetime and its watches are the provider's watches.
  return head.contains('(Ref ref');
}

/// The 1-based line at which `blanked`'s bracket/brace/paren depth first
/// goes negative, or — if it never goes negative but does not return to
/// zero by end of file — the last line. Returns `null` when the file is
/// validly balanced throughout, which is what a real `.dart` file always is
/// once comments and strings are correctly blanked.
int? _firstUnbalancedLine(String blanked) {
  var depth = 0;
  for (var i = 0; i < blanked.length; i++) {
    final c = blanked[i];
    if (c == '(' || c == '{' || c == '[') {
      depth++;
    } else if (c == ')' || c == '}' || c == ']') {
      depth--;
      if (depth < 0) {
        return '\n'.allMatches(blanked.substring(0, i)).length + 1;
      }
    }
  }
  if (depth != 0) {
    return '\n'.allMatches(blanked).length + 1;
  }
  return null;
}

/// Offsets at which a top-level declaration begins.
///
/// Brace-depth rather than "a line that starts at column zero": Dart argument
/// lists are routinely written one parameter per line, so `ref,` and
/// `) async {` inside a provider both start at column zero. See the fixture
/// in `main` — a column-zero parser read a provider's body as widget code.
List<int> _declarationStarts(String source) {
  final starts = <int>[];
  var depth = 0;
  var inDeclaration = false;
  for (var i = 0; i < source.length; i++) {
    final c = source[i];
    if (!inDeclaration && depth == 0 && c.trim().isNotEmpty) {
      starts.add(i);
      inDeclaration = true;
    }
    if (c == '(' || c == '{' || c == '[') {
      depth++;
    } else if (c == ')' || c == '}' || c == ']') {
      depth--;
    }
    if (depth == 0 && (c == ';' || c == '}')) inDeclaration = false;
  }
  return starts;
}

/// Blanks comments and string bodies, preserving every offset.
///
/// Needed because this repository's doc comments quote `ref.watch(...)` often,
/// and a check that counted those would report chains nobody wrote.
String _blankCommentsAndStrings(String src) {
  final out = List<String>.from(src.split(''));
  var i = 0;
  while (i < src.length) {
    final c = src[i];
    if (c == '/' && i + 1 < src.length && src[i + 1] == '/') {
      while (i < src.length && src[i] != '\n') {
        out[i] = ' ';
        i++;
      }
    } else if (c == '/' && i + 1 < src.length && src[i + 1] == '*') {
      out[i] = ' ';
      out[i + 1] = ' ';
      i += 2;
      while (i + 1 < src.length && !(src[i] == '*' && src[i + 1] == '/')) {
        if (src[i] != '\n') out[i] = ' ';
        i++;
      }
      if (i + 1 < src.length) {
        out[i] = ' ';
        out[i + 1] = ' ';
        i += 2;
      }
    } else if (c == "'" || c == '"') {
      final quote = c;
      final triple = i + 2 < src.length &&
          src[i + 1] == quote &&
          src[i + 2] == quote;
      if (triple) {
        i += 3;
        while (i + 2 < src.length &&
            !(src[i] == quote && src[i + 1] == quote && src[i + 2] == quote)) {
          if (src[i] != '\n') out[i] = ' ';
          i++;
        }
        i += 3;
      } else {
        i++;
        while (i < src.length && src[i] != quote && src[i] != '\n') {
          if (src[i] == r'\') {
            out[i] = ' ';
            i++;
            if (i < src.length) out[i] = ' ';
            i++;
            continue;
          }
          // A `${...}` interpolation is skipped as a balanced-brace unit
          // rather than character by character, because it can hold a
          // nested string literal — even an adjacent-literal concatenation
          // of two of them — whose own quote must not be mistaken for the
          // outer string's terminator (task 11.208, found in
          // map_screen.dart). Everything inside is still blanked; only the
          // *bookkeeping* of where the outer string actually ends changes.
          if (src[i] == r'$' && i + 1 < src.length && src[i + 1] == '{') {
            out[i] = ' ';
            out[i + 1] = ' ';
            i += 2;
            var depth = 1;
            while (i < src.length && depth > 0) {
              final ic = src[i];
              if (ic == '{') {
                depth++;
              } else if (ic == '}') {
                depth--;
              } else if (ic == "'" || ic == '"') {
                final nested = ic;
                if (src[i] != '\n') out[i] = ' ';
                i++;
                while (i < src.length &&
                    src[i] != nested &&
                    src[i] != '\n') {
                  if (src[i] == r'\') {
                    if (src[i] != '\n') out[i] = ' ';
                    i++;
                    if (i >= src.length) break;
                  }
                  if (src[i] != '\n') out[i] = ' ';
                  i++;
                }
                if (i < src.length && src[i] == nested && src[i] != '\n') {
                  out[i] = ' ';
                }
                i++;
                continue;
              }
              if (i < src.length && src[i] != '\n') out[i] = ' ';
              i++;
            }
            continue;
          }
          out[i] = ' ';
          i++;
        }
        i++;
      }
    } else {
      i++;
    }
  }
  return out.join();
}
