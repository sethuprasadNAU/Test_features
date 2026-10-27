import 'package:url_launcher_platform_interface/link.dart';
import 'package:url_launcher_platform_interface/url_launcher_platform_interface.dart';

/// A [UrlLauncherPlatform] a test can tell to succeed or fail, for
/// `AttributionLink` (task 11.286) — there is no real platform channel under
/// `flutter test`, so a widget that calls `launchUrl` needs this installed
/// first, the same reason `FakePathProviderPlatform` exists.
///
/// **Defaults to failing.** The failure path — showing the address instead of
/// doing nothing — is the one a test can actually see; the success path is
/// "the platform opened something", which a widget test cannot observe
/// either way, so there's no reason to default to it.
class FakeUrlLauncherPlatform extends UrlLauncherPlatform {
  FakeUrlLauncherPlatform({this.succeeds = false});

  bool succeeds;
  String? lastLaunchedUrl;

  @override
  LinkDelegate? get linkDelegate => null;

  @override
  Future<bool> launchUrl(String url, LaunchOptions options) async {
    lastLaunchedUrl = url;
    return succeeds;
  }
}

/// Installs [FakeUrlLauncherPlatform] and returns it so a test can flip
/// [FakeUrlLauncherPlatform.succeeds] or read [FakeUrlLauncherPlatform.lastLaunchedUrl].
/// Call once per test, e.g. in `setUp`.
FakeUrlLauncherPlatform installFakeUrlLauncher({bool succeeds = false}) {
  final fake = FakeUrlLauncherPlatform(succeeds: succeeds);
  UrlLauncherPlatform.instance = fake;
  return fake;
}
