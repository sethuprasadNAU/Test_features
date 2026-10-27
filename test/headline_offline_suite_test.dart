import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'support/app_boot_helper.dart';
import 'support/complete_identity_setup.dart';
import 'support/fake_shared_preferences.dart';

/// Task 10.15's named headline test: **the app is fully functional with the
/// server stack down and the network disabled.**
///
/// `TestWidgetsFlutterBinding` installs its own [HttpOverrides] for every
/// Flutter test file that answers any real `HttpClient` request with a
/// synthetic, non-2xx response rather than touching the network — so this
/// suite already cannot succeed by accident via a real socket. `scripts/
/// run_offline_suite.sh` runs this alongside the rest of `flutter test` with
/// the docker compose server stack explicitly brought down first, which is
/// the "explicit, named test run, not an assumption" the plan calls for.
///
/// This file is the one test in that run that actually exercises a full
/// boot: it drives the one flow every fresh install must complete —
/// first-run identity capture — through to the tab shell, proving the
/// promise rather than assuming it from the absence of a failure.
///
/// This also stands in for "a release build with no server URL configured
/// is fully functional" (10.15's other acceptance item): `ServerConfig` is
/// unconfigured by default (task 10.2), and nothing in this run ever sets
/// it, so reaching the tab shell here is that case exercised directly.
void main() {
  setUp(installFakeSharedPreferences);

  test(
    'a real HTTP request never reaches the network in this suite',
    () async {
      final response = await HttpClient()
          .getUrl(Uri.parse('http://example.invalid'))
          .then((request) => request.close());
      expect(
        response.statusCode,
        isNot(200),
        reason:
            "TestWidgetsFlutterBinding's HttpOverrides answers every real "
            'request synthetically — this pins that down rather than '
            'assuming it.',
      );
    },
  );

  testWidgets(
    'first run reaches the tab shell with no server and no network',
    (tester) async {
      final container = await pumpAppForTest(tester);
      addTearDown(container.dispose);

      expect(tester.takeException(), isNull);
      await completeIdentitySetup(tester);
      expect(tester.takeException(), isNull);

      // The Map tab's no-project empty state — reaching it proves the app
      // is past the identity gate and running normally, not stuck.
      expect(find.text('No active project'), findsOneWidget);
    },
  );
}
