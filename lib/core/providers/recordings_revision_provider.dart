import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../data/db/data_arrival.dart';

part 'recordings_revision_provider.g.dart';

/// Bumped whenever observations, position estimates, actual tag locations, tag
/// edits or the people who authored them change — anything a one-shot
/// [FutureProvider] elsewhere has already baked into its result. Screens that
/// display that data (the map and the log) watch this alongside their own
/// query provider, so a change made anywhere shows up immediately, without
/// waiting for an app restart to re-run that provider.
///
/// **Two ways it moves, and the second is the one that scales.**
///
/// A screen that has just written something may call [bump] directly — the
/// original mechanism, still correct for a local edit made by the screen
/// itself.
///
/// Everything that writes data arriving from *outside* this device — a sync
/// pull, a join, a restored backup, a pasted share, an identity adoption at
/// sign-in — announces through [DataArrival] instead, from inside the writer.
/// That is task 11.45: those writers are plain classes with no `ref`, and
/// requiring each of their callers to remember a bump is what left the sync
/// pull silent until 2026-08-27. This provider subscribes for as long as it is
/// alive, so a writer announcing is enough.
///
/// **`keepAlive` on purpose.** The subscription to [DataArrival] lives exactly
/// as long as this provider does, so if it were disposed whenever nothing
/// happened to be watching, an arrival landing in that window would be
/// announced to nobody and the counter would come back at zero. In the running
/// app the map and log providers hold it alive anyway; relying on that would
/// make correctness depend on which tab is open.
@Riverpod(keepAlive: true)
class RecordingsRevision extends _$RecordingsRevision {
  @override
  int build() {
    void onArrival() => bump();
    DataArrival.addListener(onArrival);
    ref.onDispose(() => DataArrival.removeListener(onArrival));
    return 0;
  }

  void bump() => state++;
}
