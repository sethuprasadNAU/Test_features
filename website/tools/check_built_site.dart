// Two checks on the BUILT site (`/w-35` item 3), the HTML Hugo writes rather
// than the Markdown it reads:
//
//   1. **Every internal link resolves.** A link from one page of this site to
//      another, or to a picture, a video or a heading on a page, must point at
//      something the build produced. Five were broken for two days before
//      anybody noticed, because nothing looked: Hugo checks a shortcode's file
//      but never an ordinary Markdown link.
//   2. **No raw TeX outside a formula.** A formula written so that Hugo's
//      passthrough did not pick it up (a missing `$`, a delimiter inside
//      emphasis) is printed to the reader as `\hat{x}` and nobody is told.
//      Michael caught one by reading.
//
// Run, from the repository root, after a build:
//
//   hugo --source website --destination <dir>
//   dart website/tools/check_built_site.dart <dir>
//
// Exit codes, the same contract as check_app_quotes.dart: 0 nothing wrong,
// 1 something wrong (every finding is printed, then a one-line verdict),
// 2 the check could not run, which is not a pass. **It cannot pass having
// looked at nothing**: no HTML pages, or pages with no internal link at all,
// is exit 2, because a link checker pointed at the wrong directory would
// otherwise report "0 broken" and be believed.
//
// `website/tools/selftest.sh` watches both checks go red on deliberately
// broken copies (`fixtures/built_site_*`) every time it runs.
import 'dart:io';

void main(List<String> args) {
  String? siteArg;
  String? basePathArg;
  for (final a in args) {
    if (a.startsWith('--base-path=')) {
      basePathArg = a.substring('--base-path='.length);
    } else if (a.startsWith('-')) {
      _cannotRun('unknown option $a');
    } else {
      siteArg = a;
    }
  }
  if (siteArg == null) {
    _cannotRun('give the directory Hugo built into, e.g. '
        'dart website/tools/check_built_site.dart public');
  }
  final site = Directory(siteArg);
  if (!site.existsSync()) _cannotRun('no directory at $siteArg');
  final root = site.absolute.path.replaceAll(RegExp(r'/+$'), '');
  final basePath = _normalizeBase(basePathArg ?? _basePathFromHugoToml());

  final pages = site
      .listSync(recursive: true)
      .whereType<File>()
      .where((f) => f.path.endsWith('.html'))
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));
  if (pages.isEmpty) _cannotRun('no .html files under $siteArg');

  final idsCache = <String, Set<String>>{};
  Set<String> idsOf(String file) => idsCache.putIfAbsent(file, () {
        final html = File(file).readAsStringSync();
        return {
          for (final m in _idAttr.allMatches(html)) _decode(_attrValue(m)),
        };
      });

  final broken = <String>[];
  final tex = <String>[];
  var internal = 0;
  var fragments = 0;

  for (final page in pages) {
    final rel = page.absolute.path.substring(root.length + 1);
    final html = page.readAsStringSync();
    // The page's own URL directory: docs/sync/index.html is served at
    // <base>docs/sync/, so a relative link resolves against that.
    final dir = rel.endsWith('index.html')
        ? rel.substring(0, rel.length - 'index.html'.length)
        : rel.substring(0, rel.lastIndexOf('/') + 1);
    final pageUri = Uri.parse('https://site.invalid$basePath$dir');

    for (final m in _linkAttr.allMatches(html)) {
      final raw = _htmlUnescape(_attrValue(m).trim());
      if (raw.isEmpty || _external.hasMatch(raw)) continue;
      internal++;
      final hash = raw.indexOf('#');
      final pathPart = hash < 0 ? raw : raw.substring(0, hash);
      final fragment = hash < 0 ? null : raw.substring(hash + 1);

      String targetFile;
      if (pathPart.isEmpty || pathPart.startsWith('?')) {
        targetFile = page.absolute.path;
      } else {
        final Uri resolved;
        try {
          resolved = pageUri.resolve(pathPart);
        } on FormatException {
          broken.add('$rel: "$raw" is not a URL');
          continue;
        }
        final path = Uri.decodeComponent(resolved.path);
        if (!path.startsWith(basePath)) {
          broken.add('$rel: "$raw" leaves the site (it resolves to $path, '
              'outside $basePath)');
          continue;
        }
        final inSite = path.substring(basePath.length);
        final candidates = [
          if (inSite.isEmpty || inSite.endsWith('/'))
            '$root/${inSite}index.html'
          else ...[
            '$root/$inSite',
            '$root/$inSite/index.html',
          ],
        ];
        final hit = candidates.where((c) => File(c).existsSync());
        if (hit.isEmpty) {
          broken.add('$rel: "$raw" points at nothing the build produced '
              '(looked for ${candidates.map((c) => c.substring(root.length + 1)).join(' and ')})');
          continue;
        }
        targetFile = hit.first;
      }
      if (fragment != null && fragment.isNotEmpty) {
        if (!targetFile.endsWith('.html')) continue;
        fragments++;
        final want = _decode(fragment);
        if (!idsOf(targetFile).contains(want)) {
          broken.add('$rel: "$raw" names a heading or anchor "#$want" that '
              '${targetFile.substring(root.length + 1)} does not have');
        }
      }
    }

    // Raw TeX: the reader's text, with every formula and every place TeX or
    // code may legitimately appear removed first.
    var text = html;
    for (final strip in _notProse) {
      text = text.replaceAll(strip, ' ');
    }
    text = _htmlUnescape(text.replaceAll(_tag, ' '));
    for (final m in _rawTex.allMatches(text)) {
      final from = (m.start - 30).clamp(0, text.length);
      final to = (m.end + 30).clamp(0, text.length);
      final context = text.substring(from, to).replaceAll(RegExp(r'\s+'), ' ');
      tex.add('$rel: raw TeX "${m.group(0)}" outside a formula, in '
          '"…${context.trim()}…"');
    }
  }

  if (internal == 0) {
    _cannotRun('${pages.length} page(s) and not one internal link among them '
        '— this is not a built TriTrack site, or the link pattern no longer '
        'matches what Hugo writes');
  }

  for (final b in broken) {
    stdout.writeln('  ✗ broken link — $b');
  }
  for (final t in tex) {
    stdout.writeln('  ✗ $t');
  }
  final summary = '${pages.length} page(s), $internal internal link(s) of '
      'which $fragments name a heading, base path $basePath';
  if (broken.isEmpty && tex.isEmpty) {
    stdout.writeln('check_built_site: PASS — every internal link resolves and '
        'no raw TeX appears outside a formula ($summary).');
    exit(0);
  }
  stdout.writeln('check_built_site: FAIL — ${broken.length} broken link(s) and '
      '${tex.length} piece(s) of raw TeX ($summary).');
  exit(1);
}

/// href, src and poster, quoted or (as `hugo --minify` writes them) not.
final _linkAttr = RegExp(
    r'''\b(?:href|src|poster)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>"']+))''');
final _idAttr =
    RegExp(r'''\b(?:id|name)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>"']+))''');
String _attrValue(RegExpMatch m) => m.group(1) ?? m.group(2) ?? m.group(3)!;

/// Anything with a scheme (https:, mailto:, data:, …) or protocol-relative.
final _external = RegExp(r'^(?:[a-zA-Z][a-zA-Z0-9+.-]*:|//)');

/// Where TeX, or text that looks like it, belongs: rendered formulas (MathML),
/// code, inline SVG figures, scripts, styles and comments.
final _notProse = [
  RegExp(r'<!--.*?-->', dotAll: true),
  RegExp(r'<math\b.*?</math>', dotAll: true),
  RegExp(r'<script\b.*?</script>', dotAll: true),
  RegExp(r'<style\b.*?</style>', dotAll: true),
  RegExp(r'<pre\b.*?</pre>', dotAll: true),
  RegExp(r'<code\b.*?</code>', dotAll: true),
  RegExp(r'<svg\b.*?</svg>', dotAll: true),
];
final _tag = RegExp(r'<[^>]*>');

/// A TeX command (`\hat`, `\frac`), a display or inline-math delimiter that
/// survived (`$$`, `\(`, `\[`), or a braced super- or subscript (`^{`, `_{`).
final _rawTex = RegExp(r'\\[A-Za-z]+|\$\$|\\[(\[]|[\^_]\{');

String _htmlUnescape(String s) => s
    .replaceAll('&amp;', '&')
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&quot;', '"')
    .replaceAll('&#39;', "'")
    .replaceAll('&#34;', '"');

String _decode(String s) {
  try {
    return Uri.decodeComponent(_htmlUnescape(s));
  } on ArgumentError {
    return s;
  } on FormatException {
    return s;
  }
}

String _normalizeBase(String p) {
  var b = p.trim();
  if (!b.startsWith('/')) b = '/$b';
  if (!b.endsWith('/')) b = '$b/';
  return b;
}

/// The path part of `baseURL` in website/hugo.toml, which is the prefix every
/// root-relative link on the published site carries (`/tritrack-site/`).
String _basePathFromHugoToml() {
  final toml = File('website/hugo.toml');
  if (!toml.existsSync()) return '/';
  final m = RegExp(r'''^\s*baseURL\s*=\s*['"]([^'"]+)['"]''', multiLine: true)
      .firstMatch(toml.readAsStringSync());
  if (m == null) return '/';
  return Uri.parse(m.group(1)!).path;
}

Never _cannotRun(String why) {
  stderr.writeln('check_built_site: COULD NOT RUN — $why. '
      'Exit 2 is not a pass.');
  exit(2);
}
