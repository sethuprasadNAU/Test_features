import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../time/device_time_zone.dart';
import '../time/project_time_zone.dart';
import 'app_context_provider.dart';

export '../time/project_time_zone.dart';

/// **The zone the project with [projectId] writes new deployment days in**
/// (task 11.331) — [effectiveProjectTimeZone], or this phone's zone when the
/// project cannot be read. What every screen's "today" for a new deployment
/// is read in.
final projectTimeZoneProvider = FutureProvider.autoDispose
    .family<String?, String>((ref, projectId) async {
      final project = await ref.watch(projectByIdProvider(projectId).future);
      if (project == null) return deviceTimeZone();
      return effectiveProjectTimeZone(project);
    }, name: 'projectTimeZoneProvider');
