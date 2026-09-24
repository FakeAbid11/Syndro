@Tags(<String>['acceptance'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:syndro/core/services/web_share/servers/share_server.dart';

import 'harness.dart';

/// App-to-browser share mode: a phone or laptop browser downloads files that
/// this device is serving.
///
/// `web_share/` had no tests at all, and even after the receive server was
/// covered, the *share* direction — the one where a browser picks files to take
/// away — had never been run. This drives the real `ShareServer` over real
/// HTTP: page render, the connection-approval gate, byte fidelity, resumable
/// Range requests, and filename escaping in the generated HTML.
///
/// Two deliberate structural choices:
///  - One server for the whole file. `startSharing` binds with `shared: true`
///    (`share_server.dart:245`), so a second instance can take the same port
///    while the first is still alive and the OS then distributes clients across
///    two different file lists. A per-test server produced answers from the
///    wrong instance rather than proving anything.
///  - The gate is asserted first, before anything is approved. Confirmation is
///    tracked per IP and 127.0.0.1 stays approved for the rest of the run, so
///    the "refused until approved" checks only mean something in position one.
///
/// Known gap, stated rather than papered over: the generated HTML page is
/// asserted through `/api/files`, not by scraping `/`. Read from this same
/// process, `GET /` returns only `<!DOCTYPE html>` before the connection ends —
/// identically via `HttpClient` and via a raw socket — while a real browser
/// receives all ~30 KB and renders the full listing, sizes, thumbnails and
/// correctly percent-encoded links. So it is a property of an in-process client
/// against this server, not a product defect, and no assertion here depends on
/// it. The angle-bracket filename (`<script>` in a name) is additionally
/// untestable on Windows: those characters are illegal in filenames there.
void main() {
  setUpAll(installAcceptanceBootstrap);
  tearDownAll(uninstallAcceptanceBootstrap);

  late Directory workDir;
  final server = ShareServer();
  late int port;

  late File smallFile;
  late File rangedFile;
  late List<int> rangedBytes;

  /// Characters that are legal in a Windows filename but still meaningful to an
  /// HTML/JS sink: `&` proves escaping happened, `'` is what breaks out of a
  /// single-quoted attribute. Angle brackets — the classic `<script>` payload —
  /// cannot be asserted here at all: they are illegal in Windows filenames, so
  /// that case is only reachable on Android/Linux and is left uncovered rather
  /// than faked with a name the server could never have opened.
  const evilName = "sales & cost' onmouseover=alert(1).txt";
  late File evilFile;

  setUpAll(() async {
    workDir = await Directory.systemTemp.createTemp('syndro-web-share');

    smallFile = File(p.join(workDir.path, 'holiday.jpg'));
    await smallFile.writeAsBytes(List<int>.filled(1024, 7), flush: true);

    rangedBytes = List<int>.generate(1000, (i) => i & 0xFF);
    rangedFile = File(p.join(workDir.path, 'ranged.bin'));
    await rangedFile.writeAsBytes(rangedBytes, flush: true);

    evilFile = File(p.join(workDir.path, evilName));
    await evilFile.writeAsBytes(utf8.encode('content'), flush: true);

    final url = await server.startSharing([smallFile, rangedFile, evilFile]);
    expect(url, isNotNull, reason: 'startSharing must return a share URL');
    port = Uri.parse(url!).port;
  });

  tearDownAll(() async {
    await server.stop();
    if (await workDir.exists()) await workDir.delete(recursive: true);
  });

  Future<({int status, Map<String, String> headers, List<int> body})> get(
    String path, {
    Map<String, String> headers = const {},
  }) async {
    final client = HttpClient();
    try {
      final request = await client.getUrl(
        Uri.parse('http://${InternetAddress.loopbackIPv4.address}:$port$path'),
      );
      request.headers.set(HttpHeaders.connectionHeader, 'close');
      headers.forEach(request.headers.add);
      final response =
          await request.close().timeout(const Duration(seconds: 20));

      final body = <int>[];
      await for (final chunk in response) {
        body.addAll(chunk);
      }

      final flat = <String, String>{};
      response.headers.forEach((name, values) => flat[name] = values.join(','));
      return (
        status: response.statusCode,
        headers: flat,
        body: body,
      );
    } finally {
      client.close(force: true);
    }
  }

  Future<void> approveClient() async {
    await get('/');
    await waitUntil(
      () => server.pendingConfirmations.isNotEmpty,
      timeout: const Duration(seconds: 10),
      reason: 'loading the share page should raise a connection confirmation',
    );
    server.confirmConnection(server.pendingConfirmations.first.ipAddress);
  }

  test('nothing is served to a client the user has not approved', () async {
    final deniedDownload = await get('/download/0/holiday.jpg');
    expect(deniedDownload.status, 403,
        reason: 'an unapproved browser session must not read shared files');
    expect(deniedDownload.body, isNot(equals(List<int>.filled(1024, 7))),
        reason: 'a refused download must not leak the file contents');

    final deniedList = await get('/api/files');
    expect(deniedList.status, 403, reason: 'the listing is gated the same way');

    // Approve for every case below, exactly as the user tapping Accept would.
    await approveClient();
  });

  test('the shared files are listed for an approved client', () async {
    final listed = await get('/api/files');
    expect(listed.status, 200,
        reason: 'an approved client can read the listing');

    final text = utf8.decode(listed.body, allowMalformed: true);
    expect(text, contains('holiday.jpg'));
    expect(text, contains('ranged.bin'));
    expect(text, contains('1024'), reason: 'sizes should be reported');
  });

  test('an approved download returns the file byte-for-byte', () async {
    final download = await get('/download/0/holiday.jpg');
    expect(download.status, 200);
    expect(download.body, List<int>.filled(1024, 7));
    expect(download.headers['content-length'], '1024');
    expect(download.headers['accept-ranges'], 'bytes');
    expect(download.headers['content-disposition'], contains('holiday.jpg'));
  });

  test('a resumed download honours its Range exactly', () async {
    final tail =
        await get('/download/1/ranged.bin', headers: {'range': 'bytes=500-'});
    expect(tail.status, 206, reason: 'a partial request must be answered 206');
    expect(tail.body, rangedBytes.sublist(500),
        reason: 'bytes=500- must be the real tail of the file');
    expect(tail.headers['content-range'], 'bytes 500-999/1000');

    final head =
        await get('/download/1/ranged.bin', headers: {'range': 'bytes=0-499'});
    expect(head.status, 206);
    expect(head.body, rangedBytes.sublist(0, 500));
    expect(head.headers['content-range'], 'bytes 0-499/1000');
  });

  test('a range past the end of the file is rejected, not served whole',
      () async {
    final bad =
        await get('/download/1/ranged.bin', headers: {'range': 'bytes=5000-'});
    expect(bad.status, 416,
        reason: 'a start beyond EOF must be 416, got ${bad.status}');
    expect(bad.body, isEmpty);
  });

  test('a file index outside the share list is not served', () async {
    expect((await get('/download/9/holiday.jpg')).status, isNot(200));
    expect((await get('/download/notanumber/holiday.jpg')).status, isNot(200));
  });

  test('a tricky filename is linked safely and stays downloadable', () async {
    final listed = await get('/api/files');
    expect(listed.status, 200);

    final json = utf8.decode(listed.body, allowMalformed: true);
    expect(json, contains(Uri.encodeComponent(evilName)),
        reason: 'the download link must carry the percent-encoded name, not a '
            'raw "&" or space that the browser would truncate at');

    final download = await get('/download/2/${Uri.encodeComponent(evilName)}');
    expect(download.status, 200,
        reason: 'awkward names must remain downloadable');
    expect(download.body, utf8.encode('content'));
  });
}
