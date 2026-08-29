import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../../utils/app_logger.dart';

/// Streaming multipart/form-data parser.
///
/// Reads an already-spooled upload body file in bounded windows and hands each
/// file part's bytes to the caller as they are scanned, so neither the whole
/// body nor any single part is ever fully resident in memory.
///
/// Wire format (RFC 7578, as produced by browsers):
/// ```
/// --boundary\r\n
/// Content-Disposition: form-data; name="files"; filename="a.png"\r\n
/// \r\n
/// <part data>\r\n
/// --boundary\r\n
/// ...
/// \r\n--boundary--\r\n
/// ```
class StreamingMultipartParser {
  /// Sliding-window size (bytes of the body kept in memory at once).
  static const int windowSize = 256 * 1024;

  /// Hard cap on a single part's header block (guards malformed bodies).
  static const int _maxHeaderBytes = 64 * 1024;

  /// Parses [bodyFile] and returns the number of file parts the caller
  /// accepted (parts with a filename whose [onPartStart] returned non-null).
  ///
  /// Callbacks:
  /// - [onPartStart]: a part with [filename] is beginning. Return a state
  ///   object to receive its data, or `null` to ignore the part entirely.
  /// - [onPartData]: successive slices of that part's data. Once the part's
  ///   total exceeds [maxPartBytes] the remaining bytes are discarded (the
  ///   scanner stays aligned) and [onPartData] is not called again.
  /// - [onPartEnd]: the part finished. [bytesSeen] is the full data size and
  ///   [skipped] is `true` when it exceeded [maxPartBytes] mid-stream (the
  ///   receiver should discard anything it wrote for that part). [state] is
  ///   `null` for parts the caller ignored in [onPartStart].
  static Future<int> parseFile<T>({
    required File bodyFile,
    required String boundary,
    required T? Function(String filename) onPartStart,
    required Future<void> Function(T? state, List<int> chunk) onPartData,
    required Future<void> Function(
            T? state, String filename, int bytesSeen, bool skipped)
        onPartEnd,
    int maxPartBytes = 5 * 1024 * 1024 * 1024,
  }) async {
    final delimiter = utf8.encode('\r\n--$boundary');
    final opener = utf8.encode('--$boundary');
    final crlfCrLf = utf8.encode('\r\n\r\n');

    // ── Sliding window over the body ──
    final buffer = <int>[];
    var start = 0; // consumed prefix length inside [buffer]
    var eof = false;
    final iterator = StreamIterator<List<int>>(bodyFile.openRead());

    /// Grow [buffer] until at least [needed] unconsumed bytes exist.
    Future<void> ensure(int needed) async {
      while (!eof && buffer.length - start < needed) {
        if (await iterator.moveNext()) {
          buffer.addAll(iterator.current);
        } else {
          eof = true;
        }
      }
    }

    /// Drop the consumed prefix once it grows past a window (bounds memory).
    void compact() {
      if (start > windowSize) {
        buffer.removeRange(0, start);
        start = 0;
      }
    }

    /// Find [pattern] fully inside buffer[fromAbs, endAbs). First-byte gated
    /// so the average cost is ~one comparison per body byte.
    int find(List<int> pattern, int fromAbs, int endAbs) {
      final lastStart = endAbs - pattern.length;
      for (var i = fromAbs; i <= lastStart; i++) {
        if (buffer[i] != pattern[0]) continue;
        var matched = true;
        for (var j = 1; j < pattern.length; j++) {
          if (buffer[i + j] != pattern[j]) {
            matched = false;
            break;
          }
        }
        if (matched) return i;
      }
      return -1;
    }

    /// Advance [start] past the next `\r\n--boundary`, discarding the bytes in
    /// between (used for non-file parts). Returns `false` at EOF.
    Future<bool> skipToNextDelimiter() async {
      while (true) {
        await ensure(windowSize);
        final d = find(delimiter, start, buffer.length);
        if (d != -1) {
          start = d + delimiter.length;
          compact();
          return true;
        }
        if (eof) return false;
        start = buffer.length - delimiter.length + 1;
        if (start < 0) start = 0;
        compact();
      }
    }

    var filePartCount = 0;

    try {
      // ── Phase 0: locate the opening boundary (skip any preamble) ──
      var openerAbs = -1;
      while (true) {
        await ensure(windowSize);
        openerAbs = find(opener, start, buffer.length);
        if (openerAbs != -1) break;
        if (eof) return 0; // no boundary at all → no parts
        // Keep a tail that could still hold a partial boundary.
        final keep = buffer.length - opener.length + 1;
        start = keep > start ? keep : start;
        compact();
      }
      start = openerAbs + opener.length;
      compact();

      // ── Part loop ──
      while (true) {
        // Peek the two bytes after a boundary: `--` = final, `\r\n` = part.
        await ensure(2);
        if (buffer.length - start < 2) break; // truncated body
        if (buffer[start] == 45 && buffer[start + 1] == 45) {
          break; // closing boundary reached
        }
        if (buffer[start] != 13 || buffer[start + 1] != 10) {
          // Malformed separator — resync on the next delimiter.
          start += 1;
          compact();
          if (!await skipToNextDelimiter()) return filePartCount;
          continue;
        }
        start += 2; // consume CRLF; headers begin here
        compact();

        // ── Headers (bounded) ──
        var headerEnd = -1;
        while (true) {
          final limit = start + _maxHeaderBytes;
          final searchEnd = buffer.length < limit ? buffer.length : limit;
          headerEnd = find(crlfCrLf, start, searchEnd);
          if (headerEnd != -1) break;
          if (eof || buffer.length >= limit) {
            AppLogger.warn(
                'Multipart: header block exceeds $_maxHeaderBytes bytes — aborting parse');
            return filePartCount;
          }
          await ensure(buffer.length - start + windowSize ~/ 2);
        }
        final headers =
            utf8.decode(buffer.sublist(start, headerEnd), allowMalformed: true);
        start = headerEnd + 4; // past \r\n\r\n
        compact();

        final filename = _extractFilename(headers);
        if (filename == null) {
          // Plain form field: skip its data without invoking callbacks.
          if (!await skipToNextDelimiter()) return filePartCount;
          continue;
        }

        final state = onPartStart(filename);
        if (state != null) filePartCount++;

        // ── Part data: stream to the caller until the next delimiter ──
        var partBytes = 0;
        var skipped = false;
        var dataStart = start;
        var closedCleanly = false;

        Future<void> emit(int fromAbs, int toAbs) async {
          final n = toAbs - fromAbs;
          if (n <= 0) return;
          final newTotal = partBytes + n;
          if (state != null && !skipped) {
            if (newTotal <= maxPartBytes) {
              await onPartData(state, buffer.sublist(fromAbs, toAbs));
            } else {
              final fit = maxPartBytes - partBytes;
              if (fit > 0) {
                await onPartData(state, buffer.sublist(fromAbs, fromAbs + fit));
              }
              skipped = true;
            }
          }
          partBytes = newTotal;
        }

        while (true) {
          await ensure(windowSize);
          final delimAbs = find(delimiter, dataStart, buffer.length);
          if (delimAbs != -1) {
            // The delimiter begins with the CRLF that terminates the data, so
            // the data runs up to — but not including — the match itself.
            await emit(dataStart, delimAbs);
            start = delimAbs + delimiter.length;
            closedCleanly = true;
            break;
          }
          if (eof) {
            // Truncated tail: accept what arrived (tolerant — the previous
            // in-memory parser also stopped at a missing boundary).
            await emit(dataStart, buffer.length);
            start = buffer.length;
            break;
          }
          // Flush everything except a possible partial-boundary tail.
          final safeEnd = buffer.length - delimiter.length + 1;
          if (safeEnd > dataStart) {
            await emit(dataStart, safeEnd);
            start = safeEnd;
          }
          compact();
          dataStart = start;
        }

        await onPartEnd(state, filename, partBytes, skipped);
        if (!closedCleanly) return filePartCount; // truncated body
        compact();
      }
      return filePartCount;
    } finally {
      await iterator.cancel();
    }
  }

  /// Extract the `filename` attribute from a raw header block, URL-decoded.
  /// Returns `null` when the part carries no filename (plain form field).
  static String? _extractFilename(String headers) {
    final match = RegExp(r'filename="([^"]+)"').firstMatch(headers);
    if (match == null) return null;
    var filename = match.group(1)!;
    try {
      filename = Uri.decodeComponent(filename);
    } catch (_) {
      // Keep the raw filename if decoding fails (same policy as before).
    }
    return filename;
  }
}