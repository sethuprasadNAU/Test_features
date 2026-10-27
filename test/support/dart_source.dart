/// Small source-reading helpers shared by the guards that derive their subject
/// from the code rather than from a hand-written list.
///
/// These are deliberately textual rather than analyzer-based. A guard that
/// needs `package:analyzer` and a resolved element model is a guard nobody
/// runs; these read the same files a person would read. Where the text can
/// mislead — a table name inside a doc comment, an `insert` in prose — the
/// answer is [stripComments], not a heavier tool.
library;

import 'dart:io';

/// Every `.dart` file under [root], excluding generated output.
List<File> dartFilesUnder(String root) => Directory(root)
    .listSync(recursive: true)
    .whereType<File>()
    .where((f) => f.path.endsWith('.dart'))
    .where((f) => !f.path.endsWith('.g.dart'))
    .where((f) => !f.path.endsWith('.freezed.dart'))
    .toList()
  ..sort((a, b) => a.path.compareTo(b.path));

/// [source] with comments blanked out, string literals left intact.
///
/// Doc comments in this codebase are long and quote code freely — table names,
/// method names, whole call sites — so a guard that greps raw source finds its
/// own subject described in prose and concludes the code does something it
/// does not. Comment text is replaced by spaces rather than removed so that
/// character offsets, and therefore line numbers, stay true.
String stripComments(String source) {
  final out = StringBuffer();
  var i = 0;
  while (i < source.length) {
    final c = source[i];
    final next = i + 1 < source.length ? source[i + 1] : '';
    if (c == '/' && next == '/') {
      while (i < source.length && source[i] != '\n') {
        out.write(' ');
        i++;
      }
      continue;
    }
    if (c == '/' && next == '*') {
      while (i < source.length &&
          !(source[i] == '*' && i + 1 < source.length && source[i + 1] == '/')) {
        out.write(source[i] == '\n' ? '\n' : ' ');
        i++;
      }
      if (i < source.length) {
        out.write('  ');
        i += 2;
      }
      continue;
    }
    if (c == "'" || c == '"') {
      final triple = source.startsWith(c * 3, i);
      final delimiter = triple ? c * 3 : c;
      out.write(delimiter);
      i += delimiter.length;
      while (i < source.length && !source.startsWith(delimiter, i)) {
        if (source[i] == r'\' && i + 1 < source.length) {
          out.write(source.substring(i, i + 2));
          i += 2;
          continue;
        }
        out.write(source[i]);
        i++;
      }
      if (i < source.length) {
        out.write(delimiter);
        i += delimiter.length;
      }
      continue;
    }
    out.write(c);
    i++;
  }
  return out.toString();
}

/// The top-level declaration containing [needle], as text.
///
/// Walks back to the nearest line that starts in column 0 and is not a closing
/// brace, and forward to the first column-0 line that closes it. Good enough
/// for the provider declarations this is used on, and it fails loudly (returns
/// null) rather than guessing when the shape is not what it expects.
String? enclosingTopLevelDeclaration(String source, String needle) {
  final at = source.indexOf(needle);
  if (at == -1) return null;
  final lines = source.split('\n');
  var offset = 0;
  var lineOfNeedle = -1;
  for (var i = 0; i < lines.length; i++) {
    offset += lines[i].length + 1;
    if (offset > at) {
      lineOfNeedle = i;
      break;
    }
  }
  if (lineOfNeedle == -1) return null;
  var start = lineOfNeedle;
  while (start > 0) {
    final line = lines[start];
    final startsInColumnZero =
        line.isNotEmpty && line[0] != ' ' && line[0] != '\t';
    if (startsInColumnZero && !line.startsWith('}') && !line.startsWith(')')) {
      break;
    }
    start--;
  }
  var end = lineOfNeedle;
  while (end < lines.length - 1) {
    end++;
    final line = lines[end];
    if (line.startsWith('}') || line.startsWith(')')) break;
  }
  return lines.sublist(start, end + 1).join('\n');
}
