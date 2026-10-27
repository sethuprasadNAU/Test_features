// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'device_id_provider.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint, type=warning
/// A random id generated once per install and persisted thereafter — the
/// `origin_device_id` every row's [SyncMeta] carries (technical doc's global
/// sync columns). It is the last tiebreaker in [MergeResolver]'s
/// last-write-wins ordering when two devices edit the same row at the same
/// revision and timestamp, and it is what lets a future sync layer tell "my
/// copy" from "their copy" of the same logical row.
///
/// Not a hardware identifier (no permissions, no privacy implications beyond
/// an opaque random string) — purely a local install marker.

@ProviderFor(deviceId)
final deviceIdProvider = DeviceIdProvider._();

/// A random id generated once per install and persisted thereafter — the
/// `origin_device_id` every row's [SyncMeta] carries (technical doc's global
/// sync columns). It is the last tiebreaker in [MergeResolver]'s
/// last-write-wins ordering when two devices edit the same row at the same
/// revision and timestamp, and it is what lets a future sync layer tell "my
/// copy" from "their copy" of the same logical row.
///
/// Not a hardware identifier (no permissions, no privacy implications beyond
/// an opaque random string) — purely a local install marker.

final class DeviceIdProvider
    extends $FunctionalProvider<AsyncValue<String>, String, FutureOr<String>>
    with $FutureModifier<String>, $FutureProvider<String> {
  /// A random id generated once per install and persisted thereafter — the
  /// `origin_device_id` every row's [SyncMeta] carries (technical doc's global
  /// sync columns). It is the last tiebreaker in [MergeResolver]'s
  /// last-write-wins ordering when two devices edit the same row at the same
  /// revision and timestamp, and it is what lets a future sync layer tell "my
  /// copy" from "their copy" of the same logical row.
  ///
  /// Not a hardware identifier (no permissions, no privacy implications beyond
  /// an opaque random string) — purely a local install marker.
  DeviceIdProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'deviceIdProvider',
        isAutoDispose: false,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$deviceIdHash();

  @$internal
  @override
  $FutureProviderElement<String> $createElement($ProviderPointer pointer) =>
      $FutureProviderElement(pointer);

  @override
  FutureOr<String> create(Ref ref) {
    return deviceId(ref);
  }
}

String _$deviceIdHash() => r'55a632e4c9bb4f32285eb4a01ccddb2f367080af';
