import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/providers/sync_provider.dart';
import 'sync_status_presentation.dart';

/// **The sync surface, after task 11.189: one icon instead of a bar.**
///
/// ## What this replaced, and why
///
/// Until 2026-09-07 sync had a coloured strip across the top of every tab.
/// Task 11.149 measured what the shell's two strips cost the screen under
/// them on a 6.1-inch phone: the body left to whichever tab was showing was
/// **570 logical pixels at the default text size and 56 at AX5**, and the
/// Record screen's scrolling form was handed a viewport of *zero* from AX4.
/// Michael asked for the strip to go:
///
/// > *"Could we get away from the bar at the top of the map window that
/// > constantly takes up vertical space and move to some icon based system
/// > right above the + on the map… The north map reorientation is a nice
/// > model — small and selectable and out of the way, still clickable."*
///
/// So this is `MapNorthArrow`'s shape, in `MapNorthArrow`'s language: a
/// [diameter]-pixel translucent circle that floats over the map, does not
/// grow with the text size (it is an icon, not a character), and taps through
/// to the screen that holds the whole story.
///
/// ## Task 10.2's invariant, which a redesign is very easy to break
///
/// **A person who never configured a server sees nothing here — not a green
/// tick.** A tick would be claiming a sync succeeded when nothing has ever
/// tried. `SyncStatus.isWorthShowing` carries that rule and it is the same
/// rule the bar used; `sync_status_icon_test.dart` watches it, because the
/// tempting simplification — "no status, so show the calm one" — produces
/// exactly the false green this app has spent six tasks removing.
///
/// ## Why the sentence is a tooltip and a semantics label rather than text
///
/// The whole point of the change is that the map keeps its pixels, so the
/// sentence cannot be on the map. It reaches a VoiceOver user as this
/// control's accessibility label — an icon-only status control that announced
/// itself as "warning icon" would be worse than the bar it replaced — and a
/// sighted person gets colour, shape, and one tap to `SyncStatusScreen`,
/// which says all of it with room to spare. That is the same exemption the
/// other round map controls carry (see `MeasureButton`): a non-destructive
/// control whose meaning is one tap away.
class SyncStatusIcon extends ConsumerWidget {
  const SyncStatusIcon({super.key, this.padding = EdgeInsets.zero});

  /// Space around the icon **when it is showing**, and nothing at all when it
  /// is not.
  ///
  /// Declared here rather than as a `SizedBox` beside the call site for the
  /// reason `TilesNotLoadingBand` takes the same parameter: this widget is
  /// conditional, and a gap that survives its absence is a gap nobody
  /// decided. The Main Map stacks it directly above the "+".
  final EdgeInsets padding;

  /// `MapNorthArrow`'s circle, to the pixel — Michael named that control as
  /// the model, and two floating map buttons of different sizes at the same
  /// corner would read as two kinds of thing.
  static const diameter = 28.0;

  /// The glyph inside it. Does not scale with `textScaler`: it is an icon,
  /// not a character (rule 4 of the Position screen's text-size budget).
  static const glyphSize = 17.0;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref.watch(syncControllerProvider).value;
    // `isWorthShowing`, not `isAvailable`: a project the signed-in person has
    // left is unavailable *and* is the one unavailable state with something
    // to say (task 11.54). Everything else that makes sync unavailable — no
    // server, no project, a project never published — is a reason there is
    // nothing to report, and task 10.2 says the surface is absent then rather
    // than calm.
    if (status == null || !status.isWorthShowing) {
      return const SizedBox.shrink();
    }
    final presentation = SyncStatusPresentation.of(status);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Padding(
      padding: padding,
      child: Semantics(
        button: true,
        label: 'Sync status. ${presentation.message}',
        // The label above is the whole announcement; the glyph inside would
        // otherwise add "warning" or "error" after it as a second, vaguer
        // copy of the same fact.
        excludeSemantics: true,
        child: Tooltip(
          message: presentation.message,
          child: GestureDetector(
            key: const ValueKey('sync-status-icon'),
            onTap: () => context.push('/more/sync-status'),
            child: Container(
              width: diameter,
              height: diameter,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                // `MapNorthArrow`'s own scrim, so the two read as one family
                // of control. The glyph carries the severity colour; the
                // circle stays neutral, because a 28-pixel disc of red over
                // satellite imagery is a different and much louder object
                // than the one Michael asked for.
                color: isDark
                    ? Colors.black.withValues(alpha: 0.55)
                    : Colors.white.withValues(alpha: 0.85),
              ),
              child: Center(
                child: Icon(
                  presentation.glyph,
                  size: glyphSize,
                  color: presentation.color,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// **The same status as a dot, for the two places a dot is the whole
/// message** — Michael's answer of 2026-09-07 to "should the bar go app-wide
/// or only on the map".
///
/// ## Its two homes, and why the second one exists
///
/// [SyncStatusBadge] goes on the **More tab's icon**, so the state is visible
/// from every screen rather than only from the map. Michael looked at that and
/// asked the obvious next question:
///
/// > *"there should be a corresponding dot on the sync line in the more menu
/// > so the user knows where to look in the more menu — ie what was causing
/// > the original dot to be green, yellow or red."*
///
/// So [SyncStatusDot] goes on the More screen's **"Sync Status"** row. A
/// coloured dot with nowhere obvious to look is half a signal: it says
/// *something* is wrong and leaves somebody to open five menu entries finding
/// out which.
///
/// **Two widgets rather than one, and the reason is that they are two
/// different objects.** On the tab the dot is an *annotation on an icon*,
/// which is what Material's `Badge` is for — it overlays, it must not grow the
/// navigation bar, and it is read as "this tab has something on it". On the
/// menu row it is *the subject*: it sits beside the words, in reading order,
/// and it is the thing a person is looking for. They share the severity, the
/// visibility rule and the accessibility label, all of which come from
/// [_reportable] below, **so they cannot come to show different colours** —
/// the trap this task found between the old sync bar and the sync status card,
/// which had disagreed about [SyncHealth.healthy] for as long as both existed.
///
/// ## Where the first attempt went wrong
///
/// Task 11.189's first version put the row's dot on the **leading icon**, as a
/// `Badge`, the same 8 logical pixels as the tab's. Michael, the same day:
/// *"you put it on the icon on the left and it is hard to see."* An 8-pixel
/// annotation is legible on a navigation icon because the whole tab is small
/// and there is nothing else in that corner; on a full-width list row with a
/// title, a chevron and eleven neighbours it is a speck on a speck. So the
/// row's dot moved to the right of the words and got nearly twice the
/// diameter. **The lesson is small and worth keeping: a size that works as an
/// annotation is not a size that works as a subject.**
///
/// ## What neither of them does
///
/// Both obey the same invariant as [SyncStatusIcon]: **nothing at all when no
/// server is configured**, so an absent dot means "nothing has ever tried"
/// rather than "everything is fine". That gate and the one hiding the "Sync
/// Status" menu row are the same fact — `SyncController.build` returns
/// [SyncUnavailable.notConfigured] from exactly the `serverConfigProvider`
/// answer `MoreScreen` reads — so **a dot on the tab can never point at a menu
/// row that is not there.** `more_screen_test.dart` watches that pair.
///
/// Both show in every state including [SyncSeverity.healthy], deliberately,
/// and Michael confirmed that on 2026-09-07. Hiding the calm one would make a
/// dot's absence mean two different things — healthy, or no server — and that
/// ambiguity is the whole of task 10.2's concern pointed the other way.
class SyncStatusBadge extends ConsumerWidget {
  const SyncStatusBadge({super.key, required this.child});

  /// The icon the dot is placed on — the More tab's.
  final Widget child;

  /// Material's dot badge is 6 logical pixels by default, which disappears
  /// against a navigation bar's icon. Eight is still smaller than the icon it
  /// sits on and is legible on a phone.
  ///
  /// **Deliberately smaller than [SyncStatusDot.diameter]**, and the two are
  /// not a drift: this one is an annotation that must not swamp the icon
  /// under it, and that one is the subject of its own row. See this file's
  /// header for what happened when they were the same number.
  static const dotSize = 8.0;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final reportable = _reportable(ref);
    if (reportable == null) return child;
    return Semantics(
      // Merged into the destination's own "More" label by the navigation bar,
      // so a screen-reader user hears the tab and then the state. A dot is the
      // one thing a screen reader cannot report on its own.
      label: _label(reportable),
      child: Badge(
        key: const ValueKey('sync-status-tab-badge'),
        backgroundColor: reportable.color,
        smallSize: dotSize,
        child: child,
      ),
    );
  }
}

/// The same status as a **standalone** dot, sized to be found rather than to
/// annotate — for the More screen's "Sync Status" row. See this file's header
/// for why this is not [SyncStatusBadge] with a bigger number.
class SyncStatusDot extends ConsumerWidget {
  const SyncStatusDot({super.key});

  /// Set against the 16-logical-pixel body text it sits beside: large enough
  /// to read as a deliberate coloured mark at a glance, small enough not to
  /// read as a second icon competing with the row's own.
  ///
  /// **It does not scale with the text size**, for the same reason the map's
  /// status icon does not: it is a mark, not a character (rule 4 of the
  /// Position screen's text-size budget).
  static const diameter = 14.0;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final reportable = _reportable(ref);
    if (reportable == null) return const SizedBox.shrink();
    return Semantics(
      // Merged into the row's own "Sync Status" label, so a screen-reader user
      // hears the row and then the state rather than a colour they cannot see.
      label: _label(reportable),
      excludeSemantics: true,
      child: Icon(
        Icons.circle,
        key: const ValueKey('sync-status-row-dot'),
        size: diameter,
        color: reportable.color,
      ),
    );
  }
}

/// The status worth reporting as a dot, or null when there is nothing to
/// report.
///
/// **One function, so the two dots share the visibility rule as well as the
/// colour.** `isWorthShowing`, not `isAvailable`: a project the signed-in
/// person has left is unavailable *and* is the one unavailable state with
/// something to say (task 11.54). Everything else that makes sync unavailable
/// — no server, no project, a project never published — is a reason there is
/// nothing to report, and task 10.2 says the surface is absent then rather
/// than calm.
SyncStatusPresentation? _reportable(WidgetRef ref) {
  final status = ref.watch(syncControllerProvider).value;
  if (status == null || !status.isWorthShowing) return null;
  return SyncStatusPresentation.of(status);
}

String _label(SyncStatusPresentation presentation) =>
    'Sync status. ${presentation.message}';
