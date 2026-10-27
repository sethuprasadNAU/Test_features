import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/providers/device_lock_provider.dart';

/// Security Model §4.8 control 2, task 10.79. Shown once, non-blockingly, to
/// anyone using this device with no passcode, PIN, pattern or biometric lock
/// configured.
///
/// **Lives on the More screen, not as a banner**, for the same reason task
/// 11.189 moved [CloudBackupRetiredTile] there: a strip above every tab costs
/// real screen height on every launch for every person, most of whom already
/// have a lock set and will never see this render as anything but
/// `SizedBox.shrink()`.
///
/// **Non-blocking by design, not by omission.** §4.8 is explicit that
/// blocking app use on passcode presence is a worse outcome than the
/// exposure this warns about — a field tech mid-survey must never be locked
/// out over a device setting. So this is a tile someone taps into, not a
/// dialog that appears unasked and interrupts whatever screen they were on.
class DeviceLockWarningTile extends ConsumerWidget {
  const DeviceLockWarningTile({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final show = ref.watch(deviceLockWarningNoticeProvider).value ?? false;
    if (!show) return const SizedBox.shrink();

    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.errorContainer,
      child: ListTile(
        key: const ValueKey('device-lock-warning-notice'),
        leading: Icon(Icons.lock_open, color: scheme.onErrorContainer),
        title: Text(
          'This device has no screen lock',
          style: TextStyle(color: scheme.onErrorContainer),
        ),
        subtitle: Text(
          'Tap to read what that means for your data.',
          style: TextStyle(color: scheme.onErrorContainer),
        ),
        trailing: Icon(
          Icons.chevron_right,
          color: scheme.onErrorContainer.withValues(alpha: 0.7),
        ),
        onTap: () => _explain(context, ref),
      ),
    );
  }

  Future<void> _explain(BuildContext context, WidgetRef ref) async {
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('This device has no screen lock'),
        content: const SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'TriTrack relies on this device\'s screen lock to encrypt its '
                'data, and this device has none. Anyone who has it can read '
                'your recorded locations.',
              ),
              SizedBox(height: 12),
              Text(
                'Set a passcode, PIN, pattern, Face ID or fingerprint lock in '
                'system settings to turn that protection on. TriTrack works '
                'either way.',
              ),
              SizedBox(height: 12),
              Text(
                'If a device is lost, removing it in More → Server Connection '
                'cuts off its access at once, lock or no lock.',
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              ref.read(deviceLockWarningNoticeProvider.notifier).dismiss();
              Navigator.of(context).pop();
            },
            child: const Text('Got it'),
          ),
        ],
      ),
    );
  }
}
