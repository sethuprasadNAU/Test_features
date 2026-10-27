/// The signal raised by code that **writes** data the screens display, so the
/// screens find out without the writer's *caller* having to remember to tell
/// them.
///
/// ## Why this exists
///
/// Task 11.41's follow-on, found on real hardware on 2026-08-27: a Mac synced,
/// reported success, and the teammate's bearings were not on the map. They
/// were in SQLite. Nothing told the map.
///
/// `recordingsRevisionProvider` exists exactly for that — *"so a mutation made
/// on one screen shows up immediately elsewhere, without waiting for an app
/// restart to re-run that provider"* — and every one of its callers was a
/// **local UI edit**. Every path by which observation data arrived from
/// *outside* this device announced nothing at all. `_mapDataProvider` and
/// `historyDataProvider` are plain (non-`autoDispose`) family providers on
/// tabs that live as long as the process, so their cached result survived
/// until the app was quit.
///
/// The first fix put a bump in each of the five providers that happened to
/// call an inbound writer, and a test held a hand-written list of those five
/// files. A sixth path in an unlisted file was silently exempt, and the symptom
/// is field data on the device that never appears on screen — nothing looks
/// wrong. Task 11.45 moved the announcement here, to the writer, where there is
/// nothing for a caller to forget.
///
/// ## Contract
///
/// - **Announcing is cheap and idempotent.** Twice is the same as once: the
///   only consequence is that a screen re-runs its query.
/// - **Announcing a write that later rolls back is harmless** for the same
///   reason — the screen re-queries and sees what is really there. Writers may
///   therefore announce at their own operation boundary without reasoning about
///   an enclosing transaction they did not open.
/// - **Announce per operation, not per row.** A merge of a thousand rows is one
///   arrival; announcing per row would re-run the map's whole query a thousand
///   times.
/// - It is a plain callback list rather than a `Stream` or a `ValueNotifier` so
///   that `lib/data` keeps depending on neither Flutter nor Riverpod: the
///   writers are ordinary classes with no `ref`, which is precisely why the
///   announcement could not live in them before.
///
/// `test/core/providers/data_arrival_announced_test.dart` derives, from the
/// source, every place that writes a table the screens read, and fails if one
/// of them neither announces here nor bumps the provider directly.
abstract final class DataArrival {
  static final List<void Function()> _listeners = <void Function()>[];

  /// Registers [listener]. Callers must pair this with [removeListener] on
  /// dispose — `recordingsRevisionProvider` does it in `ref.onDispose`.
  static void addListener(void Function() listener) => _listeners.add(listener);

  static void removeListener(void Function() listener) =>
      _listeners.remove(listener);

  /// Says that rows the screens display have changed on this device.
  ///
  /// Iterates a copy, so a listener that removes itself while being called
  /// (a provider disposed mid-notification) cannot corrupt the walk.
  static void announce() {
    for (final listener in List<void Function()>.of(_listeners)) {
      listener();
    }
  }

  /// How many listeners are attached. For tests of this class only.
  static int get listenerCount => _listeners.length;
}
