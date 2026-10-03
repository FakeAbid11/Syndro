import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:syndro/core/services/file_service.dart';

void main() {
  group('FileService', () {
    late FileService fileService;

    setUp(() {
      fileService = FileService();
    });

    group('sanitizeFilename', () {
      test('should remove dangerous characters', () {
        final result = fileService.sanitizeFilename('file<>:"/\\|?*name.txt');
        expect(result, equals('file_________name.txt'));
      });

      test('should preserve valid file names', () {
        final result = fileService.sanitizeFilename('valid_file-name.txt');
        expect(result, equals('valid_file-name.txt'));
      });

      test('should handle empty filename', () {
        expect(
          () => fileService.sanitizeFilename(''),
          throwsA(isA<FileServiceException>()),
        );
      });

      test('should handle path separators', () {
        final result = fileService.sanitizeFilename('folder/file.txt');
        expect(result.contains('/'), isFalse);
      });

      test('should handle parent directory references', () {
        final result = fileService.sanitizeFilename('../secret.txt');
        expect(result.contains('..'), isFalse);
      });
    });

    group('isPathWithinDirectory', () {
      test('should return true for path within directory', () {
        final result = fileService.isPathWithinDirectory(
          '/home/user/downloads/file.txt',
          '/home/user/downloads',
        );
        expect(result, isTrue);
      });

      test('should return false for path outside directory', () {
        final result = fileService.isPathWithinDirectory(
          '/home/user/other/file.txt',
          '/home/user/downloads',
        );
        expect(result, isFalse);
      });

      // The next three are the regression: a destination is validated before it
      // is created, so the file cannot be resolved. The old implementation fell
      // back to the raw string for the file while still resolving the directory,
      // mixing two forms of the same path. Whenever they differed the check
      // failed and a legitimate upload was rejected as path traversal — on a
      // Windows 8.3 short name, on macOS `/var` -> `/private/var`, or through
      // any junction. That broke every two-node acceptance test on the Windows CI
      // runner, where TEMP resolves to `C:\Users\runneradmin\...` from a path
      // constructed as `C:\Users\RUNNER~1\...`.
      test(
          'accepts a file that does not exist yet under an existing directory',
          () {
        final dir = Directory.systemTemp.createTempSync('syndro-path-ok');
        addTearDown(() => dir.deleteSync(recursive: true));

        expect(
          fileService.isPathWithinDirectory(
            p.join(dir.path, 'not-created-yet.txt'),
            dir.path,
          ),
          isTrue,
        );
      });

      test('accepts a nested path whose parents do not exist yet', () {
        final dir = Directory.systemTemp.createTempSync('syndro-path-nested');
        addTearDown(() => dir.deleteSync(recursive: true));

        expect(
          fileService.isPathWithinDirectory(
            p.join(dir.path, 'a', 'b', 'c.txt'),
            dir.path,
          ),
          isTrue,
        );
      });

      test('still rejects a traversal out of the allowed directory', () {
        final dir = Directory.systemTemp.createTempSync('syndro-path-escape');
        addTearDown(() => dir.deleteSync(recursive: true));

        // The relaxation must not weaken the actual defence: a `..` that climbs
        // out has to be refused.
        expect(
          fileService.isPathWithinDirectory(
            p.join(dir.path, '..', 'escaped.txt'),
            dir.path,
          ),
          isFalse,
        );
        expect(
          fileService.isPathWithinDirectory(
            p.normalize(p.join(dir.path, '..', '..', 'escaped.txt')),
            dir.path,
          ),
          isFalse,
        );
      });

      test('compares case-insensitively on Windows and macOS', () {
        if (!Platform.isWindows && !Platform.isMacOS) return;

        final dir = Directory.systemTemp.createTempSync('syndro-path-case');
        addTearDown(() => dir.deleteSync(recursive: true));

        expect(
          fileService.isPathWithinDirectory(
            p.join(dir.path.toUpperCase(), 'file.txt'),
            dir.path.toLowerCase(),
          ),
          isTrue,
        );
      });

      // The real reproduction, where the filesystem exposes two names for one
      // directory: a symlinked/junctioned alias. This is the macOS
      // `/var/folders` -> `/private/var/folders` case exactly, and the same shape
      // as a Windows junction.
      //
      // Creating a symlink on Windows needs Developer Mode or elevation, so skip
      // rather than fail where it is not permitted — on those runners the
      // 8.3 short-name variant is exercised instead, by the CI suite itself.
      test('accepts a file under a directory reached through an alias',
          () async {
        final real =
            Directory.systemTemp.createTempSync('syndro-path-real');
        addTearDown(() async {
          if (await real.exists()) await real.delete(recursive: true);
        });
        await Directory(p.join(real.path, 'sub')).create(recursive: true);

        final aliasPath = p.join(real.parent.path, 'syndro-path-alias');
        final alias = Link(aliasPath);
        if (await alias.exists()) await alias.delete();

        try {
          await alias.create(real.path, recursive: true);
        } catch (e) {
          markTestSkipped('cannot create a symlink here: $e');
          return;
        }
        addTearDown(() async {
          if (await alias.exists()) await alias.delete();
        });

        // Addressed via the alias, validated against the real path.
        expect(
          fileService.isPathWithinDirectory(
            p.join(aliasPath, 'sub', 'new-file.txt'),
            real.path,
          ),
          isTrue,
          reason: 'an alias and its target name the same directory',
        );
      });
    });
  });
}
