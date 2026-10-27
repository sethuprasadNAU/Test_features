import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/providers/app_context_provider.dart';
import '../../../core/providers/device_id_provider.dart';
import '../../../core/theme/design_tokens.dart';
import '../../../data/models/user.dart';
import '../../../data/repositories/profile_editor.dart';
import '../../../data/repositories/repository_providers.dart';
import '../../../data/repositories/user_email_repository.dart';
import '../../../data/repositories/user_repository.dart';
import '../../../widgets/load_failure.dart';
import '../../../widgets/saving_filled_button.dart';
import '../../identity/identity_validation.dart';

/// View/edit the current device's identity (Phase 7.2) — the counterpart to
/// the non-skippable first-run capture in `IdentitySetupScreen`, reachable
/// any time afterward from More. Still **identity, not authentication**: no
/// verification happens here either.
///
/// Editing the email specifically needs care beyond a normal field edit: it
/// is the cross-device dedup anchor (`ProjectMerger`/`SharedObservationImporter`),
/// so changing it here means anything already exported or shared under the
/// old address won't self-identify as this user to another device unless
/// that old address is retained — see [UserEmailRepository]. The user is
/// warned and must confirm before an email change is written.
class ProfileScreen extends ConsumerStatefulWidget {
  const ProfileScreen({super.key});

  @override
  ConsumerState<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends ConsumerState<ProfileScreen> {
  final _formKey = GlobalKey<FormState>();
  final _firstNameController = TextEditingController();
  final _lastNameController = TextEditingController();
  final _emailController = TextEditingController();

  User? _loadedUser;
  bool _saving = false;

  @override
  void dispose() {
    _firstNameController.dispose();
    _lastNameController.dispose();
    _emailController.dispose();
    super.dispose();
  }

  void _loadFrom(User user) {
    if (_loadedUser?.userId == user.userId) return;
    _loadedUser = user;
    _firstNameController.text = user.firstName;
    _lastNameController.text = user.lastName;
    _emailController.text = user.email;
  }

  @override
  Widget build(BuildContext context) {
    final userAsync = ref.watch(currentUserProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Profile')),
      body: userAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => LoadFailure('your profile', error: e),
        data: (user) {
          _loadFrom(user);
          return _buildForm(context);
        },
      ),
    );
  }

  Widget _buildForm(BuildContext context) {
    return Form(
      key: _formKey,
      autovalidateMode: AutovalidateMode.onUserInteraction,
      child: Column(
        children: [
          Expanded(
            child: ListView(
              padding: const EdgeInsets.symmetric(
                horizontal: DesignTokens.spacingScreenHorizontal,
                vertical: 16,
              ),
              children: [
                const Text(
                  'This is who your observations on this device are attributed to — '
                  'not a login, and nothing here is verified.',
                  style: TextStyle(fontSize: 12),
                ),
                const SizedBox(height: 20),
                TextFormField(
                  controller: _firstNameController,
                  textCapitalization: TextCapitalization.words,
                  decoration: const InputDecoration(
                    labelText: 'First name',
                    border: OutlineInputBorder(),
                  ),
                  validator: (value) => validateRequiredName(value, 'First name'),
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _lastNameController,
                  textCapitalization: TextCapitalization.words,
                  decoration: const InputDecoration(
                    labelText: 'Last name',
                    border: OutlineInputBorder(),
                  ),
                  validator: (value) => validateRequiredName(value, 'Last name'),
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _emailController,
                  keyboardType: TextInputType.emailAddress,
                  decoration: const InputDecoration(
                    labelText: 'Email',
                    border: OutlineInputBorder(),
                  ),
                  validator: validateEmail,
                ),
                const SizedBox(height: 8),
                Text(
                  'Changing your email affects how your records are matched with '
                  'the same person\'s records from another device — you\'ll be asked '
                  'to confirm.',
                  style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant),
                ),
                const SizedBox(height: 20),
                const _WhereSignInLivesNotice(),
              ],
            ),
          ),
          SafeArea(
            minimum: const EdgeInsets.fromLTRB(
                DesignTokens.spacingScreenHorizontal, 0, DesignTokens.spacingScreenHorizontal, 12),
            child: SavingFilledButton(
              label: 'SAVE',
              onPressed: _saving ? null : _save,
              saving: _saving,
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _save() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    final existing = _loadedUser;
    if (existing == null) return;

    final newEmail = _emailController.text.trim();
    final emailChanged =
        UserRepository.normalizeEmail(newEmail) != UserRepository.normalizeEmail(existing.email);

    if (emailChanged) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Change email?'),
          content: Text(
            'Backups and shared records you have already sent carry your current '
            'address (${existing.email}), and will still show that old address.',
          ),
          actions: [
            TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancel')),
            FilledButton(
                onPressed: () => Navigator.of(context).pop(true), child: const Text('Change email')),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;
    }

    setState(() => _saving = true);
    try {
      final deviceId = await ref.read(deviceIdProvider.future);
      final userRepo = await ref.read(userRepositoryProvider.future);
      final userEmailRepo = await ref.read(userEmailRepositoryProvider.future);

      await ProfileEditor(userRepo, userEmailRepo).apply(
        existing: existing,
        firstName: _firstNameController.text.trim(),
        lastName: _lastNameController.text.trim(),
        email: newEmail,
        deviceId: deviceId,
      );
      ref.invalidate(currentUserProvider);

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Profile updated')),
      );
      Navigator.of(context).maybePop();
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }
}

/// **Task 11.37, item 2 — the one line this screen was missing.**
///
/// This screen asks for an email address and offers Save. So does Server
/// Connection, and only that one signs you in. Somebody looking for sign-in
/// finds this screen first (it is higher up the More list, and it says
/// "Email"), fills it in, saves, and reasonably concludes that sign-in either
/// worked or was never built. That is what happened on 2026-08-26.
///
/// **The email on this screen is not the defect and does not move.** It is
/// local identity — who observations recorded here are attributed to — it is
/// required on first run, and it works with no server and no network at all,
/// which is the whole point of an offline-first field app. The two fields
/// genuinely are different things. Nothing said so.
///
/// Tappable rather than a sentence naming the screen, because a person who has
/// just been told sign-in is somewhere else should not then have to go and
/// find it.
class _WhereSignInLivesNotice extends StatelessWidget {
  const _WhereSignInLivesNotice();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: () => context.push('/more/server'),
      borderRadius: BorderRadius.circular(8),
      child: Container(
        constraints: const BoxConstraints(
          minHeight: DesignTokens.minTouchTarget,
        ),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          children: [
            Icon(Icons.dns_outlined, color: scheme.onSurfaceVariant),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                'Looking for sign-in? It is under More \u2192 Server '
                'Connection. This address is only how this device labels '
                'your own records.',
                style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
              ),
            ),
            Icon(Icons.chevron_right, color: scheme.onSurfaceVariant),
          ],
        ),
      ),
    );
  }
}
