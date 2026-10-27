import 'package:flutter_test/flutter_test.dart';
import 'package:tritrack/data/csv/csv_export_archive.dart';

/// Task 11.241: the CSV export is one zip, and every file comes back out of
/// it byte-for-byte.
void main() {
  test('every CSV goes in and comes back unchanged, UTF-8 and all', () {
    final files = {
      'observations.csv': 'observation_id,tag_name\nobs-1,Marie\n',
      'tags.csv': 'tag_id,tag_name\ntag-1,Kākāpō ♀\n',
      'individuals.csv': 'individual_id,name\ni-1,Marie\n',
    };
    final bytes = CsvExportArchive.encode(files);
    expect(bytes, isNotEmpty);
    expect(CsvExportArchive.decode(bytes), files);
  });

  test('an export with no optional tables is still a valid archive', () {
    final bytes = CsvExportArchive.encode({'observations.csv': 'a,b\n'});
    expect(CsvExportArchive.decode(bytes).keys, ['observations.csv']);
  });
}
