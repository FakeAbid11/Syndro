import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:syndro/core/services/file_service.dart';

/// P0-2 unit coverage for collision-free destination naming.
///
/// The invariant under test: a receive must never delete a file that is
/// already there. Everything runs inside a temp directory, so no user data can
/// be touched, and the originals' contents are asserted after every case.
void main() {
  late Directory dir;
  late FileService service;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('syndro-collision-test');
    service = FileService();
  });

  tearDown(() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  Future<File> seed(String name, [String content = 'original']) {
    final file = File(p.join(dir.path, name));
    return file.writeAsString(content, flush: true);
  }

  Future<String> resolve(String name) =>
      service.resolveUniqueFilePath(p.join(dir.path, name));

  group('resolveUniqueFilePath', () {
    test('returns the desired path untouched when nothing is there', () async {
      final resolved = await resolve('photo.jpg');
      expect(resolved, p.join(dir.path, 'photo.jpg'));
    });

    test('appends (1) when the destination exists', () async {
      await seed('photo.jpg');
      expect(p.basename(await resolve('photo.jpg')), 'photo (1).jpg');
    });

    test('steps to (2) when (1) is also taken', () async {
      await seed('photo.jpg');
      await seed('photo (1).jpg');
      expect(p.basename(await resolve('photo.jpg')), 'photo (2).jpg');
    });

    test('keeps looking past a gap in the sequence', () async {
      await seed('photo.jpg');
      await seed('photo (2).jpg');
      expect(p.basename(await resolve('photo.jpg')), 'photo (1).jpg');
    });

    test('preserves the final extension on multi-dot names', () async {
      await seed('archive.tar.gz');
      expect(p.basename(await resolve('archive.tar.gz')), 'archive.tar (1).gz',
          reason: 'only the last extension may move, never the whole suffix');
    });

    test('handles a name with no extension', () async {
      await seed('README');
      expect(p.basename(await resolve('README')), 'README (1)');
    });

    test('treats a leading-dot name as extension-less', () async {
      await seed('.gitignore');
      expect(p.basename(await resolve('.gitignore')), '.gitignore (1)');
    });

    test('handles names containing spaces and unicode', () async {
      await seed('Q3 Budget.pdf');
      expect(p.basename(await resolve('Q3 Budget.pdf')), 'Q3 Budget (1).pdf');
      await seed('café.jpg');
      expect(p.basename(await resolve('café.jpg')), 'café (1).jpg');
    });

    test('never deletes or modifies an existing file', () async {
      final original = await seed('photo.jpg', 'DO NOT LOSE ME');
      await resolve('photo.jpg');
      await resolve('photo.jpg');
      expect(await File(original.path).readAsString(), 'DO NOT LOSE ME');
      expect(await dir.list().length, 1,
          reason: 'resolving must not create anything');
    });

    test('stays inside the original directory', () async {
      await seed('photo.jpg');
      final resolved = await resolve('photo.jpg');
      expect(p.dirname(resolved), dir.path);
    });
  });

  group('moveFileIntoPlace', () {
    test('moves a new file to the desired path', () async {
      final temp = await seed('incoming.tmp', 'payload');

      final placed = await service.moveFileIntoPlace(
          temp.path, p.join(dir.path, 'final.bin'));

      expect(placed, p.join(dir.path, 'final.bin'));
      expect(await File(placed).readAsString(), 'payload');
      expect(await temp.exists(), isFalse,
          reason: 'the temp file must be gone');
    });

    test('does not overwrite an existing destination', () async {
      final keeper = await seed('final.bin', 'EXISTING USER DATA');
      final temp = await seed('incoming.tmp', 'payload');

      final placed = await service.moveFileIntoPlace(
          temp.path, p.join(dir.path, 'final.bin'));

      expect(p.basename(placed), 'final (1).bin');
      expect(await File(keeper.path).readAsString(), 'EXISTING USER DATA',
          reason: 'the pre-existing file must be untouched');
      expect(await File(placed).readAsString(), 'payload');
    });

    test('a second collision yields (2)', () async {
      await seed('final.bin', 'A');
      await seed('final (1).bin', 'B');

      final temp = await seed('incoming.tmp', 'C');
      final placed = await service.moveFileIntoPlace(
          temp.path, p.join(dir.path, 'final.bin'));

      expect(p.basename(placed), 'final (2).bin');
      expect(await File(p.join(dir.path, 'final.bin')).readAsString(), 'A');
      expect(await File(p.join(dir.path, 'final (1).bin')).readAsString(), 'B');
    });
  });
}
