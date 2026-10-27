// Does the website still quote the app correctly?
//
// A sentence on the website that the app no longer says is this project's
// single most-repeated defect. It has been found four separate times inside
// `lib/` alone, and the website will accumulate quoted copy faster than the
// app did. This check exists so that drift is a red build rather than a
// discovery.
//
// It enforces four rules over `website/content/`:
//
//   1. Every {{< app "..." >}} string must still exist in the app's own
//      source, as the text of a Dart string literal. If the app's wording
//      changes and the site's does not, this goes red.
//
//   2. No double-quoted span may appear in prose at all. Quoting app copy
//      without the shortcode would be invisible to rule 1, so the plain act
//      of typing quotation marks is refused. This is what makes the marking
//      non-optional: a writer cannot quote the app without either using the
//      shortcode or being told to.
//
//   3. No **bold** span may appear in prose. Bold is how UI labels get
//      written when somebody forgets the shortcode, and the shortcode already
//      renders bold. Use _italics_ for emphasis.
//
//   4. No {{< app "..." >}} string may be a value the database stores. An
//      `enum` member's `db` value is pinned by the schema, so a quote of one
//      passes however the screens change — it is a quote that cannot go red,
//      and a check that cannot fail is not a check. Added by `/w-08` after
//      task 11.99 rewrote two screens and every quoted string on the pages
//      describing them stayed green.
//
// Rules 2 and 3 have one escape hatch, `website/quote-waivers.txt`, and it is
// deliberately noisy: each waiver carries a written reason, an unused waiver
// is an error, and a duplicated waiver is an error rather than a last-write-
// wins. A hand-maintained list that can rot silently is the thing this file
// exists to prevent.
//
// What it cannot catch is in website/README.md, under "What the drift check
// does not catch". Read that before trusting a green run to mean more than it
// does.
//
// **What counts as "the app's own source", and why it is not only `lib/`.**
// By default the roots are `lib/` **and every `packages/*/lib/`** — derived at
// run time, not listed, so a package added tomorrow is covered without anybody
// remembering. `/w-03` found the hole the hard way: the role names a member
// reads (owner, contributor, viewer) and the five record-type buttons on the
// record screen are `enum` labels in `packages/tritrack_sync/lib/src/
// enums.dart`, so the guide's most-read table had to be written as unmarked
// prose — exactly the rot this file exists to prevent.
//
// `server/` is still out, and deliberately: this project's standing invariant
// is that no server prose is ever shown to a user — the server sends a refusal
// code and the app writes the sentence. A quoted string that could only be
// found in `server/` would be a defect in the app, not a gap in this check.
//
// Usage:
//   dart run website/tools/check_app_quotes.dart
//   dart run website/tools/check_app_quotes.dart --app-root=X --content-root=Y --waivers=Z
//
// `--app-root` may be given more than once, and giving it at all replaces the
// default roots rather than adding to them.
//
// Exit 0 = no drift. Exit 1 = drift or a rule violation. Exit 2 = the check
// could not run (missing directory, unreadable waiver file) — which is not the
// same as "passed", and CI must treat it as failure too.

import 'dart:io';

const _ok = 0;
const _violations = 1;
const _cannotRun = 2;

void main(List<String> args) {
  final givenRoots = <String>[];
  var contentRoot = 'website/content';
  var waiversPath = 'website/quote-waivers.txt';

  for (final a in args) {
    if (a.startsWith('--app-root=')) {
      givenRoots.add(a.substring('--app-root='.length));
    } else if (a.startsWith('--content-root=')) {
      contentRoot = a.substring('--content-root='.length);
    } else if (a.startsWith('--waivers=')) {
      waiversPath = a.substring('--waivers='.length);
    } else {
      stderr.writeln('check_app_quotes: unknown argument "$a"');
      exit(_cannotRun);
    }
  }

  final appRoots = givenRoots.isNotEmpty ? givenRoots : defaultAppRoots();
  final roots = appRoots.join(', ');

  for (final root in appRoots) {
    if (!Directory(root).existsSync()) {
      stderr.writeln('check_app_quotes: no such directory: $root');
      exit(_cannotRun);
    }
  }
  final contentDir = Directory(contentRoot);
  if (!contentDir.existsSync()) {
    stderr.writeln('check_app_quotes: no such directory: $contentRoot');
    exit(_cannotRun);
  }

  final Waivers waivers;
  try {
    waivers = Waivers.load(waiversPath);
  } on FormatException catch (e) {
    stderr.writeln('check_app_quotes: $waiversPath: ${e.message}');
    exit(_cannotRun);
  }

  // Per root, not across all of them. A root that contributes nothing is a
  // root this check is blind in, and a blind root inside a green run is
  // exactly the shape of "a check that cannot tell success from its own
  // failure" — the reason the total was never the question.
  final dartFiles = <File>[];
  for (final root in appRoots) {
    final found = Directory(root)
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'))
        .toList();
    if (found.isEmpty) {
      stderr.writeln('check_app_quotes: $root contains no .dart files — '
          'refusing to report success against nothing');
      exit(_cannotRun);
    }
    dartFiles.addAll(found);
  }
  dartFiles.sort((a, b) => a.path.compareTo(b.path));

  // Every run of literal text the app can actually display, normalised.
  final appStrings = <String>{};
  // The subset that is a database column value rather than anything a person
  // reads. Rule 4 refuses a quote of one — see [dartEnumStorageValues].
  final storageValues = <String>{};
  for (final f in dartFiles) {
    final src = f.readAsStringSync();
    appStrings.addAll(dartStringSegments(src));
    storageValues.addAll(dartEnumStorageValues(src));
  }
  if (storageValues.isEmpty) {
    stderr.writeln('check_app_quotes: found no enum storage values in $roots, '
        'so rule 4 could not refuse anything — which means it is not running '
        'rather than that nothing violates it.');
    exit(_cannotRun);
  }

  final mdFiles = contentDir
      .listSync(recursive: true)
      .whereType<File>()
      .where((f) => f.path.endsWith('.md'))
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));

  final problems = <String>[];
  var quotedCount = 0;

  for (final f in mdFiles) {
    final raw = f.readAsStringSync();
    final scan = ProseScan(raw);

    for (final q in scan.appQuotes) {
      quotedCount++;
      final quoted = normalise(q.text);
      // Rule 4 first, and instead of rule 1 rather than alongside it: a
      // storage value always satisfies rule 1, which is the whole complaint.
      if (storageValues.contains(quoted)) {
        problems.add('${f.path}:${q.line}: "${q.text}" is a value the database '
            'stores, not something a screen says.\n'
            '    It is an enum\'s db value, pinned by the schema, so this '
            'quote passes however the screens change — it cannot go red, and '
            'a quote that cannot go red is not evidence of anything.\n'
            '    Quote the words the screen writes instead. (If a screen '
            'really does print this string, that is the defect '
            'test/documentation/role_vocabulary_test.dart exists to fail on, '
            'and it is the app that has to change.)');
        continue;
      }
      if (!saysIt(appStrings, quoted)) {
        problems.add('${f.path}:${q.line}: the app no longer says '
            '"${q.text}" — no string in $roots contains it.\n'
            '    Either the app\'s wording changed and this page must follow, '
            'or the quote was never exact.');
      }
    }

    for (final v in scan.rawQuotes) {
      if (waivers.use(v.text)) continue;
      problems.add('${f.path}:${v.line}: quotation marks around "${v.text}".\n'
          '    Quote the app with {{< app "${v.text}" >}} so the quote is '
          'checked, or add it to $waiversPath with a reason.');
    }

    for (final v in scan.boldSpans) {
      if (waivers.use(v.text)) continue;
      problems.add('${f.path}:${v.line}: bold around "${v.text}".\n'
          '    A UI label goes in {{< app "${v.text}" >}} — which renders bold '
          'and is checked. For emphasis use _italics_. Otherwise add it to '
          '$waiversPath with a reason.');
    }
  }

  for (final unused in waivers.unused) {
    problems.add('$waiversPath: the waiver "$unused" matched nothing.\n'
        '    Remove it. A waiver list that keeps entries nothing needs is a '
        'list nobody reads.');
  }

  if (problems.isNotEmpty) {
    for (final p in problems) {
      stdout.writeln('  ✗ $p');
    }
    // The last line is the finding, not the name of the check: CI keeps only
    // the tail, and a name in the tail has never told anybody anything.
    stdout.writeln('check_app_quotes: FAIL — ${problems.length} problem(s) '
        'across ${mdFiles.length} page(s); $quotedCount quoted string(s) '
        'checked against ${appStrings.length} strings in $roots.');
    exit(_violations);
  }

  stdout.writeln('check_app_quotes: PASS — $quotedCount quoted string(s) on '
      '${mdFiles.length} page(s) all still exist among ${appStrings.length} '
      'strings in $roots, and none of them is one of the '
      '${storageValues.length} database value(s) a quote could never go red '
      'on; ${waivers.count} waiver(s), all used.');
  exit(_ok);
}

/// Where the app's user-visible strings live, worked out rather than listed.
///
/// `lib/`, plus the `lib/` of every package under `packages/`. **Derived, so
/// that a package added next month is covered by whoever adds it and not by
/// whoever remembers this file exists** — a hand-maintained list of roots
/// would be the same defect one level up from the one this check catches.
///
/// A `packages/` directory holding no package with a `lib/` is refused rather
/// than skipped. This check would then be searching one root while its own
/// documentation says two, and a check that quietly covers less than it claims
/// is worse than one that covers less and says so.
List<String> defaultAppRoots() {
  final roots = <String>['lib'];
  final packages = Directory('packages');
  if (!packages.existsSync()) return roots;

  final found = packages
      .listSync()
      .whereType<Directory>()
      .map((d) => '${d.path}/lib')
      .where((path) => Directory(path).existsSync())
      .toList()
    ..sort();
  if (found.isEmpty) {
    stderr.writeln('check_app_quotes: packages/ exists but no package inside '
        'it has a lib/ directory, so this check would be searching only lib/ '
        'while claiming to search both. Name the roots with --app-root if '
        'that is really what you want.');
    exit(_cannotRun);
  }
  return roots..addAll(found);
}

/// Does any string the app can display still contain this text?
///
/// Containment rather than equality, deliberately: the guide often quotes one
/// sentence of a two-sentence message, or the fixed half of a message with a
/// name interpolated into it. "The app still says this" is exactly the
/// question of whether the text survives inside something displayed.
bool saysIt(Set<String> appStrings, String quoted) {
  if (appStrings.contains(quoted)) return true;
  for (final s in appStrings) {
    if (s.contains(quoted)) return true;
  }
  return false;
}

/// A span found in a page, with the line it sits on.
class Span {
  Span(this.text, this.line);
  final String text;
  final int line;
}

/// Whitespace-collapsed, typographic punctuation folded to ASCII.
///
/// The app wraps long sentences across source lines and uses whichever
/// apostrophe the keyboard produced; the website uses whichever the writer
/// typed. Neither difference is drift, so neither should be reported as
/// drift. Every other difference is.
String normalise(String s) {
  return s
      .replaceAll('‘', "'")
      .replaceAll('’', "'")
      .replaceAll('“', '"')
      .replaceAll('”', '"')
      .replaceAll('–', '-')
      .replaceAll('—', '-')
      .replaceAll(' ', ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
}

// --------------------------------------------------------------------------
// The website side: what a page actually asserts about the app.
// --------------------------------------------------------------------------

class ProseScan {
  ProseScan(String raw) {
    final body = _stripFrontMatter(raw);
    _scan(body);
  }

  /// Strings the page claims the app says.
  final List<Span> appQuotes = [];

  /// Quotation marks in prose that are not going through the shortcode.
  final List<Span> rawQuotes = [];

  /// Bold spans in prose.
  final List<Span> boldSpans = [];

  static final _appShortcode =
      RegExp(r'\{\{<\s*app\s+"((?:[^"\\]|\\.)*)"\s*>\}\}');
  static final _anyShortcode = RegExp(r'\{\{[<%].*?[>%]\}\}', dotAll: true);
  static final _fence = RegExp(r'^ {0,3}(`{3,}|~{3,}).*$', multiLine: true);
  static final _quoted = RegExp(r'"([^"\n]*)"|“([^”\n]*)”');
  static final _bold = RegExp(r'\*\*([^*\n]+)\*\*|__([^_\n]+)__');

  void _scan(String body) {
    // Shortcodes first: they are the marked quotes, and their own syntax
    // contains the quotation marks rule 2 forbids everywhere else.
    for (final m in _appShortcode.allMatches(body)) {
      appQuotes.add(Span(_unescape(m.group(1)!), _lineOf(body, m.start)));
    }

    // Blank out, in order: fenced code, inline code, shortcodes, link
    // destinations, HTML comments. What survives is prose the reader sees.
    var prose = _blankFences(body);
    prose = _blankAll(prose, _anyShortcode);
    prose = _blankAll(prose, RegExp(r'`[^`\n]*`'));
    prose = _blankAll(prose, RegExp(r'<!--.*?-->', dotAll: true));
    prose = _blankAll(prose, RegExp(r'\]\([^)\n]*\)'));

    for (final m in _quoted.allMatches(prose)) {
      final inner = (m.group(1) ?? m.group(2) ?? '').trim();
      if (inner.isEmpty) continue;
      rawQuotes.add(Span(inner, _lineOf(prose, m.start)));
    }
    for (final m in _bold.allMatches(prose)) {
      final inner = (m.group(1) ?? m.group(2) ?? '').trim();
      if (inner.isEmpty) continue;
      boldSpans.add(Span(inner, _lineOf(prose, m.start)));
    }
  }

  /// Replace a match with spaces so every later offset still lands on the
  /// line it came from.
  static String _blankAll(String s, RegExp re) =>
      s.replaceAllMapped(re, (m) => m.group(0)!.replaceAll(RegExp(r'[^\n]'), ' '));

  static String _blankFences(String s) {
    final lines = s.split('\n');
    var inFence = false;
    for (var i = 0; i < lines.length; i++) {
      final isFenceLine = _fence.hasMatch(lines[i]);
      if (isFenceLine) {
        inFence = !inFence;
        lines[i] = '';
        continue;
      }
      if (inFence) lines[i] = '';
    }
    return lines.join('\n');
  }

  static String _stripFrontMatter(String raw) {
    for (final d in ['---', '+++']) {
      if (!raw.startsWith('$d\n')) continue;
      final end = raw.indexOf('\n$d', d.length);
      if (end < 0) break;
      final head = raw.substring(0, end + 1 + d.length);
      final blanked = head.replaceAll(RegExp(r'[^\n]'), '');
      return blanked + raw.substring(end + 1 + d.length);
    }
    return raw;
  }

  static String _unescape(String s) =>
      s.replaceAll(r'\"', '"').replaceAll(r'\\', r'\');

  static int _lineOf(String s, int offset) =>
      '\n'.allMatches(s.substring(0, offset)).length + 1;
}

// --------------------------------------------------------------------------
// The waiver list.
// --------------------------------------------------------------------------

class Waivers {
  Waivers._(this._reasons);

  final Map<String, String> _reasons;
  final Set<String> _used = {};

  int get count => _reasons.length;
  Iterable<String> get unused =>
      _reasons.keys.where((k) => !_used.contains(k));

  bool use(String text) {
    final key = normalise(text);
    if (!_reasons.containsKey(key)) return false;
    _used.add(key);
    return true;
  }

  static Waivers load(String path) {
    final f = File(path);
    if (!f.existsSync()) return Waivers._({});
    final reasons = <String, String>{};
    final lines = f.readAsLinesSync();
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      if (line.trim().isEmpty || line.trimLeft().startsWith('#')) continue;
      final tab = line.indexOf('\t');
      if (tab < 0) {
        throw FormatException('line ${i + 1}: expected "text<TAB>reason", '
            'found no tab. A waiver without a written reason is a waiver '
            'nobody can review.');
      }
      final key = normalise(line.substring(0, tab));
      final reason = line.substring(tab + 1).trim();
      if (key.isEmpty) {
        throw FormatException('line ${i + 1}: empty waiver text.');
      }
      if (reason.isEmpty) {
        throw FormatException('line ${i + 1}: waiver "$key" has no reason.');
      }
      // Keyed by a string somebody typed, so a duplicate is a hard error and
      // never a last-write-wins.
      if (reasons.containsKey(key)) {
        throw FormatException('line ${i + 1}: "$key" is waived twice. Two '
            'reasons for one waiver means one of them is not being applied.');
      }
      reasons[key] = reason;
    }
    return Waivers._(reasons);
  }
}

// --------------------------------------------------------------------------
// The app side: every run of literal text `lib/` can display.
// --------------------------------------------------------------------------

/// Walks Dart source and returns the normalised text of every string literal
/// segment, plus the concatenation of adjacent literals.
///
/// It is a scanner rather than a regex because comments contain quotes,
/// strings contain comment markers, and a false match in either direction is
/// the difference between a check and a decoration. Interpolations split a
/// literal into segments: `'Removed from $name'` yields `Removed from`, so a
/// page may quote either side of an interpolation but never a whole sentence
/// that only exists once a variable is filled in.
Set<String> dartStringSegments(String src) {
  final out = <String>{};
  final literals = _lex(src).literals;

  for (final lit in literals) {
    for (final s in lit.segments) {
      final t = normalise(s);
      if (t.isNotEmpty) out.add(t);
    }
  }

  // Dart concatenates adjacent literals. A long sentence written as three
  // wrapped literals is one sentence to the reader, so it must be one string
  // to this check.
  for (var a = 0; a + 1 < literals.length; a++) {
    final buf = StringBuffer(literals[a].segments.join(' '));
    var b = a + 1;
    // Bounded: a run of adjacent literals is a wrapped sentence, not a
    // hundred-element list, and an unbounded join is quadratic on a file that
    // happens to contain one.
    while (b < literals.length && b - a <= 8 &&
        src.substring(literals[b - 1].end, literals[b].start).trim().isEmpty) {
      buf.write(' ');
      buf.write(literals[b].segments.join(' '));
      final t = normalise(buf.toString());
      if (t.isNotEmpty) out.add(t);
      b++;
    }
  }

  return out;
}

/// One string literal, and where it sat.
typedef _Literal = ({int start, int end, List<String> segments});

/// The literals in a Dart file, and a same-length copy of the source with
/// every comment and every literal blanked out.
///
/// **Two consumers, one lexer.** [dartStringSegments] wants the literals;
/// [dartEnumStorageValues] wants the shape of the code *around* them —
/// braces, parentheses and commas — and a brace inside a comment or a string
/// would ruin that. Blanking to spaces rather than deleting keeps every offset
/// where it was, so a position in the skeleton is a position in the source.
typedef _Lexed = ({List<_Literal> literals, String skeleton});

_Lexed _lex(String src) {
  final literals = <_Literal>[];
  final skeleton = List<String>.filled(src.length, '');
  for (var k = 0; k < src.length; k++) {
    skeleton[k] = src[k];
  }
  void blank(int from, int to) {
    for (var k = from; k < to && k < src.length; k++) {
      if (src[k] != '\n') skeleton[k] = ' ';
    }
  }

  var i = 0;
  final n = src.length;

  while (i < n) {
    final c = src[i];

    if (c == '/' && i + 1 < n && src[i + 1] == '/') {
      final from = i;
      while (i < n && src[i] != '\n') {
        i++;
      }
      blank(from, i);
      continue;
    }
    if (c == '/' && i + 1 < n && src[i + 1] == '*') {
      final from = i;
      var depth = 1;
      i += 2;
      while (i < n && depth > 0) {
        if (src[i] == '/' && i + 1 < n && src[i + 1] == '*') {
          depth++;
          i += 2;
        } else if (src[i] == '*' && i + 1 < n && src[i + 1] == '/') {
          depth--;
          i += 2;
        } else {
          i++;
        }
      }
      blank(from, i);
      continue;
    }

    var raw = false;
    var q = i;
    if (c == 'r' && i + 1 < n && (src[i + 1] == "'" || src[i + 1] == '"')) {
      raw = true;
      q = i + 1;
    } else if (c != "'" && c != '"') {
      i++;
      continue;
    }

    final quote = src[q];
    final triple = q + 2 < n && src[q + 1] == quote && src[q + 2] == quote;
    final delim = triple ? quote * 3 : quote;
    final start = i;
    var p = q + delim.length;

    final segments = <String>[];
    final buf = StringBuffer();

    while (p < n) {
      if (!raw && src[p] == r'\' && p + 1 < n) {
        buf.write(_dartEscape(src[p + 1]));
        p += 2;
        continue;
      }
      if (src.startsWith(delim, p)) {
        p += delim.length;
        break;
      }
      if (!raw && src[p] == r'$') {
        // An interpolation ends this segment and begins another.
        segments.add(buf.toString());
        buf.clear();
        p++;
        if (p < n && src[p] == '{') {
          var depth = 1;
          p++;
          while (p < n && depth > 0) {
            if (src[p] == '{') depth++;
            if (src[p] == '}') depth--;
            p++;
          }
        } else {
          while (p < n && RegExp(r'[A-Za-z0-9_.]').hasMatch(src[p])) {
            p++;
          }
        }
        continue;
      }
      if (!triple && src[p] == '\n') break; // unterminated; give up on it
      buf.write(src[p]);
      p++;
    }
    segments.add(buf.toString());

    literals.add((start: start, end: p, segments: segments));
    blank(start, p);
    i = p;
  }

  return (literals: literals, skeleton: skeleton.join());
}

// --------------------------------------------------------------------------
// Rule 4: the strings that are storage, not speech.
// --------------------------------------------------------------------------

/// Every string a Dart `enum` in [src] stores in a database column.
///
/// **Why this is a rule and not a note in the README** (`/w-08`). Task 11.99
/// rewrote the projects list and the members screen — a cloud icon became a
/// labelled row, five bare icons became a menu of written labels, and an
/// owner-only screen opened to everybody — and **every quoted string on the
/// two guide pages describing those screens stayed green through all of it.**
/// Three of them were `{{< app "owner" >}}`, `{{< app "contributor" >}}` and
/// `{{< app "viewer" >}}`: not screen wording at all, but the exact strings
/// `ProjectRole` puts in a SQLite column. The schema pins them, so no change
/// to any screen could ever have turned those quotes red. **A quote that
/// cannot go red is not evidence, and a check that cannot fail is not a
/// check** — so quoting one is refused outright rather than accepted.
///
/// **Which argument is the storage one is read, not assumed.** The convention
/// in `packages/tritrack_sync/lib/src/enums.dart` is a generative constructor
/// `const RecordType(this.db, this.label)` — `db` first — but that is a
/// convention, and a rule resting on it would quietly stop working the day
/// somebody wrote `const Foo(this.label, this.db)`. So the constructor's
/// parameter list is parsed, `db`'s position in it is found, and that position
/// is taken from each member's arguments. An enum with no `db` parameter
/// contributes nothing, which is right: it stores nothing.
///
/// **The labels beside them are deliberately untouched.**
/// `GroundTruthKind.animalOnly` is `('animal_only', 'Animal only')`, and the
/// second of those is exactly what the record screen shows a person. Refusing
/// every string that happens to sit inside an `enum` would have made the
/// truth-point page unwriteable — and `/w-06` widened this check's roots to
/// reach those labels in the first place.
Set<String> dartEnumStorageValues(String src) {
  final out = <String>{};
  final lexed = _lex(src);
  final sk = lexed.skeleton;

  // Literals by start offset, so a position in the skeleton can be turned
  // back into the text that was there.
  final byStart = <int, _Literal>{
    for (final lit in lexed.literals) lit.start: lit,
  };

  for (final m in RegExp(r'\benum\s+(\w+)[^{;]*\{').allMatches(sk)) {
    final name = m.group(1)!;
    final bodyStart = m.end;
    final bodyEnd = _matchingBrace(sk, m.end - 1);
    if (bodyEnd < 0) continue;

    // Where `db` sits in the constructor's parameter list. No `db`, nothing
    // stored, nothing to refuse.
    final ctor = RegExp('const\\s+$name\\s*\\(([^)]*)\\)')
        .firstMatch(sk.substring(bodyStart, bodyEnd));
    if (ctor == null) continue;
    final params = ctor
        .group(1)!
        .split(',')
        .map((p) => p.trim())
        .where((p) => p.isNotEmpty)
        .toList();
    final dbIndex = params.indexWhere((p) => p == 'this.db');
    if (dbIndex < 0) continue;

    // The member list runs from the opening brace to the `;` that ends it.
    var listEnd = bodyEnd;
    for (var k = bodyStart; k < bodyEnd; k++) {
      final ch = sk[k];
      if (ch == '(' || ch == '{' || ch == '[') {
        final close = _matchingBrace(sk, k);
        if (close < 0) break;
        k = close;
        continue;
      }
      if (ch == ';') {
        listEnd = k;
        break;
      }
    }

    for (final member
        in RegExp(r'(\w+)\s*\(').allMatches(sk.substring(bodyStart, listEnd))) {
      final open = bodyStart + member.end - 1;
      final close = _matchingBrace(sk, open);
      if (close < 0) continue;
      final args = _splitArgs(sk, open + 1, close);
      if (dbIndex >= args.length) continue;
      final (argFrom, argTo) = args[dbIndex];
      for (var k = argFrom; k < argTo; k++) {
        final lit = byStart[k];
        if (lit == null) continue;
        final t = normalise(lit.segments.join(' '));
        if (t.isNotEmpty) out.add(t);
        break;
      }
    }
  }

  return out;
}

/// The offset of the bracket closing the one at [open], or -1.
int _matchingBrace(String sk, int open) {
  const pairs = {'{': '}', '(': ')', '[': ']'};
  final want = pairs[sk[open]];
  if (want == null) return -1;
  var depth = 0;
  for (var k = open; k < sk.length; k++) {
    final ch = sk[k];
    if (pairs.containsKey(ch)) depth++;
    if (ch == '}' || ch == ')' || ch == ']') {
      depth--;
      if (depth == 0) return ch == want ? k : -1;
    }
  }
  return -1;
}

/// The half-open ranges of the top-level arguments between [from] and [to].
List<(int, int)> _splitArgs(String sk, int from, int to) {
  final out = <(int, int)>[];
  var start = from;
  for (var k = from; k < to; k++) {
    final ch = sk[k];
    if (ch == '(' || ch == '{' || ch == '[') {
      final close = _matchingBrace(sk, k);
      if (close < 0 || close >= to) break;
      k = close;
      continue;
    }
    if (ch == ',') {
      out.add((start, k));
      start = k + 1;
    }
  }
  if (start < to) out.add((start, to));
  return out;
}

String _dartEscape(String c) {
  switch (c) {
    case 'n':
    case 't':
    case 'r':
      return ' ';
    default:
      return c;
  }
}
