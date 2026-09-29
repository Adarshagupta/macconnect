import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

/// Hardware H.264 encoder with no frame reordering. Each input picture produces one access unit
/// before the next one starts, so the stream does not sit in an encoder queue.
final class H264Encoder {
    private var session: VTCompressionSession?
    private let gate = NSLock()
    private let finished = DispatchSemaphore(value: 0)
    private var request: UInt64 = 0
    private var completed: UInt64 = 0
    private var encoded = Data()
    private var failed = false
    private var parameterSets = Data()
    private var frameIndex: Int64 = 0
    private var needsKeyframe = true
    private let callback: VTCompressionOutputCallback = { refcon, sourceFrameRefcon, status, _, sampleBuffer in
        guard let refcon, let sourceFrameRefcon else { return }
        let encoder = Unmanaged<H264Encoder>.fromOpaque(refcon).takeUnretainedValue()
        let ticket = UInt64(UInt(bitPattern: sourceFrameRefcon))
        encoder.finish(ticket: ticket, status: status, sampleBuffer: sampleBuffer)
    }

    init(width: Int, height: Int) throws {
        var session: VTCompressionSession?
        let spec: [CFString: Any] = [
            kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: kCFBooleanTrue!,
        ]
        let source: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: NSNumber(value: kCVPixelFormatType_32BGRA),
            kCVPixelBufferWidthKey: NSNumber(value: width),
            kCVPixelBufferHeightKey: NSNumber(value: height),
        ]
        var status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: Int32(width),
            height: Int32(height),
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: spec as CFDictionary,
            imageBufferAttributes: source as CFDictionary,
            compressedDataAllocator: nil,
            outputCallback: callback,
            refcon: Unmanaged.passUnretained(self).toOpaque(),
            compressionSessionOut: &session
        )
        if status != noErr || session == nil {
            status = VTCompressionSessionCreate(
                allocator: kCFAllocatorDefault,
                width: Int32(width),
                height: Int32(height),
                codecType: kCMVideoCodecType_H264,
                encoderSpecification: nil,
                imageBufferAttributes: source as CFDictionary,
                compressedDataAllocator: nil,
                outputCallback: callback,
                refcon: Unmanaged.passUnretained(self).toOpaque(),
                compressionSessionOut: &session
            )
        }
        guard status == noErr, let session else {
            throw SocketError.message("Could not start the H.264 encoder (\(status))")
        }
        self.session = session
        set(kVTCompressionPropertyKey_RealTime, kCFBooleanTrue!)
        set(kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse!)
        set(kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_High_AutoLevel)
        set(kVTCompressionPropertyKey_MaxKeyFrameInterval, NSNumber(value: 60))
        set(kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, NSNumber(value: 1))
        set(kVTCompressionPropertyKey_ExpectedFrameRate, NSNumber(value: 60))
        set(kVTCompressionPropertyKey_MaxFrameDelayCount, NSNumber(value: 0))
        set(kVTCompressionPropertyKey_AverageBitRate, NSNumber(value: 20_000_000))
        // A hard cap. Window drags change most of the screen, and a tight cap turns that into blocky glitches.
        let limits = [NSNumber(value: 5_000_000), NSNumber(value: 1)] as CFArray
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_DataRateLimits, value: limits)
        VTCompressionSessionPrepareToEncodeFrames(session)
        Log.line("H.264 encoder ready at \(width)x\(height)")
    }

    deinit {
        if let session {
            VTCompressionSessionInvalidate(session)
        }
    }

    func encode(_ pixelBuffer: CVPixelBuffer) -> Data? {
        guard let session else { return nil }
        gate.lock()
        request += 1
        let ticket = request
        failed = false
        encoded = Data()
        gate.unlock()
        while finished.wait(timeout: .now()) == .success {}

        let force = needsKeyframe
        frameIndex += 1
        let properties: CFDictionary? = force
            ? [kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue!] as CFDictionary
            : nil
        var flags = VTEncodeInfoFlags()
        let status = VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: CMTime(value: frameIndex, timescale: 60),
            duration: CMTime(value: 1, timescale: 60),
            frameProperties: properties,
            sourceFrameRefcon: UnsafeMutableRawPointer(bitPattern: UInt(ticket)),
            infoFlagsOut: &flags
        )
        guard status == noErr else {
            needsKeyframe = true
            return nil
        }
        // Wait long enough for a hard frame (a window being dragged). Giving up here drops a picture
        // the next one still refers to, which shows up as glitches until the next keyframe.
        if finished.wait(timeout: .now() + .milliseconds(150)) == .timedOut {
            needsKeyframe = true
            return nil
        }
        gate.lock()
        defer { gate.unlock() }
        if failed || completed != ticket || encoded.isEmpty {
            needsKeyframe = true
            return nil
        }
        needsKeyframe = false
        return encoded
    }

    private func finish(ticket: UInt64, status: OSStatus, sampleBuffer: CMSampleBuffer?) {
        gate.lock()
        defer { gate.unlock() }
        guard ticket == request else { return }
        if status == noErr, let sampleBuffer, let annex = annexB(sampleBuffer) {
            encoded = annex
            failed = false
        } else {
            encoded = Data()
            failed = true
        }
        completed = ticket
        finished.signal()
    }

    private func set(_ key: CFString, _ value: Any) {
        guard let session else { return }
        VTSessionSetProperty(session, key: key, value: value as CFTypeRef)
    }

    private func annexB(_ sampleBuffer: CMSampleBuffer) -> Data? {
        guard CMSampleBufferDataIsReady(sampleBuffer),
              let block = CMSampleBufferGetDataBuffer(sampleBuffer) else {
            return nil
        }
        var length = 0
        var pointer: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &pointer) == kCMBlockBufferNoErr,
              let pointer, length > 0 else {
            return nil
        }
        let bytes = UnsafeRawBufferPointer(start: pointer, count: length)
        var result = Data()
        if isKeyframe(sampleBuffer) {
            if parameterSets.isEmpty {
                parameterSets = parameterSetsAnnexB(sampleBuffer)
            }
            result.append(parameterSets)
        }
        var offset = 0
        while offset + 4 <= bytes.count {
            let nalLength = (Int(bytes[offset]) << 24) | (Int(bytes[offset + 1]) << 16) | (Int(bytes[offset + 2]) << 8) | Int(bytes[offset + 3])
            offset += 4
            guard nalLength > 0, offset + nalLength <= bytes.count else { return nil }
            result.append(contentsOf: [0, 0, 0, 1])
            result.append(contentsOf: bytes[offset..<(offset + nalLength)])
            offset += nalLength
        }
        return result.isEmpty ? nil : result
    }

    private func isKeyframe(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[CFString: Any]],
              let notSync = attachments.first?[kCMSampleAttachmentKey_NotSync] as? Bool else {
            return true
        }
        return !notSync
    }

    private func parameterSetsAnnexB(_ sampleBuffer: CMSampleBuffer) -> Data {
        guard let format = CMSampleBufferGetFormatDescription(sampleBuffer) else { return Data() }
        var data = Data()
        var index = 0
        while true {
            var pointer: UnsafePointer<UInt8>?
            var size = 0
            var count = 0
            let status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                format,
                parameterSetIndex: index,
                parameterSetPointerOut: &pointer,
                parameterSetSizeOut: &size,
                parameterSetCountOut: &count,
                nalUnitHeaderLengthOut: nil
            )
            guard status == noErr, let pointer, size > 0 else { break }
            data.append(contentsOf: [0, 0, 0, 1])
            data.append(pointer, count: size)
            index += 1
            if count > 0 && index >= count { break }
        }
        return data
    }
}
