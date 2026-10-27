import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/providers/app_context_provider.dart';
import '../../../core/providers/server_config_provider.dart';
import '../../../widgets/cloud_backup_retired_notice.dart';
import '../../../widgets/device_lock_warning_notice.dart';
import '../../../widgets/sync_status_icon.dart';

/// Hub for the screens without a dedicated tab. Project Setup and Pre-Trip
/// Checklist are built (Phase 4); Manage Offline Maps is built (Phase 5);
/// Log (the sortable observation list; renamed from "Observation History"
/// 2026-07-17), Tag Library (renamed from "Tag Database Management" — task
/// 11.245), Observation Sharing, and Data Export/Backup are built (Phase 6);
/// Profile is built (Phase 7 — view/edit the device's local identity; still
/// not a login, nothing is verified).
class MoreScreen extends ConsumerWidget {
  const MoreScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final userAsync = ref.watch(currentUserProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('More')),
      body: ListView(
        children: [
          // Task 10.79, Security Model §4.8 control 2. A one-time,
          // non-blocking warning for anyone using this device with no
          // passcode/biometric lock — renders nothing once dismissed, and
          // nothing at all for a device that already has one.
          const DeviceLockWarningTile(),
          // Task 11.189. A one-time notice about a feature that was removed,
          // for the people who had a cloud backup folder linked before task
          // 11.30 took it away. It was a permanent strip above every tab
          // until 2026-09-07, where task 11.149 measured it taking 550 of a
          // 6.1-inch phone's 852 logical pixels at AX5. It renders nothing at
          // all for everybody else, and nothing at all once dismissed.
          const CloudBackupRetiredTile(),
          ListTile(
            leading: const Icon(Icons.person_outline),
            title: const Text('Profile'),
            // "Surface the current user": who is using this device, visible
            // without leaving the app's normal navigation (Task 7.5). Not a
            // login — this is identity, not authentication.
            subtitle: userAsync.when(
              data: (user) => Text(
                user.hasPlaceholderIdentity
                    ? 'Identity not set'
                    : '${user.firstName} ${user.lastName} · ${user.email}',
              ),
              loading: () => const Text('Loading…'),
              error: (_, _) => null,
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.push('/more/profile'),
          ),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.switch_account),
            title: const Text('Projects'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.push('/more/projects'),
          ),
          ListTile(
            leading: const Icon(Icons.folder_open),
            title: const Text('Project Setup / Extent'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.push('/more/project-setup'),
          ),
          // Task 11.244. **The animals, on the menu rather than behind
          // Project Setup** — Michael, reviewing task 11.241: *"Seems like
          // the animal's list should be on that menu as well."* They sit
          // beside Project Setup because that is where a person goes to set
          // the project up, and above the checklist because the animals are
          // what the project is about.
          ListTile(
            leading: const Icon(Icons.pets),
            title: const Text('Animals'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.push('/more/animals'),
          ),
          // Task 11.313. **Beside Animals, the same way** — Michael's second
          // 11.302 device look: an owner manages members more often than
          // animals, yet this was two taps behind Projects (the project's own
          // row, then its ⋮ menu). The route there
          // (`/more/projects/:projectId/members`) still works; this is a
          // second, shorter door to the same screen, for the open project.
          ListTile(
            leading: const Icon(Icons.group_outlined),
            title: const Text('Members'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.push('/more/members'),
          ),
          // Task 11.245. **This project's own tags, moved off Project
          // Setup** — beside Animals, for the same reason: a tag is
          // equipment (design §1), and this is where a person setting the
          // project up now thinks to look for it. Not the same screen as
          // "Tag Library" below: that is every transmitter this *device*
          // knows about, across projects and outside them; this is the ones
          // copied into *this* project (task 11.219).
          ListTile(
            leading: const Icon(Icons.label_outline),
            title: const Text('Tags'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.push('/more/tags'),
          ),
          ListTile(
            leading: const Icon(Icons.checklist),
            title: const Text('Pre-Trip Checklist'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.push('/more/checklist'),
          ),
          ListTile(
            leading: const Icon(Icons.map),
            title: const Text('Manage Offline Maps'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.push('/more/offline-maps'),
          ),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.history),
            title: const Text('Log'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.push('/more/log'),
          ),
          // **"Tag Library", not "Tag Database" (task 11.245).** This
          // device's own inventory of transmitters — every one it knows
          // about, across projects and outside them — as distinct from
          // "Tags" above, which is what *this project* holds a copy of
          // (task 11.219). Two names that both said "database" read as one
          // set; "Library" says *yours, kept, reusable* and matches the
          // table (`Tag_Library`).
          ListTile(
            leading: const Icon(Icons.podcasts),
            title: const Text('Tag Library'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.push('/more/tag-database'),
          ),
          ListTile(
            leading: const Icon(Icons.share),
            title: const Text('Observation Sharing'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.push('/more/observation-sharing'),
          ),
          ListTile(
            leading: const Icon(Icons.backup),
            title: const Text('Data Export / Backup'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.push('/more/data-export'),
          ),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.dns_outlined),
            title: const Text('Server Connection'),
            // "Not configured" is the default and fully supported (task
            // 10.2) — this subtitle states that plainly rather than treating
            // it as an error or omitting it.
            subtitle: ref
                .watch(serverConfigProvider)
                .when(
                  data: (config) => Text(
                    config.isConfigured
                        ? config.baseUrl!
                        : 'Not configured — working offline',
                  ),
                  loading: () => const Text('Loading…'),
                  error: (_, _) => null,
                ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.push('/more/server'),
          ),
          // Task 10.2's invariant: a user who never configured a server sees
          // none of this, not even a menu entry for it.
          if (ref.watch(serverConfigProvider).value?.isConfigured ?? false)
            ListTile(
              leading: const Icon(Icons.sync),
              // **The dot the More tab's badge points at** (task 11.189).
              // Michael, 2026-09-07, on seeing the tab badge: *"there should
              // be a corresponding dot on the sync line in the more menu so
              // the user knows where to look."* A coloured dot on a tab says
              // *something* is wrong and leaves somebody opening menu entries
              // to find out which. It reads the same provider through the
              // same helper the tab's badge does, so the two cannot show
              // different colours.
              //
              // **Beside the words, not on the leading icon**, and nearly
              // twice the tab badge's diameter. It was an 8-pixel `Badge` on
              // that icon for about an hour, and Michael's verdict was *"you
              // put it on the icon on the left and it is hard to see"* — a
              // size that works as an annotation on a small tab is a speck on
              // a full-width row. `MainAxisSize.min` so the row is the title
              // and the dot rather than the title stretched to the chevron.
              title: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Flexible(child: Text('Sync Status')),
                  SizedBox(width: 10),
                  SyncStatusDot(),
                ],
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => context.push('/more/sync-status'),
            ),
          const Divider(),
          // Task 11.133 item 3. Last in the list because it is the one entry
          // nobody navigates here to use — but it is the one a beta tester is
          // asked to open when their report needs a build number, and until
          // now there was nothing to send them to.
          ListTile(
            leading: const Icon(Icons.info_outline),
            title: const Text('App Info'),
            subtitle: const Text('Version, build number and map credits'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.push('/more/app-info'),
          ),
        ],
      ),
    );
  }
}
