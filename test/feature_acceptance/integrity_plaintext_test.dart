@Tags(<String>['acceptance'])
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

/// Plaintext receive does not verify file integrity.
///
/// The sender computes and transmits `x-file-hash` on the unencrypted path
/// (`transfer_service_impl.dart:3413`), but `_handleFileUpload` never reads
/// that header: the only two reads of `x-file-hash` in the file are at `:2131`
/// and `:2345`, both inside `_handleEncryptedFileUpload`. So a plaintext upload
/// whose bytes do not match its declared hash is written out, marked
/// `completed`, recorded in history and announced with a "Transfer complete"
/// notification.
///
/// Size truncation *is* caught (`phase1_correctness_test.dart:112-141`), which
/// is why this gap has gone unnoticed: the existing test that looks like an
/// integrity test only checks the byte count.
///
/// EXPECTED TO FAIL until the plaintext handler verifies the hash it is given.
void main() {
  setUpAll(installAcceptanceBootstrap);
  tearDownAll(uninstallAcceptanceBootstrap);

  test('a plaintext upload whose bytes contradict its declared hash is refused',
      () async {
    final node = await SyndroNode.start(
      deviceId: 'fa-integrity-receiver',
      displayName: 'FA Integrity Receiver',
      encryptionEnabled: false,
    );
    try {
      const transferId = 'fa02-hash-mismatch';
      const fileName = 'hashme.bin';
      final bodyBytes = List<int>.filled(2048, 0x41);

      final initiate = await rawPostJson(node.port, '/transfer/initiate', {
        'x-device-id': 'fa-external-sender',
      }, <String, Object?>{
        'id': transferId,
        'senderId': 'fa-external-sender',
        'senderName': 'FA External',
        'senderToken': 'fa-token-1',
        'receiverId': 'this-device',
        'items': <Map<String, Object?>>[
          <String, Object?>{'name': fileName, 'size': bodyBytes.length},
        ],
      });
      expect(initiate, 200, reason: 'initiate must be accepted');
      await node.service.approveTransfer(transferId);

      // Exactly the declared number of bytes, so the size gate passes — but a
      // hash of content that is not what we sent.
      final upload = await rawPost(node.port, '/transfer/upload', {
        'x-transfer-id': transferId,
        'x-file-name': fileName,
        'x-file-size': '${bodyBytes.length}',
        'x-sender-id': 'fa-external-sender',
        'x-sender-token': 'fa-token-1',
        'x-file-hash': 'f' * 64,
      }, bodyBytes);

      expect(upload, 400,
          reason: 'the receiver accepted a payload that does not match the '
              'hash the sender declared for it');
      expect(await node.downloaded(fileName).exists(), isFalse,
          reason: 'an unverified payload must not be left in the downloads dir');
    } finally {
      await node.dispose();
      await _delete(node.downloadDir);
      await _delete(node.workDir);
    }
  });
}

Future<void> _delete(Directory dir) async {
  try {
    if (await dir.exists()) await dir.delete(recursive: true);
  } on FileSystemException {
    // Best effort.
  }
}
