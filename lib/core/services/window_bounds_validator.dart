import 'dart:math';
import 'dart:ui';

import 'window_settings_service.dart';

/// Sanitizes previously saved window bounds against the current display
/// layout so the window can never be restored off-screen, with a degenerate
/// size, or with a position the user cannot reach (e.g. saved on a monitor
/// that is no longer connected).
class WindowBoundsValidator {
  WindowBoundsValidator._();

  static const double _minWidth = 800;
  static const double _minHeight = 600;

  /// The bounding rectangle of all [displayBounds] (logical pixels).
  static Rect virtualScreen(List<Rect> displayBounds) {
    if (displayBounds.isEmpty) return Rect.zero;
    var minX = displayBounds.first.left;
    var minY = displayBounds.first.top;
    var maxX = displayBounds.first.right;
    var maxY = displayBounds.first.bottom;
    for (final display in displayBounds.skip(1)) {
      minX = min(minX, display.left);
      minY = min(minY, display.top);
      maxX = max(maxX, display.right);
      maxY = max(maxY, display.bottom);
    }
    return Rect.fromLTRB(minX, minY, maxX, maxY);
  }

  /// Validates [bounds] against [displayBounds].
  ///
  /// Returns the bounds to restore, or `null` when the window should be
  /// centered instead (no saved bounds, off-screen position, degenerate or
  /// non-finite size, or no displays to validate against).
  static WindowBounds? sanitize(
    WindowBounds? bounds,
    List<Rect> displayBounds,
  ) {
    if (bounds == null) return null;

    final width = bounds.width;
    final height = bounds.height;
    if (!width.isFinite || !height.isFinite) return null;
    if (width < _minWidth || height < _minHeight) return null;

    if (displayBounds.isEmpty) return null;
    final screen = virtualScreen(displayBounds);
    if (screen.isEmpty) return null;

    // A maximized window is positioned by the OS — keep the flag but drop any
    // stale coordinates so we never setPosition() over the maximize state.
    if (bounds.maximized) {
      return WindowBounds(
        width: width,
        height: height,
        x: null,
        y: null,
        maximized: true,
      );
    }

    if (bounds.x != null && bounds.y != null) {
      final x = bounds.x!;
      final y = bounds.y!;
      if (!x.isFinite || !y.isFinite) return null;

      // The title bar must be reachable: require its region to intersect at
      // least one display, otherwise the window is effectively invisible.
      final titleBar = Rect.fromLTWH(
        x,
        y,
        min(width, 200),
        min(height, 40),
      );
      var reachable = false;
      for (final display in displayBounds) {
        if (display.overlaps(titleBar)) {
          reachable = true;
          break;
        }
      }
      if (!reachable) return null;
    }

    return bounds;
  }
}