/// Driving the projects list's per-row action menu (task 11.99).
///
/// Every action on a project's row used to be a bare `IconButton` with its
/// meaning in a `tooltip`, so tests reached for `find.byIcon(...)`, read
/// `.onPressed`, and read the tooltip text. **A touchscreen never shows a
/// tooltip**, which is why the row is now a `PopupMenuButton` whose items carry
/// written labels — and why a disabled item's reason is a second line on the
/// item rather than hover text.
///
/// These helpers exist so the several test files that drive that row say
/// *"the Delete project item is disabled, and here is why it says so"* rather
/// than each re-deriving how to reach into an open menu's overlay.
///
/// **[readProjectMenu] reads the whole menu in one opening and closes it
/// again**, rather than offering one getter per question. Two getters meant two
/// openings, and the second `tap` landed on the *first* menu's overlay — which
/// chose an item rather than reopening anything. That is a test helper quietly
/// performing an action nobody asked for, and it is the sort of thing that
/// makes a green run mean less than it looks.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// One item of an open project-row menu.
typedef ProjectMenuItem = ({
  /// Whether it can be chosen. A disabled item is still rendered — task 11.12's
  /// rule is explain, don't hide — so "absent" and "present but refused" are
  /// different answers and this only reports the second.
  bool enabled,

  /// The second line, where a reason or a one-line description goes. Null when
  /// the item has only its label.
  String? note,
});

/// Opens the overflow menu on project row [row] (0-based, top to bottom).
Future<void> openProjectMenu(WidgetTester tester, {int row = 0}) async {
  await tester.tap(find.byIcon(Icons.more_vert).at(row));
  await tester.pumpAndSettle();
}

/// Dismisses an open menu by tapping the barrier outside it.
Future<void> closeProjectMenu(WidgetTester tester) async {
  await tester.tapAt(const Offset(5, 5));
  await tester.pumpAndSettle();
}

/// Opens row [row]'s menu, reads every item on it, and closes it again.
///
/// Keys are the visible labels, in the order the menu renders them — so a test
/// can assert *what* is offered, *whether* it may be chosen, *what it says*,
/// and that Delete comes last.
///
/// **A duplicate label is an error, not a last-write-wins.** This map is keyed
/// on a string a person typed into the screen, and task 11.88 spent a whole
/// task on what happens when such a structure silently overwrites: an attack
/// that had flipped was reported as blind. Two menu items labelled the same
/// would make one of them untestable and unreachable by a reader; better to
/// fail here and say so.
Future<Map<String, ProjectMenuItem>> readProjectMenu(
  WidgetTester tester, {
  int row = 0,
}) async {
  await openProjectMenu(tester, row: row);
  final items = <String, ProjectMenuItem>{};
  for (final element
      in find.byWidgetPredicate((w) => w is PopupMenuItem).evaluate()) {
    final widget = element.widget as PopupMenuItem;
    final texts = tester
        .widgetList<Text>(
          find.descendant(of: find.byWidget(widget), matching: find.byType(Text)),
        )
        .toList();
    if (texts.isEmpty) continue;
    final label = texts.first.data!;
    if (items.containsKey(label)) {
      fail(
        'Two items in the project row menu are both labelled "$label". A menu '
        'keyed on typed labels cannot have duplicates — one of them would be '
        'invisible to every test that names it, and ambiguous to a reader.',
      );
    }
    items[label] = (
      enabled: widget.enabled,
      note: texts.length < 2 ? null : texts[1].data,
    );
  }
  await closeProjectMenu(tester);
  return items;
}

/// The marker [readProjectMenuOrder] uses for a `PopupMenuDivider`.
const String projectMenuDivider = '---divider---';

/// Every entry of row [row]'s menu, in order, dividers included.
///
/// **The dividers are the point, not decoration.** Task 11.99's second finding
/// was that leave-the-project and delete-the-project were two unlabelled
/// glyphs of the same size, one tap apart, and only one of them is
/// recoverable. Labels fix half of that; separation fixes the other half, and
/// a test that reads only the labels would call the job done while the two
/// were still neighbours.
Future<List<String>> readProjectMenuOrder(
  WidgetTester tester, {
  int row = 0,
}) async {
  await openProjectMenu(tester, row: row);
  final order = <String>[];
  for (final element
      in find.byWidgetPredicate((w) => w is PopupMenuEntry).evaluate()) {
    final widget = element.widget;
    if (widget is PopupMenuDivider) {
      order.add(projectMenuDivider);
      continue;
    }
    final texts = tester.widgetList<Text>(
      find.descendant(of: find.byWidget(widget), matching: find.byType(Text)),
    );
    if (texts.isNotEmpty) order.add(texts.first.data!);
  }
  await closeProjectMenu(tester);
  return order;
}

/// Opens row [row]'s menu and chooses [label]. Leaves the menu closed.
Future<void> tapProjectMenuItem(
  WidgetTester tester,
  String label, {
  int row = 0,
}) async {
  await openProjectMenu(tester, row: row);
  await tester.tap(find.text(label));
  await tester.pumpAndSettle();
}
