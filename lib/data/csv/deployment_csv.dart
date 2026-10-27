import 'package:tritrack_sync/tritrack_sync.dart';

import '../models/deployment.dart';
import 'schema_table_csv.dart';

/// **`deployments.csv`** — the `Deployments` table as it is, plus three
/// things an analyst needs and should not have to derive (task 11.331):
///
/// - `time_zone` — the zone the row's days were written in (a column the
///   table declares, so it is in the derived header like every other);
/// - `attached_day` and `removed_day` — **the days as plain dates**
///   (`2026-07-01`), read in that zone.
///
/// Why the plain dates: `attached_date` and `removed_date` are UTC instants,
/// and a bare day is the start of that day *in the field*. Read naively in a
/// spreadsheet, a New Zealand season's days come out a day early (midnight in
/// Auckland is the previous day in UTC), and an Arizona day comes out right
/// only by luck. The plain date is the day somebody wrote down. A timed end
/// (a same-day swap) gives the day it fell on, there; its instant is still in
/// `removed_date`.
///
/// **Every existing column keeps its place**; the two days are appended.
String deploymentsCsv(List<Deployment> deployments) => SchemaTableCsv.export(
  Tables.deployments,
  [
    for (final d in deployments)
      {
        ...d.toColumns(),
        'attached_day': _day(d, d.attachedDate),
        'removed_day': _day(d, d.removedDate),
      },
  ],
  extra: const ['attached_day', 'removed_day'],
);

String? _day(Deployment d, DateTime? at) {
  if (at == null) return null;
  final date = d.calendarDateOf(at);
  return '${date.year.toString().padLeft(4, '0')}-'
      '${date.month.toString().padLeft(2, '0')}-'
      '${date.day.toString().padLeft(2, '0')}';
}
