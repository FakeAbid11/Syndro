import 'package:flutter_test/flutter_test.dart';
import 'package:syndro/core/services/sound_service.dart';

void main() {
  group('SoundService', () {
    test('should be a singleton', () {
      final instance1 = SoundService();
      final instance2 = SoundService();
      expect(identical(instance1, instance2), isTrue);
    });

    test('playRequestSound should not throw', () async {
      // On test platform (no real OS), this should gracefully fail
      // without throwing an exception
      await SoundService().playRequestSound();
    });

    test('playCompleteSound should not throw', () async {
      await SoundService().playCompleteSound();
    });
  });
}
