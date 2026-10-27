/// A raster tile provider TriTrack can pull from, offline-cache, and
/// attribute correctly. Curated to providers whose license explicitly
/// permits offline/bulk caching (per the technical doc's "resolve early"
/// flag — Google and some Mapbox tiers explicitly prohibit this, satellite
/// especially). The app never hard-codes a single provider: the user picks
/// one (or, later, supplies their own URL template) so the app stays
/// deployable globally regardless of which free-licensed source covers their
/// field site.
class TileSource {
  const TileSource({
    required this.id,
    required this.name,
    required this.category,
    required this.urlTemplate,
    required this.attribution,
    this.shortAttribution,
    this.poweredByCredit,
    this.attributionUrl,
    this.subdomains = const [],
    this.maxZoom = 19,
  });

  /// Stable id, persisted as the user's selection.
  final String id;

  final String name;

  /// Rough terrain/street/satellite grouping for the basemap toggle.
  final TileCategory category;

  /// `{z}`/`{x}`/`{y}`/`{s}` template per flutter_map's `TileLayer`.
  final String urlTemplate;

  /// Required attribution text — every one of these providers' terms require
  /// on-screen credit; never remove the attribution widget.
  final String attribution;

  /// The credit to show on the map when a shortened one is permitted, or
  /// null when this provider's full [attribution] must stay visible.
  ///
  /// **Null is the safe value and the default.** A short form is only set
  /// where the provider's own published terms say in so many words that the
  /// rest may live behind a button. Where they do not, or where they are
  /// ambiguous, this stays null and the whole string stays on the map —
  /// which is the cheap outcome. Task 11.133 read all three today,
  /// 2026-09-02; the verdicts and the sentences they rest on are recorded on
  /// each source below.
  ///
  /// Whatever this is, the full [attribution] and [attributionUrl] are always
  /// one tap away, from the "ⓘ" beside the credit and from App Info under
  /// More. **The credit gets smaller. It never disappears.**
  final String? shortAttribution;

  /// A second, separate credit some providers require **in addition to**
  /// naming the data sources — Esri's *"Powered by Esri"*. Null for providers
  /// that require no such line.
  ///
  /// **Task 11.134 item 3, and it was decided rather than researched.** Task
  /// 11.133 could not settle from Esri's published pages whether fetching
  /// raster tiles directly from an ArcGIS service triggers the separate
  /// "Powered by Esri" requirement, which covers use of their *"APIs, SDKs,
  /// open source libraries, services, or data"*. The costs are not
  /// symmetrical: the text is four words, the same page allows it to live
  /// *"in a window that is accessible from a menu or button"*, and this app
  /// already has two of those in App Info and the credit's "ⓘ". Answering the
  /// question was the expensive branch and being wrong about it was the
  /// costly one, so it is satisfied instead. **Do not re-open the research on
  /// the strength of this comment.**
  ///
  /// It deliberately does not go on the map itself. It is not one of the
  /// source names, so folding it into [attribution] would put it in the band
  /// task 11.133 spent a task shrinking, and Esri's own terms do not ask for
  /// it there.
  final String? poweredByCredit;

  final String? attributionUrl;

  /// What is actually painted on the map for this source.
  String get onScreenAttribution => shortAttribution ?? attribution;

  /// Whether the map credit is showing less than the whole story, and so
  /// whether the "ⓘ" beside it has anything the map is not already saying.
  bool get isAbbreviated => shortAttribution != null;
  final List<String> subdomains;
  final int maxZoom;
}

enum TileCategory { terrain, street, satellite }

/// The built-in curated list. All three permit offline/bulk tile caching for
/// an app like this under their published usage policies, unlike Google
/// Maps or Mapbox's standard (non-offline-SDK) tiers.
abstract final class TileSources {
  /// **Attribution verdict (task 11.133, read 2026-09-02): no short form —
  /// this string already is the short form.**
  ///
  /// The OSM Foundation's Attribution Guidelines (adopted 2021-06-25, read at
  /// `osmfoundation.org/wiki/Licence/Attribution_Guidelines`) name
  /// *"© OpenStreetMap contributors"* as an acceptable historical form, and
  /// require that *"attribution must be presented to anyone who uses, views,
  /// accesses, interacts with, or is otherwise exposed to the map"* and that
  /// *"the attribution format should not require individuals to interact with
  /// the map or produced work to see the attribution."* The tile usage policy
  /// (`operations.osmfoundation.org/policies/tiles/`) adds: *"do not hide
  /// attribution beneath UI, behind toggles, or off-screen."*
  ///
  /// So the words stay. What the guidelines do allow behind a button is the
  /// **licence detail** — *"there needs to be a way to access more
  /// information, including origin and licence of the data, if that
  /// information is not directly in the attribution text (for example by
  /// making the text a clickable link)"* — which is what [attributionUrl] and
  /// the "ⓘ" are for. There is nothing left to shorten.
  static const openStreetMap = TileSource(
    id: 'osm_standard',
    name: 'OpenStreetMap',
    category: TileCategory.street,
    urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
    attribution: '© OpenStreetMap contributors',
    attributionUrl: 'https://www.openstreetmap.org/copyright',
    maxZoom: 19,
  );

  /// **Attribution verdict (task 11.133, read 2026-09-02): ambiguous, so the
  /// full text stays. This is the default basemap and therefore the one
  /// Michael was actually looking at — the honest answer is that it does not
  /// get shorter.**
  ///
  /// `opentopomap.org/about` (in German, section *Verwendung*) says the
  /// licence text *"sollte deutlich sichtbar sein"* — **should** be clearly
  /// visible, not *muss* — and gives the string this app carries.
  ///
  /// Three things make it a judgement rather than a permission, and the
  /// project's rule is that a judgement about somebody else's licence goes
  /// the cheap way:
  ///
  ///   1. **The links on that page point at CC BY-SA *3.0*, not 4.0.** 4.0 is
  ///      the version that explicitly blesses satisfying attribution *"by
  ///      providing a URI or hyperlink to a resource that includes the
  ///      required information"* — the exact sentence an "ⓘ" argument would
  ///      rest on. 3.0 §4(c) says only that credit *"may be implemented in
  ///      any reasonable manner"*, *"reasonable to the medium or means"*,
  ///      with no worked example about a link. Whether a phone screen makes
  ///      the full string impractical is a question nobody has ruled on.
  ///   2. **This is two credits under two licences, not one string.**
  ///      "© OpenStreetMap contributors, SRTM" is map *data* under ODbL and
  ///      falls under the OSM guidelines above, which say attribution must
  ///      not require interaction to see. "© OpenTopoMap (CC-BY-SA)" is the
  ///      *style*. Shortening cannot be reasoned about as one blob, and any
  ///      short form that keeps both names is barely shorter than this.
  ///   3. **Asking them is not a plan.** The same page says the maintainers
  ///      cannot answer most of their email; it is a spare-time project.
  ///
  /// The consequence is worth stating plainly rather than leaving to be
  /// rediscovered: **the credit band does not get shorter on the default
  /// basemap.** It gets an "ⓘ" and a home in App Info, and that is all.
  static const openTopoMap = TileSource(
    id: 'opentopomap',
    name: 'OpenTopoMap',
    category: TileCategory.terrain,
    urlTemplate: 'https://{s}.tile.opentopomap.org/{z}/{x}/{y}.png',
    attribution:
        '© OpenStreetMap contributors, SRTM | map style © OpenTopoMap (CC-BY-SA)',
    attributionUrl: 'https://opentopomap.org/about',
    subdomains: ['a', 'b', 'c'],
    maxZoom: 17,
  );

  /// **Attribution verdict (task 11.133, read 2026-09-02): short form
  /// permitted. This is the one provider whose terms grant the small-screen
  /// accommodation in so many words.**
  ///
  /// Esri's *Esri and data attribution — interactive maps* page (read via a
  /// text-extraction proxy, because the developer site renders entirely in
  /// the browser and returns an empty document to anything else — so this is
  /// one hop removed from the origin and is flagged as such) lists among its
  /// display requirements: *"display names directly on or at the bottom of
  /// the map where it is always visible"*, and *"provide an expandable UI to
  /// display all names when they can not be displayed on small screens."*
  /// Its recommendations include prefixing with *"Sources: Name A, Name
  /// B…"*. That last requirement is close to a description of the "ⓘ", so
  /// the short form here keeps "Esri" always visible and moves the rest of
  /// the list behind it.
  ///
  /// **Two things about this source are recorded rather than fixed here.**
  ///
  ///   * **The full string was out of date and has been corrected.** The
  ///     service's own metadata (`.../World_Imagery/MapServer?f=pjson`,
  ///     queried 2026-09-02) gives `copyrightText` as *"Source: Esri, Vantor,
  ///     Earthstar Geographics, and the GIS User Community"*. This app was
  ///     naming **Maxar**, which the service no longer names — Maxar has been
  ///     renamed Vantor. Esri's own instruction is to read `copyrightText`
  ///     from the service and to *"frequently verify names as data source
  ///     providers can change"*, which a hard-coded string cannot do. **This
  ///     is the correct-when-written-then-silently-falsified class**, and the
  ///     hard-coding is still here; only the value is fresher. See the
  ///     Discovered Scope entry for task 11.133.
  ///   * **Whether "Powered by Esri" is also owed is unresolved.** That is a
  ///     separate requirement covering use of Esri *"APIs, SDKs, open source
  ///     libraries, services, or data"*, and this app fetches from an Esri
  ///     service. Nothing read settles whether raster tile access from a
  ///     third-party map library triggers it. If it is owed, the same page
  ///     allows it to live *"in a window that is accessible from a menu or
  ///     button"* — so the "ⓘ" and App Info would already satisfy it, which
  ///     makes it cheaper to cover than to answer. Flagged for Michael.
  static const esriWorldImagery = TileSource(
    id: 'esri_world_imagery',
    name: 'Esri World Imagery',
    category: TileCategory.satellite,
    urlTemplate:
        'https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}',
    attribution:
        'Sources: Esri, Vantor, Earthstar Geographics, and the GIS User Community',
    shortAttribution: 'Sources: Esri and others — tap ⓘ',
    poweredByCredit: 'Powered by Esri',
    attributionUrl:
        'https://www.arcgis.com/home/item.html?id=10df2279f9684e4a9f6a7f08febac2a9',
    maxZoom: 19,
  );

  static const all = [openStreetMap, openTopoMap, esriWorldImagery];

  /// The source with [id], or null if this build has none by that id.
  static TileSource? tryById(String id) =>
      all.where((s) => s.id == id).firstOrNull;

  /// The source with [id]. **Throws for an unknown id rather than
  /// substituting a default.** Task 11.231: this used to fall back to
  /// [openStreetMap] silently, which let a test pass while deleting the
  /// wrong source's tiles entirely (11.230's fixture asked for `'osm'`,
  /// got OpenStreetMap back, and the delete went looking under
  /// `tiles/osm_standard/` while the files were under `tiles/osm/`, so
  /// nothing was removed at all and the neighbour "survived" because
  /// nothing had happened to it). A lookup that cannot fail is a lookup
  /// that cannot be trusted. Callers that can show an unknown id to a
  /// person (a manifest entry) should use [tryById] instead and say so.
  static TileSource byId(String id) {
    final source = tryById(id);
    if (source == null) {
      throw ArgumentError.value(id, 'id', 'No tile source with this id');
    }
    return source;
  }
}
