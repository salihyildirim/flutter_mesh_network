import 'dart:convert';

import 'enums.dart';
import 'parse_helpers.dart';

/// An immutable message that travels through the mesh network.
///
/// Messages are routed using a controlled-flood algorithm:
/// each node that receives a message re-broadcasts it to its
/// neighbors, incrementing [hopCount] and appending its own id
/// to [visitedNodes] to prevent loops.
///
/// ```dart
/// final msg = MeshMessage.text(
///   senderId: 'abc-123',
///   senderName: 'Ahmet',
///   payload: 'Bina girişindeyim',
/// );
/// ```
class MeshMessage {
  /// Unique identifier for this message (typically a UUID v4).
  final String id;

  /// The id of the node that originally created this message.
  final String senderId;

  /// Human-readable display name of the sender.
  final String senderName;

  /// Optional recipient node id; `null` means broadcast.
  final String? targetId;

  /// The semantic type of this message (text, SOS, beacon, etc.).
  final MessageType type;

  /// Routing priority level for this message.
  final MessagePriority priority;

  /// The message body or content.
  final String payload;

  /// Sender latitude at the time of creation, if available.
  final double? latitude;

  /// Sender longitude at the time of creation, if available.
  final double? longitude;

  /// Number of hops this message has traversed so far.
  final int hopCount;

  /// Maximum number of hops before this message is dropped.
  final int maxHops;

  /// Timestamp when this message was created.
  final DateTime createdAt;

  /// Timestamp after which this message should be discarded.
  final DateTime expiresAt;

  /// Ids of nodes that have already processed this message.
  final List<String> visitedNodes;

  const MeshMessage({
    required this.id,
    required this.senderId,
    required this.senderName,
    this.targetId,
    required this.type,
    required this.priority,
    required this.payload,
    this.latitude,
    this.longitude,
    this.hopCount = 0,
    this.maxHops = 10,
    required this.createdAt,
    required this.expiresAt,
    this.visitedNodes = const [],
  });

  // ---------------------------------------------------------------------------
  // Queries
  // ---------------------------------------------------------------------------

  /// Whether the message's TTL has elapsed.
  bool get isExpired => DateTime.now().isAfter(expiresAt);

  /// Whether the message has no specific target (broadcast).
  bool get isBroadcast => targetId == null;

  /// Whether the message can still be forwarded to more hops.
  bool get canForward => hopCount < maxHops && !isExpired;

  /// Whether [nodeId] has already processed this message.
  bool hasVisited(String nodeId) => visitedNodes.contains(nodeId);

  // ---------------------------------------------------------------------------
  // Transformations
  // ---------------------------------------------------------------------------

  /// Returns a copy with an incremented hop and [nodeId] added to the
  /// visited set. Use this before re-broadcasting a received message.
  MeshMessage forwarded(String nodeId) {
    return MeshMessage(
      id: id,
      senderId: senderId,
      senderName: senderName,
      targetId: targetId,
      type: type,
      priority: priority,
      payload: payload,
      latitude: latitude,
      longitude: longitude,
      hopCount: hopCount + 1,
      maxHops: maxHops,
      createdAt: createdAt,
      expiresAt: expiresAt,
      visitedNodes: [...visitedNodes, nodeId],
    );
  }

  // ---------------------------------------------------------------------------
  // Serialization
  // ---------------------------------------------------------------------------

  Map<String, dynamic> toJson() => {
        'id': id,
        'senderId': senderId,
        'senderName': senderName,
        if (targetId != null) 'targetId': targetId,
        'type': type.name,
        'priority': priority.name,
        'payload': payload,
        if (latitude != null) 'latitude': latitude,
        if (longitude != null) 'longitude': longitude,
        'hopCount': hopCount,
        'maxHops': maxHops,
        'createdAt': createdAt.toIso8601String(),
        'expiresAt': expiresAt.toIso8601String(),
        'visitedNodes': visitedNodes,
      };

  factory MeshMessage.fromJson(Map<String, dynamic> json) {
    return MeshMessage(
      id: json['id'] as String,
      senderId: json['senderId'] as String,
      senderName: json['senderName'] as String,
      targetId: json['targetId'] as String?,
      type: parseEnum(json['type'], MessageType.values, MessageType.text),
      priority: parseEnum(
          json['priority'], MessagePriority.values, MessagePriority.normal),
      payload: json['payload'] as String,
      latitude: (json['latitude'] as num?)?.toDouble(),
      longitude: (json['longitude'] as num?)?.toDouble(),
      hopCount: json['hopCount'] as int? ?? 0,
      maxHops: json['maxHops'] as int? ?? 10,
      createdAt: DateTime.parse(json['createdAt'] as String),
      expiresAt: DateTime.parse(json['expiresAt'] as String),
      visitedNodes: _parseVisitedNodes(json['visitedNodes']),
    );
  }

  /// Decodes [visitedNodes] from either a JSON list or a JSON-encoded string
  /// (as stored in SQLite).
  static List<String> _parseVisitedNodes(dynamic raw) {
    if (raw is List) return List<String>.from(raw);
    if (raw is String) return List<String>.from(jsonDecode(raw));
    return const [];
  }

  /// Serializes for SQLite storage.
  ///
  /// Unlike [toJson] (which uses enum names for wire safety),
  /// this method stores enums as integer indices to match the
  /// database schema, and encodes [visitedNodes] as a JSON string.
  Map<String, dynamic> toDbMap() {
    final map = toJson();
    map['type'] = type.index;
    map['priority'] = priority.index;
    map['visitedNodes'] = jsonEncode(visitedNodes);
    return map;
  }

  /// Wire-format encode / decode for transport layers.
  String encode() => jsonEncode(toJson());

  static MeshMessage decode(String data) =>
      MeshMessage.fromJson(jsonDecode(data) as Map<String, dynamic>);

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is MeshMessage && other.id == id;

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() =>
      'MeshMessage(id: $id, type: ${type.name}, from: $senderName, '
      'hops: $hopCount/$maxHops)';
}
