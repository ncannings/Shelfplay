import AVFoundation
import SwiftUI
import UIKit

/// AVFoundation capture: live EAN/UPC detection plus still photos for cover recognition.
final class CameraController: NSObject, AVCaptureMetadataOutputObjectsDelegate, AVCapturePhotoCaptureDelegate, @unchecked Sendable {
    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "shelfplay.camera")
    private let metadataOutput = AVCaptureMetadataOutput()
    private let photoOutput = AVCapturePhotoOutput()
    private var configured = false
    private var photoContinuation: CheckedContinuation<UIImage?, Never>?

    /// Called on the main thread with each detected barcode while `detectsBarcodes` is true.
    var onBarcode: ((String) -> Void)?
    var detectsBarcodes = true

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
