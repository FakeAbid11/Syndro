/// Trust anchors for the authenticated self-updater.
///
/// Everything in this file is public by design and belongs in source control:
/// a signature is only useful because the key that made it is fixed here, in
/// the binary the attacker cannot edit. These values are NOT secrets and must
/// not be moved to `flutter_secure_storage`, which would hand the verifier a
/// key an attacker could swap.
library;

/// The signing identity Syndro will accept for a release payload.
///
/// Pairs with `tool/gen_update_key.dart` (key generation) and
/// `tool/sign_update_manifest.dart` (CI signing).
class UpdateTrust {
  UpdateTrust._();

  /// Exact release-asset name carrying the signed manifest.
  static const String manifestAssetName = 'update-manifest.json';

  /// Manifest layout this build understands. A higher `schema` is rejected so
  /// an old client never mis-reads a format it only partly supports.
  static const int manifestSchema = 1;

  /// Accepted signing keys, by id.
  ///
  /// Rotation: run `dart run tool/gen_update_key.dart --force`, bump the id,
  /// and add the new entry. Keep the previous entry until every client that
  /// trusts it has updated past it — dropping a key here immediately stops
  /// that key's older releases from offering an in-app update.
  static const Map<String, List<int>> trustedEd25519PublicKeys =
      <String, List<int>>{
    '2026-09': <int>[
      0x78, 0x10, 0xaf, 0x26, 0xa5, 0x74, 0xf9, 0x19, //
      0xe8, 0xde, 0x78, 0x00, 0xa0, 0x50, 0xeb, 0x8d, //
      0xb0, 0x28, 0x29, 0xfd, 0x3c, 0x46, 0x70, 0x3d, //
      0xd4, 0x84, 0x76, 0x92, 0xec, 0x36, 0xad, 0x13, //
    ],
  };

  /// Hosts a manifest may legitimately be fetched from.
  ///
  /// Defence in depth only: `package:http` follows up to five redirects, so a
  /// host check on the initial URL cannot constrain where the bytes end up.
  /// The signature is what actually establishes trust here.
  static bool isTrustedAssetHost(String host) {
    final h = host.toLowerCase();
    return h == 'github.com' ||
        h == 'api.github.com' ||
        h == 'objects.githubusercontent.com' ||
        h.endsWith('.githubusercontent.com');
  }
}
