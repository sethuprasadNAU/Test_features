import 'dart:io';

import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:tritrack/features/map/services/cached_tile_provider.dart';
import 'package:tritrack/features/map/services/offline_tile_downloader.dart';
import 'package:tritrack/features/map/services/tile_sources.dart';
import 'package:tritrack/features/map/services/tile_user_agent.dart';

import '../../support/dart_source.dart';
import '../../support/fake_path_provider.dart';

/// **Task 11.134 item 1 — kept measured rather than kept written down.**
///
/// The OpenStreetMap tile usage policy requires a `User-Agent` that identifies
/// the application and says traffic using a library default will be blocked.
/// **A block arrives as tiles that stop loading**, on the screen a field
/// technician uses all day, and quite possibly only once usage is high enough
/// to be noticed — which is the beta. Nothing in the app reports it and
/// nothing in CI can see it, so the guard has to sit at the request.
///
/// What the task measured, on 2026-09-02, before anything was designed:
///
///   * live tiles → `flutter_map (edu.nau.tritrack)`, from each `TileLayer`'s
///     `userAgentPackageName:`;
///   * **the bulk region downloader → `Dart/3.12 (dart:io)`**, because it
///     passed no headers at all. The SDK default, on the path that asks for
///     thousands of tiles.
///
/// The first two groups here re-run that measurement against a real
/// `HttpServer` on every commit — the header a socket actually received, not
/// the header a constant says it should be. The third holds the class shut:
/// **the identity is set in `CachedTileProvider`, so a seventh map screen
/// cannot forget it**, and the source guard fails if a `TileLayer` appears
/// without that provider or if `userAgentPackageName:` comes back.
void main() {
  late HttpServer server;
  late List<String?> agentsSeen;

  setUp(() async {
    agentsSeen = [];
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) {
      agentsSeen.add(request.headers.value('user-agent'));
      request.response
        ..statusCode = 200
        ..add(const [0x89, 0x50, 0x4E, 0x47]);
      request.response.close();
    });
  });

  tearDown(() => server.close(force: true));

  TileSource localSource() => TileSource(
    id: 'test_local',
    name: 'Local',
    category: TileCategory.street,
    urlTemplate: 'http://127.0.0.1:${server.port}/{z}/{x}/{y}.png',
    attribution: 'test',
  );

  test('the User-Agent names the app, not a library', () {
    // The two failing shapes, named rather than implied: the SDK default and
    // flutter_map's when nobody passed a package name.
    expect(tileUserAgent, contains('TriTrack'));
    expect(tileUserAgent, contains('edu.nau.tritrack'));
    expect(tileUserAgent, isNot(startsWith('Dart/')));
    expect(tileUserAgent, isNot(contains('flutter_map')));
    expect(
      tileUserAgent,
      contains('+http'),
      reason: 'the policy asks for a way to reach somebody',
    );
  });

  test(
    'a live tile request carries it, and flutter_map cannot overwrite it',
    () async {
      final provider = CachedTileProvider(source: localSource());
      // Constructing a TileLayer is what used to set the header. It uses
      // putIfAbsent, so this asserts the app's value survives contact with it.
      TileLayer(
        tileProvider: provider,
        urlTemplate: 'http://127.0.0.1:${server.port}/{z}/{x}/{y}.png',
        userAgentPackageName: 'something.else',
      );
      expect(provider.headers['User-Agent'], tileUserAgent);

      await http.get(
        Uri.parse('http://127.0.0.1:${server.port}/1/2/3.png'),
        headers: provider.headers,
      );
      expect(agentsSeen, [tileUserAgent]);
    },
  );

  test(
    'a bulk region download carries it — this is the one that was Dart/…',
    () async {
      installFakePathProvider();
      final result = await OfflineTileDownloader.downloadTiles(
        tiles: const [TileXY(5, 1, 2), TileXY(5, 1, 3)],
        source: localSource(),
      );
      expect(result.completed, 2, reason: 'the fixture server answers 200');
      expect(agentsSeen, hasLength(2));
      expect(agentsSeen, everyElement(tileUserAgent));
    },
  );

  group('no map screen can send a different identity', () {
    // Textual, deliberately: see test/support/dart_source.dart. Comments are
    // blanked first, so the doc comments in cached_tile_provider.dart that
    // discuss `userAgentPackageName` do not read as call sites.
    final sources = dartFilesUnder('lib')
        .map((f) => MapEntry(f.path, stripComments(f.readAsStringSync())))
        .toList();

    test('every TileLayer in lib/ uses CachedTileProvider', () {
      final offenders = <String>[];
      for (final entry in sources) {
        final layers = 'TileLayer('.allMatches(entry.value).length;
        final providers = 'CachedTileProvider('.allMatches(entry.value).length;
        if (layers > providers) {
          offenders.add(
            '${entry.key}: $layers TileLayer(, only $providers '
            'CachedTileProvider(',
          );
        }
      }
      expect(
        offenders,
        isEmpty,
        reason:
            'A TileLayer with flutter_map\'s own NetworkTileProvider '
            'sends "flutter_map (unknown)" — the library default the '
            'OpenStreetMap policy says it will block, and the app would '
            'report the block as a blank map. Pass '
            'tileProvider: CachedTileProvider(source: ...).\n'
            '${offenders.join('\n')}',
      );
    });

    test('userAgentPackageName has not come back', () {
      final offenders = [
        for (final entry in sources)
          if (entry.value.contains('userAgentPackageName')) entry.key,
      ];
      expect(
        offenders,
        isEmpty,
        reason:
            'It is inert — CachedTileProvider sets the header first and '
            'flutter_map only fills one in if absent — so a value here would '
            'read as the app\'s identity while changing nothing. One place '
            'names the app: tile_user_agent.dart.\n${offenders.join('\n')}',
      );
    });
  });
}
