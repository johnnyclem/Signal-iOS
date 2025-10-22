//
// Copyright 2025 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import AVFoundation
import Foundation
import ObjectiveC
import SignalRingRTC
import SignalServiceKit

private enum VideoCaptureAssociatedKeys {
    static var diagnostics = "org.signal.video.capture.diagnostics"
}

private final class SignalVideoCaptureDiagnostics: NSObject {
    let configurationQueue = DispatchQueue(label: "org.signal.video.capture.configuration", qos: .userInitiated)
    private let healthQueue = DispatchQueue(label: "org.signal.video.capture.health", qos: .utility)

    fileprivate var shouldAutoRestartCapture: Bool {
        get { shouldAutoRestartCaptureStorage.get() }
        set { shouldAutoRestartCaptureStorage.set(newValue) }
    }

    private let shouldAutoRestartCaptureStorage = AtomicBool(false, lock: .sharedGlobal)

    private var observers: [NSObjectProtocol] = []
    private weak var trackedSession: AVCaptureSession?

    func attach(to session: AVCaptureSession, controller: VideoCaptureController) {
        healthQueue.async { [weak self, weak controller] in
            guard let self else { return }
            if self.trackedSession === session { return }
            self.removeObserversLocked()
            self.trackedSession = session

            let center = NotificationCenter.default
            let runtime = center.addObserver(forName: .AVCaptureSessionRuntimeError, object: session, queue: nil) { [weak controller, weak self] notification in
                guard let self else { return }
                let error = notification.userInfo?[AVCaptureSessionErrorKey] as? NSError
                Logger.warn("Video capture runtime error: \(String(describing: error))")
                // Restart capture asynchronously so that transient encoder stalls or dropped-frame cascades recover.
                self.scheduleRestartIfNecessary(controller: controller)
            }
            let interrupted = center.addObserver(forName: .AVCaptureSessionWasInterrupted, object: session, queue: nil) { notification in
                let reasonRaw = notification.userInfo?[AVCaptureSessionInterruptionReasonKey] as? NSNumber
                let reason = reasonRaw.flatMap { AVCaptureSession.InterruptionReason(rawValue: $0.intValue) }
                Logger.info("Video capture session interrupted: \(String(describing: reason))")
            }
            let interruptionEnded = center.addObserver(forName: .AVCaptureSessionInterruptionEnded, object: session, queue: nil) { [weak controller, weak self] _ in
                guard let self else { return }
                Logger.info("Video capture session interruption ended")
                self.scheduleRestartIfNecessary(controller: controller)
            }
            observers = [runtime, interrupted, interruptionEnded]
        }
    }

    private func scheduleRestartIfNecessary(controller: VideoCaptureController?) {
        healthQueue.asyncAfter(deadline: .now() + .milliseconds(150)) { [weak self, weak controller] in
            guard let self, let controller, self.shouldAutoRestartCapture else { return }
            controller.restartCaptureAfterError()
        }
    }

    func removeObservers() {
        healthQueue.sync {
            self.removeObserversLocked()
            self.trackedSession = nil
        }
    }

    private func removeObserversLocked() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll(keepingCapacity: false)
    }

    deinit {
        removeObservers()
    }
}

extension VideoCaptureController {
    static func makeSignalOptimized() -> VideoCaptureController {
        let controller = VideoCaptureController()
        controller.configureForHighQualityCapture()
        controller.signalDiagnostics.shouldAutoRestartCapture = false
        return controller
    }

    func configureForHighQualityCapture() {
        let diagnostics = signalDiagnostics
        diagnostics.configurationQueue.async { [weak self] in
            guard let self, let session = self.captureSession else { return }
            session.beginConfiguration()
            defer {
                session.commitConfiguration()
                diagnostics.attach(to: session, controller: self)
            }

            let preferredPreset: AVCaptureSession.Preset
            if session.canSetSessionPreset(.hd1920x1080) {
                preferredPreset = .hd1920x1080
            } else if session.canSetSessionPreset(.hd1280x720) {
                preferredPreset = .hd1280x720
            } else if session.canSetSessionPreset(.high) {
                preferredPreset = .high
            } else {
                preferredPreset = session.sessionPreset
            }
            if session.sessionPreset != preferredPreset {
                session.sessionPreset = preferredPreset
            }

            for input in session.inputs {
                guard let deviceInput = input as? AVCaptureDeviceInput, deviceInput.device.hasMediaType(.video) else { continue }
                configure(device: deviceInput.device)
            }

            configureVideoOutputs(in: session)
        }
    }

    func signalStartCapture() {
        let diagnostics = signalDiagnostics
        diagnostics.shouldAutoRestartCapture = true
        startCapture()
        configureForHighQualityCapture()
    }

    func signalStopCapture() {
        signalDiagnostics.shouldAutoRestartCapture = false
        stopCapture()
    }

    func switchCameraAndOptimize(isUsingFrontCamera: Bool) {
        switchCamera(isUsingFrontCamera: isUsingFrontCamera)
        configureForHighQualityCapture()
    }

    fileprivate func restartCaptureAfterError() {
        DispatchQueue.main.async {
            let diagnostics = self.signalDiagnostics
            guard diagnostics.shouldAutoRestartCapture else { return }
            if let session = self.captureSession, session.isRunning {
                return
            }
            self.startCapture()
            self.configureForHighQualityCapture()
        }
    }

    private func configure(device: AVCaptureDevice) {
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }

            if #available(iOS 17.0, *), device.isCenterStageEnabled {
                device.isCenterStageEnabled = false
            }
            if #available(iOS 15.0, *), device.isGeometricDistortionCorrectionSupported {
                device.isGeometricDistortionCorrectionEnabled = true
            }
            if device.isLowLightBoostSupported {
                device.automaticallyEnablesLowLightBoostWhenAvailable = true
            }
            if #available(iOS 13.0, *), device.supportedColorSpaces.contains(.sRGB) {
                // Force Rec. 709/sRGB primaries so that the captured buffer matches what WebRTC expects.
                device.activeColorSpace = .sRGB
            }
            if #available(iOS 14.1, *), device.isVideoHDREnabled {
                device.isVideoHDREnabled = false
            }
            if #available(iOS 15.4, *), device.isGlobalToneMappingSupported {
                device.isGlobalToneMappingEnabled = true
            }

            if let (format, frameRate) = bestFormat(for: device) {
                if device.activeFormat != format {
                    device.activeFormat = format
                }
                let frameDuration = CMTime(value: 1, timescale: CMTimeScale(frameRate))
                device.activeVideoMinFrameDuration = frameDuration
                device.activeVideoMaxFrameDuration = frameDuration
            }
        } catch {
            Logger.error("Failed to configure capture device: \(error)")
        }
    }

    private func configureVideoOutputs(in session: AVCaptureSession) {
        for output in session.outputs {
            guard let videoOutput = output as? AVCaptureVideoDataOutput else { continue }
            // Apple recommends NV12 output (kCVPixelFormatType_420YpCbCr8BiPlanar) for real-time encoding
            // because it maps directly onto hardware encoders and WebRTC expects Rec. 709 YUV buffers.
            // See "AVCaptureVideoDataOutput" and "Choosing Pixel Formats for Video Capture" in the
            // AVFoundation Programming Guide.
            var settings: [String: Any] = [:]
            let preferredPixelFormats: [OSType] = [kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
            if let supportedFormat = preferredPixelFormats.first(where: { videoOutput.availableVideoPixelFormatTypes.contains($0) }) {
                settings[kCVPixelBufferPixelFormatTypeKey as String] = supportedFormat
            }
            settings[kCVPixelBufferMetalCompatibilityKey as String] = true
            settings[kCVPixelBufferIOSurfacePropertiesKey as String] = [:]
            settings[kCVImageBufferColorPrimariesKey as String] = kCVImageBufferColorPrimaries_ITU_R_709_2
            settings[kCVImageBufferTransferFunctionKey as String] = kCVImageBufferTransferFunction_ITU_R_709_2
            settings[kCVImageBufferYCbCrMatrixKey as String] = kCVImageBufferYCbCrMatrix_ITU_R_709_2
            videoOutput.videoSettings = settings
            // Drop late frames to avoid building encoder backlog; WebRTC handles the lower frame cadence.
            videoOutput.alwaysDiscardsLateVideoFrames = true

            if let connection = videoOutput.connection(with: .video) {
                if connection.isVideoStabilizationSupported {
                    connection.preferredVideoStabilizationMode = .standard
                }
                if connection.isVideoOrientationSupported {
                    connection.videoOrientation = .portrait
                }
            }
        }
    }

    private func bestFormat(for device: AVCaptureDevice) -> (AVCaptureDevice.Format, Int)? {
        let preferredPixelFormats: [FourCharCode] = [kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
        let maxDimensions = CMVideoDimensions(width: 1920, height: 1080)
        let minDimensions = CMVideoDimensions(width: 1280, height: 720)

        let candidates = device.formats.compactMap { format -> (AVCaptureDevice.Format, CMVideoDimensions, Double)? in
            let description = format.formatDescription
            let dimensions = CMVideoFormatDescriptionGetDimensions(description)
            guard dimensions.width <= maxDimensions.width, dimensions.height <= maxDimensions.height else { return nil }
            guard dimensions.width >= minDimensions.width, dimensions.height >= minDimensions.height else { return nil }
            let pixelType = CMFormatDescriptionGetMediaSubType(description)
            guard preferredPixelFormats.contains(pixelType) else { return nil }
            guard let range = format.videoSupportedFrameRateRanges.sorted(by: { $0.maxFrameRate > $1.maxFrameRate }).first,
                  range.maxFrameRate >= 30 else { return nil }
            return (format, dimensions, range.maxFrameRate)
        }

        guard !candidates.isEmpty else { return nil }

        let best = candidates.sorted { lhs, rhs in
            let lhsScore = score(dimensions: lhs.1)
            let rhsScore = score(dimensions: rhs.1)
            if lhsScore == rhsScore {
                return lhs.2 > rhs.2
            }
            return lhsScore > rhsScore
        }.first!

        let cappedFrameRate = Int(min(best.2, 30))
        return (best.0, cappedFrameRate)
    }

    private func score(dimensions: CMVideoDimensions) -> Int {
        // Prefer 16:9 1080p, fall back to 720p.
        let targetWidth = 1920
        let targetHeight = 1080
        let areaScore = Int(dimensions.width * dimensions.height)
        let aspect = Double(dimensions.width) / Double(max(dimensions.height, 1))
        let aspectPenalty = abs(aspect - (16.0 / 9.0))
        let aspectScore = Int((1000 - min(999, aspectPenalty * 1000)))
        let resolutionBonus = dimensions.width >= targetWidth && dimensions.height >= targetHeight ? 1_000_000 : 0
        return resolutionBonus + areaScore + aspectScore
    }

    private var signalDiagnostics: SignalVideoCaptureDiagnostics {
        if let diagnostics = objc_getAssociatedObject(self, &VideoCaptureAssociatedKeys.diagnostics) as? SignalVideoCaptureDiagnostics {
            return diagnostics
        }
        let diagnostics = SignalVideoCaptureDiagnostics()
        objc_setAssociatedObject(self, &VideoCaptureAssociatedKeys.diagnostics, diagnostics, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return diagnostics
    }
}
