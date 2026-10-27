// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'cloud_backup_retirement_provider.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint, type=warning
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

@ProviderFor(CloudBackupRetirementNotice)
final cloudBackupRetirementNoticeProvider =
    CloudBackupRetirementNoticeProvider._();

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
final class CloudBackupRetirementNoticeProvider
    extends $AsyncNotifierProvider<CloudBackupRetirementNotice, bool> {
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
  CloudBackupRetirementNoticeProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'cloudBackupRetirementNoticeProvider',
        isAutoDispose: false,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$cloudBackupRetirementNoticeHash();

  @$internal
  @override
  CloudBackupRetirementNotice create() => CloudBackupRetirementNotice();
}

String _$cloudBackupRetirementNoticeHash() =>
    r'80418c979247675fbd67a9fc75385dcb439f647e';

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

abstract class _$CloudBackupRetirementNotice extends $AsyncNotifier<bool> {
  FutureOr<bool> build();
  @$mustCallSuper
  @override
  WhenComplete runBuild() {
    final ref = this.ref as $Ref<AsyncValue<bool>, bool>;
    final element =
        ref.element
            as $ClassProviderElement<
              AnyNotifier<AsyncValue<bool>, bool>,
              AsyncValue<bool>,
              Object?,
              Object?
            >;
    return element.handleCreate(ref, build);
  }
}
