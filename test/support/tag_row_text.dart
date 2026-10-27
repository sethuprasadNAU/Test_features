import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The single line each tag row shows, reassembled from the pieces the row is
/// actually built from.
///
/// **Michael, 2026-09-06:** the tag list row is now one line and nothing else,
/// so the font could go up. The line is a single `Text` capped at one line, so
/// this is one piece today — but the row has already been through one shape
/// where it was three, and a test that reaches into a row's internals goes red
/// for a reason that reads as "the list is empty" rather than "the row is
/// assembled differently now".
///
/// So this asks the row what it says rather than which widget says it. Every
/// `Text` under a tile is joined in order, which reproduces exactly what a
/// reader sees under either shape.
List<String> tagRowLines(WidgetTester tester) {
  final lines = <String>[];
  for (final tile in find.byType(ListTile).evaluate()) {
    final pieces = <String>[];
    void visit(Element element) {
      final widget = element.widget;
      if (widget is Text && widget.data != null) pieces.add(widget.data!);
      element.visitChildren(visit);
    }

    tile.visitChildren(visit);
    final line = pieces.join();
    if (line.contains('MHz')) lines.add(line);
  }
  return lines;
}

/// The tag row whose line contains [fragment] — for tapping one, where a bare
/// `find.text` would match the name piece rather than the whole row.
Finder tagRowContaining(String fragment) => find.ancestor(
      of: find.textContaining(fragment),
      matching: find.byType(ListTile),
    );
