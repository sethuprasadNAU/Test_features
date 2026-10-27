import 'package:flutter_test/flutter_test.dart';

import 'support/app_boot_helper.dart';
import 'support/complete_identity_setup.dart';
import 'support/fake_shared_preferences.dart';

void main() {
  setUp(installFakeSharedPreferences);

  testWidgets('App boots to the Main Map tab with all 5 tabs present', (tester) async {
    final container = await pumpAppForTest(tester);
    addTearDown(container.dispose);
    await completeIdentitySetup(tester);

    // A fresh install has no active project yet, so the Main Map tab shows
    // its empty state rather than the map itself.
    expect(find.text('No active project'), findsOneWidget);
    for (final label in ['Map', 'Record', 'Compass', 'Position', 'More']) {
      expect(find.text(label), findsOneWidget);
    }
  });
}
