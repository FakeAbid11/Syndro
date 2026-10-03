import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:syndro/core/database/database_helper.dart';

/// Points the sqflite FFI factory at a throwaway databases directory and
/// returns it, so the caller can delete it in `tearDownAll`.
///
/// Without this, every test file opens the same
/// `.dart_tool/sqflite_common_ffi/databases/syndro.db`. `flutter test` runs
/// test *files* in parallel processes, so those files contend for one SQLite
/// database: writes fail with `database is locked (code 5)` — which surfaces
/// inside the app as `Error sending files: SqfliteFfiException(...)` and turns
/// a healthy transfer path into a red test — and one file's `clearHistory()`
/// erases another file's rows. Measured on this repo: 17 acceptance failures
/// with a shared database, 6 with each file on its own.
///
/// Call from `setUpAll`, not `setUp`: [DatabaseHelper] is a process singleton
/// that caches its open database, so re-pointing the path mid-file would not
/// move an already-open handle.
Future<Directory> useIsolatedSqliteDatabases() async {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  final dir = await Directory.systemTemp.createTemp('syndro-test-db-');
  databaseFactory = databaseFactoryFfi;
  await databaseFactory.setDatabasesPath(dir.path);
  addTearDown(() => disposeIsolatedSqliteDatabases(dir));
  return dir;
}

/// Closes the cached singleton before removing [dir].
///
/// The order matters: deleting the file under an open handle leaves
/// [DatabaseHelper] pointing at a database that no longer exists for anything
/// that runs later in the same process.
Future<void> disposeIsolatedSqliteDatabases(Directory dir) async {
  await DatabaseHelper.instance.close();
  if (await dir.exists()) {
    await dir.delete(recursive: true);
  }
}
