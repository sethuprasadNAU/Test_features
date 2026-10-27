import 'package:flutter_test/flutter_test.dart';
import 'package:tritrack/data/csv/schema_table_csv.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

import '../fixtures.dart';

/// Task 11.240: the `tags.csv` and `individuals.csv` lookup files derive
/// their columns from the shared schema, and carry the lineage that makes
/// a multi-season analysis possible.
void main() {
  List<List<String>> parse(String csv) => [
    for (final line in csv.trim().split('\n')) line.split(','),
  ];

  test('the individuals header is exactly the shared spec, in order', () {
    expect(
      SchemaTableCsv.header(Tables.individuals),
      tableSpecsByName[Tables.individuals]!.columnNames.toList(),
    );
    expect(SchemaTableCsv.header(Tables.individuals),
        containsAll(['individual_id', 'lineage_id', 'color_hex']));
  });

  test('the tags header carries lineage_id, omits the retired colour column, '
      'and no longer names an animal', () {
    final header = SchemaTableCsv.header(
      Tables.tags,
      omit: SchemaTableCsv.retiredTagColumns,
    );
    expect(header, containsAll(['tag_id', 'lineage_id']));
    expect(header, isNot(contains('color_hex')));
    // **Task 11.243.** A tag is equipment; which animal wore it and when is
    // `deployments.csv`, exported beside this one by the same screen.
    expect(header, isNot(contains('individual_id')));
    expect(
      SchemaTableCsv.header(Tables.deployments),
      containsAll([
        'deployment_id',
        'tag_id',
        'individual_id',
        'attached_date',
        'removed_date',
      ]),
      reason: 'the join a multi-season analysis needs is a table of its own',
    );
    expect(SchemaTableCsv.retiredTagColumns, {'color_hex'});
    // Every other spec column is there: the omission is exactly the retired
    // set and nothing else.
    expect(
      header.length,
      tableSpecsByName[Tables.tags]!.columns.length -
          SchemaTableCsv.retiredTagColumns.length,
    );
  });

  test('rows export under the derived header, empty where a column is absent',
      () {
    final rows = parse(SchemaTableCsv.export(
      Tables.individuals,
      [sampleIndividual(name: 'Marie', lineageId: 'lineage-marie').toColumns()],
    ));
    final header = rows[0];
    final row = rows[1];
    expect(row[header.indexOf('name')], 'Marie');
    expect(row[header.indexOf('lineage_id')], 'lineage-marie');
    expect(row[header.indexOf('species')], '');
  });

  test('a table outside the shared schema is refused rather than guessed', () {
    expect(() => SchemaTableCsv.header('Tag_Library'), throwsArgumentError);
  });
}
