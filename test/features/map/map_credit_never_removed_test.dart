import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tritrack/features/map/services/tile_sources.dart';
import 'package:tritrack/features/map/widgets/map_furniture.dart';

/// Task 11.133 item 2 — **the credit gets smaller; it never disappears.**
///
/// `tile_sources.dart` has said since the sources were added that *"every one
/// of these providers' terms require on-screen credit; never remove the
/// attribution widget."* That is a licence term, not a style rule, and task
/// 11.133 shortened one of the three credits — so it is exactly the moment
/// the sentence stops being self-evidently true and needs an instrument.
///
/// **What is checked here is the invariant, not the three current strings.**
/// A future basemap gets these assertions for free by being in
/// [TileSources.all]; a future task that empties a credit, or shortens one to
/// nothing, or shows a short form with no way to reach the rest, fails here
/// and is told why. What is deliberately *not* checked is whether a given
/// short form is legally sufficient — no test can know that. The reasoning
/// per provider, with the sentences it rests on and the date they were read,
/// is on each source in `tile_sources.dart`.
void main() {
  group('every basemap credits its provider on screen', () {
    for (final source in TileSources.all) {
      test('${source.name} has a full attribution and shows something',
          () {
        expect(
          source.attribution.trim(),
          isNotEmpty,
          reason: '${source.name} would be drawn with no credit at all. '
              'Showing it is a condition of using these tiles.',
        );
        expect(
          source.onScreenAttribution.trim(),
          isNotEmpty,
          reason: '${source.name} has a short form that shows nothing, which '
              'is the same as removing the credit.',
        );
      });

      test('${source.name}: a shortened credit still names its provider', () {
        final short = source.shortAttribution;
        if (short == null) return; // Full text on screen: nothing to check.
        // The one thing every provider read on 2026-09-02 agreed on, whatever
        // else they differ about: the *name* stays visible. OpenStreetMap's
        // guidelines put it hardest — "the attribution format should not
        // require individuals to interact with the map to see the
        // attribution" — and Esri's short-screen allowance is still an
        // allowance to abbreviate the list, not to drop the source.
        //
        // `name` is the display name of the basemap, whose first word is the
        // organisation in all three cases; matching on that rather than on a
        // hand-listed set of provider names keeps this from becoming the
        // hand-maintained list it exists to replace.
        final provider = source.name.split(' ').first;
        expect(
          short,
          contains(provider),
          reason: '${source.name}\'s shortened credit does not name '
              '"$provider". A short form may drop the list; it may not drop '
              'the party being credited.',
        );
        expect(
          short.length,
          lessThan(source.attribution.length),
          reason: 'a "short" form no shorter than the full text is a sign the '
              'two have drifted apart — check which one the map is painting.',
        );
      });
    }
  });

  testWidgets('an abbreviated credit always offers the way to the rest',
      (tester) async {
    // The OpenStreetMap attribution guidelines require "a way to access more
    // information, including origin and licence of the data", and Esri's
    // require "an expandable UI to display all names when they can not be
    // displayed on small screens". Both are the same widget: the "ⓘ". A
    // shortened credit with no way to reach the full text is the failure this
    // asserts against.
    for (final source in TileSources.all.where((s) => s.isAbbreviated)) {
      expect(
        source.attributionUrl,
        isNotNull,
        reason: '${source.name} shows a shortened credit and offers no '
            'licence page to reach the rest at.',
      );
    }

    // And the button is actually rendered when a caller supplies the handler.
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.bottomLeft,
            child: SizedBox(
              width: 390,
              child: MapAttribution(
                source: TileSources.esriWorldImagery,
                onShowDetails: () {},
              ),
            ),
          ),
        ),
      ),
    );
    expect(find.byIcon(Icons.info_outline), findsOneWidget);
  });

  testWidgets('the credit text still lets a pointer through; the ⓘ does not',
      (tester) async {
    // Task 11.131's bearing tip can be dragged out over the bottom band and
    // has to stay grabbable, and a pan starting on the credit should pan the
    // map — which is why the band is pointer-transparent. Task 11.133 put a
    // button in it, so the transparency is no longer free and is asserted
    // here rather than assumed: everything except the ⓘ still passes through.
    var behindTaps = 0;
    var infoTaps = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Stack(
            children: [
              Positioned.fill(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => behindTaps++,
                ),
              ),
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: MapAttribution(
                  source: TileSources.openStreetMap,
                  onShowDetails: () => infoTaps++,
                ),
              ),
            ],
          ),
        ),
      ),
    );

    final band = tester.getRect(find.byType(MapAttribution));
    // The left-hand end of the band, where the credit text is.
    await tester.tapAt(Offset(band.left + 10, band.center.dy));
    await tester.pump();
    expect(
      behindTaps,
      1,
      reason: 'a tap on the credit text was swallowed by the band. That is '
          'the map losing a pan, and task 11.131 losing the grab that pulls a '
          'dragged bearing back in.',
    );
    expect(infoTaps, 0);

    await tester.tap(find.byIcon(Icons.info_outline));
    await tester.pump();
    expect(
      infoTaps,
      1,
      reason: 'the ⓘ is the one part of the band that must take a pointer — '
          'without it a shortened credit has no way to show the rest.',
    );
    expect(behindTaps, 1);
  });
}
