/// The type of a mesh message.
///
/// Determines how the mesh network prioritizes and routes the message.
enum MessageType {
  /// Free-form text message between users.
  text,

  /// Location coordinate update (latitude/longitude).
  location,

  /// Emergency distress signal — highest priority, longest TTL.
  sos,

  /// Cancellation of a previous SOS.
  sosCancel,

  /// Periodic heartbeat with position data.
  beacon,

  /// System command (e.g. strategy change, shutdown).
  command,
}

/// Priority level of a mesh message.
///
/// Higher priority messages are forwarded first and may use
/// more aggressive (power-hungry) transports.
enum MessagePriority {
  /// Background — forwarded only when convenient.
  low,

  /// Default priority for regular messages.
  normal,

  /// Elevated — forwarded ahead of normal traffic.
  high,

  /// Emergency — uses all available transports immediately.
  critical,
}

/// Available transport layers for mesh communication.
enum TransportType {
  /// Bluetooth Low Energy (~100–200 m, very low power).
  ble,

  /// Wi-Fi Direct (~200 m, high bandwidth).
  wifiDirect,

  /// Wi-Fi Aware on Android / MultipeerConnectivity on iOS
  /// (~200–300 m, low power discovery).
  nearby,
}

/// Strategy that governs which transports are active and how
/// aggressively the mesh scans for peers.
enum TransportStrategy {
  /// Battery saver — BLE only.
  lowPower,

  /// Default — BLE discovery + Wi-Fi Direct for data.
  balanced,

  /// All transports active, faster scan intervals.
  maxPerformance,

  /// All transports, aggressive scanning, no power limits.
  emergency,
}

/// Role of a node in the mesh network.
enum NodeRole {
  /// General volunteer assisting in the field.
  volunteer,

  /// Incident commander coordinating the operation.
  commander,

  /// Team lead managing a group of field workers.
  teamLead,

  /// Search-and-rescue field operator.
  searcher,

  /// Medical responder providing first aid or triage.
  medic,

  /// Civilian or bystander in the affected area.
  civilian,
}

/// Current operational status of a node.
enum NodeStatus {
  /// Node is online and operating normally.
  active,

  /// Node has gone offline or is unreachable.
  inactive,

  /// Node has triggered an SOS distress signal.
  sos,

  /// Node is trapped under rubble and needs rescue.
  underRubble,
}
