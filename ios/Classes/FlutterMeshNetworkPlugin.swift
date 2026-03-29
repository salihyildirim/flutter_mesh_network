import Flutter
import UIKit

/// Main plugin entry point for flutter_mesh_network on iOS.
///
/// Registers two MethodChannels and delegates calls to dedicated handlers:
/// - `flutter_mesh_network/nearby` -> MeshConnectivityHandler (MultipeerConnectivity)
/// - `flutter_mesh_network/ble`    -> BlePeripheralHandler   (CoreBluetooth)
public class FlutterMeshNetworkPlugin: NSObject, FlutterPlugin {

    private let meshHandler = MeshConnectivityHandler()
    private let bleHandler = BlePeripheralHandler()

    public static func register(with registrar: FlutterPluginRegistrar) {
        let instance = FlutterMeshNetworkPlugin()

        // --- Nearby (MultipeerConnectivity) channel ---
        let nearbyChannel = FlutterMethodChannel(
            name: "flutter_mesh_network/nearby",
            binaryMessenger: registrar.messenger()
        )
        instance.meshHandler.setMethodChannel(nearbyChannel)
        nearbyChannel.setMethodCallHandler(instance.handleNearbyCall)

        // --- BLE Peripheral channel ---
        let bleChannel = FlutterMethodChannel(
            name: "flutter_mesh_network/ble",
            binaryMessenger: registrar.messenger()
        )
        instance.bleHandler.setMethodChannel(bleChannel)
        bleChannel.setMethodCallHandler(instance.handleBleCall)

        // Keep the instance alive for the duration of the registrar.
        registrar.addMethodCallDelegate(instance, channel: nearbyChannel)
    }

    // MARK: - FlutterPlugin (required but unused — routing happens via per-channel handlers)

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        // This is only called for the nearbyChannel because of addMethodCallDelegate.
        // We route through handleNearbyCall instead, so this is a no-op fallback.
        result(FlutterMethodNotImplemented)
    }

    // MARK: - Nearby Channel Handler

    private func handleNearbyCall(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let args = call.arguments as? [String: Any] ?? [:]

        switch call.method {
        case "isAvailable":
            result(meshHandler.isAvailable())

        case "publish":
            let serviceName = args["serviceName"] as? String ?? "mesh-net"
            let userId      = args["userId"] as? String ?? ""
            let userName    = args["userName"] as? String ?? ""
            let latitude    = args["latitude"] as? Double
            let longitude   = args["longitude"] as? Double
            result(meshHandler.startPublishing(
                serviceName: serviceName,
                userId: userId,
                userName: userName,
                latitude: latitude,
                longitude: longitude
            ))

        case "subscribe":
            let serviceName = args["serviceName"] as? String ?? "mesh-net"
            result(meshHandler.startSubscribing(serviceName: serviceName))

        case "sendMessage":
            let peerId = args["peerId"] as? String ?? ""
            let data   = args["data"] as? String ?? ""
            result(meshHandler.sendMessage(peerId: peerId, data: data))

        case "broadcastMessage":
            let data = args["data"] as? String ?? ""
            result(meshHandler.broadcastMessage(data: data))

        case "measureDistance":
            let peerId = args["peerId"] as? String ?? ""
            if let distance = meshHandler.measureDistance(peerId: peerId) {
                result(distance)
            } else {
                result(nil)
            }

        case "stopPublish":
            meshHandler.stopPublish()
            result(true)

        case "stopSubscribe":
            meshHandler.stopSubscribe()
            result(true)

        case "updateLocation":
            let latitude  = args["latitude"] as? Double ?? 0
            let longitude = args["longitude"] as? Double ?? 0
            meshHandler.updateLocation(latitude: latitude, longitude: longitude)
            result(true)

        case "getPeers":
            result(meshHandler.getPeers())

        case "stop":
            meshHandler.stop()
            result(true)

        default:
            result(FlutterMethodNotImplemented)
        }
    }

    // MARK: - BLE Channel Handler

    private func handleBleCall(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let args = call.arguments as? [String: Any] ?? [:]

        switch call.method {
        case "initialize":
            result(bleHandler.initialize())

        case "startGattServer":
            result(bleHandler.startGattServer())

        case "startAdvertising":
            let name = args["userName"] as? String ?? ""
            let lat  = args["latitude"] as? Double
            let lng  = args["longitude"] as? Double
            result(bleHandler.startAdvertising(name: name, lat: lat, lng: lng))

        case "stopAdvertising":
            bleHandler.stopAdvertising()
            result(true)

        case "updateLocation":
            let lat = args["latitude"] as? Double
            let lng = args["longitude"] as? Double
            bleHandler.updateAdvertising(lat: lat, lng: lng)
            result(true)

        case "notifyAll":
            let data = args["data"] as? String ?? ""
            let payload = data.data(using: .utf8) ?? Data()
            result(bleHandler.notifyAllSubscribers(data: payload))

        case "getState":
            result(bleHandler.getState())

        case "stop":
            bleHandler.stop()
            result(true)

        default:
            result(FlutterMethodNotImplemented)
        }
    }
}
