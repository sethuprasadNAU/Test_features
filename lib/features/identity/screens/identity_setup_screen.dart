import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/providers/app_context_provider.dart';
import '../../../core/providers/device_id_provider.dart';
import '../../../core/theme/design_tokens.dart';
import '../../../core/providers/recordings_revision_provider.dart';
import '../../../data/repositories/repository_providers.dart';
import '../identity_validation.dart';
import '../../../data/repositories/mutation_authorization.dart';
import '../../../widgets/saving_filled_button.dart';

/// First-run identity capture, and the same screen a placeholder-email
/// device (a fresh install, or one still carrying the auto-created
/// `field-user-<uuid>@local.tritrack` account) is routed to before it can
/// reach the rest of the app. This is **identity, not authentication** —
/// nothing here is verified, it's just a truthful answer to "who is using
/// this device" so cross-device merge/dedup (keyed on email) has something
/// real to match on. See Phase 7 of the development plan.
///
/// Updates the existing local user row in place (`UserRepository.update`)
/// rather than creating a new one — the current `user_id` is already
/// referenced by every observation/tag/project on this device.
class IdentitySetupScreen extends ConsumerStatefulWidget {
  const IdentitySetupScreen({super.key});

  @override
  ConsumerState<IdentitySetupScreen> createState() => _IdentitySetupScreenState();
}

class _IdentitySetupScreenState extends ConsumerState<IdentitySetupScreen> {
  final _formKey = GlobalKey<FormState>();
  final _firstNameController = TextEditingController();
  final _lastNameController = TextEditingController();
  final _emailController = TextEditingController();

  bool _saving = false;

  @override
  void dispose() {
    _firstNameController.dispose();
    _lastNameController.dispose();
    _emailController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      child: Scaffold(
        appBar: AppBar(title: const Text('Set up your identity'), automaticallyImplyLeading: false),
        body: SafeArea(
          child: Form(
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
                        'Who are you? This only labels what you record on this device — '
                        'it is not a sign-in.',
                      ),
                      const SizedBox(height: 8),
                      const Text(
                        'Your name and email let this device\'s records be matched with '
                        'the same person\'s records from another device.',
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
                    ],
                  ),
                ),
                SafeArea(
                  minimum: const EdgeInsets.fromLTRB(
                      DesignTokens.spacingScreenHorizontal, 0, DesignTokens.spacingScreenHorizontal, 12),
                  child: SavingFilledButton(
                    label: 'CONTINUE',
                    onPressed: _saving ? null : _save,
                    saving: _saving,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _save() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;

    setState(() => _saving = true);
    try {
      final existing = await ref.read(currentUserProvider.future);
      final deviceId = await ref.read(deviceIdProvider.future);
      final repo = await ref.read(userRepositoryProvider.future);

      final updated = existing.copyWith(
        firstName: _firstNameController.text.trim(),
        lastName: _lastNameController.text.trim(),
        email: _emailController.text.trim(),
      );
      await repo.update(updated, actor: MutationActor.user(existing.userId), deviceId: deviceId);
      ref.invalidate(currentUserProvider);
      // The log names the author of every bearing out of this `Users` row, so
      // a name typed here has to reach it (task 11.45).
      ref.read(recordingsRevisionProvider.notifier).bump();

      if (!mounted) return;
      context.go('/map');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }
}
