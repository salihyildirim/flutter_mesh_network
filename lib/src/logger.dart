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

  static void ble(String message) => _log(message, name: 'mesh.ble');
  static void wifi(String message) => _log(message, name: 'mesh.wifi');
  static void nearby(String message) => _log(message, name: 'mesh.nearby');
  static void mesh(String message) => _log(message, name: 'mesh.core');
  static void storage(String message) => _log(message, name: 'mesh.storage');

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
