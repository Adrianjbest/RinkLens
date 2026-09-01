// Build 785 Recovery CV: deterministic fixture artwork; no camera/frame ownership.
#if canImport(SwiftUI)
import Foundation
import UIKit

nonisolated enum RinkLensFixtureThumbnailError: LocalizedError, Sendable {
    case renderFailed

    var errorDescription: String? { "The fixture thumbnail could not be rendered." }
}

/// Pure renderer for YouTube metadata publishing. Its complete inputs are an
/// immutable fixture snapshot and optional persisted logo bytes; it never asks
/// CaptureEngine or FrameHub for a live image.
nonisolated enum RinkLensFixtureThumbnailRenderer {
    static let pixelSize = CGSize(width: 1280, height: 720)

    static func renderJPEG(
        snapshot: RinkLensGameConfigurationSnapshot,
        homeLogoData: Data? = nil,
        awayLogoData: Data? = nil
    ) throws -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: pixelSize, format: format)
        let image = renderer.image { context in
            draw(snapshot: snapshot, homeLogoData: homeLogoData, awayLogoData: awayLogoData, context: context.cgContext)
        }
        guard let data = image.jpegData(compressionQuality: 0.90), data.count <= 2_000_000 else {
            throw RinkLensFixtureThumbnailError.renderFailed
        }
        return data
    }

    private static func draw(snapshot: RinkLensGameConfigurationSnapshot, homeLogoData: Data?, awayLogoData: Data?, context: CGContext) {
        let canvas = CGRect(origin: .zero, size: pixelSize)
        let homeColour = colour(snapshot.homeTeam.primaryColourRGBA, fallback: UIColor(red: 0.05, green: 0.18, blue: 0.36, alpha: 1))
        let awayColour = colour(snapshot.awayTeam.primaryColourRGBA, fallback: UIColor(red: 0.55, green: 0.06, blue: 0.12, alpha: 1))
        context.setFillColor(UIColor(red: 0.025, green: 0.035, blue: 0.065, alpha: 1).cgColor)
        context.fill(canvas)
        context.saveGState()
        context.setAlpha(0.72)
        context.setFillColor(homeColour.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 640, height: 720))
        context.setFillColor(awayColour.cgColor)
        context.fill(CGRect(x: 640, y: 0, width: 640, height: 720))
        context.restoreGState()

        context.setFillColor(UIColor.black.withAlphaComponent(0.30).cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 1280, height: 112))
        context.fill(CGRect(x: 0, y: 582, width: 1280, height: 138))

        drawText(snapshot.seasonName.uppercased(), in: CGRect(x: 70, y: 30, width: 1140, height: 52), font: .systemFont(ofSize: 35, weight: .bold), alignment: .center)
        drawLogo(data: homeLogoData, fallback: snapshot.homeTeam.abbreviation, in: CGRect(x: 148, y: 150, width: 280, height: 260), tint: homeColour)
        drawLogo(data: awayLogoData, fallback: snapshot.awayTeam.abbreviation, in: CGRect(x: 852, y: 150, width: 280, height: 260), tint: awayColour)
        drawText(snapshot.homeTeam.shortName.uppercased(), in: CGRect(x: 60, y: 438, width: 500, height: 72), font: .systemFont(ofSize: 50, weight: .black), alignment: .center)
        drawText(snapshot.awayTeam.shortName.uppercased(), in: CGRect(x: 720, y: 438, width: 500, height: 72), font: .systemFont(ofSize: 50, weight: .black), alignment: .center)
        drawText("V", in: CGRect(x: 590, y: 302, width: 100, height: 100), font: .systemFont(ofSize: 76, weight: .black), alignment: .center)

        let competition = (snapshot.competition?.isEmpty == false ? snapshot.competition! : "LIVE ICE HOCKEY").uppercased()
        drawText(competition, in: CGRect(x: 70, y: 590, width: 1140, height: 42), font: .systemFont(ofSize: 29, weight: .bold), alignment: .center)
        let fixtureLine = "\(dateFormatter.string(from: snapshot.scheduledStart).uppercased())  •  \(timeFormatter.string(from: snapshot.scheduledStart))"
        drawText(fixtureLine, in: CGRect(x: 70, y: 638, width: 1140, height: 45), font: .monospacedDigitSystemFont(ofSize: 31, weight: .semibold), alignment: .center)
    }

    private static func drawLogo(data: Data?, fallback: String, in rect: CGRect, tint: UIColor) {
        if let data, let image = UIImage(data: data) {
            let scale = min(rect.width / image.size.width, rect.height / image.size.height)
            let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            image.draw(in: CGRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height))
            return
        }
        let circle = UIBezierPath(ovalIn: rect.insetBy(dx: 18, dy: 8))
        UIColor.white.withAlphaComponent(0.94).setFill(); circle.fill()
        drawText(fallback, in: rect.offsetBy(dx: 0, dy: rect.height * 0.37), font: .systemFont(ofSize: 54, weight: .black), colour: tint, alignment: .center)
    }

    private static func drawText(_ text: String, in rect: CGRect, font: UIFont, colour: UIColor = .white, alignment: NSTextAlignment) {
        let paragraph = NSMutableParagraphStyle(); paragraph.alignment = alignment
        (text as NSString).draw(in: rect, withAttributes: [.font: font, .foregroundColor: colour, .paragraphStyle: paragraph])
    }

    private static func colour(_ rgba: String?, fallback: UIColor) -> UIColor {
        guard let raw = rgba?.trimmingCharacters(in: CharacterSet(charactersIn: "#")), raw.count == 6,
              let value = UInt64(raw, radix: 16) else { return fallback }
        return UIColor(red: CGFloat((value >> 16) & 255) / 255, green: CGFloat((value >> 8) & 255) / 255, blue: CGFloat(value & 255) / 255, alpha: 1)
    }

    private static let dateFormatter: DateFormatter = {
        let value = DateFormatter(); value.locale = Locale(identifier: "en_GB"); value.timeZone = TimeZone(identifier: "Europe/London"); value.dateFormat = "EEEE d MMMM"; return value
    }()
    private static let timeFormatter: DateFormatter = {
        let value = DateFormatter(); value.locale = Locale(identifier: "en_GB"); value.timeZone = TimeZone(identifier: "Europe/London"); value.dateFormat = "HH:mm"; return value
    }()
}

nonisolated enum RinkLensFixtureThumbnailAssets {
    static func logoData(fileName: String?) -> Data? {
        guard let fileName, !fileName.isEmpty else { return nil }
        return try? Data(contentsOf: RinkTemplateStorageService().templatesDirectory.appendingPathComponent(fileName))
    }
}
#endif
