// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'tag_sort_provider.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint, type=warning
/// The tag database screen's chosen sort order, persisted across launches
/// (task 11.178: "a person who sorts by name once probably means it").
/// `keepAlive: true` matches [ActiveProjectId]'s reasoning — this is read from
/// a bare `ref.read` by the CSV export path with no guaranteed listener.

@ProviderFor(TagSortOrderSetting)
final tagSortOrderSettingProvider = TagSortOrderSettingProvider._();

/// The tag database screen's chosen sort order, persisted across launches
/// (task 11.178: "a person who sorts by name once probably means it").
/// `keepAlive: true` matches [ActiveProjectId]'s reasoning — this is read from
/// a bare `ref.read` by the CSV export path with no guaranteed listener.
final class TagSortOrderSettingProvider
    extends $AsyncNotifierProvider<TagSortOrderSetting, TagSortOrder> {
  /// The tag database screen's chosen sort order, persisted across launches
  /// (task 11.178: "a person who sorts by name once probably means it").
  /// `keepAlive: true` matches [ActiveProjectId]'s reasoning — this is read from
  /// a bare `ref.read` by the CSV export path with no guaranteed listener.
  TagSortOrderSettingProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'tagSortOrderSettingProvider',
        isAutoDispose: false,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$tagSortOrderSettingHash();

  @$internal
  @override
  TagSortOrderSetting create() => TagSortOrderSetting();
}

String _$tagSortOrderSettingHash() =>
    r'afdfc5a203ea766194f4d1203cdf57fd19a6a862';

/// The tag database screen's chosen sort order, persisted across launches
/// (task 11.178: "a person who sorts by name once probably means it").
/// `keepAlive: true` matches [ActiveProjectId]'s reasoning — this is read from
/// a bare `ref.read` by the CSV export path with no guaranteed listener.

abstract class _$TagSortOrderSetting extends $AsyncNotifier<TagSortOrder> {
  FutureOr<TagSortOrder> build();
  @$mustCallSuper
  @override
  WhenComplete runBuild() {
    final ref = this.ref as $Ref<AsyncValue<TagSortOrder>, TagSortOrder>;
    final element =
        ref.element
            as $ClassProviderElement<
              AnyNotifier<AsyncValue<TagSortOrder>, TagSortOrder>,
              AsyncValue<TagSortOrder>,
              Object?,
              Object?
            >;
    return element.handleCreate(ref, build);
  }
}
