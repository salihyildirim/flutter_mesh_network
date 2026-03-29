import 'dart:async';

import 'package:flutter/services.dart';

import '../config.dart';
import '../logger.dart';
import '../models/enums.dart';
import '../models/mesh_message.dart';
import '../models/mesh_node.dart';
import 'transport.dart';

/// Nearby transport layer.
///
/// On **Android** this delegates to Wi-Fi Aware (NAN).
/// On **iOS** this delegates to MultipeerConnectivity (MPC).
///
/// Both are accessed through the same [MethodChannel] so the Dart
/// code is completely platform-agnostic — the native plugin decides
/// which API to use.
class NearbyTransport implements MeshTransport {
  NearbyTransport(this._config);

  static const _channel = MethodChannel('flutter_mesh_network/nearby');

  final MeshConfig _config;
  final _messages = StreamController<MeshMessage>.broadcast();
  final _nodes = StreamController<MeshNode>.broadcast();

  bool _available = false;
  bool _publishing = false;
  bool _subscribing = false;

  // ---------------------------------------------------------------------------
  // MeshTransport
  // ---------------------------------------------------------------------------

  @override
  TransportType get type => TransportType.nearby;

  @override
  bool get isActive => _publishing || _subscribing;

  @override
  Stream<MeshMessage> get messages => _messages.stream;

  @override
  Stream<MeshNode> get nodes => _nodes.stream;

  /// Check hardware / OS support before calling [start].
  Future<bool> checkAvailability() async {
    try {
      _available =
          await _channel.invokeMethod<bool>('isAvailable') ?? false;
      MeshLogger.nearby(
          'Nearby ${_available ? "available" : "not available"}');
      return _available;
    } on MissingPluginException {
      MeshLogger.nearby('Nearby native plugin not found');
      _available = false;
      return false;
    } catch (e) {
      MeshLogger.error('Nearby', 'Availability check failed', e);
      _available = false;
      return false;
    }
  }

  @override
  Future<bool> start({
    required String userId,
    required String userName,
    double? latitude,
    double? longitude,
  }) async {
    if (!await checkAvailability()) return false;

    _channel.setMethodCallHandler(_handleNative);

    final pubResult = await _channel.invokeMethod<bool>('publish', {
      'serviceName': _config.serviceName,
      'userId': userId,
      'userName': userName,
      'latitude': latitude,
      'longitude': longitude,
    });
    _publishing = pubResult ?? false;

    final subResult = await _channel.invokeMethod<bool>('subscribe', {
      'serviceName': _config.serviceName,
    });
    _subscribing = subResult ?? false;

    MeshLogger.nearby(
        'Nearby started (pub: $_publishing, sub: $_subscribing)');
    return _publishing || _subscribing;
  }

  @override
  Future<bool> send(MeshMessage message, String peerId) async {
    if (!isActive) return false;
    try {
      return await _channel.invokeMethod<bool>('sendMessage', {
            'peerId': peerId,
            'data': message.encode(),
          }) ??
          false;
    } catch (e) {
      MeshLogger.error('Nearby', 'Send failed', e);
      return false;
    }
  }

  @override
  Future<int> broadcast(MeshMessage message) async {
    if (!isActive) return 0;
    try {
      final peers = await _channel.invokeMethod<List<dynamic>>('getPeers');
      if (peers == null || peers.isEmpty) return 0;

      var sent = 0;
      for (final peer in peers) {
        if (peer is! Map) continue;
        final id = peer['id'] as String?;
        if (id != null && await send(message, id)) sent++;
      }
      return sent;
    } catch (e) {
      MeshLogger.error('Nearby', 'Broadcast failed', e);
      return 0;
    }
  }

  @override
  Future<void> updateLocation(double latitude, double longitude) async {
    if (!isActive) return;
    try {
      await _channel.invokeMethod('updateLocation', {
        'latitude': latitude,
        'longitude': longitude,
      });
    } catch (e) {
      MeshLogger.error('Nearby', 'Location update failed', e);
    }
  }

  /// Measure distance to a peer via Wi-Fi RTT (Android only).
  /// Returns distance in meters, or `null` if unsupported / unavailable.
  Future<double?> measureDistance(String peerId) async {
    try {
      final mm = await _channel.invokeMethod<int>('measureDistance', {
        'peerId': peerId,
      });
      return mm != null && mm > 0 ? mm / 1000.0 : null;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> stop() async {
    try {
      if (_publishing) await _channel.invokeMethod('stopPublish');
      if (_subscribing) await _channel.invokeMethod('stopSubscribe');
    } catch (_) {}
    _publishing = false;
    _subscribing = false;
    MeshLogger.nearby('Nearby transport stopped');
  }

  @override
  Future<void> dispose() async {
    await stop();
    _channel.setMethodCallHandler(null);
    _messages.close();
    _nodes.close();
  }

  // ---------------------------------------------------------------------------
  // Native callbacks
  // ---------------------------------------------------------------------------

  Future<void> _handleNative(MethodCall call) async {
    switch (call.method) {
      case 'onPeerDiscovered':
        if (call.arguments is! Map) return;
        try {
          final args = Map<String, dynamic>.from(call.arguments as Map);
          _nodes.add(MeshNode.fromJson(args));
        } catch (e) {
          MeshLogger.error('Nearby', 'Peer parse failed', e);
        }

      case 'onMessageReceived':
        if (call.arguments is! String) return;
        try {
          _messages.add(MeshMessage.decode(call.arguments as String));
        } catch (e) {
          MeshLogger.error('Nearby', 'Message parse failed', e);
        }

      case 'onAvailabilityChanged':
        _available = call.arguments == true;
        if (!_available) {
          _publishing = false;
          _subscribing = false;
        }
        MeshLogger.nearby('Availability changed: $_available');
    }
  }
}
