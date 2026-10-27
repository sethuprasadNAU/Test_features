import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:tritrack/data/repositories/repository_providers.dart';

import '../data/fixtures.dart';

/// **Puts the sample collar on an animal, so the Record screen offers it** —
/// task 11.249.
///
/// Since that task the wheel lists a collar only while a deployment says it
/// is on an animal today (`tagIdsAudibleOn`). Every test that pumps the
/// Record screen used to seed `sampleTag()` alone and got a wheel; now that
/// seeds equipment in a box and gets the empty state. This is the one line
/// each of them adds after inserting the tag.
///
/// The animal is named **after the collar** by default, so the wheel's line
/// reads `150.325 MHz · Coco` — the same as before, minus the pulse rate —
/// rather than `Coco (Marie)`. A test about the bracketed name passes
/// [animalName].
///
/// Call it inside `tester.runAsync`, like every other database write in a
/// widget test.
Future<void> putSampleTagOnAnAnimal(
  ProviderContainer container, {
  String tagId = 'tag-1',
  String projectId = 'project-1',
  String animalId = 'individual-1',
  String animalName = 'Coco',
  String deploymentId = 'deployment-1',
  DateTime? attachedDate,
  DateTime? removedDate,
}) async {
  final individuals = await container.read(individualRepositoryProvider.future);
  final deployments = await container.read(deploymentRepositoryProvider.future);
  await individuals.insert(
    sampleIndividual(id: animalId, projectId: projectId, name: animalName),
  );
  await deployments.link(
    sampleDeployment(
      id: deploymentId,
      projectId: projectId,
      tagId: tagId,
      individualId: animalId,
      attachedDate: attachedDate,
      removedDate: removedDate,
    ),
  );
}
