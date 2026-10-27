import 'package:sqflite/sqflite.dart';

import '../db/data_arrival.dart';
import 'deployment_repository.dart';
import 'individual_repository.dart';
import 'mutation_authorization.dart';
import 'tag_repository.dart';

/// **"These collars are the same animal"** — task 11.241, the deliberate act
/// task 11.240 refused to do by guessing.
///
/// The v16 backfill made one individual per collar, because it could not
/// know that "Marie" on 160.321 MHz and "Marie" on 160.523 MHz were one bird
/// — two collars called Marie may be two birds, and a migration that matched
/// names would have invented an animal. So a person says so, here, and this
/// is what saying so does:
///
/// 1. **Every deployment of the absorbed animal is re-pointed at the kept
///    one** — task 11.243 moved this from the collar to the dated link, and
///    design §7 keeps the feature saying exactly that. It re-points
///    deployments and moves no bearings. A deployment of a collar since
///    removed from the project moves too: the animal wore it, and a merge
///    that skipped those would leave a deployment naming an animal that no
///    longer exists.
/// 2. **The absorbed animal's own row is tombstoned.** Its name, colour,
///    status, species, sex and notes go with it; that is the one thing a
///    merge cannot undo, and the screen says so before it happens.
/// 3. **Nothing about a collar changes** — not its name, frequency, dates,
///    status or version history. They were never wrong.
/// 4. **No bearing, session, estimate, no-signal entry or truth point is
///    touched.** They are keyed by collar, not by animal; "Marie's track" is
///    a query over her collars, so after the merge it simply returns both.
///    `individual_merge_test.dart` asserts observation counts are identical
///    before and after, per collar and in total, and was watched failing
///    first — that assertion is the reason a person can trust the button.
///
/// **It is a merge of animals, not of collars.** The kept individual keeps
/// its identity, its id and every field; nothing of the absorbed one is
/// copied onto it. A person who wants the absorbed animal's notes keeps them
/// by hand, before merging, and the confirmation says so.
///
/// **Owner-only**, and since task 11.243 that is a decision rather than an
/// inheritance. It used to be owner-only *because* it wrote
/// `Tags.individual_id`, a change to an existing tag; it writes deployments
/// now, which a contributor may write. The rung is kept anyway: **merging
/// tombstones an animal's row and cannot be undone**, which is a different
/// and larger act than recording a collaring. `TagRepository.assertMayEdit`
/// is still what asks the question, because it is the one that means "owner
/// of this project".
///
/// **The interlock can refuse a merge, and that is deliberate** (§6).
/// Declaring two animals one can put two open-ended deployments on a single
/// animal, which is the state the rule exists to forbid. The whole merge then
/// rolls back with [OverlappingDeployment] rather than half-applying — and it
/// has to be this side, because the server checks each arriving row against
/// stored state and would otherwise refuse some of a merge and accept the
/// rest.
///
/// **One transaction.** A merge that re-pointed one collar and then failed
/// would leave the animal half-merged with no error a person could act on.
class IndividualMerge {
  IndividualMerge(this.database);

  final Database database;

  /// Folds [absorbId] into [keepId] inside [projectId]. Returns how many
  /// collars moved.
  ///
  /// Throws [ArgumentError] when the two are the same animal already, or
  /// when either is not a live individual of this project — both are screen
  /// mistakes, not states the database can be in after a merge.
  Future<int> merge({
    required String projectId,
    required String keepId,
    required String absorbId,
    required MutationActor actor,
    String? deviceId,
    DateTime? now,
  }) async {
    if (keepId == absorbId) {
      throw ArgumentError('an animal cannot be merged into itself');
    }
    final at = now ?? DateTime.now();
    final moved = await database.transaction((txn) async {
      final individuals = IndividualRepository(txn);
      final tags = TagRepository(txn);
      final keep = await individuals.findById(keepId, projectId: projectId);
      final absorb = await individuals.findById(absorbId, projectId: projectId);
      if (keep == null) {
        throw ArgumentError('no live individual $keepId in $projectId');
      }
      if (absorb == null) {
        throw ArgumentError('no live individual $absorbId in $projectId');
      }
      // Refuse before the first write, not on it: a merge a contributor
      // cannot finish must not start.
      await tags.assertMayEdit(projectId, actor);

      final deployments = DeploymentRepository(txn);
      final links = await deployments.findByIndividual(
        absorbId,
        projectId: projectId,
      );
      for (final link in links) {
        // Through `update` rather than a bare column write, so the interlock
        // is asked. See the note above on why a refusal rolls the merge back
        // instead of leaving it half-applied.
        await deployments.update(
          link.copyWith(individualId: keepId),
          actor: actor,
          deviceId: deviceId,
          now: at,
        );
      }
      await individuals.remove(
        absorbId,
        projectId: projectId,
        actor: actor,
        deviceId: deviceId,
        now: at,
      );
      return links.length;
    });
    // The map keys colour and legend by collar and animal; the Log and the
    // Record wheel read the same rows. One announcement for the whole merge,
    // after it is committed (task 11.45's rule).
    DataArrival.announce();
    return moved;
  }
}
