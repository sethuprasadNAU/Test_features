/// Task 11.179 — **a slash command exists only while its task is still
/// runnable.**
///
/// `.claude/commands/*.md` opens a fresh Claude Code window on a task. **The
/// window cannot tell whether the task is still outstanding**, and on
/// 2026-09-02 task 11.37 was re-invoked four days after it finished: the run
/// re-derived all six of its items against the code, concluded nothing was
/// needed, and was entirely wasted. Measuring the directory afterwards found
/// **122 of 152 command files were for tasks already Done, merged, cancelled
/// or superseded.**
///
/// The remedy adopted then was a habit — *the planning session deletes a
/// task's command file when it resolves that task's comms entry.* **This file
/// is that habit made mechanical**, for the reason `CLAUDE.md` gives about
/// reopen triggers: a sentence that says "delete this when X" and a test that
/// fails when X are the same claim, and only one of them tells anybody.
///
/// **A command file and a `Status:` field are two copies of "is this work
/// outstanding".** This test makes the copies agree.
///
/// ## It was built green, and that is the point of the sabotage below
///
/// Task 11.123 measured the directory on 2026-09-06: **all 20 command files
/// were for tasks that are `Not started`, `Deferred` or `Partial`.** So this
/// check passed on the day it was written and proved nothing by passing. **A
/// check written green proves nothing until it has been watched red**, so task
/// 11.179 resurrected the command file of a `Done` task and of a finished
/// website task and watched both fail, then confirmed that `Deferred` and
/// `Partial` — which are legitimately re-runnable — still pass.
///
/// ## What counts as still-runnable
///
/// `Not started`, `In progress`, `Blocked`, `Deferred` and `Partial` all keep
/// a command alive. **`Deferred` and `Partial` matter most:** a deferred task
/// is waiting for a written trigger and a partial one stopped at a named line,
/// and in both cases the command is exactly what somebody will want when the
/// trigger fires. `Done`, `Cancelled`, `Superseded` and `Merged` mean the
/// command should have been deleted.
///
/// ## Where each status is read from, and why
///
/// - **A numbered task (`11.62`)** — from its entry in
///   `CLAUDE_DOCS/DEVELOPMENT_PLAN.md`, which is the authority on what is
///   outstanding. Most entries carry a `**Status:**` line; a few write the
///   status as the entry's opening paragraph instead (task 11.50's *"STAY
///   DEFERRED"*, task 11.80's *"PARTIAL 2026-09-01"*), so both shapes are
///   read.
/// - **A website task (`/w-10`)** — from `CLAUDE_DOCS/WEBSITE_COMMS.md`, whose
///   entry headings end in `Done` or `Partial` (read by that leading word, so
///   `Done (the page stays a draft)` is Done; task 11.332). **`WEBSITE_PLAN.md` has no
///   `Status:` field at all** — that lane records completion in prose — so the
///   comms file is the only machine-readable source there. A website task with
///   no comms entry has not run, which keeps its command alive.
/// - **A command that is not for a task** — a command whose `description:`
///   names no task id has no status to read. **The uncovered set is empty as of
///   2026-09-10 and printing it is what made that visible.** It held the five
///   `Step N of 5` files of the August security campaign, which were not plan
///   entries; task 11.220 checked each against the plan and deleted all five —
///   `scope-and-triage` is task 10.106, `harness-trustworthy` is 10.95,
///   `gate-c-close` is 10.92 and `gate-d-close` is 10.93/10.94, all Done, and
///   **three of those entries name their own command file in the `Status:`
///   line**. `gates-final` ran the gates five times between 17 and 30 August;
///   Gate D passes and Gate C's one remaining blocker is criterion 5, the NAU
///   review, which is Michael's to arrange and not something a window can run.
///   The set is still **printed on every run** rather than silently skipped, so
///   a new uncovered command is visible in the log instead of being a fact
///   about this file that nobody meets.
///
/// The task id comes from the `description:` frontmatter rather than the
/// filename, and the two are **required to agree** where the filename encodes
/// one. Renaming a stale command therefore does not escape the check.
///
/// ## The direction this fails in
///
/// A status paragraph is prose, and the classifier reads the re-runnable words
/// first: a paragraph containing both is treated as re-runnable. That is
/// deliberate — task 11.80's status paragraph says `PARTIAL` in its first
/// sentence and *"is done"* in its second, about a different half of the same
/// task. So this check can **miss** a stale command whose status paragraph
/// happens to contain a re-runnable word, and cannot invent one. A missed
/// staleness costs a wasted window; a false red costs every commit in the
/// repository until somebody works out what the test meant.
///
/// A status paragraph containing **neither** kind of word is a failure, not a
/// pass. That is the one place this refuses to guess.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../support/plan_status.dart';

const String _commandsDirectory = '.claude/commands';
const String _planPath = developmentPlanPath;
const String _websiteCommsPath = 'CLAUDE_DOCS/WEBSITE_COMMS.md';

/// `11-62-methods-nobody-calls.md` -> `11.62`; `w-10-...md` -> `w-10`.
final RegExp _idFromFilename = RegExp(r'^(?:(\d+)-(\d+)|w-(\d+))-');

/// `"Task 11.62 — ..."` or `"Task /w-10 — ..."` from the frontmatter.
final RegExp _idFromDescription = RegExp(r'Task\s+/?`?(\d+\.\d+|w-\d+)');

final RegExp _descriptionLine = RegExp(r'^description:\s*"?(.*?)"?\s*$');

class _Command {
  _Command(this.file, this.taskId, this.filenameId);

  final String file;
  final String? taskId;
  final String? filenameId;
}

List<String> _tracked(String prefix) {
  final result = Process.runSync('git', [
    'ls-files',
    '-z',
    '--cached',
    '--others',
    '--exclude-standard',
    prefix,
  ]);
  if (result.exitCode != 0) {
    fail(
      '`git ls-files $prefix` failed (${result.stderr}). This test must not '
      'fall back to listing the directory: an untracked scratch copy of a '
      'command file is not something anybody can be sent to run, and reading '
      'one would fail the build over a file that is not in the repository.',
    );
  }
  return (result.stdout as String)
      .split('\u0000')
      .where((p) => p.isNotEmpty)
      .toList();
}

String? _descriptionOf(String path) {
  for (final line in File(path).readAsLinesSync().take(10)) {
    final match = _descriptionLine.firstMatch(line);
    if (match != null) return match.group(1);
  }
  return null;
}

/// Every status word a website task's comms headings carry, newest first is
/// irrelevant — any `Done` heading means the task ran to completion.
///
/// **The status is the leading word after the heading's last em dash**, with
/// any backticks or asterisks around it taken off — not the whole text there.
/// Task 11.332 item 5: `Done (the theory page stays a draft)` and
/// `` `Done` `` are both Done, and reading the whole tail made each of them a
/// status nobody matched, so a finished task's command file passed.
List<String> _websiteStatuses(List<String> comms, String taskId) {
  final mention = RegExp('^###[^\n]*${RegExp.escape(taskId)}\\b');
  final leadingWord = RegExp(r'^[`*\s]*([A-Za-z]+)');
  final statuses = <String>[];
  for (final line in comms) {
    if (!mention.hasMatch(line)) continue;
    final tail = line.split('—').last;
    final word = leadingWord.firstMatch(tail)?.group(1);
    if (word != null) statuses.add(word.toUpperCase());
  }
  return statuses;
}

void main() {
  late List<_Command> commands;
  late List<String> plan;
  late List<String> websiteComms;

  setUpAll(() {
    final files = _tracked(_commandsDirectory)
        .where((p) => p.endsWith('.md'))
        .toList()
      ..sort();

    commands = files.map((path) {
      final name = path.split('/').last;
      final fromName = _idFromFilename.firstMatch(name);
      final filenameId = fromName == null
          ? null
          : fromName.group(3) != null
              ? 'w-${fromName.group(3)}'
              : '${fromName.group(1)}.${fromName.group(2)}';
      final description = _descriptionOf(path);
      final fromDescription = description == null
          ? null
          : _idFromDescription.firstMatch(description);
      return _Command(path, fromDescription?.group(1), filenameId);
    }).toList();

    plan = readDevelopmentPlan();
    websiteComms = File(_websiteCommsPath).readAsLinesSync();
  });

  // Task 11.332 item 5 (from `/w-37`). A website heading's status was read as
  // the whole text after its last em dash, so `Done (the theory page stays a
  // draft)` and `` `Done` `` were not `DONE` and a finished task's command
  // file passed. On 2026-10-10 nine headings in WEBSITE_COMMS.md had one of
  // those two shapes (`/w-31`, `/w-32`, `/w-36`, `/w-37`, `/w-38`). Watched
  // red first: a planted `/w-36` command file passed the check below, and
  // these cases failed, before the classifier read the leading word.
  test('a website heading is classified by its leading status word', () {
    String? statusOf(String heading) {
      final statuses = _websiteStatuses([heading], 'w-36');
      return statuses.isEmpty ? null : statuses.single;
    }

    expect(statusOf('### Task `/w-36` — 2026-10-08 — commit `abc` — Done'), 'DONE');
    expect(
      statusOf('### Task `/w-36` — 2026-10-08 — commit `abc` — '
          'Done (the theory page stays a draft)'),
      'DONE',
    );
    expect(
      statusOf('### `/w-36` — resolved 2026-10-08 by the planning session — '
          '`Done` (page stays a draft)'),
      'DONE',
    );
    expect(
      statusOf('### Task `/w-36` — 2026-10-08 — commit `abc` — '
          'Partial (stopped at: the video)'),
      'PARTIAL',
    );
    // The planning session's "resolved" headings carry no status word of
    // their own in that position, and one says "(the task stays Partial)":
    // its leading word is not a status, so it must not read as Done.
    expect(
      statusOf('### `/w-36` — resolved 2026-09-07 by the planning session '
          '(the task stays Partial)'),
      isNot('DONE'),
    );
  });

  group('command files outlive their tasks (task 11.179)', () {
    // Every check below is satisfied by finding nothing, so the scan asserts
    // its own scope before any of them run.
    test('the scan found the commands directory and the plan', () {
      expect(
        commands.length,
        greaterThan(5),
        reason:
            'Only ${commands.length} files were found under '
            '$_commandsDirectory. There were 20 on 2026-09-06 and this '
            'directory does not empty quickly. A scan this narrow makes every '
            'check below pass having read nothing.',
      );
      expect(
        plan.length,
        greaterThan(1000),
        reason:
            '$_planPath came back with only ${plan.length} lines. Every task '
            'status is read from it; a truncated read would make every '
            'command look unclassifiable.',
      );
      expect(
        websiteComms.length,
        greaterThan(100),
        reason:
            '$_websiteCommsPath came back with only ${websiteComms.length} '
            'lines. Website task statuses are read from it.',
      );
      final withId = commands.where((c) => c.taskId != null).length;
      // ignore: avoid_print
      print(
        '${commands.length} command files, $withId of them for a task; '
        'not covered: '
        '${commands.where((c) => c.taskId == null).map((c) => c.file.split('/').last).join(', ')}',
      );
    });

    test('a command file names the same task its filename does', () {
      final mismatched = <String>[];
      for (final command in commands) {
        if (command.filenameId == null) continue;
        if (command.taskId == command.filenameId) continue;
        mismatched.add(
          '  ${command.file}: filename says ${command.filenameId}, '
          'description says ${command.taskId ?? "no task at all"}',
        );
      }
      expect(
        mismatched,
        isEmpty,
        reason:
            'These command files disagree with themselves about which task '
            'they are for:\n${mismatched.join('\n')}\n'
            'The status check below reads the description, so a mismatch is '
            'either a typo or a stale command renamed out of the way. Fix the '
            'description or the filename so they name the same task.',
      );
    });

    test('every command file is for a task that is still runnable', () {
      final stale = <String>[];
      final unclassifiable = <String>[];

      for (final command in commands) {
        final taskId = command.taskId;
        if (taskId == null) continue; // printed above; no status to read

        if (taskId.startsWith('w-')) {
          final statuses = _websiteStatuses(websiteComms, taskId);
          // No comms entry means the task has never reported, so it has never
          // run to completion and its command is still wanted.
          if (statuses.any((s) => s == 'DONE')) {
            stale.add(
              '  ${command.file}: $taskId reported Done in '
              '$_websiteCommsPath',
            );
          }
          continue;
        }

        final paragraph = planStatusParagraph(plan, taskId);
        if (paragraph == null) {
          unclassifiable.add(
            '  ${command.file}: no `### Task $taskId` entry in $_planPath',
          );
          continue;
        }
        final finished = isFinishedStatus(paragraph);
        if (finished == null) {
          unclassifiable.add(
            '  ${command.file}: $taskId\'s status paragraph says neither that '
            'it is outstanding nor that it is finished — '
            '"${paragraph.length > 120 ? '${paragraph.substring(0, 120)}…' : paragraph}"',
          );
        } else if (finished) {
          stale.add('  ${command.file}: $taskId is finished — "$paragraph"');
        }
      }

      expect(
        stale,
        isEmpty,
        reason:
            'These command files are for work that is over:\n'
            '${stale.join('\n')}\n'
            'Delete them. A command file opens a fresh window that cannot '
            'tell the task is already finished — on 2026-09-02 task 11.37 was '
            're-invoked four days after it closed and re-derived all six of '
            'its items before concluding nothing was needed.\n'
            'If the task is genuinely runnable again, the plan entry is what '
            'should say so: reopen it there rather than keeping a command for '
            'a task the plan calls Done.',
      );

      expect(
        unclassifiable,
        isEmpty,
        reason:
            'These command files are for a task whose status could not be '
            'read:\n${unclassifiable.join('\n')}\n'
            'This is a failure rather than a pass because a status nobody can '
            'read is indistinguishable from a stale command, and only one of '
            'those is harmless. Either the plan entry has been renamed or '
            'removed, or its status paragraph does not say whether the work is '
            'outstanding. Say so in the entry: ${stillRunnableWords.join(', ')}, '
            'or ${finishedWords.join(', ')}.',
      );
    });
  });
}
