import CoreMedia
import CoreVideo
import Foundation
import ScreenCaptureKit

/// Captures the main display. ScreenCaptureKit only delivers a picture when something changes, so a
/// still screen costs nothing. The newest picture is the one that gets encoded.
///
/// The Mac's own mouse pointer is left out of the picture on purpose. Its position is sent separately
/// (Session.startCursorSender) and Windows draws it on top, so it moves without waiting for a picture.
final class DisplayCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    private var stream: SCStream?
    private let queue = DispatchQueue(label: "com.macconnect.capture")
    private let onFrame: (CVPixelBuffer) -> Void
    private var onStop: ((String) -> Void)?
    let width: Int
    let height: Int

    private init(filter: SCContentFilter, configuration: SCStreamConfiguration, width: Int, height: Int, onFrame: @escaping (CVPixelBuffer) -> Void) {
        self.width = width
        self.height = height
        self.onFrame = onFrame
        super.init()
        // SCStream only accepts its delegate at creation time, so it is built after `self` exists.
        self.stream = SCStream(filter: filter, configuration: configuration, delegate: self)
    }

    static func prepare(onFrame: @escaping (CVPixelBuffer) -> Void) async throws -> DisplayCapture {
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
        configuration.colorSpaceName = CGColorSpace.sRGB
        configuration.showsCursor = false
        // Up to 60 pictures a second are offered. The sender takes only the newest one it can keep up with.
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        configuration.queueDepth = 2

        let filter = SCContentFilter(display: display, excludingWindows: [])
        return DisplayCapture(filter: filter, configuration: configuration, width: width, height: height, onFrame: onFrame)
    }

    func start(onStop: @escaping (String) -> Void) async throws {
        guard let stream else {
            throw SocketError.message("The capture stream was not created")
        }
        self.onStop = onStop
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        Log.line("Capturing the main display at \(width)x\(height)")
    }

    func stop() async {
        guard let stream else { return }
        do {
            try await stream.stopCapture()
        } catch {
            Log.line("Stop capture: \(error.localizedDescription)")
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, CMSampleBufferIsValid(sampleBuffer) else { return }
        if isEmptyFrame(sampleBuffer) { return }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        onFrame(pixelBuffer)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onStop?(error.localizedDescription)
    }

    /// Status frames that carry no new picture.
    private func isEmptyFrame(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int,
              let status = SCFrameStatus(rawValue: raw) else {
            return false
        }
        return status == .idle || status == .blank
    }
}
