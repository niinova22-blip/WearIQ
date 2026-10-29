import AVFoundation
import CoreImage
import UIKit

enum CameraError: LocalizedError {
    case unavailable
    case configurationFailed

    var errorDescription: String? {
        switch self {
        case .unavailable: String(localized: "No camera is available on this device.")
        case .configurationFailed: String(localized: "The camera could not be started.")
        }
    }
}

/// Owns the capture session. Frames are delivered on a background queue, throttled,
/// and the most recent frame can be grabbed as a still image. Nothing is written to disk.
final class CameraController: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "weariq.camera.session")
    private let videoQueue = DispatchQueue(label: "weariq.camera.video")
    private let output = AVCaptureVideoDataOutput()
    private let ciContext = CIContext()

    private let lock = NSLock()
    private var latestBuffer: CVPixelBuffer?
    private var lastDelivery = Date.distantPast

    /// Called on a background queue at most `frameRate` times per second.
    var onFrame: ((CVPixelBuffer) -> Void)?
    var frameRate: Double = 5

    static var authorizationStatus: AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .video)
    }

    static func requestAccess() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .video)
    }

    func start(position: AVCaptureDevice.Position) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            sessionQueue.async {
                do {
                    try self.configure(position: position)
                    self.session.startRunning()
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func stop() {
        sessionQueue.async {
            self.session.stopRunning()
            self.lock.withLock { self.latestBuffer = nil }
        }
    }

    /// Current frame as an upright still image.
    func captureStill() -> CGImage? {
        guard let buffer = lock.withLock({ latestBuffer }) else { return nil }
        let image = CIImage(cvPixelBuffer: buffer)
        return ciContext.createCGImage(image, from: image.extent)
    }

    private func configure(position: AVCaptureDevice.Position) throws {
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.inputs.forEach(session.removeInput)
        session.sessionPreset = .hd1920x1080
        // No microphone is used; leave the audio session to the voice guidance.
        session.automaticallyConfiguresApplicationAudioSession = false

        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position) else {
            throw CameraError.unavailable
        }
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else { throw CameraError.configurationFailed }
        session.addInput(input)

        if !session.outputs.contains(output) {
            output.alwaysDiscardsLateVideoFrames = true
            output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            guard session.canAddOutput(output) else { throw CameraError.configurationFailed }
            session.addOutput(output)
            output.setSampleBufferDelegate(self, queue: videoQueue)
        }
        if let connection = output.connection(with: .video) {
            // Deliver portrait, upright frames so Vision can use orientation .up.
            if connection.isVideoRotationAngleSupported(90) { connection.videoRotationAngle = 90 }
            if connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = position == .front
            }
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let now = Date()
        let deliver: Bool = lock.withLock {
            latestBuffer = buffer
            guard now.timeIntervalSince(lastDelivery) >= 1 / frameRate else { return false }
            lastDelivery = now
            return true
        }
        if deliver { onFrame?(buffer) }
    }
}
