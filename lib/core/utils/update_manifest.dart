import 'dart:convert';

import 'package:cryptography/cryptography.dart';

import 'update_trust.dart';

/// One verified entry of a release manifest: what the publisher says a named
/// asset is made of.
class UpdateManifestAsset {
  const UpdateManifestAsset({
    required this.name,
    required this.sha256Hex,
    required this.size,
  });

  /// Release asset name, matched exactly — never by substring.
  final String name;

  /// Lowercase hex SHA-256 digest of the asset's bytes.
  final String sha256Hex;

  /// Exact byte length of the asset.
  final int size;

  Map<String, Object> toJson() => <String, Object>{
        'name': name,
        'sha256': sha256Hex,
        'size': size,
      };

  @override
  String toString() => 'UpdateManifestAsset($name, $size bytes)';
}

/// A release manifest whose signature has been checked against
/// [UpdateTrust.trustedEd25519PublicKeys].
///
/// The only safe way to obtain an instance is [UpdateManifest.verify]; the
/// constructor is private so an unverified manifest cannot exist.
///
/// Wire format — one release asset, `update-manifest.json`:
///
/// ```json
/// {
///   "schema": 1,
///   "keyId": "2026-09",
///   "payload": "{\"assets\":[…],\"version\":\"1.3.0\"}",
///   "sig": "<base64url Ed25519 signature>"
/// }
/// ```
///
/// `payload` is a *string* holding canonical JSON, and the signature covers the
/// UTF-8 bytes of that string. Signing a string field rather than the enclosing
/// document is deliberate: re-serialising parsed JSON does not reliably
/// reproduce the signed bytes (key order, whitespace and number formatting all
/// vary), and a verifier that guesses wrong accepts nothing — or, worse,
/// accepts what it should not.
class UpdateManifest {
  const UpdateManifest._({
    required this.version,
    required this.keyId,
    required this.assets,
  });

  /// Version the publisher vouched for. Must equal the release tag we are
  /// offering, which is what stops a valid old manifest being replayed onto a
  /// newer release.
  final String version;

  /// Which trusted key signed this.
  final String keyId;

  final List<UpdateManifestAsset> assets;

  static final RegExp _hex64 = RegExp(r'^[0-9a-fA-F]{64}$');

  /// The manifest entry for [name], or null when the publisher did not sign
  /// that asset. Comparison is exact so an extra `Syndro-Setup-1.3.0-evil.exe`
  /// entry cannot be selected in place of the real one.
  UpdateManifestAsset? assetFor(String name) {
    for (final asset in assets) {
      if (asset.name == name) return asset;
    }
    return null;
  }

  /// Parse and cryptographically authenticate [rawJson] against the shipped
  /// trust anchors.
  ///
  /// Throws [FormatException] for any rejection — bad envelope, unknown key id,
  /// failed signature, version that does not match [expectedVersion], or a
  /// malformed digest. Callers must treat every rejection identically: refuse
  /// the in-app install path.
  static Future<UpdateManifest> verify(
    String rawJson, {
    required String expectedVersion,
  }) =>
      verifyWithTrustedPublicKeys(
        rawJson,
        expectedVersion: expectedVersion,
        trustedPublicKeys: UpdateTrust.trustedEd25519PublicKeys,
      );

  /// [verify] with an explicit key set. Exists so tests can sign fixtures with
  /// a throwaway keypair without a real signing seed being in the repository.
  ///
  /// Nothing in `lib/` may call this directly: the one permitted caller is
  /// UpdateService's `_resolveTrustedAsset`, and only when its
  /// `@visibleForTesting` parameter is non-null — which the analyzer reports as
  /// an error if any production call site ever passes it.
  static Future<UpdateManifest> verifyWithTrustedPublicKeys(
    String rawJson, {
    required String expectedVersion,
    required Map<String, List<int>> trustedPublicKeys,
  }) async {
    if (expectedVersion.isEmpty) {
      throw const FormatException('No release version to authenticate against');
    }

    final Object? decoded;
    try {
      decoded = jsonDecode(rawJson);
    } on FormatException {
      throw const FormatException('Manifest is not valid JSON');
    }
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('Manifest is not a JSON object');
    }

    if (decoded['schema'] != UpdateTrust.manifestSchema) {
      throw FormatException(
        'Unsupported manifest schema ${decoded['schema']}',
      );
    }

    final keyId = decoded['keyId'];
    if (keyId is! String) throw const FormatException('Missing keyId');
    final publicKeyBytes = trustedPublicKeys[keyId];
    if (publicKeyBytes == null) {
      throw FormatException('Untrusted signing key id: $keyId');
    }

    final payload = decoded['payload'];
    if (payload is! String || payload.isEmpty) {
      throw const FormatException('Missing payload string');
    }

    final signatureBytes = _decodeBase64Url(decoded['sig']);
    if (signatureBytes == null || signatureBytes.length != 64) {
      throw const FormatException('Signature is not 64 bytes');
    }

    final signature = Signature(
      signatureBytes,
      publicKey: SimplePublicKey(publicKeyBytes, type: KeyPairType.ed25519),
    );

    final bool authentic;
    try {
      authentic = await Ed25519()
          .verify(utf8.encode(payload), signature: signature);
    } on Object catch (e) {
      // A malformed signature can surface as a StateError from the algorithm
      // rather than a plain `false`; either way it is not authenticated.
      throw FormatException('Signature could not be checked: $e');
    }
    if (!authentic) {
      throw const FormatException(
          'Signature does not match any trusted publisher key');
    }

    final Object? payloadDecoded;
    try {
      payloadDecoded = jsonDecode(payload);
    } on FormatException {
      throw const FormatException('Payload is not valid JSON');
    }
    if (payloadDecoded is! Map<String, dynamic>) {
      throw const FormatException('Payload is not a JSON object');
    }

    if (payloadDecoded['version'] != expectedVersion) {
      throw FormatException(
        'Manifest is for release ${payloadDecoded['version']}, not '
        '$expectedVersion',
      );
    }

    final rawAssets = payloadDecoded['assets'];
    if (rawAssets is! List) throw const FormatException('assets is not a list');

    final assets = <UpdateManifestAsset>[];
    for (final entry in rawAssets) {
      if (entry is! Map) {
        throw const FormatException('asset entry is not an object');
      }
      final name = entry['name'];
      final digest = entry['sha256'];
      final size = entry['size'];
      if (name is! String || name.isEmpty) {
        throw const FormatException('asset name is missing');
      }
      if (digest is! String || !_hex64.hasMatch(digest)) {
        throw FormatException('asset $name has a malformed sha256');
      }
      if (size is! int || size <= 0) {
        throw FormatException('asset $name has an invalid size');
      }
      assets.add(UpdateManifestAsset(
        name: name,
        sha256Hex: digest.toLowerCase(),
        size: size,
      ));
    }

    return UpdateManifest._(
      version: expectedVersion,
      keyId: keyId,
      assets: assets,
    );
  }

  /// Byte-stable JSON that [signPayload] produces a signature over and [verify]
  /// consumes. Key order is fixed (alphabetical) and numbers stay integers so
  /// the signer and verifier cannot drift apart.
  ///
  /// Shared with `tool/sign_update_manifest.dart` on purpose: the CI job and
  /// the tests must sign the exact same bytes a client will verify.
  static String canonicalPayload({
    required String version,
    required List<UpdateManifestAsset> assets,
  }) {
    final sorted = <UpdateManifestAsset>[...assets]
      ..sort((a, b) => a.name.compareTo(b.name));
    final entries = sorted.map((asset) {
      final fields = <String, Object>{
        'name': asset.name,
        'sha256': asset.sha256Hex,
        'size': asset.size,
      };
      final keys = fields.keys.toList()..sort();
      return '{${keys.map((k) => '"$k":${jsonEncode(fields[k])}').join(',')}}';
    }).join(',');
    return '{"assets":[$entries],"version":${jsonEncode(version)}}';
  }

  /// Decode a base64url value, tolerating the `=` padding the encoder emits and
  /// the padding stripped by tools that copy the value around.
  static List<int>? _decodeBase64Url(Object? value) {
    if (value is! String || value.isEmpty) return null;
    var text = value.replaceAll('-', '+').replaceAll('_', '/');
    final remainder = text.length % 4;
    if (remainder == 1) return null;
    if (remainder > 0) text += '=' * (4 - remainder);
    try {
      return base64.decode(text);
    } on FormatException {
      return null;
    }
  }
}
