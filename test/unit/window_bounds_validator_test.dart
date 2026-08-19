import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:syndro/core/services/window_bounds_validator.dart';
import 'package:syndro/core/services/window_settings_service.dart';

void main() {
  group('WindowBoundsValidator.virtualScreen', () {
    test('unions multiple displays', () {
      const rects = [
        Rect.fromLTWH(-1920, 0, 1920, 1080),
        Rect.fromLTWH(0, 0, 2560, 1440),
      ];
      expect(
        WindowBoundsValidator.virtualScreen(rects),
        const Rect.fromLTRB(-1920, 0, 2560, 1440),
      );
    });

    test('empty list yields an empty rect', () {
      expect(WindowBoundsValidator.virtualScreen(const []), Rect.zero);
    });
  });

  group('WindowBoundsValidator.sanitize', () {
    const single = [Rect.fromLTWH(0, 0, 1920, 1080)];

    test('null input is rejected (center instead)', () {
      expect(WindowBoundsValidator.sanitize(null, single), isNull);
    });

    test('no displays to validate against is rejected', () {
      const bounds = WindowBounds(width: 1200, height: 800);
      expect(WindowBoundsValidator.sanitize(bounds, const []), isNull);
    });

    test('degenerate sizes are rejected', () {
      expect(
        WindowBoundsValidator.sanitize(
          const WindowBounds(width: 0, height: 0),
          single,
        ),
        isNull,
      );
      expect(
        WindowBoundsValidator.sanitize(
          const WindowBounds(width: -100, height: 800),
          single,
        ),
        isNull,
      );
      expect(
        WindowBoundsValidator.sanitize(
          const WindowBounds(width: 100, height: 100),
          single,
        ),
        isNull,
      );
      expect(
        WindowBoundsValidator.sanitize(
          const WindowBounds(width: double.nan, height: 800),
          single,
        ),
        isNull,
      );
      expect(
        WindowBoundsValidator.sanitize(
          const WindowBounds(width: 1200, height: double.infinity),
          single,
        ),
        isNull,
      );
    });

    test('off-screen positions are rejected', () {
      // To the right
      expect(
        WindowBoundsValidator.sanitize(
          const WindowBounds(width: 1200, height: 800, x: 2000, y: 200),
          single,
        ),
        isNull,
      );
      // To the left
      expect(
        WindowBoundsValidator.sanitize(
          const WindowBounds(width: 1200, height: 800, x: -1500, y: 200),
          single,
        ),
        isNull,
      );
      // Above
      expect(
        WindowBoundsValidator.sanitize(
          const WindowBounds(width: 1200, height: 800, x: 200, y: -900),
          single,
        ),
        isNull,
      );
      // Below
      expect(
        WindowBoundsValidator.sanitize(
          const WindowBounds(width: 1200, height: 800, x: 200, y: 1200),
          single,
        ),
        isNull,
      );
      // Non-finite coordinates
      expect(
        WindowBoundsValidator.sanitize(
          const WindowBounds(width: 1200, height: 800, x: double.nan, y: 200),
          single,
        ),
        isNull,
      );
    });

    test('valid on-screen position is kept', () {
      final result = WindowBoundsValidator.sanitize(
        const WindowBounds(width: 1200, height: 800, x: 100, y: 100),
        single,
      );
      expect(result, isNotNull);
      expect(result!.x, 100);
      expect(result.y, 100);
      expect(result.width, 1200);
    });

    test('positionless (centered) bounds are kept', () {
      final result = WindowBoundsValidator.sanitize(
        const WindowBounds(width: 1200, height: 800),
        single,
      );
      expect(result, isNotNull);
      expect(result!.x, isNull);
      expect(result.y, isNull);
    });

    test('maximized keeps the flag and drops stale coordinates', () {
      final result = WindowBoundsValidator.sanitize(
        const WindowBounds(
          width: 1200,
          height: 800,
          x: 99999,
          y: -88888,
          maximized: true,
        ),
        single,
      );
      expect(result, isNotNull);
      expect(result!.maximized, isTrue);
      expect(result.x, isNull);
      expect(result.y, isNull);
    });

    test('window on a second (left) display is kept', () {
      const rects = [
        Rect.fromLTWH(0, 0, 1920, 1080),
        Rect.fromLTWH(-1920, 0, 1920, 1080),
      ];
      final result = WindowBoundsValidator.sanitize(
        const WindowBounds(width: 1200, height: 800, x: -1800, y: 100),
        rects,
      );
      expect(result, isNotNull);
      expect(result!.x, -1800);
      expect(result.y, 100);
    });

    test('title bar fully off-screen is rejected', () {
      // Window body would overlap the display bottom, but its title bar
      // starts below the screen — effectively unusable.
      final result = WindowBoundsValidator.sanitize(
        const WindowBounds(width: 1200, height: 800, x: 100, y: 1100),
        single,
      );
      expect(result, isNull);
    });
  });
}