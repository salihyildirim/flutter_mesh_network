import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import '../config.dart';
import '../logger.dart';
import '../models/enums.dart';
import '../models/mesh_message.dart';
import '../models/mesh_node.dart';
import 'transport.dart';

/// BLE transport layer.
///
/// **Central mode** (scanning + GATT client): handled by `flutter_blue_plus`.
/// **Peripheral mode** (advertising + GATT server): handled by native code
/// via the `MethodChannel('flutter_mesh_network/ble')`.
class BleTransport implements MeshTransport {
  BleTransport(this._config);

  static const _channel = MethodChannel('flutter_mesh_network/ble');

  final MeshConfig _config;
  final _messages = StreamController<MeshMessage>.broadcast();
  final _nodes = StreamController<MeshNode>.broadcast();
  final _discoveredNodes = <String, MeshNode>{};

  Timer? _scanTimer;
  StreamSubscription<List<ScanResult>>? _scanSubscription;
  bool _isScanning = false;
  bool _isAdvertising = false;
  bool _isGattRunning = false;

  // ---------------------------------------------------------------------------
  // MeshTransport
  // ---------------------------------------------------------------------------

  @override
  TransportType get type => TransportType.ble;

  @override
  bool get isActive => _isScanning || _isAdvertising;

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
    final supported = await FlutterBluePlus.isSupported;
    if (!supported) {
      MeshLogger.ble('BLE not supported on this device');
      return false;
    }

    await _startScanning();
    await _startPeripheral(userName, latitude, longitude);

    MeshLogger.ble('BLE transport active '
        '(scan: $_isScanning, advertise: $_isAdvertising)');
    return _isScanning || _isAdvertising;
  }

  @override
  Future<bool> send(MeshMessage message, String peerId) async {
    try {
      final device = BluetoothDevice.fromId(peerId);
      await device.connect(
        license: License.free,
        timeout: const Duration(seconds: 5),
      );

      final services = await device.discoverServices();
      final meshService = services.firstWhere(
        (s) => s.uuid == Guid(_config.bleServiceUuid),
        orElse: () => throw StateError('Mesh GATT service not found'),
      );

      final txChar = meshService.characteristics.firstWhere(
        (c) => c.uuid == Guid(_config.bleTxCharUuid),
      );

      final bytes = utf8.encode(message.encode());
      const chunkSize = 182;
      for (var i = 0; i < bytes.length; i += chunkSize) {
        final end = (i + chunkSize).clamp(0, bytes.length);
        await txChar.write(bytes.sublist(i, end), withoutResponse: false);
      }

      await device.disconnect();
      MeshLogger.ble('Sent to $peerId (${bytes.length} B)');
      return true;
    } catch (e) {
      MeshLogger.error('BLE', 'Send failed to $peerId', e);
      return false;
    }
  }

  @override
  Future<int> broadcast(MeshMessage message) async {
    // If GATT server is running, notify all connected subscribers.
    if (_isGattRunning) {
      return _notifySubscribers(message);
    }

    // Otherwise, send individually to discovered BLE peers.
    var count = 0;
    for (final node in _discoveredNodes.values) {
      if (node.connectionType == TransportType.ble && node.isOnline()) {
        final ok = await send(message, node.id);
        if (ok) count++;
      }
    }
    return count;
  }

  @override
  Future<void> updateLocation(double latitude, double longitude) async {
    if (!_isAdvertising) return;
    try {
      await _channel.invokeMethod('updateLocation', {
        'latitude': latitude,
        'longitude': longitude,
      });
    } catch (e) {
      MeshLogger.error('BLE', 'Location update failed', e);
    }
  }

  @override
  Future<void> stop() async {
    _scanTimer?.cancel();
    await _scanSubscription?.cancel();
    _scanSubscription = null;
    _isScanning = false;
    _isAdvertising = false;
    _isGattRunning = false;
    FlutterBluePlus.stopScan();

    try {
      await _channel.invokeMethod('stop');
    } catch (_) {}

    MeshLogger.ble('BLE transport stopped');
  }

  @override
  Future<void> dispose() async {
    await stop();
    _channel.setMethodCallHandler(null);
    _messages.close();
    _nodes.close();
  }

  // ---------------------------------------------------------------------------
  // Central mode — scanning
  // ---------------------------------------------------------------------------

  Future<void> _startScanning() async {
    if (_isScanning) return;
    _isScanning = true;

    _performScan();
    _scanTimer = Timer.periodic(_config.bleRescanInterval, (_) {
      _performScan();
    });
  }

  Future<void> _performScan() async {
    try {
      FlutterBluePlus.stopScan();
      await _scanSubscription?.cancel();
      _scanSubscription = FlutterBluePlus.scanResults.listen((results) {
        for (final r in results) {
          _handleScanResult(r);
        }
      });
      await FlutterBluePlus.startScan(timeout: _config.bleScanDuration);
    } catch (e) {
      MeshLogger.error('BLE', 'Scan error', e);
    }
  }

  void _handleScanResult(ScanResult result) {
    final name = result.advertisementData.advName;
    if (!name.startsWith('GEA_') && !name.startsWith('MSH_')) return;

    final prefix = name.startsWith('GEA_') ? 'GEA_' : 'MSH_';
    final nodeId = result.device.remoteId.str;
    final nodeName = name.replaceFirst(prefix, '');

    double? lat, lng;
    // Read location from service data (primary) or manufacturer data (legacy).
    final svcData = result.advertisementData.serviceData;
    final mfgData = result.advertisementData.manufacturerData;
    final locationBytes = svcData.values.isNotEmpty
        ? svcData.values.first
        : mfgData.isNotEmpty
            ? (mfgData[0x4745] ?? mfgData.values.first)
            : null;
    if (locationBytes != null && locationBytes.length >= 16) {
      lat = _bytesToDouble(locationBytes.sublist(0, 8));
      lng = _bytesToDouble(locationBytes.sublist(8, 16));
    }

    final node = MeshNode(
      id: nodeId,
      name: nodeName,
      connectionType: TransportType.ble,
      latitude: lat,
      longitude: lng,
      signalStrength: result.rssi,
      lastSeen: DateTime.now(),
    );

    // Prune stale entries when the map grows beyond 100 nodes.
    if (_discoveredNodes.length > 100) {
      _pruneStaleNodes();
    }

    _discoveredNodes[nodeId] = node;
    _nodes.add(node);
  }

  /// Removes discovered nodes that have not been seen for over 10 minutes.
  void _pruneStaleNodes() {
    final cutoff = DateTime.now().subtract(const Duration(minutes: 10));
    _discoveredNodes.removeWhere(
      (_, node) => node.lastSeen.isBefore(cutoff),
    );
  }

  // ---------------------------------------------------------------------------
  // Peripheral mode — native GATT server + advertising
  // ---------------------------------------------------------------------------

  Future<void> _startPeripheral(
      String userName, double? lat, double? lng) async {
    try {
      _channel.setMethodCallHandler(_handleNativeCallback);

      final initialized =
          await _channel.invokeMethod<bool>('initialize') ?? false;
      if (!initialized) return;

      _isGattRunning =
          await _channel.invokeMethod<bool>('startGattServer') ?? false;

      _isAdvertising =
          await _channel.invokeMethod<bool>('startAdvertising', {
                'userName': userName,
                'latitude': lat,
                'longitude': lng,
              }) ??
              false;

      MeshLogger.ble(
          'Peripheral: gatt=$_isGattRunning, adv=$_isAdvertising');
    } on MissingPluginException {
      MeshLogger.ble('BLE peripheral native plugin not available');
    } catch (e) {
      MeshLogger.error('BLE', 'Peripheral start failed', e);
    }
  }

  Future<int> _notifySubscribers(MeshMessage message) async {
    if (!_isGattRunning) return 0;
    try {
      return await _channel.invokeMethod<int>('notifyAll', {
            'data': message.encode(),
          }) ??
          0;
    } catch (e) {
      MeshLogger.error('BLE', 'Notify failed', e);
      return 0;
    }
  }

  Future<void> _handleNativeCallback(MethodCall call) async {
    switch (call.method) {
      case 'onBleMessageReceived':
        if (call.arguments is! Map) return;
        final args = Map<String, dynamic>.from(call.arguments as Map);
        final data = args['data'] as String?;
        if (data == null) return;
        try {
          _messages.add(MeshMessage.decode(data));
        } catch (e) {
          MeshLogger.error('BLE', 'Message parse failed', e);
        }
      case 'onBleAdvertisingStarted':
        _isAdvertising = call.arguments == true;
    }
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  static double _bytesToDouble(List<int> bytes) {
    if (bytes.length < 8) return 0;
    final bd = ByteData(8);
    for (var i = 0; i < 8; i++) {
      bd.setUint8(i, bytes[i]);
    }
    return bd.getFloat64(0);
  }
}
