import '../models/enums.dart';
import '../models/mesh_message.dart';

/// Decides which transports to use for a given message based on
/// message type, priority, battery level, and active strategy.
///
/// ```
/// ┌──────────────────┬─────┬────────┬───────────┐
/// │ Scenario         │ BLE │ Nearby │ Wi-Fi Dir │
/// ├──────────────────┼─────┼────────┼───────────┤
/// │ SOS / Critical   │  ✓  │   ✓    │     ✓     │
/// │ Beacon / Location│  ✓  │   ✓    │           │
/// │ Short text       │  ✓  │   ✓    │           │
/// │ Long text / data │     │        │     ✓     │
/// │ Battery < 30 %   │  ✓  │   ✓    │           │
/// │ Battery < 15 %   │  ✓  │        │           │
/// └──────────────────┴─────┴────────┴───────────┘
/// ```
class TransportSelector {
  const TransportSelector();

  static const _criticalBattery = 0.15;
  static const _lowBattery = 0.30;
  static const _largePayloadThreshold = 500;

  /// Returns the ordered list of transports to use for [message].
  List<TransportType> select({
    required MeshMessage message,
    required TransportStrategy strategy,
    required double? batteryLevel,
    required bool bleAvailable,
    required bool wifiDirectAvailable,
    required bool nearbyAvailable,
  }) {
    if (strategy == TransportStrategy.emergency) {
      return _all(bleAvailable, wifiDirectAvailable, nearbyAvailable);
    }

    if (batteryLevel != null && batteryLevel < _criticalBattery) {
      if (message.priority == MessagePriority.critical) {
        return _all(bleAvailable, wifiDirectAvailable, nearbyAvailable);
      }
      return bleAvailable ? [TransportType.ble] : const [];
    }

    if (strategy == TransportStrategy.lowPower) {
      return bleAvailable ? [TransportType.ble] : const [];
    }

    if (batteryLevel != null && batteryLevel < _lowBattery) {
      return [
        if (bleAvailable) TransportType.ble,
        if (nearbyAvailable) TransportType.nearby,
      ];
    }

    return switch (message.type) {
      MessageType.sos || MessageType.sosCancel || MessageType.command =>
        _all(bleAvailable, wifiDirectAvailable, nearbyAvailable),
      MessageType.beacon || MessageType.location => [
          if (nearbyAvailable) TransportType.nearby,
          if (bleAvailable) TransportType.ble,
        ],
      MessageType.text => message.payload.length > _largePayloadThreshold
          ? _highBandwidth(bleAvailable, wifiDirectAvailable, nearbyAvailable)
          : [
              if (bleAvailable) TransportType.ble,
              if (nearbyAvailable) TransportType.nearby,
              if (!bleAvailable && !nearbyAvailable && wifiDirectAvailable)
                TransportType.wifiDirect,
            ],
    };
  }

  /// Recommended scan interval for the given strategy and battery.
  Duration scanInterval(TransportStrategy strategy, double? batteryLevel) {
    if (batteryLevel != null && batteryLevel < _criticalBattery) {
      return const Duration(seconds: 120);
    }
    return switch (strategy) {
      TransportStrategy.emergency => const Duration(seconds: 10),
      TransportStrategy.maxPerformance => const Duration(seconds: 15),
      TransportStrategy.balanced => const Duration(seconds: 30),
      TransportStrategy.lowPower => const Duration(seconds: 60),
    };
  }

  List<TransportType> _all(bool ble, bool wifi, bool nearby) => [
        if (ble) TransportType.ble,
        if (nearby) TransportType.nearby,
        if (wifi) TransportType.wifiDirect,
      ];

  List<TransportType> _highBandwidth(bool ble, bool wifi, bool nearby) => [
        if (wifi) TransportType.wifiDirect,
        if (nearby) TransportType.nearby,
        if (ble) TransportType.ble,
      ];
}
