import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:syndro/core/services/single_instance_service.dart';

Future<int> _freePort() async {
  final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = server.port;
  await server.close();
  return port;
}

void main() {
  test('first instance on a free port is primary', () async {
    final port = await _freePort();
    final guard = SingleInstanceGuard(port);
    expect(
      await guard.start(onShowWindow: () async {}),
      SingleInstanceRole.primary,
    );
    await guard.dispose();
  });

  test('second instance is secondary and signals the primary', () async {
    final port = await _freePort();
    final shown = Completer<void>();

    final primary = SingleInstanceGuard(port);
    expect(
      await primary.start(onShowWindow: () async {
        if (!shown.isCompleted) shown.complete();
      }),
      SingleInstanceRole.primary,
    );

    final secondary = SingleInstanceGuard(port);
    expect(
      await secondary.start(onShowWindow: () async {}),
      SingleInstanceRole.secondary,
    );

    // The probe from the secondary must have reached the primary.
    await shown.future.timeout(const Duration(seconds: 3));

    await primary.dispose();
    await secondary.dispose();
  });

  test('unrelated process on the port does not force this instance to exit',
      () async {
    final port = await _freePort();
    final holder = await ServerSocket.bind(InternetAddress.loopbackIPv4, port);

    final guard = SingleInstanceGuard(port);
    // The holder never answers the probe, so this instance proceeds as
    // primary rather than exiting.
    expect(
      await guard.start(onShowWindow: () async {}),
      SingleInstanceRole.primary,
    );

    await guard.dispose();
    await holder.close();
  });
}