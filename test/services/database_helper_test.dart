import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:syndro/core/database/database_helper.dart';
import 'package:syndro/core/models/device.dart';
import 'package:syndro/core/models/transfer.dart';

/// CRUD + migration coverage for [DatabaseHelper], running on the real
/// SQLite engine via `sqflite_common_ffi` (no emulator required).
void main() {
  // The singleton test from the original suite is preserved below; all other
  // tests use the FFI factory pointed at a fresh temp databases path.
  group('DatabaseHelper', () {
    test('should be a singleton', () {
      final instance1 = DatabaseHelper.instance;
      final instance2 = DatabaseHelper.instance;

      expect(identical(instance1, instance2), isTrue);
    });
  });

  group('DatabaseHelper CRUD (sqflite_common_ffi)', () {
    late Directory tempDir;

    setUpAll(() {
      sqfliteFfiInit();
    });

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('syndro_db_test_');
      databaseFactory = databaseFactoryFfi;
      await databaseFactory.setDatabasesPath(tempDir.path);
    });

    tearDown(() async {
      await DatabaseHelper.instance.close();
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    Transfer buildTransfer(String id,
        {TransferStatus status = TransferStatus.completed}) {
      return Transfer(
        id: id,
        senderId: 'sender-1',
        receiverId: 'receiver-1',
        items: const [
          TransferItem(name: 'a.txt', path: '/tmp/a.txt', size: 10),
          TransferItem(name: 'b.txt', path: '/tmp/b.txt', size: 20),
        ],
        status: status,
        progress: const TransferProgress(bytesTransferred: 30, totalBytes: 30),
        createdAt: DateTime.fromMillisecondsSinceEpoch(1700000000000),
      );
    }

    test('insert + typed history round-trip', () async {
      final db = DatabaseHelper.instance;
      await db.insertTransfer(
        buildTransfer('t1'),
        null,
        Device(
          id: 'receiver-1',
          name: 'Laptop',
          platform: DevicePlatform.windows,
          ipAddress: '192.168.1.5',
          port: 8765,
          lastSeen: DateTime.now(),
        ),
      );

      final entries = await db.getHistoryEntries();
      expect(entries, hasLength(1));
      expect(entries[0].id, 't1');
      expect(entries[0].status, 'completed');
      expect(entries[0].fileCount, 2);
      expect(entries[0].totalBytes, 30);
      expect(entries[0].receiverName, 'Laptop');
      expect(entries[0].displayName, 'Laptop');
      expect(entries[0].createdAt.millisecondsSinceEpoch, 1700000000000);
      expect(entries[0].completedAt, isNotNull);
    });

    test('updateTransferStatus persists status and completed_at', () async {
      final db = DatabaseHelper.instance;
      await db.insertTransfer(
        buildTransfer('t2', status: TransferStatus.transferring),
        null,
        null,
      );

      await db.updateTransferStatus(
        't2',
        TransferStatus.failed,
        errorMessage: 'socket closed',
      );

      final entries = await db.getHistoryEntries();
      expect(entries[0].status, 'failed');
      expect(entries[0].errorMessage, 'socket closed');
      expect(entries[0].completedAt, isNotNull,
          reason: 'failed transfers also get a completion timestamp');
    });

    test('deleteTransfer cascades to items', () async {
      final db = DatabaseHelper.instance;
      await db.insertTransfer(buildTransfer('t3'), null, null);
      expect(await db.getTransferById('t3'), isNotNull);

      await db.deleteTransfer('t3');

      expect(await db.getTransferById('t3'), isNull);
      expect(await db.getHistoryEntries(), isEmpty);
    });

    test('getStatistics aggregates counts and bytes', () async {
      final db = DatabaseHelper.instance;
      await db.insertTransfer(buildTransfer('s1'), null, null);
      await db.insertTransfer(
        buildTransfer('s2', status: TransferStatus.failed),
        null,
        null,
      );

      final stats = await db.getStatistics();
      expect(stats['totalTransfers'], 2);
      expect(stats['completedTransfers'], 1);
      expect(stats['failedTransfers'], 1);
      expect(stats['totalBytes'], 30);
    });

    test('clearHistory empties all tables', () async {
      final db = DatabaseHelper.instance;
      await db.insertTransfer(buildTransfer('c1'), null, null);
      await db.clearHistory();

      expect(await db.getHistoryEntries(), isEmpty);
      final info = await db.getDatabaseInfo();
      expect(info['transferCount'], 0);
      expect(info['itemCount'], 0);
    });

    test('opening a v1 database migrates to v2 without data loss', () async {
      // Simulate the v1 schema (no status index) at the path DatabaseHelper
      // will open, at version 1.
      final dbPath =
          '${await databaseFactory.getDatabasesPath()}/syndro.db';
      final old = await databaseFactory.openDatabase(
        dbPath,
        options: OpenDatabaseOptions(
          version: 1,
          onCreate: (db, version) async {
          await db.execute('''
            CREATE TABLE transfers (
              id TEXT PRIMARY KEY,
              sender_id TEXT NOT NULL,
              receiver_id TEXT NOT NULL,
              sender_name TEXT,
              receiver_name TEXT,
              status TEXT NOT NULL,
              total_bytes INTEGER NOT NULL,
              bytes_transferred INTEGER NOT NULL,
              file_count INTEGER NOT NULL,
              created_at INTEGER NOT NULL,
              completed_at INTEGER,
              error_message TEXT
            )
          ''');
          await db.execute('''
            CREATE TABLE transfer_items (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              transfer_id TEXT NOT NULL,
              file_name TEXT NOT NULL,
              file_size INTEGER NOT NULL,
              file_path TEXT,
              is_directory INTEGER NOT NULL DEFAULT 0,
              FOREIGN KEY (transfer_id) REFERENCES transfers(id) ON DELETE CASCADE
            )
          ''');
          await db.insert('transfers', {
            'id': 'legacy',
            'sender_id': 's',
            'receiver_id': 'r',
            'status': 'completed',
            'total_bytes': 5,
            'bytes_transferred': 5,
            'file_count': 1,
            'created_at': 12345,
          });
        },
        ),
      );
      await old.close();

      // Opening through the helper must run _onUpgrade (v1 → v2).
      final helper = DatabaseHelper.instance;
      final entries = await helper.getHistoryEntries();
      expect(entries, hasLength(1));
      expect(entries[0].id, 'legacy');

      // The migration's status index actually exists.
      final rawDb = await helper.database;
      final rows = await rawDb.rawQuery(
          "SELECT name FROM sqlite_master WHERE type='index' AND name = 'idx_transfers_status'");
      expect(rows, hasLength(1));
    });
  });
}
