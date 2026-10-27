import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../../core/providers/active_selection_provider.dart';
import '../../../core/providers/app_context_provider.dart';
import '../../../core/providers/auth_provider.dart';
import '../../../core/providers/device_id_provider.dart';
import '../../../core/providers/gps_provider.dart';
import '../../../core/providers/project_link_provider.dart';
import '../../../core/theme/design_tokens.dart';
import '../../../core/time/device_time_zone.dart';
import '../../../core/time/field_time_zone_text.dart';
import '../../../core/time/project_time_zone.dart';
import '../../../core/time/time_zone_boundaries.dart';
import '../../../data/repositories/repository_providers.dart';
import 'package:tritrack_sync/tritrack_sync.dart';
import '../../../data/models/project.dart';
import '../../../data/models/project_membership.dart';
import '../../../data/models/sync_meta.dart';
import '../../../widgets/disabled_reason.dart';
import '../../../widgets/load_failure.dart';
import '../../../widgets/saving_filled_button.dart';
import '../../../widgets/segmented_toggle.dart';
import '../../map/providers/download_manager.dart';
import '../widgets/finish_setting_up_sheet.dart';
import 'project_extent_picker_screen.dart';
import '../../../data/repositories/mutation_authorization.dart';
import '../../../data/sync/sync_transport.dart';
import '../../../data/repositories/project_membership_repository.dart';

/// Project Setup / Extent: name/description/notes, coordinate display
/// preference, and geographic extent.
///
/// **The triangulation time-window field left this screen at task 11.268**
/// (item 7) — Position Estimation's default selection now uses a fixed
/// 6-hour window rather than a per-project setting nobody knew existed. See
/// `kTriangulationDefaultWindow` in `position_estimation_screen.dart`.
///
/// The hi-fi mockup shows a freely-editable extent *polygon*, but the
/// schema (Phase 1) only stores an axis-aligned bounding box
/// (`bbox_min/max_lat/lon`) — a real polygon column would be a bigger
/// schema change than this phase scopes, and the mockup itself flags the
/// polygon as an unresolved question. Extent is set via [ProjectExtentPickerScreen]
/// (pan/zoom a real basemap to each corner) rather than raw lat/lon text
/// fields, which are error-prone for a field user to type accurately.
class ProjectSetupScreen extends ConsumerStatefulWidget {
  /// [projectId] selects which project this screen edits:
  /// - `null` (default): the currently-active project (existing behavior).
  /// - `'new'`: always start a blank form, ignoring the active project.
  /// - any other id: load and edit that specific project by id.
  const ProjectSetupScreen({super.key, this.projectId});

  final String? projectId;

  @override
  ConsumerState<ProjectSetupScreen> createState() => _ProjectSetupScreenState();
}

class _ProjectSetupScreenState extends ConsumerState<ProjectSetupScreen> {
  final _nameController = TextEditingController();
  final _descriptionController = TextEditingController();
  final _notesController = TextEditingController();

  double? _minLat;
  double? _minLon;
  double? _maxLat;
  double? _maxLon;

  CoordinateFormat _coordinateFormat = CoordinateFormat.dd;

  /// **Task 11.331: the project's time zone.** The zone stored on the
  /// project, or the one the person picked here; null while the default
  /// stands. [_suggestedZone] is that default — the zone at the center of
  /// the area, or this phone's when there is no area — recomputed whenever
  /// the area changes.
  String? _chosenZone;
  String? _suggestedZone;
  TimeZoneSource _suggestedSource = TimeZoneSource.thisPhone;
  int _suggestionRequest = 0;
  bool _suggestionStarted = false;

  bool _saving = false;
  bool _gpsBusy = false;
  Project? _loadedProject;

  @override
  void dispose() {
    _nameController.dispose();
    _descriptionController.dispose();
    _notesController.dispose();
    super.dispose();
  }

  void _loadFrom(Project project) {
    if (_loadedProject?.projectId == project.projectId) return;
    _loadedProject = project;
    _nameController.text = project.projectName;
    _descriptionController.text = project.description ?? '';
    _notesController.text = project.notes ?? '';
    _minLat = project.bboxMinLat;
    _minLon = project.bboxMinLon;
    _maxLat = project.bboxMaxLat;
    _maxLon = project.bboxMaxLon;
    _coordinateFormat = project.coordinateFormat;
    _chosenZone = FieldTimeZone.isKnown(project.timeZone)
        ? project.timeZone
        : null;
    // Called during build, so the lookup starts after this frame.
    _suggestionStarted = true;
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _refreshZoneSuggestion(),
    );
  }

  /// The zone the project will be saved with.
  String? get _zone => _chosenZone ?? _suggestedZone;

  /// Recomputes [_suggestedZone] from the current area — offline, from the
  /// boundaries the app ships. A newer request supersedes an older one, so a
  /// slow lookup cannot overwrite a newer area's answer.
  Future<void> _refreshZoneSuggestion() async {
    _suggestionStarted = true;
    final request = ++_suggestionRequest;
    String? zone;
    var source = TimeZoneSource.thisPhone;
    if (_minLat != null &&
        _minLon != null &&
        _maxLat != null &&
        _maxLon != null) {
      zone = await zoneAtPlace(
        (_minLat! + _maxLat!) / 2,
        (_minLon! + _maxLon!) / 2,
      );
      if (zone != null) source = TimeZoneSource.areaCenter;
    }
    zone ??= deviceTimeZone();
    if (!mounted || request != _suggestionRequest) return;
    setState(() {
      _suggestedZone = zone;
      _suggestedSource = source;
    });
  }

  @override
  Widget build(BuildContext context) {
    final isNew = widget.projectId == 'new';
    final specificId = widget.projectId != null && !isNew
        ? widget.projectId
        : null;
    final projectAsync = isNew
        ? const AsyncValue<Project?>.data(null)
        : specificId != null
        ? ref.watch(projectByIdProvider(specificId))
        : ref.watch(currentProjectProvider);
    // Task 11.132: this used to read `_loadedProject`, an instance field
    // written inside `body`'s `data` branch below during this very build.
    // State mutated during `build` cannot affect anything built earlier in
    // that same `build` — there is no error or flicker, the title just uses
    // the old value forever, because nothing schedules a rebuild afterward.
    // `projectAsync.value` is already known at this point in the build, so
    // it carries no such lag.
    final hasLoadedProject = !isNew && projectAsync.value != null;
    return Scaffold(
      appBar: AppBar(
        title: Text(hasLoadedProject ? 'Project Setup' : 'New Project'),
      ),
      body: projectAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => LoadFailure('this project', error: e),
        data: (project) {
          if (project != null && !isNew) _loadFrom(project);
          if (project == null && !_suggestionStarted) {
            // A new project: the default zone is this phone's until an area
            // is set (task 11.331). Started after this frame, not during it.
            _suggestionStarted = true;
            WidgetsBinding.instance.addPostFrameCallback(
              (_) => _refreshZoneSuggestion(),
            );
          }
          // A not-yet-created project has no owner to defer to — its creator
          // becomes the owner on save, so editing is always allowed.
          if (project == null) return _buildForm(context, isOwner: true);
          // Task 11.1: ownership is the project's open `owner` memberships,
          // not `Projects.owner_user_id`, so this is a query rather than a
          // column comparison. Rendered only once the answer is known —
          // showing the form enabled and then disabling it, or the reverse,
          // would be a worse lie than a moment's spinner.
          return ref
              .watch(isProjectOwnerProvider(project.projectId))
              .when(
                loading: () => const Center(child: CircularProgressIndicator()),
                error: (e, _) => LoadFailure(
                  'what you are allowed to change here',
                  error: e,
                ),
                data: (isOwner) => _buildForm(context, isOwner: isOwner),
              );
        },
      ),
    );
  }

  /// Greys [child] out for a non-owner. [ignorePointer] additionally blocks
  /// input for widgets (like [SegmentedToggle]) with no nullable `onPressed`
  /// to disable directly.
  ///
  /// **Task 11.138: this used to wrap the child in a `Tooltip` saying "Only a
  /// project owner can edit project settings", and a touchscreen never opens
  /// a tooltip.** The reason is not added back on each control, because the
  /// form already opens with a lock banner saying exactly that sentence, in
  /// the open, above the first field it applies to. Four second lines
  /// repeating a banner three inches above them is not an improvement on a
  /// tooltip; it is the same sentence four more times. The one control this
  /// does not cover is SAVE PROJECT, which is pinned to the bottom of the
  /// screen and stays put while the banner scrolls away — that one carries
  /// its own reason, below.
  Widget _gatedToOwner(
    Widget child,
    bool isOwner, {
    bool ignorePointer = false,
  }) {
    if (isOwner) return child;
    return ignorePointer
        ? IgnorePointer(child: Opacity(opacity: 0.5, child: child))
        : child;
  }

  Widget _buildForm(BuildContext context, {required bool isOwner}) {
    return Column(
      children: [
        Expanded(
          child: ListView(
            padding: const EdgeInsets.symmetric(
              horizontal: DesignTokens.spacingScreenHorizontal,
              vertical: 16,
            ),
            children: [
              if (!isOwner)
                Padding(
                  padding: const EdgeInsets.only(bottom: 16),
                  child: Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Theme.of(
                        context,
                      ).colorScheme.errorContainer.withValues(alpha: 0.4),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.lock_outline, size: 18),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            'Only a project owner can edit these settings. You can still '
                            'view them.',
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: Theme.of(
                                context,
                              ).colorScheme.onErrorContainer,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              // **Read-only, not disabled, for a non-owner** (task 11.184). This
              // used to be `enabled: isOwner`, which greys the text *and* makes
              // it unselectable — the rendering of "this control is not for
              // you." Nothing here is withheld from a non-owner: every value is
              // also visible in the project list and, for tags, in the CSV
              // export. So a non-owner not being able to select or copy a name
              // or a note off this screen was an accident of the widget rather
              // than a decision, and it read as data being kept from them.
              // `readOnly: true` is the honest rendering instead: legible,
              // selectable, just not editable. The three text fields below and
              // the triangulation-window field share this.
              TextField(
                controller: _nameController,
                enabled: true,
                readOnly: !isOwner,
                decoration: const InputDecoration(
                  labelText: 'Name',
                  border: OutlineInputBorder(),
                ),
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _descriptionController,
                enabled: true,
                readOnly: !isOwner,
                decoration: const InputDecoration(
                  labelText: 'Description',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _notesController,
                enabled: true,
                readOnly: !isOwner,
                decoration: const InputDecoration(
                  labelText: 'Species notes',
                  border: OutlineInputBorder(),
                ),
                minLines: 1,
                maxLines: 3,
              ),
              const SizedBox(height: 16),
              const _SectionLabel('COORDINATE FORMAT'),
              const SizedBox(height: 4),
              // **Task 11.268, item 8**: Michael did not know the
              // triangulation window drove anything because the screen
              // never said. Every remaining setting here says what it
              // does, in one line.
              const Text(
                'How coordinates are shown on the map, in position '
                'estimates, and when sharing a location.',
                style: TextStyle(fontSize: 12),
              ),
              const SizedBox(height: 6),
              _gatedToOwner(
                SegmentedToggle<CoordinateFormat>(
                  options: const [
                    (CoordinateFormat.dd, 'DD'),
                    (CoordinateFormat.dms, 'DMS'),
                    (CoordinateFormat.utm, 'UTM'),
                  ],
                  selected: _coordinateFormat,
                  onChanged: (v) => setState(() => _coordinateFormat = v),
                ),
                isOwner,
                ignorePointer: true,
              ),
              const SizedBox(height: 16),
              const _SectionLabel('PROJECT EXTENT'),
              const SizedBox(height: 4),
              const Text(
                'Where a map opens by default when there is no GPS fix or '
                'recorded position to frame it on.',
                style: TextStyle(fontSize: 12),
              ),
              const SizedBox(height: 6),
              _ExtentPreview(
                minLat: _minLat,
                minLon: _minLon,
                maxLat: _maxLat,
                maxLon: _maxLon,
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: _gatedToOwner(
                      OutlinedButton.icon(
                        onPressed: isOwner ? _pickExtentOnMap : null,
                        icon: const Icon(Icons.map_outlined),
                        label: const Text('Set extent on map'),
                      ),
                      isOwner,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _gatedToOwner(
                      OutlinedButton.icon(
                        onPressed: isOwner && !_gpsBusy
                            ? _fillFromCurrentLocation
                            : null,
                        icon: _gpsBusy
                            ? const SizedBox(
                                height: 16,
                                width: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.my_location),
                        label: const Text('Use current location'),
                      ),
                      isOwner,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              ..._timeZoneSection(context, isOwner: isOwner),
              const SizedBox(height: 16),
              Text(
                _rolesEnforcementNote(
                  _loadedProject == null
                      ? false
                      : ref
                                .watch(
                                  isProjectLinkedProvider(_loadedProject!.projectId),
                                )
                                .value ??
                            false,
                ),
                style: const TextStyle(fontSize: 11, fontStyle: FontStyle.italic),
              ),
            ],
          ),
        ),
        SafeArea(
          minimum: const EdgeInsets.fromLTRB(
            DesignTokens.spacingScreenHorizontal,
            0,
            DesignTokens.spacingScreenHorizontal,
            12,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // The pinned footer outruns the banner at the top of the form:
              // scroll down and SAVE PROJECT is the only greyed control still
              // on screen, with its explanation somewhere above the fold.
              // Costs nothing for an owner (task 11.138).
              if (!isOwner)
                const DisabledReasonNote(
                  reason: 'Only a project owner can save changes here.',
                ),
              _gatedToOwner(
                SavingFilledButton(
                  label: 'SAVE PROJECT',
                  minHeight: 48,
                  onPressed:
                      !isOwner ||
                          _saving ||
                          _nameController.text.trim().isEmpty
                      ? null
                      : _save,
                  saving: _saving,
                ),
                isOwner,
              ),
            ],
          ),
        ),
      ],
    );
  }

  Future<void> _pickExtentOnMap() async {
    final initial =
        _minLat != null && _minLon != null && _maxLat != null && _maxLon != null
        ? ExtentResult(
            minLat: _minLat!,
            minLon: _minLon!,
            maxLat: _maxLat!,
            maxLon: _maxLon!,
          )
        : null;
    final result = await Navigator.of(context).push<ExtentResult>(
      MaterialPageRoute(
        builder: (_) => ProjectExtentPickerScreen(initial: initial),
      ),
    );
    if (result == null || !mounted) return;
    setState(() {
      _minLat = result.minLat;
      _minLon = result.minLon;
      _maxLat = result.maxLat;
      _maxLon = result.maxLon;
    });
    unawaited(_refreshZoneSuggestion());
  }

  /// **Task 11.105 — the first of the two instances task 11.66 reproduced on a
  /// phone.**
  ///
  /// This used to be `catch (e) { e is LocationPermissionDeniedException ? … }`
  /// and the typed branch had never once been taken. `gpsPositionProvider` is
  /// autoDispose and `ref.read(...future)` holds no listener across the await,
  /// so the element is disposed while still loading and the caller gets a
  /// `StateError` about that — the exception, and its sentence, are destroyed
  /// in transit rather than wrapped. Every refusal came out as *"Could not get
  /// a GPS fix. Try again outdoors or with a clear sky view"*, which sends
  /// somebody outdoors to fix a permission dialog. See `provider_error.dart`
  /// for the measurements.
  ///
  /// **So the cause is no longer carried by the exception.** It is read as a
  /// value from `locationProblemProvider` after the attempt fails — the shape
  /// task 11.104 established for the refused server address. Nothing about the
  /// fix depends on which object the `await` threw, which is the point: it is
  /// the one thing that turned out not to be knowable.
  Future<void> _fillFromCurrentLocation() async {
    setState(() => _gpsBusy = true);
    try {
      // **A deadline on a GPS fix, not on a request** — this is one of the two
      // `.timeout()` calls in `lib/` that survive task 11.61's policy, and
      // `test/documentation/request_deadline_allowlist_test.dart` holds the
      // reasoning. Nothing here touches a server; what is being bounded is a
      // satellite fix, which can legitimately never arrive.
      //
      // **The number that used to be quoted here was wrong by the time anybody
      // read it.** This comment said Riverpod retried a failed provider ten
      // times over 38 seconds, so the timeout had to be shorter than that.
      // Task 11.107 replaced that default with `appRetryPolicy` on 2026-08-31:
      // three attempts and 1.6 seconds of backoff. The timeout is still what
      // bounds this — a provider that never completes is not a provider that
      // failed, and no retry policy bounds waiting — but it is not racing the
      // number this sentence used to name.
      final gps = await ref
          .read(gpsPositionProvider.future)
          .timeout(
            const Duration(seconds: 15),
            onTimeout: () => throw TimeoutException('No GPS fix yet'),
          );
      if (!mounted) return;
      const delta =
          0.0045; // ~500m at mid-latitudes; approximate, no real basemap to reference yet.
      setState(() {
        _minLat = gps.latitude - delta;
        _maxLat = gps.latitude + delta;
        _minLon = gps.longitude - delta;
        _maxLon = gps.longitude + delta;
      });
      unawaited(_refreshZoneSuggestion());
    } catch (_) {
      // Asked only now, and asked fresh: the permission may have been changed
      // in the system settings since this provider last answered, including by
      // the dialog `gpsPosition` just showed.
      ref.invalidate(locationProblemProvider);
      final problem = await ref.read(locationProblemProvider.future);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            problem?.message ??
                'Could not get a GPS fix. Try again outdoors or with a '
                    'clear sky view.',
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _gpsBusy = false);
    }
  }

  Future<void> _save() async {
    // Task 11.331: changing a saved project's zone says what it does first.
    final storedZone = _loadedProject?.timeZone;
    final newZone = _zone;
    if (FieldTimeZone.isKnown(storedZone) &&
        newZone != null &&
        newZone != storedZone &&
        !await _confirmZoneChange(storedZone!, newZone)) {
      return;
    }
    if (!mounted) return;
    setState(() => _saving = true);
    try {
      final now = DateTime.now();
      final user = await ref.read(currentUserProvider.future);
      final deviceId = await ref.read(deviceIdProvider.future);
      final repo = await ref.read(projectRepositoryProvider.future);
      final existing = _loadedProject;

      final projectId = existing?.projectId ?? const Uuid().v4();
      final project = Project(
        projectId: projectId,
        projectName: _nameController.text.trim(),
        description: _descriptionController.text.trim().isEmpty
            ? null
            : _descriptionController.text.trim(),
        notes: _notesController.text.trim().isEmpty
            ? null
            : _notesController.text.trim(),
        ownerUserId: existing?.ownerUserId ?? user.userId,
        creationDate: existing?.creationDate ?? now,
        bboxMinLat: _minLat,
        bboxMinLon: _minLon,
        bboxMaxLat: _maxLat,
        bboxMaxLon: _maxLon,
        coordinateFormat: _coordinateFormat,
        // **`triangulationWindowMinutes` retired at task 11.268** (item 7):
        // off this form, and nothing reads the stored value any more — see
        // `kTriangulationDefaultWindow` in `position_estimation_screen.dart`.
        // Left at the model's default for every save rather than carried
        // forward from `existing`, on purpose: the column is inert, so what
        // it holds cannot matter.
        // Task 11.56: a project created in place is the first of its line,
        // so its lineage is its own id — what the v18 migration wrote for
        // every project that predates it. An edit carries the stored pair
        // through unchanged; this form owns neither.
        lineageId: existing == null ? projectId : existing.lineageId,
        copiedAt: existing?.copiedAt,
        // Task 11.331: the zone shown on this form, default or chosen. New
        // deployment rows copy it; rows already written keep their own.
        timeZone: _zone ?? existing?.timeZone,
        sync:
            existing?.sync ??
            SyncMeta.initial(
              now: now,
              modifiedBy: user.userId,
              originDeviceId: deviceId,
            ),
      );

      if (existing == null) {
        await repo.insert(project);
        // Task 8.4: every project gets an owner membership row at creation
        // time, rather than relying solely on the lazy on-load backfill
        // `currentProjectProvider`/`projectByIdProvider`/`allProjectsProvider`
        // apply to projects that predate this table's adoption.
        final membershipRepo = await ref.read(
          projectMembershipRepositoryProvider.future,
        );
        await membershipRepo.insert(
          ProjectMembership(
            membershipId: const Uuid().v4(),
            projectId: project.projectId,
            userId: project.ownerUserId,
            joinDate: project.creationDate,
            role: ProjectRole.owner,
            sync: project.sync,
          ),
          authority: const MembershipInsertAuthority.bootstrapOwner(),
        );
      } else {
        await repo.update(
          project,
          actor: MutationActor.user(user.userId),
          deviceId: deviceId,
        );
      }
      await ref.read(activeProjectIdProvider.notifier).set(project.projectId);
      ref.invalidate(currentProjectProvider);
      ref.invalidate(allProjectsProvider);
      ref.invalidate(projectByIdProvider(project.projectId));

      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Project saved')));
        if (existing == null) await _offerFinishSettingUp(project);
        if (mounted) Navigator.of(context).maybePop();
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// **Task 11.331: the project's time zone, in plain words.** Deployment
  /// days are days in this zone wherever the phone reading them is, so the
  /// creator sees it before saving and can change it; an owner can change it
  /// later, and the change rewrites nothing already recorded.
  List<Widget> _timeZoneSection(BuildContext context, {required bool isOwner}) {
    final zone = _zone;
    final suggestion = _suggestedZone;
    final String source;
    if (_chosenZone == null) {
      source = _suggestedSource == TimeZoneSource.areaCenter
          ? 'Chosen from the center of your project area.'
          : "This phone's time zone, because the project has no area yet.";
    } else {
      source = _loadedProject?.timeZone == _chosenZone
          ? "This project's time zone."
          : 'Chosen by you.';
    }
    final offerSuggestion =
        _chosenZone != null &&
        suggestion != null &&
        suggestion != _chosenZone &&
        _suggestedSource == TimeZoneSource.areaCenter;
    return [
      const _SectionLabel('TIME ZONE'),
      const SizedBox(height: 4),
      const Text(
        'The days tags go on and come off are days in this time zone, '
        'wherever the phone showing them is.',
        style: TextStyle(fontSize: 12),
      ),
      const SizedBox(height: 6),
      Text(
        zone == null ? 'Working it out…' : describeTimeZone(zone),
        key: const ValueKey('project_time_zone'),
        style: const TextStyle(fontWeight: FontWeight.w700),
      ),
      if (zone != null)
        Text(
          source,
          key: const ValueKey('project_time_zone_source'),
          style: const TextStyle(fontSize: 12),
        ),
      if (offerSuggestion) ...[
        const SizedBox(height: 6),
        Text(
          'The center of this area is in ${describeTimeZone(suggestion)}.',
          key: const ValueKey('project_time_zone_suggestion'),
          style: const TextStyle(fontSize: 12),
        ),
        Align(
          alignment: Alignment.centerLeft,
          child: _gatedToOwner(
            TextButton(
              key: const ValueKey('project_time_zone_use_suggestion'),
              onPressed: isOwner
                  ? () => setState(() => _chosenZone = suggestion)
                  : null,
              child: const Text('Use that time zone'),
            ),
            isOwner,
          ),
        ),
      ],
      const SizedBox(height: 6),
      _gatedToOwner(
        OutlinedButton.icon(
          key: const ValueKey('project_time_zone_change'),
          onPressed: isOwner ? _pickTimeZone : null,
          icon: const Icon(Icons.schedule),
          label: const Text('Change time zone'),
        ),
        isOwner,
      ),
    ];
  }

  Future<void> _pickTimeZone() async {
    final picked = await showDialog<String>(
      context: context,
      builder: (context) => _TimeZonePicker(current: _zone),
    );
    if (picked == null || !mounted) return;
    setState(() => _chosenZone = picked);
  }

  /// What changing a saved project's zone does, said before it happens
  /// (task 11.331 item 3).
  Future<bool> _confirmZoneChange(String from, String to) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Change the time zone?'),
        content: Text(
          'From ${describeTimeZone(from)} to ${describeTimeZone(to)}.\n\n'
          'Days already recorded stay the same days. New dates when a tag '
          'goes on or comes off, and "today" on those forms, use the new '
          'time zone.',
        ),
        actions: [
          TextButton(
            key: const ValueKey('cancel_time_zone_change'),
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const ValueKey('confirm_time_zone_change'),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Change'),
          ),
        ],
      ),
    );
    return confirmed == true;
  }

  /// **Task 11.324, item 1: "Finish setting up", once, for a new project.**
  /// Publish now (only when this phone is signed in) and download the area's
  /// offline maps now — both ticked, the size shown. *Later* starts nothing;
  /// the Pre-Trip Checklist keeps both. See `finish_setting_up_sheet.dart`.
  Future<void> _offerFinishSettingUp(Project project) async {
    final maps = ProjectAreaDownload.of(project);
    String? publishAs;
    try {
      // `currentSession` is null whenever no server is configured, so this
      // is "signed in to a server", the same gate Projects' Publish uses.
      publishAs = (await ref.read(currentSessionProvider.future))?.email;
    } catch (_) {
      publishAs = null;
    }
    if (publishAs == null && maps == null) return;
    if (!mounted) return;
    // Read before the sheet's `await`: the screen pops right after, and the
    // publish outlives it on a `keepAlive` notifier.
    final messenger = ScaffoldMessenger.of(context);
    final downloads = ref.read(downloadManagerProvider.notifier);
    final link = ref.read(projectLinkControllerProvider.notifier);
    final choice = await showFinishSettingUpSheet(
      context,
      publishAs: publishAs,
      maps: maps,
    );
    if (choice.downloadMaps && maps != null) maps.start(downloads);
    if (choice.publish) {
      unawaited(
        _publishNew(project.projectName, project.projectId, link, messenger),
      );
    }
  }

  static Future<void> _publishNew(
    String name,
    String projectId,
    ProjectLinkController link,
    ScaffoldMessengerState messenger,
  ) async {
    String sentence;
    try {
      final report = await link.publish(projectId);
      final refused = report.refused.length;
      sentence = refused == 0
          ? 'Published "$name"'
          : 'Published "$name", but the server would not accept $refused '
                '${refused == 1 ? 'record' : 'records'}. More → Sync Status '
                'lists ${refused == 1 ? 'it' : 'them'}.';
    } catch (e) {
      sentence = e is SyncTransportException && e.userMessage != null
          ? e.userMessage!
          : 'Could not publish "$name"; it is saved on this device and still '
                'unpublished. Publish it from Projects → ⋮ when you have cell '
                'or wifi coverage. It is also on the Pre-Trip Checklist.';
    }
    messenger.showSnackBar(
      SnackBar(duration: const Duration(seconds: 8), content: Text(sentence)),
    );
  }
}

/// Task 11.211: this sentence used to say, unconditionally, *"Roles/
/// permissions are device-local only in this release"* — which has been
/// false since join-and-approve shipped. `_requireOwner` in
/// `server/lib/src/projects/project_routes.dart` refuses a non-owner's
/// membership writes for any project the server knows about (§4.21), so a
/// published project's roles are enforced whether or not this device is even
/// online. **Only a project that has never left this device has nothing but
/// the device to enforce anything.** Both halves of the backup-file warning
/// stay true regardless — a backup is a plain file, and whoever holds it can
/// edit it either way.
String _rolesEnforcementNote(bool published) => published
    ? 'This project lives on a server — roles and permissions are enforced '
          'there, by the server, on every device. A backup file can still be edited by '
          'whoever holds it.'
    : 'This project has never been published — nothing but this device '
          "enforces anyone's role. A backup file can still be edited by "
          'whoever holds it.';

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w800,
        letterSpacing: 0.5,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
    );
  }
}

/// **Pick a time zone by hand** (task 11.331) — every place zone the tz
/// database names, then the sea zones, each shown in plain words and found by
/// typing part of its name.
class _TimeZonePicker extends StatefulWidget {
  const _TimeZonePicker({required this.current});

  final String? current;

  @override
  State<_TimeZonePicker> createState() => _TimeZonePickerState();
}

class _TimeZonePickerState extends State<_TimeZonePicker> {
  final _filter = TextEditingController();
  late final List<(String, String)> _all = [
    for (final zone in pickableTimeZones()) (zone, describeTimeZone(zone)),
  ];

  @override
  void dispose() {
    _filter.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final query = _filter.text.trim().toLowerCase();
    final shown = [
      for (final entry in _all)
        if (query.isEmpty ||
            entry.$1.toLowerCase().replaceAll('_', ' ').contains(query) ||
            entry.$2.toLowerCase().contains(query))
          entry,
    ];
    return AlertDialog(
      title: const Text('Time zone'),
      content: SizedBox(
        width: double.maxFinite,
        height: 400,
        child: Column(
          children: [
            TextField(
              key: const ValueKey('time_zone_filter'),
              controller: _filter,
              decoration: const InputDecoration(
                labelText: 'Search, e.g. Phoenix or UTC−7',
                prefixIcon: Icon(Icons.search),
              ),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: ListView.builder(
                itemCount: shown.length,
                itemBuilder: (context, i) {
                  final (zone, words) = shown[i];
                  return ListTile(
                    key: ValueKey('time_zone_$zone'),
                    dense: true,
                    selected: zone == widget.current,
                    title: Text(words),
                    subtitle: zone.startsWith('Etc/') ? null : Text(zone),
                    onTap: () => Navigator.of(context).pop(zone),
                  );
                },
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
      ],
    );
  }
}

class _ExtentPreview extends StatelessWidget {
  const _ExtentPreview({this.minLat, this.minLon, this.maxLat, this.maxLon});
  final double? minLat;
  final double? minLon;
  final double? maxLat;
  final double? maxLon;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final hasExtent =
        minLat != null && minLon != null && maxLat != null && maxLon != null;
    return Container(
      height: 100,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        border: Border.all(color: scheme.outline, width: 1.5),
        borderRadius: BorderRadius.circular(10),
      ),
      child: hasExtent
          ? Padding(
              padding: const EdgeInsets.all(16),
              child: Container(
                decoration: BoxDecoration(
                  color: scheme.primary.withValues(alpha: 0.1),
                  border: Border.all(color: scheme.primary, width: 1.5),
                ),
              ),
            )
          : Text(
              'No extent set',
              style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12),
            ),
    );
  }
}

