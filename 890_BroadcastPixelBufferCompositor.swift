// BUILD 697 STATE CONTRACT: authoritative mutations pass through the declared domain owner/reducer; local values are drafts, projections, snapshots or caches only.
#if canImport(SwiftUI)
import Foundation
import CoreGraphics
import CoreImage
import CoreVideo
import UIKit

// MARK: - v9.2 Stage 2 CoreImage camera PixelBuffer compositor

/// CoreImage compositor for the staged recording migration.
///
/// Stage 2/4 behaviour is intentionally camera-only: it copies the incoming
/// camera `CVPixelBuffer` into a writer-sized output `CVPixelBuffer`. Overlay
/// composition is supported as an optional parameter for later stages but is not
/// enabled by default.
/// RecordingWriter calls this owner only from its dedicated serial queue.
/// Explicitly opt out of the target-wide MainActor default: Core Image render
/// and pixel-buffer allocation are media work, never presentation work.
nonisolated final class BroadcastPixelBufferCompositor: @unchecked Sendable {
    static let shared = BroadcastPixelBufferCompositor()

    private let context: CIContext
    private let colorSpace = CGColorSpaceCreateDeviceRGB()

    private init() {
        context = CIContext(options: [
            .cacheIntermediates: false,
            .workingColorSpace: CGColorSpaceCreateDeviceRGB(),
            .outputColorSpace: CGColorSpaceCreateDeviceRGB()
        ])
    }

    func renderCameraOnly(
        cameraPixelBuffer: CVPixelBuffer,
        outputSize: CGSize,
        pixelBufferPool: CVPixelBufferPool?,
        cameraRotationDegrees: Double = 0,
        compositeRotationDegrees: Double = 0,
        mirrorCorrectionEnabled: Bool = false
    ) -> CVPixelBuffer? {
        render(
            cameraPixelBuffer: cameraPixelBuffer,
            overlayCIImage: nil,
            outputSize: outputSize,
            pixelBufferPool: pixelBufferPool,
            cameraRotationDegrees: cameraRotationDegrees,
            compositeRotationDegrees: compositeRotationDegrees,
            mirrorCorrectionEnabled: mirrorCorrectionEnabled
        )
    }

    func render(
        cameraPixelBuffer: CVPixelBuffer,
        overlayCIImage: CIImage?,
        outputSize: CGSize,
        pixelBufferPool: CVPixelBufferPool?,
        cameraRotationDegrees: Double,
        compositeRotationDegrees: Double,
        mirrorCorrectionEnabled: Bool
    ) -> CVPixelBuffer? {
        guard outputSize.width > 0, outputSize.height > 0 else { return nil }
        guard let outputBuffer = makeOutputPixelBuffer(size: outputSize, pixelBufferPool: pixelBufferPool) else { return nil }

        let outputRect = CGRect(origin: .zero, size: outputSize)
        let output = makeOutputImage(
            cameraPixelBuffer: cameraPixelBuffer,
            overlayCIImage: overlayCIImage,
            outputSize: outputSize,
            cameraRotationDegrees: cameraRotationDegrees,
            compositeRotationDegrees: compositeRotationDegrees,
            mirrorCorrectionEnabled: mirrorCorrectionEnabled
        )
        context.render(output, to: outputBuffer, bounds: outputRect, colorSpace: colorSpace)
        return outputBuffer
    }

    /// R18 uses Core Image's explicit preparation API on the same singleton
    /// CIContext and the real RecordingWriter pixel-buffer pool. This compiles
    /// kernels and allocates intermediates before REC without rendering a fake
    /// recording frame or creating a second compositor/context.
    func prepare(
        cameraPixelBuffer: CVPixelBuffer,
        overlayCIImage: CIImage?,
        outputSize: CGSize,
        pixelBufferPool: CVPixelBufferPool?,
        cameraRotationDegrees: Double,
        compositeRotationDegrees: Double,
        mirrorCorrectionEnabled: Bool
    ) -> Bool {
        guard outputSize.width > 0, outputSize.height > 0,
              let outputBuffer = makeOutputPixelBuffer(size: outputSize, pixelBufferPool: pixelBufferPool) else {
            return false
        }
        let outputRect = CGRect(origin: .zero, size: outputSize)
        let output = makeOutputImage(
            cameraPixelBuffer: cameraPixelBuffer,
            overlayCIImage: overlayCIImage,
            outputSize: outputSize,
            cameraRotationDegrees: cameraRotationDegrees,
            compositeRotationDegrees: compositeRotationDegrees,
            mirrorCorrectionEnabled: mirrorCorrectionEnabled
        )
        do {
            let destination = CIRenderDestination(pixelBuffer: outputBuffer)
            try context.prepareRender(output, from: outputRect, to: destination, at: .zero)
            return true
        } catch {
            return false
        }
    }

    private func makeOutputImage(
        cameraPixelBuffer: CVPixelBuffer,
        overlayCIImage: CIImage?,
        outputSize: CGSize,
        cameraRotationDegrees: Double,
        compositeRotationDegrees: Double,
        mirrorCorrectionEnabled: Bool
    ) -> CIImage {
        let outputRect = CGRect(origin: .zero, size: outputSize)
        let cameraImage = CIImage(cvPixelBuffer: cameraPixelBuffer)
        var composite = cameraImage
            .transformedForAspectFill(
                outputSize: outputSize,
                rotationDegrees: cameraRotationDegrees,
                mirrorCorrectionEnabled: mirrorCorrectionEnabled
            )
            .cropped(to: outputRect)
        if let overlayCIImage {
            // The canonical overlay cache is rendered on the 1920x1080
            // programme canvas. Streaming may select 1280x720; cropping that
            // image discarded the right/bottom content and left text/logos at
            // the wrong sampling scale. Scale the complete overlay canvas to
            // the physical output before compositing.
            composite = overlayCIImage
                .scaledToOutputCanvas(outputSize)
                .cropped(to: outputRect)
                .composited(over: composite)
        }
        return composite
            .rotatedAroundOutputCenter(degrees: compositeRotationDegrees, outputSize: outputSize)
            .cropped(to: outputRect)
    }

    private func makeOutputPixelBuffer(size: CGSize, pixelBufferPool: CVPixelBufferPool?) -> CVPixelBuffer? {
        var outputBuffer: CVPixelBuffer?
        if let pixelBufferPool {
            let status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pixelBufferPool, &outputBuffer)
            guard status == kCVReturnSuccess else { return nil }
            return outputBuffer
        }

        let attributes: [String: Any] = [
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ]
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            Int(size.width),
            Int(size.height),
            kCVPixelFormatType_32ARGB,
            attributes as CFDictionary,
            &outputBuffer
        )
        guard status == kCVReturnSuccess else { return nil }
        return outputBuffer
    }
}

nonisolated private extension CIImage {
    func scaledToOutputCanvas(_ outputSize: CGSize) -> CIImage {
        let source = extent.integral
        guard source.width > 0, source.height > 0,
              outputSize.width > 0, outputSize.height > 0 else { return self }
        let normalized = transformed(by: CGAffineTransform(translationX: -source.minX, y: -source.minY))
        return normalized.transformed(by: CGAffineTransform(
            scaleX: outputSize.width / source.width,
            y: outputSize.height / source.height
        ))
    }

    func transformedForAspectFill(outputSize: CGSize, rotationDegrees: Double, mirrorCorrectionEnabled: Bool) -> CIImage {
        var image = self
        let originalExtent = image.extent.integral
        guard originalExtent.width > 0, originalExtent.height > 0 else { return image }

        if mirrorCorrectionEnabled {
            image = image.transformed(by: CGAffineTransform(translationX: originalExtent.midX, y: originalExtent.midY))
                .transformed(by: CGAffineTransform(scaleX: -1, y: 1))
                .transformed(by: CGAffineTransform(translationX: -originalExtent.midX, y: -originalExtent.midY))
        }

        let radians = CGFloat(rotationDegrees * .pi / 180.0)
        if abs(rotationDegrees.truncatingRemainder(dividingBy: 360)) > 0.01 {
            let extent = image.extent.integral
            image = image.transformed(by: CGAffineTransform(translationX: extent.midX, y: extent.midY))
                .transformed(by: CGAffineTransform(rotationAngle: radians))
                .transformed(by: CGAffineTransform(translationX: -extent.midX, y: -extent.midY))
            let shifted = image.extent.integral
            image = image.transformed(by: CGAffineTransform(translationX: -shifted.minX, y: -shifted.minY))
        }

        let rotatedExtent = image.extent.integral
        let scale = max(outputSize.width / max(1, rotatedExtent.width), outputSize.height / max(1, rotatedExtent.height))
        image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let scaledExtent = image.extent.integral
        let tx = (outputSize.width - scaledExtent.width) / 2.0 - scaledExtent.minX
        let ty = (outputSize.height - scaledExtent.height) / 2.0 - scaledExtent.minY
        return image.transformed(by: CGAffineTransform(translationX: tx, y: ty))
    }

    func rotatedAroundOutputCenter(degrees: Double, outputSize: CGSize) -> CIImage {
        let normalized = degrees.truncatingRemainder(dividingBy: 360)
        guard abs(normalized) > 0.01 else { return self }
        let center = CGPoint(x: outputSize.width / 2.0, y: outputSize.height / 2.0)
        return transformed(by: CGAffineTransform(translationX: center.x, y: center.y))
            .transformed(by: CGAffineTransform(rotationAngle: CGFloat(normalized * .pi / 180.0)))
            .transformed(by: CGAffineTransform(translationX: -center.x, y: -center.y))
    }
}
#endif
