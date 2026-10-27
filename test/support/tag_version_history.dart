import 'package:tritrack/data/models/tag_version.dart';
import 'package:tritrack/data/repositories/tag_version_repository.dart';

/// Every version of [tagId], oldest first — a tag's measurement history.
///
/// **This lives in `test/support/` rather than on [TagVersionRepository]
/// because nothing in the app reads a tag's history back.** Task 11.212 widened
/// `sync_auth_uncalled_methods_test.dart` over `lib/data/repositories/` and
/// found `TagVersionRepository.historyFor` had no caller in `lib/` at all — its
/// only callers were the three test files that now import this. A public method
/// kept alive solely by the tests that assert on it proves nothing about the
/// app, which is the shape that guard exists to refuse, so the method was
/// deleted and its query moved here.
///
/// **The ordering is the part worth keeping in one place.** Two versions can
/// legitimately share an `effective_from` after a merge, so "oldest first" has
/// to be a total order rather than an arbitrary one — see
/// [TagVersionRepository.currentFor], which orders the same pair of columns the
/// other way round for the same reason.
///
/// **Asked and answered: Michael decided on 2026-09-09 that a screen showing a
/// collar's frequency and pulse rates over the season is not wanted now**, so
/// the deletion stands and this helper is where the query lives. **This is a
/// decision against, not an oversight** — if that screen is ever built, the
/// method belongs back on the repository and this helper should call it rather
/// than a second copy of the query appearing beside it.
Future<List<TagVersion>> tagVersionHistory(
  TagVersionRepository versions,
  String tagId, {
  bool includeDeleted = false,
}) async {
  final rows = await versions.findRows(
    where: 'tag_id = ?',
    whereArgs: [tagId],
    orderBy: 'effective_from ASC, created_at ASC',
    includeDeleted: includeDeleted,
  );
  return rows.map(TagVersion.fromRow).toList();
}
