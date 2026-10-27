import 'dart:async';
import 'dart:convert';

import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:shared_preferences/shared_preferences.dart';

part 'cloud_backup_retirement_provider.g.dart';

/// The only thing left of the automatic cloud backup (task 11.30): a one-time
/// notice for the people who had it switched on, and the removal of the
/// setting it read.
///
/// **Why this exists rather than nothing at all.** The feature copied a
/// project's whole archive into a folder the user linked in iCloud Drive or
/// Google Drive, on a schedule, and it is now gone. Somebody who linked such a
/// folder has real files sitting in it that this app will never write to
/// again, and no screen would otherwise ever say so. Deleting a backup
/// mechanism without telling the person who relied on it is how a field season
/// gets lost — they would go on believing a copy was being kept.
///
/// **What counts as "had it on" is a linked folder, not the `enabled` flag.**
/// The old setting defaulted `enabled` to `true` before any folder was chosen,
/// so `enabled` alone was true for people for whom nothing was ever copied
/// anywhere. A linked folder (`folderToken`) is the only durable evidence that
/// bytes actually left the device, and it is exactly the population with files
/// to account for.
///
/// **It reads the old preference directly rather than through the deleted
/// notifier**, which is the point: the settings model, its provider, the
/// service, the platform channel and the UI section are all removed, and this
/// reads the leftover JSON blob one last time before erasing the key. Once
/// [dismiss] runs, the key is gone and this can never fire again — including
/// after a reinstall-free upgrade, which is the case it is for.
@Riverpod(keepAlive: true)
class CloudBackupRetirementNotice extends _$CloudBackupRetirementNotice {
  /// The key the retired [CloudBackupSettingsNotifier] wrote. Named here, in
  /// the only code that still knows it exists, because leaving an orphaned
  /// preference on every device forever is its own small mess.
  static const prefsKey = 'cloud_backup_settings_v1';

  final _prefs = SharedPreferencesAsync();

  /// True only while a device that had a folder linked has not yet
  /// acknowledged the notice.
  @override
  Future<bool> build() async {
    final raw = await _prefs.getString(prefsKey);
    if (raw == null) return false;
    try {
      final json = jsonDecode(raw) as Map<String, Object?>;
      final hadFolderLinked = (json['folderToken'] as String?) != null;
      if (!hadFolderLinked) {
        // Nothing was ever copied anywhere, so there is nothing to tell them
        // and nothing to account for. Still clear the key: it describes a
        // feature that no longer exists.
        unawaited(_prefs.remove(prefsKey));
        return false;
      }
      return true;
    } catch (_) {
      // Unparseable leftovers say nothing reliable about whether a folder was
      // linked. Showing a notice about files that may not exist would be worse
      // than silence, so clear it and say nothing.
      unawaited(_prefs.remove(prefsKey));
      return false;
    }
  }

  /// Acknowledged. Clears the old key so the notice never returns.
  Future<void> dismiss() async {
    state = const AsyncData(false);
    await _prefs.remove(prefsKey);
  }
}
