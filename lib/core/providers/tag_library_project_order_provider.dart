import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// **The order of the project headings on the Tag Library, as this person
/// arranged them** — task 11.321. Michael, 2026-09-30: *"I should also be
/// able to click and drag and change the order of the projects in the tag
/// library."*
///
/// Project ids, first to last. Kept on this device only, like the library
/// itself and its sort order (`TagSortOrderSetting`): it is how one person
/// likes their own list laid out, not a fact about any project. A project
/// not in the list goes after the ones that are, by name — see
/// `groupLibraryByProject`.
final tagLibraryProjectOrderProvider =
    AsyncNotifierProvider<TagLibraryProjectOrder, List<String>>(
      TagLibraryProjectOrder.new,
    );

class TagLibraryProjectOrder extends AsyncNotifier<List<String>> {
  static const _prefsKey = 'tag_library_project_order';
  final _prefs = SharedPreferencesAsync();

  @override
  Future<List<String>> build() async =>
      await _prefs.getStringList(_prefsKey) ?? const [];

  /// Shown at once, then saved — a heading dropped in its new place must not
  /// jump back while the write finishes.
  Future<void> set(List<String> projectIds) async {
    state = AsyncData(List.unmodifiable(projectIds));
    await _prefs.setStringList(_prefsKey, projectIds);
  }
}
