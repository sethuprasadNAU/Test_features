// **The pilot video: one Take on map sweep** (`/w-32`), recorded at about 15 s
// and played back four times faster by `record_video.sh`.
//
// Driven by `record_video.sh`, never by a bare `flutter test`. This does what
// `capture_test.dart`'s Take on map block does — same fixture, same scripted
// compass (`take_on_map.dart`) — but slowly enough to watch, and it announces
// itself on stdout so the script can start and stop `simctl io ... recordVideo`
// around exactly the part worth watching rather than the app booting.
//
// **Why the recording is started by what this prints and not by a timer.** The
// boot, the first fix and the basemap tiles arriving take a different time on
// every run, and a fixed delay would put some of that in front of the clip. The
// two lines below are the whole protocol:
//
//   `VIDEO_START` — the screen is ready and nothing is moving; start recording.
//   `VIDEO_STOP`  — the sweep is released and has been held on screen; stop.
//
// The still first frame the guide would show for readers who do not play the
// clip is the `take-on-map` picture itself: the clip begins on exactly that
// screen, so the poster is regenerated with everything else and cannot drift.

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'harness.dart';
import 'readiness.dart';
import 'take_on_map.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('a Take on map sweep, for the pilot video',
      timeout: const Timeout(Duration(minutes: 10)), (tester) async {
    final container = await bootApp(tester);
    addTearDown(container.dispose);
    enableGpsFix();
    await settle(tester);

    await addTodaysBearings(container);
    await selectSageOnRecord(container);
    await goTo(tester, container, '/record');
    if (!await openTakeOnMap(tester)) {
      // ignore: avoid_print
      print('VIDEO_FAILED: the Take on map button is not on the Record screen');
      return;
    }
    setFakeHeading(sweepStartDeg);
    await settle(tester, wait: const Duration(seconds: 1));
    // The same condition the still uses: basemap drawn, the two earlier
    // bearings and the pointing line on the layer, the live readout showing.
    await awaitReady(tester, container, 'take-on-map');

    // **Every frame the app asks for is drawn while the recorder runs.** The
    // test binding's default draws only the frames a test pumps, and `settle`
    // pumps every 120 ms, so the first recording came out at 7.4 frames a
    // second and looked choppy once played back four times faster.
    final usualPolicy = binding.framePolicy;
    binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

    // ignore: avoid_print
    print('VIDEO_START');
    // Let the recorder start before anything moves, and let the viewer see the
    // screen at rest: the clip's first frame is the poster.
    await settle(tester, wait: const Duration(seconds: 3));

    // A 7 s sweep, turned continuously rather than in steps: the compass is
    // moved by the clock every frame, and the faked compass stream samples it
    // every 100 ms the way a real one would. (The pictures' sweep moves in
    // 350 ms steps, which is fine for a still and jerky in a clip.)
    const sweepTime = Duration(seconds: 7);
    final sweep = await startSweep(tester, steps: 0);
    if (sweep != null) {
      final clock = Stopwatch()..start();
      while (clock.elapsed < sweepTime) {
        final done = clock.elapsedMilliseconds / sweepTime.inMilliseconds;
        setFakeHeading(sweepStartDeg + (sweepEndDeg - sweepStartDeg) * done);
        await tester.pump(const Duration(milliseconds: 16));
      }
      setFakeHeading(sweepEndDeg);
      await settle(tester, wait: const Duration(milliseconds: 600));
      await sweep.up();
    }
    // The released state, with Cancel, Retake and Confirm, held long enough to
    // read before the loop starts over.
    await settle(tester, wait: const Duration(seconds: 3));
    // ignore: avoid_print
    print('VIDEO_STOP');
    await settle(tester, wait: const Duration(seconds: 1));
    binding.framePolicy = usualPolicy;

    restoreHeading();
    await removeTodaysBearings(container);
  });
}
