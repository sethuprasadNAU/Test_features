import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tritrack/features/more/screens/tag_database_screen.dart';

/// Resolves what the Tag Library screen watches, and keeps it alive, so the
/// screen can be pumped in a widget test's fake-async zone without a fresh
/// database read it could never finish.
///
/// **Task 11.321 added the second of the two**: the library is grouped by
/// the projects each collar is on, read by an auto-disposing provider, so a
/// bare `read` would let it go before the screen arrived to watch it.
Future<void> primeTagLibrary(ProviderContainer container) async {
  container.listen(tagLibraryProvider, (_, _) {});
  container.listen(tagLibraryHoldersProvider, (_, _) {});
  await container.read(tagLibraryProvider.future);
  await container.read(tagLibraryHoldersProvider.future);
}

/// Opens the Tag Library heading for [projectId] — every heading starts
/// closed since task 11.321, unless it is the only one. Pass null for "Not on
/// any project".
Future<void> openLibraryGroup(WidgetTester tester, String? projectId) async {
  await tester.tap(
    find.byKey(ValueKey('tag_library_group_header_${projectId ?? ''}')),
  );
  await tester.pumpAndSettle();
}
