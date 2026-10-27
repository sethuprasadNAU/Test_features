// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'download_manager.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint, type=warning
/// App-level download queue: runs tile/DEM downloads independent of any
/// dialog or screen, so navigating within the app never kills an in-flight
/// download (only backgrounding the whole app pauses it — see class doc on
/// [didChangeAppLifecycleState]).
///
/// `keepAlive`d and never tied to a widget's lifetime. Phase C screens
/// `ref.watch(downloadManagerProvider)` for the job list (id, kind,
/// status, done/total/failed, error) and call [enqueueTiles]/[enqueueDem]/
/// [cancel]/[retry]/[resume] to drive it — no other public surface is
/// needed.

@ProviderFor(DownloadManager)
final downloadManagerProvider = DownloadManagerProvider._();

/// App-level download queue: runs tile/DEM downloads independent of any
/// dialog or screen, so navigating within the app never kills an in-flight
/// download (only backgrounding the whole app pauses it — see class doc on
/// [didChangeAppLifecycleState]).
///
/// `keepAlive`d and never tied to a widget's lifetime. Phase C screens
/// `ref.watch(downloadManagerProvider)` for the job list (id, kind,
/// status, done/total/failed, error) and call [enqueueTiles]/[enqueueDem]/
/// [cancel]/[retry]/[resume] to drive it — no other public surface is
/// needed.
final class DownloadManagerProvider
    extends $NotifierProvider<DownloadManager, List<DownloadJob>> {
  /// App-level download queue: runs tile/DEM downloads independent of any
  /// dialog or screen, so navigating within the app never kills an in-flight
  /// download (only backgrounding the whole app pauses it — see class doc on
  /// [didChangeAppLifecycleState]).
  ///
  /// `keepAlive`d and never tied to a widget's lifetime. Phase C screens
  /// `ref.watch(downloadManagerProvider)` for the job list (id, kind,
  /// status, done/total/failed, error) and call [enqueueTiles]/[enqueueDem]/
  /// [cancel]/[retry]/[resume] to drive it — no other public surface is
  /// needed.
  DownloadManagerProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'downloadManagerProvider',
        isAutoDispose: false,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$downloadManagerHash();

  @$internal
  @override
  DownloadManager create() => DownloadManager();

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(List<DownloadJob> value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<List<DownloadJob>>(value),
    );
  }
}

String _$downloadManagerHash() => r'4fb70d87868605e893370932c1091ae986fd3289';

/// App-level download queue: runs tile/DEM downloads independent of any
/// dialog or screen, so navigating within the app never kills an in-flight
/// download (only backgrounding the whole app pauses it — see class doc on
/// [didChangeAppLifecycleState]).
///
/// `keepAlive`d and never tied to a widget's lifetime. Phase C screens
/// `ref.watch(downloadManagerProvider)` for the job list (id, kind,
/// status, done/total/failed, error) and call [enqueueTiles]/[enqueueDem]/
/// [cancel]/[retry]/[resume] to drive it — no other public surface is
/// needed.

abstract class _$DownloadManager extends $Notifier<List<DownloadJob>> {
  List<DownloadJob> build();
  @$mustCallSuper
  @override
  WhenComplete runBuild() {
    final ref = this.ref as $Ref<List<DownloadJob>, List<DownloadJob>>;
    final element =
        ref.element
            as $ClassProviderElement<
              AnyNotifier<List<DownloadJob>, List<DownloadJob>>,
              List<DownloadJob>,
              Object?,
              Object?
            >;
    return element.handleCreate(ref, build);
  }
}
