import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:syndro/core/utils/update_manifest.dart';
import 'package:syndro/core/utils/update_trust.dart';

/// Fixtures for the signed update manifest.
///
/// Every signature here comes from a keypair generated at run time, never from
/// the real signing seed (which lives outside the repository) — so no private
/// key is ever committed, and CI can run these tests without secrets.
void main() {
  const keyId = 'test-key';
  const version = '1.3.0';

  late SimpleKeyPair keyPair;
  late List<int> publicKeyBytes;

  setUp(() async {
    keyPair = await Ed25519().newKeyPair();
    publicKeyBytes = (await keyPair.extractPublicKey()).bytes;
  });

  Future<String> signedManifest(
    List<UpdateManifestAsset> assets, {
    String forVersion = version,
    SimpleKeyPair? withKeyPair,
    String? keyIdOverride,
    int? schema,
    String Function(String payload)? envelope,
  }) async {
    final payload =
        UpdateManifest.canonicalPayload(version: forVersion, assets: assets);
    final signature = await Ed25519()
        .sign(utf8.encode(payload), keyPair: withKeyPair ?? keyPair);
    final body = jsonEncode(<String, Object?>{
      'schema': schema ?? UpdateTrust.manifestSchema,
      'keyId': keyIdOverride ?? keyId,
      'payload': payload,
      'sig': base64Url.encode(signature.bytes),
    });
    return envelope == null ? body : envelope(body);
  }

  UpdateManifestAsset asset(
    String name, {
    String? sha256Hex,
    int size = 13738329,
  }) =>
      UpdateManifestAsset(
        name: name,
        sha256Hex:
            sha256Hex ?? 'a' * 63 + '1', //
        size: size,
      );

  Future<UpdateManifest> verify(String raw, {String against = version}) =>
      UpdateManifest.verifyWithTrustedPublicKeys(
        raw,
        expectedVersion: against,
        trustedPublicKeys: {keyId: publicKeyBytes},
      );

  group('happy path', () {
    test('a correctly signed manifest yields its assets', () async {
      final manifest = await verify(await signedManifest([
        asset('Syndro-Setup-1.3.0.exe'),
        asset('Syndro-1.3.0.apk', size: 82167012),
      ]));

      expect(manifest.version, version);
      expect(manifest.keyId, keyId);
      expect(manifest.assets, hasLength(2));
      expect(manifest.assetFor('Syndro-1.3.0.apk')?.size, 82167012);
    });

    test('digests are normalised to lowercase', () async {
      final manifest = await verify(await signedManifest([
        asset('a.exe', sha256Hex: 'AB' * 31 + 'cd'),
      ]));
      expect(manifest.assetFor('a.exe')?.sha256Hex, '${'ab' * 31}cd');
    });

    test('canonicalPayload is independent of caller asset order', () async {
      final one = UpdateManifest.canonicalPayload(version: version, assets: [
        asset('z.apk'),
        asset('a.exe'),
      ]);
      final two = UpdateManifest.canonicalPayload(version: version, assets: [
        asset('a.exe'),
        asset('z.apk'),
      ]);
      expect(one, two);
      // Quoted so a reviewer can see the fixed key order inside each entry.
      expect(one, startsWith('{"assets":[{"name":"a.exe","sha256":'));
    });
  });

  group('rejects', () {
    test('a payload edited after signing', () async {
      final raw = await signedManifest([asset('Syndro-Setup-1.3.0.exe')]);
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      decoded['payload'] =
          (decoded['payload'] as String).replaceFirst('${'a' * 63}1', 'b' * 64);
      expect(
        verify(jsonEncode(decoded)),
        throwsA(isA<FormatException>()),
        reason: 'swapping the advertised digest must break the signature',
      );
    });

    test('a signature made by a different key', () async {
      final stranger = await Ed25519().newKeyPair();
      expect(
        verify(await signedManifest(
          [asset('a.exe')],
          withKeyPair: stranger,
        )),
        throwsA(isA<FormatException>()),
      );
    });

    test('an unknown key id', () async {
      expect(
        verify(await signedManifest([asset('a.exe')], keyIdOverride: 'other')),
        throwsA(isA<FormatException>()),
      );
    });

    test('a schema this build does not understand', () async {
      expect(
        verify(await signedManifest([asset('a.exe')], schema: 2)),
        throwsA(isA<FormatException>()),
      );
    });

    test('a manifest bound to a different release version', () async {
      expect(
        verify(await signedManifest([asset('a.exe')]), against: '9.9.9'),
        throwsA(isA<FormatException>()),
        reason: 'otherwise a signed 1.3.0 manifest could authorise 9.9.9',
      );
    });

    test('a signature that is not 64 bytes', () async {
      final raw = await signedManifest([asset('a.exe')]);
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      final short = <int>[...base64Url.decode(decoded['sig'] as String)]
        ..removeLast();
      decoded['sig'] = base64Url.encode(short);
      expect(verify(jsonEncode(decoded)), throwsA(isA<FormatException>()));
    });

    test('a malformed or missing sha256', () async {
      expect(
        verify(await signedManifest([asset('a.exe', sha256Hex: 'not-hex')])),
        throwsA(isA<FormatException>()),
      );
      expect(
        verify(await signedManifest(
          [asset('a.exe', sha256Hex: 'a' * 64)],
        )),
        completes,
      );
      expect(
        verify(await signedManifest([asset('a.exe', sha256Hex: 'a' * 62)])),
        throwsA(isA<FormatException>()),
      );
    });

    test('a non-positive size', () async {
      expect(
        verify(await signedManifest([asset('a.exe', size: 0)])),
        throwsA(isA<FormatException>()),
      );
      expect(
        verify(await signedManifest([asset('a.exe', size: -5)])),
        throwsA(isA<FormatException>()),
      );
    });

    test('non-JSON, a JSON array, and an absent payload', () async {
      expect(verify('not json'), throwsA(isA<FormatException>()));
      expect(verify('[]'), throwsA(isA<FormatException>()));
      expect(verify(jsonEncode({'schema': 1, 'keyId': keyId})),
          throwsA(isA<FormatException>()));
    });

    test('an empty version to authenticate against', () async {
      expect(
        UpdateManifest.verifyWithTrustedPublicKeys(
          await signedManifest([asset('a.exe')]),
          expectedVersion: '',
          trustedPublicKeys: {keyId: publicKeyBytes},
        ),
        throwsA(isA<FormatException>()),
      );
    });

    test('the shipped anchors reject a test-key signature', () async {
      // Guards the seam: `verify` must consult UpdateTrust, not an injected map.
      expect(
        UpdateManifest.verify(
          await signedManifest([asset('a.exe')]),
          expectedVersion: version,
        ),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('asset selection', () {
    test('matches the name exactly and ignores lookalikes', () async {
      final manifest = await verify(await signedManifest([
        asset('Syndro-Setup-1.3.0.exe'),
        asset('Syndro-Setup-1.3.0-evil.exe'),
      ]));

      expect(manifest.assetFor('Syndro-Setup-1.3.0.exe'), isNotNull);
      expect(manifest.assetFor('Syndro-Setup-1.3.0-evil.exe'), isNotNull);
      expect(manifest.assetFor('Syndro-Setup'), isNull,
          reason: 'no substring matching');
      expect(manifest.assetFor('syndro-setup-1.3.0.exe'), isNull,
          reason: 'matching is case-sensitive');
      expect(manifest.assetFor('missing.exe'), isNull);
    });
  });

  group('base64url tolerance', () {
    test('accepts unpadded and url-safe signature encodings', () async {
      final raw = await signedManifest([asset('a.exe')]);
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      final bytes = base64Url.decode(decoded['sig'] as String);

      for (final variant in [
        base64Url.encode(bytes), // encoder default, with padding
        base64Url.encode(bytes).replaceAll('=', ''), // padding stripped
      ]) {
        decoded['sig'] = variant;
        expect(await verify(jsonEncode(decoded)), isA<UpdateManifest>(),
            reason: 'failed for encoding: $variant');
      }
    });

    test('rejects a signature that is not base64url at all', () async {
      final raw = await signedManifest([asset('a.exe')]);
      final decoded = jsonDecode(raw) as Map<String, dynamic>
        ..['sig'] = '%%%%not-base64%%%%';
      expect(verify(jsonEncode(decoded)), throwsA(isA<FormatException>()));
    });
  });
}
