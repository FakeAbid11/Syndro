import 'dart:async';
import 'dart:io';

/// Whether this process is the first (primary) instance or a duplicate.
enum SingleInstanceRole { primary, secondary }

/// Ensures only one app instance runs at a time.
///
/// The primary instance binds a loopback TCP listener. A second launch
/// detects the busy port, pings the primary with a probe byte to confirm it
/// is really a Syndro instance, asks it to show its window, and exits — so
/// clicking the shortcut again restores the already-running (possibly
/// tray-hidden) app instead of starting a conflicting duplicate process.
///
/// If the port happens to be held by an unrelated process, the probe gets no
/// answer and this instance proceeds as the primary rather than exiting.
class SingleInstanceGuard {
  SingleInstanceGuard(this.port);

  /// Probe byte sent by the secondary to the primary.
  static const int _probe = 1;

  /// Acknowledgment byte sent by the primary back to the secondary.
  static const int _ack = 2;

  final int port;

  ServerSocket? _server;
  Future<void> Function()? _onShowWindow;

  /// Binds the loopback listener. Returns [SingleInstanceRole.secondary]
  /// when another Syndro instance already holds the port (and signals it to
  /// show its window), otherwise [SingleInstanceRole.primary].
  Future<SingleInstanceRole> start({
    required Future<void> Function() onShowWindow,
  }) async {
    _onShowWindow = onShowWindow;
    try {
      _server = await ServerSocket.bind(
        InternetAddress.loopbackIPv4,
        port,
        shared: false,
      );
    } on SocketException {
      final confirmed = await _probeExisting();
      if (confirmed) {
        // Another Syndro instance is running — it now knows to show itself.
        return SingleInstanceRole.secondary;
      }
      // Unrelated process holds the port; continue as primary anyway.
      return SingleInstanceRole.primary;
    } catch (_) {
      return SingleInstanceRole.primary;
    }

    _server!.listen((socket) {
      // Acknowledge the probe so a launcher knows this is a Syndro instance,
      // then notify once the probe connection closes.
      try {
        socket.add([_ack]);
        socket.flush();
      } catch (_) {}
      socket.listen(
        (_) {},
        onDone: () {
          socket.destroy();
          _onShowWindow?.call();
        },
        onError: (_) {
          socket.destroy();
          _onShowWindow?.call();
        },
      );
    });

    return SingleInstanceRole.primary;
  }

  /// Connect to [port], send the probe, and wait for the acknowledgment.
  Future<bool> _probeExisting() async {
    try {
      final socket = await Socket.connect(
        InternetAddress.loopbackIPv4,
        port,
        timeout: const Duration(seconds: 2),
      );
      try {
        socket.add([_probe]);
        await socket.flush();
        final reply = await socket.first.timeout(const Duration(milliseconds: 500));
        return reply.isNotEmpty && reply.first == _ack;
      } catch (_) {
        return false;
      } finally {
        socket.destroy();
      }
    } catch (_) {
      return false;
    }
  }

  /// Release the listener. Only call when the process is about to exit.
  Future<void> dispose() async {
    try {
      await _server?.close();
    } catch (_) {}
    _server = null;
  }
}