import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart' as ll;

import '../../../core/providers/gps_provider.dart';
import '../../../core/providers/map_settings_provider.dart';
import '../../map/map_camera_target.dart';
import '../../map/services/cached_tile_provider.dart';
import '../../map/widgets/map_furniture.dart';

/// The four corners of an axis-aligned bounding box, in plain degrees.
class ExtentResult {
  const ExtentResult({
    required this.minLat,
    required this.minLon,
    required this.maxLat,
    required this.maxLon,
  });

  final double minLat;
  final double minLon;
  final double maxLat;
  final double maxLon;
}

/// Pan-and-zoom extent picker: rather than typing four raw lat/lon numbers
/// (not good for human input), the field user navigates a real basemap to
/// each corner of the project area and taps "Set corner" — this screen
/// hands the resulting bounding box back to Project Setup.
class ProjectExtentPickerScreen extends ConsumerStatefulWidget {
  const ProjectExtentPickerScreen({super.key, this.initial});

  final ExtentResult? initial;

  @override
  ConsumerState<ProjectExtentPickerScreen> createState() => _ProjectExtentPickerScreenState();
}

class _ProjectExtentPickerScreenState extends ConsumerState<ProjectExtentPickerScreen> {
  final _mapController = MapController();

  ll.LatLng? _cornerA;
  ll.LatLng? _cornerB;

  late ll.LatLng _cameraCenter;
  double _cameraZoom = MapCameraTarget.worldViewZoom;
  bool _centeredOnGps = false;

  @override
  void initState() {
    super.initState();
    final initial = widget.initial;
    if (initial != null) {
      _cornerA = ll.LatLng(initial.minLat, initial.minLon);
      _cornerB = ll.LatLng(initial.maxLat, initial.maxLon);
      _cameraCenter = ll.LatLng(
        (initial.minLat + initial.maxLat) / 2,
        (initial.minLon + initial.maxLon) / 2,
      );
      _centeredOnGps = true; // don't override an already-set extent with GPS
      _cameraZoom = 14;
    } else {
      // Task 11.103. This was `LatLng(0, 0)` — the Gulf of Guinea at street
      // zoom, offered to somebody about to draw their study area. Until GPS
      // arrives (the build below moves the camera when it does) the honest
      // opening view is the whole planet, which asserts nothing.
      _cameraCenter = MapCameraTarget.worldViewCenter;
      _cameraZoom = MapCameraTarget.worldViewZoom;
    }
  }

  @override
  Widget build(BuildContext context) {
    final tileSourceAsync = ref.watch(selectedTileSourceProvider);
    final tileSource = tileSourceAsync.value;
    final gps = ref.watch(gpsPositionProvider).value;

    if (!_centeredOnGps && gps != null) {
      _centeredOnGps = true;
      _cameraCenter = ll.LatLng(gps.latitude, gps.longitude);
      _cameraZoom = 14;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _mapController.move(_cameraCenter, 14);
      });
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Set Project Extent')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Text(
              'Pan and zoom to one corner of the project area, tap "Set corner A", '
              'then do the same for the opposite corner.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
          Expanded(
            child: tileSource == null
                ? const Center(child: CircularProgressIndicator())
                : Stack(
                    alignment: Alignment.center,
                    children: [
                      FlutterMap(
                        mapController: _mapController,
                        options: MapOptions(
                          initialCenter: _cameraCenter,
                          initialZoom: _cameraZoom,
                          minZoom: 2,
                          onMapEvent: (event) => _cameraCenter = event.camera.center,
                        ),
                        children: [
                          TileLayer(
                            urlTemplate: tileSource.urlTemplate,
                            subdomains: tileSource.subdomains,
                            maxZoom: tileSource.maxZoom.toDouble(),
                            tileProvider: CachedTileProvider(source: tileSource),
                          ),
                          if (_cornerA != null && _cornerB != null)
                            PolygonLayer(
                              polygons: [
                                Polygon(
                                  points: [
                                    ll.LatLng(_cornerA!.latitude, _cornerA!.longitude),
                                    ll.LatLng(_cornerA!.latitude, _cornerB!.longitude),
                                    ll.LatLng(_cornerB!.latitude, _cornerB!.longitude),
                                    ll.LatLng(_cornerB!.latitude, _cornerA!.longitude),
                                  ],
                                  color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.15),
                                  borderColor: Theme.of(context).colorScheme.primary,
                                  borderStrokeWidth: 2,
                                ),
                              ],
                            ),
                          MarkerLayer(
                            markers: [
                              if (_cornerA != null)
                                Marker(
                                  point: _cornerA!,
                                  width: 32,
                                  height: 32,
                                  child: const Icon(Icons.location_on, color: Colors.red),
                                ),
                              if (_cornerB != null)
                                Marker(
                                  point: _cornerB!,
                                  width: 32,
                                  height: 32,
                                  child: const Icon(Icons.location_on, color: Colors.blue),
                                ),
                            ],
                          ),
                        ],
                      ),
                      const IgnorePointer(
                        child: Icon(Icons.add, size: 28),
                      ),
                      // **Task 11.135 — verdict: show it, and it is the
                      // cheapest of the five.**
                      //
                      // This screen exists so somebody can look at the ground
                      // and say "the project is this rectangle". With no
                      // tiles it is a crosshair over nothing and the person
                      // is being asked to draw a boundary they cannot see —
                      // and the map they are looking at is very often ground
                      // they have never downloaded, which is exactly when
                      // this fails. The map area carries no other furniture
                      // at all (one crosshair, drawn at the centre), so a
                      // band in the top corner covers nothing anybody is
                      // reading, and it is up only while tiles are missing.
                      const Positioned(
                        top: 12,
                        left: 12,
                        right: 12,
                        child: TilesNotLoadingBand(
                          bannerKey:
                              ValueKey('extent-picker-tiles-not-loading'),
                        ),
                      ),
                    ],
                  ),
          ),
          SafeArea(
            minimum: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () => setState(() => _cornerA = _cameraCenter),
                        child: Text(_cornerA == null ? 'Set corner A' : 'Corner A ✓'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () => setState(() => _cornerB = _cameraCenter),
                        child: Text(_cornerB == null ? 'Set corner B' : 'Corner B ✓'),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                SizedBox(
                  height: 48,
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: _cornerA == null || _cornerB == null ? null : _save,
                    child: const Text('USE THIS EXTENT', style: TextStyle(fontWeight: FontWeight.w800)),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  void _save() {
    final a = _cornerA!;
    final b = _cornerB!;
    Navigator.of(context).pop(ExtentResult(
      minLat: a.latitude < b.latitude ? a.latitude : b.latitude,
      maxLat: a.latitude > b.latitude ? a.latitude : b.latitude,
      minLon: a.longitude < b.longitude ? a.longitude : b.longitude,
      maxLon: a.longitude > b.longitude ? a.longitude : b.longitude,
    ));
  }
}
