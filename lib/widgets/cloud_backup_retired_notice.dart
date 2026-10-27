import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/providers/cloud_backup_retirement_provider.dart';

/// Shown once, to the people who had a cloud backup folder linked before task
/// 11.30 removed the feature.
///
/// **Dismissible, unlike the permanent banner it replaced.** That banner was
/// deliberately permanent because it described a live problem the user could
/// still fix. This describes something that already happened and cannot be
/// un-happened; once they have read it, repeating it forever is just noise.
///
/// ## Where it lives, and why it is no longer a banner (task 11.189)
///
/// It used to be the second strip in the app shell, above every tab. Task
/// 11.149 measured what that cost: **550 of a 6.1-inch phone's 852 logical
/// pixels at AX5**, and 380 at AX3, because its two sentences wrap and
/// nothing bounded them.
///
/// Michael's answer of 2026-09-07 was to fold the notice into the new sync
/// status icon along with everything else. **Task 11.189 did not do that, and
/// says so plainly so he can overrule it: this is not a status.** It is a
/// one-time notice about a feature that was removed, and no state of the app
/// is described by "retirement notice pending" — folding it into a live
/// status icon would make the icon lie about sync in order to carry an
/// unrelated fact. So it left the banner strip entirely and became an entry
/// on the More screen, above everything else while it is showing and gone for
/// good once dismissed.
///
/// The dialog behind it is unchanged, which is where the explanation always
/// was.
class CloudBackupRetiredTile extends ConsumerWidget {
  const CloudBackupRetiredTile({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final show = ref.watch(cloudBackupRetirementNoticeProvider).value ?? false;
    if (!show) return const SizedBox.shrink();

    final scheme = Theme.of(context).colorScheme;
    // `Material`, not a `Container(color:)` — a `ListTile` paints its
    // background and its ink splash on the nearest `Material` ancestor, so a
    // coloured box between the two hides the tap feedback. Flutter says so in
    // an assertion, which is how this was found.
    return Material(
      color: scheme.secondaryContainer,
      child: ListTile(
        key: const ValueKey('cloud-backup-retired-notice'),
        leading: Icon(Icons.info_outline, color: scheme.onSecondaryContainer),
        title: Text(
          'Automatic cloud backup has been removed',
          style: TextStyle(color: scheme.onSecondaryContainer),
        ),
        subtitle: Text(
          'Tap to read what replaced it.',
          style: TextStyle(color: scheme.onSecondaryContainer),
        ),
        trailing: Icon(
          Icons.chevron_right,
          color: scheme.onSecondaryContainer.withValues(alpha: 0.7),
        ),
        onTap: () => _explain(context, ref),
      ),
    );
  }

  Future<void> _explain(BuildContext context, WidgetRef ref) async {
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Automatic cloud backup has been removed'),
        // Every sentence here is a fact about this build. Nothing describes a
        // mechanism the app no longer has: the old files are not touched, the
        // manual export is not touched, and syncing is only a backup for a
        // project that is actually published to a server.
        content: const SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'TriTrack used to copy this project into a folder you chose in '
                'iCloud Drive or Google Drive. It no longer does.',
              ),
              SizedBox(height: 12),
              Text(
                'The backups already there are untouched, and you can still '
                'restore them from Data Export & Backup.',
              ),
              SizedBox(height: 12),
              Text(
                'To keep a copy now, sync the project to a server, or save a '
                'backup file from Data Export & Backup. An unsynced project '
                'exists only on this device.',
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              ref.read(cloudBackupRetirementNoticeProvider.notifier).dismiss();
              Navigator.of(context).pop();
            },
            child: const Text('Got it'),
          ),
        ],
      ),
    );
  }
}
