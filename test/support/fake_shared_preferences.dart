import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

/// Installs an in-memory [SharedPreferencesAsyncPlatform] so widget tests
/// that boot the real app (which reads `ActiveProjectId`/`ActiveUserId` via
/// `SharedPreferencesAsync`) don't hit "SharedPreferencesAsyncPlatform
/// instance must be set" — there's no real platform channel under
/// `flutter test`. Call once per test, e.g. in `setUp`.
void installFakeSharedPreferences() {
  SharedPreferencesAsyncPlatform.instance = InMemorySharedPreferencesAsync.empty();
}
