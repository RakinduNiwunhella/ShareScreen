import Foundation
import Network

struct SignalingMessage: Codable {
    var type: String
    var token: String?
    var sdp: String?
    var candidate: String?
    var sdpMLineIndex: Int32?
    var sdpMid: String?
    var message: String?
}

enum SignalingServerError: Error {
    case invalidHello
    case notAuthenticated
}

final class SignalingServer {
    let port: UInt16
    private let queue = DispatchQueue(label: "SignalingServer")
    private var listener: NWListener?
    private var connection: NWConnection?
    private var buffer = Data()
    private let expectedToken: String
    private var authenticated = false

    var onHello: (() -> Void)?
    var onAnswer: ((String) -> Void)?
    var onCandidate: ((String, Int32, String?) -> Void)?
    var onDisconnected: (() -> Void)?

    init(port: UInt16, expectedToken: String) {
        self.port = port
        self.expectedToken = expectedToken
    }

    func start() throws {
        let parameters = NWParameters.tcp
        let listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port)!)
        listener.newConnectionHandler = { [weak self] conn in
            self?.queue.async {
                self?.accept(conn)
            }
        }
        listener.stateUpdateHandler = { state in
            if case .failed(let err) = state {
                print("Signaling listener failed: \(err)")
            }
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    func stop() {
        listener?.cancel()
        listener = nil
        connection?.cancel()
        connection = nil
        buffer.removeAll()
        authenticated = false
    }

    private func accept(_ conn: NWConnection) {
        if connection != nil {
            conn.cancel()
            return
        }
        connection = conn
        conn.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            if case .ready = state {
                self.receiveLoop()
            } else if case .failed = state {
                self.queue.async {
                    if self.connection === conn {
                        self.connection = nil
                        self.buffer.removeAll()
                        self.authenticated = false
                        self.onDisconnected?()
                    }
                }
            } else if case .cancelled = state {
                self.queue.async {
                    if self.connection === conn {
                        self.connection = nil
                        self.buffer.removeAll()
                        self.authenticated = false
                        self.onDisconnected?()
                    }
                }
            }
        }
        conn.start(queue: queue)
    }

    private func receiveLoop() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            self.queue.async {
                if let data, !data.isEmpty {
                    self.buffer.append(data)
                    self.processBuffer()
                }
                if let error {
                    print("Signaling receive error: \(error)")
                }
                if isComplete {
                    self.connection?.cancel()
                    self.connection = nil
                    self.buffer.removeAll()
                    self.authenticated = false
                    self.onDisconnected?()
                    return
                }
                if self.connection != nil {
                    self.receiveLoop()
                }
            }
        }
    }

    private func processBuffer() {
        while let range = buffer.firstRange(of: Data([0x0A])) {
            let lineData = buffer.subdata(in: buffer.startIndex..<range.lowerBound)
            buffer.removeSubrange(buffer.startIndex...range.lowerBound)
            guard !lineData.isEmpty else { continue }
            handleLine(lineData)
        }
    }

    private func handleLine(_ lineData: Data) {
        let decoder = JSONDecoder()
        guard let msg = try? decoder.decode(SignalingMessage.self, from: lineData) else {
            sendError("invalid_json")
            return
        }
        switch msg.type {
        case "hello":
            guard let t = msg.token, t == expectedToken else {
                sendError("bad_token")
                authenticated = false
                return
            }
            authenticated = true
            send(["type": "hello_ok"])
            onHello?()
        case "answer":
            guard authenticated, let sdp = msg.sdp else { sendError("unauthorized"); return }
            onAnswer?(sdp)
        case "candidate":
            guard authenticated, let c = msg.candidate, let idx = msg.sdpMLineIndex else {
                sendError("unauthorized")
                return
            }
            onCandidate?(c, idx, msg.sdpMid)
        default:
            break
        }
    }

    func sendOffer(_ sdp: String) {
        let msg = SignalingMessage(type: "offer", token: nil, sdp: sdp, candidate: nil, sdpMLineIndex: nil, sdpMid: nil, message: nil)
        sendMessage(msg)
    }

    func sendAnswer(_ sdp: String) {
        let msg = SignalingMessage(type: "answer", token: nil, sdp: sdp, candidate: nil, sdpMLineIndex: nil, sdpMid: nil, message: nil)
        sendMessage(msg)
    }

    func sendCandidate(_ candidate: String, sdpMLineIndex: Int32, sdpMid: String?) {
        let msg = SignalingMessage(type: "candidate", token: nil, sdp: nil, candidate: candidate, sdpMLineIndex: sdpMLineIndex, sdpMid: sdpMid, message: nil)
        sendMessage(msg)
    }

    private func sendError(_ text: String) {
        let msg = SignalingMessage(type: "error", token: nil, sdp: nil, candidate: nil, sdpMLineIndex: nil, sdpMid: nil, message: text)
        sendMessage(msg)
    }

    private func send(_ dict: [String: String]) {
        guard let data = try? JSONSerialization.data(withJSONObject: dict) else { return }
        var out = data
        out.append(0x0A)
        connection?.send(content: out, completion: .contentProcessed { _ in })
    }

    private func sendMessage(_ msg: SignalingMessage) {
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(msg) else { return }
        var out = data
        out.append(0x0A)
        connection?.send(content: out, completion: .contentProcessed { _ in })
    }
}
