import 'package:test/test.dart';
import 'package:tritrack_server/tritrack_server.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

/// Task 11.159. **The rule is that a row may not claim more edits than the time
/// it says they took could hold**, and every case below is either a real field
/// shape that must stay silent or a pin that must be named.
///
/// The numbers in the "legitimate" group are not invented: they come from
/// `test/data/sync/offline_revision_burst_test.dart` in the app, which measured
/// how an offline burst actually reaches the server before any of this was
/// designed.
void main() {
  Map<String, Object?> row({
    required int revision,
    required String createdAt,
    required String updatedAt,
  }) => {
    'revision': revision,
    'created_at': createdAt,
    'updated_at': updatedAt,
  };

  group('a legitimate row is never flagged', () {
    test(
      'the measured offline burst — fifty corrections to one row over an hour '
      '— is explainable',
      () {
        // The exact shape `offline_revision_burst_test.dart` measured: the
        // push carries one row advanced by fifty.
        final verdict = RevisionPlausibility.classify(
          incoming: row(
            revision: 51,
            createdAt: '2026-09-01T09:00:00.000Z',
            updatedAt: '2026-09-01T10:00:00.000Z',
          ),
          existing: row(
            revision: 1,
            createdAt: '2026-09-01T09:00:00.000Z',
            updatedAt: '2026-09-01T09:00:00.000Z',
          ),
        );
        expect(verdict, isNull);
      },
    );

    test(
      'a season off the network — one row corrected daily for four months — is '
      'explainable, which is the case a bound on the increment would refuse',
      () {
        final verdict = RevisionPlausibility.classify(
          incoming: row(
            revision: 121,
            createdAt: '2026-05-01T09:00:00.000Z',
            updatedAt: '2026-09-01T09:00:00.000Z',
          ),
          existing: row(
            revision: 1,
            createdAt: '2026-05-01T09:00:00.000Z',
            updatedAt: '2026-05-01T09:00:00.000Z',
          ),
        );
        expect(verdict, isNull);
      },
    );

    test(
      'a row created and saved five times inside one second is explainable',
      () {
        final verdict = RevisionPlausibility.classify(
          incoming: row(
            revision: 5,
            createdAt: '2026-09-01T09:00:00.000Z',
            updatedAt: '2026-09-01T09:00:00.000Z',
          ),
          existing: null,
        );
        expect(verdict, isNull);
      },
    );

    test('a brand-new row at revision 1 is explainable', () {
      final verdict = RevisionPlausibility.classify(
        incoming: row(
          revision: 1,
          createdAt: '2026-09-01T09:00:00.000Z',
          updatedAt: '2026-09-01T09:00:00.000Z',
        ),
        existing: null,
      );
      expect(verdict, isNull);
    });

    test(
      'a re-offer of a row the server already holds claims no edits at all',
      () {
        final same = row(
          revision: 7,
          createdAt: '2026-09-01T09:00:00.000Z',
          updatedAt: '2026-09-01T09:30:00.000Z',
        );
        expect(
          RevisionPlausibility.classify(incoming: same, existing: same),
          isNull,
        );
      },
    );
  });

  group('a pin is named', () {
    test(
      'a first push at 2^62 is flagged — the case a bound on the increment '
      'cannot see, because an insert has no stored revision to compare with',
      () {
        final verdict = RevisionPlausibility.classify(
          incoming: row(
            revision: 4611686018427387904,
            createdAt: '2026-09-01T09:00:00.000Z',
            updatedAt: '2026-09-01T10:00:00.000Z',
          ),
          existing: null,
        );
        expect(verdict, isNotNull);
        expect(verdict!.anomaly, RevisionAnomaly.impossibleEditRate);
        expect(verdict.storedRevision, isNull);
        expect(verdict.claimedEdits, 4611686018427387904);
        // 3600 seconds at one edit a second, plus the burst allowance.
        expect(verdict.allowedEdits, 4600);
      },
    );

    test(
      'a jump to a million on a row the server holds is flagged, and a million '
      'pins a field record exactly as permanently as 2^62 does — which is why '
      'no ceiling high enough to be safe would have caught it',
      () {
        final verdict = RevisionPlausibility.classify(
          incoming: row(
            revision: 1000000,
            createdAt: '2026-09-01T09:00:00.000Z',
            updatedAt: '2026-09-01T09:05:00.000Z',
          ),
          existing: row(
            revision: 7,
            createdAt: '2026-09-01T09:00:00.000Z',
            updatedAt: '2026-09-01T09:00:00.000Z',
          ),
        );
        expect(verdict, isNotNull);
        expect(verdict!.claimedEdits, 999993);
        expect(verdict.storedRevision, 7);
        expect(verdict.incomingRevision, 1000000);
      },
    );

    test('the largest revision the share/import path admits is flagged when it '
        'arrives, and is still stored — noticing is not refusing', () {
      final verdict = RevisionPlausibility.classify(
        incoming: row(
          revision: UntrustedImportRules.maxImportedRevision,
          createdAt: '2026-03-01T09:00:00.000Z',
          updatedAt: '2026-09-01T09:00:00.000Z',
        ),
        existing: null,
      );
      expect(verdict, isNotNull);
      expect(verdict!.incomingRevision, 3999000000);
    });

    test('an uninitialised counter — the likelier cause than malice — is named '
        'the same way', () {
      final verdict = RevisionPlausibility.classify(
        incoming: row(
          revision: 9223372036854775807,
          createdAt: '2026-09-01T09:00:00.000Z',
          updatedAt: '2026-09-01T09:00:01.000Z',
        ),
        existing: null,
      );
      expect(verdict, isNotNull);
      expect(verdict!.claimedEdits, 9223372036854775807);
    });
  });

  group('the verdict never guesses', () {
    test(
      'a backwards clock buys no allowance — the span is clamped to zero '
      'rather than trusted, so a hostile created_at cannot purchase headroom',
      () {
        final verdict = RevisionPlausibility.classify(
          incoming: row(
            revision: 5000,
            createdAt: '2026-09-01T09:00:00.000Z',
            updatedAt: '2026-08-01T09:00:00.000Z',
          ),
          existing: null,
        );
        expect(verdict, isNotNull);
        expect(verdict!.allowedEdits, RevisionPlausibility.burstAllowance);
        expect(verdict.spanSeconds, 0);
      },
    );

    test('a timestamp that will not parse produces no verdict — that is a '
        'RowValidator matter, and answering here would send a reader after the '
        'wrong cause', () {
      expect(
        RevisionPlausibility.classify(
          incoming: {
            'revision': 9223372036854775807,
            'created_at': 'north',
            'updated_at': 'north',
          },
          existing: null,
        ),
        isNull,
      );
    });

    test('a non-integer revision produces no verdict', () {
      expect(
        RevisionPlausibility.classify(
          incoming: row(
            revision: 1,
            createdAt: '2026-09-01T09:00:00.000Z',
            updatedAt: '2026-09-01T09:00:00.000Z',
          )..['revision'] = 'lots',
          existing: null,
        ),
        isNull,
      );
    });

    test(
      'the allowance is stated, so a log line is a finding and not a name',
      () {
        expect(RevisionPlausibility.plausibleEdits(0), 1000);
        expect(RevisionPlausibility.plausibleEdits(-1), 1000);
        expect(RevisionPlausibility.plausibleEdits(3600), 4600);
      },
    );
  });

  group('RowMerge carries the verdict without letting it change the merge', () {
    final receivedAt = DateTime.utc(2026, 9, 1, 10);

    test('an absurd incoming row still wins, and is flagged', () {
      final decision = RowMerge.decide(
        incoming: row(
          revision: 4611686018427387904,
          createdAt: '2026-09-01T09:00:00.000Z',
          updatedAt: '2026-09-01T09:30:00.000Z',
        ),
        existing: row(
          revision: 7,
          createdAt: '2026-09-01T09:00:00.000Z',
          updatedAt: '2026-09-01T09:00:00.000Z',
        ),
        receivedAt: receivedAt,
      );
      // The merge is untouched: detection never refuses, and a row that would
      // have been stored is still stored.
      expect(decision.action, MergeAction.update);
      expect(decision.revisionVerdict, isNotNull);
    });

    test(
      'an honest edit losing to a pinned row reports the row that blocked it — '
      'the only way a pin that predates this detection becomes visible',
      () {
        final decision = RowMerge.decide(
          incoming: row(
            revision: 8,
            createdAt: '2026-09-01T09:00:00.000Z',
            updatedAt: '2026-09-01T09:30:00.000Z',
          ),
          existing: row(
            revision: 4611686018427387904,
            createdAt: '2026-09-01T09:00:00.000Z',
            updatedAt: '2026-09-01T09:10:00.000Z',
          ),
          receivedAt: receivedAt,
        );
        expect(decision.action, MergeAction.skip);
        expect(decision.blockingRowVerdict, isNotNull);
        expect(
          decision.blockingRowVerdict!.incomingRevision,
          4611686018427387904,
        );
      },
    );

    test('an ordinary loss reports no blocking row', () {
      final decision = RowMerge.decide(
        incoming: row(
          revision: 2,
          createdAt: '2026-09-01T09:00:00.000Z',
          updatedAt: '2026-09-01T09:10:00.000Z',
        ),
        existing: row(
          revision: 9,
          createdAt: '2026-09-01T09:00:00.000Z',
          updatedAt: '2026-09-01T09:20:00.000Z',
        ),
        receivedAt: receivedAt,
      );
      expect(decision.action, MergeAction.skip);
      expect(decision.blockingRowVerdict, isNull);
    });
  });
}
