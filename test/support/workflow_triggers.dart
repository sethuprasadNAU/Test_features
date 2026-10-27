/// Reading a GitHub workflow's `on:` block the way a runner does — comments
/// ignored — and reading the notice a deliberate pause leaves in it.
///
/// **Task 11.325, 2026-10-02.** GitHub's checks were paused (they start only
/// by hand) while the code changes many times a day, and each workflow keeps
/// the triggers it had as a comment under a dated notice so that restoring is
/// a copy, not a reconstruction. **A saved copy of a trigger is also text a
/// naive `contains` finds**, which is how `broken_control_trigger_test.dart`
/// would have kept passing over a workflow that no longer started on anything.
/// Every test that asks what a workflow starts on goes through here, so the
/// comment and the trigger cannot be confused.
library;

/// A workflow's notice: `# PAUSED 2026-10-02 (task 11.325): …` when it starts
/// only by hand, `# NARROWED …` when only some of its triggers were removed.
final RegExp pauseNotice = RegExp(
  r'^# (PAUSED|NARROWED) (\d{4}-\d{2}-\d{2}) \(task ([^)]+)\):',
  multiLine: true,
);

/// The source with every comment-only line removed.
String withoutComments(String source) => source
    .split('\n')
    .where((line) => !line.trimLeft().startsWith('#'))
    .join('\n');

/// The text of the live `on:` block: from `on:` to the next top-level key.
String onBlock(String source) {
  final lines = withoutComments(source).split('\n');
  final start = lines.indexOf('on:');
  if (start < 0) return '';
  final body = <String>[];
  for (final line in lines.skip(start + 1)) {
    if (line.isNotEmpty && !line.startsWith(' ') && !line.startsWith('\t')) {
      break;
    }
    body.add(line);
  }
  return 'on:\n${body.join('\n')}';
}

/// The two-space keys under `on:` — `push`, `pull_request`, `schedule`,
/// `workflow_dispatch`.
Set<String> triggerKeys(String onBlockText) => RegExp(
      r'^  ([a-z_]+):',
      multiLine: true,
    ).allMatches(onBlockText).map((m) => m.group(1)!).toSet();

/// What the notice says to restore, uncommented: the `on:` block as it was.
/// Null when the file has no saved block.
String? savedTriggers(String source) {
  const marker = '# Saved triggers, exactly as they were:';
  final at = source.indexOf(marker);
  if (at < 0) return null;
  final lines = source
      .substring(at + marker.length)
      .split('\n')
      .skip(1)
      .takeWhile((line) => line.startsWith('#'))
      .map((line) => line.replaceFirst(RegExp(r'^# ?'), ''));
  return lines.join('\n');
}

/// The triggers that start a workflow without a person: everything under `on:`
/// except the button.
Set<String> automaticTriggers(String onBlockText) =>
    triggerKeys(onBlockText)..remove('workflow_dispatch');
