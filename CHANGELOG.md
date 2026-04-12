## 0.1.3

- Fix BLE advertising crash on Android SDK 36 (`addManufacturerSpecificData` removed).
- Use `addServiceData` for BLE location advertising with backward-compatible scan parsing.

## 0.1.2

- Add Swift Package Manager support (`darwin/flutter_mesh_network/Package.swift`).
- Complete API documentation for all public members (100% coverage).
- Add "Physical Devices Only" notice to README.
- Improve example app: error handling, stream subscription cleanup, online peer count, SOS message icon, empty state placeholder.

## 0.1.1

- Upgrade flutter_blue_plus to ^2.2.1.
- Shorten package description for pub.dev scoring.

## 0.1.0

- Initial release.
- BLE transport: scanning (flutter_blue_plus) + GATT server & advertising (native).
- Wi-Fi Direct transport: TCP socket server with auto-reconnect.
- Nearby transport: Wi-Fi Aware on Android, MultipeerConnectivity on iOS.
- Intelligent transport selection based on message type, battery level, and strategy.
- Store-and-forward mesh routing with hop counting, TTL, and loop prevention.
- SQLite persistence for messages and nodes.
- Configurable via `MeshConfig` (service name, BLE UUIDs, TTLs, scan intervals, etc.).
- SOS mode with automatic strategy escalation and revert.
- RTT distance measurement support (Android, Wi-Fi Aware).
