import CoreGraphics
import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import ImageIO
import ScreenCaptureKit

final class DisplayCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    private let stream: SCStream
    private let queue = DispatchQueue(label: "com.macconnect.capture")
    private let context = CIContext(options: [.useSoftwareRenderer: false])
    private let onFrame: (Data) -> Void
    private var onStop: ((String) -> Void)?
    private var lastFrame = 0.0
    let width: Int
    let height: Int

    private init(stream: SCStream, width: Int, height: Int, onFrame: @escaping (Data) -> Void) {
        self.stream = stream
        self.width = width
        self.height = height
        self.onFrame = onFrame
        super.init()
    }

    static func prepare(onFrame: @escaping (Data) -> Void) async throws -> DisplayCapture {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let mainID = CGMainDisplayID()
        guard let display = content.displays.first(where: { $0.displayID == mainID }) ?? content.displays.first else {
            throw SocketError.message("No display is available to capture")
        }

        let longSide = max(display.width, display.height)
        let scale = min(1.0, 1920.0 / Double(max(longSide, 1)))
        var width = Int((Double(display.width) * scale).rounded(.down))
        var height = Int((Double(display.height) * scale).rounded(.down))
        width = max(2, width - (width % 2))
        height = max(2, height - (height % 2))

        let configuration = SCStreamConfiguration()
        configuration.width = width
        configuration.height = height
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.showsCursor = true
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 20)
        configuration.queueDepth = 3

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let stream = SCStream(filter: filter, configuration: configuration, delegate: nil)
        let capture = DisplayCapture(stream: stream, width: width, height: height, onFrame: onFrame)
        stream.delegate = capture
        return capture
    }

    func start(onStop: @escaping (String) -> Void) async throws {
        self.onStop = onStop
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        Log.line("Capturing the main display at \(width)x\(height)")
    }

    func stop() async {
        do {
            try await stream.stopCapture()
        } catch {
            Log.line("Stop capture: \(error.localizedDescription)")
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        guard outputType == .screen, CMSampleBufferIsValid(sampleBuffer), let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return
        }
        if isBlank(sampleBuffer) {
            return
        }
        let now = CFAbsoluteTimeGetCurrent()
        if now - lastFrame < 0.045 {
            return
        }
        lastFrame = now
        guard let jpeg = jpegData(from: pixelBuffer) else { return }
        onFrame(jpeg)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onStop?(error.localizedDescription)
    }

    private func isBlank(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int,
              let status = SCFrameStatus(rawValue: raw) else {
            return false
        }
        return status == .idle || status == .blank
    }

    private func jpegData(from pixelBuffer: CVPixelBuffer) -> Data? {
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        guard let cgImage = context.createCGImage(image, from: image.extent) else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else {
            return nil
        }
        let options = [kCGImageDestinationLossyCompressionQuality: 0.6] as CFDictionary
        CGImageDestinationAddImage(destination, cgImage, options)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
