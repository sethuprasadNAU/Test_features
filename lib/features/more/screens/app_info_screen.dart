import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../../map/services/tile_sources.dart';
import '../../map/widgets/map_furniture.dart';

/// Task 11.133 item 3 — what build am I on, and who made these maps.
///
/// **The version is here because a bug report needs it, not because the screen
/// looked bare.** Michael has a debug-signed Android APK, an iOS build and a
/// macOS build in circulation on his own devices, and until now a beta tester
/// reporting a problem had no way to say which one they were holding. A report
/// that cannot be tied to a build gets read against the wrong commit.
///
/// **And it is read from the build, never from a constant.** A version string
/// typed into Dart is a hand-maintained list — this project's oldest defect
/// class — and a version number is the worst possible place for one, because
/// it is the single field the whole report is keyed on and it is wrong the
/// first time somebody forgets to bump it. [PackageInfo] reads what the
/// installer actually shipped: on Android the `PackageManager`'s
/// `versionName`/`versionCode`, on Apple platforms `CFBundleShortVersionString`
/// and `CFBundleVersion`. If the pubspec and the binary ever disagree, this
/// screen shows the binary, which is the one the tester is running.
///
/// The full map attributions live here too, because they have to live
/// somewhere reachable: the map credit is shortened for one basemap and the
/// "ⓘ" beside it points here for the rest. See `tile_sources.dart` for each
/// provider's terms and the verdict taken on them.
///
/// Task 11.286 item 1 — the guide link. **Here rather than a fifteenth row on
/// `MoreScreen`**: this screen is already the app's one page of reference
/// material (build number, map credits), the guide is reference material
/// too, and a beta tester who came here for a build number to paste into a
/// report is exactly the person who might also want the thing that explains
/// what they're looking at. Growing the More list is not free; growing this
/// one page by one more reference link is what it's already for.
class AppInfoScreen extends StatefulWidget {
  const AppInfoScreen({super.key});

  /// The one place this address is written for the guide. Task 11.286: "one
  /// address, one place, so there is one thing to change." (The domain also
  /// appears in `tile_user_agent.dart`'s User-Agent string, for OpenStreetMap's
  /// tile-usage policy — a different purpose, not a second copy of this link.)
  static const _guideUrl =
      'https://dynamic-and-active-systems-lab.github.io/tritrack-site/docs/';

  /// **Where every "tell TriTrack support" sentence in the app leads** (task
  /// 11.324, item 4). TriTrack runs one central server (`CLAUDE.md`, standing
  /// decision 3), so a person with a server problem has nobody local to ask;
  /// they ask the project. The website's Support page says how.
  static const _supportUrl =
      'https://dynamic-and-active-systems-lab.github.io/tritrack-site/support/';

  @override
  State<AppInfoScreen> createState() => _AppInfoScreenState();
}

class _AppInfoScreenState extends State<AppInfoScreen> {
  Future<PackageInfo>? _info;

  @override
  void initState() {
    super.initState();
    _info = PackageInfo.fromPlatform();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('App Info')),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          FutureBuilder<PackageInfo>(
            future: _info,
            builder: (context, snapshot) {
              return ListTile(
                leading: const Icon(Icons.info_outline),
                title: const Text('Version'),
                // **Selectable, and that is the point of the screen.** Somebody
                // reporting a problem has to get this string into an email or a
                // message, and a version they have to squint at and retype is a
                // version that arrives wrong — the retype-a-value class task
                // 11.37 named. Long-press copies it.
                subtitle: SelectableText(_versionLine(snapshot)),
              );
            },
          ),
          const Divider(),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Text('Map data and imagery', style: theme.textTheme.titleSmall),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(
              'TriTrack\'s basemaps come from these providers. Their credit '
              'on the map is a condition of use and cannot be turned off; the '
              'full text and licenses are here.',
              style: theme.textTheme.bodySmall,
            ),
          ),
          for (final source in TileSources.all)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(source.name, style: theme.textTheme.titleSmall),
                  const SizedBox(height: 2),
                  SelectableText(
                    source.attribution,
                    style: theme.textTheme.bodySmall,
                  ),
                  // Task 11.134 item 3 — the other half of the same four
                  // words. Esri's terms allow this credit behind a menu or
                  // button; this screen and the map's "ⓘ" are both that, so
                  // it is in both rather than argued about.
                  if (source.poweredByCredit != null)
                    SelectableText(
                      source.poweredByCredit!,
                      style: theme.textTheme.bodySmall,
                    ),
                  if (source.attributionUrl != null)
                    AttributionLink(
                      label: 'License and data sources',
                      url: source.attributionUrl!,
                    ),
                  const SizedBox(height: 4),
                ],
              ),
            ),
          const Divider(),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Text('User guide', style: theme.textTheme.titleSmall),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(
              'Opens a web page with instructions for recording bearings, '
              'syncing and managing tags. You will need cell or wifi '
              'coverage.',
              style: theme.textTheme.bodySmall,
            ),
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: AttributionLink(
              label: 'Open the guide',
              url: AppInfoScreen._guideUrl,
            ),
          ),
          const Divider(),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Text('TriTrack support', style: theme.textTheme.titleSmall),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(
              'For a problem with the app or the server, or a question. '
              'Include the version at the top of this screen.',
              style: theme.textTheme.bodySmall,
            ),
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: AttributionLink(
              label: 'Contact TriTrack support',
              url: AppInfoScreen._supportUrl,
            ),
          ),
        ],
      ),
    );
  }

  /// **Never a version number the app made up.**
  ///
  /// While the platform read is in flight this says so, and if it fails it
  /// says that too and names what to do instead. The tempting alternative — a
  /// hard-coded fallback — would put a plausible, wrong version in front of
  /// somebody who is about to paste it into a bug report, and they would have
  /// no way to tell. An honest "could not read it" costs one question; a
  /// confident wrong answer costs a misfiled report nobody ever untangles.
  static String _versionLine(AsyncSnapshot<PackageInfo> snapshot) {
    if (snapshot.hasError) {
      return 'Could not read this build’s version. Please say how you '
          'installed the app, and roughly when, when you report a problem.';
    }
    final info = snapshot.data;
    if (info == null) return 'Reading…';
    return '${info.version} (build ${info.buildNumber})';
  }
}
