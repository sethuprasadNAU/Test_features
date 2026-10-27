import 'package:tritrack_sync/tritrack_sync.dart';

import '../../core/text/role_labels.dart';
import '../models/individual.dart';
import 'base_repository.dart';
import 'mutation_authorization.dart';

/// The animals a project holds — task 11.240.
///
/// An ordinary project-scoped repository under the role gradient
/// [BaseRepository.insertRow] applies everywhere: a viewer writes nothing, a
/// contributor may name an animal (the tech who identifies a chick in the
/// field must be able to record it — the same argument `TagRepository` makes
/// for creating a tag), and **editing one carries no owner-only rung**,
/// because editing an individual changes what no bearing means. Bearings
/// attach to the transmitter; the animal is derived through it.
///
/// **Deleting one does, since task 11.255** — see [remove] and
/// [assertMayDelete]. It is the one write on this table an owner alone may
/// make; every other write stays contributor-level.
///
/// **Colour's one home.** [nextColorHex] moved here from `TagRepository`
/// (and its round-robin now counts animals, not collars, because two collars
/// on one bird are one colour). A tag's colour is read *through* its
/// individual — see `TagRepository` — and never stored on the tag.
///
/// **What is deliberately not here: a list of a tag's individuals, or an
/// individual's tags.** The link is `Tags.individual_id`; "Marie's collars"
/// is `TagRepository.findByIndividual` (task 11.241), a query over `Tags` by
/// that column, and "Marie's track" is a query over those collars' bearings.
/// Storing either the other way round is the denormalisation the design
/// refuses. Saying two animals are one is `IndividualMerge`.
class IndividualRepository extends BaseRepository {
  IndividualRepository(super.db)
    : super(
        table: Tables.individuals,
        pk: const ['individual_id', 'project_id'],
        rule: MutationRule.anyUser,
      );

  /// Creates an animal inside [Individual.projectId]. The role gradient
  /// resolves against the project read off the row.
  Future<void> insert(Individual individual) =>
      insertRow(individual.toColumns());

  Future<Individual?> findById(
    String id, {
    required String projectId,
    bool includeDeleted = false,
  }) async {
    final row = await findRowByKey({
      'individual_id': id,
      'project_id': projectId,
    }, includeDeleted: includeDeleted);
    return row == null ? null : Individual.fromRow(row);
  }

  /// Every animal in one project, by name.
  Future<List<Individual>> findByProject(
    String projectId, {
    bool includeDeleted = false,
  }) async {
    final rows = await findRows(
      where: 'project_id = ?',
      whereArgs: [projectId],
      includeDeleted: includeDeleted,
      orderBy: 'name, individual_id',
    );
    return rows.map(Individual.fromRow).toList();
  }

  /// Edits an animal — name, colour, status, anything. Under
  /// [MutationRule.anyUser] with the gradient, so a contributor may correct
  /// a name; a viewer is refused.
  ///
  /// Recolouring here recolours every collar the animal has worn, on every
  /// screen, immediately — that is the design, not a side effect: colour is
  /// the animal's and the tags read it through.
  Future<int> update(
    Individual individual, {
    required MutationActor actor,
    String? deviceId,
    DateTime? now,
  }) => updateByKey(
    {
      'individual_id': individual.individualId,
      'project_id': individual.projectId,
    },
    individual.toColumns(),
    actor: actor,
    deviceId: deviceId,
    now: now,
  );

  /// Tombstones an animal. The foreign key holds and the row is never
  /// hard-deleted, so a deployment naming it does not break — but nothing
  /// reads its name or colour through a tombstoned row any more (task
  /// 11.258 closed that: see [DeploymentRepository.latestDeploymentsSubquery]).
  ///
  /// **Task 11.241's answer to what removing an animal does to its collars:
  /// nothing, because the only caller re-points them first.** `IndividualMerge`
  /// moves every collar to the kept animal and then calls this on the
  /// absorbed one, so no collar is ever left naming a tombstoned animal by
  /// this app. **Task 11.244 gave the app a second caller** — a bare
  /// "Delete animal" on `AnimalDetailScreen`, `DeploymentLinking.deleteAnimal`
  /// — which withdraws every collar first rather than re-pointing it, so a
  /// collar this leaves behind goes back to being on nobody, the ordinary
  /// state of a transmitter on a shelf.
  ///
  /// **A collar that *does* arrive naming a tombstoned animal — a sync from
  /// a device that raced one of the two paths above — has no screen of its
  /// own (task 11.258 measured this: no "Collars with no animal" list was
  /// ever built).** It instead reads exactly like a collar nobody has ever
  /// linked: `latestDeploymentsSubquery` skips the tombstoned-animal
  /// deployment and falls through to the next live one, or to none, so the
  /// collar shows no name and the neutral swatch until somebody links it
  /// afresh. **The bearings already taken on it are not affected** —
  /// [DeploymentRepository.animalForObservationIn] still resolves them to
  /// the animal that wore the collar at the time, tombstoned or not, the
  /// same as a bearing on a tag since removed from the project.
  ///
  /// **Owner-only since task 11.255** — [assertMayDelete], asked here so
  /// every caller gets it whether or not it also asked first. Every other
  /// write to this table — naming, editing, linking, unlinking — stays
  /// contributor-level; only the tombstone moved.
  Future<int> remove(
    String id, {
    required String projectId,
    required MutationActor actor,
    String? deviceId,
    DateTime? now,
  }) async {
    await assertMayDelete(projectId, actor);
    return softDeleteByKey(
      {'individual_id': id, 'project_id': projectId},
      actor: actor,
      deviceId: deviceId,
      now: now,
    );
  }

  /// Throws [UnauthorizedMutation] unless [actor] may delete an animal in
  /// [projectId] — task 11.255, asked before a write and exposed so a screen
  /// can ask it before offering the control.
  ///
  /// **Deleting is the one rung on this table; editing is not.** Merging two
  /// animals reaches the same tombstone through `IndividualMerge.merge`
  /// (task 11.254's finding, `PERMISSIONS_MATRIX.md` §8 entry 13) and has
  /// carried this same "owns this project" check since task 11.243 —
  /// `TagRepository.assertMayEdit`, restated here rather than shared, because
  /// the reason is about `Individuals`, not about `Tags`.
  Future<void> assertMayDelete(String projectId, MutationActor actor) async {
    if (actor.isReplication) return;
    final standing = await projectStandingFor(projectId, actor.userId);
    switch (standing) {
      case UnknownStanding():
        return;
      case NotAMemberStanding():
        throw UnauthorizedMutation.notAMember(
          table: table,
          rowId: projectId,
          rule: rule,
          actorUserId: actor.userId,
        );
      case MemberStanding(:final role):
        if (role == ProjectRole.owner) return;
        throw UnauthorizedMutation(
          table: table,
          rowId: projectId,
          rule: rule,
          actorUserId: actor.userId,
          permitted:
              'an owner of this project (you are ${role.withArticle})',
        );
    }
  }

  /// Count of animals in [projectId], tombstones included — the round-robin
  /// position the next auto-assigned colour continues from.
  Future<int> individualCount({required String projectId}) async {
    final result = await db.rawQuery(
      'SELECT COUNT(*) AS c FROM ${Tables.individuals} WHERE project_id = ?',
      [projectId],
    );
    return result.first['c'] as int;
  }

  /// The next auto-assigned palette colour for an animal created new inside
  /// [projectId] — round-robins off [individualCount] so consecutive
  /// creations get distinct colours.
  ///
  /// **This is the `nextColorHex` that used to live on `TagRepository`**
  /// (task 11.240). It counts animals rather than collars because colour is
  /// now the animal's: a bird on her second collar is still one colour, and
  /// counting her twice would make the within-project collisions the map
  /// legend cares about more likely for no reason.
  Future<String> nextColorHex({required String projectId}) async =>
      TagColorPalette.nextColor(await individualCount(projectId: projectId));
}
