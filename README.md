# flutter_mesh_network

A cross-platform Flutter plugin for **offline mesh networking**. Enables device-to-device communication via BLE, Wi-Fi Direct, and Wi-Fi Aware (Android) / MultipeerConnectivity (iOS) — no internet or cellular infrastructure required.

## Features

- **3 transport layers** — BLE, Wi-Fi Direct, Wi-Fi Aware / MultipeerConnectivity
- **Automatic mesh routing** — flood-fill with hop counting, TTL, and loop prevention
- **Store-and-forward** — messages are queued and relayed when new peers appear
- **Intelligent transport selection** — picks the best transport based on message type, battery level, and strategy
- **SOS mode** — switches to emergency strategy, uses all transports aggressively
- **Offline persistence** — SQLite storage for messages and discovered nodes
- **RTT distance measurement** — Wi-Fi Aware ranging on supported Android devices
- **Single entry point** — one class (`MeshNetwork`), one config (`MeshConfig`)

## Platform Support

| Transport | Android | iOS |
|---|---|---|
| BLE (scan + advertise + GATT) | 8.0+ | 13.0+ |
| Wi-Fi Direct | 8.0+ | - |
| Wi-Fi Aware (NAN) | 8.0+ | - |
| MultipeerConnectivity | - | 13.0+ |

## Quick Start

```dart
import 'package:flutter_mesh_network/flutter_mesh_network.dart';

// Create a mesh network instance.
final mesh = MeshNetwork(
  config: const MeshConfig(serviceName: 'my-app'),
);

// Listen for messages and peer changes.
mesh.onMessage.listen((msg) {
  print('${msg.senderName}: ${msg.payload}');
});

mesh.onNodeChanged.listen((node) {
  print('${node.name} is ${node.isOnline() ? "online" : "offline"}');
});

// Start the mesh.
await mesh.start(userId: 'user-123', userName: 'Ahmet');

// Send a text message to all peers.
await mesh.sendText('Hello mesh!');

// Send to a specific peer.
await mesh.sendText('Direct message', targetId: 'peer-456');

// Broadcast your location.
await mesh.broadcastLocation(latitude: 39.93, longitude: 32.85);

// Send SOS (switches to emergency mode automatically).
await mesh.sendSos(latitude: 39.93, longitude: 32.85);

// Cancel SOS and revert to previous strategy.
mesh.cancelSos();

// Clean up when done.
await mesh.dispose();
```

## Configuration

All defaults are tuned for search-and-rescue scenarios. Override as needed:

```dart
const config = MeshConfig(
  serviceName: 'my-app',        // max 15 chars, lowercase + hyphens
  maxHops: 10,                  // max relay hops per message
  messageTtl: Duration(hours: 6),
  sosTtl: Duration(hours: 24),
  strategy: TransportStrategy.balanced,
  enableLogging: true,
);
```

### Transport Strategies

| Strategy | Description |
|---|---|
| `lowPower` | BLE only — minimal battery usage |
| `balanced` | BLE + Wi-Fi Aware — default |
| `maxPerformance` | All transports active |
| `emergency` | All transports, aggressive scanning |

## Important: Physical Devices Only

Mesh networking relies on hardware-level radios (BLE, Wi-Fi Direct, Wi-Fi Aware, MultipeerConnectivity). **Emulators and simulators do not support these technologies.** You must test on real physical devices.

## Android Setup

Add to `android/app/build.gradle`:

```groovy
android {
    defaultConfig {
        minSdkVersion 26  // Required for Wi-Fi Aware
    }
}
```

Add to `AndroidManifest.xml`:

```xml
<uses-permission android:name="android.permission.BLUETOOTH_SCAN" />
<uses-permission android:name="android.permission.BLUETOOTH_ADVERTISE" />
<uses-permission android:name="android.permission.BLUETOOTH_CONNECT" />
<uses-permission android:name="android.permission.ACCESS_FINE_LOCATION" />
<uses-permission android:name="android.permission.NEARBY_WIFI_DEVICES" />
<uses-feature android:name="android.hardware.wifi.aware" android:required="false" />
```

## iOS Setup

Add to `Info.plist`:

```xml
<key>NSBluetoothAlwaysUsageDescription</key>
<string>Used for offline mesh communication.</string>
<key>NSLocalNetworkUsageDescription</key>
<string>Used to discover nearby mesh peers.</string>
<key>NSBonjourServices</key>
<array>
    <string>_my-app._tcp</string>
    <string>_my-app._udp</string>
</array>
<key>UIBackgroundModes</key>
<array>
    <string>bluetooth-central</string>
    <string>bluetooth-peripheral</string>
</array>
```

## How It Works

```
Phone A ←──BLE──→ Phone B ←──Wi-Fi──→ Phone C
  │                                       │
  └──────── MultipeerConnectivity ────────┘
```

Each device runs as both a **scanner** (finds peers) and a **beacon** (advertises itself). Messages are flooded through the network with hop counting and visited-node tracking to prevent loops. The `TransportSelector` picks the optimal transport(s) for each message based on type, priority, and battery level.

## License

MIT — see [LICENSE](LICENSE).
