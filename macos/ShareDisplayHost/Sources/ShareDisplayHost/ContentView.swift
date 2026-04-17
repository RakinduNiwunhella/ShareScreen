import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import ScreenCaptureKit
import SwiftUI

struct ContentView: View {
    @StateObject private var model = HostViewModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("ShareDisplay Host")
                .font(.title2)
                .bold()

            Picker("Mode", selection: $model.mode) {
                ForEach(StreamMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            if model.mode == .displayCapture {
                Picker("Display", selection: $model.selectedDisplayID) {
                    ForEach(model.displays, id: \.displayID) { d in
                        Text(displayLabel(d)).tag(UInt32(d.displayID))
                    }
                }
                .disabled(model.isRunning || model.displays.isEmpty)
            }

            HStack {
                Text("Port")
                TextField("8765", value: $model.port, format: .number)
                    .frame(width: 80)
                    .disabled(model.isRunning)
            }

            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Pairing PIN")
                        .font(.headline)
                    Text(model.token)
                        .font(.system(size: 28, weight: .semibold, design: .monospaced))
                    Text("Give this PIN to the Windows viewer (or scan the QR).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let qr = model.qrImage {
                    Image(nsImage: qr)
                        .interpolation(.none)
                        .resizable()
                        .frame(width: 140, height: 140)
                }
            }

            HStack {
                Button(model.isRunning ? "Stop" : "Start sharing") {
                    Task { await model.toggle() }
                }
                .keyboardShortcut(.defaultAction)

                if model.isRunning {
                    ProgressView()
                        .scaleEffect(0.8)
                }

                Spacer()

                Text(model.status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("Connection")
                    .font(.headline)
                Text("Windows connects to \(model.localIP ?? "this Mac"):\(model.port)")
                    .font(.caption)
                Text("ICE: \(model.iceState)")
                    .font(.caption)
            }

            Spacer(minLength: 0)
        }
        .padding(20)
        .task {
            await model.loadDisplays()
        }
    }

    private func displayLabel(_ d: SCDisplay) -> String {
        "Display \(d.displayID) — \(d.width)×\(d.height) @ \(Int(d.frame.origin.x)),\(Int(d.frame.origin.y))"
    }
}

@MainActor
final class HostViewModel: ObservableObject {
    @Published var mode: StreamMode = .testPattern
    @Published var port: UInt16 = 8765
    @Published var token: String = Pairing.generateToken()
    @Published var isRunning = false
    @Published var status = "Idle"
    @Published var iceState = "new"
    @Published var localIP: String?
    @Published var displays: [SCDisplay] = []
    @Published var selectedDisplayID: UInt32 = 0
    @Published var qrImage: NSImage?

    private let host = WebRTCHost()

    func loadDisplays() async {
        do {
            let list = try await ScreenCaptureService().availableDisplays()
            displays = list
            if let first = list.first {
                selectedDisplayID = UInt32(first.displayID)
            }
        } catch {
            status = "Could not list displays: \(error.localizedDescription)"
        }
    }

    func toggle() async {
        if isRunning {
            await stop()
        } else {
            await start()
        }
    }

    private func start() async {
        status = "Starting…"
        token = Pairing.generateToken()
        localIP = NetworkHelpers.primaryIPv4Address()
        qrImage = QRCode.makeImage(from: connectionURI())

        host.onConnectionChange = { [weak self] state in
            Task { @MainActor in
                self?.iceState = String(describing: state)
            }
        }

        do {
            let w: Int32 = 1280
            let h: Int32 = 720
            let fps: Int32 = 30
            let display: SCDisplay? = displays.first { UInt32($0.displayID) == selectedDisplayID }
            try await host.configureVideo(mode: mode, display: display, width: w, height: h, fps: fps)
            try host.startSignaling(port: port, token: token)
            let name = ProcessInfo.processInfo.hostName
            host.publishMDNS(port: Int(port), token: token, hostName: name)
            isRunning = true
            status = "Waiting for Windows viewer…"
        } catch {
            status = "Failed: \(error.localizedDescription)"
            await host.stopMedia()
        }
    }

    private func stop() async {
        host.stopSignaling()
        await host.stopMedia()
        isRunning = false
        status = "Stopped"
        iceState = "new"
        qrImage = nil
    }

    private func connectionURI() -> String {
        let ip = localIP ?? "127.0.0.1"
        return "sharedisplay://connect?host=\(ip)&port=\(port)&token=\(token)"
    }
}

enum QRCode {
    static func makeImage(from text: String) -> NSImage? {
        let data = Data(text.utf8)
        let filter = CIFilter.qrCodeGenerator()
        filter.message = data
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        let ctx = CIContext()
        guard let cg = ctx.createCGImage(scaled, from: scaled.extent) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }
}
