package com.fluttermeshnetwork.flutter_mesh_network

import android.app.Activity
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodChannel

/**
 * FlutterMeshNetworkPlugin — main entry point for the flutter_mesh_network plugin.
 *
 * Registers two MethodChannels:
 *   - flutter_mesh_network/nearby  → Wi-Fi Aware (NAN)
 *   - flutter_mesh_network/ble     → BLE Peripheral (GATT server + advertising)
 *
 * Delegates all calls to [WifiAwareHandler] and [BlePeripheralHandler] respectively.
 */
class FlutterMeshNetworkPlugin : FlutterPlugin, ActivityAware {

    private var nearbyChannel: MethodChannel? = null
    private var bleChannel: MethodChannel? = null

    private var wifiAwareHandler: WifiAwareHandler? = null
    private var blePeripheralHandler: BlePeripheralHandler? = null

    private var activity: Activity? = null

    // =========================================================================
    // FlutterPlugin
    // =========================================================================

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        val messenger = binding.binaryMessenger
        val context = binding.applicationContext

        // Wi-Fi Aware channel
        nearbyChannel = MethodChannel(messenger, "flutter_mesh_network/nearby")
        wifiAwareHandler = WifiAwareHandler(context)
        wifiAwareHandler!!.setMethodChannel(nearbyChannel!!)
        nearbyChannel!!.setMethodCallHandler { call, result ->
            wifiAwareHandler!!.onMethodCall(call, result)
        }

        // BLE Peripheral channel
        bleChannel = MethodChannel(messenger, "flutter_mesh_network/ble")
        blePeripheralHandler = BlePeripheralHandler(context)
        blePeripheralHandler!!.setMethodChannel(bleChannel!!)
        bleChannel!!.setMethodCallHandler { call, result ->
            blePeripheralHandler!!.onMethodCall(call, result)
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        nearbyChannel?.setMethodCallHandler(null)
        nearbyChannel = null

        bleChannel?.setMethodCallHandler(null)
        bleChannel = null

        wifiAwareHandler?.dispose()
        wifiAwareHandler = null

        blePeripheralHandler?.stop()
        blePeripheralHandler = null
    }

    // =========================================================================
    // ActivityAware
    // =========================================================================

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding.activity
        wifiAwareHandler?.setActivity(activity)
        blePeripheralHandler?.setActivity(activity)
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        activity = binding.activity
        wifiAwareHandler?.setActivity(activity)
        blePeripheralHandler?.setActivity(activity)
    }

    override fun onDetachedFromActivityForConfigChanges() {
        activity = null
        wifiAwareHandler?.setActivity(null)
        blePeripheralHandler?.setActivity(null)
    }

    override fun onDetachedFromActivity() {
        activity = null
        wifiAwareHandler?.setActivity(null)
        blePeripheralHandler?.setActivity(null)
    }
}
