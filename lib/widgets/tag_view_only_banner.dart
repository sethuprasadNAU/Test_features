import 'package:flutter/material.dart';

import '../data/models/tag_fields.dart';
import 'info_button.dart';

/// **The tag-edit refusal, as the banner of the read-only tag form** rather
/// than as a dialog that replaces it.
///
/// A refusal is not the same as a locked door (Michael, 2026-09-06). Before
/// that date a viewer's tap on a locked tag opened a refusal and stopped, so
/// **the one person who most needed to read a tag was the only one who could
/// not** — pulse rate, pattern, notes, colour and date put on were all
/// unreachable. That was invisible because the refusal was correct: it
/// explained itself, it was actionable, and it was covered by a test.
/// Nothing was wrong with the message; what was wrong was that it was the
/// *end* of the road.
///
/// **Same words, same key, new address (task 11.219).** It used to live in
/// `tag_database_screen.dart`, because that was where every tag was edited.
/// Since copy-on-add that screen shows this device's own tag *library*,
/// which no role governs — a person's list of their own equipment is theirs.
/// The owner-only rule still binds **a project's copy** of a tag, so this
/// moved to Project Setup, where that copy is edited.
///
/// Keeping `tag_edit_not_permitted` is not cosmetic:
/// `test/features/refusal_messages_rendered_test.dart` renders all of the
/// app's `UnauthorizedMutation` messages through the real screen precisely
/// because none of them had ever executed, and moving a refusal into a
/// different widget is exactly how one of them would quietly stop being
/// reachable again.
class TagViewOnlyBanner extends StatelessWidget {
  const TagViewOnlyBanner({super.key, required this.tag});

  final TagFields tag;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      key: const ValueKey('tag_edit_not_permitted'),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.lock_outline, size: 18, color: scheme.onSurfaceVariant),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Only an owner can change this tag',
                  style: Theme.of(context).textTheme.titleSmall,
                ),
              ),
              // Task 11.320: the reason, which nobody acts on, behind the
              // shared (i); the banner keeps what the person can still do.
              const InfoButton(
                key: ValueKey('tag_edit_not_permitted_why'),
                title: 'Why only an owner',
                detail:
                    'Renaming a project\'s tag, moving its frequency or '
                    'retiring it changes what every observation already '
                    'recorded against it means, so only a project owner can.',
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            '${tag.frequencyMhz.toStringAsFixed(3)} MHz · ${tag.tagName} '
            'belongs to a project you are not an owner of. You can read it '
            'below, or keep and change your own copy in your tag library — it '
            'reaches no project.',
          ),
        ],
      ),
    );
  }
}
