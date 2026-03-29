import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../config.dart';
import '../logger.dart';
import '../models/enums.dart';
import '../models/mesh_message.dart';
import '../models/mesh_node.dart';
import 'transport.dart';

/// Wi-Fi Direct transport layer.
///
/// Uses a TCP socket server to accept incoming connections and a
/// map of outgoing sockets for sending.  Messages are delimited
/// by a double newline (`\n\n`).
class WifiDirectTransport implements MeshTransport {
  WifiDirectTransport(this._config);

  final MeshConfig _config;
  final _messages = StreamController<MeshMessage>.broadcast();
  final _nodes = StreamController<MeshNode>.broadcast();
  final _peers = <String, Socket>{}; // address → socket

  ServerSocket? _server;
  bool _running = false;

  @override
  TransportType get type => TransportType.wifiDirect;

  @override
  bool get isActive => _running;

  @override
  Stream<MeshMessage> get messages => _messages.stream;

  @override
  Stream<MeshNode> get nodes => _nodes.stream;

  @override
  Future<bool> start({
    required String userId,
    required String userName,
    double? latitude,
    double? longitude,
  }) async {
    if (_running) return true;

    try {
      _server = await ServerSocket.bind(
        InternetAddress.anyIPv4,
        _config.wifiDirectPort,
      );
      _running = true;

      _server!.listen(
        _handleClient,
        onError: (e) => MeshLogger.error('WiFi', 'Server error', e),
      );

      MeshLogger.wifi(
          'Wi-Fi Direct server listening on port ${_config.wifiDirectPort}');
      return true;
    } catch (e) {
      MeshLogger.error('WiFi', 'Server start failed', e);
      return false;
    }
  }

  @override
  Future<bool> send(MeshMessage message, String peerAddress) async {
    final frame = '${message.encode()}\n\n';
    try {
      var socket = _peers[peerAddress];

      if (socket != null) {
        try {
          socket.write(frame);
          await socket.flush();
          return true;
        } catch (_) {
          _peers.remove(peerAddress);
          try { await socket.close(); } catch (_) {}
        }
      }

      final fresh = await Socket.connect(
        peerAddress,
        _config.wifiDirectPort,
        timeout: const Duration(seconds: 5),
      );
      _peers[peerAddress] = fresh;
      fresh.write(frame);
      await fresh.flush();
      return true;
    } catch (e) {
      MeshLogger.error('WiFi', 'Send failed to $peerAddress', e);
      _peers.remove(peerAddress);
      return false;
    }
  }

  @override
  Future<int> broadcast(MeshMessage message) async {
    if (_peers.isEmpty) return 0;

    final encoded = '${message.encode()}\n\n';
    var count = 0;

    for (final entry in _peers.entries.toList()) {
      try {
        entry.value.write(encoded);
        await entry.value.flush();
        count++;
      } catch (e) {
        MeshLogger.error('WiFi', 'Broadcast failed to ${entry.key}', e);
        _peers.remove(entry.key);
      }
    }
    return count;
  }

  @override
  Future<void> updateLocation(double latitude, double longitude) async {
    // Wi-Fi Direct doesn't advertise location in service info.
    // Location is shared via beacon messages instead.
  }

  @override
  Future<void> stop() async {
    _running = false;
    for (final socket in _peers.values) {
      try {
        await socket.close();
      } catch (_) {}
    }
    _peers.clear();

    try {
      await _server?.close();
    } catch (_) {}
    _server = null;

    MeshLogger.wifi('Wi-Fi Direct transport stopped');
  }

  @override
  Future<void> dispose() async {
    await stop();
    _messages.close();
    _nodes.close();
  }

  // ---------------------------------------------------------------------------
  // Private
  // ---------------------------------------------------------------------------

  void _handleClient(Socket client) {
    final address = client.remoteAddress.address;
    _peers[address] = client;
    MeshLogger.wifi('Peer connected: $address');

    final buffer = StringBuffer();

    client.listen(
      (data) {
        buffer.write(utf8.decode(data));
        _processBuffer(buffer, address);
      },
      onDone: () {
        _peers.remove(address);
        MeshLogger.wifi('Peer disconnected: $address');
      },
      onError: (e) {
        _peers.remove(address);
        MeshLogger.error('WiFi', 'Client error ($address)', e);
      },
    );
  }

  void _processBuffer(StringBuffer buffer, String address) {
    final content = buffer.toString();
    final parts = content.split('\n\n');

    // The last element is either empty (complete message) or a partial.
    // Keep the partial in the buffer.
    if (parts.length <= 1) return;

    buffer.clear();
    buffer.write(parts.last); // keep partial

    for (var i = 0; i < parts.length - 1; i++) {
      final raw = parts[i].trim();
      if (raw.isEmpty) continue;
      try {
        _messages.add(MeshMessage.decode(raw));
      } catch (e) {
        MeshLogger.error('WiFi', 'Message parse failed', e);
      }
    }
  }
}
