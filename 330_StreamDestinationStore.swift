// BUILD 699 STATE CONTRACT: authoritative mutations pass through the declared domain owner/reducer; local values are drafts, projections, snapshots or caches only.
#if canImport(SwiftUI)
import SwiftUI
import Foundation

/// Stores the RTMPS/HLS destination used by the in-process publisher.
///
/// This store must not restart cameras, OCR, overlays or previews.
final class StreamDestinationStore: ObservableObject {
    static let shared = StreamDestinationStore()

    static let youtubePlatformName = "YouTube Live"

    enum IngestProtocol: String, CaseIterable, Identifiable, Sendable {
        case rtmps = "RTMPS"
        case hls = "HLS"

        var id: String { rawValue }
        var detail: String {
            switch self {
            case .rtmps: return "Low latency • H.264 on YouTube"
            case .hls: return "Higher quality • H.264 or HEVC (H.265) • higher latency"
            }
        }
    }

    enum QualityProfile: String, CaseIterable, Identifiable, Sendable {
        case hd720p60 = "720p60"
        case fullHD1080p60 = "1080p60"
        case fullHD1080p30 = "1080p30"

        var id: String { rawValue }
        var detail: String {
            switch self {
            case .hd720p60: return "Balanced • 1280×720 at 60 fps"
            case .fullHD1080p60: return "Best quality • 1920×1080 at 60 fps"
            case .fullHD1080p30: return "Low light • 1920×1080 at 30 fps"
            }
        }

        nonisolated var framesPerSecond: Int {
            self == .fullHD1080p30 ? 30 : 60
        }
    }

    enum VideoCodec: String, CaseIterable, Identifiable, Sendable {
        case h264 = "H.264"
        case hevc = "H.265"

        var id: String { rawValue }
        nonisolated var displayName: String { self == .h264 ? "H.264" : "HEVC (H.265)" }
        nonisolated var encoderName: String { self == .h264 ? "H.264 High" : "HEVC Main" }

        nonisolated func maximumBitrate(for profile: QualityProfile) -> Int {
            switch (self, profile) {
            case (.h264, .hd720p60): return 8_000_000
            case (.h264, .fullHD1080p60): return 16_000_000
            case (.h264, .fullHD1080p30): return 10_000_000
            case (.hevc, .hd720p60): return 8_000_000
            case (.hevc, .fullHD1080p60): return 10_000_000
            case (.hevc, .fullHD1080p30): return 7_000_000
            }
        }

        nonisolated func minimumBitrate(for profile: QualityProfile) -> Int {
            switch (self, profile) {
            case (.h264, .hd720p60): return 6_000_000
            case (.h264, .fullHD1080p60): return 12_000_000
            case (.h264, .fullHD1080p30): return 7_000_000
            case (.hevc, .hd720p60): return 5_000_000
            case (.hevc, .fullHD1080p60): return 7_000_000
            case (.hevc, .fullHD1080p30): return 5_000_000
            }
        }

        nonisolated func detail(for profile: QualityProfile) -> String {
            let bitrate = Double(maximumBitrate(for: profile)) / 1_000_000
            switch self {
            case .h264:
                return "H.264 High • up to \(String(format: "%.0f", bitrate)) Mbps • widest RTMPS compatibility"
            case .hevc:
                return "HEVC Main • up to \(String(format: "%.0f", bitrate)) Mbps • sharper detail per transmitted bit"
            }
        }
    }

    @Published var platformName: String
    @Published var streamURL: String
    @Published var streamKey: String
    @Published var useRTMPS: Bool
    @Published var ingestProtocol: IngestProtocol
    @Published var videoCodec: VideoCodec
    @Published var adaptiveBitrate: Bool

    private let defaults: UserDefaults

    private enum Keys {
        static let platformName = "icecast.streamDestination.platformName"
        static let streamURL = "icecast.streamDestination.streamURL"
        static let streamKey = "icecast.streamDestination.streamKey"
        static let useRTMPS = "icecast.streamDestination.useRTMPS"
        static let ingestProtocol = "rinklens.streaming.ingestProtocol"
        static let videoCodec = "rinklens.streaming.videoCodec"
        static let adaptiveBitrate = "rinklens.streaming.adaptiveBitrate"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        self.platformName = defaults.string(forKey: Keys.platformName) ?? ""
        self.streamURL = defaults.string(forKey: Keys.streamURL) ?? ""
        self.streamKey = defaults.string(forKey: Keys.streamKey) ?? ""
        self.useRTMPS = defaults.bool(forKey: Keys.useRTMPS)
        if let stored = defaults.string(forKey: Keys.ingestProtocol),
           let protocolValue = IngestProtocol(rawValue: stored) {
            self.ingestProtocol = protocolValue
        } else {
            let savedURL = defaults.string(forKey: Keys.streamURL)?.lowercased() ?? ""
            self.ingestProtocol = savedURL.hasPrefix("https://") ? .hls : .rtmps
        }
        self.videoCodec = VideoCodec(rawValue: defaults.string(forKey: Keys.videoCodec) ?? "") ?? .hevc
        if defaults.object(forKey: Keys.adaptiveBitrate) != nil {
            self.adaptiveBitrate = defaults.bool(forKey: Keys.adaptiveBitrate)
        } else {
            self.adaptiveBitrate = true
        }
        // Recovery CO: OAuth/event import was removed. Discard any legacy
        // account-derived event metadata left by earlier builds. Manual YouTube
        // RTMPS URL/key settings remain under the normal destination keys.
        defaults.removeObject(forKey: "rinklens.youtube.broadcastID")
        defaults.removeObject(forKey: "rinklens.youtube.broadcastTitle")
        defaults.removeObject(forKey: "rinklens.youtube.viewerURL")
    }

    var trimmedPlatformName: String { platformName.trimmingCharacters(in: .whitespacesAndNewlines) }
    var trimmedStreamURL: String { streamURL.trimmingCharacters(in: .whitespacesAndNewlines) }
    var trimmedStreamKey: String { streamKey.trimmingCharacters(in: .whitespacesAndNewlines) }

    var displayPlatformName: String { trimmedPlatformName.isEmpty ? "Custom stream" : trimmedPlatformName }

    var isYouTubeLiveDestination: Bool {
        if trimmedPlatformName.localizedCaseInsensitiveContains("youtube") { return true }
        guard let host = URLComponents(string: trimmedStreamURL)?.host?.lowercased() else { return false }
        return host == "youtube.com" || host.hasSuffix(".youtube.com")
    }

    /// The saved codec remains operator intent. The destination/protocol
    /// boundary resolves that intent to a codec the physical ingest accepts.
    /// YouTube's Live Streaming API contract documents RTMP/RTMPS as H.264;
    /// HEVC remains available for custom Enhanced-RTMP and YouTube HLS.
    var resolvedVideoCodec: VideoCodec {
        if isYouTubeLiveDestination, ingestProtocol == .rtmps, videoCodec == .hevc {
            return .h264
        }
        return videoCodec
    }

    var videoCodecResolutionText: String {
        if videoCodec != resolvedVideoCodec {
            return "HEVC (H.265) requested • H.264 applied because YouTube RTMPS requires H.264."
        }
        return "\(resolvedVideoCodec.encoderName) requested and applied."
    }

    var protocolLabel: String {
        if ingestProtocol == .hls { return "HLS" }
        if useRTMPS { return "RTMPS" }
        let lowerURL = trimmedStreamURL.lowercased()
        if lowerURL.hasPrefix("rtmps://") { return "RTMPS" }
        if lowerURL.hasPrefix("rtmp://") { return "RTMP" }
        return "RTMP/RTMPS"
    }

    var isConfigured: Bool { !trimmedStreamURL.isEmpty && !trimmedStreamKey.isEmpty }
    var hasAnyValue: Bool { !trimmedPlatformName.isEmpty || !trimmedStreamURL.isEmpty || !trimmedStreamKey.isEmpty || useRTMPS }

    var hasSupportedScheme: Bool {
        let lower = trimmedStreamURL.lowercased()
        switch ingestProtocol {
        case .rtmps: return lower.hasPrefix("rtmp://") || lower.hasPrefix("rtmps://")
        case .hls: return lower.hasPrefix("https://")
        }
    }

    var isReadyForBroadcastFlow: Bool {
        validationWarnings.isEmpty
    }

    var validationWarnings: [String] {
        var warnings: [String] = []
        if trimmedStreamURL.isEmpty {
            warnings.append("Missing Stream URL.")
        } else if !hasSupportedScheme {
            warnings.append(ingestProtocol == .hls
                ? "YouTube HLS Stream URL must start with https://."
                : "Stream URL must start with rtmp:// or rtmps://.")
        }

        if trimmedStreamKey.isEmpty {
            warnings.append("Missing Stream Key.")
        }

        if ingestProtocol == .rtmps, useRTMPS && trimmedStreamURL.lowercased().hasPrefix("rtmp://") {
            warnings.append("Use RTMPS is on, but the Stream URL starts with rtmp://.")
        }

        if isYouTubeLiveDestination, !trimmedStreamURL.isEmpty {
            let components = URLComponents(string: trimmedStreamURL)
            switch ingestProtocol {
            case .rtmps:
                if components?.scheme?.lowercased() != "rtmps" {
                    warnings.append("YouTube Live RTMPS requires the RTMPS URL from Live Control Room.")
                }
                if let host = components?.host?.lowercased(), !host.isEmpty {
                    if host != "youtube.com", !host.hasSuffix(".youtube.com") {
                        warnings.append("This does not look like a YouTube ingestion server. Copy the RTMPS Stream URL from YouTube Live Control Room.")
                    } else if host == "a.rtmp.youtube.com" || host == "b.rtmp.youtube.com" {
                        warnings.append("The YouTube RTMPS hostname is mistyped. Use a.rtmps.youtube.com or copy the Stream URL again from Live Control Room.")
                    }
                } else {
                    warnings.append("The YouTube Stream URL is missing a valid ingestion server.")
                }
                if let port = components?.port, port != 443 {
                    warnings.append("YouTube RTMPS must connect on port 443.")
                }
            case .hls:
                if components?.scheme?.lowercased() != "https" {
                    warnings.append("YouTube HLS ingestion requires HTTPS.")
                }
                let host = components?.host?.lowercased() ?? ""
                if host != "a.upload.youtube.com", host != "b.upload.youtube.com" {
                    warnings.append("Use the YouTube HLS upload URL from Live Control Room.")
                }
            }
        }

        return warnings
    }

    var validationSummaryText: String {
        let warnings = validationWarnings
        if warnings.isEmpty { return "Configuration ready." }
        return warnings.joined(separator: " ")
    }

    /// Full publish URI used by the publisher. For most platforms this is the
    /// base RTMP/RTMPS URL plus the stream key as the final path component.
    var fullPublishURLText: String {
        let base = trimmedStreamURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let key = trimmedStreamKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty, !key.isEmpty else { return "" }
        return "\(base)/\(key)"
    }

    /// YouTube's HLS endpoint is a filename template. The secret key stays in
    /// the query and is never emitted into diagnostics.
    var hlsUploadBaseURLText: String {
        guard ingestProtocol == .hls else { return "" }
        let key = trimmedStreamKey
        guard !key.isEmpty else { return "" }
        if trimmedStreamURL.contains("file=") {
            if trimmedStreamURL.contains("cid=") { return trimmedStreamURL }
            return trimmedStreamURL.replacingOccurrences(of: "file=", with: "cid=\(key)&copy=0&file=")
        }
        let base = trimmedStreamURL.trimmingCharacters(in: CharacterSet(charactersIn: "?&"))
        return "\(base)?cid=\(key)&copy=0&file="
    }

    /// Saves only when the user taps Save. Do not call this from TextField
    /// onChange during a game.
    func save(platformName: String, streamURL: String, streamKey: String, useRTMPS: Bool) {
        let previous = ["platform": self.platformName, "urlPresent": String(!self.streamURL.isEmpty), "keyPresent": String(!self.streamKey.isEmpty), "rtmps": String(self.useRTMPS), "codec": videoCodec.rawValue]
        self.platformName = platformName.trimmingCharacters(in: .whitespacesAndNewlines)
        self.streamURL = streamURL.trimmingCharacters(in: .whitespacesAndNewlines)
        self.streamKey = streamKey.trimmingCharacters(in: .whitespacesAndNewlines)
        self.useRTMPS = useRTMPS

        writeValues(to: defaults)
        guard RinkLensRiskFeaturePolicy.isEnabled(.streamingStructuredTransitionsV2) else { return }
        RinkLensStructuredEventLogger.shared.record(
            domain: .streaming,
            event: "destination_saved",
            entityID: "active",
            previous: previous,
            next: ["platform": self.platformName, "urlPresent": String(!self.streamURL.isEmpty), "keyPresent": String(!self.streamKey.isEmpty), "rtmps": String(self.useRTMPS), "codec": videoCodec.rawValue],
            source: "StreamDestinationStore.save",
            reason: "Operator saved stream destination"
        )
    }

    func save() {
        save(platformName: platformName, streamURL: streamURL, streamKey: streamKey, useRTMPS: useRTMPS)
    }

    /// Selects the YouTube workflow without inventing an ingestion address or
    /// stream key. YouTube owns both values and the operator copies them from the
    /// current Live Control Room stream. Existing YouTube values are retained;
    /// incompatible custom-platform values are cleared deliberately.
    func prepareYouTubeLiveSetup() {
        let wasYouTube = isYouTubeLiveDestination
        platformName = Self.youtubePlatformName
        useRTMPS = true
        ingestProtocol = .rtmps
        if !wasYouTube {
            streamURL = ""
            streamKey = ""
        }
        guard RinkLensRiskFeaturePolicy.isEnabled(.streamingStructuredTransitionsV2) else { return }
        RinkLensStructuredEventLogger.shared.record(
            domain: .streaming,
            event: "youtube_setup_selected",
            entityID: "active",
            previous: ["youtube": String(wasYouTube)],
            next: ["platform": Self.youtubePlatformName, "rtmps": "true", "urlPresent": String(!streamURL.isEmpty), "keyPresent": String(!streamKey.isEmpty)],
            source: "StreamDestinationStore.prepareYouTubeLiveSetup",
            reason: "Operator selected the YouTube Live destination workflow"
        )
    }

    func clear() {
        let previous = ["platform": platformName, "urlPresent": String(!streamURL.isEmpty), "keyPresent": String(!streamKey.isEmpty), "rtmps": String(useRTMPS)]
        platformName = ""
        streamURL = ""
        streamKey = ""
        useRTMPS = false
        ingestProtocol = .rtmps

        clearValues(from: defaults)
        guard RinkLensRiskFeaturePolicy.isEnabled(.streamingStructuredTransitionsV2) else { return }
        RinkLensStructuredEventLogger.shared.record(
            domain: .streaming,
            event: "destination_cleared",
            entityID: "active",
            previous: previous,
            next: ["platform": "", "urlPresent": "false", "keyPresent": "false", "rtmps": "false"],
            source: "StreamDestinationStore.clear",
            reason: "Operator cleared stream destination"
        )
    }

    private func writeValues(to defaults: UserDefaults) {
        defaults.set(platformName, forKey: Keys.platformName)
        defaults.set(streamURL, forKey: Keys.streamURL)
        defaults.set(streamKey, forKey: Keys.streamKey)
        defaults.set(useRTMPS, forKey: Keys.useRTMPS)
        defaults.set(ingestProtocol.rawValue, forKey: Keys.ingestProtocol)
        defaults.set(videoCodec.rawValue, forKey: Keys.videoCodec)
        defaults.set(adaptiveBitrate, forKey: Keys.adaptiveBitrate)
        defaults.synchronize()
    }

    private func clearValues(from defaults: UserDefaults) {
        defaults.removeObject(forKey: Keys.platformName)
        defaults.removeObject(forKey: Keys.streamURL)
        defaults.removeObject(forKey: Keys.streamKey)
        defaults.removeObject(forKey: Keys.useRTMPS)
        defaults.removeObject(forKey: Keys.ingestProtocol)
        defaults.removeObject(forKey: Keys.videoCodec)
        defaults.removeObject(forKey: Keys.adaptiveBitrate)
        defaults.synchronize()
    }
}

extension BroadcastProductionProfile {
    var streamQualityProfile: StreamDestinationStore.QualityProfile {
        switch self {
        case .smoothMotion, .balanced: return .fullHD1080p60
        case .lowLight: return .fullHD1080p30
        case .reducedData: return .hd720p60
        }
    }
}
#endif
