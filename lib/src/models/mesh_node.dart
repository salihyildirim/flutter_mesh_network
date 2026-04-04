import 'dart:math' as math;

import 'enums.dart';
import 'parse_helpers.dart';

/// A peer device discovered on the mesh network.
///
/// Nodes are identified by a unique [id] and carry metadata
/// such as position, signal strength, and connection type.
class MeshNode {
  /// Unique identifier for this node (typically the BLE remote id).
  final String id;

  /// Human-readable display name of this node.
  final String name;

  /// The role this node plays in the mesh (e.g. volunteer, medic).
  final NodeRole role;

  /// Current operational status of this node.
  final NodeStatus status;

  /// Last known latitude of this node, if available.
  final double? latitude;

  /// Last known longitude of this node, if available.
  final double? longitude;

  /// Battery level of this node as a fraction (0.0 – 1.0), if known.
  final double? batteryLevel;

  /// The transport layer through which this node was discovered.
  final TransportType? connectionType;

  /// Timestamp of the most recent communication with this node.
  final DateTime lastSeen;

  /// Received signal strength indicator (RSSI) in dBm.
  final int signalStrength;

  const MeshNode({
    required this.id,
    required this.name,
    this.role = NodeRole.volunteer,
    this.status = NodeStatus.active,
    this.latitude,
    this.longitude,
    this.batteryLevel,
    this.connectionType,
    required this.lastSeen,
    this.signalStrength = 0,
  });

  /// Whether the node was seen within the last [threshold] (default 5 min).
  bool isOnline({Duration threshold = const Duration(minutes: 5)}) =>
      DateTime.now().difference(lastSeen) < threshold;

  /// Haversine distance in meters to [other], or `null` if either
  /// node lacks coordinates.
  double? distanceTo(MeshNode other) {
    final lat1 = latitude;
    final lng1 = longitude;
    final lat2 = other.latitude;
    final lng2 = other.longitude;
    if (lat1 == null || lng1 == null || lat2 == null || lng2 == null) {
      return null;
    }
    return _haversine(lat1, lng1, lat2, lng2);
  }

  /// Returns a copy of this node with the given fields replaced.
  MeshNode copyWith({
    NodeStatus? status,
    double? latitude,
    double? longitude,
    double? batteryLevel,
    TransportType? connectionType,
    DateTime? lastSeen,
    int? signalStrength,
  }) {
    return MeshNode(
      id: id,
      name: name,
      role: role,
      status: status ?? this.status,
      latitude: latitude ?? this.latitude,
      longitude: longitude ?? this.longitude,
      batteryLevel: batteryLevel ?? this.batteryLevel,
      connectionType: connectionType ?? this.connectionType,
      lastSeen: lastSeen ?? this.lastSeen,
      signalStrength: signalStrength ?? this.signalStrength,
    );
  }

  // ---------------------------------------------------------------------------
  // Serialization
  // ---------------------------------------------------------------------------

  /// Converts this node to a JSON-compatible map.
  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'role': role.name,
        'status': status.name,
        if (latitude != null) 'latitude': latitude,
        if (longitude != null) 'longitude': longitude,
        if (batteryLevel != null) 'batteryLevel': batteryLevel,
        if (connectionType != null) 'connectionType': connectionType!.name,
        'lastSeen': lastSeen.toIso8601String(),
        'signalStrength': signalStrength,
      };

  /// Serializes for SQLite storage (enums as integer indices).
  Map<String, dynamic> toDbMap() {
    final map = toJson();
    map['role'] = role.index;
    map['status'] = status.index;
    map['connectionType'] = connectionType?.index;
    return map;
  }

  /// Creates a [MeshNode] from a JSON map (as produced by [toJson]).
  factory MeshNode.fromJson(Map<String, dynamic> json) {
    return MeshNode(
      id: json['id'] as String,
      name: json['name'] as String,
      role: parseEnum(json['role'], NodeRole.values, NodeRole.volunteer),
      status: parseEnum(json['status'], NodeStatus.values, NodeStatus.active),
      latitude: (json['latitude'] as num?)?.toDouble(),
      longitude: (json['longitude'] as num?)?.toDouble(),
      batteryLevel: (json['batteryLevel'] as num?)?.toDouble(),
      connectionType: json['connectionType'] != null
          ? parseEnum(json['connectionType'], TransportType.values,
              TransportType.ble)
          : null,
      lastSeen: json['lastSeen'] != null
          ? DateTime.parse(json['lastSeen'] as String)
          : DateTime.now(),
      signalStrength: json['signalStrength'] as int? ?? 0,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is MeshNode && other.id == id;

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() => 'MeshNode($name, ${connectionType?.name ?? "?"}, '
      'rssi: $signalStrength)';

  // ---------------------------------------------------------------------------
  // Private
  // ---------------------------------------------------------------------------

  static double _haversine(
      double lat1, double lng1, double lat2, double lng2) {
    const r = 6371000.0; // Earth radius in meters
    final dLat = _rad(lat2 - lat1);
    final dLng = _rad(lng2 - lng1);
    final a = math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(_rad(lat1)) *
            math.cos(_rad(lat2)) *
            math.sin(dLng / 2) *
            math.sin(dLng / 2);
    return r * 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
  }

  static double _rad(double deg) => deg * math.pi / 180;
}
