import 'package:flutter/material.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

import '../../../data/sync/project_deletion_notice.dart';
import '../../../data/sync/restored_project_arrival.dart';

/// **The words around destroying a project on the server** (task 11.290) —
/// the two dialogs an owner passes through, and the sentence every member
/// reads under the project's name. Kept in one file so the promise the
/// server can keep is written in one place and quoted nowhere from memory.
///
/// ## What these sentences may and may not say
///
/// - **"Delete now" may not say "permanently."** The server's backups keep
///   archives for [ProjectDeletionStanding.backupRetentionDays] days, so a
///   project removed today is recoverable from a dump until then whatever the
///   live server does. The honest sentence is *removed from the server now,
///   and out of the backups within N days*, and the person clicking is often
///   the one who has to make a truthful statement to somebody else.
/// - **Every number is the server's.** The grace period and the backup window
///   arrive on the standing the server answered with; nothing here has a
///   default of its own.
/// - **A member's own copy is never described as deleted.** The server's
///   rows go; the phone's stay, and the row says so.

/// `YYYY-MM-DD` in the device's local zone, or a dash for a date the server
/// did not give — the same shape the Members screen prints dates in.
String formatDeletionDate(DateTime? at) =>
    at == null ? '—' : at.toLocal().toIso8601String().substring(0, 10);

/// The line under a project's name, for the state [notice] describes.
///
/// [isOwner] chooses the last clause: the owner is told they can cancel; a
/// member is told nothing of the kind, because they cannot, and a sentence
/// offering a control the reader does not have is a trap. Both are told to
/// export, because both can, and it is the one thing that matters before the
/// date.
String describeProjectDeletion(
  ProjectDeletionNotice notice, {
  required bool isOwner,
  required DateTime now,
}) {
  final date = formatDeletionDate(notice.destroyAt);
  if (notice.executed) {
    return 'Deleted from the server on $date. The records on this device are '
        'kept — export them from ⋮.';
  }
  if (notice.isPastAt(now)) {
    // The date has passed on this clock and this device has not been told
    // the deletion ran. Both halves are stated: the schedule, and that this
    // device is behind on it. Not "was deleted" — that is a claim the server
    // has not made to this device.
    return 'Scheduled for deletion from the server on $date — that date has '
        'passed, and this device has not synced since to confirm it. Export '
        'from ⋮ before syncing.';
  }
  final days = notice.daysLeftAt(now);
  final left = days == 1 ? '1 day left' : '$days days left';
  return 'Deletion from the server scheduled: $left ($date). Every member\'s '
      'records in it go with it. Export from ⋮ before then'
      '${isOwner ? ', or cancel from ⋮.' : '.'}';
}

/// The owner's dialog: schedule, delete now (behind a second confirmation),
/// or cancel. Returns the action to send, or null.
Future<ProjectDeletionAction?> showProjectDeletionDialog(
  BuildContext context, {
  required String projectName,
  required ProjectDeletionStanding standing,
}) async {
  final grace = standing.graceDays;
  final chosen = await showDialog<ProjectDeletionAction>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text('Delete "$projectName" permanently?'),
      content: SingleChildScrollView(
        child: Text(
          'This deletes the project from the server in '
          '$grace ${grace == 1 ? 'day' : 'days'}, with every member\'s '
          'records in it — bearings, animals, collars and estimates. You can '
          'cancel any time before then.\n\n'
          'Until then every member sees the countdown and can export. Each '
          'member\'s copy on their own device stays, including this one, but '
          'stops syncing.',
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(),
          child: const Text('Cancel'),
        ),
        // The immediate path is offered here, as Michael specified, and it
        // is a text button beside the filled one: the ordinary choice is the
        // scheduled one. **Both labels carry the verb** — Michael, on the
        // device look (2026-09-20): "Cancel / Delete now / Schedule" left him
        // unsure which button scheduled what.
        TextButton(
          onPressed: () =>
              Navigator.of(dialogContext).pop(ProjectDeletionAction.immediate),
          child: const Text('Delete immediately…'),
        ),
        FilledButton(
          onPressed: () =>
              Navigator.of(dialogContext).pop(ProjectDeletionAction.schedule),
          child: const Text('Schedule delete'),
        ),
      ],
    ),
  );
  if (chosen != ProjectDeletionAction.immediate) return chosen;
  if (!context.mounted) return null;
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text('Remove "$projectName" from the server now?'),
      content: SingleChildScrollView(
        child: Text(
          'This removes the project and every member\'s records from the '
          'server now, and out of the server\'s backups within '
          '${standing.backupRetentionDays} days. Each member\'s copy on their '
          'own device stays, but will not sync again.\n\n'
          'There is no countdown and no cancel.',
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: Theme.of(dialogContext).colorScheme.error,
            foregroundColor: Theme.of(dialogContext).colorScheme.onError,
          ),
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: const Text('Remove now'),
        ),
      ],
    ),
  );
  return confirmed == true ? ProjectDeletionAction.immediate : null;
}

/// **The owner's confirmation before restoring a project they deleted**
/// (task 11.302). Returns true to go ahead.
///
/// Not a safety catch — restoring is the recoverable direction, and the
/// project can be deleted again. It is here because the act reaches other
/// people's phones: every member gets the project back, and a person should
/// know that before it happens rather than hear it from a colleague. When a
/// destruction was scheduled the dialog says the restore withdraws it,
/// because that is the one consequence a person might not expect from the
/// word *restore*.
Future<bool> showRestoreProjectDialog(
  BuildContext context, {
  required String projectName,
  DateTime? destroyAt,
}) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text('Restore "$projectName"?'),
      content: SingleChildScrollView(
        child: Text(
          'This brings the project back, with every record, for every '
          'member.\n\n'
          '${destroyAt == null ? '' : 'The deletion from the server '
                    'scheduled for ${formatDeletionDate(destroyAt)} is '
                    'canceled.\n\n'}'
          'It reaches their devices the next time they open TriTrack with '
          'cell or wifi coverage.',
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: const Text('Restore project'),
        ),
      ],
    ),
  );
  return confirmed == true;
}

/// What a device says when projects somebody else deleted come back because
/// they restored them (task 11.302). The caller leaves out restores made by
/// the signed-in account — the person did those, and was told where.
///
/// **The member is who this is for.** They lost the project without being
/// told, so a project reappearing is indistinguishable from a fault unless
/// something says what happened — and names who did it: the restore is
/// only ever made by the owner who deleted it, so the name on the restored
/// row is the person who did both. [RestoredProjectArrival.restoredByName]
/// is null when this device holds no name for them, and the sentence then
/// says "an owner" rather than inventing one.
String describeRestoredArrivals(List<RestoredProjectArrival> arrivals) {
  if (arrivals.length == 1) {
    final arrival = arrivals.single;
    final name = arrival.projectName;
    final who = arrival.restoredByName ?? 'An owner';
    return '"$name" is back in your projects. $who had deleted it and has '
        'restored it on the server, with everything in it.';
  }
  final names = [for (final a in arrivals) '"${a.projectName}"'];
  final listed =
      '${names.sublist(0, names.length - 1).join(', ')} and ${names.last}';
  return '$listed are back in your projects. They had been deleted and have '
      'been restored on the server, with everything in them.';
}

/// What a device says when a project it is on was deleted by somebody else
/// (task 11.313). The caller leaves out deletions made by the signed-in
/// account — the person did those, and the screen they did it on already
/// told them.
///
/// **The member is who this is for.** The project just vanishes from their
/// device — hidden, not closed, so a restore still finds it (see
/// `ProjectDeletionAnnouncement`'s doc) — and without this sentence a
/// disappearance reads exactly like a fault. It names who did it, the same
/// way [describeRestoredArrivals] does, and it says only what is
/// true about what happens next: neither the push this device would run nor
/// the server's own authorization reads a project's own tombstone before
/// accepting a write scoped to it, so anything recorded here and not yet
/// sent still reaches the server on the next ordinary round — it is not
/// held, and it is not lost.
String describeDeletedArrivals(List<ProjectDeletionArrival> arrivals) {
  if (arrivals.length == 1) {
    final arrival = arrivals.single;
    final name = arrival.projectName;
    final who = arrival.deletedByName ?? 'An owner';
    return '$who deleted "$name". Nothing you recorded in it is lost — it '
        'still reaches the server. If it is restored, it comes back by '
        'itself.';
  }
  final names = [for (final a in arrivals) '"${a.projectName}"'];
  final listed =
      '${names.sublist(0, names.length - 1).join(', ')} and ${names.last}';
  return '$listed were deleted. Nothing you recorded in them is lost — it '
      'still reaches the server. If they are restored, they come back by '
      'themselves.';
}
