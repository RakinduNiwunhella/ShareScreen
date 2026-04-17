import CoreMedia
import CoreVideo
import Foundation
import QuartzCore
import ScreenCaptureKit
import WebRTC

enum ScreenCaptureServiceError: Error {
    case noDisplays
    case streamFailed
}

final class ScreenCaptureService: NSObject {
    private var stream: SCStream?
    private var videoSource: RTCVideoSource?
    private var capturer: ScreenFrameCapturer?
    private var width: Int32 = 1280
    private var height: Int32 = 720
    private var fps: Int32 = 30

    func availableDisplays() async throws -> [SCDisplay] {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        return content.displays
    }

    func start(
        display: SCDisplay,
        videoSource: RTCVideoSource,
        width: Int32,
        height: Int32,
        fps: Int32
    ) async throws {
        await stop()
        self.videoSource = videoSource
        self.width = width
        self.height = height
        self.fps = fps

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.width = Int(width)
        config.height = Int(height)
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = true
        config.queueDepth = 3

        let capturer = ScreenFrameCapturer(delegate: videoSource, fps: fps)
        self.capturer = capturer

        let output = StreamOutput(capturer: capturer)
        let sc = SCStream(filter: filter, configuration: config, delegate: nil)
        stream = sc
        try sc.addStreamOutput(output, type: .screen, sampleHandlerQueue: DispatchQueue(label: "sc.stream"))
        try await sc.startCapture()
    }

    func stop() async {
        if let stream {
            try? await stream.stopCapture()
        }
        stream = nil
        capturer = nil
        videoSource = nil
    }
}

private final class StreamOutput: NSObject, SCStreamOutput {
    private weak var capturer: ScreenFrameCapturer?

    init(capturer: ScreenFrameCapturer) {
        self.capturer = capturer
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        guard outputType == .screen else { return }
        capturer?.handle(sampleBuffer: sampleBuffer)
    }
}

/// Bridges CMSampleBuffer frames into WebRTC; throttles to target FPS.
final class ScreenFrameCapturer: RTCVideoCapturer {
    private var lastEmit: CFTimeInterval = 0
    private let minInterval: CFTimeInterval
    private let fps: Int32

    init(delegate: RTCVideoCapturerDelegate, fps: Int32) {
        self.fps = fps
        self.minInterval = 1.0 / max(1, Double(fps))
        super.init(delegate: delegate)
    }

    func handle(sampleBuffer: CMSampleBuffer) {
        let now = CACurrentMediaTime()
        if now - lastEmit < minInterval { return }
        lastEmit = now

        guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }

        let rtcBuffer = RTCCVPixelBuffer(pixelBuffer: pb)
        let ns = Int64(now * 1_000_000_000)
        let frame = RTCVideoFrame(buffer: rtcBuffer, rotation: ._0, timeStampNs: ns)
        delegate?.capturer(self, didCapture: frame)
    }
}
