import 'dart:io';

import 'package:flutter/services.dart';

/// Turns an exception into one short sentence a user can act on.
///
/// Raw exception text must never reach the UI. `PlatformException` carries
/// platform error codes, `FileSystemException` carries absolute paths, and
/// `SqfliteFfiException` carries SQL — none of which mean anything to the
/// person holding the phone. Callers log the error with `AppLogger` and show
/// the result of this function instead.
///
/// [fallback] is the caller's own plain-language description of what failed.
/// It is used whenever the error carries no signal worth surfacing, so every
/// call site still says something specific about the operation.
String userMessageFor(Object error, {required String fallback}) {
  if (error is PlatformException) {
    switch (error.code) {
      case 'read_external_storage_denied':
      case 'permission_denied':
      case 'storage_permission_denied':
        return 'Syndro needs permission to reach those files';
      case 'unknown_path':
      case 'invalid_path':
        return 'That location is no longer available';
      case 'multiple_request':
        return 'A file picker is already open';
      case 'channel-error':
        return 'The file picker is not available right now';
    }
    return fallback;
  }

  if (error is MissingPluginException) {
    return 'This is not available on this device';
  }

  if (error is FileSystemException) {
    return 'Could not read or write that file';
  }

  if (error is SocketException || error is HttpException) {
    return 'Could not reach the other device';
  }

  if (error is FormatException) {
    return 'That file could not be read';
  }

  return fallback;
}
