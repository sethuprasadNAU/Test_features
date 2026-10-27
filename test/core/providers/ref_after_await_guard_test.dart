import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Task 11.256 — **the "Cannot use the Ref … after it has been disposed"
/// class, defined and derived from the code, with a verdict per member.**
///
/// Six instances were fixed one at a time (tasks 11.235, 11.236, 11.238) and
/// the hand count behind them was wrong the whole time. This file is the
/// definition that was missing, and it is a guard rather than a list: it
/// re-derives the population on every run, refuses an empty derivation, and
/// prints the count and every verdict as its last words.
///
/// ## The predicate, and where it comes from
///
/// `ref_after_await_hazards_test.dart` measured, on riverpod 3.3.2, that the
/// failure needs **three things at once**:
///
/// 1. the provider **auto-disposes**;
/// 2. its body (or a method of it, for a notifier class) **uses `ref` or
///    `state` after an `await` has completed** — `await ref.watch(x.future)`
///    is safe with respect to its *own* `await`, because the `ref` call runs
///    first, but a second one after it runs after the first gap and is the
///    shape (task 11.236 fixed exactly that, twice);
/// 3. it is **reached by a read that nothing keeps alive** — a `.read(` of it
///    anywhere in `lib/`, or of an auto-disposing provider whose body watches
///    it, transitively. A listener (a widget `ref.watch`, a `ref.listen`, a
///    `keepAlive` provider watching it) is what changes the outcome, so the
///    closure stops at `keepAlive` providers and never follows a `watch`.
///
/// Remove any one and the same measurement shows the body completing
/// normally. **The seven working providers task 11.235 could not separate from
/// the four broken ones differ on (3) alone**, which is why a guard on the body
/// shape fired on all eleven. This one condemns the conjunction, and today the
/// conjunction is empty.
///
/// **What this predicate deliberately does not cover, stated rather than
/// assumed away.** The second hazard the plan entry names — an invalidation
/// landing while a provider is mid-build, which orphans a bare `keepAlive`
/// read's future for good — was measured in the same file to be **independent
/// of the body shape** (it hangs a body that never touches `ref` after its gap
/// just the same), so no predicate over provider bodies can find it.
/// `ArrivalRefresh.settleFirst` (task 11.153) is the guard for that hazard and
/// `refresh_lists_test.dart` checks its list.
///
/// ## Exemptions are written here, with a reason, or they are not exemptions
///
/// A condemned member that is nevertheless safe — a `.read(` site whose widget
/// also watches the provider, say — goes in [_exemptions] with the sentence
/// that justifies it. The test fails on a condemned member with no entry and
/// on an entry whose member is no longer condemned, so an exemption cannot
/// outlive its reason unnoticed.
///
/// ## What the derivation reads, so its blind spots are known
///
/// Auto-dispose is read from the generated `.g.dart` (`isAutoDispose: true`
/// beside `@ProviderFor(x)`) and from hand-written `*Provider.autoDispose`
/// declarations. Bodies are sliced by brace matching after comment lines are
/// stripped (task 11.173's rule). A `ref` handed to a helper after a gap
/// counts as a `ref` use — `_ensureOwnerMembership` was that shape — but a
/// helper that *stores* a `ref` and uses it later is invisible to this. Reads
/// are found textually, so a provider read through an alias or a variable is
/// invisible too. Both are recorded so the next reader knows the instrument's
/// edge rather than mistaking it for the world's.
void main() {
  group('the predicate, on fixtures with a known answer', () {
    // Task 11.212's rule: exercise a finder against a fixture whose answer is
    // known, not against whatever the codebase holds today. Each case below
    // is one verdict, watched red by flipping the fixture.

    test('every ref call before the first await is not the shape, whether '
        'there is one await or the watches are issued up front', () {
      final census = _derive({
        'lib/a.dart': '''
@riverpod
Future<int> safe(Ref ref) async {
  final repo = await ref.watch(repoProvider.future);
  final n = await repo.count();
  return n;
}
@riverpod
Future<int> upFront(Ref ref) async {
  final repoFuture = ref.watch(repoProvider.future);
  final otherFuture = ref.watch(otherProvider.future);
  final repo = await repoFuture;
  final other = await otherFuture;
  return repo.count(other);
}
''',
        'lib/a.g.dart': _generated({'safe': true, 'upFront': true}),
      });
      expect(census.byName('safeProvider').hasShape, isFalse);
      expect(census.byName('upFrontProvider').hasShape, isFalse);
    });

    test('a second await ref.watch after the first is the shape — the ref '
        'call runs after the first gap (what task 11.236 fixed twice)', () {
      final census = _derive({
        'lib/a.dart': '''
@riverpod
Future<int> twice(Ref ref) async {
  final repo = await ref.watch(repoProvider.future);
  final other = await ref.watch(otherProvider.future);
  return repo.count(other);
}
''',
        'lib/a.g.dart': _generated({'twice': true}),
      });
      expect(census.byName('twiceProvider').hasShape, isTrue);
    });

    test('a ref use after a completed await is the shape', () {
      final census = _derive({
        'lib/a.dart': '''
@riverpod
Future<int> shaped(Ref ref) async {
  final repo = await ref.watch(repoProvider.future);
  final n = await repo.count();
  final other = ref.watch(otherProvider);
  return n + other;
}
''',
        'lib/a.g.dart': _generated({'shaped': true}),
      });
      expect(census.byName('shapedProvider').hasShape, isTrue);
    });

    test('a ref handed to a helper after a gap is the shape (task 11.235)', () {
      final census = _derive({
        'lib/a.dart': '''
@riverpod
Future<List<int>> repaired(Ref ref) async {
  final repo = await ref.watch(repoProvider.future);
  final rows = await repo.all();
  for (final row in rows) {
    await _repair(ref, row);
  }
  return rows;
}
''',
        'lib/a.g.dart': _generated({'repaired': true}),
      });
      expect(census.byName('repairedProvider').hasShape, isTrue);
    });

    test('an arrow body with only the safe form is not the shape', () {
      final census = _derive({
        'lib/a.dart': '''
@riverpod
Future<bool> arrow(Ref ref, String id) async =>
    (await ref.watch(standingProvider(id).future)).mayWrite;
''',
        'lib/a.g.dart': _generated({'arrow': true}),
      });
      expect(census.byName('arrowProvider').hasShape, isFalse);
    });

    test('a hand-written autoDispose provider is in the population', () {
      final census = _derive({
        'lib/a.dart': '''
final handProvider =
    FutureProvider.autoDispose.family<List<int>, String>((ref, id) async {
  final repo = await ref.watch(repoProvider.future);
  final rows = await repo.find(id);
  ref.watch(otherProvider);
  return rows;
}, name: 'handProvider');
''',
      });
      final hand = census.byName('handProvider');
      expect(hand.autoDispose, isTrue);
      expect(hand.hasShape, isTrue);
    });

    test('a keepAlive provider is in the census and never condemned', () {
      final census = _derive({
        'lib/a.dart': '''
@Riverpod(keepAlive: true)
Future<int> kept(Ref ref) async {
  final repo = await ref.watch(repoProvider.future);
  final n = await repo.count();
  return ref.watch(otherProvider) + n;
}
void tap(WidgetRef ref) => ref.read(keptProvider.future);
''',
        'lib/a.g.dart': _generated({'kept': false}),
      });
      final kept = census.byName('keptProvider');
      expect(kept.autoDispose, isFalse);
      expect(kept.hasShape, isTrue);
      expect(census.condemned, isEmpty);
    });

    test('a notifier method using state after a gap is the shape; one that '
        'awaits after writing is not', () {
      final census = _derive({
        'lib/a.dart': '''
@riverpod
class Late extends _\$Late {
  @override
  Future<int> build() async => 0;
  Future<void> set(int v) async {
    await _prefs.setInt(_key, v);
    state = AsyncData(v);
  }
}
@riverpod
class Early extends _\$Early {
  @override
  Future<int> build() async => 0;
  Future<void> set(int v) async {
    state = AsyncData(v);
    await _prefs.setInt(_key, v);
  }
  Future<void> other() async {
    await _prefs.remove(_key);
  }
}
''',
        'lib/a.g.dart': _generated({'Late': true, 'Early': true}),
      });
      expect(census.byName('lateProvider').hasShape, isTrue);
      expect(census.byName('earlyProvider').hasShape, isFalse);
    });

    test('shape + auto-dispose + a bare read anywhere in lib/ is condemned; '
        'the same provider only ever watched is not', () {
      const tree = '''
@riverpod
Future<int> shaped(Ref ref) async {
  final repo = await ref.watch(repoProvider.future);
  final n = await repo.count();
  return n + ref.watch(otherProvider);
}
''';
      const screen = '''
class S extends ConsumerWidget {
  Widget build(BuildContext context, WidgetRef ref) {
    final n = ref.watch(shapedProvider);
    return Text('\$n');
  }
}
''';
      const button = '''
Future<void> onTap(WidgetRef ref) async {
  final n = await ref.read(shapedProvider.future);
}
''';
      final watched = _derive({
        'lib/a.dart': tree,
        'lib/a.g.dart': _generated({'shaped': true}),
        'lib/s.dart': screen,
      });
      expect(watched.condemned, isEmpty);
      expect(watched.byName('shapedProvider').reachedBareBy, isNull);

      final read = _derive({
        'lib/a.dart': tree,
        'lib/a.g.dart': _generated({'shaped': true}),
        'lib/s.dart': screen,
        'lib/b.dart': button,
      });
      expect(read.condemned.map((p) => p.symbol), ['shapedProvider']);
      expect(read.byName('shapedProvider').reachedBareBy, contains('b.dart'));
    });

    test('a bare read reaches what the read provider watches, transitively, '
        'through auto-dispose providers only (task 11.236\'s finding)', () {
      const providers = '''
@riverpod
Future<bool> outer(Ref ref, String id) async =>
    (await ref.watch(innerProvider(id).future)).flag;
@riverpod
Future<Standing> inner(Ref ref, String id) async {
  final user = await ref.watch(userProvider.future);
  return ref.watch(standingProvider(id, user.id));
}
@Riverpod(keepAlive: true)
Future<bool> wall(Ref ref) async {
  final v = await ref.watch(innerProvider('x').future);
  return v.flag;
}
''';
      final direct = _derive({
        'lib/p.dart': providers,
        'lib/p.g.dart': _generated({
          'outer': true,
          'inner': true,
          'wall': false,
        }),
        'lib/b.dart':
            'void t(WidgetRef ref) => ref.read(outerProvider("a").future);',
      });
      expect(direct.condemned.map((p) => p.symbol), ['innerProvider']);
      expect(
        direct.byName('innerProvider').reachedBareBy,
        contains('outerProvider'),
      );

      final throughWall = _derive({
        'lib/p.dart': providers,
        'lib/p.g.dart': _generated({
          'outer': true,
          'inner': true,
          'wall': false,
        }),
        'lib/b.dart': 'void t(WidgetRef ref) => ref.read(wallProvider.future);',
      });
      expect(
        throughWall.condemned,
        isEmpty,
        reason: 'a keepAlive provider watching inner keeps it alive',
      );
    });

    test('a comment mentioning ref after an await is not the shape', () {
      final census = _derive({
        'lib/a.dart': '''
@riverpod
Future<int> commented(Ref ref) async {
  final repo = await ref.watch(repoProvider.future);
  final n = await repo.count();
  // ref.watch used to be here and it broke (task 11.235)
  return n;
}
''',
        'lib/a.g.dart': _generated({'commented': true}),
      });
      expect(census.byName('commentedProvider').hasShape, isFalse);
    });
  });

  group('the population, derived from lib/', () {
    late _Census census;

    setUpAll(() {
      final sources = <String, String>{};
      for (final entity in Directory('lib').listSync(recursive: true)) {
        if (entity is File && entity.path.endsWith('.dart')) {
          sources[entity.path] = entity.readAsStringSync();
        }
      }
      census = _derive(sources);
    });

    test('the derivation reached something (a guard that scans nothing '
        'passes for the wrong reason)', () {
      expect(census.providers.where((p) => p.autoDispose), isNotEmpty);
      expect(census.providers.where((p) => p.hasShape), isNotEmpty);
      expect(
        census.providers.where((p) => p.reachedBareBy != null),
        isNotEmpty,
      );
      expect(
        census.providers.where((p) => p.handWritten),
        isNotEmpty,
        reason:
            'deployments_provider.dart and individuals_provider.dart are '
            'hand-written autoDispose families; if both are gone, the '
            'hand-written branch of this derivation is untested',
      );
    });

    test('every condemned member is exempted in writing, and every exemption '
        'names a member that is still condemned', () {
      final condemned = {for (final p in census.condemned) p.symbol: p};
      for (final p in condemned.values) {
        expect(
          _exemptions,
          contains(p.symbol),
          reason:
              '${p.symbol} (${p.path}) auto-disposes, uses ref or state '
              'after a completed await, and is reached by a read nothing keeps '
              'alive (${p.reachedBareBy}). That is the shape that broke the '
              'tag database\'s + button (11.235) and Sync Status\'s "Try again" '
              '(11.236). Either issue every ref call before the first await, '
              'or write the reason it is safe into _exemptions.',
        );
      }
      for (final symbol in _exemptions.keys) {
        expect(
          condemned,
          contains(symbol),
          reason:
              '$symbol is exempted but no longer condemned — the exemption '
              'has outlived its reason; delete it',
        );
      }
    });

    tearDownAll(() {
      // Last words are the finding (task 11.69's rule): the count and every
      // verdict, so the next person who asks "how many" reads it here rather
      // than counting by hand.
      final auto = census.providers.where((p) => p.autoDispose).toList();
      final shaped = auto.where((p) => p.hasShape).toList();
      final reached = auto.where((p) => p.reachedBareBy != null).toList();
      final buffer = StringBuffer()
        ..writeln('ref-after-await census (task 11.256):')
        ..writeln(
          '  ${census.providers.length} generated or hand-written '
          'providers in lib/; ${auto.length} auto-dispose',
        )
        ..writeln(
          '  ${shaped.length} auto-dispose with ref/state used after '
          'a completed await:',
        )
        ..writeAll(shaped.map((p) => '    ${p.symbol}  ${p.verdict}\n'))
        ..writeln(
          '  ${reached.length} auto-dispose reached by a bare read '
          '(directly or through what they watch)',
        )
        ..writeln(
          '  condemned (all three at once): '
          '${census.condemned.length}; exempted: ${_exemptions.length}',
        )
        ..writeln(
          '  regenerate: this file, group "the population"; or the '
          'python sketch in task 11.256\'s comms entry',
        );
      // ignore: avoid_print
      print(buffer);
    });
  });
}

/// Condemned members that are safe anyway, each with the sentence that says
/// why. Empty today: the derivation finds nothing that has all three
/// properties at once. A member added here is a decision, not a silence.
const Map<String, String> _exemptions = {};

/// The census of one source tree: every provider found, with its verdict.
class _Census {
  _Census(this.providers);
  final List<_ProviderInfo> providers;

  _ProviderInfo byName(String symbol) => providers.firstWhere(
    (p) => p.symbol == symbol,
    orElse: () => fail('no provider named $symbol in the census'),
  );

  List<_ProviderInfo> get condemned => providers
      .where((p) => p.autoDispose && p.hasShape && p.reachedBareBy != null)
      .toList();
}

class _ProviderInfo {
  _ProviderInfo({
    required this.symbol,
    required this.path,
    required this.autoDispose,
    required this.handWritten,
    required this.hasShape,
    required this.watches,
  });

  /// The `xProvider` symbol the rest of the app names it by.
  final String symbol;
  final String path;
  final bool autoDispose;
  final bool handWritten;

  /// `ref` or `state` used after a completed `await`, in the body or in any
  /// method of a notifier class.
  final bool hasShape;

  /// Provider symbols this one's body `ref.watch`es or `ref.read`s.
  final Set<String> watches;

  /// Set by the closure: what reaches this provider with nothing keeping it
  /// alive — a file with a `.read(` of it, or the provider that watches it
  /// and is itself reached.
  String? reachedBareBy;

  String get verdict {
    if (!autoDispose) return 'keepAlive — not in the class';
    if (!hasShape) return 'no ref after a gap — safe read bare or watched';
    if (reachedBareBy == null) {
      return 'shape, only ever watched or listened — safe (a listener is what '
          'changes the outcome, measured in ref_after_await_hazards_test)';
    }
    return 'CONDEMNED — reached bare by $reachedBareBy';
  }
}

/// The `.g.dart` fixture shape this derivation reads: `@ProviderFor(name)`
/// followed, somewhere below, by `isAutoDispose: true|false`.
String _generated(Map<String, bool> providers) {
  final buffer = StringBuffer();
  providers.forEach((name, autoDispose) {
    buffer
      ..writeln('@ProviderFor($name)')
      ..writeln('final ${_symbolFor(name)} = ${name}Provider._();')
      ..writeln('final class ${name}Provider extends \$FunctionalProvider {')
      ..writeln('  const ${name}Provider._()')
      ..writeln('    : super(isAutoDispose: $autoDispose);')
      ..writeln('}');
  });
  return buffer.toString();
}

String _symbolFor(String declaredName) =>
    '${declaredName[0].toLowerCase()}${declaredName.substring(1)}Provider';

String _stripCommentLines(String source) => source
    .split('\n')
    .where((line) => !line.trimLeft().startsWith('//'))
    .join('\n');

_Census _derive(Map<String, String> rawSources) {
  final sources = {
    for (final e in rawSources.entries) e.key: _stripCommentLines(e.value),
  };
  final providers = <_ProviderInfo>[];

  // Generated providers: the .g.dart says which auto-dispose, the .dart
  // beside it holds the body.
  for (final entry in sources.entries) {
    if (!entry.key.endsWith('.g.dart')) continue;
    final sourcePath = '${entry.key.substring(0, entry.key.length - 7)}.dart';
    final source = sources[sourcePath];
    if (source == null) {
      fail('${entry.key} has no $sourcePath beside it');
    }
    for (final m in RegExp(r'@ProviderFor\((\w+)\)').allMatches(entry.value)) {
      final name = m.group(1)!;
      final flag = RegExp(
        r'isAutoDispose: (true|false)',
      ).firstMatch(entry.value.substring(m.end));
      if (flag == null) fail('${entry.key}: no isAutoDispose after $name');
      final body = _declarationBody(source, name);
      if (body == null) fail('$sourcePath: no declaration of $name found');
      providers.add(
        _ProviderInfo(
          symbol: _symbolFor(name),
          path: sourcePath,
          autoDispose: flag.group(1) == 'true',
          handWritten: false,
          hasShape: body.isClass
              ? _classMethods(body.text).any(_usesRefOrStateAfterGap)
              : _usesRefOrStateAfterGap(body.text),
          watches: _watchesIn(body.text),
        ),
      );
    }
  }

  // Hand-written `xProvider = FutureProvider.autoDispose...` declarations.
  for (final entry in sources.entries) {
    if (entry.key.endsWith('.g.dart')) continue;
    for (final m in RegExp(
      r'final (\w+) =\s*\w+Provider\.autoDispose',
    ).allMatches(entry.value)) {
      final text = _statementFrom(entry.value, m.start);
      providers.add(
        _ProviderInfo(
          symbol: m.group(1)!,
          path: entry.key,
          autoDispose: true,
          handWritten: true,
          hasShape: _usesRefOrStateAfterGap(text),
          watches: _watchesIn(text),
        ),
      );
    }
  }

  // Bare reads: a `.read(xProvider` anywhere — a widget callback, another
  // provider's body, a container in a harness.
  final bySymbol = {for (final p in providers) p.symbol: p};
  final frontier = <_ProviderInfo>[];
  for (final p in providers) {
    if (!p.autoDispose) continue;
    final readers = <String>[];
    for (final entry in sources.entries) {
      if (RegExp(
        r'\.read\(\s*' + RegExp.escape(p.symbol) + r'\b',
      ).hasMatch(entry.value)) {
        readers.add(entry.key.split('/').last);
      }
    }
    if (readers.isNotEmpty) {
      p.reachedBareBy = 'read bare in ${readers.join(', ')}';
      frontier.add(p);
    }
  }
  // …and what a bare-read auto-dispose provider watches is reached too,
  // because when it disposes its dependencies lose their only listener. A
  // keepAlive dependency stops the walk: it stays alive, and so does
  // everything it watches.
  while (frontier.isNotEmpty) {
    final p = frontier.removeLast();
    for (final dep in p.watches) {
      final target = bySymbol[dep];
      if (target == null ||
          !target.autoDispose ||
          target.reachedBareBy != null) {
        continue;
      }
      target.reachedBareBy =
          'watched by ${p.symbol}, which is ${p.reachedBareBy}';
      frontier.add(target);
    }
  }

  return _Census(providers);
}

class _Body {
  _Body(this.text, {required this.isClass});
  final String text;
  final bool isClass;
}

/// The text of the declaration named [name] — a top-level function from its
/// signature to its closing brace or `;`, or a class from `class` to its
/// closing brace.
_Body? _declarationBody(String source, String name) {
  final classMatch = RegExp(
    '^class $name\\b',
    multiLine: true,
  ).firstMatch(source);
  if (classMatch != null) {
    final open = source.indexOf('{', classMatch.end);
    return _Body(
      source.substring(classMatch.start, _matching(source, open) + 1),
      isClass: true,
    );
  }
  // A return type, then the name, then its parameter list.
  // The return type may be a record — `Future<({int waiting, int held})>` —
  // so braces and colons are allowed before the name.
  final fn = RegExp(
    '^[A-Za-z_<>?,.:\\s(){}]*?\\b$name\\(',
    multiLine: true,
  ).firstMatch(source);
  if (fn == null) return null;
  final paramsClose = _matching(source, fn.end - 1);
  return _Body(_bodyAfterParams(source, fn.start, paramsClose), isClass: false);
}

/// From a function's closing `)` to the end of its body: a `=> …;` or `{…}`.
String _bodyAfterParams(String source, int start, int paramsClose) {
  final arrow = source.indexOf('=>', paramsClose);
  final brace = source.indexOf('{', paramsClose);
  if (arrow != -1 && (brace == -1 || arrow < brace)) {
    return source.substring(start, _statementEnd(source, arrow) + 1);
  }
  return source.substring(start, _matching(source, brace) + 1);
}

/// A `final x = …;` statement from [start] to its terminating `;` at depth 0.
String _statementFrom(String source, int start) =>
    source.substring(start, _statementEnd(source, start) + 1);

int _statementEnd(String source, int from) {
  var depth = 0;
  for (var i = from; i < source.length; i++) {
    switch (source[i]) {
      case '(' || '{' || '[':
        depth++;
      case ')' || '}' || ']':
        depth--;
      case ';' when depth == 0:
        return i;
    }
  }
  fail('unterminated statement from offset $from');
}

/// Index of the bracket closing the one at [open].
int _matching(String source, int open) {
  final opener = source[open];
  final closer = const {'(': ')', '{': '}', '[': ']'}[opener]!;
  var depth = 0;
  for (var i = open; i < source.length; i++) {
    if (source[i] == opener) depth++;
    if (source[i] == closer && --depth == 0) return i;
  }
  fail('unbalanced $opener at offset $open');
}

/// The bodies of a class's members, one string each, so an `await` in one
/// method is never counted against a `ref` in another.
List<String> _classMethods(String classText) {
  final open = classText.indexOf('{');
  final inner = classText.substring(open + 1, classText.length - 1);
  final members = <String>[];
  var depth = 0;
  var start = 0;
  for (var i = 0; i < inner.length; i++) {
    switch (inner[i]) {
      case '(' || '{' || '[':
        depth++;
      case ')' || ']':
        depth--;
      case '}':
        depth--;
        if (depth == 0) {
          members.add(inner.substring(start, i + 1));
          start = i + 1;
        }
      case ';' when depth == 0:
        members.add(inner.substring(start, i + 1));
        start = i + 1;
    }
  }
  return members;
}

/// The predicate on one body: some `ref` or `state` token sits after an
/// `await` that has completed — i.e. a statement boundary (`;`, `{`, `}`)
/// lies between the two — and is not that `await`'s own operand.
bool _usesRefOrStateAfterGap(String body) {
  final awaits = RegExp(r'\bawait\b').allMatches(body).map((m) => m.start);
  final uses = RegExp(r'\b(ref|state)\b').allMatches(body).map((m) => m.start);
  for (final use in uses) {
    for (final a in awaits) {
      if (a >= use) continue;
      final between = body.substring(a, use);
      if (RegExp(r'[;{}]').hasMatch(between)) return true;
    }
  }
  return false;
}

Set<String> _watchesIn(String body) => RegExp(
  r'\bref\.(?:watch|read|listen)\(\s*(\w+Provider)\b',
).allMatches(body).map((m) => m.group(1)!).toSet();
