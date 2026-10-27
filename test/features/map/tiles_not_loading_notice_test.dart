import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tritrack/features/map/services/tile_fetch_health.dart';
import 'package:tritrack/features/map/widgets/map_furniture.dart';

/// **Task 11.134 item 1, second half — what a person is told when tiles stop
/// arriving.**
///
/// Before this, nothing: a blocked app, a rate-limited one, a phone with no
/// signal and a provider outage were all a basemap that simply did not fill
/// in, which is indistinguishable from a basemap with nothing to draw. The
/// band on the Main Map is measured in `map_screen_space_budget_test.dart`
/// (that measurement is what shortened it to one line); this file holds the
/// signal's own behaviour and the words behind it.
void main() {
  setUp(TileFetchHealth.instance.reset);
  tearDown(TileFetchHealth.instance.reset);

  group('the signal', () {
    test('one failure is not a story; a screenful of them is', () {
      final health = TileFetchHealth.instance;
      for (var i = 0; i < TileFetchHealth.failureThreshold - 1; i++) {
        health.recordNetworkFailure();
        expect(
          health.failing.value,
          isFalse,
          reason:
              'a band that flickers on one late tile is a band people '
              'learn to ignore',
        );
      }
      health.recordNetworkFailure();
      expect(health.failing.value, isTrue);
    });

    test('one success clears it, immediately', () {
      final health = TileFetchHealth.instance;
      for (var i = 0; i < TileFetchHealth.failureThreshold; i++) {
        health.recordNetworkFailure();
      }
      expect(health.failing.value, isTrue);
      health.recordNetworkSuccess();
      expect(health.failing.value, isFalse);
    });

    test('a run of failures broken by a success never trips it', () {
      // The state a field technician is actually in at the edge of coverage:
      // most tiles arriving, some not. That is not "tiles are not arriving".
      final health = TileFetchHealth.instance;
      for (var i = 0; i < 20; i++) {
        health.recordNetworkFailure();
        health.recordNetworkFailure();
        health.recordNetworkSuccess();
      }
      expect(health.failing.value, isFalse);
    });

    test('it is a listenable, so a map does not have to poll it', () {
      final health = TileFetchHealth.instance;
      var notifications = 0;
      void listener() => notifications++;
      health.failing.addListener(listener);
      addTearDown(() => health.failing.removeListener(listener));

      for (var i = 0; i < TileFetchHealth.failureThreshold; i++) {
        health.recordNetworkFailure();
      }
      expect(notifications, 1);
      // Failures past the threshold must not re-notify — every tile in a
      // screenful failing would otherwise rebuild the map screen a dozen
      // times for one unchanged fact.
      health.recordNetworkFailure();
      expect(notifications, 1);
    });
  });

  group('what it says', () {
    test('names no cause, on the map or behind it', () {
      // The rule this project keeps relearning: the branch reached when the
      // code does not know why must not assert a cause. The fetch knows one
      // fact — nothing came back.
      const forbidden = [
        'blocked',
        'you are offline',
        'your network',
        'no internet',
        'rate limit',
      ];
      final text =
          '${TileFetchHealth.notLoadingMessage} '
                  '${TileFetchHealth.notLoadingDetail}'
              .toLowerCase();
      for (final claim in forbidden) {
        expect(
          text,
          isNot(contains(claim)),
          reason:
              'this message cannot know that "$claim" is what happened, '
              'and a wrong cause sends somebody to fix a network that is fine',
        );
      }
    });

    test('says what still works, and names one action', () {
      expect(TileFetchHealth.notLoadingDetail, contains('already downloaded'));
      expect(TileFetchHealth.notLoadingDetail, contains('recording a bearing'));
      expect(
        TileFetchHealth.notLoadingDetail,
        contains('App Info'),
        reason:
            'a report that cannot be tied to a build is read against the '
            'wrong commit — the version is on that screen',
      );
    });

    testWidgets('the detail is reachable and shows both halves', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showTilesNotLoadingSheet(context),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(find.text(TileFetchHealth.notLoadingMessage), findsOneWidget);
      expect(find.text(TileFetchHealth.notLoadingDetail), findsOneWidget);
    });
  });
}
