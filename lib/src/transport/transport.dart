import '../models/enums.dart';
import '../models/mesh_message.dart';
import '../models/mesh_node.dart';

/// Contract that every transport layer must implement.
///
/// The mesh router is transport-agnostic: it calls [send] and
/// [broadcast], and listens to [messages] and [nodes].
/// Each concrete implementation handles the underlying protocol
/// (BLE, Wi-Fi Direct, Wi-Fi Aware / MPC).
abstract class MeshTransport {
  /// Which transport layer this implementation represents.
  TransportType get type;

  /// Whether this transport is currently operational.
  bool get isActive;

  /// Stream of messages received from remote peers.
  Stream<MeshMessage> get messages;

  /// Stream of newly discovered or updated peer nodes.
  Stream<MeshNode> get nodes;

  /// Start the transport layer (advertising, scanning, listening).
  Future<bool> start({
    required String userId,
    required String userName,
    double? latitude,
    double? longitude,
  });

  /// Send [message] to a specific peer identified by [peerId].
  /// Returns `true` if delivery was acknowledged.
  Future<bool> send(MeshMessage message, String peerId);

  /// Broadcast [message] to all reachable peers.
  /// Returns the number of peers the message was dispatched to.
  Future<int> broadcast(MeshMessage message);

  /// Update the locally advertised position.
  Future<void> updateLocation(double latitude, double longitude);

  /// Tear down the transport layer.
  Future<void> stop();

  /// Release all resources.  Must be called when the transport
  /// is no longer needed.
  Future<void> dispose();
}
