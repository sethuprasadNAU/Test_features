import 'dart:async';

import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../data/db/app_database.dart';

part 'database_provider.g.dart';

@Riverpod(keepAlive: true)
Future<AppDatabase> appDatabase(Ref ref) async {
  final db = await AppDatabase.open();
  ref.onDispose(() {
    unawaited(db.close());
  });
  return db;
}
