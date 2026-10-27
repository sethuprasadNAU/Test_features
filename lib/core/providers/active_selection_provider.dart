import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:shared_preferences/shared_preferences.dart';

part 'active_selection_provider.g.dart';

/// Persisted IDs only, for now. Phase 1 adds `currentProjectProvider` /
/// `currentUserProvider` that resolve these IDs to full `Project`/`User`
/// rows via the repositories built in that phase — screens should migrate
/// to those once available rather than re-deriving objects from the ID here.
///
/// **Both notifiers below are `keepAlive: true`, not the `@riverpod` default.**
/// This is app-global selection state — task 10.2 set the same precedent for
/// `ServerConfigNotifier` — and callers legitimately mutate them via a bare
/// `ref.read(...).notifier).set(...)` with no active watcher at the call site
/// (`CurrentSession.completeSignIn`, `app_context_provider.dart`'s
/// auto-create path, several `More` screens). An `autoDispose` notifier with
/// no listener can be torn down by Riverpod the instant its refcount hits
/// zero — which a bare `read` can trigger immediately — and if that lands
/// while `set()` is suspended on its `await _prefs.setString(...)`, the
/// `state = AsyncData(...)` assignment after it throws "Cannot use the Ref
/// of ... after it has been disposed." **This happened on a real device**
/// (task 10.4's phone-on-LAN check), crashing inside `completeSignIn`. It did
/// not reproduce in a plain `ProviderContainer` unit test even with a real
/// `Future.delayed` standing in for the network round trip — Riverpod's
/// disposal scheduling goes through a `Vsync` that a widget-bound
/// `ProviderScope` supplies (frame callbacks) and a bare container falls back
/// to a zero-duration `Timer`, so the two don't race identically. `keepAlive`
/// removes the possibility outright rather than depending on reproducing or
/// reasoning about that timing, in either environment.
@Riverpod(keepAlive: true)
class ActiveProjectId extends _$ActiveProjectId {
  static const _prefsKey = 'active_project_id';
  final _prefs = SharedPreferencesAsync();

  @override
  Future<String?> build() => _prefs.getString(_prefsKey);

  Future<void> set(String? projectId) async {
    if (projectId == null) {
      await _prefs.remove(_prefsKey);
    } else {
      await _prefs.setString(_prefsKey, projectId);
    }
    // Defensive, even under keepAlive: `ref.mounted` is cheap and protects
    // against a manual `ref.invalidate` racing this same await.
    if (!ref.mounted) return;
    state = AsyncData(projectId);
  }
}

@Riverpod(keepAlive: true)
class ActiveUserId extends _$ActiveUserId {
  static const _prefsKey = 'active_user_id';
  final _prefs = SharedPreferencesAsync();

  @override
  Future<String?> build() => _prefs.getString(_prefsKey);

  Future<void> set(String? userId) async {
    if (userId == null) {
      await _prefs.remove(_prefsKey);
    } else {
      await _prefs.setString(_prefsKey, userId);
    }
    if (!ref.mounted) return;
    state = AsyncData(userId);
  }
}
