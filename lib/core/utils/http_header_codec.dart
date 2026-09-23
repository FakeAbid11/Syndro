/// HTTP header values are ASCII-only: `dart:io`'s `HttpHeaders.set` rejects any
/// code unit >= 128 with a `FormatException`, so a peer used to lose the whole
/// transfer when it met a file named `café.jpg`.
///
/// The exact name travels in a percent-encoded companion header; the legacy
/// header keeps a lossy ASCII rendering so peers predating this codec still
/// complete the transfer instead of throwing.
class HttpHeaderCodec {
  HttpHeaderCodec._();

  /// Header carrying the percent-encoded real name, paired with a legacy one.
  static const String fileNameEncodedHeader = 'x-file-name-enc';

  /// Wire-format version of [value] for a receiver that cannot decode [encoded].
  ///
  /// Never returns an empty string for non-empty input, because receivers
  /// reject an absent filename header outright.
  static String toAscii(String value) {
    final buffer = StringBuffer();
    for (final unit in value.codeUnits) {
      buffer.writeCharCode(unit >= 0x20 && unit <= 0x7E ? unit : 0x5F);
    }
    final ascii = buffer.toString();
    return ascii.isEmpty ? '_' : ascii;
  }

  /// Percent-encoded [value], safe to place in a header on any platform.
  static String encode(String value) => Uri.encodeComponent(value);

  /// The real filename, preferring the encoded header.
  ///
  /// Throws [FormatException] when [encoded] is present but not valid
  /// percent-encoding, so callers must reject the request before touching disk.
  static String decode({String? encoded, String? legacy}) {
    if (encoded != null && encoded.isNotEmpty) return Uri.decodeComponent(encoded);
    return legacy ?? '';
  }
}
