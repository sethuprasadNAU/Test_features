import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../viewshed/dem_tile_store.dart';
import '../models/offline_region.dart';
import '../providers/download_manager.dart';
import '../providers/offline_regions_provider.dart';
import '../services/offline_region_store.dart';
import '../services/tile_sources.dart';

/// The three things a person can do to one downloaded area — rename it,
/// download it again, delete it — shared by the "Offline Data" list
/// (`manage_offline_maps_screen.dart`) and the Offline Data Map's area sheet
/// (`offline_data_map_screen.dart`), so the two screens cannot drift on what
/// a delete says or does. Task 11.230.

/// `1.2MB`-style size, shared by the two offline screens.
String formatBytes(int bytes) {
  if (bytes < 1024) return '${bytes}B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)}KB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)}MB';
}

/// The names in [ids], for a sentence: one name, two names, or one name and
/// a count. An id not found in [all] is skipped rather than shown as
/// nothing, since an area can be renamed or deleted between when a count was
/// computed and when this reads it.
String areaNamesPhrase(Iterable<String> ids, List<OfflineRegion> all) {
  final names = <String>[];
  for (final id in ids) {
    final other = all.where((r) => r.id == id).firstOrNull;
    if (other != null) names.add('"${other.displayName}"');
  }
  if (names.isEmpty) return 'another area';
  if (names.length == 1) return names.single;
  if (names.length == 2) return '${names[0]} and ${names[1]}';
  return '${names[0]} and ${names.length - 1} other areas';
}

/// The names of the areas [region] shares tiles with. Used by the list row
/// and by the delete confirmation, so the two name the same neighbours the
/// same way. [areaNamesPhrase] is the same sentence for a set of ids that
/// is not one region's own `sharedWithIds` — the Erase tool's report of what
/// it kept, task 11.231.
String sharedWithPhrase(OfflineRegion region, List<OfflineRegion> all) =>
    areaNamesPhrase(region.sharedWithIds, all);

/// Whether [region]'s tile source is one this build still knows about.
/// Always true for an elevation area, which has no tile source. Task 11.231:
/// `TileSources.byId` now refuses an unknown id rather than silently
/// substituting OpenStreetMap, so a source renamed or retired in a later
/// build must be visible on the row instead — this is what a screen checks
/// before offering "Update", which would otherwise fail with no warning.
bool regionHasKnownSource(OfflineRegion region) {
  if (region.kind != OfflineRegionKind.tiles) return true;
  final id = region.sourceId;
  return id != null && TileSources.tryById(id) != null;
}

/// What a row says about a tile area whose recorded source this build no
/// longer has. Delete still works — it never looks the id up, it uses the
/// stored string directly (`OfflineRegionStore.deleteRegion`) — only
/// re-downloading it does not, because that has to ask a real tile
/// provider for tiles.
const String deadSourceSentence =
    'Downloaded with a map source this version no longer has. It can be '
    'deleted, but not updated.';

/// What the delete confirmation says. Public so a test can hold the sentence
/// against the numbers it is built from.
///
/// The figures come from the manifest's last reconcile — the walk of the
/// disk that produced the list the person is looking at — not from a second
/// walk at tap time. The delete itself recomputes which tiles to remove from
/// the manifest as it stands when the button is pressed
/// (`OfflineRegionStore.deleteRegion`), so a stale number here can only
/// misstate the size, never delete the wrong file; and the snackbar
/// afterwards reports what was measured going.
String deleteConfirmationSentence(
  OfflineRegion region,
  List<OfflineRegion> all,
) {
  final frees = formatBytes(region.exclusiveBytes);
  final shared = region.sharedBytes;
  final again = 'Getting it back means downloading it again, which needs a '
      'connection.';
  if (shared <= 0) {
    return 'Frees $frees on this device. $again';
  }
  final with_ = sharedWithPhrase(region, all);
  if (region.exclusiveBytes <= 0) {
    return 'Frees nothing on this device: every tile here is also covered by '
        '$with_ and stays. This only removes the area from the list.';
  }
  return 'Frees $frees on this device. Another ${formatBytes(shared)} is '
      'also covered by $with_ and stays. $again';
}

/// Asks, then deletes the area — leaving every tile another area still
/// covers — and refreshes the manifest. Returns true if it was deleted.
///
/// Shows what was really freed afterwards, measured as the files went.
Future<bool> confirmAndDeleteRegion(
  BuildContext context,
  WidgetRef ref,
  OfflineRegion region,
  List<OfflineRegion> all,
) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text('Delete "${region.displayName}"?'),
      content: Text(deleteConfirmationSentence(region, all)),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('Delete'),
        ),
      ],
    ),
  );
  if (confirmed != true) return false;

  final result = await OfflineRegionStore().deleteRegion(
    id: region.id,
    tileCounter: const TileCacheCounter(),
    demStore: DemTileStore(),
  );
  ref.invalidate(offlineRegionsProvider);
  if (context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          'Deleted "${region.displayName}" — freed '
          '${formatBytes(result.bytesFreed)}.',
        ),
      ),
    );
  }
  return true;
}

/// Lets a person change (or clear) the area's name. The field opens with the
/// current name selected so typing replaces it; an empty name falls back to
/// the generic label. Returns true if a name was saved.
Future<bool> renameRegionDialog(
  BuildContext context,
  WidgetRef ref,
  OfflineRegion region,
) async {
  final name = await showDialog<String>(
    context: context,
    builder: (context) => _NameDialog(region: region),
  );
  if (name == null) return false;
  await OfflineRegionStore().rename(region.id, name);
  ref.invalidate(offlineRegionsProvider);
  return true;
}

/// Owns the rename field's controller for exactly as long as the dialog is
/// on screen — a controller disposed the moment `showDialog` returns is
/// still being painted by the dialog's exit animation.
class _NameDialog extends StatefulWidget {
  const _NameDialog({required this.region});
  final OfflineRegion region;

  @override
  State<_NameDialog> createState() => _NameDialogState();
}

class _NameDialogState extends State<_NameDialog> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.region.name ?? '');
    _controller.selection = TextSelection(
      baseOffset: 0,
      extentOffset: _controller.text.length,
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Name this area'),
      content: TextField(
        controller: _controller,
        autofocus: true,
        textCapitalization: TextCapitalization.sentences,
        decoration: InputDecoration(
          hintText: widget.region.displayName,
          helperText: 'Leave blank to use the generic label.',
        ),
        onSubmitted: (v) => Navigator.of(context).pop(v),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_controller.text),
          child: const Text('Save'),
        ),
      ],
    );
  }
}

/// A text field that owns its controller, opening with [initial] selected so
/// typing replaces it, and reporting every edit through [onChanged]. For
/// sheets and dialogs that outlive the function that opened them.
class OwnedTextField extends StatefulWidget {
  const OwnedTextField({
    super.key,
    required this.initial,
    required this.onChanged,
    this.decoration,
  });
  final String initial;
  final ValueChanged<String> onChanged;
  final InputDecoration? decoration;

  @override
  State<OwnedTextField> createState() => _OwnedTextFieldState();
}

class _OwnedTextFieldState extends State<OwnedTextField> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initial);
    _controller.selection = TextSelection(
      baseOffset: 0,
      extentOffset: _controller.text.length,
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => TextField(
        controller: _controller,
        textCapitalization: TextCapitalization.sentences,
        decoration: widget.decoration,
        onChanged: widget.onChanged,
      );
}

/// Queues the area for download again under its own id, so the manifest
/// entry that comes back is the same area with the same name.
///
/// **Safe by construction: this adds files and removes none.** A tile
/// already on disk is a cache hit the downloader skips
/// (`OfflineTileDownloader`), and a DEM tile is fetched only if the store
/// still wants it (`DemTileStore.missingTilesForPolygon`). So an update
/// fills in whatever is missing or unusable and never has to ask which
/// tiles a neighbour still needs — the question the delete has to answer
/// does not arise here. Returns false if the area is already downloading,
/// (for a tile area) has no source or zoom range to download with, or its
/// recorded source is one this build no longer has ([regionHasKnownSource])
/// — task 11.231: re-downloading needs a real tile provider to ask, and
/// `TileSources.byId` now refuses rather than silently substituting one.
bool updateRegion(WidgetRef ref, OfflineRegion region) {
  final manager = ref.read(downloadManagerProvider.notifier);
  if (manager.isInFlight(region.id)) return false;
  if (!regionHasKnownSource(region)) return false;
  switch (region.kind) {
    case OfflineRegionKind.tiles:
      final sourceId = region.sourceId;
      final minZoom = region.minZoom;
      final maxZoom = region.maxZoom;
      if (sourceId == null || minZoom == null || maxZoom == null) return false;
      manager.enqueueTiles(
        polygon: region.polygon,
        sourceId: sourceId,
        minZoom: minZoom,
        maxZoom: maxZoom,
        name: region.name,
        id: region.id,
      );
    case OfflineRegionKind.dem:
      manager.enqueueDem(
        polygon: region.polygon,
        name: region.name,
        id: region.id,
      );
  }
  return true;
}
