import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:syndro/core/services/web_share/utils/streaming_multipart_parser.dart';

/// Collected output for one parsed file part.
class _Collected {
  final String filename;
  final List<int> bytes = [];
  bool skipped = false;
  bool ended = false;
  _Collected(this.filename);
}

/// Tests for [StreamingMultipartParser]: correctness of the boundary scan
/// across sliding windows, binary-safe part streaming, non-file part
/// skipping, and the per-part size cap.
void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('syndro_multipart_');
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  /// Builds a multipart body exactly the way browsers emit it.
  List<int> buildBody({
    required String boundary,
    required Map<String, List<int>> files,
    Map<String, String> fields = const {},
    String? preamble,
    bool closingDashes = true,
    bool closingCrlf = true,
  }) {
    final sb = BytesBuilder();
    if (preamble != null) {
      sb.add(utf8.encode('$preamble\r\n'));
    }
    files.forEach((filename, data) {
      sb.add(utf8.encode('--$boundary\r\n'));
      sb.add(utf8.encode(
          'Content-Disposition: form-data; name="files"; filename="$filename"\r\n'));
      sb.add(utf8.encode('Content-Type: application/octet-stream\r\n\r\n'));
      sb.add(data);
      sb.add(utf8.encode('\r\n'));
    });
    fields.forEach((name, value) {
      sb.add(utf8.encode('--$boundary\r\n'));
      sb.add(utf8
          .encode('Content-Disposition: form-data; name="$name"\r\n\r\n'));
      sb.add(utf8.encode(value));
      sb.add(utf8.encode('\r\n'));
    });
    sb.add(utf8.encode('--$boundary'));
    if (closingDashes) sb.add(utf8.encode('--'));
    if (closingCrlf) sb.add(utf8.encode('\r\n'));
    return sb.takeBytes();
  }

  Future<File> writeBody(List<int> bytes) async {
    final file =
        File('${tempDir.path}/body_${DateTime.now().microsecondsSinceEpoch}');
    await file.writeAsBytes(bytes, flush: true);
    return file;
  }

  Future<List<_Collected>> parse(
    File bodyFile,
    String boundary, {
    int maxPartBytes = 5 * 1024 * 1024 * 1024,
  }) {
    final parts = <_Collected>[];
    return StreamingMultipartParser.parseFile<_Collected>(
      bodyFile: bodyFile,
      boundary: boundary,
      maxPartBytes: maxPartBytes,
      onPartStart: (filename) {
        final part = _Collected(filename);
        parts.add(part);
        return part;
      },
      onPartData: (part, chunk) async {
        if (part != null) part.bytes.addAll(chunk);
      },
      onPartEnd: (part, filename, bytesSeen, skipped) async {
        if (part != null) {
          part.skipped = skipped;
          part.ended = true;
        }
      },
    ).then((_) => parts);
  }

  test('parses two file parts and skips a plain text field', () async {
    const boundary = 'XyZ123Boundary';
    final fileA = utf8.encode('hello world');
    final fileB = <int>[0, 1, 2, 13, 10, 3, 255, 254, 13, 10, 4];

    final bodyFile = await writeBody(buildBody(
      boundary: boundary,
      files: {'a.txt': fileA, 'b.bin': fileB},
      fields: {'note': 'just a field'},
    ));

    final parts = await parse(bodyFile, boundary);

    expect(parts.length, 2, reason: 'plain fields must not produce parts');
    expect(parts[0].filename, 'a.txt');
    expect(parts[0].bytes, fileA);
    expect(parts[0].skipped, isFalse);
    expect(parts[0].ended, isTrue);
    expect(parts[1].filename, 'b.bin');
    expect(parts[1].bytes, fileB);
  });

  test('skips a preamble before the first boundary', () async {
    const boundary = 'BOUND';
    final bodyFile = await writeBody(buildBody(
      boundary: boundary,
      files: {'x.png': [9, 8, 7]},
      preamble: '--- some browser preamble ---',
    ));

    final parts = await parse(bodyFile, boundary);
    expect(parts.length, 1);
    expect(parts[0].filename, 'x.png');
    expect(parts[0].bytes, [9, 8, 7]);
  });

  test('binary data containing boundary-like fragments stays intact',
      () async {
    const boundary = 'BOUND';
    // Contains \r\n-- + a prefix of the boundary, and even a full CRLF dash
    // sequence — only an exact delimiter ends the part. (A full boundary
    // occurrence inside data would be an invalid multipart body, so the
    // fragment stops just short of one.)
    final tricky = <int>[
      ...utf8.encode('\r\n--bou'),
      0,
      ...utf8.encode('\r\n--BONus\r\n'),
      ...List<int>.generate(64, (i) => i * 7 % 256),
    ];

    final bodyFile = await writeBody(buildBody(
      boundary: boundary,
      files: {'tricky.bin': tricky},
    ));

    final parts = await parse(bodyFile, boundary);
    expect(parts, hasLength(1));
    expect(parts[0].bytes, tricky);
  });

  test('data larger than the scan window streams byte-exact', () async {
    const boundary = 'WinDowBoundary';
    // > 256KB window: forces multiple refill + carry cycles.
    final big = List<int>.generate(300 * 1024, (i) => (i * 31 + i ~/ 7) % 256);

    final bodyFile = await writeBody(buildBody(
      boundary: boundary,
      files: {'big.bin': big},
    ));

    final parts = await parse(bodyFile, boundary);
    expect(parts, hasLength(1));
    expect(parts[0].bytes.length, big.length);
    expect(parts[0].bytes, big);
  });

  test('oversized part is skipped once the cap is exceeded', () async {
    const boundary = 'CapBoundary';
    final oversized = List<int>.filled(1000, 65); // 'A' * 1000
    final small = utf8.encode('tiny');

    final bodyFile = await writeBody(buildBody(
      boundary: boundary,
      files: {'huge.bin': oversized, 'small.txt': small},
    ));

    final parts = await parse(bodyFile, boundary, maxPartBytes: 100);

    expect(parts, hasLength(2));
    expect(parts[0].filename, 'huge.bin');
    expect(parts[0].skipped, isTrue);
    expect(parts[0].bytes.length, 100,
        reason: 'only the prefix that fit the cap is delivered');
    expect(parts[1].filename, 'small.txt');
    expect(parts[1].skipped, isFalse);
    expect(parts[1].bytes, small);
  });

  test('URL-encoded filename is decoded', () async {
    const boundary = 'EncBoundary';
    final bodyFile = await writeBody(buildBody(
      boundary: boundary,
      files: {'my%20photo.png': [1, 2, 3]},
    ));

    final parts = await parse(bodyFile, boundary);
    expect(parts, hasLength(1));
    expect(parts[0].filename, 'my photo.png');
  });

  test('truncated body (no trailing delimiter) is tolerated', () async {
    // Hand-built body that simply ends mid-part: no closing delimiter at all.
    final body = <int>[
      ...utf8.encode('--TruncBoundary\r\n'),
      ...utf8.encode(
          'Content-Disposition: form-data; name="f"; filename="partial.bin"\r\n\r\n'),
      5, 6, 7, 8,
    ];
    final bodyFile = await writeBody(body);

    final parts = await parse(bodyFile, 'TruncBoundary');
    expect(parts, hasLength(1));
    expect(parts[0].bytes, [5, 6, 7, 8],
        reason: 'data received before EOF is delivered');
  });

  test('body without any boundary yields no parts', () async {
    final bodyFile =
        await writeBody(utf8.encode('this is not multipart at all'));
    final parts = await parse(bodyFile, 'NopeBoundary');
    expect(parts, isEmpty);
  });
}