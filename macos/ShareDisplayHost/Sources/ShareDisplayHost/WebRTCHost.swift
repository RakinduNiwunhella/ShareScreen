import Foundation
@preconcurrency import ScreenCaptureKit
@preconcurrency import WebRTC

enum StreamMode: String, CaseIterable, Identifiable {
    case testPattern
    case displayCapture

    var id: String { rawValue }

    var title: String {
        switch self {
        case .testPattern: return "Test pattern (no screen permission)"
        case .displayCapture: return "Capture display (Screen Recording)"
        }
    }
}

final class WebRTCHost: NSObject, RTCPeerConnectionDelegate {
    private let factory: RTCPeerConnectionFactory
    private var peerConnection: RTCPeerConnection?
    private var videoSource: RTCVideoSource?
    private var videoTrack: RTCVideoTrack?
    private var testCapturer: TestPatternCapturer?
    private let screenCapture = ScreenCaptureService()

    private var signaling: SignalingServer?
    private var mDNS = MDNSAdvertiser()

    var onIceCandidate: ((RTCIceCandidate) -> Void)?
    var onConnectionChange: ((RTCIceConnectionState) -> Void)?

    override init() {
        RTCInitializeSSL()
        let encoder = RTCDefaultVideoEncoderFactory()
        let decoder = RTCDefaultVideoDecoderFactory()
        self.factory = RTCPeerConnectionFactory(encoderFactory: encoder, decoderFactory: decoder)
        super.init()
    }

    deinit {
        RTCCleanupSSL()
    }

    @MainActor
    func configureVideo(mode: StreamMode, display: SCDisplay?, width: Int32, height: Int32, fps: Int32) async throws {
        await stopMedia()
        let source = factory.videoSource()
        videoSource = source
        let track = factory.videoTrack(with: source, trackId: "video0")
        videoTrack = track

        switch mode {
        case .testPattern:
            let cap = TestPatternCapturer(delegate: source, width: width, height: height, fps: fps)
            testCapturer = cap
            cap.start()
        case .displayCapture:
            guard let display else { throw ScreenCaptureServiceError.noDisplays }
            try await screenCapture.start(display: display, videoSource: source, width: width, height: height, fps: fps)
        }
    }

    @MainActor
    func stopMedia() async {
        testCapturer?.stop()
        testCapturer = nil
        await screenCapture.stop()
        videoTrack = nil
        videoSource = nil
    }

    func startSignaling(port: UInt16, token: String) throws {
        signaling?.stop()
        let server = SignalingServer(port: port, expectedToken: token)
        signaling = server

        server.onHello = { [weak self] in
            Task { await self?.createAndSendOffer() }
        }
        server.onAnswer = { [weak self] sdp in
            Task { await self?.applyAnswer(sdp) }
        }
        server.onCandidate = { [weak self] cand, idx, mid in
            self?.addRemoteCandidate(cand, sdpMLineIndex: idx, sdpMid: mid)
        }
        server.onDisconnected = { [weak self] in
            self?.peerConnection?.close()
            self?.peerConnection = nil
        }
        try server.start()
    }

    func publishMDNS(port: Int, token: String, hostName: String) {
        let hash = Pairing.hashToken(token)
        mDNS.start(name: hostName, port: port, txt: ["hash": String(hash.prefix(16))])
    }

    func stopSignaling() {
        signaling?.stop()
        signaling = nil
        mDNS.stop()
    }

    func signalingSendOffer(_ sdp: String) {
        signaling?.sendOffer(sdp)
    }

    func signalingSendCandidate(_ candidate: RTCIceCandidate) {
        signaling?.sendCandidate(candidate.sdp, sdpMLineIndex: candidate.sdpMLineIndex, sdpMid: candidate.sdpMid)
    }

    private func buildPeerConnection() -> RTCPeerConnection {
        let config = RTCConfiguration()
        config.iceServers = [RTCIceServer(urlStrings: ["stun:stun.l.google.com:19302"])]
        config.sdpSemantics = .unifiedPlan
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: ["DtlsSrtpKeyAgreement": "true"])
        let pc = factory.peerConnection(with: config, constraints: constraints, delegate: self)!
        if let track = videoTrack {
            let streamIds = ["sharedisplay"]
            pc.add(track, streamIds: streamIds)
        }
        return pc
    }

    private func createAndSendOffer() async {
        if peerConnection == nil {
            peerConnection = buildPeerConnection()
        }
        guard let pc = peerConnection else { return }
        let constraints = RTCMediaConstraints(
            mandatoryConstraints: [
                "OfferToReceiveAudio": "false",
                "OfferToReceiveVideo": "false",
            ],
            optionalConstraints: nil
        )
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            pc.offer(for: constraints) { [weak self] sdp, error in
                guard let self else {
                    cont.resume()
                    return
                }
                if let error {
                    print("offer error: \(error)")
                    cont.resume()
                    return
                }
                guard let sdp else {
                    cont.resume()
                    return
                }
                pc.setLocalDescription(sdp) { err in
                    if let err {
                        print("setLocalDescription error: \(err)")
                    } else {
                        let sdpText = sdp.sdp
                        self.signalingSendOffer(sdpText)
                    }
                    cont.resume()
                }
            }
        }
    }

    private func applyAnswer(_ sdp: String) async {
        guard let pc = peerConnection else { return }
        let answer = RTCSessionDescription(type: .answer, sdp: sdp)
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            pc.setRemoteDescription(answer) { err in
                if let err {
                    print("setRemoteDescription answer error: \(err)")
                }
                cont.resume()
            }
        }
    }

    private func addRemoteCandidate(_ sdp: String, sdpMLineIndex: Int32, sdpMid: String?) {
        guard let pc = peerConnection else { return }
        let cand = RTCIceCandidate(sdp: sdp, sdpMLineIndex: sdpMLineIndex, sdpMid: sdpMid)
        pc.add(cand) { err in
            if let err {
                print("addIceCandidate error: \(err)")
            }
        }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}

    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}

    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}

    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        onConnectionChange?(newState)
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}

    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        signalingSendCandidate(candidate)
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}

    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange state: RTCPeerConnectionState) {}

    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd rtpReceiver: RTCRtpReceiver, streams mediaStreams: [RTCMediaStream]) {}

    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove rtpReceiver: RTCRtpReceiver) {}
}
