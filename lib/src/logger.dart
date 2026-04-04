import 'dart:developer' as dev;

/// Structured logger for the mesh network library.
///
/// All output goes through `dart:developer` so it appears in
/// the IDE console and can be filtered by [name].
/// Logging is gated by [enabled]; set to `false` in production
/// or via [MeshConfig.enableLogging].
class MeshLogger {
  MeshLogger._();

  /// Master switch.  When `false`, all log calls are no-ops.
  static bool enabled = true;

  /// Logs a BLE transport message.
  static void ble(String message) => _log(message, name: 'mesh.ble');

  /// Logs a Wi-Fi Direct transport message.
  static void wifi(String message) => _log(message, name: 'mesh.wifi');

  /// Logs a Nearby (Wi-Fi Aware / MultipeerConnectivity) transport message.
  static void nearby(String message) => _log(message, name: 'mesh.nearby');

  /// Logs a core mesh routing message.
  static void mesh(String message) => _log(message, name: 'mesh.core');

  /// Logs a storage layer message.
  static void storage(String message) => _log(message, name: 'mesh.storage');

  /// Logs an error with the given [tag] and optional [error] object.
  static void error(String tag, String message, [Object? error]) {
    if (!enabled) return;
    dev.log(
      '[$tag] $message',
      name: 'mesh.error',
      error: error,
      level: 1000,
    );
  }

  static void _log(String message, {required String name}) {
    if (!enabled) return;
    dev.log(message, name: name);
  }
}
