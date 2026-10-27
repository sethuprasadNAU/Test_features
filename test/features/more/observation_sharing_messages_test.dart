import 'package:flutter_test/flutter_test.dart';
import 'package:tritrack/data/sharing/shared_observation_importer.dart';
import 'package:tritrack/features/more/screens/observation_sharing_screen.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

/// Finding **J-1**'s fourth and worst property: the app reported a hostile
/// overwrite as *"You already had this observation — updated it to the newer
/// version."* A correct-looking message that hides harm is exactly the failure
/// shape 10.25's checklist has demanded be checked at every gate since the
/// first — and it had only ever been checked on the server's refusal paths,
/// never on a success one.
///
/// These assert the wording directly. Real sqflite hangs inside `testWidgets`
/// on this project (see `app_context_provider_test.dart`), so a full
/// paste-and-save widget test is not available and the message must be tested
/// where it can be.
void main() {
  SharedObservationImportResult resultOf(
    SharedObservationImportOutcome outcome, {
    List<SharedObservationFieldChange> changes = const [],
    List<RowIssue> issues = const [],
    bool confirmedByUser = false,
  }) =>
      SharedObservationImportResult(
        outcome: outcome,
        observationId: 'obs-1',
        observerUserId: 'user-1',
        changes: changes,
        issues: issues,
        confirmedByUser: confirmedByUser,
      );

  test('every outcome has its own wording', () {
    final messages = {
      for (final outcome in SharedObservationImportOutcome.values)
        outcome: sharedObservationOutcomeMessage(resultOf(outcome)),
    };
    expect(messages.values.toSet(), hasLength(messages.length));
    for (final entry in messages.entries) {
      expect(entry.value, isNotEmpty, reason: '${entry.key}');
    }
  });

  test('no outcome that wrote nothing borrows a success sentence', () {
    for (final outcome in SharedObservationImportOutcome.values) {
      final result = resultOf(outcome);
      if (result.wrote) continue;
      final message = sharedObservationOutcomeMessage(result).toLowerCase();

      // The exact verbs J-1 shipped. A message that wrote nothing may not
      // claim it saved or updated anything.
      for (final claim in ['saved,', 'updated it', 'was replaced']) {
        expect(message, isNot(contains(claim)), reason: '$outcome: "$message"');
      }
      expect(
        message.contains('nothing changed') ||
            message.contains('not saved') ||
            message.contains('nothing changed.') ||
            message.contains('up to date'),
        isTrue,
        reason: '$outcome must state that nothing was written: "$message"',
      );
    }
  });

  test('a confirmed overwrite says what it replaced and that the prior version '
      'is kept', () {
    final message = sharedObservationOutcomeMessage(resultOf(
      SharedObservationImportOutcome.replicaUpdated,
      confirmedByUser: true,
      changes: const [
        SharedObservationFieldChange(
            column: 'latitude', was: 35.1983, becomes: 0.0),
        SharedObservationFieldChange(
            column: 'notes', was: null, becomes: 'added'),
      ],
    ));
    expect(message, contains('1 value was changed'));
    expect(message.toLowerCase(), contains('previous version is kept'));
  });

  /// Finding **K-8**: an update that destroyed nothing was reported with the
  /// confirmed-overwrite sentence, so a payload differing from the victim's row
  /// only in `created_at` and `origin_device_id` was written with no dialog
  /// anywhere and receipted as *"replaced as you confirmed — 0 values were
  /// changed."* Both halves false in one sentence, which is J-1's fourth
  /// property reproduced inside J-1's own remediation.
  ///
  /// Two tests, because there are two ways to be wrong here and one assertion
  /// would let the other through.
  group('an update nobody was asked about does not claim consent (K-8)', () {
    test('a clock-only update says nothing was changed, not that it was '
        'replaced', () {
      final message = sharedObservationOutcomeMessage(
          resultOf(SharedObservationImportOutcome.replicaUpdated));
      expect(message.toLowerCase(), isNot(contains('as you confirmed')));
      expect(message.toLowerCase(), isNot(contains('was replaced')));
      expect(message.toLowerCase(), contains('nothing you had was changed'));
      expect(message.toLowerCase(), contains('previous version is kept'));
    });

    test('an additions-only update says what it filled in, and that nothing '
        'was replaced', () {
      final message = sharedObservationOutcomeMessage(resultOf(
        SharedObservationImportOutcome.replicaUpdated,
        changes: const [
          SharedObservationFieldChange(
              column: 'notes', was: null, becomes: 'added'),
        ],
      ));
      expect(message.toLowerCase(), isNot(contains('as you confirmed')));
      expect(message, contains('1 detail it was missing was filled in'));
      expect(
        message.toLowerCase(),
        contains('nothing you already had was replaced'),
      );
    });
  });

  test('the refusal for a non-author names the reason, not a merge outcome', () {
    final message = sharedObservationOutcomeMessage(
        resultOf(SharedObservationImportOutcome.refusedNotAuthor));
    expect(message, contains('Not saved'));
    expect(message.toLowerCase(), contains('your copy is untouched'));
  });

  test('an invalid payload surfaces the field-level reason', () {
    final message = sharedObservationOutcomeMessage(resultOf(
      SharedObservationImportOutcome.refusedInvalid,
      issues: const [
        RowIssue(
          table: 'Observations',
          primaryKeyValue: 'obs-1',
          field: 'bearing_uncertainty',
          message: 'must be > 0 (was -5.0)',
        ),
      ],
    ));
    expect(message, contains('bearing_uncertainty'));
  });
}
