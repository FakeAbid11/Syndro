// One-time setup for the authenticated self-updater.
//
//   dart run tool/gen_update_key.dart               # create a keypair
//   dart run tool/gen_update_key.dart --show-public  # re-print the public key
//
// The private seed is written to a file OUTSIDE this repository and is never
// echoed to stdout: printing it would place a signing secret in terminal
// scrollback, CI logs and any transcript of the session that ran it. The
// public key is meant to be committed (lib/core/utils/update_trust.dart).

import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:path/path.dart' as p;

const String _seedDirName = '.syndro';
const String _seedFileName = 'update-signing-ed25519.seed';

Future<void> main(List<String> args) async {
  if (args.contains('--help') || args.contains('-h')) {
    stdout.writeln(
      'Usage: dart run tool/gen_update_key.dart [options]\n\n'
      '  --show-public  Print the public key for the existing seed file.\n'
      '  --force        Replace an existing seed with a new keypair.\n'
      '  -h, --help     Show this message.',
    );
    return;
  }

  final seedFile = _seedFile();
  if (seedFile == null) {
    stderr.writeln('Could not determine your home directory '
        '(USERPROFILE and HOME are both unset).');
    exitCode = 1;
    return;
  }

  if (args.contains('--show-public')) {
    final seed = await _readSeed(seedFile);
    if (seed == null) {
      stderr.writeln('No usable signing key at ${seedFile.path}');
      exitCode = 1;
      return;
    }
    _report(await _publicKeyOfSeed(seed), seedFile.path);
    return;
  }

  if (await seedFile.exists() && !args.contains('--force')) {
    stderr.writeln('A signing key already exists:\n  ${seedFile.path}\n\n'
        'Reuse it: every release signed with the same key stays installable by '
        'clients that trust it.\n'
        '  dart run tool/gen_update_key.dart --show-public   # re-print pubkey\n'
        'Rotate: the old key stops validating new releases, and releases made '
        'with it stop offering in-app updates to clients that only trust the '
        'new key.\n'
        '  dart run tool/gen_update_key.dart --force         # replace it');
    exitCode = 1;
    return;
  }

  final keyPair = await Ed25519().newKeyPair();
  final seed = await keyPair.extractPrivateKeyBytes();
  if (seed.length != 32) {
    stderr.writeln('Unexpected private key length: ${seed.length} bytes');
    exitCode = 1;
    return;
  }

  await seedFile.parent.create(recursive: true);
  await seedFile.writeAsString('${base64Url.encode(seed)}\n', flush: true);

  _report(await keyPair.extractPublicKey(), seedFile.path);
  stdout.writeln('''
Next steps:
  1. Create the GitHub repository secret SYNDRO_UPDATE_SIGNING_SEED holding
     the contents of the file above (Actions > Secrets and variables >
     Repository secrets). Only you can do this.
  2. Back that file up off this machine. If it is lost, no new release can be
     installed in-app by existing clients until a rotated key reaches them
     through a manual update.
  3. Leave it out of git — it sits outside the repo deliberately.''');
}

Future<SimplePublicKey> _publicKeyOfSeed(List<int> seed) async {
  final keyPair = await Ed25519().newKeyPairFromSeed(seed);
  return keyPair.extractPublicKey();
}

void _report(SimplePublicKey publicKey, String seedPath) {
  final rows = StringBuffer();
  for (var i = 0; i < publicKey.bytes.length; i += 8) {
    final end = (i + 8) > publicKey.bytes.length
        ? publicKey.bytes.length
        : i + 8;
    rows.writeln('      ${publicKey.bytes
        .sublist(i, end)
        .map((b) => '0x${b.toRadixString(16).padLeft(2, '0')}')
        .join(', ')},');
  }

  stdout.writeln('''
Ed25519 public key (${publicKey.bytes.length} bytes, base64url: ${base64Url.encode(publicKey.bytes)})

Paste this into lib/core/utils/update_trust.dart:

  static const List<int> trustedEd25519PublicKey = <int>[
${rows.toString().trimRight()}
    ];

Private seed stored, and never printed: $seedPath''');
}

Future<List<int>?> _readSeed(File seedFile) async {
  try {
    if (!await seedFile.exists()) {
      stderr.writeln('No signing key at ${seedFile.path}');
      stderr.writeln('Generate one with: dart run tool/gen_update_key.dart');
      return null;
    }
    final raw = (await seedFile.readAsString()).trim();
    final seed = base64Url.decode(raw);
    if (seed.length != 32) {
      stderr.writeln('Expected a 32-byte base64url seed, found '
          '${seed.length} bytes.');
      return null;
    }
    return seed;
  } on FormatException {
    stderr.writeln('${seedFile.path} is not valid base64url.');
    return null;
  } on FileSystemException catch (e) {
    stderr.writeln('Could not read ${seedFile.path}: ${e.message}');
    return null;
  }
}

File? _seedFile() {
  final home = Platform.environment['USERPROFILE'] ??
      Platform.environment['HOME'];
  if (home == null || home.isEmpty) return null;
  return File(p.join(home, _seedDirName, _seedFileName));
}
