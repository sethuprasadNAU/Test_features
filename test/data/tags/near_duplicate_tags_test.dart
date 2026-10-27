import 'package:flutter_test/flutter_test.dart';
import 'package:tritrack/data/tags/near_duplicate_tags.dart';

import '../fixtures.dart';

/// **Task 11.11's warning, and specifically the two ways it can fail.**
///
/// It can fail by staying quiet when two tags really will collide — the reason
/// it exists. It can also fail by crying wolf, which is worse than not existing
/// at all: a warning that fires on every legitimate `F12b` teaches people to
/// dismiss it unread, and then it is not there for the real one either. Both
/// directions are asserted here.
void main() {
  final coco = sampleTag(id: 'tag-coco', tagName: 'Coco', frequencyMhz: 150.325);

  group('frequency — the match that matters', () {
    test('an identical frequency matches, and says so', () {
      final matches = NearDuplicateTags.find(
        frequencyMhz: 150.325,
        tagName: 'Bandit',
        existing: [coco],
      );
      expect(matches, hasLength(1));
      expect(matches.single.matched, {TagMatchKind.frequency});
      // The whole point of the copy: the reader can check the claim.
      expect(matches.single.summary, contains('150.325'));
      expect(matches.single.summary, contains('Coco'));
      expect(matches.single.summary, contains('same frequency'));
    });

    test('one kilohertz apart is a different collar and does not match', () {
      expect(
        NearDuplicateTags.find(
          frequencyMhz: 150.326,
          tagName: 'Bandit',
          existing: [coco],
        ),
        isEmpty,
      );
    });

    test('a difference too small to display is the same frequency', () {
      // The rule is "these two show the same number", at the three decimals
      // every screen prints — not a tolerance the reader would have to be told.
      expect(NearDuplicateTags.sameFrequency(150.325, 150.32502), isTrue);
      expect(NearDuplicateTags.sameFrequency(150.325, 150.326), isFalse);
    });
  });

  group('name — the softer match', () {
    test('the same name matches whatever the case or the spacing', () {
      final matches = NearDuplicateTags.find(
        frequencyMhz: 151.100,
        tagName: '  coco ',
        existing: [coco],
      );
      expect(matches.single.matched, {TagMatchKind.name});
      expect(matches.single.summary, contains('same name'));
    });

    test('F12b beside F12 does not match — it is usually two real collars', () {
      final f12 = sampleTag(id: 'tag-f12', tagName: 'F12', frequencyMhz: 150.100);
      expect(
        NearDuplicateTags.find(
          frequencyMhz: 150.200,
          tagName: 'F12b',
          existing: [f12],
        ),
        isEmpty,
      );
    });

    test('a blank name never matches on name alone', () {
      final unnamed = sampleTag(id: 'tag-blank', tagName: '', frequencyMhz: 151.0);
      expect(
        NearDuplicateTags.find(
          frequencyMhz: 152.0,
          tagName: '',
          existing: [unnamed],
        ),
        isEmpty,
      );
    });
  });

  test('a genuinely distinct tag produces no warning at all', () {
    expect(
      NearDuplicateTags.find(
        frequencyMhz: 151.775,
        tagName: 'Bandit',
        existing: [coco],
      ),
      isEmpty,
    );
  });

  test('both fields matching is reported as both', () {
    final matches = NearDuplicateTags.find(
      frequencyMhz: 150.325,
      tagName: 'Coco',
      existing: [coco],
    );
    expect(matches.single.matched,
        {TagMatchKind.frequency, TagMatchKind.name});
    expect(matches.single.summary, contains('same frequency and same name'));
  });

  test('editing a tag does not report it as a duplicate of itself', () {
    expect(
      NearDuplicateTags.find(
        frequencyMhz: coco.frequencyMhz,
        tagName: coco.tagName,
        existing: [coco],
        excludeTagId: coco.tagId,
      ),
      isEmpty,
    );
  });

  test('a match on this project is named as such, and sorts first', () {
    // **The second phrase changed with task 11.219 and it is not cosmetic.**
    // It read *"in the tag database, not on this project"*, which was true
    // when there was one global tag table. There is no such thing now: a
    // match is either one of this project's own tags or an entry in the
    // person's device-local library, and those are different objects with
    // different consequences.
    final inLibrary = sampleTagLibraryEntry(
      id: 'library-coco',
      tagName: 'Coco',
      frequencyMhz: 151.0,
    );
    final matches = NearDuplicateTags.find(
      frequencyMhz: 150.325,
      tagName: 'Coco',
      existing: [inLibrary, coco],
      projectTagIds: {coco.tagId},
    );
    expect(matches.first.existing.tagId, coco.tagId);
    expect(matches.first.summary, contains('already on this project'));
    expect(matches.last.summary, contains('in your tag library'));
  });

  test('a copy is not a duplicate of the library entry it came from', () {
    // **§2.6's trap.** Copying a library entry into a project produces, by
    // definition, a tag with the same frequency and the same name as the
    // entry it came from. Run that through this check unchanged and *every
    // single copy warns* — and a warning that always fires is one people
    // learn to dismiss, which is the exact failure this check's own doc
    // comment says it exists to avoid, caused by the check itself.
    final entry = sampleTagLibraryEntry(id: 'library-1', lineageId: 'lin-1');
    expect(
      NearDuplicateTags.find(
        frequencyMhz: entry.frequencyMhz,
        tagName: entry.tagName,
        existing: [entry],
        excludeLineageIds: {'lin-1'},
      ),
      isEmpty,
    );
    // And the control: without the exclusion it *does* fire, so the test
    // above is measuring the exclusion rather than an empty corpus.
    expect(
      NearDuplicateTags.find(
        frequencyMhz: entry.frequencyMhz,
        tagName: entry.tagName,
        existing: [entry],
      ),
      hasLength(1),
    );
  });
}
