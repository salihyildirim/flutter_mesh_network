import Foundation
import MultipeerConnectivity
import Flutter

/// MultipeerConnectivity handler — the iOS equivalent of Android's Wi-Fi Aware / Nearby.
///
/// Uses MCSession, MCNearbyServiceAdvertiser, and MCNearbyServiceBrowser to form
/// an encrypted peer-to-peer mesh over Wi-Fi and Bluetooth simultaneously.
final class MeshConnectivityHandler: NSObject {

    // MARK: - Constants

    private static let peerPrefix = "MSH_"
    private static let defaultServiceType = "mesh-net" // max 15 chars, lowercase + hyphens

    // MARK: - Properties

    private var peerID: MCPeerID!
    private var session: MCSession!
    private var advertiser: MCNearbyServiceAdvertiser?
    private var browser: MCNearbyServiceBrowser?
    private weak var methodChannel: FlutterMethodChannel?

    private var isPublishing = false
    private var isSubscribing = false

    private var userId: String = ""
    private var userName: String = ""
    private var latitude: Double?
    private var longitude: Double?

    /// Maps MCPeerID.displayName -> userId
    private var peerUserIds: [String: String] = [:]
    /// Maps userId -> MCPeerID (for targeted sends)
    private var connectedPeers: [String: MCPeerID] = [:]

    // MARK: - Channel Setup

    func setMethodChannel(_ channel: FlutterMethodChannel) {
        methodChannel = channel
    }

    // MARK: - Public API

    func isAvailable() -> Bool {
        // MultipeerConnectivity is always available on iOS 7+
        return true
    }

    func startPublishing(
        serviceName: String,
        userId: String,
        userName: String,
        latitude: Double?,
        longitude: Double?
    ) -> Bool {
        guard !isPublishing else { return true }

        self.userId = userId
        self.userName = userName
        self.latitude = latitude
        self.longitude = longitude

        peerID = MCPeerID(displayName: "\(Self.peerPrefix)\(userName)")

        session = MCSession(
            peer: peerID,
            securityIdentity: nil,
            encryptionPreference: .required
        )
        session.delegate = self

        advertiser = MCNearbyServiceAdvertiser(
            peer: peerID,
            discoveryInfo: buildDiscoveryInfo(),
            serviceType: Self.defaultServiceType
        )
        advertiser?.delegate = self
        advertiser?.startAdvertisingPeer()

        isPublishing = true
        NSLog("[MeshNet] MPC: Advertising started as %@%@", Self.peerPrefix, userName)
        return true
    }

    func startSubscribing(serviceName: String) -> Bool {
        guard !isSubscribing else { return true }

        if session == nil {
            peerID = peerID ?? MCPeerID(displayName: "\(Self.peerPrefix)Unknown")
            session = MCSession(
                peer: peerID,
                securityIdentity: nil,
                encryptionPreference: .required
            )
            session.delegate = self
        }

        browser = MCNearbyServiceBrowser(
            peer: peerID,
            serviceType: Self.defaultServiceType
        )
        browser?.delegate = self
        browser?.startBrowsingForPeers()

        isSubscribing = true
        NSLog("[MeshNet] MPC: Browsing started")
        return true
    }

    func sendMessage(peerId: String, data: String) -> Bool {
        guard let targetPeer = connectedPeers[peerId],
              session.connectedPeers.contains(targetPeer) else {
            NSLog("[MeshNet] MPC: Peer not connected: %@", peerId)
            return false
        }

        guard let payload = data.data(using: .utf8) else { return false }

        do {
            try session.send(payload, toPeers: [targetPeer], with: .reliable)
            NSLog("[MeshNet] MPC: Message sent to %@", peerId)
            return true
        } catch {
            NSLog("[MeshNet] MPC: Send failed: %@", error.localizedDescription)
            return false
        }
    }

    func broadcastMessage(data: String) -> Int {
        guard !session.connectedPeers.isEmpty,
              let payload = data.data(using: .utf8) else { return 0 }

        do {
            try session.send(payload, toPeers: session.connectedPeers, with: .reliable)
            let count = session.connectedPeers.count
            NSLog("[MeshNet] MPC: Broadcast to %d peers", count)
            return count
        } catch {
            NSLog("[MeshNet] MPC: Broadcast failed: %@", error.localizedDescription)
            return 0
        }
    }

    func updateLocation(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude

        guard isPublishing else { return }

        // Restart advertiser with updated discovery info
        advertiser?.stopAdvertisingPeer()
        advertiser = MCNearbyServiceAdvertiser(
            peer: peerID,
            discoveryInfo: buildDiscoveryInfo(),
            serviceType: Self.defaultServiceType
        )
        advertiser?.delegate = self
        advertiser?.startAdvertisingPeer()
    }

    func getPeers() -> [[String: String]] {
        guard let session = session else { return [] }
        return session.connectedPeers.map { peer in
            let uid = peerUserIds[peer.displayName] ?? peer.displayName
            let name = peer.displayName
                .replacingOccurrences(of: Self.peerPrefix, with: "")
            return ["id": uid, "name": name]
        }
    }

    func measureDistance(peerId: String) -> Int? {
        // MultipeerConnectivity does not expose distance / RSSI information.
        return nil
    }

    // MARK: - Stop

    func stopPublish() {
        advertiser?.stopAdvertisingPeer()
        advertiser = nil
        isPublishing = false
        NSLog("[MeshNet] MPC: Advertising stopped")
    }

    func stopSubscribe() {
        browser?.stopBrowsingForPeers()
        browser = nil
        isSubscribing = false
        NSLog("[MeshNet] MPC: Browsing stopped")
    }

    func stop() {
        stopPublish()
        stopSubscribe()
        session?.disconnect()
        connectedPeers.removeAll()
        peerUserIds.removeAll()
    }

    // MARK: - Helpers

    private func buildDiscoveryInfo() -> [String: String] {
        var info: [String: String] = [
            "userId": userId,
            "userName": userName
        ]
        if let lat = latitude {
            info["lat"] = String(format: "%.6f", lat)
        }
        if let lng = longitude {
            info["lng"] = String(format: "%.6f", lng)
        }
        return info
    }

    private func invokeFlutter(_ method: String, arguments: Any? = nil) {
        DispatchQueue.main.async { [weak self] in
            self?.methodChannel?.invokeMethod(method, arguments: arguments)
        }
    }
}

// MARK: - MCNearbyServiceAdvertiserDelegate

extension MeshConnectivityHandler: MCNearbyServiceAdvertiserDelegate {

    func advertiser(
        _ advertiser: MCNearbyServiceAdvertiser,
        didReceiveInvitationFromPeer peerID: MCPeerID,
        withContext context: Data?,
        invitationHandler: @escaping (Bool, MCSession?) -> Void
    ) {
        let name = peerID.displayName
        if name.hasPrefix(Self.peerPrefix) {
            NSLog("[MeshNet] MPC: Auto-accepting invitation from %@", name)
            invitationHandler(true, session)
        } else {
            NSLog("[MeshNet] MPC: Rejecting non-mesh peer: %@", name)
            invitationHandler(false, nil)
        }
    }

    func advertiser(
        _ advertiser: MCNearbyServiceAdvertiser,
        didNotStartAdvertisingPeer error: Error
    ) {
        NSLog("[MeshNet] MPC: Advertising failed: %@", error.localizedDescription)
    }
}

// MARK: - MCNearbyServiceBrowserDelegate

extension MeshConnectivityHandler: MCNearbyServiceBrowserDelegate {

    func browser(
        _ browser: MCNearbyServiceBrowser,
        foundPeer peerID: MCPeerID,
        withDiscoveryInfo info: [String: String]?
    ) {
        let displayName = peerID.displayName
        guard displayName.hasPrefix(Self.peerPrefix) else { return }

        NSLog("[MeshNet] MPC: Found peer: %@", displayName)

        let peerUserId = info?["userId"] ?? displayName
        let peerUserName = info?["userName"]
            ?? displayName.replacingOccurrences(of: Self.peerPrefix, with: "")

        peerUserIds[displayName] = peerUserId
        connectedPeers[peerUserId] = peerID

        browser.invitePeer(peerID, to: session, withContext: nil, timeout: 10)

        var nodeData: [String: Any] = [
            "id": peerUserId,
            "name": peerUserName,
            "role": 0,
            "status": 0,
            "connectionType": 2, // wifiAware equivalent
            "lastSeen": ISO8601DateFormatter().string(from: Date())
        ]
        if let latStr = info?["lat"], let lat = Double(latStr) {
            nodeData["latitude"] = lat
        }
        if let lngStr = info?["lng"], let lng = Double(lngStr) {
            nodeData["longitude"] = lng
        }

        invokeFlutter("onPeerDiscovered", arguments: nodeData)
    }

    func browser(
        _ browser: MCNearbyServiceBrowser,
        lostPeer peerID: MCPeerID
    ) {
        let displayName = peerID.displayName
        NSLog("[MeshNet] MPC: Lost peer: %@", displayName)

        if let uid = peerUserIds[displayName] {
            connectedPeers.removeValue(forKey: uid)
        }
        peerUserIds.removeValue(forKey: displayName)
    }

    func browser(
        _ browser: MCNearbyServiceBrowser,
        didNotStartBrowsingForPeers error: Error
    ) {
        NSLog("[MeshNet] MPC: Browsing failed: %@", error.localizedDescription)
    }
}

// MARK: - MCSessionDelegate

extension MeshConnectivityHandler: MCSessionDelegate {

    func session(
        _ session: MCSession,
        peer peerID: MCPeerID,
        didChange state: MCSessionState
    ) {
        let name = peerID.displayName
        switch state {
        case .connected:
            NSLog("[MeshNet] MPC: Connected to %@", name)
        case .connecting:
            NSLog("[MeshNet] MPC: Connecting to %@", name)
        case .notConnected:
            NSLog("[MeshNet] MPC: Disconnected from %@", name)
            if let uid = peerUserIds[name] {
                connectedPeers.removeValue(forKey: uid)
            }
        @unknown default:
            break
        }
    }

    func session(
        _ session: MCSession,
        didReceive data: Data,
        fromPeer peerID: MCPeerID
    ) {
        guard let message = String(data: data, encoding: .utf8) else { return }
        NSLog("[MeshNet] MPC: Message from %@: %@...", peerID.displayName, String(message.prefix(50)))
        invokeFlutter("onMessageReceived", arguments: message)
    }

    // Required stubs — not used for mesh messaging.

    func session(
        _ session: MCSession,
        didReceive stream: InputStream,
        withName streamName: String,
        fromPeer peerID: MCPeerID
    ) {}

    func session(
        _ session: MCSession,
        didStartReceivingResourceWithName resourceName: String,
        fromPeer peerID: MCPeerID,
        with progress: Progress
    ) {}

    func session(
        _ session: MCSession,
        didFinishReceivingResourceWithName resourceName: String,
        fromPeer peerID: MCPeerID,
        at localURL: URL?,
        withError error: Error?
    ) {}
}
