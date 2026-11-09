import AVFoundation
import SwiftUI
import UIKit
import Vision

/// Live sleeve-detection state for cover auto-capture.
enum CoverDetection: Equatable {
    case searching
    case holding(Double)   // 0…1 progress towards a steady capture
    case ready
}

/// AVFoundation capture: live EAN/UPC detection, live sleeve detection for cover auto-capture,
/// and still photos for cover recognition.
final class CameraController: NSObject, AVCaptureMetadataOutputObjectsDelegate, AVCapturePhotoCaptureDelegate,
                              AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "shelfplay.camera")
    private let metadataOutput = AVCaptureMetadataOutput()
    private let photoOutput = AVCapturePhotoOutput()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let videoQueue = DispatchQueue(label: "shelfplay.camera.frames")
    private var configured = false
    private var photoContinuation: CheckedContinuation<UIImage?, Never>?

    /// Called on the main thread with each detected barcode while `detectsBarcodes` is true.
    var onBarcode: ((String) -> Void)?
    var detectsBarcodes = true

    /// When true, frames are checked for a square sleeve; `onCoverDetection` reports progress on the main thread.
    var detectsCovers = false {
        didSet { if !detectsCovers { videoQueue.async { self.resetCoverTracking(rearm: false) } } }
    }
    var onCoverDetection: ((CoverDetection) -> Void)?

    // Sleeve tracking (video queue only).
    private var lastFrameTime = Date.distantPast
    private var lastBox: CGRect?
    private var steadyFrames = 0
    private var armed = true
    private var missingSince: Date?
    private var lastReported: CoverDetection = .searching
    private let steadyFramesNeeded = 5

    static var hasCamera: Bool { AVCaptureDevice.default(for: .video) != nil }

    func start() async -> Bool {
        guard Self.hasCamera else { return false }
        let granted: Bool
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: granted = true
        case .notDetermined: granted = await AVCaptureDevice.requestAccess(for: .video)
        default: granted = false
        }
        guard granted else { return false }
        return await withCheckedContinuation { cont in
            queue.async {
                if !self.configured { self.configure() }
                if !self.session.isRunning { self.session.startRunning() }
                cont.resume(returning: self.configured)
            }
        }
    }

    func stop() {
        queue.async { if self.session.isRunning { self.session.stopRunning() } }
    }

    private func configure() {
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
                ?? AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device) else { return }
        session.beginConfiguration()
        session.sessionPreset = .photo
        if session.canAddInput(input) { session.addInput(input) }
        if session.canAddOutput(metadataOutput) {
            session.addOutput(metadataOutput)
            metadataOutput.setMetadataObjectsDelegate(self, queue: .main)
            let wanted: [AVMetadataObject.ObjectType] = [.ean13, .ean8, .upce]
            metadataOutput.metadataObjectTypes = wanted.filter(metadataOutput.availableMetadataObjectTypes.contains)
        }
        if session.canAddOutput(photoOutput) { session.addOutput(photoOutput) }
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(self, queue: videoQueue)
        if session.canAddOutput(videoOutput) { session.addOutput(videoOutput) }
        session.commitConfiguration()
        if (try? device.lockForConfiguration()) != nil {
            if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
            if device.isAutoFocusRangeRestrictionSupported { device.autoFocusRangeRestriction = .near }
            device.unlockForConfiguration()
        }
        configured = true
    }

    func capturePhoto() async -> UIImage? {
        await withCheckedContinuation { cont in
            queue.async {
                guard self.session.isRunning else { cont.resume(returning: nil); return }
                self.photoContinuation = cont
                self.photoOutput.capturePhoto(with: AVCapturePhotoSettings(), delegate: self)
            }
        }
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        let image = photo.fileDataRepresentation().flatMap(UIImage.init(data:))
        queue.async {
            self.photoContinuation?.resume(returning: image)
            self.photoContinuation = nil
        }
    }

    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput objects: [AVMetadataObject], from connection: AVCaptureConnection) {
        guard detectsBarcodes,
              let code = objects.compactMap({ ($0 as? AVMetadataMachineReadableCodeObject)?.stringValue }).first,
              code.allSatisfy(\.isNumber) else { return }
        onBarcode?(code)
    }
}

extension CameraController {
    /// Look for a steady, square-ish sleeve filling a good part of the frame (~7 checks a second).
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard detectsCovers, Date.now.timeIntervalSince(lastFrameTime) > 0.14,
              let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lastFrameTime = .now

        let request = VNDetectRectanglesRequest()
        request.minimumAspectRatio = 0.75
        request.maximumAspectRatio = 1.0
        request.minimumSize = 0.4
        request.minimumConfidence = 0.75
        request.quadratureTolerance = 20
        request.maximumObservations = 1
        try? VNImageRequestHandler(cvPixelBuffer: pixels, orientation: .right).perform([request])

        guard let box = request.results?.first?.boundingBox, box.width * box.height > 0.18 else {
            // Re-arm once the sleeve has been out of view for a moment, so the same cover isn't scanned twice.
            if missingSince == nil { missingSince = .now }
            if let since = missingSince, Date.now.timeIntervalSince(since) > 0.8 { armed = true }
            lastBox = nil
            steadyFrames = 0
            report(.searching)
            return
        }
        missingSince = nil
        guard armed else { report(.searching); return }

        if let last = lastBox, abs(last.midX - box.midX) < 0.035, abs(last.midY - box.midY) < 0.035,
           abs(last.width - box.width) < 0.05, abs(last.height - box.height) < 0.05 {
            steadyFrames += 1
        } else {
            steadyFrames = 0
        }
        lastBox = box
        if steadyFrames >= steadyFramesNeeded {
            armed = false
            steadyFrames = 0
            report(.ready)
        } else {
            report(.holding(Double(steadyFrames + 1) / Double(steadyFramesNeeded + 1)))
        }
    }

    private func report(_ state: CoverDetection) {
        guard state != lastReported else { return }
        lastReported = state
        DispatchQueue.main.async { self.onCoverDetection?(state) }
    }

    private func resetCoverTracking(rearm: Bool) {
        lastBox = nil
        steadyFrames = 0
        if rearm { armed = true }
        report(.searching)
    }
}

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }

    func makeUIView(context: Context) -> PreviewView {
        let v = PreviewView()
        v.previewLayer.session = session
        v.previewLayer.videoGravity = .resizeAspectFill
        return v
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {}
}
