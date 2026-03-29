package com.fluttermeshnetwork.flutter_mesh_network

import android.app.Activity
import android.bluetooth.*
import android.bluetooth.le.*
import android.content.Context
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.ParcelUuid
import android.util.Log
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.charset.StandardCharsets
import java.util.UUID

/**
 * Handles BLE Peripheral mode: GATT server + advertising.
 *
 * Channel: `flutter_mesh_network/ble`
 *
 * Advertising name prefix: "MSH_"
 * Uses the Nordic UART Service (NUS) UUID layout for TX/RX characteristics.
 */
class BlePeripheralHandler(private val context: Context) {

    companion object {
        private const val TAG = "MshBle"
        private const val NAME_PREFIX = "MSH_"

        // Nordic UART Service UUIDs
        val SERVICE_UUID: UUID  = UUID.fromString("6e400001-b5a3-f393-e0a9-e50e24dcca9e")
        val TX_CHAR_UUID: UUID  = UUID.fromString("6e400002-b5a3-f393-e0a9-e50e24dcca9e") // client writes
        val RX_CHAR_UUID: UUID  = UUID.fromString("6e400003-b5a3-f393-e0a9-e50e24dcca9e") // server notifies

        // Client Characteristic Configuration Descriptor
        val CCCD_UUID: UUID = UUID.fromString("00002902-0000-1000-8000-00805f9b34fb")

        // Custom manufacturer ID (0x4D53 = "MS" in little-endian ASCII)
        const val MANUFACTURER_ID = 0x4D53
    }

    private val mainHandler = Handler(Looper.getMainLooper())
    private var methodChannel: MethodChannel? = null
    private var activity: Activity? = null

    // Bluetooth stack
    private var bluetoothManager: BluetoothManager? = null
    private var bluetoothAdapter: BluetoothAdapter? = null
    private var advertiser: BluetoothLeAdvertiser? = null
    private var gattServer: BluetoothGattServer? = null

    // State
    private var isAdvertising = false
    private var isGattRunning = false
    private var userName: String = ""
    private var latitude: Double? = null
    private var longitude: Double? = null

    // Connected / subscribed devices
    private val connectedDevices = mutableMapOf<String, BluetoothDevice>()
    private val subscribedDevices = mutableSetOf<String>()

    // Incoming message buffer per device (chunked writes)
    private val incomingBuffers = mutableMapOf<String, StringBuilder>()

    // GATT characteristic reference for notifications
    private var rxCharacteristic: BluetoothGattCharacteristic? = null

    fun setMethodChannel(channel: MethodChannel) {
        methodChannel = channel
    }

    fun setActivity(act: Activity?) {
        activity = act
    }

    // =========================================================================
    // MethodCall dispatch
    // =========================================================================

    fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "initialize" -> result.success(initialize())

            "startGattServer" -> result.success(startGattServer())

            "startAdvertising" -> {
                val name = call.argument<String>("userName") ?: ""
                val lat = call.argument<Double>("latitude")
                val lng = call.argument<Double>("longitude")
                result.success(startAdvertising(name, lat, lng))
            }

            "stopAdvertising" -> {
                stopAdvertising()
                result.success(true)
            }

            "updateLocation" -> {
                val lat = call.argument<Double>("latitude")
                val lng = call.argument<Double>("longitude")
                updateAdvertising(lat, lng)
                result.success(true)
            }

            "notifyAll" -> {
                val data = call.argument<String>("data") ?: ""
                val count = notifyAllSubscribers(data.toByteArray(Charsets.UTF_8))
                result.success(count)
            }

            "getState" -> result.success(getState())

            "stop" -> {
                stop()
                result.success(true)
            }

            else -> result.notImplemented()
        }
    }

    // =========================================================================
    // Initialization
    // =========================================================================

    private fun initialize(): Boolean {
        bluetoothManager = context.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager
        bluetoothAdapter = bluetoothManager?.adapter

        if (bluetoothAdapter == null) {
            Log.e(TAG, "Bluetooth not available")
            return false
        }

        advertiser = bluetoothAdapter?.bluetoothLeAdvertiser
        if (advertiser == null) {
            Log.e(TAG, "BLE Advertising not supported")
            return false
        }

        return true
    }

    // =========================================================================
    // GATT Server
    // =========================================================================

    private fun startGattServer(): Boolean {
        if (isGattRunning) return true

        try {
            gattServer = bluetoothManager?.openGattServer(context, gattCallback)
            if (gattServer == null) {
                Log.e(TAG, "Failed to open GATT server")
                return false
            }

            gattServer!!.addService(createGattService())
            isGattRunning = true
            Log.d(TAG, "GATT server started")
            return true
        } catch (e: SecurityException) {
            Log.e(TAG, "GATT server permission denied: ${e.message}")
            return false
        } catch (e: Exception) {
            Log.e(TAG, "GATT server error: ${e.message}")
            return false
        }
    }

    private fun createGattService(): BluetoothGattService {
        val service = BluetoothGattService(SERVICE_UUID, BluetoothGattService.SERVICE_TYPE_PRIMARY)

        // TX — client writes mesh messages here
        val txChar = BluetoothGattCharacteristic(
            TX_CHAR_UUID,
            BluetoothGattCharacteristic.PROPERTY_WRITE or
                    BluetoothGattCharacteristic.PROPERTY_WRITE_NO_RESPONSE,
            BluetoothGattCharacteristic.PERMISSION_WRITE
        )

        // RX — server notifies mesh messages to clients
        rxCharacteristic = BluetoothGattCharacteristic(
            RX_CHAR_UUID,
            BluetoothGattCharacteristic.PROPERTY_READ or
                    BluetoothGattCharacteristic.PROPERTY_NOTIFY,
            BluetoothGattCharacteristic.PERMISSION_READ
        )

        val cccd = BluetoothGattDescriptor(
            CCCD_UUID,
            BluetoothGattDescriptor.PERMISSION_READ or BluetoothGattDescriptor.PERMISSION_WRITE
        )
        rxCharacteristic!!.addDescriptor(cccd)

        service.addCharacteristic(txChar)
        service.addCharacteristic(rxCharacteristic!!)
        return service
    }

    // ---- GATT callbacks ----------------------------------------------------

    private val gattCallback = object : BluetoothGattServerCallback() {

        override fun onConnectionStateChange(device: BluetoothDevice, status: Int, newState: Int) {
            try {
                val address = device.address
                when (newState) {
                    BluetoothGattServer.STATE_CONNECTED -> {
                        Log.d(TAG, "Device connected: $address")
                        connectedDevices[address] = device
                        incomingBuffers[address] = StringBuilder()
                    }
                    BluetoothGattServer.STATE_DISCONNECTED -> {
                        Log.d(TAG, "Device disconnected: $address")
                        connectedDevices.remove(address)
                        subscribedDevices.remove(address)
                        incomingBuffers.remove(address)
                    }
                }
            } catch (e: SecurityException) {
                Log.e(TAG, "Connection state change error: ${e.message}")
            }
        }

        override fun onCharacteristicWriteRequest(
            device: BluetoothDevice,
            requestId: Int,
            characteristic: BluetoothGattCharacteristic,
            preparedWrite: Boolean,
            responseNeeded: Boolean,
            offset: Int,
            value: ByteArray?
        ) {
            try {
                if (characteristic.uuid == TX_CHAR_UUID && value != null) {
                    handleIncomingWrite(device, value)
                }
                if (responseNeeded) {
                    gattServer?.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, 0, null)
                }
            } catch (e: SecurityException) {
                Log.e(TAG, "Write request error: ${e.message}")
            }
        }

        override fun onCharacteristicReadRequest(
            device: BluetoothDevice,
            requestId: Int,
            offset: Int,
            characteristic: BluetoothGattCharacteristic
        ) {
            try {
                if (characteristic.uuid == RX_CHAR_UUID) {
                    gattServer?.sendResponse(
                        device, requestId, BluetoothGatt.GATT_SUCCESS, 0,
                        characteristic.value ?: byteArrayOf()
                    )
                }
            } catch (e: SecurityException) {
                Log.e(TAG, "Read request error: ${e.message}")
            }
        }

        override fun onDescriptorWriteRequest(
            device: BluetoothDevice,
            requestId: Int,
            descriptor: BluetoothGattDescriptor,
            preparedWrite: Boolean,
            responseNeeded: Boolean,
            offset: Int,
            value: ByteArray?
        ) {
            try {
                if (descriptor.uuid == CCCD_UUID) {
                    val address = device.address
                    if (value?.contentEquals(BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE) == true) {
                        subscribedDevices.add(address)
                        Log.d(TAG, "Notifications enabled for $address")
                    } else {
                        subscribedDevices.remove(address)
                        Log.d(TAG, "Notifications disabled for $address")
                    }
                }
                if (responseNeeded) {
                    gattServer?.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, 0, null)
                }
            } catch (e: SecurityException) {
                Log.e(TAG, "Descriptor write error: ${e.message}")
            }
        }

        override fun onMtuChanged(device: BluetoothDevice, mtu: Int) {
            Log.d(TAG, "MTU changed: $mtu for ${device.address}")
        }
    }

    // ---- Incoming write assembly -------------------------------------------

    private fun handleIncomingWrite(device: BluetoothDevice, value: ByteArray) {
        val address = device.address
        val chunk = String(value, StandardCharsets.UTF_8)
        Log.d(TAG, "Write from $address: ${chunk.take(50)}...")

        val buffer = incomingBuffers.getOrPut(address) { StringBuilder() }
        buffer.append(chunk)

        val accumulated = buffer.toString()
        if (accumulated.endsWith("\n\n") || isCompleteJson(accumulated)) {
            val messageData = accumulated.trimEnd('\n')
            incomingBuffers[address] = StringBuilder()

            Log.d(TAG, "Complete message from $address (${messageData.length} chars)")

            mainHandler.post {
                methodChannel?.invokeMethod("onBleMessageReceived", mapOf(
                    "deviceId" to address,
                    "data" to messageData
                ))
            }
        }
    }

    private fun isCompleteJson(str: String): Boolean {
        val trimmed = str.trim()
        return try {
            if (trimmed.startsWith("{") && trimmed.endsWith("}")) {
                org.json.JSONObject(trimmed)
                true
            } else false
        } catch (_: Exception) {
            false
        }
    }

    // =========================================================================
    // BLE Advertising
    // =========================================================================

    private fun startAdvertising(name: String, lat: Double?, lng: Double?): Boolean {
        if (isAdvertising) stopAdvertising()

        userName = name
        latitude = lat
        longitude = lng

        try {
            bluetoothAdapter?.name = "$NAME_PREFIX$name"

            val settings = AdvertiseSettings.Builder()
                .setAdvertiseMode(AdvertiseSettings.ADVERTISE_MODE_LOW_LATENCY)
                .setTxPowerLevel(AdvertiseSettings.ADVERTISE_TX_POWER_HIGH)
                .setConnectable(true)
                .setTimeout(0)
                .build()

            advertiser?.startAdvertising(settings, buildAdvertiseData(), advertiseCallback)
            Log.d(TAG, "Advertising started: $NAME_PREFIX$name")
            return true
        } catch (e: SecurityException) {
            Log.e(TAG, "Advertising permission denied: ${e.message}")
            return false
        } catch (e: Exception) {
            Log.e(TAG, "Advertising error: ${e.message}")
            return false
        }
    }

    private fun buildAdvertiseData(): AdvertiseData {
        val builder = AdvertiseData.Builder()
            .setIncludeDeviceName(true)
            .addServiceUuid(ParcelUuid(SERVICE_UUID))

        val lat = latitude
        val lng = longitude
        if (lat != null && lng != null) {
            builder.addManufacturerSpecificData(MANUFACTURER_ID, encodeLocation(lat, lng))
        }

        return builder.build()
    }

    private fun encodeLocation(lat: Double, lng: Double): ByteArray {
        val buffer = ByteBuffer.allocate(16).order(ByteOrder.BIG_ENDIAN)
        buffer.putDouble(lat)
        buffer.putDouble(lng)
        return buffer.array()
    }

    private fun updateAdvertising(lat: Double?, lng: Double?) {
        latitude = lat
        longitude = lng

        if (!isAdvertising) return

        // Restart advertising with updated data
        try { advertiser?.stopAdvertising(advertiseCallback) } catch (_: SecurityException) {}
        try {
            val settings = AdvertiseSettings.Builder()
                .setAdvertiseMode(AdvertiseSettings.ADVERTISE_MODE_LOW_LATENCY)
                .setTxPowerLevel(AdvertiseSettings.ADVERTISE_TX_POWER_HIGH)
                .setConnectable(true)
                .setTimeout(0)
                .build()

            advertiser?.startAdvertising(settings, buildAdvertiseData(), advertiseCallback)
        } catch (e: Exception) {
            Log.e(TAG, "Advertising update error: ${e.message}")
        }
    }

    private val advertiseCallback = object : AdvertiseCallback() {
        override fun onStartSuccess(settingsInEffect: AdvertiseSettings) {
            isAdvertising = true
            Log.d(TAG, "Advertising started successfully")
            mainHandler.post {
                methodChannel?.invokeMethod("onBleAdvertisingStarted", true)
            }
        }

        override fun onStartFailure(errorCode: Int) {
            isAdvertising = false
            val reason = when (errorCode) {
                ADVERTISE_FAILED_DATA_TOO_LARGE         -> "data too large"
                ADVERTISE_FAILED_TOO_MANY_ADVERTISERS   -> "too many advertisers"
                ADVERTISE_FAILED_ALREADY_STARTED         -> "already started"
                ADVERTISE_FAILED_INTERNAL_ERROR          -> "internal error"
                ADVERTISE_FAILED_FEATURE_UNSUPPORTED     -> "feature unsupported"
                else                                     -> "unknown ($errorCode)"
            }
            Log.e(TAG, "Advertising failed: $reason")
            mainHandler.post {
                methodChannel?.invokeMethod("onBleAdvertisingStarted", false)
            }
        }
    }

    private fun stopAdvertising() {
        if (!isAdvertising) return
        try { advertiser?.stopAdvertising(advertiseCallback) } catch (_: SecurityException) {}
        isAdvertising = false
        Log.d(TAG, "Advertising stopped")
    }

    // =========================================================================
    // Notify (GATT Server -> connected clients)
    // =========================================================================

    private fun notifyAllSubscribers(data: ByteArray): Int {
        val rx = rxCharacteristic ?: return 0
        var count = 0

        for (address in subscribedDevices.toList()) {
            val device = connectedDevices[address] ?: continue
            try {
                rx.value = data
                if (gattServer?.notifyCharacteristicChanged(device, rx, false) == true) count++
            } catch (e: SecurityException) {
                Log.e(TAG, "Notify error for $address: ${e.message}")
            }
        }

        Log.d(TAG, "Notified $count/${subscribedDevices.size} subscribers")
        return count
    }

    // =========================================================================
    // State & lifecycle
    // =========================================================================

    private fun getState(): Map<String, Any> = mapOf(
        "isAdvertising" to isAdvertising,
        "isGattRunning" to isGattRunning,
        "connectedCount" to connectedDevices.size,
        "subscribedCount" to subscribedDevices.size
    )

    fun stop() {
        stopAdvertising()

        try { gattServer?.close() } catch (_: Exception) {}
        gattServer = null
        isGattRunning = false

        connectedDevices.clear()
        subscribedDevices.clear()
        incomingBuffers.clear()

        // Restore default Bluetooth name
        try { bluetoothAdapter?.name = Build.MODEL } catch (_: SecurityException) {}

        Log.d(TAG, "BLE Peripheral stopped")
    }
}
