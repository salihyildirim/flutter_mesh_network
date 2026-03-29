import 'models/enums.dart';

/// Configuration for a [MeshNetwork] instance.
///
/// All values have sensible defaults for search-and-rescue scenarios.
/// Override individual fields via [copyWith] to tune for your use case.
///
/// ```dart
/// final config = MeshConfig(
///   serviceName: 'my-app',
///   maxHops: 5,
///   strategy: TransportStrategy.maxPerformance,
/// );
/// ```
class MeshConfig {
  // ---------------------------------------------------------------------------
  // Identity
  // ---------------------------------------------------------------------------

  /// Bonjour / NSD service name.  Must be ≤ 15 characters,
  /// lowercase alphanumeric + hyphens only (required by MPC / NSD).
  final String serviceName;

  // ---------------------------------------------------------------------------
  // BLE
  // ---------------------------------------------------------------------------

  /// GATT service UUID used for mesh communication.
  final String bleServiceUuid;

  /// GATT characteristic UUID for writing messages (client → server).
  final String bleTxCharUuid;

  /// GATT characteristic UUID for receiving messages (server → client).
  final String bleRxCharUuid;

  /// Duration of a single BLE scan pass.
  final Duration bleScanDuration;

  /// Interval between consecutive BLE scan passes.
  final Duration bleRescanInterval;

  // ---------------------------------------------------------------------------
  // Wi-Fi Direct
  // ---------------------------------------------------------------------------

  /// TCP port for Wi-Fi Direct socket server.
  final int wifiDirectPort;

  // ---------------------------------------------------------------------------
  // Mesh routing
  // ---------------------------------------------------------------------------

  /// Maximum number of hops a message can traverse.
  final int maxHops;

  /// Time-to-live for regular messages.
  final Duration messageTtl;

  /// Time-to-live for SOS messages (typically longer).
  final Duration sosTtl;

  /// How often the local node broadcasts its position.
  final Duration locationBroadcastInterval;

  /// Initial transport strategy.
  final TransportStrategy strategy;

  // ---------------------------------------------------------------------------
  // Storage
  // ---------------------------------------------------------------------------

  /// SQLite database file name.
  final String databaseName;

  /// Duration after which stale nodes are purged from the database.
  final Duration staleNodeThreshold;

  // ---------------------------------------------------------------------------
  // Logging
  // ---------------------------------------------------------------------------

  /// When `true`, the library prints structured logs via `dart:developer`.
  final bool enableLogging;

  const MeshConfig({
    this.serviceName = 'mesh-net',
    this.bleServiceUuid = '6e400001-b5a3-f393-e0a9-e50e24dcca9e',
    this.bleTxCharUuid = '6e400002-b5a3-f393-e0a9-e50e24dcca9e',
    this.bleRxCharUuid = '6e400003-b5a3-f393-e0a9-e50e24dcca9e',
    this.bleScanDuration = const Duration(seconds: 10),
    this.bleRescanInterval = const Duration(seconds: 30),
    this.wifiDirectPort = 8765,
    this.maxHops = 10,
    this.messageTtl = const Duration(hours: 6),
    this.sosTtl = const Duration(hours: 24),
    this.locationBroadcastInterval = const Duration(seconds: 30),
    this.strategy = TransportStrategy.balanced,
    this.databaseName = 'mesh_network.db',
    this.staleNodeThreshold = const Duration(days: 7),
    this.enableLogging = true,
  })  : assert(serviceName.length <= 15,
            'serviceName must be ≤ 15 characters (required by MPC / NSD)'),
        assert(maxHops > 0, 'maxHops must be greater than 0'),
        assert(wifiDirectPort >= 1 && wifiDirectPort <= 65535,
            'wifiDirectPort must be in the range 1–65535');

  MeshConfig copyWith({
    String? serviceName,
    String? bleServiceUuid,
    String? bleTxCharUuid,
    String? bleRxCharUuid,
    Duration? bleScanDuration,
    Duration? bleRescanInterval,
    int? wifiDirectPort,
    int? maxHops,
    Duration? messageTtl,
    Duration? sosTtl,
    Duration? locationBroadcastInterval,
    TransportStrategy? strategy,
    String? databaseName,
    Duration? staleNodeThreshold,
    bool? enableLogging,
  }) {
    return MeshConfig(
      serviceName: serviceName ?? this.serviceName,
      bleServiceUuid: bleServiceUuid ?? this.bleServiceUuid,
      bleTxCharUuid: bleTxCharUuid ?? this.bleTxCharUuid,
      bleRxCharUuid: bleRxCharUuid ?? this.bleRxCharUuid,
      bleScanDuration: bleScanDuration ?? this.bleScanDuration,
      bleRescanInterval: bleRescanInterval ?? this.bleRescanInterval,
      wifiDirectPort: wifiDirectPort ?? this.wifiDirectPort,
      maxHops: maxHops ?? this.maxHops,
      messageTtl: messageTtl ?? this.messageTtl,
      sosTtl: sosTtl ?? this.sosTtl,
      locationBroadcastInterval:
          locationBroadcastInterval ?? this.locationBroadcastInterval,
      strategy: strategy ?? this.strategy,
      databaseName: databaseName ?? this.databaseName,
      staleNodeThreshold: staleNodeThreshold ?? this.staleNodeThreshold,
      enableLogging: enableLogging ?? this.enableLogging,
    );
  }
}
