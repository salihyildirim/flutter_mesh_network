import 'dart:async';

import 'package:uuid/uuid.dart';

import '../config.dart';
import '../logger.dart';
import '../models/enums.dart';
import '../models/mesh_message.dart';
import '../models/mesh_node.dart';
import '../storage/mesh_storage.dart';
import '../transport/transport.dart';
import '../transport/transport_selector.dart';

/// Core routing engine that ties transports, storage, and
/// flood-fill logic together.
///
/// This is an internal class — consumers interact with it through
/// [MeshNetwork].
class MeshRouter {
  MeshRouter({
    required MeshConfig config,
    required List<MeshTransport> transports,
    required MeshStorage storage,
    TransportSelector selector = const TransportSelector(),
  })  : _config = config,
        _transports = transports,
        _storage = storage,
        _selector = selector;

  final MeshConfig _config;
  final List<MeshTransport> _transports;
  final MeshStorage _storage;
  final TransportSelector _selector;
  static const _uuid = Uuid();

  String? _userId;
  TransportStrategy _strategy = TransportStrategy.balanced;
  TransportStrategy? _preEmergencyStrategy;
  double? _batteryLevel;

  final _nodes = <String, MeshNode>{};
  final _forwardQueue = <MeshMessage>[];

  final _messageStream = StreamController<MeshMessage>.broadcast();
  final _nodeStream = StreamController<MeshNode>.broadcast();

  final _subscriptions = <StreamSubscription>[];
  Timer? _forwardTimer;
  Timer? _cleanupTimer;

  Stream<MeshMessage> get messages => _messageStream.stream;
  Stream<MeshNode> get nodes => _nodeStream.stream;
  Map<String, MeshNode> get knownNodes => Map.unmodifiable(_nodes);

  int get onlineNodeCount =>
      _nodes.values.where((n) => n.isOnline()).length;

  // ---------------------------------------------------------------------------
  // Lifecycle
  // ---------------------------------------------------------------------------

  Future<void> start(String userId) async {
    _userId = userId;
    _strategy = _config.strategy;

    // Subscribe to every transport's event streams.
    for (final t in _transports) {
      _subscriptions
        ..add(t.messages.listen(_handleIncoming))
        ..add(t.nodes.listen(_handleNodeDiscovered));
    }

    // Restore persisted nodes.
    final saved = await _storage.getAllNodes();
    for (final n in saved) {
      _nodes[n.id] = n;
    }

    // Periodic forward-queue processing.
    final interval = _selector.scanInterval(_strategy, _batteryLevel);
    _forwardTimer = Timer.periodic(interval, (_) => _processForwardQueue());

    // Periodic cleanup.
    _cleanupTimer = Timer.periodic(
      const Duration(minutes: 30),
      (_) => _cleanup(),
    );

    MeshLogger.mesh('Router started (${_transports.length} transports)');
  }

  Future<void> stop() async {
    for (final sub in _subscriptions) {
      await sub.cancel();
    }
    _subscriptions.clear();
    _forwardTimer?.cancel();
    _cleanupTimer?.cancel();
    _forwardQueue.clear();
    MeshLogger.mesh('Router stopped');
  }

  bool _disposed = false;

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await stop();
    _messageStream.close();
    _nodeStream.close();
  }

  // ---------------------------------------------------------------------------
  // Strategy
  // ---------------------------------------------------------------------------

  void setStrategy(TransportStrategy strategy) {
    _forwardTimer?.cancel();
    _strategy = strategy;
    final interval = _selector.scanInterval(_strategy, _batteryLevel);
    _forwardTimer = Timer.periodic(interval, (_) => _processForwardQueue());
    MeshLogger.mesh('Strategy changed to ${strategy.name}');
  }

  void setBatteryLevel(double level) {
    _batteryLevel = level;
    // Reset forward timer — scan interval depends on battery level.
    _forwardTimer?.cancel();
    final interval = _selector.scanInterval(_strategy, _batteryLevel);
    _forwardTimer = Timer.periodic(interval, (_) => _processForwardQueue());
  }

  // ---------------------------------------------------------------------------
  // Outgoing
  // ---------------------------------------------------------------------------

  Future<MeshMessage> sendText(
    String text,
    String senderName, {
    String? targetId,
  }) async {
    final msg = _createMessage(
      type: MessageType.text,
      priority: MessagePriority.normal,
      payload: text,
      senderName: senderName,
      targetId: targetId,
      ttl: _config.messageTtl,
    );
    await _dispatch(msg);
    return msg;
  }

  Future<MeshMessage> sendSos(
    String senderName,
    double latitude,
    double longitude,
  ) async {
    if (_strategy != TransportStrategy.emergency) {
      _preEmergencyStrategy = _strategy;
    }
    _strategy = TransportStrategy.emergency;
    final msg = _createMessage(
      type: MessageType.sos,
      priority: MessagePriority.critical,
      payload: 'SOS',
      senderName: senderName,
      latitude: latitude,
      longitude: longitude,
      ttl: _config.sosTtl,
    );
    await _dispatch(msg);
    return msg;
  }

  /// Reverts the transport strategy from [TransportStrategy.emergency]
  /// back to the strategy that was active before [sendSos] was called.
  /// If there was no prior strategy, falls back to the config default.
  void cancelSos() {
    if (_strategy != TransportStrategy.emergency) return;
    final restored = _preEmergencyStrategy ?? _config.strategy;
    _preEmergencyStrategy = null;
    setStrategy(restored);
    MeshLogger.mesh('SOS cancelled, strategy reverted to ${restored.name}');
  }

  Future<void> broadcastLocation(
    String senderName,
    double latitude,
    double longitude,
  ) async {
    final msg = _createMessage(
      type: MessageType.beacon,
      priority: MessagePriority.low,
      payload: '',
      senderName: senderName,
      latitude: latitude,
      longitude: longitude,
      maxHops: 3,
      ttl: const Duration(minutes: 10),
    );

    // Also update transport-level advertised location.
    for (final t in _transports) {
      await t.updateLocation(latitude, longitude);
    }

    await _dispatch(msg);
  }

  // ---------------------------------------------------------------------------
  // Incoming
  // ---------------------------------------------------------------------------

  Future<void> _handleIncoming(MeshMessage message) async {
    if (await _storage.messageExists(message.id)) return;
    if (message.isExpired) return;

    await _storage.insertMessage(message);
    _messageStream.add(message);

    // Update node map from location-bearing messages.
    if (_isLocationBearing(message)) {
      _updateNodeFromMessage(message);
    }
    if (message.type == MessageType.sos) {
      _updateNodeFromMessage(message, status: NodeStatus.sos);
    }

    // Queue for forwarding if still alive.
    if (message.canForward && _userId != null) {
      _forwardQueue.add(message.forwarded(_userId!));
    }

    MeshLogger.mesh(
        'Received ${message.type.name} from ${message.senderName} '
        '(hop ${message.hopCount})');
  }

  void _handleNodeDiscovered(MeshNode node) {
    _nodes[node.id] = node;
    _nodeStream.add(node);
    _storage.upsertNode(node).catchError((e) {
      MeshLogger.error('Router', 'Failed to persist node', e);
    });
  }

  // ---------------------------------------------------------------------------
  // Dispatch & Flooding
  // ---------------------------------------------------------------------------

  Future<void> _dispatch(MeshMessage message) async {
    await _storage.insertMessage(message);
    _messageStream.add(message);
    await _flood(message);

    if (message.canForward) _forwardQueue.add(message);
  }

  Future<void> _flood(MeshMessage message) async {
    final types = _selector.select(
      message: message,
      strategy: _strategy,
      batteryLevel: _batteryLevel,
      bleAvailable: _transportActive(TransportType.ble),
      wifiDirectAvailable: _transportActive(TransportType.wifiDirect),
      nearbyAvailable: _transportActive(TransportType.nearby),
    );

    for (final type in types) {
      final transport = _transportFor(type);
      if (transport == null) continue;

      final forwarded =
          _userId != null ? message.forwarded(_userId!) : message;
      await transport.broadcast(forwarded);
    }
  }

  Future<void> _processForwardQueue() async {
    if (_forwardQueue.isEmpty) return;

    final batch = List<MeshMessage>.from(_forwardQueue);
    _forwardQueue.clear();
    batch.sort((a, b) => b.priority.index.compareTo(a.priority.index));

    for (final msg in batch) {
      if (msg.canForward && !msg.isExpired) {
        await _flood(msg);
      }
    }
  }

  Future<void> _cleanup() async {
    await _storage.deleteExpiredMessages();
    await _storage.deleteStaleNodes();
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  MeshMessage _createMessage({
    required MessageType type,
    required MessagePriority priority,
    required String payload,
    required String senderName,
    String? targetId,
    double? latitude,
    double? longitude,
    int? maxHops,
    required Duration ttl,
  }) {
    final now = DateTime.now();
    return MeshMessage(
      id: _uuid.v4(),
      senderId: _userId!,
      senderName: senderName,
      targetId: targetId,
      type: type,
      priority: priority,
      payload: payload,
      latitude: latitude,
      longitude: longitude,
      maxHops: maxHops ?? _config.maxHops,
      createdAt: now,
      expiresAt: now.add(ttl),
      visitedNodes: [_userId!],
    );
  }

  bool _isLocationBearing(MeshMessage m) =>
      (m.type == MessageType.beacon || m.type == MessageType.location) &&
      m.latitude != null &&
      m.longitude != null;

  void _updateNodeFromMessage(MeshMessage msg, {NodeStatus? status}) {
    final node = MeshNode(
      id: msg.senderId,
      name: msg.senderName,
      status: status ?? NodeStatus.active,
      latitude: msg.latitude,
      longitude: msg.longitude,
      lastSeen: DateTime.now(),
    );
    _handleNodeDiscovered(node);
  }

  bool _transportActive(TransportType type) =>
      _transports.any((t) => t.type == type && t.isActive);

  MeshTransport? _transportFor(TransportType type) {
    for (final t in _transports) {
      if (t.type == type) return t;
    }
    return null;
  }
}
