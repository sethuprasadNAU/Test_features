import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:shared_preferences/shared_preferences.dart';

part 'tag_sort_provider.g.dart';

/// The two orders task 11.178 offers — no ascending/descending choice, since
/// nobody asked for one and it doubles the surface for no requested benefit.
/// [frequency] matches [TagRepository.findAll]'s existing default order.
enum TagSortOrder { frequency, name }

/// The tag database screen's chosen sort order, persisted across launches
/// (task 11.178: "a person who sorts by name once probably means it").
/// `keepAlive: true` matches [ActiveProjectId]'s reasoning — this is read from
/// a bare `ref.read` by the CSV export path with no guaranteed listener.
@Riverpod(keepAlive: true)
class TagSortOrderSetting extends _$TagSortOrderSetting {
  static const _prefsKey = 'tag_sort_order';
  final _prefs = SharedPreferencesAsync();

  @override
  Future<TagSortOrder> build() async {
    final raw = await _prefs.getString(_prefsKey);
    return TagSortOrder.values.firstWhere(
      (o) => o.name == raw,
      orElse: () => TagSortOrder.frequency,
    );
  }

  Future<void> set(TagSortOrder order) async {
    await _prefs.setString(_prefsKey, order.name);
    if (!ref.mounted) return;
    state = AsyncData(order);
  }
}
