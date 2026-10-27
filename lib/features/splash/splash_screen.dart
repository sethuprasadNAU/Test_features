import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/providers/app_context_provider.dart';
import '../../core/providers/provider_error.dart';
import '../../data/models/user.dart';

/// Brand green used across the app's splash + brand mark (see
/// CLAUDE_DOCS/design_handoff_tritrack/README.md "Design Tokens").
const kBrandGreen = Color(0xFF3E7A4C);

/// How long the branded splash (Screen 0 of the hi-fi handoff) is shown
/// before routing into the app. Overridden to [Duration.zero] in widget
/// tests so `pumpAndSettle` reaches the real first screen immediately.
final splashDurationProvider = Provider<Duration>((ref) {
  return const Duration(milliseconds: 1600);
});

/// Full branded splash screen ("Screen 0" in the design handoff): full-bleed
/// brand green background, a translucent-white icon chip holding the brand
/// mark, the "TRITRACK" wordmark, and a "WILDLIFE TELEMETRY" tagline near
/// the bottom. Always the brand green — there is no dark-mode variant.
class SplashScreen extends ConsumerStatefulWidget {
  const SplashScreen({super.key, this.nextLocation = '/map'});

  /// Where to navigate once the splash has finished showing.
  final String nextLocation;

  /// Shown once the identity read has failed at least once and the app's
  /// retry policy has scheduled another attempt. **This is the whole point of
  /// task 11.107's first half:** a retry nobody can see is indistinguishable
  /// from a frozen app, and the number of seconds was never the problem.
  static const String retryingLabel = 'Still trying…';

  /// Shown when the identity read has failed and the app has stopped trying.
  static const String failureHeadline = 'TriTrack could not finish starting up';

  /// The way on. Re-reads the identity from scratch.
  static const String failureAction = 'Try again';

  @override
  ConsumerState<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends ConsumerState<SplashScreen> {
  @override
  void initState() {
    super.initState();
    unawaited(_resolveAndNavigate(withBrandDelay: true));
  }

  /// **Set when the identity read has failed and the app has given up.** Not
  /// the error object — nothing about it reaches the screen (see
  /// `test/documentation/raw_error_in_ui_test.dart`); only whether the cause is
  /// knowable at all, which is what decides the sentence below.
  bool _failed = false;
  bool _causeUnknowable = false;

  /// Waits out the splash duration and resolves the local user in parallel,
  /// then routes to identity capture instead of [nextLocation] if that user
  /// still carries the auto-created placeholder email (fresh install, or a
  /// device that never completed Phase 7's first-run identity capture) —
  /// see `IdentitySetupScreen`.
  ///
  /// No app-level navigation reaches the rest of the app without passing
  /// through here first. It is not, on its own, proof against every route
  /// into this screen's replacement: an exported Android activity is
  /// startable by any app already on the device with an explicit component
  /// intent, which Flutter's embedding would otherwise hand straight to
  /// go_router as the initial route ahead of `/splash`. That gap is closed
  /// at the platform layer instead — `app_router.dart`'s
  /// `overridePlatformDefaultLocation` and the Android/iOS
  /// deep-linking-disabled config — precisely so this comment does not have
  /// to claim more than the widget itself guarantees (task 10.77, finding
  /// K-3). The precondition for that gap was a malicious app already on the
  /// device, which §5.4 of the security model declares a non-goal.
  Future<void> _resolveAndNavigate({required bool withBrandDelay}) async {
    final duration =
        withBrandDelay ? ref.read(splashDurationProvider) : Duration.zero;
    try {
      final results = await Future.wait([
        Future<void>.delayed(duration),
        ref.read(currentUserProvider.future),
      ]);
      if (!mounted) return;
      final user = results[1] as User;
      context.go(user.hasPlaceholderIdentity ? '/identity-setup' : widget.nextLocation);
    } catch (error) {
      // **Task 11.107.** Before this `catch` existed, a failed identity read
      // was an unhandled error: `context.go` never ran and the app stayed on
      // the brand green with nothing said, on the first screen anybody sees.
      // With the 38-second default retry in front of it (task 11.105) that
      // read as a freeze, then as a permanent one.
      if (!mounted) return;
      setState(() {
        _failed = true;
        // `providerErrorWasDestroyed` means the provider was torn down while
        // still loading and its error was destroyed rather than delivered:
        // the app genuinely does not know why. Saying so is the honest
        // answer; naming a cause here would be the wrong-cause defect task
        // 11.104 exists to correct.
        _causeUnknowable = providerErrorWasDestroyed(unwrapProviderError(error));
      });
    }
  }

  void _tryAgain() {
    setState(() {
      _failed = false;
      _causeUnknowable = false;
    });
    ref.invalidate(currentUserProvider);
    // No brand delay on a retry: the branding has been on screen for a while
    // already, and somebody who has just pressed a button is waiting on an
    // answer, not on a logo.
    unawaited(_resolveAndNavigate(withBrandDelay: false));
  }

  /// The tagline slot at the bottom of the splash carries three different
  /// things, and which one is showing is the answer to *is this app working or
  /// has it stopped* — the question task 11.107 exists to make answerable.
  Widget _statusSlot(bool retrying) {
    if (_failed) return _failurePanel();
    if (retrying) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: Colors.white.withValues(alpha: 0.8),
            ),
          ),
          const SizedBox(width: 10),
          Text(
            SplashScreen.retryingLabel,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: Colors.white.withValues(alpha: 0.85),
            ),
          ),
        ],
      );
    }
    return Text(
      'WILDLIFE TELEMETRY',
      style: TextStyle(
        fontSize: 11,
        fontWeight: FontWeight.w700,
        letterSpacing: 2,
        color: Colors.white.withValues(alpha: 0.6),
      ),
    );
  }

  /// **What a person reads when the app has stopped.** Plain sentences, an
  /// honest cause, and one thing to press. No part of the caught error appears
  /// here: on this screen it would be a Riverpod or sqflite sentence, which
  /// says nothing to a biologist and everything to anybody the screenshot is
  /// forwarded to (task 11.105 follow-up).
  Widget _failurePanel() {
    const body = "TriTrack could not read this device's user profile, so it "
        'stopped here. Nothing has been lost.';
    const unknowable = 'This device could not tell why.';
    const nextStep = 'If trying again does not work, close TriTrack '
        'completely and reopen it.';

    return Container(
      constraints: const BoxConstraints(maxWidth: 380),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            SplashScreen.failureHeadline,
            style: TextStyle(
              fontSize: 17,
              fontWeight: FontWeight.w700,
              color: Colors.white,
            ),
          ),
          const SizedBox(height: 10),
          Text(
            _causeUnknowable ? '$body $unknowable $nextStep' : '$body $nextStep',
            style: TextStyle(
              fontSize: 14,
              height: 1.35,
              color: Colors.white.withValues(alpha: 0.9),
            ),
          ),
          const SizedBox(height: 16),
          Align(
            alignment: Alignment.centerRight,
            child: FilledButton(
              onPressed: _tryAgain,
              style: FilledButton.styleFrom(
                backgroundColor: Colors.white,
                foregroundColor: kBrandGreen,
              ),
              child: const Text(SplashScreen.failureAction),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Watched, not read: this is how the screen learns that an attempt has
    // failed and another is scheduled. `AsyncValue.retrying` is Riverpod's own
    // flag for exactly that state, and watching is what rebuilds this widget
    // when it flips.
    final retrying = ref.watch(currentUserProvider).retrying;

    return Scaffold(
      backgroundColor: kBrandGreen,
      body: SafeArea(
        child: Stack(
          children: [
            Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // 96px icon chip: translucent-white rounded square holding
                  // the brand mark (white rays on brand green).
                  Container(
                    width: 96,
                    height: 96,
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.14),
                      borderRadius: BorderRadius.circular(21),
                    ),
                    padding: const EdgeInsets.all(14),
                    child: Image.asset(
                      'assets/icon/tritrack-icon-monochrome-white-1024.png',
                      fit: BoxFit.contain,
                    ),
                  ),
                  const SizedBox(height: 22),
                  // Wordmark: "TRI" near-black + "TRACK" white, weight 800.
                  RichText(
                    text: const TextSpan(
                      style: TextStyle(
                        fontSize: 30,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 30 * 0.03,
                      ),
                      children: [
                        TextSpan(
                          text: 'TRI',
                          style: TextStyle(color: Color(0xFF1A1A1A)),
                        ),
                        TextSpan(
                          text: 'TRACK',
                          style: TextStyle(color: Colors.white),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            Positioned(
              left: 24,
              right: 24,
              bottom: 56,
              child: Center(child: _statusSlot(retrying)),
            ),
          ],
        ),
      ),
    );
  }
}
