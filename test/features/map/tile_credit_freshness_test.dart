import 'package:flutter_test/flutter_test.dart';
import 'package:tritrack/features/map/services/tile_sources.dart';

import '../../support/tile_credit_probes.dart';

/// **Task 11.134 item 2 — the half of the credit-freshness check that needs
/// no network, so it runs on every commit.**
///
/// The reasoning for the whole mechanism, and for why it is a scheduled check
/// rather than a runtime fetch, is in `test/support/tile_credit_probes.dart`.
/// This file holds link 2 of the chain: **the app's `const` credits still
/// name everyone the providers were recorded as crediting.** Link 1 — that
/// the recording still matches the live providers — is
/// `test/network/tile_credit_freshness_test.dart`, tagged `network`.
///
/// The last group is the **detection proof**: this check watched failing
/// against a deliberately stale constant, permanently, rather than once by
/// hand on the day it was written. A harness that patches a line in a file it
/// does not own dies silently when that file is refactored (task 11.125), so
/// nothing here patches anything — the stale credit is passed in as an
/// argument.
void main() {
  group('every basemap has a freshness probe behind its credit', () {
    test('one probe per tile source, and no orphans', () {
      final sourceIds = TileSources.all.map((s) => s.id).toSet();
      final probeIds = tileCreditProbes.map((p) => p.sourceId).toList();

      expect(
        probeIds.toSet(),
        sourceIds,
        reason:
            'A basemap with no probe is a licence condition nothing '
            'checks — which is the state task 11.134 found all three in. Add '
            'an entry to tileCreditProbes naming where that provider '
            'publishes the credit it requires.',
      );
      expect(
        probeIds.length,
        probeIds.toSet().length,
        reason: 'two probes for one source: the second silently decides',
      );
    });
  });

  group('the app still credits everyone the providers credit', () {
    for (final probe in tileCreditProbes) {
      test(probe.sourceId, () {
        final failures = staleCreditFailures(probe);
        expect(failures, isEmpty, reason: failures.join('\n\n'));
      });
    }
  });

  group('watched failing against a stale constant', () {
    test('a credit that drops a published name is caught', () {
      // The real defect, reconstructed: the Esri credit named Maxar for as
      // long as it took somebody to read the service metadata by hand.
      final esri = tileCreditProbes.firstWhere(
        (p) => p.sourceId == 'esri_world_imagery',
      );
      final failures = staleCreditFailures(
        esri,
        creditOverride:
            'Sources: Esri, Maxar, Earthstar Geographics, and the GIS User '
            'Community',
      );
      expect(failures, hasLength(1));
      expect(failures.single, contains('"Vantor"'));
      expect(
        failures.single,
        contains('tile_sources.dart'),
        reason:
            'a failure has to name the file to edit; a five-line CI tail '
            'is enough exactly when the last thing a check says is what it '
            'found',
      );
    });

    test('every probe catches its own credit being emptied', () {
      // Not just Esri. A probe whose requiredTokens list is empty would pass
      // anything at all, and would look identical to a passing check.
      for (final probe in tileCreditProbes) {
        expect(
          staleCreditFailures(probe, creditOverride: 'Map data'),
          isNotEmpty,
          reason:
              '${probe.sourceId} accepts a credit naming nobody, so it '
              'is not evidence about anything',
        );
      }
    });
  });

  group('the network half can tell drift from freshness', () {
    // The extractors are pure, so what they do to a body can be proved here
    // rather than only against the live providers — which means the network
    // test's green means "the provider still says this", not "the parser
    // happened to return the same empty string twice".
    test('a body carrying the recorded credit reports no drift', () {
      final esri = tileCreditProbes.firstWhere(
        (p) => p.sourceId == 'esri_world_imagery',
      );
      expect(
        publishedCreditDrift(
          esri,
          '{"copyrightText": "${esri.publishedCredit}"}',
        ),
        isNull,
      );
    });

    test('a renamed provider is reported, with both names', () {
      final esri = tileCreditProbes.firstWhere(
        (p) => p.sourceId == 'esri_world_imagery',
      );
      final drift = publishedCreditDrift(
        esri,
        '{"copyrightText": "Source: Esri, Maxar, Earthstar Geographics, and '
        'the GIS User Community"}',
      );
      expect(drift, isNotNull);
      expect(drift, contains('Maxar'));
      expect(drift, contains('Vantor'));
    });

    test('a page that no longer carries the credit is reported as missing', () {
      for (final probe in tileCreditProbes) {
        final drift = publishedCreditDrift(
          probe,
          probe.sourceId == 'esri_world_imagery' ? '{}' : '<html></html>',
        );
        expect(drift, isNotNull);
        expect(drift, contains('Could not find'));
      }
    });

    test('the OpenTopoMap extractor reads the licence block, not the URL '
        'block', () {
      // That page carries an earlier <code> giving the tile URL template.
      // "The first <code> on the page" would have checked the wrong thing
      // and passed.
      final otm = tileCreditProbes.firstWhere(
        (p) => p.sourceId == 'opentopomap',
      );
      const body = '''
<code>https://{a|b|c}.tile.opentopomap.org/{z}/{x}/{y}.png</code>
<p>Als Lizenztext sollte Folgendes deutlich sichtbar sein:<br/>
<code>Kartendaten: &copy; <a href="x">OpenStreetMap</a>-Mitwirkende, SRTM |
Kartendarstellung: &copy; <a href="y">OpenTopoMap</a>
(<a href="z">CC-BY-SA</a>)</code></p>''';
      expect(otm.extract(body.replaceAll('&copy;', '©')), otm.publishedCredit);
    });
  });
}
