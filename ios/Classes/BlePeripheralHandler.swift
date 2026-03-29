import Foundation
import CoreBluetooth
import Flutter

/// BLE Peripheral handler — GATT server + advertising via CoreBluetooth.
///
/// Exposes a Nordic UART Service (NUS) so that remote centrals can write
/// mesh messages to the TX characteristic and receive notifications on RX.
final class BlePeripheralHandler: NSObject {

    // MARK: - UUIDs (Nordic UART Service based)

    private let serviceUUID  = CBUUID(string: "6E400001-B5A3-F393-E0A9-E50E24DCCA9E")
    private let txCharUUID   = CBUUID(string: "6E400002-B5A3-F393-E0A9-E50E24DCCA9E") // Central writes here
    private let rxCharUUID   = CBUUID(string: "6E400003-B5A3-F393-E0A9-E50E24DCCA9E") // Peripheral notifies here

    private static let peerPrefix = "MSH_"

    // MARK: - Properties

    private var peripheralManager: CBPeripheralManager?
    private weak var methodChannel: FlutterMethodChannel?

    private var rxCharacteristic: CBMutableCharacteristic?

    private var isAdvertising = false
    private var isGattRunning = false
    private var userName: String = ""
    private var latitude: Double?
    private var longitude: Double?

    /// Centrals currently subscribed to the RX (notify) characteristic.
    private var subscribedCentrals: [CBCentral] = []

    /// Chunked incoming data buffer keyed by central identifier.
    private var incomingBuffers: [UUID: Data] = [:]

    /// Set when startAdvertising is called before the peripheral is powered on.
    private var pendingAdvertise = false

    // MARK: - Channel Setup

    func setMethodChannel(_ channel: FlutterMethodChannel) {
        methodChannel = channel
    }

    // MARK: - Public API

    func initialize() -> Bool {
        peripheralManager = CBPeripheralManager(delegate: self, queue: nil)
        return true
    }

    func startGattServer() -> Bool {
        guard let pm = peripheralManager, pm.state == .poweredOn else {
            NSLog("[MeshBle] Peripheral manager not ready")
            return false
        }

        let txCharacteristic = CBMutableCharacteristic(
            type: txCharUUID,
            properties: [.write, .writeWithoutResponse],
            value: nil,
            permissions: [.writeable]
        )

        rxCharacteristic = CBMutableCharacteristic(
            type: rxCharUUID,
            properties: [.read, .notify],
            value: nil,
            permissions: [.readable]
        )

        let service = CBMutableService(type: serviceUUID, primary: true)
        service.characteristics = [txCharacteristic, rxCharacteristic!]

        pm.add(service)
        isGattRunning = true
        NSLog("[MeshBle] GATT Server started")
        return true
    }

    func startAdvertising(name: String, lat: Double?, lng: Double?) -> Bool {
        userName = name
        latitude = lat
        longitude = lng

        guard let pm = peripheralManager else { return false }

        if pm.state != .poweredOn {
            pendingAdvertise = true
            return false
        }

        doStartAdvertising()
        return true
    }

    func stopAdvertising() {
        peripheralManager?.stopAdvertising()
        isAdvertising = false
        NSLog("[MeshBle] Advertising stopped")
    }

    func updateAdvertising(lat: Double?, lng: Double?) {
        latitude = lat
        longitude = lng

        if isAdvertising {
            doStartAdvertising()
        }
    }

    func notifyAllSubscribers(data: Data) -> Int {
        guard let rx = rxCharacteristic, !subscribedCentrals.isEmpty else { return 0 }

        let sent = peripheralManager?.updateValue(
            data,
            for: rx,
            onSubscribedCentrals: nil
        ) ?? false

        let count = sent ? subscribedCentrals.count : 0
        NSLog("[MeshBle] Notified %d/%d subscribers", count, subscribedCentrals.count)
        return count
    }

    func getState() -> [String: Any] {
        return [
            "isAdvertising": isAdvertising,
            "isGattRunning": isGattRunning,
            "connectedCount": subscribedCentrals.count,
            "subscribedCount": subscribedCentrals.count
        ]
    }

    func stop() {
        stopAdvertising()
        peripheralManager?.removeAllServices()
        subscribedCentrals.removeAll()
        incomingBuffers.removeAll()
        isGattRunning = false
        NSLog("[MeshBle] BLE Peripheral stopped")
    }

    // MARK: - Helpers

    private func doStartAdvertising() {
        guard let pm = peripheralManager else { return }

        if pm.isAdvertising {
            pm.stopAdvertising()
        }

        let advertisementData: [String: Any] = [
            CBAdvertisementDataLocalNameKey: "\(Self.peerPrefix)\(userName)",
            CBAdvertisementDataServiceUUIDsKey: [serviceUUID]
        ]

        pm.startAdvertising(advertisementData)
        NSLog("[MeshBle] Advertising started: %@%@", Self.peerPrefix, userName)
    }

    private func invokeFlutter(_ method: String, arguments: Any? = nil) {
        DispatchQueue.main.async { [weak self] in
            self?.methodChannel?.invokeMethod(method, arguments: arguments)
        }
    }

    private func isCompleteJson(_ str: String) -> Bool {
        let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{") && trimmed.hasSuffix("}") else { return false }
        return (try? JSONSerialization.jsonObject(with: Data(trimmed.utf8))) != nil
    }
}

// MARK: - CBPeripheralManagerDelegate

extension BlePeripheralHandler: CBPeripheralManagerDelegate {

    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        let stateStr: String
        switch peripheral.state {
        case .poweredOn:
            stateStr = "poweredOn"
            if pendingAdvertise {
                pendingAdvertise = false
                doStartAdvertising()
            }
        case .poweredOff:
            stateStr = "poweredOff"
            isAdvertising = false
            isGattRunning = false
        case .unauthorized:  stateStr = "unauthorized"
        case .unsupported:   stateStr = "unsupported"
        case .resetting:     stateStr = "resetting"
        case .unknown:       stateStr = "unknown"
        @unknown default:    stateStr = "unknown"
        }

        NSLog("[MeshBle] Peripheral state: %@", stateStr)
    }

    func peripheralManagerDidStartAdvertising(
        _ peripheral: CBPeripheralManager,
        error: Error?
    ) {
        if let error = error {
            NSLog("[MeshBle] Advertising failed: %@", error.localizedDescription)
            isAdvertising = false
        } else {
            NSLog("[MeshBle] Advertising confirmed started")
            isAdvertising = true
        }

        invokeFlutter("onBleAdvertisingStarted", arguments: isAdvertising)
    }

    func peripheralManager(
        _ peripheral: CBPeripheralManager,
        didReceiveWrite requests: [CBATTRequest]
    ) {
        for request in requests {
            guard request.characteristic.uuid == txCharUUID,
                  let value = request.value else {
                peripheral.respond(to: request, withResult: .success)
                continue
            }

            let centralId = request.central.identifier
            var buffer = incomingBuffers[centralId] ?? Data()
            buffer.append(value)

            if let str = String(data: buffer, encoding: .utf8),
               str.hasSuffix("\n\n") || isCompleteJson(str) {
                let message = str.trimmingCharacters(in: .whitespacesAndNewlines)
                incomingBuffers.removeValue(forKey: centralId)

                NSLog("[MeshBle] Complete message from %@: %@...", centralId.uuidString, String(message.prefix(80)))

                invokeFlutter("onBleMessageReceived", arguments: [
                    "deviceId": centralId.uuidString,
                    "data": message
                ])
            } else {
                incomingBuffers[centralId] = buffer
            }

            peripheral.respond(to: request, withResult: .success)
        }
    }

    func peripheralManager(
        _ peripheral: CBPeripheralManager,
        central: CBCentral,
        didSubscribeTo characteristic: CBCharacteristic
    ) {
        guard characteristic.uuid == rxCharUUID else { return }
        subscribedCentrals.append(central)
        NSLog("[MeshBle] Central subscribed: %@", central.identifier.uuidString)
    }

    func peripheralManager(
        _ peripheral: CBPeripheralManager,
        central: CBCentral,
        didUnsubscribeFrom characteristic: CBCharacteristic
    ) {
        guard characteristic.uuid == rxCharUUID else { return }
        subscribedCentrals.removeAll { $0.identifier == central.identifier }
        NSLog("[MeshBle] Central unsubscribed: %@", central.identifier.uuidString)
    }

    func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) {
        NSLog("[MeshBle] Ready to update subscribers")
    }
}
