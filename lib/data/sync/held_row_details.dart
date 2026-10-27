import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

import '../repositories/deployment_linking.dart'
    show formatLinkDate, formatLinkInstant;
import '../repositories/deployment_repository.dart' show OverlappingDeployment;
import 'sync_held_rows.dart';

/// One held row, resolved into the three things a person needs: **which
/// record, which rule held it, and what they can do about it** — task 11.41.
///
/// ## Why this exists
///
/// The banner says *"2 records aren't on the server. Tap to see why"* and the
/// screen it opened did not say why. It printed the table name — the literal
/// words "Tags" and "Users" — one paragraph of prose covering three unrelated
/// causes, and a "Try again" button. A person looking at it could not tell
/// **which** tag, **which** person, whether their data was safe, or whether
/// there was anything to do.
///
/// That is not a cosmetic complaint. On real hardware it cost a diagnosis:
/// the two rows this task was opened for could have been identified in
/// seconds from a screen that named them, and instead the cause had to be
/// guessed at from two tables' names.
///
/// ## What it may and may not say
///
/// **No server-supplied prose reaches this screen** (security model §4.13) and
/// nothing here changes that. The server answers one opaque `unauthorized` for
/// every reason it refuses a row, deliberately, so that a refusal cannot be
/// used to probe what the server holds — see `RowAuthorizer`. This class
/// therefore never claims to report *the server's* reason.
///
/// What it reports instead is **what is true of the record on this device**:
/// who it says made it, whether that is the person signed in here, and which
/// tags it uses that this project has not added. Those are the facts the
/// server's rules turn on, they are readable locally, and between them they
/// distinguish every case that actually occurs. Where they do not settle it,
/// [HeldRowDetail.heldBy] says so rather than inventing a reason — a control
/// that cannot tell one cause from another must say which it is, and that is
/// the whole point of this file.
///
/// It is **not** a second copy of the server's authorization rules. It states
/// row contents and asks one local membership question; it evaluates no
/// permission and gates nothing. A client-side copy of `RowAuthorizer` is
/// exactly the two-implementations-that-must-agree defect this project keeps
/// finding, and building one here to make a screen read better would be a
/// poor trade.
class HeldRowDetail {
  const HeldRowDetail({
    required this.held,
    required this.recordLabel,
    required this.heldBy,
    required this.whatYouCanDo,
    required this.recordExists,
  });

  /// The stored hold, for the timestamp and retry control.
  final HeldRow held;

  /// Which record — a name a person would recognise, not an id. Falls back to
  /// the row key when the row itself is gone or carries nothing nameable.
  final String recordLabel;

  /// Which rule held it, in one sentence, stated as a fact about this record.
  final String heldBy;

  /// What the person can do — including "nothing, and that is fine".
  final String whatYouCanDo;

  /// False when the row named by the hold is no longer on this device.
  ///
  /// Reported rather than hidden: a hold on a record that does not exist can
  /// never be retried and never resolved by a push, so it is a warning about
  /// nothing. `SyncEngine` settles these on the next sync; until then, saying
  /// so beats printing a table name.
  final bool recordExists;
}

/// Resolves [HeldRow]s against the live database.
abstract final class HeldRowDetails {
  /// **What this device says when the server refused a record and gave no
  /// reason** — task 11.122, item 2.
  ///
  /// ## The defect this replaced, which was not a missing case
  ///
  /// Until this task the `rejected` branch read *"That is a fault in the app
  /// or a version mismatch, not something wrong with what you recorded"* and
  /// *"nothing you can do in the app will change the answer."* Both sentences
  /// were false for the case task 11.84 measured: a name carrying a control
  /// character or a bidirectional override **is** something about what the
  /// person recorded, and editing it in Profile fixes it and re-offers the
  /// row by itself.
  ///
  /// **The defect was not that the branch lacked a second reason.** It was
  /// that *the branch reached when this device has no information stated a
  /// cause as fact.* The push response carries an outcome and no issue
  /// detail, so this device genuinely cannot tell "your value is malformed"
  /// from "app and server on different versions" — and the old copy resolved
  /// that uncertainty by picking one and asserting it.
  ///
  /// ## The rule these two strings exist to hold
  ///
  /// **Fix the default before fixing the case.** The branch reached when the
  /// client does not know why says only what is known: the server refused
  /// this record, here is where to look, here is how to ask. It names no
  /// cause, and it **never says there is nothing you can do** — that is the
  /// one sentence that is unrecoverable when it is wrong, because the person
  /// stops trying and a person who stops trying files no report.
  ///
  /// Written as named constants rather than inline literals so
  /// `held_row_details_test.dart` reads the copy itself, rather than a person
  /// reading it once and it drifting afterwards.
  static const String rejectedWithoutADetail =
      'The server would not store this record and did not say why. This '
      'device cannot tell whether something in the record is wrong or the app '
      'and server are on different versions.';

  /// The remedy half of [rejectedWithoutADetail]. See its doc for the rule.
  ///
  /// Every step here is one the person can actually take, and none of them
  /// claims to be the fix — because this device does not know what the fix
  /// is. The pasted-text hint is first because it is the cause task 11.84
  /// measured, and it is offered as a thing to check rather than as the
  /// answer.
  static const String rejectedRemedy =
      'Your copy is safe. Open the record and retype any text that was pasted '
      'in — pasted text can carry hidden characters the server will not '
      'store. Save, then tap "Try again". If it stays held, it is worth '
      'reporting, with this record\'s name and the app and server versions.';

  /// Reads each hold's record and describes it.
  ///
  /// [currentUserId] is the signed-in person, which is the comparison every
  /// naming sentence below turns on. Null — no identity yet — is handled
  /// rather than assumed away: the sentences then say who the record names
  /// without claiming that is or is not you.
  static Future<List<HeldRowDetail>> resolve(
    DatabaseExecutor db, {
    required String projectId,
    required String? currentUserId,
    required List<HeldRow> held,
  }) async {
    final details = <HeldRowDetail>[];
    final names = PersonNames(db);
    final addedTags = await _tagsAddedTo(db, projectId);

    for (final row in held) {
      final table = syncTablesByName[row.tableName];
      final stored = table == null ? null : await _readRow(db, table, row);
      details.add(
        await _describe(
          held: row,
          table: table,
          stored: stored,
          currentUserId: currentUserId,
          names: names,
          addedTags: addedTags,
          alsoHeld: held,
          db: db,
        ),
      );
    }
    return details;
  }

  static Future<HeldRowDetail> _describe({
    required HeldRow held,
    required SyncTable? table,
    required Map<String, Object?>? stored,
    required String? currentUserId,
    required PersonNames names,
    required Set<String> addedTags,
    required List<HeldRow> alsoHeld,
    required DatabaseExecutor db,
  }) async {
    if (table == null) {
      // A hold on a table this build does not know about — version skew.
      return HeldRowDetail(
        held: held,
        recordLabel: 'A record this version of the app does not recognize',
        heldBy: 'This record comes from a newer version of the app.',
        whatYouCanDo: 'Update the app, then tap "Try again".',
        recordExists: false,
      );
    }

    final label = stored == null
        ? _missingLabel(table, held)
        : await _label(db, table, stored, names);

    if (stored == null) {
      return HeldRowDetail(
        held: held,
        recordLabel: label,
        heldBy:
            'This record is no longer on this device, so nothing is waiting '
            'to be sent.',
        whatYouCanDo: 'Nothing. The next successful sync clears this.',
        recordExists: false,
      );
    }

    // The facts the rules turn on, read straight off the row.
    final namedOthers = <String, String>{}; // column -> user_id
    for (final column in table.userColumns) {
      final value = stored[column];
      if (value is! String || value.isEmpty) continue;
      if (value == currentUserId) continue;
      namedOthers[column] = value;
    }
    final foreignTags = <String>[
      for (final column in table.tagColumns)
        if (stored[column] is String &&
            (stored[column] as String).isNotEmpty &&
            !addedTags.contains(stored[column]))
          stored[column] as String,
    ];

    // Order matters: an author's name is the stricter rule and the one that
    // resolves on its own, so it is reported first when both are true.
    final identityNames = {
      for (final column in table.identityUserColumns)
        if (namedOthers.containsKey(column)) namedOthers[column]!,
    };

    if (held.reason == HeldRowReason.rejected) {
      // **Task 11.267, checked first.** An interlock refusal carries no
      // `RowRefusal` code (deliberately — see `RowIssueCode`'s header), so
      // `_rejectionDetail` below would always return null for one and this
      // device would report the honest default over a cause it can actually
      // explain: it holds both deployments and can re-run the shared rule
      // itself. Returns null when it cannot — no interlock rule was
      // recorded, or a local re-check no longer finds a conflict (the other
      // row was since edited or withdrawn) — and null falls through exactly
      // like `_rejectionDetail` returning null does.
      final interlock = await _interlockDetail(db, table, stored, held);
      if (interlock != null) {
        return HeldRowDetail(
          held: held,
          recordLabel: label,
          heldBy: interlock.heldBy,
          whatYouCanDo: interlock.whatYouCanDo,
          recordExists: true,
        );
      }
      // Task 11.124. `_rejectionDetail` returns null whenever this device
      // cannot honestly name a cause — no code, a code it does not recognise,
      // or a column name that is not one this build declares for this table —
      // and null lands on task 11.122's default below. That default is the
      // answer for every reason nobody has invented yet, so it stays the
      // branch rather than being replaced by the cases that came first.
      final detail = _rejectionDetail(table, held);
      return HeldRowDetail(
        held: held,
        recordLabel: label,
        heldBy: detail?.heldBy ?? rejectedWithoutADetail,
        whatYouCanDo: detail?.whatYouCanDo ?? rejectedRemedy,
        recordExists: true,
      );
    }
    if (held.reason == HeldRowReason.unaccounted) {
      return HeldRowDetail(
        held: held,
        recordLabel: label,
        heldBy:
            'The server did not say what it did with this record, so this '
            'device treats it as refused.',
        whatYouCanDo:
            'Update the app, then tap "Try again". This usually means the app '
            'and server are on different versions.',
        recordExists: true,
      );
    }

    if (identityNames.isNotEmpty) {
      final who = await names.of(identityNames.first);
      return HeldRowDetail(
        held: held,
        recordLabel: label,
        heldBy:
            'This record says $who made it, and this device is signed in as '
            '${await names.orAnonymous(currentUserId)}. It is only accepted '
            'from that person\'s own device.',
        whatYouCanDo:
            'Nothing from this device. It reaches the server only when $who '
            'syncs it from their own; if they never will, it stays here. Keep '
            'this device backed up, or export the project for a second copy.',
        recordExists: true,
      );
    }

    if (foreignTags.isNotEmpty) {
      final tagLabel = await _tagLabel(db, foreignTags.first);
      return HeldRowDetail(
        held: held,
        recordLabel: label,
        heldBy:
            'This record uses $tagLabel, which this project has not added, so '
            'the server will not store it.',
        whatYouCanDo:
            'Ask an owner of this project to add $tagLabel to it, then tap '
            '"Try again".',
        recordExists: true,
      );
    }

    // **Task 11.46: the record is fine, and the record it belongs with is
    // not.** Checked after the two rules that are about *this* row, because
    // when both are true this row's own problem is the one to report — but
    // before the audit-column rule below, which would otherwise answer "your
    // colleague last changed this" for a bearing whose only fault is the
    // session it names.
    final waitingOn = await _referentAlsoWaiting(
      db: db,
      table: table,
      stored: stored,
      held: held,
      alsoHeld: alsoHeld,
      names: names,
    );
    if (waitingOn != null) {
      return HeldRowDetail(
        held: held,
        recordLabel: label,
        heldBy:
            'This record refers to $waitingOn, which is also waiting to be '
            'sent. It goes once that one does.',
        whatYouCanDo:
            'Sort out $waitingOn first — its card is on this screen too. This '
            'one follows on its own.',
        recordExists: true,
      );
    }

    // **The audit column, on a table that also names somebody.** Task 11.47
    // removed this branch's most common and most costly case: on shared
    // vocabulary — a tag, a session, an estimate — who last edited it no
    // longer has to be somebody the project reaches, so those rows are simply
    // accepted now. What still reaches here is a record of *your own* that a
    // colleague last touched, and there the remedy is real and worth stating
    // plainly, because it is the one held-row case a person can actually
    // clear themselves. Until this task it was the tail of a sentence that
    // began "Nothing."
    if (namedOthers.isNotEmpty) {
      final who = await names.of(namedOthers.values.first);
      return HeldRowDetail(
        held: held,
        recordLabel: label,
        heldBy:
            'This record says $who made the last change to it, and this '
            'device is signed in as ${await names.orAnonymous(currentUserId)}. '
            'A change is only accepted from the person it says made it.',
        whatYouCanDo:
            'Open the record, change anything and save: that makes you the '
            'last to change it, and it syncs next time. Otherwise it goes up '
            'when $who\'s own device syncs.',
        recordExists: true,
      );
    }

    // Everything readable on this device says the record is ordinary. The
    // honest answer is that this device does not know — the server answers one
    // opaque refusal for every reason and will not say which.
    return HeldRowDetail(
      held: held,
      recordLabel: label,
      heldBy:
          'The server would not take this record and did not say why, and '
          'nothing in the record on this device explains it.',
      whatYouCanDo:
          'Tap "Try again". If it stays, it is worth reporting — the app does '
          'not expect this.',
      recordExists: true,
    );
  }

  /// **Task 11.267.** The sentence for a row a shared rule about the
  /// project's *other* rows refused, or null when this device cannot answer
  /// for it — [held.interlockRule] names no rule this build knows, [stored]
  /// is not a deployment, or a fresh [DeploymentInterlock.conflictFor] no
  /// longer finds anything for the candidate to conflict with (the other
  /// deployment was since edited or withdrawn, or this device's local copy
  /// has moved on since the push that got refused).
  ///
  /// **Reads the answer from this device's own store rather than the wire.**
  /// The server sends only [DeploymentInterlock.ruleId] — see
  /// `SyncPushResponse.interlockRefusals` — because the device that pushed
  /// this row already holds every row the rule reads, which is what let the
  /// rule refuse a *push* in the first place. Re-running it locally is the
  /// same computation `DeploymentRepository._assertNoConflict` runs before a
  /// local link, so this reports the identical answer rather than a second
  /// one — and it can, unlike a code chosen at the refusal site, say which
  /// two deployments and which dates.
  static Future<({String heldBy, String whatYouCanDo})?> _interlockDetail(
    DatabaseExecutor db,
    SyncTable table,
    Map<String, Object?>? stored,
    HeldRow held,
  ) async {
    if (held.interlockRule != DeploymentInterlock.ruleId) return null;
    if (table.name != DeploymentInterlock.table || stored == null) {
      return null;
    }
    final candidate = DeploymentInterlock.intervalFromRow(stored);
    final projectId = stored['project_id'];
    if (candidate == null || projectId is! String) return null;

    final rows = await db.query(
      table.name,
      where: 'project_id = ? AND deployment_id != ?',
      whereArgs: [projectId, candidate.deploymentId],
    );
    final others = <DeploymentInterval>[
      for (final row in rows)
        ?DeploymentInterlock.intervalFromRow(row),
    ];
    final conflict = DeploymentInterlock.conflictFor(candidate, others);
    if (conflict == null) return null;

    final otherClause = await _deploymentClause(db, conflict.other);
    return (
      heldBy:
          'The server would not store this record because it overlaps '
          'another deployment: $otherClause. '
          '${OverlappingDeployment.messageFor(conflict.subject)}',
      whatYouCanDo:
          'Open the animal\'s page and set a time on the attached or '
          'removed date so the two no longer overlap, then tap "Try again". '
          'Or undo one of the two links with Remove record.',
    );
  }

  /// One deployment named and dated, for [_interlockDetail]'s sentence —
  /// "the tag \"X\" (attached 2026-09-10, removed 2026-09-15)".
  static Future<String> _deploymentClause(
    DatabaseExecutor db,
    DeploymentInterval other,
  ) async {
    final tagLabel = await _tagLabel(db, other.tagId);
    final attached = other.attachedDate;
    final removed = other.removedDate;
    final range = attached == null
        ? 'no attached date recorded'
        : removed == null
        ? 'attached ${_dayAndTime(attached, other.timeZone)}, still on'
        : 'attached ${_dayAndTime(attached, other.timeZone)}, removed '
              '${_dayAndTime(removed, other.timeZone)}';
    return '$tagLabel ($range)';
  }

  /// **In this device's zone (task 11.326).** A deployment date is local
  /// midnight where it was written (`deploymentDateFor`) and is stored as a
  /// UTC instant; read back through UTC it was the day before anywhere east
  /// of UTC — a held card in New Zealand or London named the wrong days.
  ///
  /// **With the time when the end has one (task 11.323 item 7).** The remedy
  /// below asks for a time on a date, so a same-day swap's time is the fact
  /// the person has to work around; a bare day still reads as a day.
  ///
  /// **In the row's own zone since task 11.331** ([zone]) — the field's day,
  /// whatever zone this device is in. A row from before schema v20 has none
  /// and still reads in this device's zone, as above.
  static String _dayAndTime(DateTime at, [String? zone]) =>
      formatLinkInstant(at, zone);

  /// The day alone, for the card's title (task 11.326's zone rule above).
  static String _dateOnly(DateTime at, [String? zone]) =>
      formatLinkDate(at, zone);

  /// The specific sentence for a refusal the server explained, or **null
  /// whenever this device cannot honestly name a cause** — task 11.124.
  ///
  /// ## Null is the important return value
  ///
  /// It is returned for three different situations, and they are deliberately
  /// not told apart: no code stored (a row held before this column existed, or
  /// a refusal the server could not explain), a code this build does not
  /// recognise (a newer server), and a field name that is not a column this
  /// build declares for this table. All three mean the same thing to the
  /// person reading the screen — *this device does not know why* — and all
  /// three land on [rejectedWithoutADetail], which task 11.122 wrote to be
  /// correct for exactly the reasons nobody has invented yet.
  ///
  /// ## Why the field name is checked rather than printed
  ///
  /// `issueField` is a string the **server** chose. It names a column of a row
  /// this device composed and sent, so it discloses nothing — but a value from
  /// the wire that reaches a screen unexamined is how a screen ends up
  /// rendering whatever a server feels like sending. So it is matched against
  /// [SyncTable.columns] for this table and used only as a lookup key; the
  /// words a person reads are written here. The set it is matched against is
  /// [tableSpecsByName] — the same canonical declaration the validator that
  /// produced the refusal read, so the two cannot drift.
  static ({String heldBy, String whatYouCanDo})? _rejectionDetail(
    SyncTable table,
    HeldRow held,
  ) {
    final code = held.issueCode;
    if (code == null) return null;

    final field = held.issueField;
    final declared = tableSpecsByName[table.name]?.columnNames;
    final known = field != null && (declared?.contains(field) ?? false);
    final what = known ? _fieldPhrase(field) : null;

    // The subject of every sentence below. Without a usable field name it
    // names the *kind* of value at fault — which is weaker than naming the
    // column and still far better than naming no cause at all. The switch is
    // exhaustive, so a code added to the vocabulary has to be given a subject
    // here rather than silently falling into the wrong one.
    final subject =
        what ??
        switch (code) {
          RowIssueCode.textNotAName ||
          RowIssueCode.textNotAnIdentifier ||
          RowIssueCode.textTooLong ||
          RowIssueCode.textWrongType ||
          RowIssueCode.textNotAColor => 'one of the text values in this record',
          RowIssueCode.numberWrongType ||
          RowIssueCode.numberNotARealNumber ||
          RowIssueCode.numberBelowMinimum ||
          RowIssueCode.numberAboveMaximum => 'one of the numbers in this record',
        };

    return switch (code) {
      RowIssueCode.textNotAName => (
        heldBy:
            'The server would not store this record because $subject contains '
            'a character it will not accept in a name. Names may hold only '
            'letters, digits, spaces, dashes and ordinary punctuation; an '
            'invisible character in pasted text is the usual cause.',
        whatYouCanDo:
            'Open the record, retype $subject by hand rather than pasting it, '
            'save, and tap "Try again".',
      ),
      RowIssueCode.textNotAnIdentifier => (
        heldBy:
            'The server would not store this record because $subject is not a '
            'usable identifier. The app makes identifiers, so the fault is in '
            'the app or an import, not in what you recorded.',
        whatYouCanDo:
            'Tap "Try again" in case it was a one-off. If it stays held, it is '
            'worth reporting, with this record\'s name and the app and server '
            'versions.',
      ),
      RowIssueCode.textTooLong => (
        heldBy:
            'The server would not store this record because $subject is too '
            'long for the space it has.',
        whatYouCanDo:
            'Open the record and shorten $subject (copy anything you want to '
            'keep first), then save and tap "Try again".',
      ),
      RowIssueCode.textWrongType => (
        heldBy:
            'The server expected $subject to be text and found something '
            'else. The fault is in the app or an import, not in what you '
            'recorded.',
        whatYouCanDo:
            'Tap "Try again" in case it was a one-off. If it stays held, it is '
            'worth reporting, with this record\'s name and the app and server '
            'versions.',
      ),
      RowIssueCode.textNotAColor => (
        heldBy:
            'The server would not store this record because $subject is not a '
            'color it recognizes. The fault is in the app or an import, not '
            'in what you recorded.',
        whatYouCanDo:
            'Open the record, pick the color again, save, and tap "Try '
            'again".',
      ),
      // **Task 11.136's three.** Each says what is out of bounds and leaves
      // the reader somewhere to go. None of them says what the bound *is*: the
      // number lives on the server's copy of the schema as well as this
      // device's, and a sentence quoting one this build happens to hold would
      // be the correct-when-written-then-silently-falsified class the sign-in
      // screen already refused to write.
      RowIssueCode.numberBelowMinimum => (
        heldBy:
            'The server would not store this record because $subject is '
            'smaller than it allows — usually a position out of range, or a '
            'zero where a real measurement belongs.',
        whatYouCanDo:
            'Open the record, check $subject, save any correction and tap '
            '"Try again". If the value looks right, it is worth reporting, '
            'with this record\'s name and the app and server versions.',
      ),
      RowIssueCode.numberAboveMaximum => (
        heldBy:
            'The server would not store this record because $subject is '
            'larger than it allows — usually a position out of range, or a '
            'bearing or frequency outside the app\'s band.',
        whatYouCanDo:
            'Open the record, check $subject, save any correction and tap '
            '"Try again". If the value looks right, it is worth reporting, '
            'with this record\'s name and the app and server versions.',
      ),
      // **Task 11.158's one.** Like [RowIssueCode.textWrongType] it is about
      // the *kind* of value rather than its size, so it names no bound — and
      // like task 11.122's default it stops short of saying there is nothing
      // to be done, because for a record that came in from a spreadsheet
      // there often is.
      RowIssueCode.numberWrongType => (
        heldBy:
            'The server expected $subject to be a number and found a word or '
            'a blank. A record imported from a spreadsheet or another app is '
            'the usual cause.',
        whatYouCanDo:
            'Open the record and type a number into $subject if you can, then '
            'save and tap "Try again". If there is nothing to correct, or it '
            'stays held, it is worth reporting, with this record\'s name and '
            'the app and server versions.',
      ),
      RowIssueCode.numberNotARealNumber => (
        heldBy:
            'The server would not store this record because $subject is not a '
            'real number — it is missing or unmeasurable. An import or a fault '
            'in the app is the usual cause, not what you recorded.',
        whatYouCanDo:
            'Open the record and retype $subject if you can, then save and tap '
            '"Try again". If it stays held, it is worth reporting, with this '
            'record\'s name and the app and server versions.',
      ),
    };
  }

  /// A column name in words a person would recognise.
  ///
  /// **A fallback rather than a table of every column**, and that is a
  /// decision rather than an omission: the columns a person can actually edit
  /// are few, and a hand-kept map of all 200-odd would be wrong the first time
  /// somebody added one — task 11.88's rule. The general form reads acceptably
  /// for anything not named here ("the position source", "the antenna type"),
  /// so a new column gets a serviceable sentence with nobody having to
  /// remember this file exists.
  static String _fieldPhrase(String column) => switch (column) {
    'first_name' => 'the first name',
    'last_name' => 'the last name',
    'email' => 'the email address',
    'tag_name' => 'the tag name',
    'project_name' => 'the project name',
    'notes' => 'the notes',
    'label' => 'the label',
    _ => 'the ${column.replaceAll('_', ' ')}',
  };

  /// Reads the one row a hold names, or null if it is gone.
  /// **Task 11.46.** Names the record [stored] points at, when that record is
  /// itself being held — or null when it points at nothing that is waiting.
  ///
  /// ## Why this branch had to exist
  ///
  /// A project built from a colleague's archive carries rows a colleague last
  /// touched, and the server refuses those (correctly — a record is only
  /// accepted from the person it says made it). The rows that then fail are
  /// not those rows: they are the person's **own** bearings, which point at
  /// them. Every fact this file reads off such a bearing says it is ordinary —
  /// it names the right author, it uses a tag the project has added — so it
  /// fell through to the "the server did not say why" ending, on the field
  /// data, which is the record a biologist cares about most. The cause was one
  /// card away on the same screen and nothing connected them.
  ///
  /// ## How the link is found, and what that does not cover
  ///
  /// A held row is identified by its primary key, and this schema names a
  /// referring column after the key column it refers to — `tag_id`,
  /// `session_id`, `project_id`, `user_id`. So a row refers to a held record
  /// when it carries **every** column of that record's primary key, with
  /// matching values. Both halves matter: requiring all of them is what stops
  /// two bearings in one project matching each other on `project_id` alone.
  ///
  /// **The one reference this misses is `Projects.owner_user_id → Users`,**
  /// which is spelled differently at the two ends — and that case never
  /// reaches here, because a row naming somebody else is answered by the
  /// naming rules above. Stated rather than left to be discovered: this is a
  /// same-name convention, not a declared foreign-key graph. The declared one
  /// lives in the server's `postgres_schema.dart` and does not reach this
  /// package; see the plan's Discovered Scope for what moving it would buy.
  ///
  /// Where more than one held record matches, the earliest in [syncTables]
  /// wins. That list is in foreign-key-safe order, so the earliest match is
  /// the root of the cascade rather than something further down it — a bearing
  /// held behind a tag is told about the tag, not about the tag's project link
  /// which is stuck behind the same tag.
  static Future<String?> _referentAlsoWaiting({
    required DatabaseExecutor db,
    required SyncTable table,
    required Map<String, Object?> stored,
    required HeldRow held,
    required List<HeldRow> alsoHeld,
    required PersonNames names,
  }) async {
    for (final candidate in syncTables) {
      for (final other in alsoHeld) {
        if (other.tableName != candidate.name) continue;
        // A record does not wait for itself.
        if (other.tableName == held.tableName && other.rowKey == held.rowKey) {
          continue;
        }
        // Its primary key, as the columns and values that identify it.
        final clause = syncRowKeyWhere(candidate, other.rowKey);
        if (clause == null) continue;
        final keyValues = <String, Object?>{};
        for (var i = 0; i < candidate.primaryKey.length; i++) {
          if (i < clause.args.length) {
            keyValues[candidate.primaryKey[i]] = clause.args[i];
          }
        }
        if (keyValues.length != candidate.primaryKey.length) continue;
        final refers = keyValues.entries.every(
          (entry) =>
              stored.containsKey(entry.key) &&
              stored[entry.key] != null &&
              stored[entry.key].toString() == entry.value.toString(),
        );
        if (!refers) continue;

        final otherRow = await _readRow(db, candidate, other);
        if (otherRow == null) continue;
        return _label(db, candidate, otherRow, names);
      }
    }
    return null;
  }

  static Future<Map<String, Object?>?> _readRow(
    DatabaseExecutor db,
    SyncTable table,
    HeldRow held,
  ) async {
    final clause = syncRowKeyWhere(table, held.rowKey);
    if (clause == null) return null;
    final rows = await db.query(
      table.name,
      where: clause.where,
      whereArgs: clause.args,
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first;
  }

  /// Which tags this project has — the question an owner can act on.
  ///
  /// **Task 11.219: read from `Tags` itself, not from a link table.** A tag
  /// belongs to one project now, so "this project has that tag" is the tag
  /// row's own `project_id`. Deleted rows count: a tag removed from the
  /// project is still one an owner can put back, which is exactly the action
  /// this answer is used to suggest.
  static Future<Set<String>> _tagsAddedTo(
    DatabaseExecutor db,
    String projectId,
  ) async {
    final rows = await db.query(
      Tables.tags,
      columns: ['tag_id'],
      where: 'project_id = ?',
      whereArgs: [projectId],
    );
    return {
      for (final row in rows)
        if (row['tag_id'] is String) row['tag_id'] as String,
    };
  }

  static Future<String> _tagLabel(DatabaseExecutor db, String tagId) async {
    final rows = await db.query(
      Tables.tags,
      columns: ['tag_name', 'frequency_mhz'],
      where: 'tag_id = ?',
      whereArgs: [tagId],
      limit: 1,
    );
    // A tag id is unique across the device even now that the key is
    // composite: every id is a fresh v4 UUID, and a copy takes a new one.
    // This is a label, not a lookup that decides anything.
    if (rows.isEmpty) return 'a tag this device does not have';
    return 'the tag ${_tagText(rows.first)}';
  }

  static String _tagText(Map<String, Object?> row) {
    final name = row['tag_name'];
    final mhz = row['frequency_mhz'];
    final frequency = mhz is num ? '${mhz.toStringAsFixed(3)} MHz' : null;
    if (name is String && name.isNotEmpty) {
      return frequency == null ? '"$name"' : '"$name" ($frequency)';
    }
    return frequency ?? 'unnamed';
  }

  static String _missingLabel(SyncTable table, HeldRow held) =>
      '${_humanTableName(table.name)} · ${held.rowKey}';

  /// A name for one record, per table — **the dispatch itself, not a lookup
  /// beside one.**
  ///
  /// A `Map` rather than a `switch`, so `recordLabelBuilders.keys` is the same
  /// object the code dispatches on and `held_row_details_test.dart` can assert
  /// that every synced table is covered without the assertion and the
  /// behaviour being able to drift apart. That is task 10.66's standing
  /// criterion applied here: a table name keyed by hand is exactly the shape
  /// that silently exempts a new table, and the exemption would put that
  /// table's records back to being described by their bare table name — the
  /// state this whole file exists to end.
  static final Map<String, LabelBuilder> recordLabelBuilders = {
    Tables.users: (db, row, names) async =>
        'The person ${await names.of(row['user_id'] as String? ?? '')}',
    Tables.userEmails: (db, row, names) async =>
        'An email address recorded for '
        '${await names.of(row['user_id'] as String? ?? '')}',
    Tables.projects: (db, row, names) async =>
        'The project "${row['project_name'] ?? 'unnamed'}"',
    Tables.projectMemberships: (db, row, names) async =>
        '${await names.of(row['user_id'] as String? ?? '')}\'s membership of '
        'this project (${row['role'] ?? 'unknown role'})',
    // Task 11.240. The animal's own name, which is what a person calls it.
    Tables.individuals: (db, row, names) async =>
        'The animal "${row['name'] ?? 'unnamed'}"',
    Tables.tags: (db, row, names) async => 'The tag ${_tagText(row)}',
    // Task 11.243. **It names the collar and not the animal**, because this
    // row carries a `tag_id` and an `individual_id` and only the first has a
    // helper that can turn an id into something a person recognises. Naming
    // the animal would mean a second lookup, and a held row is exactly the
    // case where the animal's row may not have arrived either — so the
    // sentence would fall back to an id, which is worse than not offering
    // one. The date is what distinguishes two deployments of one collar.
    Tables.deployments: (db, row, names) async {
      // The stored text is the UTC instant, so it is rendered in this
      // device's zone, as [_dateOnly] is (task 11.326). A held row can be
      // held for a malformed value, so text that does not parse is shown as
      // it is stored rather than thrown on.
      final raw = row['attached_date'];
      final at = raw is String ? DateTime.tryParse(raw) : null;
      final zone = row['time_zone'];
      final day = at != null
          ? _dateOnly(at, zone is String ? zone : null)
          : raw is String && raw.isNotEmpty
          ? raw.split('T').first
          : null;
      return 'Which animal wore the tag ${_tagText(row)}'
          '${day != null ? ', from $day' : ''}';
    },
    Tables.tagVersions: (db, row, names) async =>
        'A recorded change to the tag ${_tagText(row)}',
    Tables.triangulationSessions: (db, row, names) async {
      final label = row['label'];
      return label is String && label.isNotEmpty
          ? 'The session "$label"'
          : 'A triangulation session from ${_when(row, 'started_at_local')}';
    },
    Tables.observations: (db, row, names) async =>
        'A bearing on '
        '${await _tagLabelBare(db, row['tag_id'] as String? ?? '')}, '
        '${_when(row, 'timestamp_local')}',
    Tables.nonDetections: (db, row, names) async =>
        'A "heard nothing" record, ${_when(row, 'timestamp_local')}',
    Tables.observationExclusions: (db, row, names) async =>
        row['kind'] == 'supersede'
        ? 'A bearing marked as superseded'
        : 'A bearing marked as excluded',
    Tables.estimatedPositions: (db, row, names) async =>
        'An estimated position for '
        '${await _tagLabelBare(db, row['tag_id'] as String? ?? '')}, '
        '${_when(row, 'timestamp_local')}',
    Tables.actualTagLocations: (db, row, names) async =>
        'A known location for '
        '${await _tagLabelBare(db, row['tag_id'] as String? ?? '')}, '
        '${_when(row, 'timestamp_local')}',
  };

  static Future<String> _label(
    DatabaseExecutor db,
    SyncTable table,
    Map<String, Object?> row,
    PersonNames names,
  ) async {
    final builder = recordLabelBuilders[table.name];
    // The fallback the guard test forbids for any table in `syncTables`. It
    // stays reachable for a client-only table, which never reaches this screen
    // but should not crash it if it ever does.
    if (builder == null) return _humanTableName(table.name);
    return builder(db, row, names);
  }

  /// The tag-naming half of [_label], without the leading "the tag".
  static Future<String> _tagLabelBare(DatabaseExecutor db, String tagId) async {
    final rows = await db.query(
      Tables.tags,
      columns: ['tag_name', 'frequency_mhz'],
      where: 'tag_id = ?',
      whereArgs: [tagId],
      limit: 1,
    );
    return rows.isEmpty ? 'a tag not on this device' : _tagText(rows.first);
  }

  static String _when(Map<String, Object?> row, String column) {
    final value = row[column];
    if (value is! String || value.length < 16) return 'at an unknown time';
    return value.substring(0, 16).replaceFirst('T', ' ');
  }

  /// The table names this file may still fall back to, made readable.
  static String _humanTableName(String tableName) =>
      tableName.replaceAll('_', ' ').trim();
}

/// Builds the human name for one record of one table.
typedef LabelBuilder =
    Future<String> Function(
      DatabaseExecutor db,
      Map<String, Object?> row,
      PersonNames names,
    );

/// `user_id` → the name a person would recognise, read once each.
class PersonNames {
  PersonNames(this.db);

  final DatabaseExecutor db;
  final Map<String, String> _cache = {};

  Future<String> of(String userId) async {
    if (userId.isEmpty) return 'somebody this device cannot name';
    final cached = _cache[userId];
    if (cached != null) return cached;
    final rows = await db.query(
      Tables.users,
      columns: ['first_name', 'last_name'],
      where: 'user_id = ?',
      whereArgs: [userId],
      limit: 1,
    );
    final name = rows.isEmpty
        ? 'somebody whose name this device does not have'
        : '${rows.first['first_name'] ?? ''} '
                  '${rows.first['last_name'] ?? ''}'
              .trim();
    final resolved = name.isEmpty
        ? 'somebody whose name this device does not have'
        : name;
    _cache[userId] = resolved;
    return resolved;
  }

  Future<String> orAnonymous(String? userId) async =>
      userId == null ? 'nobody yet' : of(userId);
}
