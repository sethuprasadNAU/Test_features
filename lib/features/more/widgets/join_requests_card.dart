import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

import '../../../core/providers/join_request_watcher.dart';

/// **What happened to the requests this person made** — every outcome, in one
/// place (tasks 11.81 and 11.83).
///
/// ## Why approval and rejection are told by the same element
///
/// Task 11.81 built this card so a *rejected* person was told rather than left
/// staring at a screen that never changed — the class task 11.60 found for
/// removed members, met before it could happen again. It then filtered
/// approvals out of its own list, on the reasoning that an approved person
/// would find their project on the list below.
///
/// **So at the exact moment the good news arrived, the one element tracking
/// the request went blank**, and what replaced it was a Join button on a
/// screen nobody had a reason to open. Michael found it on two real devices on
/// 2026-08-31: the Mac approved, and the iPhone showed nothing at all.
///
/// A person told *"waiting for approval"* should next be told *"you're in"*,
/// by the same words in the same place — and by then it should be true, which
/// is `JoinRequestWatcher`'s half of task 11.83.
///
/// ## Where it appears
///
/// Both the "Join a project" screen and the **projects screen**. The second is
/// the point: the whole defect was that the truth was one screen away from
/// where the person was looking, and putting it back on the join screen alone
/// would move it one screen away again.
class JoinRequestsCard extends ConsumerWidget {
  const JoinRequestsCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final watch = ref.watch(joinRequestWatcherProvider);
    final rows = <_RequestRow>[];
    for (final request in watch.requests) {
      final row = _rowFor(request, watch.arrivals[request.requestId]);
      if (row != null) rows.add(row);
    }
    if (rows.isEmpty) return const SizedBox.shrink();
    return Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 16, 16, 0),
            child: Text('Your requests'),
          ),
          for (final row in rows)
            ListTile(
              leading: row.spinning
                  ? const SizedBox(
                      width: 24,
                      height: 24,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Icon(row.icon),
              title: Text(row.projectName),
              subtitle: Text(row.message),
              isThreeLine: true,
            ),
        ],
      ),
    );
  }

  /// The one row this request deserves, or null if it deserves none.
  ///
  /// **An approval is shown only while this device has something to say about
  /// it.** Decided requests are never pruned on the server, so a person who
  /// joined three projects over a season carries three approvals in this list
  /// forever; rendering them all would turn a status card into a history no
  /// one asked for. The arrival state is in-memory and lasts the session,
  /// which is exactly as long as "you're in" is news.
  _RequestRow? _rowFor(MyJoinRequest request, JoinArrivalState? arrival) {
    final name = request.projectName;
    if (request.isPending) {
      return _RequestRow(
        projectName: name,
        icon: Icons.hourglass_empty,
        message: 'Waiting for the owner to approve it.',
      );
    }
    switch (request.decision) {
      case joinDecisionRejected:
        return _RequestRow(
          projectName: name,
          icon: Icons.do_not_disturb_on_outlined,
          message:
              'The owner turned this down. You can ask again with the same '
              'code.',
        );
      // **`cleared` is why decided requests are kept rather than deleted.** A
      // request removed by a code rotation would otherwise leave somebody on
      // "waiting" forever.
      case joinDecisionCleared:
        return _RequestRow(
          projectName: name,
          icon: Icons.do_not_disturb_on_outlined,
          message:
              'The project code was changed, so this request was cleared. Ask '
              'the owner for the new code.',
        );
    }
    if (arrival == null) return null;
    return switch (arrival.arrival) {
      JoinArrival.arriving => _RequestRow(
        projectName: name,
        icon: Icons.cloud_download_outlined,
        spinning: true,
        message:
            "You're in. Downloading the project now — the first time can "
            'take a while on a big project.',
      ),
      // **Checked, not only remembered** (task 11.302's device look). The
      // arrival is recorded when the download finishes; on Michael's Mac on
      // 2026-09-24 the owner then deleted the project, it left the projects
      // list, and this line went on saying it was there. `JoinRequestWatcher`
      // now re-reads the project's row whenever synced data arrives and
      // clears [JoinArrivalState.projectPresent] when it is gone. For
      // somebody still on the project that means an owner deleted it — a
      // member's own device cannot delete the project's row — and a restore
      // brings it back by itself.
      JoinArrival.arrived when !arrival.projectPresent => _RequestRow(
        projectName: name,
        icon: Icons.remove_circle_outline,
        message:
            'You joined this project, but it has been deleted. If it is '
            'restored, it comes back by itself.',
      ),
      JoinArrival.arrived => _RequestRow(
        projectName: name,
        icon: Icons.check_circle_outline,
        message:
            "You're in. It's on this device and syncing — open it from "
            'your projects list.',
      ),
      // **Present and behind, or not here yet.** The pull commits each page
      // before advancing, so an interruption partway leaves the project on
      // the projects screen holding part of its history; an interruption
      // before the first page leaves nothing to look at. Two situations, two
      // sentences — a person who can see the project needs to know it is
      // incomplete, and a person who cannot needs to know it is coming.
      JoinArrival.incomplete when arrival.projectPresent => _RequestRow(
        projectName: name,
        icon: Icons.cloud_off_outlined,
        message:
            "You're in, but the download stopped partway. The rest arrives "
            'the next time this device syncs with a connection.',
      ),
      JoinArrival.incomplete => _RequestRow(
        projectName: name,
        icon: Icons.cloud_off_outlined,
        message:
            "You're in, but the download hasn't started — the server could "
            'not be reached. It tries again each time you open the app with a '
            'connection.',
      ),
      // Only reachable against a server older than task 11.83, which sends the
      // decision without saying which project it is about. Nothing on this
      // device can complete the join, so it says the one true thing and points
      // at the screen that can.
      JoinArrival.cannotAct => _RequestRow(
        projectName: name,
        icon: Icons.check_circle_outline,
        message:
            "You're in. This device could not download it by itself — open "
            '"Join a project" and join it from the list there.',
      ),
    };
  }
}

class _RequestRow {
  const _RequestRow({
    required this.projectName,
    required this.icon,
    required this.message,
    this.spinning = false,
  });

  final String projectName;
  final IconData icon;
  final String message;
  final bool spinning;
}
