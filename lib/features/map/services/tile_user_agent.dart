/// The `User-Agent` every tile request this app makes must carry, and the one
/// place it is written down.
///
/// **Task 11.134 item 1. Measured before anything was designed, on
/// 2026-09-02, against a local `HttpServer` that recorded the header it was
/// actually sent.** The measurement, not a reading of the code:
///
///   * Live tiles on all six `TileLayer` sites went out as
///     `flutter_map (edu.nau.tritrack)`. Every site passed
///     `userAgentPackageName: 'edu.nau.tritrack'`, and `flutter_map` turns
///     that into a header with `putIfAbsent` — so it identified the app, but
///     it named the library first and carried no way to reach anybody.
///   * **The bulk region downloader sent `Dart/3.12 (dart:io)`.**
///     `OfflineTileDownloader` calls `client.get(url)` with no headers at
///     all, so it got the SDK's default. That is *the* library default the
///     OpenStreetMap tile usage policy says it will block, and it was on the
///     highest-volume path in the app: a region download asks for thousands
///     of tiles as fast as six concurrent requests allow, while a live map
///     asks for a screenful.
///
/// The policy (`operations.osmfoundation.org/policies/tiles/`) requires a
/// *"valid HTTP User-Agent identifying the application"* and warns that
/// generic ones are blocked. **A block arrives as tiles that stop loading**,
/// which until this task the app reported as nothing at all — see
/// [TileFetchHealth] in `tile_fetch_health.dart` for the other half.
///
/// ## Why this is a constant with no version in it
///
/// **The version is deliberately absent.** Two ways to include it and both
/// are worse than leaving it out:
///
///   * a hard-coded version string is the hand-maintained list this project
///     keeps being bitten by, and `app_info_screen.dart` already refuses one
///     for exactly this reason — it is wrong the first time somebody forgets
///     to bump it, and nothing says so;
///   * reading it from `PackageInfo` makes the header asynchronous, so a
///     tile provider built synchronously in `build()` would either wait for
///     it or send a different header on the first frame.
///
/// The policy asks for a *stable* agent that identifies the app. A version
/// makes it less stable and is only *"ideally"* included. The app's name and
/// its bundle identifier do the identifying, and the URL does the contacting.
///
/// **What the URL costs, stated rather than discovered.** It is a fact about
/// something shipped separately from the app, so an already-installed build
/// keeps sending it if the site ever moves — the same shape as the rule about
/// clients hard-coding facts about servers. It is here anyway because the
/// alternative is no contact at all, and because the durable half of the
/// string is `edu.nau.tritrack`: a tile operator with a question can identify
/// the app from that whether or not the address still resolves.
const String tileUserAgent =
    'TriTrack (edu.nau.tritrack; '
    '+https://dynamic-and-active-systems-lab.github.io/tritrack-site/)';

/// The headers every tile fetch carries — live tiles through
/// `CachedTileProvider`, and bulk downloads through `OfflineTileDownloader`.
///
/// Returns a **fresh mutable map** each call on purpose: `flutter_map`'s
/// `TileLayer` constructor calls `putIfAbsent` on `tileProvider.headers`, and
/// a shared `const` map would throw. `putIfAbsent` also means the value here
/// wins — a `TileLayer` cannot overwrite it with `flutter_map (unknown)`.
Map<String, String> tileRequestHeaders() => {'User-Agent': tileUserAgent};
