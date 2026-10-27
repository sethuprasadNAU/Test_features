/// Reading a task's status out of `CLAUDE_DOCS/DEVELOPMENT_PLAN.md`.
///
/// Task 11.179 wrote this for two checks that both need the same answer —
/// *is this work still outstanding?* — and would otherwise each carry their own
/// copy of the parsing. Two copies of a classifier is two places for it to be
/// wrong, and only one of them gets fixed.
///
/// **The plan is prose, and this reads only the paragraph a task states its
/// status in.** Most entries open with a `**Status:**` line; a few write the
/// status as the entry's first paragraph instead (task 11.50's *"STAY
/// DEFERRED"*, task 11.80's *"PARTIAL 2026-09-01"*), so both shapes are read
/// and nothing further down the entry is looked at. That bound matters: a task
/// entry is thousands of words that mention other tasks being Done.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const String developmentPlanPath = 'CLAUDE_DOCS/DEVELOPMENT_PLAN.md';

/// Words meaning the work is still outstanding.
const List<String> stillRunnableWords = [
  'NOT STARTED',
  'IN PROGRESS',
  'BLOCKED',
  'DEFERRED',
  'PARTIAL',
];

/// Words meaning the work is over.
const List<String> finishedWords = [
  'DONE',
  'CANCELLED',
  'CANCELED',
  'SUPERSEDED',
  'MERGED',
  'RESOLVED',
];

/// The plan, as lines. Fails rather than returning an empty list, because
/// every caller's check is satisfied by reading nothing.
List<String> readDevelopmentPlan() {
  final file = File(developmentPlanPath);
  expect(
    file.existsSync(),
    isTrue,
    reason:
        '$developmentPlanPath is missing. It is the authority on what work is '
        'outstanding, and nothing that reads a task status means anything '
        'without it.',
  );
  final lines = file.readAsLinesSync();
  expect(
    lines.length,
    greaterThan(1000),
    reason:
        '$developmentPlanPath came back with only ${lines.length} lines. A '
        'truncated read makes every task look as though it has no entry.',
  );
  return lines;
}

/// The paragraph in which `### Task [taskId]`'s entry states its status, or
/// null when the plan has no entry for that task at all.
String? planStatusParagraph(List<String> plan, String taskId) {
  final heading = RegExp('^### Task ${RegExp.escape(taskId)}( |\$)');
  final start = plan.indexWhere(heading.hasMatch);
  if (start < 0) return null;

  var end = plan.length;
  for (var i = start + 1; i < plan.length; i++) {
    if (plan[i].startsWith('### ')) {
      end = i;
      break;
    }
  }
  final body = plan.sublist(start + 1, end);

  final statusLine = body.indexWhere((l) => l.contains('**Status:**'));
  final from = statusLine >= 0 ? statusLine : 0;
  final paragraph = <String>[];
  for (var i = from; i < body.length; i++) {
    if (body[i].trim().isEmpty) break;
    paragraph.add(body[i]);
  }
  return paragraph.join(' ');
}

/// True when [paragraph] says the work is over, false when it says the work is
/// outstanding, **null when it says neither**.
///
/// Re-runnable words are read first, deliberately. Task 11.80's status
/// paragraph says `PARTIAL` in its first sentence and *"is done"* in its
/// second, about a different half of the same task — so a paragraph containing
/// both is treated as outstanding. This can miss a finished task; it cannot
/// invent one. Callers turn the null into a failure rather than a pass: a
/// status nobody can read is indistinguishable from the thing being checked
/// for, and only one of those is harmless.
bool? isFinishedStatus(String paragraph) {
  final upper = paragraph.toUpperCase();
  for (final word in stillRunnableWords) {
    if (upper.contains(word)) return false;
  }
  for (final word in finishedWords) {
    if (upper.contains(word)) return true;
  }
  return null;
}
