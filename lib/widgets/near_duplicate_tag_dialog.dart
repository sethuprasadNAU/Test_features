import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';


import '../core/errors/guarded_write.dart';

import '../data/repositories/repository_providers.dart';
import '../data/models/tag.dart';
import '../data/models/tag_fields.dart';
import '../data/tags/near_duplicate_tags.dart';

/// What the person decided about a tag they were about to create
/// ([checkNewTagAgainstExisting]).
sealed class NewTagDecision {
  const NewTagDecision();
}

/// Create the new tag: nothing matched, or the person chose *Create anyway*.
final class CreateNewTag extends NewTagDecision {
  const CreateNewTag();
}

/// Create nothing and use [tag], the project's tag with the same Tag ID —
/// the default since task 11.324. What "use" means is the caller's: select
/// it, link it, or save a shared bearing on it.
final class UseExistingTag extends NewTagDecision {
  const UseExistingTag(this.tag);
  final Tag tag;
}

/// Create nothing: the person went back, or the check could not run.
final class GoBackFromNewTag extends NewTagDecision {
  const GoBackFromNewTag();
}

/// The near-duplicate warning shown before a tag is created (task 11.11).
///
/// **It warns and then gets out of the way.** Every place a tag can be created
/// calls this, and none of them can be made to refuse. Two collars can
/// legitimately share a nominal frequency if they are never in range together,
/// and a refusal would block honest field data to prevent untidiness — the
/// same trade task 11.11 declined when it rejected owner-only tag creation.
///
/// **A Tag ID this project already has gets a different default** (task
/// 11.324, Michael, reviewing the guide): *Use the existing tag* is the filled
/// button, and a second tag with the same ID is the deliberate *Create
/// anyway*. Still never a refusal — two phones offline can create the same ID,
/// and the planned merge tool (Phase 12) resolves that. A match only in the
/// Tag Library, or only on frequency, keeps the original warning.
Future<NewTagDecision> checkNewTagAgainstExisting(
  BuildContext context,
  WidgetRef ref, {
  required double frequencyMhz,
  required String tagName,
  required String? projectId,
  String? excludeTagId,
  Set<String> excludeLineageIds = const {},
}) async {
  // Task 11.137: this reads the tag database to decide whether to warn, and it
  // sits between the person tapping Create and anything being written. A read
  // that threw took the whole create with it and showed nothing at all — the
  // tap looked like it had not registered.
  //
  // **A failure here refuses the create rather than waving it through**: the
  // warning is the only thing standing between a slip of the finger and a
  // second collar on one frequency, and skipping the check silently would be a
  // worse answer than saying so. `refused: null` — reading the tag list needs
  // no write right.
  var matches = const <NearDuplicateTag>[];
  var projectTags = const <Tag>[];
  final checked = await runGuardedWrite(
    context,
    write: () async {
      // **What "already have" means since task 11.219** (§2.6): this device's
      // tag library, plus the destination project's own tags. Those are two
      // different lists now — a project's tag is a *copy* of a library entry
      // with its own id — and the warning has to be able to say which of the
      // two it found, because "already on this project" and "in your tag
      // library" have different consequences for the person reading it.
      final library = await ref.read(tagLibraryRepositoryProvider.future);
      final existing = <TagFields>[...await library.findAll()];

      var projectTagIds = const <String>{};
      if (projectId != null) {
        final tagRepo = await ref.read(tagRepositoryProvider.future);
        projectTags = await tagRepo.findByProject(projectId);
        existing.addAll(projectTags);
        projectTagIds = {for (final tag in projectTags) tag.tagId};
      }

      matches = NearDuplicateTags.find(
        frequencyMhz: frequencyMhz,
        tagName: tagName,
        existing: existing,
        projectTagIds: projectTagIds,
        excludeTagId: excludeTagId,
        excludeLineageIds: excludeLineageIds,
      );
    },
    refused: null,
    failed: 'Could not check this tag against the ones you already have, so it '
        'was not created. Try again, and report it if this keeps happening.',
  );
  if (!checked) return const GoBackFromNewTag();
  if (matches.isEmpty) return const CreateNewTag();
  if (!context.mounted) return const GoBackFromNewTag();

  // The project's own tag with the same Tag ID, if there is one. `matches` is
  // sorted most concerning first, so a tag that also shares the frequency
  // wins over one that only shares the ID.
  final sameIdMatch = matches
      .where((m) => m.sharesProject && m.matched.contains(TagMatchKind.name))
      .firstOrNull;
  final sameId = sameIdMatch == null
      ? null
      : projectTags
            .where((t) => t.tagId == sameIdMatch.existing.tagId)
            .firstOrNull;

  final decision = await showDialog<NewTagDecision>(
    context: context,
    builder: (context) => _NearDuplicateTagDialog(
      matches: matches,
      frequencyMhz: frequencyMhz,
      tagName: tagName,
      sameId: sameId,
    ),
  );
  return decision ?? const GoBackFromNewTag();
}

class _NearDuplicateTagDialog extends StatelessWidget {
  const _NearDuplicateTagDialog({
    required this.matches,
    required this.frequencyMhz,
    required this.tagName,
    required this.sameId,
  });

  final List<NearDuplicateTag> matches;
  final double frequencyMhz;
  final String tagName;

  /// The project's tag with the Tag ID being typed, or null. When set, the
  /// dialog's default is to use it (task 11.324).
  final Tag? sameId;

  /// Whether any match would put two tags on one frequency in one project —
  /// the case that actually breaks something, as opposed to merely looking
  /// untidy.
  bool get _collidesInProject => matches.any(
    (m) => m.sharesProject && m.matched.contains(TagMatchKind.frequency),
  );

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final existing = sameId;
    return AlertDialog(
      key: const ValueKey('near_duplicate_tag_dialog'),
      title: Text(
        existing != null
            ? 'Tag ID ${existing.tagName} is already on this project'
            : matches.length == 1
            ? 'A similar tag already exists'
            : '${matches.length} similar tags already exist',
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              '${frequencyMhz.toStringAsFixed(3)} MHz · $tagName '
              'looks like something already in the tag database:',
            ),
            const SizedBox(height: 12),
            for (final match in matches)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('• '),
                    Expanded(
                      child: Text(
                        match.summary,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                    ),
                  ],
                ),
              ),
            const SizedBox(height: 4),
            Text(
              existing != null
                  ? 'Use the existing tag, unless this really is a second, '
                        'different tag with the same Tag ID.'
                  : _collidesInProject
                  // Said plainly, because this is the consequence the person
                  // is actually being asked to weigh: a bearing carries a
                  // frequency and nothing else, so two collars on one
                  // frequency in one project cannot be told apart later.
                  ? 'With two tags on one frequency, the app cannot tell '
                        'which one a bearing came from.\n\n'
                        'Create it anyway if they really are two different '
                        'tags — for example, never in range at the same time.'
                  : 'Create it anyway if this really is a different tag.',
              style: TextStyle(color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () =>
              Navigator.of(context).pop(const GoBackFromNewTag()),
          child: const Text('Go back'),
        ),
        if (existing != null) ...[
          TextButton(
            key: const ValueKey('near_duplicate_tag_create_anyway'),
            onPressed: () => Navigator.of(context).pop(const CreateNewTag()),
            child: const Text('Create anyway'),
          ),
          FilledButton(
            key: const ValueKey('near_duplicate_tag_use_existing'),
            onPressed: () =>
                Navigator.of(context).pop(UseExistingTag(existing)),
            child: const Text('Use the existing tag'),
          ),
        ] else
          FilledButton(
            key: const ValueKey('near_duplicate_tag_create_anyway'),
            onPressed: () => Navigator.of(context).pop(const CreateNewTag()),
            child: const Text('Create anyway'),
          ),
      ],
    );
  }
}
