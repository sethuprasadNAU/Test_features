import 'package:flutter/foundation.dart';

/// Whether basemap tiles are arriving from the network, so that a map with no
/// tiles on it can say so.
///
/// **Task 11.134 item 1, second half.** The first half set a `User-Agent` the
/// OpenStreetMap tile policy will not block. This is the half that survives
/// whatever that measurement said: **a block, a rate limit, a dead network
/// and a provider outage all arrive as tiles that simply do not appear**, and
/// until now the app said nothing about any of them. A blank basemap with no
/// sentence is indistinguishable from a blank basemap with no signal.
///
/// **It names no cause, and that is the design, not a gap.** The fetch knows
/// one fact — the last several tile requests did not produce a tile — and it
/// does not know whether that is the phone's radio, the field site, the
/// provider, or this app being refused. The message it drives says exactly
/// that much and names what still works. This project's rule is that the
/// branch reached when the code does not know why must not assert a cause.
///
/// **Signal, not per-screen state.** Every live tile in the app is fetched
/// through `CachedTileProvider`, on six `TileLayer` sites across five
/// screens, so the counting belongs at the fetch. What each screen does with
/// it is that screen's choice, and any map can listen to [failing] without a
/// second counter being written.
///
/// **Task 11.135 decided the other four screens one at a time, and one of
/// them said no.** Four show `TilesNotLoadingBand` (`map_furniture.dart`):
/// the Main Map, the Offline Data Map, the project-extent picker, and both
/// maps on the record-position screen. **The Position Estimation screen does
/// not** — measured with the shell's banners live, its clear map band is 101
/// logical pixels against a floor of 96, and this band is 48, which would
/// leave 45. That verdict and its number are written into the MAP SPACE
/// BUDGET at the top of `position_estimation_screen.dart`, beside the rules
/// it follows. **A screen deciding not to show this is a result, not a gap**,
/// and the fact is process-wide, so the sentence is never wrong there — only
/// absent.
///
/// **A cache hit is silence, not success.** Serving a tile from disk says
/// nothing about the network, so it neither raises nor clears the flag —
/// otherwise a fully cached region would hide a provider that has been
/// refusing every request for an hour.
class TileFetchHealth {
  TileFetchHealth._();

  static final TileFetchHealth instance = TileFetchHealth._();

  /// How many network fetches in a row must fail before the app says so.
  ///
  /// **Not one.** A single tile failing is ordinary — a tile at the edge of
  /// coverage, one dropped request while a train goes through a cutting — and
  /// a band that flickers on every one of those is a band people learn to
  /// ignore. A screenful is on the order of a dozen tiles, so four
  /// consecutive failures with no success in between means the map is
  /// visibly not filling in rather than one square being late.
  static const int failureThreshold = 4;

  /// What the map says while [failing] is true.
  ///
  /// **It names no cause because the fetch does not know one.** A refused
  /// request, an expired rate limit, a phone with no route out and a provider
  /// having a bad afternoon are the same event here: nothing came back. The
  /// sentence that would be most useful — "you are being blocked" — is the
  /// one this code cannot support, and a confident wrong cause sends somebody
  /// to fix a network that is fine.
  ///
  /// It says what still works, because that is the part a field technician
  /// needs in the next thirty seconds: **tiles already downloaded still draw,
  /// and recording a bearing never touched the tile service at all.**
  static const String notLoadingMessage = 'New map tiles are not arriving.';

  /// The rest of it, one tap behind [notLoadingMessage].
  ///
  /// **It is here rather than on the map because of a measurement, not a
  /// preference.** The three sentences below were on the map first. At the
  /// left column's width they wrap to four lines, and
  /// `map_screen_space_budget_test.dart` measured the worst case at **14
  /// logical pixels of clear map against a floor of 96** — the band alone was
  /// most of what the screen had left. Rule 3 of that budget says the answer
  /// is a better home, not a smaller floor.
  ///
  /// **Still no cause.** The fetch knows that nothing came back; it does not
  /// know whether that is the radio, the field site, the provider or this app
  /// being refused, and a confident wrong cause sends somebody to fix a
  /// network that is fine. What it can do honestly is say what still works
  /// and name one action.
  static const String notLoadingDetail =
      'Tiles already downloaded still draw, and recording a bearing does not '
      'need the map service.\n\n'
      'This device may have no connection, or the map service may be refusing '
      'requests; the app cannot tell which.\n\n'
      'If it keeps happening on a connection you know works, report it with '
      'the version from More › App Info.';

  /// What a **download** says about the tiles it did not get, as opposed to
  /// what the live map says about the tiles it is not getting.
  ///
  /// **Task 11.135.** The Offline Data Map is the one screen in the app where
  /// somebody fetches tiles deliberately, and a job that lost tiles used to
  /// report a bare count — which is what happened, not what it means or what
  /// to do about it. These two say the rest, on the card that is already
  /// there.
  ///
  /// **Still no cause**, for the same reason [notLoadingMessage] gives none:
  /// the downloader knows that some requests came back with nothing usable,
  /// and a refusal, a rate limit, a dead radio and a provider outage are the
  /// same event from here. What it can say honestly is what a retry does.
  static String notArrivedCount(int failed) =>
      '$failed ${failed == 1 ? 'tile' : 'tiles'} did not arrive.';

  /// The half a person can act on: **Retry is cheap and loses nothing.**
  ///
  /// True because the downloader skips any tile already on disk before it
  /// makes a request, so a retry asks only for what is missing. Written here
  /// rather than on the card so it sits beside the sentence it qualifies.
  static const String retryFetchesOnlyWhatIsMissing =
      'Retry asks only for the ones still missing — whatever did arrive is '
      'already on this device.';

  int _consecutiveFailures = 0;

  final ValueNotifier<bool> _failing = ValueNotifier<bool>(false);

  /// True once [failureThreshold] network tile fetches have failed with no
  /// success between them; false again the moment one succeeds.
  ValueListenable<bool> get failing => _failing;

  void recordNetworkSuccess() {
    _consecutiveFailures = 0;
    _failing.value = false;
  }

  void recordNetworkFailure() {
    _consecutiveFailures++;
    if (_consecutiveFailures >= failureThreshold) _failing.value = true;
  }

  /// Puts the signal back to "no failures seen", so one test cannot leave the
  /// band up for the next. Not called by the app.
  @visibleForTesting
  void reset() {
    _consecutiveFailures = 0;
    _failing.value = false;
  }
}
