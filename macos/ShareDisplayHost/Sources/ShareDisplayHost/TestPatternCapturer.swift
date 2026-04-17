import CoreVideo
import Foundation
import QuartzCore
import WebRTC

final class TestPatternCapturer: RTCVideoCapturer {
    private var timer: Timer?
    private let width: Int32
    private let height: Int32
    private let fps: Int32

    init(delegate: RTCVideoCapturerDelegate, width: Int32, height: Int32, fps: Int32) {
        self.width = width
        self.height = height
        self.fps = fps
        super.init(delegate: delegate)
    }

    func start() {
        stop()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.timer = Timer.scheduledTimer(withTimeInterval: 1.0 / Double(self.fps), repeats: true) { [weak self] _ in
                self?.emitFrame()
            }
            if let timer = self.timer {
                RunLoop.main.add(timer, forMode: .common)
            }
        }
    }

    func stop() {
        DispatchQueue.main.async { [weak self] in
            self?.timer?.invalidate()
            self?.timer = nil
        }
    }

    private func emitFrame() {
        guard let pixelBuffer = Self.makeTestPatternBuffer(width: width, height: height) else { return }
        let rtcBuffer = RTCCVPixelBuffer(pixelBuffer: pixelBuffer)
        let ns = Int64(CACurrentMediaTime() * 1_000_000_000)
        let frame = RTCVideoFrame(buffer: rtcBuffer, rotation: ._0, timeStampNs: ns)
        delegate?.capturer(self, didCapture: frame)
    }

    private static func makeTestPatternBuffer(width: Int32, height: Int32) -> CVPixelBuffer? {
        var pixelBuffer: CVPixelBuffer?
        let attrs: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any],
        ]
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            Int(width),
            Int(height),
            kCVPixelFormatType_32BGRA,
            attrs as CFDictionary,
            &pixelBuffer
        )
        guard status == kCVReturnSuccess, let buffer = pixelBuffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let t = CACurrentMediaTime()
        for y in 0..<Int(height) {
            let row = base.advanced(by: y * bytesPerRow).assumingMemoryBound(to: UInt32.self)
            for x in 0..<Int(width) {
                let r = UInt32((sin(t + Double(x) * 0.02) * 127 + 128))
                let g = UInt32((sin(t + Double(y) * 0.02) * 127 + 128))
                let b = UInt32((sin(t * 2) * 127 + 128))
                row[x] = 0xFF_00_00_00 | (b << 16) | (g << 8) | r
            }
        }
        return buffer
    }
}
