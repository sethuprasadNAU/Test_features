import 'dart:convert';

import 'package:tritrack/features/map/services/tile_sources.dart';

/// **Task 11.134 item 2 — one mechanism for all three providers, and the
/// reasoning for the shape it took.**
///
/// The app's map credits are `const` strings, and one of them was already
/// wrong: it named **Maxar**, a company renamed **Vantor**, while the Esri
/// service it credits had been publishing the new name for some time. Nothing
/// in the app or the suite would ever have said so. **Showing the credit is a
/// condition of the tile licences, so a stale credit is a breach rather than
/// a typo**, and Esri's own instruction is to read `copyrightText` from the
/// service and *"frequently verify names as data source providers can
/// change"* — neither of which a `const` can do.
///
/// ## The two shapes, priced against each other
///
/// **Rejected: fetch the credit at runtime, constant as offline fallback.**
/// It is what Esri's instruction literally describes, and it is wrong here
/// for four reasons that compound. It puts a network call behind a licence
/// condition, on a screen that has none today and on a device that is offline
/// as its *normal* condition — so in the field the fallback constant is what
/// shows anyway, and the constant is not removed, only shadowed. It makes the
/// text painted on the map come from a third-party response, which is a new
/// place for arbitrary text to arrive on screen. It gives two sources of
/// truth for one string, which is the defect class, not a fix for it. And two
/// of the three providers publish no machine-readable field at all — there is
/// nothing to fetch for OpenStreetMap or OpenTopoMap, so runtime fetching
/// would cover one provider and leave the same defect twice.
///
/// **Chosen: keep the constants, and check them against the providers on a
/// schedule.** It cannot break the app or the map. It covers all three
/// providers, because a check may read an HTML page and a human's eye where a
/// running app may not. It catches drift in days rather than never. What it
/// buys is honestly less than runtime fetching would: **drift is caught when
/// the check runs and somebody reads the red**, not the moment it happens.
/// That is the whole cost, and it is written here rather than left to be
/// discovered.
///
/// ## Two links, each checked by the instrument that can
///
/// The chain from a provider's published text to the words on the map has two
/// links, and they fail differently:
///
///  1. **provider → the recorded [publishedCredit] here.** This is the link
///     that broke on Maxar. It can only be checked against the network, so it
///     is checked by `test/network/tile_credit_freshness_test.dart`, which is
///     tagged `network`, skipped by default, and run on a schedule by
///     `.github/workflows/tile-credit-freshness.yml`.
///  2. **the recorded text → the app's `const`.** No network needed, so it is
///     checked on **every commit** by
///     `test/features/map/tile_credit_freshness_test.dart`. A constant edited
///     to say something the provider does not publish fails there in seconds.
///
/// ## Where this derivation stops
///
/// [requiredTokens] is the honest reach of link 2, and it is deliberately a
/// containment check rather than string equality, because two of the three
/// app credits are legitimately not verbatim copies:
///
///   * **OpenTopoMap publishes its required text in German.** The app shows
///     an English rendering. Equality is impossible; what must survive
///     translation is every proper name and licence token.
///   * **Esri publishes `Source: …` and recommends `Sources: Name A, Name
///     B…`** for the on-screen form. The prefix differs by their own
///     recommendation; the list of names is what matters.
///
/// So this check answers *"does the app still credit everyone the provider
/// currently credits?"* It does **not** answer *"is the app's wording the
/// wording the provider would prefer?"* — that stays a human reading, and the
/// verdicts from the last one are on each source in `tile_sources.dart`.
///
/// There is deliberately **no list of retired names to forbid**. It was
/// considered: `Maxar` in a forbidden list would have caught the actual
/// defect a second way. It is not here because it would be a hand-maintained
/// list acting as a control, which is this project's oldest defect class —
/// and it is not needed, because a rename removes the *new* name from the app
/// credit as surely as it leaves the old one, and [requiredTokens] catches
/// that from the provider's side.
class TileCreditProbe {
  const TileCreditProbe({
    required this.sourceId,
    required this.probeUrl,
    required this.extract,
    required this.publishedCredit,
    required this.requiredTokens,
    required this.recordedOn,
    required this.relationNote,
    this.bodyEncoding = utf8,
  });

  /// The [TileSource] this covers. Every source in [TileSources.all] must
  /// have exactly one probe — held by the offline test, so a fourth basemap
  /// cannot be added with no freshness check behind its credit.
  final String sourceId;

  /// Where the provider publishes the text it requires.
  final String probeUrl;

  /// Pulls the required credit out of what [probeUrl] returns. Returns the
  /// empty string when it is not there at all, which the network check
  /// reports as drift rather than as an error — a provider that reorganised
  /// its page is exactly the event this is watching for.
  final String Function(String body) extract;

  /// What [extract] returned on [recordedOn], verbatim.
  final String publishedCredit;

  /// Every name and licence token from [publishedCredit] that must still
  /// appear in the app's full on-screen credit. See "where this derivation
  /// stops" above for why this is containment and not equality.
  final List<String> requiredTokens;

  final String recordedOn;

  /// How [probeUrl]'s bytes are to be decoded.
  ///
  /// **On the probe, not sniffed from the response.** OpenTopoMap's about
  /// page is ISO-8859-1 and declares it in a `<meta>` tag inside the document
  /// — not in the `Content-Type` header, which is where a client would look.
  /// Read as UTF-8 its "©" comes back as a replacement character and the
  /// check fails naming an encoding problem as a credit change, which is a
  /// wrong cause in an instrument: exactly what this project keeps finding.
  /// Measured on 2026-09-02, not assumed.
  final Encoding bodyEncoding;

  /// How the app's credit relates to [publishedCredit], in one sentence, so
  /// the next reader does not have to re-derive why it is not a copy.
  final String relationNote;
}

/// Collapses runs of whitespace and trims — HTML sources wrap their text.
String _normalise(String text) => text.replaceAll(RegExp(r'\s+'), ' ').trim();

String _stripTags(String html) => html.replaceAll(RegExp('<[^>]*>'), '');

/// The `<code>…</code>` immediately after [marker], tags stripped.
///
/// **Anchored on the sentence that introduces it, not on "the first `<code>`
/// on the page".** That page has an earlier `<code>` block giving the tile
/// URL template, so "the first one" would silently check the wrong thing, and
/// a check that reads the wrong thing and passes is worse than no check.
String _codeBlockAfter(String body, String marker) {
  final at = body.indexOf(marker);
  if (at < 0) return '';
  final open = body.indexOf('<code>', at);
  if (open < 0) return '';
  final close = body.indexOf('</code>', open);
  if (close < 0) return '';
  return _normalise(_stripTags(body.substring(open + '<code>'.length, close)));
}

const List<TileCreditProbe> tileCreditProbes = [
  TileCreditProbe(
    sourceId: 'osm_standard',
    probeUrl: 'https://osmfoundation.org/wiki/Licence/Attribution_Guidelines',
    extract: _extractOsmForm,
    publishedCredit: '© OpenStreetMap contributors',
    requiredTokens: ['© OpenStreetMap contributors'],
    recordedOn: '2026-09-02',
    relationNote:
        'The OSM Foundation attribution guidelines name this exact form as '
        'acceptable, so the app credit is that form verbatim. The check is '
        'that the guidelines page still names it.',
  ),
  TileCreditProbe(
    sourceId: 'opentopomap',
    probeUrl: 'https://opentopomap.org/about',
    extract: _extractOpenTopoMapLicenceText,
    publishedCredit:
        'Kartendaten: © OpenStreetMap-Mitwirkende, SRTM | Kartendarstellung: '
        '© OpenTopoMap (CC-BY-SA)',
    requiredTokens: ['OpenStreetMap', 'SRTM', 'OpenTopoMap', 'CC-BY-SA'],
    recordedOn: '2026-09-02',
    bodyEncoding: latin1,
    relationNote:
        'OpenTopoMap publishes its required text in German, under "Als '
        'Lizenztext sollte Folgendes deutlich sichtbar sein". The app shows '
        'an English rendering of the same two credits, so what is checked is '
        'that every name and licence token survived the translation.',
  ),
  TileCreditProbe(
    sourceId: 'esri_world_imagery',
    probeUrl:
        'https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer?f=pjson',
    extract: _extractEsriCopyrightText,
    publishedCredit:
        'Source: Esri, Vantor, Earthstar Geographics, and the GIS User '
        'Community',
    requiredTokens: [
      'Esri',
      'Vantor',
      'Earthstar Geographics',
      'GIS User Community',
    ],
    recordedOn: '2026-09-02',
    relationNote:
        'The service publishes "Source: …" in its own metadata; Esri\'s '
        'display guidance recommends the on-screen form be prefixed '
        '"Sources: Name A, Name B…", which is what the app shows. The prefix '
        'differs by their recommendation; the list of names must not. This '
        'is the probe that would have caught Maxar.',
  ),
];

String _extractOsmForm(String body) =>
    body.contains('© OpenStreetMap contributors')
    ? '© OpenStreetMap contributors'
    : '';

String _extractOpenTopoMapLicenceText(String body) => _codeBlockAfter(
  body,
  'Als Lizenztext sollte Folgendes deutlich sichtbar sein',
);

String _extractEsriCopyrightText(String body) {
  final decoded = jsonDecode(body);
  if (decoded is! Map) return '';
  final text = decoded['copyrightText'];
  return text is String ? _normalise(text) : '';
}

/// **Link 2, offline.** Every name the provider publishes, still credited by
/// the app? Returns one sentence per failure, empty when the credit is fresh.
///
/// [creditOverride] exists so the detection proof can point this at a
/// deliberately stale string without editing the app.
List<String> staleCreditFailures(
  TileCreditProbe probe, {
  String? creditOverride,
}) {
  final source = TileSources.all.firstWhere((s) => s.id == probe.sourceId);
  final credit = creditOverride ?? source.attribution;
  return [
    for (final token in probe.requiredTokens)
      if (!credit.contains(token))
        'The ${source.name} credit no longer names "$token", which '
            '${probe.probeUrl} published on ${probe.recordedOn} as part of '
            '"${probe.publishedCredit}". Showing the credit is a licence '
            'condition, so a name dropped from it is a breach. Fix the '
            'attribution in lib/features/map/services/tile_sources.dart, or '
            '— if the provider itself dropped the name — update this probe '
            'and say so in the source\'s doc comment.',
  ];
}

/// **Link 1, network.** Is what the provider publishes still what was
/// recorded here? Returns null when it is, a sentence naming both when not.
String? publishedCreditDrift(TileCreditProbe probe, String body) {
  final live = probe.extract(body);
  if (live == probe.publishedCredit) return null;
  if (live.isEmpty) {
    return 'Could not find the required credit at ${probe.probeUrl} at all. '
        'It read "${probe.publishedCredit}" on ${probe.recordedOn}. Either '
        'the page has been reorganised or the provider has withdrawn it; '
        'read it and update the probe and the app credit together.';
  }
  return '${probe.probeUrl} now publishes "$live". It published '
      '"${probe.publishedCredit}" on ${probe.recordedOn}. Update the probe '
      'and the app credit in lib/features/map/services/tile_sources.dart '
      'together — this is exactly the change that renamed Maxar to Vantor '
      'and went unnoticed.';
}
