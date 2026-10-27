import 'package:tritrack_sync/tritrack_sync.dart';

import '../models/deployment.dart';
import 'base_repository.dart';
import 'mutation_authorization.dart';

/// **The dated link between a collar and an animal** — task 11.243,
/// `CLAUDE_DOCS/ANIMALS_AND_DEPLOYMENTS_DESIGN.md` §§4 and 6.
///
/// An ordinary project-scoped repository under the role gradient
/// [BaseRepository.insertRow] applies everywhere: a viewer writes nothing, a
/// contributor may record a collaring. **There is no owner-only rung**, and
/// that is a decision rather than an oversight — saying which collar went on
/// which bird is exactly what the person holding the bird knows and the owner
/// does not, and requiring an owner would mean it is recorded at the end of
/// the season or not at all. See `tableMutationRules`.
///
/// ## The interlock lives at the write, and also on the server
///
/// [link] and [update] refuse a deployment that would put two collars on one
/// animal, or one collar on two animals, for any moment at all — Michael's
/// rule, §6, with its one-day allowance withdrawn by §6a (task 11.263).
/// **The rule itself is `DeploymentInterlock` in the
/// shared package and this class only supplies the project's other rows**,
/// because `SyncService` on the server has to reach the same answer against a
/// row arriving from an untrusted device. A rule enforced on one device is a
/// rule about that device, not about the record.
///
/// ## What is deliberately not here
///
/// **No `individual_id` on an observation, ever** (§7). "Which animal was
/// this bearing about" is [animalForObservationIn] — a walk over intervals —
/// and it is a derivation rather than a stored pointer so that correcting a
/// date re-attributes exactly the window corrected. Storing it would undo
/// task 11.32 at a larger scale.
class DeploymentRepository extends BaseRepository {
  DeploymentRepository(super.db)
    : super(
        table: Tables.deployments,
        pk: const ['deployment_id', 'project_id'],
        rule: MutationRule.anyUser,
      );

  /// Records that [deployment]'s collar went on its animal.
  ///
  /// Throws [OverlappingDeployment] when the interlock refuses it, naming the
  /// row it collides with — **never silently adjusting a date somebody
  /// wrote**, per §6.
  Future<void> link(Deployment deployment) async {
    await _assertNoConflict(deployment);
    await insertRow(deployment.toColumns());
  }

  /// Edits a deployment — its dates, its notes, or which row either end
  /// names. Re-checks the interlock, because moving a date is exactly the
  /// edit that can create an overlap.
  Future<int> update(
    Deployment deployment, {
    required MutationActor actor,
    String? deviceId,
    DateTime? now,
  }) async {
    await _assertNoConflict(deployment);
    return updateByKey(
      {
        'deployment_id': deployment.deploymentId,
        'project_id': deployment.projectId,
      },
      deployment.toColumns(),
      actor: actor,
      deviceId: deviceId,
      now: now,
    );
  }

  /// Withdraws a link. Tombstoned rather than hard-deleted like everything
  /// else, and a tombstoned deployment constrains nothing — which is what
  /// makes withdrawing one actually free both ends (see
  /// [DeploymentInterlock]).
  Future<int> unlink(
    String deploymentId, {
    required String projectId,
    required MutationActor actor,
    String? deviceId,
    DateTime? now,
  }) => softDeleteByKey(
    {'deployment_id': deploymentId, 'project_id': projectId},
    actor: actor,
    deviceId: deviceId,
    now: now,
  );

  Future<void> _assertNoConflict(Deployment deployment) async {
    final conflict = DeploymentInterlock.conflictFor(
      deployment.interval,
      (await findByProject(
        deployment.projectId,
      )).map((d) => d.interval),
    );
    if (conflict != null) {
      throw OverlappingDeployment(
        candidate: deployment,
        conflict: conflict,
      );
    }
  }

  Future<Deployment?> findById(
    String id, {
    required String projectId,
    bool includeDeleted = false,
  }) async {
    final row = await findRowByKey({
      'deployment_id': id,
      'project_id': projectId,
    }, includeDeleted: includeDeleted);
    return row == null ? null : Deployment.fromRow(row);
  }

  /// Every deployment in one project, oldest first.
  ///
  /// A null `attached_date` sorts last rather than first: SQLite orders NULL
  /// before everything, and a deployment nobody dated is the one least likely
  /// to be what a person is looking for.
  Future<List<Deployment>> findByProject(
    String projectId, {
    bool includeDeleted = false,
  }) async {
    final rows = await findRows(
      where: 'project_id = ?',
      whereArgs: [projectId],
      includeDeleted: includeDeleted,
      orderBy: 'attached_date IS NULL, attached_date, deployment_id',
    );
    return rows.map(Deployment.fromRow).toList();
  }

  /// "Marie's collars" — every deployment of [individualId], oldest first.
  ///
  /// Tombstoned deployments are **excluded** by default, unlike
  /// `TagRepository.findByIndividual`'s old behaviour: a withdrawn link is a
  /// statement that the collar was never on this animal, not a record that it
  /// was and then came off. Coming off is a `removed_date`.
  Future<List<Deployment>> findByIndividual(
    String individualId, {
    required String projectId,
    bool includeDeleted = false,
  }) async {
    final rows = await findRows(
      where: 'individual_id = ? AND project_id = ?',
      whereArgs: [individualId, projectId],
      includeDeleted: includeDeleted,
      orderBy: 'attached_date IS NULL, attached_date, deployment_id',
    );
    return rows.map(Deployment.fromRow).toList();
  }

  /// Every deployment of [tagId] — "who has worn this collar".
  Future<List<Deployment>> findByTag(
    String tagId, {
    required String projectId,
    bool includeDeleted = false,
  }) async {
    final rows = await findRows(
      where: 'tag_id = ? AND project_id = ?',
      whereArgs: [tagId, projectId],
      includeDeleted: includeDeleted,
      orderBy: 'attached_date IS NULL, attached_date, deployment_id',
    );
    return rows.map(Deployment.fromRow).toList();
  }

  /// **Which animal a record taken against [tagId] at [at] was about** — the
  /// load-bearing derivation, design §7, and since task 11.251 an answer
  /// that can be *contested* (design §4a).
  ///
  /// Every live deployment of the collar whose interval contains the moment
  /// ([Deployment.coversMoment]) is a candidate. One candidate is the
  /// answer; none is [AnimalAttribution.nobody]; **more than one is reported
  /// as contested and never resolved by picking.** Reads [deployments] — the
  /// project's, or one tag's; see below for why it does not fetch them
  /// itself.
  ///
  /// ## Why it does not return the first match
  ///
  /// It did, until 2026-09-15, and the interval was half-open to make sure
  /// there was only ever one — which put every bearing taken on the day a
  /// collar came off inside *no* deployment, and on a same-day swap inside
  /// the *next* animal's. Michael saw both on his map. §4a's fix closes a
  /// date-only day at both ends, so two deployments can now cover one moment
  /// (a hand-typed pair, an older row, a swap whose time was skipped) —
  /// and a derivation that returned the first of them would answer
  /// confidently and arbitrarily, with no boundary condition left to find it
  /// by. So the readers get the list and decide in the open: the Log shows
  /// the record under every candidate, the Map draws it neutral and the
  /// legend says why. Rare by construction, because the §5a confirmation
  /// records the time on a swap, and a time beats a day.
  ///
  /// ## Two answers that look like bugs and are the design
  ///
  /// **A bearing with no covering deployment has no animal.** A collar that
  /// falls off keeps transmitting, and bearings taken on it afterwards belong
  /// to no animal — that is the honest answer and it is the second of the
  /// three things the whole table was built for (§2). *The natural
  /// implementation quietly attributes them to the most recent animal
  /// instead*, which is precisely the lie the old `Tags.individual_id`
  /// told; it is asserted in this repository's tests so a later "fix" has to
  /// argue with a test rather than with a comment. **The Log's animal filter
  /// is the caller** (task 11.244), and it was over-selecting on exactly this
  /// point before it used this: filtering by Marie returned bearings taken on
  /// her collar in the seasons before she wore it.
  ///
  /// **A deployment with a null `attached_date` covers no interval and
  /// attributes nothing** — including bearings taken while the collar
  /// demonstrably was on. Nobody said when it went on, so nothing can be said
  /// about which bearings it covers. Michael named this as the thing that
  /// will look like a bug the first time he meets it; it is asserted too.
  ///
  /// Tombstoned deployments are excluded: a withdrawn link never happened —
  /// which is the caller's job here, since this reads a list it was handed.
  ///
  /// ## A tombstoned tag or animal answers, task 11.258
  ///
  /// **This deliberately does not check whether [tagId] or the candidate's
  /// animal is still live.** The question is *"which animal was this bearing
  /// about"*, and that is a fact about the moment the bearing was taken — it
  /// does not change because somebody later removed the tag from the project
  /// or deleted the animal. `TagRepository.removeFromProject`'s own doc
  /// comment makes exactly this argument for the tag side ("every
  /// observation… still resolves"); this extends it to the animal side. A
  /// caller that displays the answer, rather than merely matching against
  /// it, is the one responsible for handling a name that is no longer live —
  /// the Log's filter only ever offers a live animal to filter *by* (so a
  /// candidate naming a tombstoned one is simply never selectable, never
  /// hidden), and the Map's [Deployment] readers fall back to the neutral
  /// swatch when a candidate's id is not in the live animal list it was
  /// handed. **This is the opposite answer from [latestDeploymentsSubquery],
  /// on purpose**: that derivation answers "whose collar is this *now*",
  /// which a tombstoned animal cannot be; this one answers what a moment in
  /// the past was about, which a tombstoned animal still can be.
  ///
  /// ## Why it takes a list rather than querying
  ///
  /// **It was an `async` method with its own query until task 11.244**, and
  /// it had no caller — declared in `sync_auth_uncalled_methods_test.dart`'s
  /// exemption list with this task named as the trigger. The trigger fired,
  /// and the answer was not to find it one caller but to notice that **every
  /// real caller asks it about many records at once**: the Log filters a
  /// screenful of bearings, the map colours a screenful of rays. A per-record
  /// query would be one SQLite round trip per row on the UI path.
  ///
  /// So the derivation is a pure function over deployments the caller already
  /// has, and there is exactly one of it. `DeploymentRepository.findByTag`
  /// or `projectDeploymentsProvider` is where the list comes from.
  static AnimalAttribution animalForObservationIn(
    Iterable<Deployment> deployments, {
    required String tagId,
    required DateTime at,
  }) => AnimalAttribution.among([
    for (final deployment in deployments)
      if (deployment.tagId == tagId &&
          !deployment.sync.isDeleted &&
          deployment.coversMoment(at))
        deployment.individualId,
  ]);

  /// **Whose collar this is, for a screen that has to put it somewhere** —
  /// the animal of its most recent deployment, or null for a collar nobody
  /// has ever linked.
  ///
  /// ## This answers a display question, not an attribution one
  ///
  /// [animalForObservationIn] answers *"which animal was this bearing
  /// about"* and takes a timestamp, because that is the only honest way to
  /// ask it.
  /// This answers *"which animal does this collar belong under"* — the
  /// grouping on Project Setup, the swatch on a tag row, the colour of a
  /// legend entry — and there is no timestamp to ask it with, because a list
  /// of equipment is not about a moment.
  ///
  /// **The two give different answers and both are right.** A collar that
  /// came off Marie in June and has been transmitting from the bottom of a
  /// gully since is *listed under Marie* — she is whose collar it is — while
  /// every bearing taken on it since June is attributed to **nobody**. The
  /// second is the fact that matters to the data and it is the one
  /// [animalForObservationIn] is careful about; the first is where a person
  /// looks for the row.
  ///
  /// **Most recent, not "still on".** "Still on" would move a retired
  /// collar into the unlinked pile the moment its deployment ended, which
  /// puts it beside collars nobody has ever used and offers to link it
  /// afresh — a worse answer than the one it had a minute earlier. A
  /// deployment with no attached date is skipped, for the reason on
  /// [DeploymentInterlock]: it covers no interval, so it cannot be the most
  /// recent anything.
  ///
  /// ## One query, shared with the tag read join
  ///
  /// This and `TagRepository`'s read join (`Tag.individualName`, the swatch
  /// colour) ask the same question, and until task 11.251 they were two
  /// implementations — a Dart walk here and SQL there — that had to be kept
  /// agreeing by hand. Michael found them disagreeing on 2026-09-14: a tag
  /// moved to a second animal the same day, and both tie-broke on
  /// `attached_date` alone, where a same-day reassignment ties. Both were
  /// fixed that day to break the tie on `created_at`, in parallel, with a
  /// comment on each pointing at the other. **That is a matching comment,
  /// not a shared implementation**, so this method now runs
  /// [latestDeploymentsSubquery] — the exact text the join embeds — and the
  /// two cannot drift.
  Future<String?> latestAnimalForTag(
    String tagId, {
    required String projectId,
  }) async {
    final rows = await db.rawQuery(
      'SELECT individual_id FROM ($latestDeploymentsSubquery) d '
      'WHERE d.tag_id = ? AND d.project_id = ?',
      [tagId, projectId],
    );
    return rows.isEmpty ? null : rows.single['individual_id'] as String?;
  }

  /// **Each collar's most recent live, dated deployment naming a live
  /// animal — one row per `(tag_id, project_id)`**, as `tag_id, project_id,
  /// individual_id, attached_date`. Embedded by `TagRepository`'s read join
  /// and run by [latestAnimalForTag], so "whose collar is this" has one
  /// definition.
  ///
  /// **Ties on `attached_date` are broken by `created_at`, not by
  /// `deployment_id`.** Found wrong by Michael, 2026-09-14: unlinking a tag
  /// from one animal and linking it to another the same day gives both
  /// deployments the same `attached_date` (today), and `deployment_id` — a
  /// random UUID — carries no information about which happened later.
  /// `created_at` is the real instant the link was written. `deployment_id`
  /// is the last resort only so that exactly one row can ever win.
  ///
  /// **A correlated `NOT EXISTS`, not `MAX(attached_date)` with a bare
  /// column.** SQLite guarantees a bare column in an aggregate query takes
  /// its value from the row that produced the aggregate — and says nothing
  /// about which row that is when two tie. **No window function**:
  /// `schema.dart`'s v4 migration already avoids `ROW_NUMBER()` because
  /// older SQLite builds bundled on-device may not have it, and a runtime
  /// query cannot risk it either.
  ///
  /// **A deployment naming a tombstoned animal is treated as if it were not
  /// there — task 11.258.** Neither of this app's own writers ever leaves
  /// one: [IndividualRepository.remove]'s doc comment records that
  /// `IndividualMerge` re-points every deployment before tombstoning the
  /// absorbed animal, and `DeploymentLinking.deleteAnimal` withdraws every
  /// deployment before tombstoning the animal itself. So this is not a state
  /// this app's own screens can put a project in — but it is a state a sync
  /// can, from a device that raced the two: it links a collar to an animal
  /// offline, another device deletes that animal, and both land. "Whose
  /// collar is this" is a grouping question, not a history question — see
  /// [DeploymentRepository.animalForObservationIn]'s doc comment for the
  /// history question's different answer — so here the honest answer is the
  /// same one a collar nobody has linked gets: fall through to the next live
  /// deployment, or to none. **`Tables.tags` is not similarly excluded**,
  /// because `TagRepository.removeFromProject` deliberately leaves a
  /// removed tag's deployments alone (its own doc comment: "every bearing…
  /// still resolves"), and the only caller of this subquery already reads
  /// from a live-tags query, so a tombstoned tag never reaches it.
  static final String latestDeploymentsSubquery =
      'SELECT d.tag_id, d.project_id, d.individual_id, d.attached_date '
      'FROM ${Tables.deployments} d '
      'WHERE d.deleted_at IS NULL AND d.attached_date IS NOT NULL '
      'AND EXISTS (SELECT 1 FROM ${Tables.individuals} i0 '
      'WHERE i0.individual_id = d.individual_id AND i0.project_id = d.project_id '
      'AND i0.deleted_at IS NULL) '
      'AND NOT EXISTS (SELECT 1 FROM ${Tables.deployments} d2 '
      'WHERE d2.tag_id = d.tag_id AND d2.project_id = d.project_id '
      'AND d2.deleted_at IS NULL AND d2.attached_date IS NOT NULL '
      'AND d2.deployment_id != d.deployment_id '
      'AND EXISTS (SELECT 1 FROM ${Tables.individuals} i1 '
      'WHERE i1.individual_id = d2.individual_id AND i1.project_id = d2.project_id '
      'AND i1.deleted_at IS NULL) '
      'AND (d2.attached_date > d.attached_date '
      'OR (d2.attached_date = d.attached_date AND d2.created_at > d.created_at) '
      'OR (d2.attached_date = d.attached_date AND d2.created_at = d.created_at '
      'AND d2.deployment_id > d.deployment_id)))';
}

/// Michael's interlock, refused — task 11.243.
///
/// Carries the candidate and the row it collides with so a screen can name
/// both dates. **The message is written on the device**, here, because the
/// server may not send prose to a client screen (Security Model §4.13) and
/// because only this side can resolve an id into a collar's name.
class OverlappingDeployment implements Exception {
  const OverlappingDeployment({required this.candidate, required this.conflict});

  final Deployment candidate;
  final DeploymentConflict conflict;

  /// What went wrong, in a sentence that says which dates to fix — which is
  /// the whole of what Michael asked for: *"it tells the user to fix the
  /// removed/attached dates of the tags."*
  ///
  /// It names no tag name and no animal name because this class holds ids,
  /// not rows; a screen with both in hand should write its own sentence and
  /// use this as the fallback.
  ///
  /// **"Do not overlap", with no allowance named** (task 11.263, design §6a).
  /// Until then the sentence ended *"by more than a day"*; the day is gone,
  /// and a same-day handover is recorded with a time instead — which is why
  /// the sentence mentions one.
  ///
  /// **Names an action both editors can now do, on any day** (task 11.265,
  /// design §6b). Until then, a past-day pair reached this exact sentence
  /// with no control on a past day able to set a time at all — advice the
  /// screen could not follow. *Set removed date* and *Edit attached date*
  /// now offer a time on a past day whenever the picked day already
  /// overlaps, so "needs a time on both" names something the person holding
  /// this screen can actually go and do.
  String get message => messageFor(conflict.subject);

  /// [message]'s sentence, keyed only on [subject] — pulled out so a caller
  /// with a [DeploymentConflictSubject] but no [Deployment] to wrap can reuse
  /// the exact wording rather than writing a second copy of it.
  ///
  /// **Task 11.267's held-row card is that caller.** A row a *push* refused
  /// for overlapping is described from a bare stored row, not from a
  /// `Deployment` this device just tried to link — there is no
  /// `OverlappingDeployment` to construct, only the [DeploymentConflict] its
  /// own local re-check of `DeploymentInterlock.conflictFor` produces.
  static String messageFor(DeploymentConflictSubject subject) =>
      switch (subject) {
        DeploymentConflictSubject.animal =>
          'This animal would be wearing two tags at once. Fix the attached '
              'and removed dates so they do not overlap — a same-day swap '
              'needs a time on both.',
        DeploymentConflictSubject.tag =>
          'This tag would be on two animals at once. Fix the attached and '
              'removed dates so they do not overlap — a same-day swap needs a '
              'time on both.',
      };

  @override
  String toString() => 'OverlappingDeployment: $message ($conflict)';
}
