import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../viewshed/dem_tile_store.dart';
import '../../../widgets/segmented_toggle.dart';
import '../providers/receiver_altitude_provider.dart';

/// The mark for "how high the receiver is". **Not an aeroplane, on purpose**
/// (Michael, 2026-09-12): on every phone an aeroplane means aeroplane mode,
/// which means the radios are off, and this app exists to listen to a radio.
/// An icon that reads as *receiver disabled* is a bad ten seconds to hand
/// somebody in an aircraft. A gauge dial is what an altimeter looks like.
/// `record_screen_altitude_test.dart` refuses `Icons.flight` and
/// `Icons.airplanemode_active` here.
const IconData kReceiverAltitudeIcon = Icons.speed;

/// Opens the altitude sheet. [latitude]/[longitude] are where the next record
/// will be placed — the draft's pin, or the GPS fix — and are what the MSL
/// conversion looks the ground up under. Null means no position yet, which
/// leaves AGL entry working and refuses MSL.
Future<void> showReceiverAltitudeSheet(
  BuildContext context, {
  required double? latitude,
  required double? longitude,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (context) => _ReceiverAltitudeSheet(
      latitude: latitude,
      longitude: longitude,
    ),
  );
}

/// What the sheet found out about the ground under the position, which is
/// the one fact the MSL path depends on.
enum _Ground { looking, known, noPosition, noElevation }

class _ReceiverAltitudeSheet extends ConsumerStatefulWidget {
  const _ReceiverAltitudeSheet({
    required this.latitude,
    required this.longitude,
  });

  final double? latitude;
  final double? longitude;

  @override
  ConsumerState<_ReceiverAltitudeSheet> createState() =>
      _ReceiverAltitudeSheetState();
}

class _ReceiverAltitudeSheetState extends ConsumerState<_ReceiverAltitudeSheet> {
  final _controller = TextEditingController();
  late AltitudeUnit _unit;
  late AltitudeReference _reference;
  _Ground _ground = _Ground.looking;
  double? _groundMetres;
  String? _refusal;

  @override
  void initState() {
    super.initState();
    final current = ref.read(receiverAltitudeProvider);
    _unit = current.unit;
    _reference = current.reference;
    if (current.isAboveGround) {
      _controller.text = _unit.fromMetres(current.aglMetres).round().toString();
    }
    _lookUpGround();
  }

  /// **The terrain tile, and only the terrain tile.** The save path falls
  /// back from the tile to the phone's GPS altitude for `elevation`, and that
  /// is defensible on foot — a person's GPS altitude is the ground plus a
  /// couple of metres. In an aircraft the GPS altitude *is the aircraft's*,
  /// so using it as the ground here would make every MSL entry come out as
  /// zero above ground, which is precisely the wrong number this control
  /// exists to stop. No tile, no MSL.
  Future<void> _lookUpGround() async {
    final lat = widget.latitude;
    final lon = widget.longitude;
    if (lat == null || lon == null) {
      setState(() => _ground = _Ground.noPosition);
      return;
    }
    final ground = await DemTileStore().elevationAt(lat, lon);
    if (!mounted) return;
    setState(() {
      _groundMetres = ground;
      _ground = ground == null ? _Ground.noElevation : _Ground.known;
      // An MSL figure can only be prefilled once the ground is known.
      if (ground != null && _reference == AltitudeReference.msl) {
        final current = ref.read(receiverAltitudeProvider);
        if (current.isAboveGround) {
          _controller.text = _unit
              .fromMetres(current.aglMetres + ground)
              .round()
              .toString();
        }
      }
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  double? get _typedMetres {
    final raw = double.tryParse(_controller.text.trim());
    if (raw == null || !raw.isFinite) return null;
    return _unit.toMetres(raw);
  }

  void _setUnit(AltitudeUnit unit) {
    if (unit == _unit) return;
    final metres = _typedMetres;
    setState(() {
      if (metres != null) {
        _controller.text = unit.fromMetres(metres).round().toString();
      }
      _unit = unit;
      _refusal = null;
    });
    ref.read(receiverAltitudeSettingProvider.notifier).setUnit(unit);
  }

  void _setReference(AltitudeReference reference) {
    if (reference == _reference) return;
    final metres = _typedMetres;
    final ground = _groundMetres;
    setState(() {
      // Keep the physical height the same across the switch when the ground
      // is known; when it is not, the number stays and MSL will be refused
      // at Set, which is the honest order — the refusal names its reason.
      if (metres != null && ground != null) {
        final converted = reference == AltitudeReference.msl
            ? metres + ground
            : metres - ground;
        _controller.text = _unit.fromMetres(converted).round().toString();
      }
      _reference = reference;
      _refusal = null;
    });
    ref.read(receiverAltitudeSettingProvider.notifier).setReference(reference);
  }

  Future<void> _set() async {
    final metres = _typedMetres;
    if (metres == null) {
      setState(() => _refusal = 'Enter a number.');
      return;
    }
    double agl;
    if (_reference == AltitudeReference.msl) {
      final ground = _groundMetres;
      if (ground == null) {
        // **A refusal, not a guess.** Over water or over ground with no tile
        // there is nothing to subtract, and an AGL made from a missing
        // ground elevation would be a plausible number nobody measured.
        setState(() => _refusal = switch (_ground) {
              _Ground.noPosition =>
                'No position yet, so the ground elevation here is unknown — '
                    'enter the altitude above ground (AGL) instead.',
              _ => 'No ground elevation is stored for this position, so an '
                  'MSL altitude cannot be converted — enter the altitude '
                  'above ground (AGL) instead.',
            });
        return;
      }
      agl = metres - ground;
    } else {
      agl = metres;
    }
    if (agl < 0) {
      setState(() => _refusal = _reference == AltitudeReference.msl
          ? 'That is below the ground here '
              '(${formatAltitude(_groundMetres!, _unit)}).'
          : 'Height above ground cannot be negative.');
      return;
    }
    final notifier = ref.read(receiverAltitudeSettingProvider.notifier);
    if (agl == 0) {
      await notifier.clear();
    } else {
      await notifier.setAglMetres(agl);
    }
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _clear() async {
    await ref.read(receiverAltitudeSettingProvider.notifier).clear();
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final current = ref.watch(receiverAltitudeProvider);
    final groundLine = switch (_ground) {
      _Ground.looking => 'Looking up the ground elevation here…',
      _Ground.known =>
        'Ground here: ${formatAltitude(_groundMetres!, _unit)} above sea level',
      _Ground.noPosition => 'No position yet — MSL entry is not available.',
      _Ground.noElevation =>
        'No ground elevation stored for this position — MSL entry is not '
            'available. Enter altitude above ground (AGL).',
    };
    return Padding(
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
        bottom: MediaQuery.of(context).viewInsets.bottom + 20,
      ),
      child: Column(
        key: const ValueKey('receiver-altitude-sheet'),
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(kReceiverAltitudeIcon, size: 20),
              const SizedBox(width: 8),
              const Expanded(
                child: Text(
                  'Receiver altitude',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            'For a receiver in an aircraft. Stays set for every record until '
            'four hours pass with nothing recorded; leave it at zero on foot.',
            style: TextStyle(fontSize: 11.5, color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: TextField(
                  key: const ValueKey('receiver-altitude-field'),
                  controller: _controller,
                  autofocus: true,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  inputFormatters: [
                    FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
                  ],
                  onChanged: (_) => setState(() => _refusal = null),
                  onSubmitted: (_) => _set(),
                  decoration: InputDecoration(
                    labelText: 'Altitude (${_unit.suffix})',
                    border: const OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              SizedBox(
                width: 110,
                child: SegmentedToggle<AltitudeUnit>(
                  key: const ValueKey('receiver-altitude-unit'),
                  height: 40,
                  options: const [
                    (AltitudeUnit.metres, 'm'),
                    (AltitudeUnit.feet, 'ft'),
                  ],
                  selected: _unit,
                  onChanged: _setUnit,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          SegmentedToggle<AltitudeReference>(
            key: const ValueKey('receiver-altitude-reference'),
            height: 36,
            options: const [
              (AltitudeReference.agl, 'AGL — above ground'),
              (AltitudeReference.msl, 'MSL — above sea level'),
            ],
            selected: _reference,
            onChanged: _setReference,
          ),
          const SizedBox(height: 6),
          Text(
            groundLine,
            key: const ValueKey('receiver-altitude-ground'),
            style: TextStyle(fontSize: 11.5, color: scheme.onSurfaceVariant),
          ),
          if (_refusal != null) ...[
            const SizedBox(height: 8),
            Text(
              _refusal!,
              key: const ValueKey('receiver-altitude-refusal'),
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: scheme.error,
              ),
            ),
          ],
          const SizedBox(height: 14),
          Row(
            children: [
              if (current.isAboveGround)
                TextButton(
                  key: const ValueKey('receiver-altitude-clear'),
                  onPressed: _clear,
                  child: const Text('Back on the ground'),
                ),
              const Spacer(),
              FilledButton(
                key: const ValueKey('receiver-altitude-set'),
                onPressed: _set,
                child: const Text('Set'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
