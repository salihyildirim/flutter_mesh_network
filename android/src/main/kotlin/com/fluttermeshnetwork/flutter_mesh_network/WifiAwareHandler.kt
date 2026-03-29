package com.fluttermeshnetwork.flutter_mesh_network

import android.app.Activity
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.net.wifi.aware.*
import android.net.wifi.rtt.RangingRequest
import android.net.wifi.rtt.RangingResult
import android.net.wifi.rtt.RangingResultCallback
import android.net.wifi.rtt.WifiRttManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.nio.charset.StandardCharsets

/**
 * Handles Wi-Fi Aware (NAN) publish, subscribe, messaging, and RTT ranging.
 *
 * Channel: `flutter_mesh_network/nearby`
 *
 * Service info format: "MSH|userId|userName|lat|lng"
 */
class WifiAwareHandler(private val context: Context) {

    companion object {
        private const val TAG = "MshNearby"
        private const val MAX_NAN_MESSAGE_SIZE = 255
        private const val CHUNK_HEADER_OVERHEAD = 40
        private const val CHUNK_SEND_DELAY_MS = 50L
        private const val SERVICE_INFO_PREFIX = "MSH"
    }

    private val mainHandler = Handler(Looper.getMainLooper())
    private var methodChannel: MethodChannel? = null
    private var activity: Activity? = null

    // Wi-Fi Aware state
    private var wifiAwareManager: WifiAwareManager? = null
    private var wifiAwareSession: WifiAwareSession? = null
    private var publishSession: PublishDiscoverySession? = null
    private var subscribeSession: SubscribeDiscoverySession? = null

    // Peer tracking: peerId -> PeerHandle
    private val peerHandles = mutableMapOf<String, PeerHandle>()
    // Reverse mapping: PeerHandle hashCode -> peerId
    private val peerIdByHandle = mutableMapOf<Int, String>()
    // Peer info cache
    private val peerInfo = mutableMapOf<String, MutableMap<String, Any>>()

    // Cached publish config (for re-attach after availability restore)
    private var cachedServiceName: String? = null
    private var cachedUserId: String? = null
    private var cachedUserName: String? = null
    private var cachedLatitude: Double? = null
    private var cachedLongitude: Double? = null

    // Message chunking: key -> accumulated data
    private val incomingChunks = mutableMapOf<String, StringBuilder>()

    // Messages queued while no session is available
    private val pendingMessages = mutableListOf<Pair<String, ByteArray>>()

    // Availability receiver
    private var availabilityReceiver: BroadcastReceiver? = null
    private var isReceiverRegistered = false

    init {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            wifiAwareManager =
                context.getSystemService(Context.WIFI_AWARE_SERVICE) as? WifiAwareManager
        }
        registerAvailabilityReceiver()
    }

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
            "isAvailable" -> result.success(isWifiAwareAvailable())

            "publish" -> {
                val serviceName = call.argument<String>("serviceName") ?: "_mshmesh._tcp"
                val userId = call.argument<String>("userId") ?: ""
                val userName = call.argument<String>("userName") ?: ""
                val latitude = call.argument<Double>("latitude")
                val longitude = call.argument<Double>("longitude")
                startPublish(serviceName, userId, userName, latitude, longitude, result)
            }

            "subscribe" -> {
                val serviceName = call.argument<String>("serviceName") ?: "_mshmesh._tcp"
                startSubscribe(serviceName, result)
            }

            "sendMessage" -> {
                val peerId = call.argument<String>("peerId") ?: ""
                val data = call.argument<String>("data") ?: ""
                sendMessageToPeer(peerId, data, result)
            }

            "measureDistance" -> {
                val peerId = call.argument<String>("peerId") ?: ""
                measureDistance(peerId, result)
            }

            "stopPublish" -> {
                publishSession?.close()
                publishSession = null
                Log.d(TAG, "Publish stopped")
                result.success(true)
            }

            "stopSubscribe" -> {
                subscribeSession?.close()
                subscribeSession = null
                Log.d(TAG, "Subscribe stopped")
                result.success(true)
            }

            "updateLocation" -> {
                cachedLatitude = call.argument<Double>("latitude")
                cachedLongitude = call.argument<Double>("longitude")
                updatePublishServiceInfo()
                result.success(true)
            }

            "getPeers" -> {
                val peers = peerInfo.map { (id, info) ->
                    mapOf("id" to id) + info.mapValues { it.value.toString() }
                }
                result.success(peers)
            }

            else -> result.notImplemented()
        }
    }

    // =========================================================================
    // Availability
    // =========================================================================

    private fun isWifiAwareAvailable(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return false
        val manager = wifiAwareManager ?: return false
        return context.packageManager.hasSystemFeature("android.hardware.wifi.aware")
                && manager.isAvailable
    }

    private fun registerAvailabilityReceiver() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        if (wifiAwareManager == null) return

        availabilityReceiver = object : BroadcastReceiver() {
            override fun onReceive(ctx: Context, intent: Intent) {
                if (intent.action != WifiAwareManager.ACTION_WIFI_AWARE_STATE_CHANGED) return

                val available = wifiAwareManager?.isAvailable == true
                Log.d(TAG, "Wi-Fi Aware availability changed: $available")

                mainHandler.post {
                    methodChannel?.invokeMethod("onAvailabilityChanged", available)
                }

                if (available && wifiAwareSession == null && cachedServiceName != null) {
                    Log.d(TAG, "Re-attaching after availability restore")
                    reattachSession()
                }

                if (!available) {
                    wifiAwareSession = null
                    publishSession = null
                    subscribeSession = null
                    peerHandles.clear()
                    peerIdByHandle.clear()
                }
            }
        }

        val filter = IntentFilter(WifiAwareManager.ACTION_WIFI_AWARE_STATE_CHANGED)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            context.registerReceiver(availabilityReceiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            context.registerReceiver(availabilityReceiver, filter)
        }
        isReceiverRegistered = true
    }

    // =========================================================================
    // Session management
    // =========================================================================

    private fun attachAndRun(onAttached: (WifiAwareSession) -> Unit, onFailed: () -> Unit) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            onFailed()
            return
        }

        wifiAwareSession?.let {
            onAttached(it)
            return
        }

        wifiAwareManager?.attach(object : AttachCallback() {
            override fun onAttached(session: WifiAwareSession) {
                Log.d(TAG, "Wi-Fi Aware session attached")
                wifiAwareSession = session
                onAttached(session)
            }

            override fun onAttachFailed() {
                Log.e(TAG, "Wi-Fi Aware attach failed")
                wifiAwareSession = null
                onFailed()
            }

            override fun onAwareSessionTerminated() {
                Log.w(TAG, "Wi-Fi Aware session terminated")
                wifiAwareSession = null
                publishSession = null
                subscribeSession = null
            }
        }, mainHandler)
    }

    private fun reattachSession() {
        val serviceName = cachedServiceName ?: return
        val userId = cachedUserId ?: return
        val userName = cachedUserName ?: return

        attachAndRun(
            onAttached = { session ->
                doPublish(session, serviceName, userId, userName, cachedLatitude, cachedLongitude)
                doSubscribe(session, serviceName)
            },
            onFailed = { Log.e(TAG, "Re-attach failed") }
        )
    }

    // =========================================================================
    // Publish
    // =========================================================================

    private fun startPublish(
        serviceName: String,
        userId: String,
        userName: String,
        latitude: Double?,
        longitude: Double?,
        result: MethodChannel.Result
    ) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            result.success(false)
            return
        }

        cachedServiceName = serviceName
        cachedUserId = userId
        cachedUserName = userName
        cachedLatitude = latitude
        cachedLongitude = longitude

        attachAndRun(
            onAttached = { session ->
                doPublish(session, serviceName, userId, userName, latitude, longitude)
                result.success(true)
            },
            onFailed = { result.success(false) }
        )
    }

    private fun doPublish(
        session: WifiAwareSession,
        serviceName: String,
        userId: String,
        userName: String,
        latitude: Double?,
        longitude: Double?
    ) {
        val serviceInfo = buildServiceInfo(userId, userName, latitude, longitude)

        val config = PublishConfig.Builder()
            .setServiceName(serviceName)
            .setPublishType(PublishConfig.PUBLISH_TYPE_UNSOLICITED)
            .setServiceSpecificInfo(serviceInfo)
            .setTerminateNotificationEnabled(true)
            .build()

        session.publish(config, object : DiscoverySessionCallback() {
            override fun onPublishStarted(session: PublishDiscoverySession) {
                Log.d(TAG, "Publish started: $serviceName")
                publishSession = session
                processPendingMessages()
            }

            override fun onMessageReceived(peerHandle: PeerHandle, message: ByteArray) {
                handleIncomingMessage(peerHandle, message)
            }

            override fun onMessageSendSucceeded(msgId: Int) {
                Log.d(TAG, "Publish message sent (id=$msgId)")
            }

            override fun onMessageSendFailed(msgId: Int) {
                Log.w(TAG, "Publish message send failed (id=$msgId)")
            }

            override fun onSessionTerminated() {
                Log.w(TAG, "Publish session terminated")
                publishSession = null
            }
        }, mainHandler)
    }

    private fun buildServiceInfo(
        userId: String,
        userName: String,
        latitude: Double?,
        longitude: Double?
    ): ByteArray {
        val latStr = latitude?.let { "%.6f".format(it) } ?: ""
        val lngStr = longitude?.let { "%.6f".format(it) } ?: ""
        val info = "$SERVICE_INFO_PREFIX|$userId|$userName|$latStr|$lngStr"
        val bytes = info.toByteArray(StandardCharsets.UTF_8)
        return if (bytes.size > MAX_NAN_MESSAGE_SIZE) bytes.copyOf(MAX_NAN_MESSAGE_SIZE) else bytes
    }

    private fun updatePublishServiceInfo() {
        val userId = cachedUserId ?: return
        val userName = cachedUserName ?: return
        val session = publishSession ?: return

        val serviceInfo = buildServiceInfo(userId, userName, cachedLatitude, cachedLongitude)
        val config = PublishConfig.Builder()
            .setServiceName(cachedServiceName ?: "_mshmesh._tcp")
            .setPublishType(PublishConfig.PUBLISH_TYPE_UNSOLICITED)
            .setServiceSpecificInfo(serviceInfo)
            .setTerminateNotificationEnabled(true)
            .build()

        try {
            session.updatePublish(config)
            Log.d(TAG, "Publish service info updated with new location")
        } catch (e: Exception) {
            Log.e(TAG, "Failed to update publish: ${e.message}")
        }
    }

    // =========================================================================
    // Subscribe
    // =========================================================================

    private fun startSubscribe(serviceName: String, result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            result.success(false)
            return
        }

        attachAndRun(
            onAttached = { session ->
                doSubscribe(session, serviceName)
                result.success(true)
            },
            onFailed = { result.success(false) }
        )
    }

    private fun doSubscribe(session: WifiAwareSession, serviceName: String) {
        val config = SubscribeConfig.Builder()
            .setServiceName(serviceName)
            .setSubscribeType(SubscribeConfig.SUBSCRIBE_TYPE_PASSIVE)
            .setTerminateNotificationEnabled(true)
            .build()

        session.subscribe(config, object : DiscoverySessionCallback() {
            override fun onSubscribeStarted(session: SubscribeDiscoverySession) {
                Log.d(TAG, "Subscribe started: $serviceName")
                subscribeSession = session
            }

            override fun onServiceDiscovered(
                peerHandle: PeerHandle,
                serviceSpecificInfo: ByteArray?,
                matchFilter: MutableList<ByteArray>?
            ) {
                handlePeerDiscovered(peerHandle, serviceSpecificInfo)
            }

            override fun onServiceDiscoveredWithinRange(
                peerHandle: PeerHandle,
                serviceSpecificInfo: ByteArray?,
                matchFilter: MutableList<ByteArray>?,
                distanceMm: Int
            ) {
                handlePeerDiscovered(peerHandle, serviceSpecificInfo, distanceMm)
            }

            override fun onMessageReceived(peerHandle: PeerHandle, message: ByteArray) {
                handleIncomingMessage(peerHandle, message)
            }

            override fun onMessageSendSucceeded(msgId: Int) {
                Log.d(TAG, "Subscribe message sent (id=$msgId)")
            }

            override fun onMessageSendFailed(msgId: Int) {
                Log.w(TAG, "Subscribe message send failed (id=$msgId)")
            }

            override fun onSessionTerminated() {
                Log.w(TAG, "Subscribe session terminated")
                subscribeSession = null
            }
        }, mainHandler)
    }

    // =========================================================================
    // Peer discovery
    // =========================================================================

    private fun handlePeerDiscovered(
        peerHandle: PeerHandle,
        serviceSpecificInfo: ByteArray?,
        distanceMm: Int? = null
    ) {
        val info = serviceSpecificInfo?.toString(StandardCharsets.UTF_8) ?: ""
        val parts = info.split("|")

        if (parts.isEmpty() || parts[0] != SERVICE_INFO_PREFIX) {
            Log.w(TAG, "Ignoring non-MSH peer: $info")
            return
        }

        val userId = parts.getOrElse(1) { peerHandle.hashCode().toString() }
        val userName = parts.getOrElse(2) { "Unknown" }
        val latStr = parts.getOrElse(3) { "" }
        val lngStr = parts.getOrElse(4) { "" }

        // Track peer
        peerHandles[userId] = peerHandle
        peerIdByHandle[peerHandle.hashCode()] = userId
        peerInfo[userId] = mutableMapOf(
            "name" to userName,
            "lastSeen" to System.currentTimeMillis()
        )

        // Build node data for Flutter
        val nodeData = mutableMapOf<String, Any>(
            "id" to userId,
            "name" to userName,
            "connectionType" to "wifiAware",
            "lastSeen" to java.time.Instant.now().toString()
        )

        if (latStr.isNotEmpty()) {
            try { nodeData["latitude"] = latStr.toDouble() } catch (_: Exception) {}
        }
        if (lngStr.isNotEmpty()) {
            try { nodeData["longitude"] = lngStr.toDouble() } catch (_: Exception) {}
        }
        if (distanceMm != null && distanceMm > 0) {
            nodeData["distanceMm"] = distanceMm
            nodeData["signalStrength"] = estimateRssiFromDistance(distanceMm)
        }

        Log.d(TAG, "Peer discovered: $userName ($userId) distance=${distanceMm}mm")

        mainHandler.post {
            methodChannel?.invokeMethod("onPeerDiscovered", nodeData)
        }

        // Establish bidirectional communication
        sendPing(peerHandle)
    }

    private fun estimateRssiFromDistance(distanceMm: Int): Int {
        val meters = distanceMm / 1000.0
        return when {
            meters < 5   -> -30
            meters < 20  -> -50
            meters < 50  -> -60
            meters < 100 -> -70
            meters < 200 -> -80
            else         -> -90
        }
    }

    private fun sendPing(peerHandle: PeerHandle) {
        val pingData = "PING|${cachedUserId ?: ""}|${cachedUserName ?: ""}"
        val session = subscribeSession ?: publishSession ?: return

        try {
            session.sendMessage(
                peerHandle, 0, pingData.toByteArray(StandardCharsets.UTF_8)
            )
        } catch (e: Exception) {
            Log.w(TAG, "Failed to send ping: ${e.message}")
        }
    }

    // =========================================================================
    // Message handling
    // =========================================================================

    private fun handleIncomingMessage(peerHandle: PeerHandle, message: ByteArray) {
        val data = String(message, StandardCharsets.UTF_8)
        val peerId = peerIdByHandle[peerHandle.hashCode()]

        // Handle ping — register the peer from the publisher side
        if (data.startsWith("PING|")) {
            val parts = data.split("|")
            val userId = parts.getOrElse(1) { "" }
            val userName = parts.getOrElse(2) { "" }
            if (userId.isNotEmpty()) {
                peerHandles[userId] = peerHandle
                peerIdByHandle[peerHandle.hashCode()] = userId
                peerInfo[userId] = mutableMapOf(
                    "name" to userName,
                    "lastSeen" to System.currentTimeMillis()
                )
                Log.d(TAG, "Ping received from $userName ($userId)")
            }
            return
        }

        // Chunked message
        if (data.startsWith("CHUNK|")) {
            handleChunkedMessage(peerId ?: peerHandle.hashCode().toString(), data)
            return
        }

        // Full (single-frame) message
        val payload = if (data.startsWith("FULL|")) data.removePrefix("FULL|") else data
        Log.d(TAG, "Message from $peerId: ${payload.take(50)}...")

        mainHandler.post {
            methodChannel?.invokeMethod("onMessageReceived", payload)
        }
    }

    private fun handleChunkedMessage(peerId: String, data: String) {
        val parts = data.split("|", limit = 5)
        if (parts.size < 5) return

        val msgId = parts[1]
        val partIndex = parts[2].toIntOrNull() ?: return
        val totalParts = parts[3].toIntOrNull() ?: return
        val chunkData = parts[4]
        val key = "$peerId:$msgId"

        if (partIndex == 0) {
            incomingChunks[key] = StringBuilder()
        }
        incomingChunks[key]?.append(chunkData)

        Log.d(TAG, "Chunk $partIndex/$totalParts for msg $msgId")

        if (partIndex == totalParts - 1) {
            val fullMessage = incomingChunks.remove(key)?.toString() ?: return
            Log.d(TAG, "Message assembled (${fullMessage.length} chars)")
            mainHandler.post {
                methodChannel?.invokeMethod("onMessageReceived", fullMessage)
            }
        }
    }

    // =========================================================================
    // Send message
    // =========================================================================

    private fun sendMessageToPeer(peerId: String, data: String, result: MethodChannel.Result) {
        val peerHandle = peerHandles[peerId]
        if (peerHandle == null) {
            Log.w(TAG, "No PeerHandle for $peerId — queuing message")
            pendingMessages.add(peerId to data.toByteArray(StandardCharsets.UTF_8))
            result.success(false)
            return
        }

        val session = publishSession ?: subscribeSession
        if (session == null) {
            Log.w(TAG, "No active session — queuing message")
            pendingMessages.add(peerId to data.toByteArray(StandardCharsets.UTF_8))
            result.success(false)
            return
        }

        try {
            sendViaSession(session, peerHandle, peerId, data)
            result.success(true)
        } catch (e: Exception) {
            Log.e(TAG, "Send message failed: ${e.message}")
            result.success(false)
        }
    }

    private fun sendViaSession(
        session: DiscoverySession,
        peerHandle: PeerHandle,
        peerId: String,
        data: String
    ) {
        val dataBytes = data.toByteArray(StandardCharsets.UTF_8)
        val maxPayload = MAX_NAN_MESSAGE_SIZE - CHUNK_HEADER_OVERHEAD

        if (dataBytes.size <= MAX_NAN_MESSAGE_SIZE - 5) {
            // Fits in a single frame
            val frame = "FULL|$data".toByteArray(StandardCharsets.UTF_8).let { bytes ->
                if (bytes.size > MAX_NAN_MESSAGE_SIZE) bytes.copyOf(MAX_NAN_MESSAGE_SIZE) else bytes
            }
            session.sendMessage(peerHandle, msgIdTick(), frame)
            Log.d(TAG, "Single message sent to $peerId (${dataBytes.size} bytes)")
        } else {
            // Chunk the message
            val msgId = (System.currentTimeMillis() % 10000).toString()
            val chunks = data.chunked(maxPayload)
            Log.d(TAG, "Sending ${chunks.size} chunks to $peerId")

            chunks.forEachIndexed { index, chunk ->
                mainHandler.postDelayed({
                    try {
                        val frame = "CHUNK|$msgId|$index|${chunks.size}|$chunk"
                            .toByteArray(StandardCharsets.UTF_8).let { bytes ->
                                if (bytes.size > MAX_NAN_MESSAGE_SIZE)
                                    bytes.copyOf(MAX_NAN_MESSAGE_SIZE) else bytes
                            }
                        session.sendMessage(peerHandle, msgIdTick(), frame)
                    } catch (e: Exception) {
                        Log.e(TAG, "Chunk $index send failed: ${e.message}")
                    }
                }, index * CHUNK_SEND_DELAY_MS)
            }
        }
    }

    private fun processPendingMessages() {
        if (pendingMessages.isEmpty()) return
        val session = publishSession ?: subscribeSession ?: return
        val snapshot = pendingMessages.toList()
        pendingMessages.clear()

        for ((peerId, data) in snapshot) {
            val peerHandle = peerHandles[peerId] ?: continue
            try {
                val text = String(data, StandardCharsets.UTF_8)
                sendViaSession(session, peerHandle, peerId, text)
                Log.d(TAG, "Pending message sent to $peerId")
            } catch (e: Exception) {
                Log.w(TAG, "Failed to send pending message to $peerId: ${e.message}")
            }
        }
    }

    /** Simple incrementing message ID (wraps at 255). */
    private var msgIdCounter = 0
    private fun msgIdTick(): Int {
        msgIdCounter = (msgIdCounter + 1) and 0xFF
        return msgIdCounter
    }

    // =========================================================================
    // RTT Ranging
    // =========================================================================

    private fun measureDistance(peerId: String, result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.P) {
            result.success(null)
            return
        }

        val peerHandle = peerHandles[peerId]
        if (peerHandle == null) {
            Log.w(TAG, "No PeerHandle for $peerId — cannot measure distance")
            result.success(null)
            return
        }

        val rttManager =
            context.getSystemService(Context.WIFI_RTT_RANGING_SERVICE) as? WifiRttManager
        if (rttManager == null || !rttManager.isAvailable) {
            Log.w(TAG, "Wi-Fi RTT not available")
            result.success(null)
            return
        }

        try {
            val request = RangingRequest.Builder()
                .addWifiAwarePeer(peerHandle)
                .build()

            val executor = activity?.mainExecutor ?: context.mainExecutor
            rttManager.startRanging(request, executor, object : RangingResultCallback() {
                override fun onRangingResults(results: MutableList<RangingResult>) {
                    val r = results.firstOrNull()
                    if (r != null && r.status == RangingResult.STATUS_SUCCESS) {
                        Log.d(TAG, "RTT distance to $peerId: ${r.distanceMm}mm")
                        result.success(r.distanceMm)
                    } else {
                        Log.w(TAG, "Ranging returned no success result")
                        result.success(null)
                    }
                }

                override fun onRangingFailure(code: Int) {
                    Log.e(TAG, "Ranging failure, code=$code")
                    result.success(null)
                }
            })
        } catch (e: SecurityException) {
            Log.e(TAG, "RTT permission denied: ${e.message}")
            result.success(null)
        } catch (e: Exception) {
            Log.e(TAG, "RTT error: ${e.message}")
            result.success(null)
        }
    }

    // =========================================================================
    // Lifecycle
    // =========================================================================

    fun dispose() {
        publishSession?.close()
        subscribeSession?.close()
        wifiAwareSession?.close()
        publishSession = null
        subscribeSession = null
        wifiAwareSession = null

        peerHandles.clear()
        peerIdByHandle.clear()
        peerInfo.clear()
        incomingChunks.clear()
        pendingMessages.clear()

        if (isReceiverRegistered) {
            try {
                context.unregisterReceiver(availabilityReceiver)
            } catch (_: Exception) {}
            isReceiverRegistered = false
        }
    }
}
