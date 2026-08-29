import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/app_settings_service.dart';

/// Singleton [AppSettingsService] so screens never construct it directly.
final appSettingsServiceProvider = Provider<AppSettingsService>((ref) {
  return AppSettingsService();
});

/// Backs the "Auto-accept from trusted devices" settings switch.
class AutoAcceptTrustedNotifier extends StateNotifier<bool> {
  AutoAcceptTrustedNotifier(this._service) : super(false);

  final AppSettingsService _service;

  Future<void> load() async {
    try {
      state = await _service.getAutoAcceptTrusted();
    } catch (_) {
      state = false;
    }
  }

  Future<void> set(bool value) async {
    await _service.setAutoAcceptTrusted(value);
    state = value;
  }
}

final autoAcceptTrustedProvider =
    StateNotifierProvider<AutoAcceptTrustedNotifier, bool>((ref) {
  final notifier = AutoAcceptTrustedNotifier(
    ref.watch(appSettingsServiceProvider),
  );
  notifier.load();
  return notifier;
});