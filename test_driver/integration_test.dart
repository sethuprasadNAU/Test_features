// Driver entry point for `flutter drive`, required to build a genuine
// `--release`/`--profile` app bundle for `integration_test/` tests (task
// 10.50, F13) — `flutter test integration_test/foo.dart -d <device>` has no
// build-mode flag at all and always runs a debug-equivalent configuration,
// so it cannot exercise `macos/Runner/Release.entitlements` or a real
// release `Info.plist`. `flutter drive` is the tool that actually supports
// `--release`.
import 'package:integration_test/integration_test_driver.dart';

Future<void> main() => integrationDriver();
