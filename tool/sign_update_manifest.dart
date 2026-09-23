// Sign a release so Syndro clients will install it in-app.
//
//   SYNDRO_UPDATE_SIGNING_SEED=<base64url seed> \
//   dart run tool/sign_update_manifest.dart \
//     --version 1.3.0 \
//     --out update-manifest.json \
//     --asset dist/Syndro-Setup-1.3.0.exe \
//     --asset dist/Syndro-1.3.0.apk
//
// The seed is read from the environment, never argv: command lines show up in
// process listings and in CI logs of failed steps. Uploads of `update-manifest`
// `.json` as a release asset are what make "Update now" appear in the client.

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:cryptography/cryptography.dart';
import 'package:syndro/core/utils/update_manifest.dart';
import 'package:syndro/core/utils/update_trust.dart';

const String _seedEnvVar = 'SYNDRO_UPDATE_SIGNING_SEED';
const String _keyIdEnvVar = 'SYNDRO_UPDATE_KEY_ID';

Future<void> main(List<String> args) async {
  final parsed = _Args.parse(args);
  if (parsed == null) {
    stderr.writeln('''
Usage: dart run tool/sign_update_manifest.dart --version <ver> --out <file> \\
         --asset <path> [--asset <path>...]

  --version  Release version this manifest authenticates (e.g. 1.3.0).
  --out      Where to write update-manifest.json.
  --asset    A release file to include. Repeatable. Name is its basename.
  -h, --help This message.

Env: $_seedEnvVar (required) base64url 32-byte Ed25519 seed.
     $_keyIdEnvVar (optional) key id to sign under; default
     ${UpdateTrust.trustedEd25519PublicKeys.keys.join(', ')}.
''');
    exitCode = 64;
    return;
  }

  final seedText = (Platform.environment[_seedEnvVar] ?? '').trim();
  if (seedText.isEmpty) {
    stderr.writeln('$_seedEnvVar is not set. Refusing to publish an unsigned '
        'release: clients would fall back to browser downloads and the '
        'in-app updater would silently stop working.');
    exitCode = 1;
    return;
  }

  final List<int> seed;
  try {
    seed = base64Url.decode(seedText);
  } on FormatException {
    stderr.writeln('$_seedEnvVar is not valid base64url.');
    exitCode = 1;
    return;
  }
  if (seed.length != 32) {
    stderr.writeln('$_seedEnvVar must decode to 32 bytes, got '
        '${seed.length}.');
    exitCode = 1;
    return;
  }

  final keyId = (Platform.environment[_keyIdEnvVar] ?? '').trim().isEmpty
      ? UpdateTrust.trustedEd25519PublicKeys.keys.first
      : Platform.environment[_keyIdEnvVar]!.trim();
  final expectedPublicKey = UpdateTrust.trustedEd25519PublicKeys[keyId];
  if (expectedPublicKey == null) {
    stderr.writeln('Unknown $_keyIdEnvVar "$keyId". Known ids: '
        '${UpdateTrust.trustedEd25519PublicKeys.keys.join(', ')}');
    exitCode = 1;
    return;
  }

  final assets = <UpdateManifestAsset>[];
  for (final path in parsed.assetPaths) {
    final file = File(path);
    if (!await file.exists()) {
      stderr.writeln('Asset not found: $path');
      exitCode = 1;
      return;
    }
    final size = await file.length();
    if (size == 0) {
      stderr.writeln('Asset is empty: $path');
      exitCode = 1;
      return;
    }
    assets.add(UpdateManifestAsset(
      name: _baseName(path),
      sha256Hex: (await crypto.sha256.bind(file.openRead()).last).toString(),
      size: size,
    ));
  }
  if (assets.isEmpty) {
    stderr.writeln('No --asset given.');
    exitCode = 1;
    return;
  }

  final keyPair = await Ed25519().newKeyPairFromSeed(seed);
  final actualPublicKey = (await keyPair.extractPublicKey()).bytes;

  // Catches the failure that matters most: a CI secret that no longer matches
  // the key embedded in the app. Without this check such a release would
  // publish green and then have every client silently refuse to install it.
  if (!_bytesEqual(actualPublicKey, expectedPublicKey)) {
    stderr.writeln('The signing key in \$$_seedEnvVar does not match the '
        'public key embedded in lib/core/utils/update_trust.dart for id '
        '"$keyId".\n  secret  : ${base64Url.encode(actualPublicKey)}\n'
        '  in app  : ${base64Url.encode(expectedPublicKey)}\n'
        'Either the secret is stale or the app has not been rebuilt after a '
        'key rotation. Refusing to sign.');
    exitCode = 1;
    return;
  }

  final payload =
      UpdateManifest.canonicalPayload(version: parsed.version, assets: assets);
  final signature =
      await Ed25519().sign(utf8.encode(payload), keyPair: keyPair);

  final envelope = const JsonEncoder.withIndent('  ').convert(<String, Object?>{
    'schema': UpdateTrust.manifestSchema,
    'keyId': keyId,
    'payload': payload,
    'sig': base64Url.encode(signature.bytes),
  });

  await File(parsed.outPath).writeAsString('$envelope\n', flush: true);

  // Round-trip the envelope through the same verifier a client runs, so a
  // signer/verifier disagreement fails the build rather than silently
  // disabling in-app updates for everyone.
  if (!await _selfCheck(parsed.outPath, parsed.version)) {
    exitCode = 1;
    return;
  }

  stdout.writeln('Signed ${assets.length} asset(s) for ${parsed.version} '
      'with key "$keyId" -> ${parsed.outPath}');
  for (final asset in assets) {
    stdout.writeln('  ${asset.name}  ${asset.size} bytes  ${asset.sha256Hex}');
  }
}

/// Verify the file just written against the anchors compiled into the app.
Future<bool> _selfCheck(String outPath, String version) async {
  try {
    final manifest = await UpdateManifest.verify(
      await File(outPath).readAsString(),
      expectedVersion: version,
    );
    return manifest.version == version;
  } on FormatException catch (e) {
    stderr.writeln('Self-check failed: ${e.message}');
    return false;
  }
}

String _baseName(String path) {
  final normalized = path.replaceAll('\\', '/');
  final slash = normalized.lastIndexOf('/');
  return slash == -1 ? path : normalized.substring(slash + 1);
}

bool _bytesEqual(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

class _Args {
  _Args._(this.version, this.outPath, this.assetPaths);

  final String version;
  final String outPath;
  final List<String> assetPaths;

  static _Args? parse(List<String> args) {
    String? version;
    String? outPath;
    final assets = <String>[];

    for (var i = 0; i < args.length; i++) {
      final flag = args[i];
      switch (flag) {
        case '--version':
        case '--out':
        case '--asset':
          if (i + 1 >= args.length) return null;
          final value = args[++i];
          if (flag == '--version') {
            version = value;
          } else if (flag == '--out') {
            outPath = value;
          } else {
            assets.add(value);
          }
        case '--help':
        case '-h':
          return null;
        default:
          return null;
      }
    }

    if (version == null || version.isEmpty || outPath == null) return null;
    return _Args._(version, outPath, assets);
  }
}
