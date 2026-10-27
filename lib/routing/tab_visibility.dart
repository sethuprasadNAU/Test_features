import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show ProviderListenable;

/// **Task 11.161 — which tab is on screen, said out loud.**
///
/// Task 11.160 stopped `StatefulShellRoute` from ticker-muting the tabs you
/// are not looking at, because riverpod reads that same `TickerMode` and
/// pausing a provider subscription behind the app's back is what produced
/// 11.160's crash. The cost it accepted, and wrote down, is that a hidden tab
/// now keeps everything it was watching. Measured on the app itself
/// (`test/routing/hidden_tab_liveness_test.dart`), that cost is **the three
/// compass sensor streams and the dial animation they drive, running for the
/// rest of the run once the Compass or Record tab has been visited.**
///
/// This is how the app says which branch is on screen, so a screen can stop
/// asking for sensor samples **on purpose** instead of having a framework
/// notice it is off-screen. The two are not the same thing, and the
/// difference is the whole of 11.160:
///
/// - `TickerMode` pauses a **subscription**, silently, leaving a
///   recomputation owed and settled during a later build. That is the defect.
/// - This drops the **watch itself**, in an ordinary rebuild. The provider
///   underneath is `autoDispose`, so it goes away with its stream, and coming
///   back is an ordinary build that creates it again. Nothing is owed, so
///   nothing is settled at a bad moment.
///
/// **The branch stays mounted either way** — this widget sits inside the
/// `Offstage` that 11.160's container already builds, and changes nothing
/// about mounting, `IndexedStack`, or branch state.
class TabVisibility extends InheritedWidget {
  const TabVisibility({super.key, required this.visible, required super.child});

  /// Whether the tab branch below this widget is the one on screen.
  final bool visible;

  /// Whether the tab containing [context] is on screen.
  ///
  /// **Absent means visible, and that is the safe direction on purpose.** A
  /// screen pushed over the shell, a modal sheet in the root navigator, and
  /// every widget test that pumps a screen bare have no [TabVisibility] above
  /// them. The failure mode of guessing "visible" is a sensor that stays on
  /// when it could have stopped; the failure mode of guessing "hidden" is a
  /// dead compass on a screen somebody is looking at.
  static bool of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<TabVisibility>()?.visible ??
      true;

  @override
  bool updateShouldNotify(TabVisibility oldWidget) =>
      oldWidget.visible != visible;
}

/// Watching a provider only while the tab it is on is the tab on screen.
extension WatchWhileTabVisible on WidgetRef {
  /// Watches [provider] while this widget's tab is on screen, and builds
  /// against [whileHidden] while it is not — **holding no subscription**, so
  /// an `autoDispose` provider and anything it is subscribed to are released.
  ///
  /// [whileHidden] is a value nobody sees: an `Offstage` branch still builds,
  /// but it is not painted. It exists so the widget can build without the
  /// provider rather than to be looked at.
  ///
  /// **Use this only where the pause is worth what resuming costs.** Every
  /// call site is a decision that a person will not be kept waiting when they
  /// come back to the tab, and the resume cost of each one is stated at the
  /// call site.
  T watchWhileTabVisible<T>(
    BuildContext context,
    ProviderListenable<T> provider, {
    required T whileHidden,
  }) => TabVisibility.of(context) ? watch(provider) : whileHidden;
}
