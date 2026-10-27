import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

part 'device_id_provider.g.dart';

/// A random id generated once per install and persisted thereafter — the
/// `origin_device_id` every row's [SyncMeta] carries (technical doc's global
/// sync columns). It is the last tiebreaker in [MergeResolver]'s
/// last-write-wins ordering when two devices edit the same row at the same
/// revision and timestamp, and it is what lets a future sync layer tell "my
/// copy" from "their copy" of the same logical row.
///
/// Not a hardware identifier (no permissions, no privacy implications beyond
/// an opaque random string) — purely a local install marker.
@Riverpod(keepAlive: true)
Future<String> deviceId(Ref ref) async {
  const prefsKey = 'device_id';
  final prefs = SharedPreferencesAsync();
  final existing = await prefs.getString(prefsKey);
  if (existing != null) return existing;

  final id = const Uuid().v4();
  await prefs.setString(prefsKey, id);
  return id;
}
