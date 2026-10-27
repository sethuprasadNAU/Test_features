import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/providers/auth_provider.dart';
import '../../../core/providers/server_config_provider.dart';
import '../../../data/auth/auth_client.dart';
import '../../../data/auth/session_store.dart';
import '../../../data/sync/server_identity_adopter.dart';
import '../../../core/errors/failure_message.dart';
import '../../../core/errors/transport_failure.dart';
import '../../../widgets/load_failure.dart';
import '../../../widgets/saving_filled_button.dart';
import '../../../core/theme/design_tokens.dart';

/// View/edit the server this device syncs with (task 10.2). "Not configured"
/// is the default and a fully supported mode, not an error — this screen
/// exists to make switching *into* server-optional connectivity a typed URL,
/// never a rebuild, and to say plainly when there is no server at all.
///
/// Deliberately does not claim "Connected": nothing here checks reachability
/// (that arrives with the server itself, task 10.3+) — only whether a URL has
/// been saved.

/// What to tell somebody when the server **did** answer, and said no.
///
/// Split out and given a name so it can be asserted directly by a test — the
/// original conflation was in a `catch` block with no way to reach it except
/// through a whole screen (task 11.37).
///
/// Each branch names a different thing to go and check, which is the entire
/// point: a person with no terminal has only this sentence to work from.
String serverAnsweredWithErrorMessage(AuthServerError error) {
  if (error.isNotFound) {
    // The reproduced case. `http://host:8080/` + `/auth/magic-link` is
    // `//auth/magic-link`, and the server answers 404 — so this wording leads
    // with the trailing slash, which is the cause far more often than a
    // server that genuinely lacks the route.
    return 'The server answered, but it has no sign-in service at that '
        'address. Check that the Server URL above ends at the port, like '
        'http://192.168.1.42:8080, with no slash after it. Nothing was '
        'changed.';
  }
  if (error.isRateLimited) {
    // Deliberately about *this device*, because that is what a 429 means
    // here. The per-address limit is invisible by design and never lands
    // in this branch — see `AuthServerError.isRateLimited`.
    return 'Too many sign-in attempts from this device. Wait about fifteen '
        'minutes and try again. Nothing was changed.';
  }
  if (error.isServerFault) {
    return 'The server was reached but hit a problem of its own (error '
        '${error.statusCode}) — not your network or this device. Tell '
        'TriTrack support (More → App Info). Nothing was changed.';
  }
  if (error.isInvalidEmail) {
    // Task 11.298. The server's mail path carries plain-ASCII addresses only,
    // and its boundary now says so instead of answering 202 and sending
    // nothing. This is about the email address the person typed — the
    // generic branch below says "the address", and on this screen that word
    // means the Server URL, which is not what is wrong.
    return 'The server will not send a sign-in code to that email address. '
        'Check it for a typo. This server cannot send to accented or '
        'non-Latin characters, quotes or brackets — use a different address, '
        'or contact TriTrack support (More → App Info). Nothing was '
        'changed.';
  }
  return 'The server was reached and refused the request (error '
      '${error.statusCode}). Your network is working; check the address, or '
      "the server's own state. Nothing was changed.";
}

/// The reassurance clause this screen adds to a classified transport
/// failure, and the reason [TransportFailure.explanation] does not carry one.
///
/// **Task 11.113 merged this screen's certificate classification with the sync
/// engine's.** Everything about *why* a request failed is decided in
/// `lib/core/errors/transport_failure.dart` and consumed here; what a failure
/// meant for the person's data is this screen's own to say, because it is a
/// different sentence on the sync surface ("Nothing on this device has been
/// changed or lost" — the person was not mid-action there, and the worry is
/// their records, not this form).
String transportFailureMessage(TransportFailure failure) =>
    '${failure.explanation} Nothing was changed.';

/// Shown when nothing at all is known about a failure.
///
/// **What is left here, enumerated for task 11.108** rather than left as an
/// unexamined "everything else": every domain-typed exception raised by
/// `AuthClient`, `CurrentSession`, `SessionStore` or `ServerIdentityAdopter`
/// has its own catch. What can still arrive is a fault in this app's own
/// code — a `TypeError` or `StateError` from a library or a bug — which
/// genuinely carries no actionable cause.
///
/// **This used to say that nothing in `requestLink` or `completeSignIn` could
/// time out, "neither calls `.timeout()`". That became false on 2026-09-03**
/// (task 11.61): every request the app sends now carries a deadline, applied
/// at the client seam rather than at a call site, so a sign-in against a
/// server that goes quiet gives up after thirty seconds. It does **not** reach
/// this fallback — `RequestGaveUp` is classified by
/// `classifyTransportFailure`, like every other request that never produced a
/// response, and lands on [transportFailureMessage] a few lines above.
const String _unknownFault =
    'Sign-in did not finish, and this device could not tell why. Nothing was '
    'changed. If it keeps happening, note what you had just tapped.';

class ServerConfigScreen extends ConsumerStatefulWidget {
  const ServerConfigScreen({super.key});

  @override
  ConsumerState<ServerConfigScreen> createState() => _ServerConfigScreenState();
}

class _ServerConfigScreenState extends ConsumerState<ServerConfigScreen> {
  final _formKey = GlobalKey<FormState>();
  final _urlController = TextEditingController();

  String? _loadedUrl;
  bool _saving = false;

  @override
  void dispose() {
    _urlController.dispose();
    super.dispose();
  }

  void _loadFrom(ServerConfig config) {
    if (_loadedUrl == config.baseUrl) return;
    _loadedUrl = config.baseUrl;
    _urlController.text = config.baseUrl ?? '';
  }

  @override
  Widget build(BuildContext context) {
    final configAsync = ref.watch(serverConfigProvider);
    final refusalAsync = ref.watch(serverUrlRefusalProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Server Connection')),
      body: configAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => LoadFailure('your server settings', error: e),
        data: (config) {
          _loadFrom(config);
          // **Waited for rather than defaulted to "no problem"** (task
          // 11.104). `refusalAsync.value` is null both while it is being
          // computed and when the address is fine, and rendering the second
          // reading of the first would flash "Server configured" onto the
          // header this task exists to correct.
          return refusalAsync.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (e, _) => LoadFailure('your server settings', error: e),
            data: (refusal) => _buildForm(context, config, refusal),
          );
        },
      ),
    );
  }

  Widget _buildForm(
    BuildContext context,
    ServerConfig config,
    ServerUrlProblem? refusal,
  ) {
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
                _StatusBanner(config: config, refusal: refusal),
                const SizedBox(height: 20),
                TextFormField(
                  controller: _urlController,
                  keyboardType: TextInputType.url,
                  autocorrect: false,
                  decoration: InputDecoration(
                    labelText: 'Server URL',
                    // **The hint must not propose an address this build will
                    // refuse** (task 11.104). It read `http://192.168.1.42:8080`
                    // in every build, which is the LAN address `README.md` §4
                    // ends in and exactly the value a release build says no to
                    // — a field offering an example it then rejects.
                    hintText: ref.watch(nonDebugBuildProvider)
                        ? 'https://tracker.example.edu'
                        : 'http://192.168.1.42:8080',
                    border: const OutlineInputBorder(),
                  ),
                  validator: validateServerUrl,
                ),
                const SizedBox(height: 8),
                Text(
                  'Leave this blank to work fully offline, with nothing synced '
                  'anywhere. Every feature works the same either way.',
                  style: TextStyle(
                    fontSize: 12,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
                // **Task 11.324: the way back to the central server**, once
                // somebody has typed another address or cleared the field.
                // Absent while the app ships no central address, and while it
                // is already the one in use. Fills the field; SAVE still
                // decides, like every other change on this screen.
                if (_central(config) case final central?)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton(
                      onPressed: () =>
                          setState(() => _urlController.text = central),
                      child: const Text('Use the TriTrack server'),
                    ),
                  ),
                if (config.isConfigured) ...[
                  const Divider(height: 40),
                  _SignInSection(refusal: refusal),
                ],
              ],
            ),
          ),
          SafeArea(
            minimum: const EdgeInsets.fromLTRB(
              DesignTokens.spacingScreenHorizontal,
              0,
              DesignTokens.spacingScreenHorizontal,
              12,
            ),
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

  /// The central server's address when it is worth offering, or null.
  String? _central(ServerConfig config) {
    final central = normalizeServerBaseUrl(
      ref.watch(centralServerAddressProvider),
    );
    return central.isEmpty || central == config.baseUrl ? null : central;
  }

  Future<void> _save() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    setState(() => _saving = true);
    try {
      await ref.read(serverConfigProvider.notifier).setUrl(_urlController.text);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            _urlController.text.trim().isEmpty
                ? 'Server cleared — working offline'
                : 'Server URL saved',
          ),
        ),
      );
      Navigator.of(context).maybePop();
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }
}

/// The one-line answer to "what is this device set up to do?", at the top of
/// the screen that decides it.
///
/// **It used to say "Server configured" whether or not the configuration was
/// usable** (task 11.104). On a release build with a plain-`http://` LAN
/// address, task 11.66 measured this header still reading *"Server configured:
/// http://192.168.0.136:8080"* while the sync bar said "Offline" and the
/// device list said nothing had answered — three surfaces, one fact, three
/// different stories, and **this was the one that read as reassurance.**
/// "Configured" is not a synonym for "saved": a value this build refuses to
/// use is stored, and it is not configuration.
class _StatusBanner extends StatelessWidget {
  const _StatusBanner({required this.config, required this.refusal});

  final ServerConfig config;

  /// Why this build will not use [config], or null if it will. From
  /// `serverUrlRefusalProvider` — the same value the sync bar and the sync
  /// status screen read, which is what stops the three disagreeing again.
  final ServerUrlProblem? refusal;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final problem = refusal;
    if (problem != null) {
      return Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: scheme.errorContainer,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // `link_off`, matching the sync bar and the sync status screen, and
            // deliberately not a cloud: every cloud icon in this app means "no
            // connection", which is the reading being corrected.
            Icon(Icons.link_off, color: scheme.onErrorContainer),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    // Says what is true — an address is saved — and refuses in
                    // the same breath to call it working.
                    'Saved, but this app will not use it: ${config.baseUrl}',
                    style: TextStyle(
                      color: scheme.onErrorContainer,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    problem.message,
                    style: TextStyle(color: scheme.onErrorContainer),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    }
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Icon(
            config.isConfigured ? Icons.dns_outlined : Icons.cloud_off,
            color: scheme.onSurfaceVariant,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              config.isConfigured
                  ? 'Server configured: ${config.baseUrl}'
                  : 'Not configured — working fully offline',
              style: TextStyle(color: scheme.onSurfaceVariant),
            ),
          ),
        ],
      ),
    );
  }
}

/// Sign-in / sign-out, shown only once a server URL exists — there is nothing
/// to sign in *to* before that.
///
/// Signed out is presented as a normal state, not a problem: the app is fully
/// usable either way, and the copy says so rather than nagging.
class _SignInSection extends ConsumerStatefulWidget {
  const _SignInSection({required this.refusal});

  /// Why this build will not use the saved address, or null if it will.
  ///
  /// **Everything in this section that talks to the server is inert when this
  /// is set**, and task 11.104's job is that the section says so in those
  /// words rather than letting each control fail and describe the failure as a
  /// network fault. Signing out is the exception, and stays enabled: it clears
  /// this device's own stored session whether or not the server can be
  /// reached, and hiding it would trap somebody signed in to a server their
  /// build refuses to talk to.
  final ServerUrlProblem? refusal;

  @override
  ConsumerState<_SignInSection> createState() => _SignInSectionState();
}

class _SignInSectionState extends ConsumerState<_SignInSection> {
  final _emailController = TextEditingController();
  final _codeController = TextEditingController();

  String? _requestId;
  bool _busy = false;

  @override
  void dispose() {
    _emailController.dispose();
    _codeController.dispose();
    super.dispose();
  }

  // Surfaced via SnackBar rather than inline text: this section sits below
  // the URL field and a divider in a scrollable column, so inline feedback
  // can land below the fold on a phone-sized screen. A SnackBar is shown
  // wherever the user is actually looking, right after they tap the button
  // that triggered it.
  void _showMessage(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _run(Future<void> Function() action, String onSuccess) async {
    setState(() => _busy = true);
    try {
      await action();
      _showMessage(onSuccess);
    } on IdentityMismatch {
      _showMessage(
        'That code belongs to a different account than the address you '
        'entered, and it is now used up. Request a new one. Nothing was '
        'changed.',
      );
    } on IdentityAdoptionRefused catch (e) {
      // Distinct from the generic catch below on purpose: "could not reach the
      // server" would be a lie here — the server was reached and answered, and
      // this device declined the answer. The reason text is written to be
      // shown and carries no server-chosen value (§4.20).
      _showMessage('${e.reason} You are still signed out.');
    } on RedemptionRejected {
      // The server does not distinguish unknown, already-used, and expired —
      // so neither does this. Saying "already used" would confirm a guessed
      // code had once been real.
      _showMessage('That sign-in code did not work. Request a new one.');
    } on SessionStorageUnavailable catch (e, stackTrace) {
      // **Task 11.38.** Caught before the generic handler because "could not
      // reach the server" is not merely unhelpful here, it is false, and it
      // sends somebody off to check their network for hours. `completeSignIn`
      // runs this check *before* redeeming, so reaching this means the code
      // was never sent and is still good — which is the one fact worth
      // leading with.
      if (kDebugMode) {
        debugPrint('Secure storage unavailable: ${e.cause}\n$stackTrace');
      }
      _showMessage(
        'This device cannot store a sign-in securely, so nothing was sent. '
        'Your code has not been used and still works. On a Mac, see "Signing '
        'the macOS build" in README.md.',
      );
    } on SessionStorageFailedAfterRedemption catch (e, stackTrace) {
      // The rare half of 11.38: the store passed its check and then failed
      // anyway. Says the code is gone, because it is, and says storage is
      // why, because somebody told only "sign-in failed" will spend the next
      // attempt on a fresh code and land here again.
      if (kDebugMode) {
        debugPrint('Storage failed after redemption: ${e.cause}\n$stackTrace');
      }
      _showMessage(
        'This device could not store the sign-in, so the code is now used up '
        'and you are still signed out. The problem is this device, not with '
        'the server or the code.',
      );
    } on AuthServerError catch (e, stackTrace) {
      // **Task 11.37.** The server was reached and answered. Saying "could not
      // reach the server" here is not vague, it is wrong — it names the
      // network, so that is where somebody goes looking, and the network is
      // fine. See [serverAnsweredWithErrorMessage] for what each status is
      // told to mean.
      if (kDebugMode) {
        debugPrint('Auth server answered ${e.statusCode}: $e\n$stackTrace');
      }
      _showMessage(serverAnsweredWithErrorMessage(e));
    } on AuthProtocolException catch (e, stackTrace) {
      // The server answered, but not with anything this build understands —
      // in practice, something between this device and the server (a proxy,
      // a load balancer) answering in its own words instead of forwarding
      // the request. Found reaching this same catch-all alongside
      // [HandshakeException] while enumerating it for task 11.108.
      if (kDebugMode) {
        debugPrint('Auth response malformed: $e\n$stackTrace');
      }
      _showMessage(
        'The server address was reached, but it did not answer the way this '
        'app expects — usually a proxy in front of the server is answering '
        'instead. Nothing was changed.',
      );
    } catch (e, stackTrace) {
      // **One classifier, consumed here** (task 11.113). Until this, four
      // separate `on` clauses above decided which transport failure was which
      // — `SocketException`, `NSErrorClientException`, `http.ClientException`,
      // `HandshakeException` — and the sync engine could not reach a single
      // one of them, so the same rejected certificate read as a named
      // certificate fault here and as "Offline" on the sync bar. Everything
      // those four clauses knew now lives in `classifyTransportFailure`, which
      // both surfaces call.
      //
      // It returns null for anything that is not a transport failure at all,
      // and that is the [_unknownFault] case: a fault in this app's own code,
      // which genuinely carries no actionable cause. Saying so honestly is the
      // corrigible half of the old blanket message; the confident wrong
      // guesses it also produced have been peeled off.
      if (kDebugMode) {
        debugPrint('Sign-in action failed: $e\n$stackTrace');
      }
      final transport = classifyTransportFailure(e);
      _showMessage(
        transport == null ? _unknownFault : transportFailureMessage(transport),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// The reason to append to a control that failed, when there is one.
  ///
  /// **The refusal is checked before the exception** (task 11.104): when this
  /// build will not use the saved address, no request left the device, so
  /// nothing the exception says about the far end can be true. Both of the
  /// controls that use this are ones somebody reaches for believing their
  /// credentials are compromised — the worst possible place to be handed a
  /// cause that sends them to check their network.
  String _becauseOf(Object error) {
    final refusal = widget.refusal;
    if (refusal != null) return ' ${refusal.message}';
    if (error is AuthServerError) {
      return ' ${serverAnsweredWithErrorMessage(error)}';
    }
    if (error is AuthProtocolException) {
      return ' The server answered in a way this app does not understand — '
          'check for a proxy in front of it.';
    }
    // **Task 11.108, extended by 11.112, merged by 11.113.** These two
    // controls hit the same server and the same certificate as sign-in,
    // through a `catch (Object)` that was a second place the fix could fall
    // through to an unnamed cause. They now consume the same classification
    // sign-in does, so a cause taught to it reaches them without anybody
    // remembering to come here.
    final transport = classifyTransportFailure(error);
    if (transport != null) return ' ${transportFailureMessage(transport)}';
    return '';
  }

  /// Confirms, then revokes every session this person holds (task 11.28).
  ///
  /// Confirmed first because it signs *this* device out too, and on a field
  /// device at the end of a track that is a real cost — not a reason to skip
  /// the control, but a reason not to fire it on one tap.
  ///
  /// Not routed through [_run]: that helper reports "could not reach the
  /// server" and moves on, which is right for signing out locally and wrong
  /// here. Somebody who reaches for this believes their credentials are
  /// compromised, and a failure they read as success is the worst outcome the
  /// control has.
  Future<void> _signOutEverywhere() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Sign out everywhere?'),
        content: const Text(
          'Every device you are signed in on stops syncing now, including '
          'this one. Nothing is deleted: each device keeps what it holds.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Sign out everywhere'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _busy = true);
    try {
      final revoked = await ref
          .read(currentSessionProvider.notifier)
          .signOutEverywhere();
      _showMessage(
        revoked == 1
            ? 'Signed out. 1 sign-in was ended.'
            : 'Signed out. $revoked sign-ins were ended.',
      );
    } catch (e, stackTrace) {
      if (kDebugMode) {
        debugPrint('Sign out everywhere failed: $e\n$stackTrace');
      }
      // Says plainly that nothing happened. The alternative — a generic
      // "could not reach the server" — leaves somebody believing a
      // compromised token has been revoked when it has not.
      //
      // Task 11.37 adds the *reason* on the end where there is one, for the
      // same reason it split the sign-in messages: somebody reaching for this
      // control believes their credentials are compromised, and "try again"
      // is not an instruction they can follow twice.
      _showMessage(
        'Could not sign out everywhere: the server did not confirm it. Your '
        'other devices are still signed in.${_becauseOf(e)}',
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Confirms, then ends every session on one device (task 11.36).
  ///
  /// **Two different confirmations, because they are two different acts.**
  /// Cutting off a device you no longer hold costs you nothing; cutting off
  /// the one in your hand signs you out of it, and on a field device at the
  /// end of a track that is a real cost. The dialog says which one is about to
  /// happen rather than making somebody infer it from a row they tapped.
  ///
  /// **Revoking this device is a success, not a failure**, and the message has
  /// to say so — the session is gone, so the screen behind it flips to signed
  /// out, and without a sentence explaining that, the most likely reading of a
  /// screen that suddenly says "Sign in to sync" is that something went wrong.
  Future<void> _revokeDevice(DeviceSession session) async {
    final isThisDevice = session.isCurrentDevice;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(
          isThisDevice ? 'Sign out this device?' : 'Sign out that device?',
        ),
        content: Text(
          isThisDevice
              // Same three facts the "sign out everywhere" dialog gives, for
              // the one device.
              ? 'This device stops syncing and you will be signed out here. '
                    'Nothing is deleted, and the app keeps working offline.'
              : 'That device stops syncing the next time it tries, until '
                    'somebody signs in on it. This device is not affected.'
                    '\n\nIt keeps the project data already downloaded onto '
                    'it; that cannot be removed from here.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Sign out'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _busy = true);
    try {
      await ref
          .read(currentSessionProvider.notifier)
          .revokeDevice(session.deviceId);
      _showMessage(
        isThisDevice
            ? 'Signed out on this device. Everything already here is '
                  'untouched, and you can sign in again below.'
            : 'That device is signed out. It stops syncing on its next '
                  'attempt.',
      );
    } catch (e, stackTrace) {
      if (kDebugMode) {
        debugPrint('Revoking ${session.deviceId} failed: $e\n$stackTrace');
      }
      // Never a bare "try again": somebody using this believes a device is
      // where it should not be, and a failure they read as success is the
      // worst outcome this control has. Same reasoning as
      // [_signOutEverywhere], including borrowing its reason text.
      _showMessage(
        'That device was not signed out — the server did not confirm it. It '
        'is still able to sync.${_becauseOf(e)}',
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final sessionAsync = ref.watch(currentSessionProvider);
    final scheme = Theme.of(context).colorScheme;

    return sessionAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Text(
        e is SessionStorageUnavailable
            // Task 11.38, the same failure on the read side. A raw
            // `PlatformException` with an OSStatus inside it tells a
            // biologist nothing; the build being unsigned is the actionable
            // part.
            ? 'This device cannot read stored sign-ins securely, so it cannot '
                  'tell whether you are signed in. Everything else in the app '
                  'works normally. On a Mac, see "Signing the macOS build" in '
                  'README.md.'
            : describeFailure(
                e,
                fallback:
                    'Could not tell whether you are signed in. Everything '
                    'else works normally. Leave this screen and come back to '
                    'check again.',
              ),
      ),
      data: (session) {
        if (session != null) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Signed in as ${session.email}',
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 8),
              Text(
                'Signing out stops syncing. Everything on this device stays '
                'and keeps working.',
                style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
              ),
              const SizedBox(height: 12),
              OutlinedButton(
                onPressed: _busy
                    ? null
                    : () => _run(
                        () =>
                            ref.read(currentSessionProvider.notifier).signOut(),
                        'Signed out',
                      ),
                child: const Text('SIGN OUT'),
              ),
              const Divider(height: 32),
              // **Task 11.36, over the route task 11.35 built.** Per-device
              // sign-out has existed and been correct since task 10.14 and
              // nothing called it, because a device knows only its own id and
              // there was no way to learn the others. There is now.
              _SignedInDevices(
                enabled: !_busy,
                onRevoke: _revokeDevice,
                refusal: widget.refusal,
              ),
              const Divider(height: 32),
              // **Task 11.28, parts 2 and 3.** The security model names
              // "sign out everywhere" as the answer both to "I think somebody
              // has my token" (§4.3) and to a lost or stolen device (§4.8).
              // The route has been built and correct since task 10.14 and no
              // screen called it, so until now the answer to both was that the
              // person could do nothing at all.
              Text(
                'Lost a device, or think somebody has your sign-in?',
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 8),
              Text(
                // Three facts, and the third is the one people get wrong.
                // Revoking a session stops a device *syncing*; it does not
                // reach into it and delete the season of coordinates it has
                // already downloaded. That is the same truth the members
                // screen tells an owner about removing somebody, and it is
                // more important here, because the device in question is in
                // somebody else's hands.
                'Signs out every device you use, including this one — use it '
                'if a device is lost. A lost device keeps the data it already '
                'downloaded; that cannot be removed from here.',
                style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
              ),
              const SizedBox(height: 12),
              OutlinedButton(
                style: OutlinedButton.styleFrom(foregroundColor: scheme.error),
                onPressed: _busy ? null : _signOutEverywhere,
                child: const Text('SIGN OUT EVERYWHERE'),
              ),
            ],
          );
        }

        final refusal = widget.refusal;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Sign in to sync',
              style: TextStyle(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            Text(
              'Optional. Recording, maps and position estimates all work '
              'without signing in.',
              style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
            ),
            // **Explained and disabled, not hidden** (task 11.12's rule, and
            // task 11.104's screen). Signing in cannot work while this build
            // refuses the saved address, and letting somebody type an email,
            // tap, and read a failure message is how the wrong cause gets
            // learned. The reason sits above the controls it disables.
            if (refusal != null) ...[
              const SizedBox(height: 12),
              Text(
                'Signing in is unavailable until the server address above is '
                'changed. ${refusal.message}',
                style: TextStyle(fontSize: 12, color: scheme.error),
              ),
            ],
            const SizedBox(height: 12),
            TextField(
              controller: _emailController,
              keyboardType: TextInputType.emailAddress,
              autocorrect: false,
              decoration: const InputDecoration(
                labelText: 'Email',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            OutlinedButton(
              onPressed: _busy || refusal != null
                  ? null
                  : () => _run(
                      () async {
                        final request = await ref
                            .read(currentSessionProvider.notifier)
                            .requestLink(_emailController.text);
                        _requestId = request.requestId;
                      },
                      'A sign-in code was requested. Paste it below once you '
                      'have it.',
                    ),
              child: const Text('REQUEST A SIGN-IN CODE'),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _codeController,
              autocorrect: false,
              decoration: const InputDecoration(
                labelText: 'Sign-in code',
                helperText: 'Paste the code, or the whole link',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            FilledButton(
              onPressed: _busy || refusal != null
                  ? null
                  : () => _run(
                      () => ref
                          .read(currentSessionProvider.notifier)
                          .completeSignIn(
                            _codeController.text,
                            expectedEmail: _emailController.text,
                          ),
                      'Signed in',
                    ),
              child: const Text('SIGN IN THIS DEVICE'),
            ),
            if (_requestId != null) ...[
              const SizedBox(height: 8),
              // **This screen used to say "Check your email", and no server
              // this project can build sends one** (task 11.119). There are
              // two senders: one writes the link to a file for development,
              // and one accepts the message and discards it. `/auth/magic-link`
              // answers the identical `202` either way, because §4.5 requires
              // it to — so the app cannot know how a code reaches anybody, and
              // **the branch that does not know must not assert a cause.**
              //
              // Deliberately not "this server does not send email", which is
              // true of every deployment today and would become false on every
              // phone still running this build the day somebody adds a mail
              // sender. That is the class the survey this came from exists to
              // stop: correct when written, silently falsified later. An
              // honest default costs nothing to maintain.
              //
              // **Task 11.115, item A.** The screen used to stop at "ask
              // whoever runs the server for it" and never said how long a
              // wait is normal — nothing distinguished an outage from an
              // ordinary delay. It still can't (task 11.119: the server's
              // response is identical either way, on purpose), so the added
              // sentence says that directly instead of naming a duration or
              // a retry count, either of which would read as the app
              // knowing something it doesn't.
              Text(
                'If no code arrives, contact TriTrack support (More → App '
                'Info) — this app cannot tell how this server delivers codes, '
                'or how long that takes.',
                style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
              ),
              const SizedBox(height: 8),
              Text(
                'The device you paste the code into is the one that gets '
                'signed in.',
                style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
              ),
            ],
          ],
        );
      },
    );
  }
}

/// **Your own signed-in devices, most recently used first** (task 11.36).
///
/// ## Why the rows say what they say
///
/// Task 11.35 built the route and asked the right question about it: a list of
/// five opaque identifiers is not something a person can pick their lost phone
/// out of. The answer taken here is **not** to add a device label. A label is a
/// schema change *and* a new piece of free text the phone chooses and this
/// screen then displays, which brings length bounds, control characters and
/// every other question this project has already paid for once on imported
/// text — a large new surface for a convenience.
///
/// What the server already records and the phone cannot choose does the job:
/// **last used** leading the row, because that is what actually distinguishes
/// your devices from each other; **signed in on** underneath it; and **this
/// device** marked plainly so nobody signs themselves out while trying to sign
/// out something else. If that turns out genuinely insufficient in use, a label
/// becomes a considered follow-up rather than the first thing reached for.
///
/// The device id is shown last and small. It is the only thing that is
/// literally unique, and on a screen where somebody is about to cut a device
/// off, having *something* to compare against the other device is worth the
/// clutter — but it leads nothing, because it identifies nothing to a person.
///
/// ## Refreshing
///
/// The list is re-read after every revocation and whenever the signed-in state
/// changes, because a stale list here is a list offering to revoke a session
/// that is already gone. It watches `currentSessionProvider` for that reason
/// rather than for the session's contents.
class _SignedInDevices extends ConsumerStatefulWidget {
  const _SignedInDevices({
    required this.enabled,
    required this.onRevoke,
    required this.refusal,
  });

  /// False while the parent is mid-action, so two revocations cannot overlap.
  final bool enabled;

  final Future<void> Function(DeviceSession) onRevoke;

  /// Why this build will not use the saved address, or null if it will.
  ///
  /// **The list is not fetched at all when this is set.** Task 11.66 measured
  /// this section reporting *"Could not read your signed-in devices — nothing
  /// answered at that address"* on a network where the server answered
  /// `/health` throughout and map tiles kept loading. Nothing had answered
  /// because nothing had been asked: this device refused to build a client for
  /// the address. Asking anyway, and then describing the refusal as silence
  /// from the far end, is the wrong-cause defect in its purest form.
  final ServerUrlProblem? refusal;

  @override
  ConsumerState<_SignedInDevices> createState() => _SignedInDevicesState();
}

class _SignedInDevicesState extends ConsumerState<_SignedInDevices> {
  // **Held as a result rather than as a `Future` for a FutureBuilder**, and
  // that is not a style preference. A future created in a post-frame callback
  // can complete with an error *before* the frame that hands it to a
  // FutureBuilder, and Dart reports an error on a future nobody is listening
  // to yet as unhandled — so the screen rendered its error message correctly
  // and the test run failed anyway, on an exception the widget had already
  // dealt with. Awaiting it here means there is never a moment when the
  // failure has nowhere to go.
  List<DeviceSession>? _sessions;
  Object? _error;
  Object? _watched;
  bool _asked = false;

  Future<void> _reload() async {
    if (!mounted) return;
    setState(() => _error = null);
    try {
      final sessions = await ref
          .read(currentSessionProvider.notifier)
          .listSessions();
      if (!mounted) return;
      setState(() => _sessions = sessions);
    } catch (e, stackTrace) {
      if (kDebugMode) {
        debugPrint('Reading signed-in devices failed: $e\n$stackTrace');
      }
      if (!mounted) return;
      // The old list is dropped rather than left on screen: rows offering to
      // revoke sessions this device can no longer confirm exist are worse
      // than no rows, and the message below says which of the two happened.
      setState(() {
        _sessions = null;
        _error = e;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    // Re-read whenever the stored session changes — including the moment a
    // revocation of *this* device clears it, which is what stops the list
    // outliving the credential it was fetched with.
    final session = ref.watch(currentSessionProvider).value;
    // Not asked at all when this build refuses the address — see [refusal].
    if (widget.refusal == null && (!_asked || !identical(session, _watched))) {
      _asked = true;
      _watched = session;
      // Deferred: `build` must not call `setState`.
      WidgetsBinding.instance.addPostFrameCallback((_) => _reload());
    }

    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text(
          'Devices you are signed in on',
          style: TextStyle(fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 8),
        Text(
          // **The first sentence exists because somebody asked** (2026-08-29,
          // on the first run of this screen on real hardware). Signed in on a
          // Mac and an iPhone under two *different* addresses, each device
          // listed only itself — correct, and the reading it invited was
          // "should my teammate's devices be here too?" The heading alone does
          // not settle that, and the question is worth settling on the screen
          // rather than in a support conversation.
          //
          // **It deliberately does not point anywhere.** The obvious follow-on
          // — "your teammates are on the Members screen" — is false for most
          // readers: Members is owner-only (`projects_screen.dart`), and this
          // screen is not project-scoped anyway, so it cannot know whether the
          // person reading it owns anything. A sentence that is true for
          // everybody and points nowhere beats one that points somewhere half
          // the audience cannot go.
          "Only your own devices. A teammate's devices never appear here. "
          'Signing one out stops it syncing the next time it tries.',
          style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
        ),
        const SizedBox(height: 12),
        _body(scheme),
      ],
    );
  }

  Widget _body(ColorScheme scheme) {
    final refusal = widget.refusal;
    if (refusal != null) {
      return Text(
        'No devices are listed because this device will not connect to the '
        'address saved above — not because you have none. '
        '${refusal.message}',
        style: TextStyle(fontSize: 12, color: scheme.error),
      );
    }
    final error = _error;
    if (error != null) {
      // Same rule as everywhere else on this screen: never blame the network
      // for something the server answered. What is deliberately *not* said is
      // "you have no other devices" — an unknown list must not read as an
      // empty one, which is a check that cannot tell success from its own
      // failure, rendered as copy.
      return Text(
        error is AuthServerError
            ? 'Could not read your signed-in devices. '
                  '${serverAnsweredWithErrorMessage(error)}'
            : 'Could not read your signed-in devices — nothing answered at '
                  'that address. That does not mean there are none.',
        style: TextStyle(fontSize: 12, color: scheme.error),
      );
    }
    final sessions = _sessions;
    if (sessions == null) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 12),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (sessions.isEmpty) {
      return Text(
        'No signed-in devices to show.',
        style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final session in sessions)
          _DeviceRow(
            session: session,
            enabled: widget.enabled,
            onRevoke: () async {
              await widget.onRevoke(session);
              await _reload();
            },
          ),
      ],
    );
  }
}

class _DeviceRow extends StatelessWidget {
  const _DeviceRow({
    required this.session,
    required this.enabled,
    required this.onRevoke,
  });

  final DeviceSession session;
  final bool enabled;
  final Future<void> Function() onRevoke;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        'Last used ${_when(session.lastSeenAt)}',
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                    ),
                    if (session.isCurrentDevice) ...[
                      const SizedBox(width: 8),
                      // Plain words rather than a coloured dot: this is the
                      // one thing on the row that changes what tapping REVOKE
                      // does to the person reading it.
                      Text(
                        'This device',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          color: scheme.primary,
                        ),
                      ),
                    ],
                  ],
                ),
                Text(
                  'Signed in ${_when(session.firstSignedInAt)}',
                  style: TextStyle(
                    fontSize: 12,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                Text(
                  session.deviceId,
                  style: TextStyle(
                    fontSize: 11,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          TextButton(
            // Keyed because "SIGN OUT" is also the account-level control a few
            // lines up this screen. Found by writing the test: it tapped the
            // second button with that label expecting the second *device*, and
            // signed the account out instead — which is the exact confusion
            // the "This device" marking exists to prevent, reproduced in a
            // test file rather than by a person.
            key: ValueKey('revoke-device-${session.deviceId}'),
            style: TextButton.styleFrom(foregroundColor: scheme.error),
            onPressed: enabled ? onRevoke : null,
            child: const Text('SIGN OUT'),
          ),
        ],
      ),
    );
  }

  /// Local time to the minute, the same spelling every other screen in this
  /// app uses for a timestamp (`sync_status_screen.dart`, `log_screen.dart`).
  static String _when(DateTime utc) =>
      utc.toLocal().toString().substring(0, 16);
}
