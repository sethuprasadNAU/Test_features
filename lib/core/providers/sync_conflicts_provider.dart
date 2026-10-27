import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../data/sync/consent_summary.dart';
import '../../data/sync/sync_conflicts.dart';
import 'database_provider.dart';

part 'sync_conflicts_provider.g.dart';

/// Superseded local edits for [projectId] the user has not yet acknowledged —
/// task 10.12's "reviewable list of an edit you made was superseded."
///
/// Not `keepAlive`: unlike [syncControllerProvider], nothing needs this held
/// warm in the background — it is read by the status screen and invalidated
/// by [SyncController] after a sync round, which is enough to stay current
/// while anything is actually watching it.
@riverpod
Future<List<SyncConflict>> syncConflicts(Ref ref, String projectId) async {
  final db = await ref.watch(appDatabaseProvider.future);
  return SyncConflictStore(db.raw).unreviewed(projectId);
}

/// [syncConflictsProvider] grouped into one entry per import or sync round —
/// task 10.87. The screen renders these, not the flat list.
@riverpod
Future<List<SyncConflictEvent>> syncConflictEvents(
  Ref ref,
  String projectId,
) async {
  final conflicts = await ref.watch(syncConflictsProvider(projectId).future);
  return SyncConflictEvent.group(
    conflicts,
    tableOrder: ConsentSummary.tableOrder,
  );
}

@riverpod
Future<int> syncConflictCount(Ref ref, String projectId) async {
  final conflicts = await ref.watch(syncConflictsProvider(projectId).future);
  return conflicts.length;
}

/// Acknowledges one conflict and refreshes [syncConflictsProvider] for
/// [projectId] so the list and count drop it immediately.
Future<void> markSyncConflictReviewed(
  WidgetRef ref,
  String projectId,
  int conflictId,
) async {
  final db = await ref.read(appDatabaseProvider.future);
  await SyncConflictStore(db.raw).markReviewed(conflictId);
  ref.invalidate(syncConflictsProvider(projectId));
}

/// Acknowledges every conflict in one [SyncConflictEvent] — the whole import,
/// or the whole sync round — and refreshes the list.
Future<void> markSyncConflictEventReviewed(
  WidgetRef ref,
  String projectId,
  SyncConflictEvent event,
) async {
  final db = await ref.read(appDatabaseProvider.future);
  await SyncConflictStore(db.raw).markReviewedMany(event.ids);
  ref.invalidate(syncConflictsProvider(projectId));
}
