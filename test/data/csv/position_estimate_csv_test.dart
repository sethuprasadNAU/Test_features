import 'package:flutter_test/flutter_test.dart';
import 'package:tritrack/data/csv/position_estimate_csv.dart';
import 'package:tritrack/localization/localization_types.dart';

import '../fixtures.dart';

/// Task 11.323 item 3: the cases the screen-level export test does not reach.
void main() {
  List<Map<String, String>> rowsOf(String csv) {
    final lines = csv.trim().split(RegExp(r'\r?\n'));
    final header = lines.first.split(',');
    return [
      for (final line in lines.skip(1))
        () {
          final cells = line.split(',');
          return {for (var i = 0; i < header.length; i++) header[i]: cells[i]};
        }(),
    ];
  }

  String export(
    List<dynamic> estimates, {
    Map<String, dynamic> observations = const {},
  }) => PositionEstimateCsv.export(
    [...estimates],
    tagsById: {'tag-1': sampleTag()},
    usersById: const {},
    individualsById: const {},
    deployments: const [],
    observationsById: {...observations},
  );

  test('a deleted estimate is left out, as the screens leave it out', () {
    final kept = sampleEstimatedPosition(id: 'kept');
    final deleted = sampleEstimatedPosition(id: 'gone').copyWith(
      sync: sampleSync().copyWith(deletedAt: DateTime.utc(2026, 9, 2)),
    );
    final rows = rowsOf(export([kept, deleted]));
    expect(rows.map((r) => r['position_id']), ['kept']);
  });

  test('a bearing deleted since the estimate was saved is counted out of '
      'bearings_on_device, and its id stays in bearing_ids', () {
    final estimate = sampleEstimatedPosition();
    final rows = rowsOf(export(
      [estimate],
      observations: {
        'obs-1': sampleObservation(id: 'obs-1'),
        'obs-2': sampleObservation(id: 'obs-2'),
        'obs-3': sampleObservation(id: 'obs-3').copyWith(
          sync: sampleSync().copyWith(deletedAt: DateTime.utc(2026, 9, 2)),
        ),
      },
    ));
    expect(rows.single['bearing_ids'], 'obs-1;obs-2;obs-3');
    expect(rows.single['bearing_count'], '3');
    expect(rows.single['bearings_on_device'], '2');
  });

  test('an unknown saver is the raw id, not a blank', () {
    final rows = rowsOf(export([sampleEstimatedPosition()]));
    expect(rows.single['saved_by'], sampleSync().lastModifiedBy);
  });

  test('cautions are stable codes, not the screen\'s sentences', () {
    expect(
      PositionEstimateCsv.cautionCode(GeometryWarning.nearParallel),
      'near_parallel',
    );
    expect(
      PositionEstimateCsv.cautionCode(GeometryWarning.largePositionUncertainty),
      'large_position_uncertainty',
    );
    expect(
      PositionEstimateCsv.cautionCode(GeometryWarning.didNotConverge),
      'did_not_converge',
    );
  });
}
