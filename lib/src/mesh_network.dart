import 'dart:async';

import 'config.dart';
import 'logger.dart';
import 'models/enums.dart';
import 'models/mesh_message.dart';
import 'models/mesh_node.dart';
import 'routing/mesh_router.dart';
import 'storage/mesh_storage.dart';
import 'transport/ble_transport.dart';
import 'transport/nearby_transport.dart';
import 'transport/transport.dart';
import 'transport/wifi_direct_transport.dart';

/// The main entry point for the Flutter Mesh Network library.
///
/// Create an instance, call [start], and you have a fully functional
/// offline mesh network.  Messages, SOS signals, and location beacons
/// are routed automatically via BLE, Wi-Fi Direct, and
/// Wi-Fi Aware (Android) / MultipeerConnectivity (iOS).
///
/// ## Quick start
///
/// ```dart
/// final mesh = MeshNetwork();
///
/// // Listen for incoming messages.
/// mesh.onMessage.listen((msg) {
///   print('${msg.senderName}: ${msg.payload}');
/// });
///
/// // Start the mesh.
/// await mesh.start(userId: 'abc-123', userName: 'Ahmet');
///
/// // Send a text message.
/// await mesh.sendText('Bina girişindeyim');
///
/// // Send SOS with location.
/// await mesh.sendSos(latitude: 39.93, longitude: 32.85);
///
/// // Clean up.
/// mesh.dispose();
/// ```
class MeshNetwork {
  /// Creates a mesh network instance with the given [config].
  ///
  /// Nothing happens until [start] is called.
  MeshNetwork({MeshConfig config = const MeshConfig()})
      : _config = config,
        _storage = MeshStorage(config) {
    MeshLogger.enabled = config.enableLogging;

    _transports = [
      BleTransport(config),
      WifiDirectTransport(config),
      NearbyTransport(config),
    ];

    _router = MeshRouter(
      config: config,
      transports: _transports,
      storage: _storage,
    );
  }

  final MeshConfig _config;
  final MeshStorage _storage;
  late final List<MeshTransport> _transports;
  late final MeshRouter _router;

  String? _userName;
  bool _running = false;

  // ---------------------------------------------------------------------------
  // Public API — state
  // ---------------------------------------------------------------------------

  /// Whether the mesh network is currently running.
  bool get isRunning => _running;

  /// The number of peers currently considered online.
  int get onlineNodeCount => _router.onlineNodeCount;

  /// All known nodes, keyed by their id.
  Map<String, MeshNode> get knownNodes => _router.knownNodes;

  /// The current configuration.
  MeshConfig get config => _config;

  // ---------------------------------------------------------------------------
  // Public API — streams
  // ---------------------------------------------------------------------------

  /// Emits every message received or sent through the mesh.
  Stream<MeshMessage> get onMessage => _router.messages;

  /// Emits whenever a peer node is discovered or updated.
  Stream<MeshNode> get onNodeChanged => _router.nodes;

  // ---------------------------------------------------------------------------
  // Public API — lifecycle
  // ---------------------------------------------------------------------------

  /// Start the mesh network.
  ///
  /// Activates all available transports and begins discovering peers.
  /// [userId] should be a stable, unique identifier for this device.
  /// [userName] is the human-readable display name.
  Future<void> start({
    required String userId,
    required String userName,
    double? latitude,
    double? longitude,
  }) async {
    if (_running) return;

    _userName = userName;
    MeshLogger.mesh('Starting mesh network as $userName...');

    try {
      for (final transport in _transports) {
        await transport.start(
          userId: userId,
          userName: userName,
          latitude: latitude,
          longitude: longitude,
        );
      }

      await _router.start(userId);
      _running = true;
      MeshLogger.mesh('Mesh network active');
    } catch (e) {
      // Rollback on partial failure.
      _running = true; // allow stop() to proceed
      await stop();
      rethrow;
    }
  }

  /// Stop the mesh network and all transports.
  Future<void> stop() async {
    if (!_running) return;
    _running = false;

    await _router.stop();
    for (final transport in _transports) {
      await transport.stop();
    }

    MeshLogger.mesh('Mesh network stopped');
  }

  /// Release all resources.  The instance cannot be reused after this.
  Future<void> dispose() async {
    await stop();
    _router.dispose();
    for (final transport in _transports) {
      await transport.dispose();
    }
    await _storage.close();
  }

  // ---------------------------------------------------------------------------
  // Public API — messaging
  // ---------------------------------------------------------------------------

  /// Send a text message to all peers, or to a specific [targetId].
  Future<MeshMessage> sendText(String text, {String? targetId}) {
    _ensureRunning();
    return _router.sendText(text, _userName!, targetId: targetId);
  }

  /// Send an SOS distress signal with the user's current position.
  ///
  /// This switches the transport strategy to [TransportStrategy.emergency]
  /// and uses all available transports to maximize reach.
  Future<MeshMessage> sendSos({
    required double latitude,
    required double longitude,
  }) {
    assert(latitude >= -90 && latitude <= 90);
    assert(longitude >= -180 && longitude <= 180);
    _ensureRunning();
    return _router.sendSos(_userName!, latitude, longitude);
  }

  /// Broadcast the user's current location as a beacon.
  Future<void> broadcastLocation({
    required double latitude,
    required double longitude,
  }) {
    assert(latitude >= -90 && latitude <= 90);
    assert(longitude >= -180 && longitude <= 180);
    _ensureRunning();
    return _router.broadcastLocation(_userName!, latitude, longitude);
  }

  // ---------------------------------------------------------------------------
  // Public API — configuration
  // ---------------------------------------------------------------------------

  /// Change the transport strategy at runtime.
  void setStrategy(TransportStrategy strategy) {
    _router.setStrategy(strategy);
  }

  /// Cancel an active SOS and revert to the previous transport strategy.
  void cancelSos() {
    _router.cancelSos();
  }

  /// Inform the library of the device's current battery level
  /// (0.0 – 1.0) so it can adjust transport usage.
  void setBatteryLevel(double level) {
    _router.setBatteryLevel(level);
  }

  // ---------------------------------------------------------------------------
  // Public API — storage
  // ---------------------------------------------------------------------------

  /// Retrieve persisted messages from the local database.
  Future<List<MeshMessage>> getMessages({int limit = 100}) {
    return _storage.getMessages(limit: limit);
  }

  /// Retrieve all known nodes from the local database.
  Future<List<MeshNode>> getNodes() {
    return _storage.getAllNodes();
  }

  // ---------------------------------------------------------------------------
  // Private
  // ---------------------------------------------------------------------------

  void _ensureRunning() {
    if (!_running || _userName == null) {
      throw StateError(
        'MeshNetwork is not running. Call start() first.',
      );
    }
  }
}
