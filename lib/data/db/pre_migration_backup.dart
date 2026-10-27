import 'dart:io';

import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Copies the on-disk database file to a timestamped local backup before a
/// migration is allowed to run against it (task 10.19).
///
/// **A raw file copy, deliberately, not a `ProjectExporter`/`BackupArchive`
/// export.** A row-level export needs working knowledge of the schema that is
/// about to change — exactly the thing a migration failure calls into
/// question — and it would have to iterate every project in the database one
/// at a time. A file copy needs neither: it captures the whole file, whatever
/// shape it's in, as one filesystem operation fast enough to run on every
/// upgrade without anyone noticing.
///
/// This is the one place the app itself can destroy data (a migration failing
/// partway through), so it is the one place a guaranteed backup matters most —
/// and it has to happen *before* `runMigrations` touches anything, not after.
abstract final class PreMigrationBackup {
  /// Keep only this many pre-migration snapshots. Migrations are rare (one per
  /// schema bump, not per app run), so this bounds a slowly-growing local
  /// directory rather than responding to real churn.
  static const int retentionCount = 3;

  /// If the database at [path] already exists and its on-disk
  /// `PRAGMA user_version` is below [targetVersion], copies it into
  /// [backupDir] before returning.
  ///
  /// No-ops for a brand-new database (nothing to lose — sqflite runs `onCreate`
  /// for it, not `onUpgrade`) or one already at [targetVersion] (nothing about
  /// to change). Safe to call before the real connection opens: it opens its
  /// own throwaway connection with no `version` option — which cannot itself
  /// trigger a migration — reads the version, and closes it before the copy,
  /// so the file is fully flushed and nothing holds it open during the copy.
  ///
  /// Returns the backup file, or null if none was needed.
  static Future<File?> ensureBackedUpBeforeMigration({
    required DatabaseFactory factory,
    required String path,
    required int targetVersion,
    required Directory backupDir,
    DateTime? now,
  }) async {
    final source = File(path);
    if (!await source.exists()) return null;

    final probe = await factory.openDatabase(path);
    final rows = await probe.rawQuery('PRAGMA user_version');
    await probe.close();
    final onDiskVersion = rows.isEmpty
        ? 0
        : (rows.first.values.first as int? ?? 0);

    // Version 0 means a file that exists but was never successfully migrated
    // (or is not a TriTrack database at all) — nothing recognizable to back up
    // separately from what `onCreate`/the first `onUpgrade` will do anyway.
    if (onDiskVersion == 0 || onDiskVersion >= targetVersion) return null;

    if (!await backupDir.exists()) {
      await backupDir.create(recursive: true);
    }
    final stamp = _timestamp((now ?? DateTime.now()).toUtc());
    final backupPath =
        '${backupDir.path}/pre_migration_v${onDiskVersion}_$stamp.db';
    final backupFile = await source.copy(backupPath);

    await _applyRetention(backupDir);
    return backupFile;
  }

  /// Deletes this directory's oldest snapshots beyond [retentionCount].
  /// Filenames are lexicographically sortable by their embedded UTC
  /// timestamp, so no filesystem metadata is needed to determine age order.
  /// A failure deleting an individual old file is swallowed — a stale extra
  /// snapshot is a much smaller problem than surfacing an error for what was
  /// otherwise a successful backup.
  static Future<void> _applyRetention(Directory backupDir) async {
    final files = await backupDir
        .list()
        .where((entry) => entry is File && entry.path.endsWith('.db'))
        .cast<File>()
        .toList();
    files.sort((a, b) => a.path.compareTo(b.path));
    if (files.length <= retentionCount) return;
    for (final file in files.sublist(0, files.length - retentionCount)) {
      try {
        await file.delete();
      } catch (_) {
        // Best-effort cleanup only — see doc comment above.
      }
    }
  }

  /// `yyyyMMdd'T'HHmmss'Z'`, hand-formatted so filenames sort chronologically
  /// as plain strings — the same scheme `CloudBackupService` uses.
  static String _timestamp(DateTime utc) {
    String p2(int n) => n.toString().padLeft(2, '0');
    return '${utc.year}${p2(utc.month)}${p2(utc.day)}'
        'T${p2(utc.hour)}${p2(utc.minute)}${p2(utc.second)}Z';
  }
}
