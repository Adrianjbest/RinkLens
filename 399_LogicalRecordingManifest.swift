import Foundation

/// Durable description of one operator recording that may cross internal
/// writer boundaries. RecordingEngine is the sole writer of this manifest;
/// media finalisation consumes it only after the capture writer is closed.
nonisolated struct RinkLensLogicalRecordingManifest: Codable, Equatable, Sendable {
    nonisolated struct MediaContract: Codable, Equatable, Sendable {
        let codec: String
        let width: Int
        let height: Int
        let cadenceValue: Int64
        let cadenceTimescale: Int32
        let bitrate: Int
        let sourceDescription: String
        let physicalDeviceID: String?
        let captureGeneration: Int
    }
    nonisolated enum State: String, Codable, Equatable, Sendable {
        case recording
        case awaitingJoin
        case complete
        case preserved
    }

    nonisolated enum FinalizationAction: Equatable, Sendable {
        case persistDirectly
        case joinOrderedSegments
        case preserveSegments
    }

    let logicalRecordingID: UUID
    private(set) var segments: [URL]
    private(set) var state: State
    let mediaContract: MediaContract?

    init(
        logicalRecordingID: UUID,
        segments: [URL],
        state: State,
        mediaContract: MediaContract? = nil
    ) {
        self.logicalRecordingID = logicalRecordingID
        self.segments = Self.uniqueSegments(segments)
        self.state = state
        self.mediaContract = mediaContract
    }

    var finalizationAction: FinalizationAction {
        guard state != .preserved, !segments.isEmpty else { return .preserveSegments }
        return segments.count == 1 ? .persistDirectly : .joinOrderedSegments
    }

    func appending(_ segment: URL) -> Self {
        var copy = self
        if !copy.segments.contains(where: { $0.standardizedFileURL == segment.standardizedFileURL }) {
            copy.segments.append(segment)
        }
        return copy
    }

    func transitioning(to state: State) -> Self {
        var copy = self
        copy.state = state
        return copy
    }

    func writeAtomically(to url: URL) throws {
        let data = try JSONEncoder.rinkLensManifestEncoder.encode(self)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
    }

    static func load(from url: URL) throws -> Self {
        try JSONDecoder.rinkLensManifestDecoder.decode(Self.self, from: Data(contentsOf: url))
    }

    /// One bounded launch-time recovery scan. Callers run this off MainActor;
    /// it returns URL metadata only and never opens media tracks or pixels.
    static func discover(in root: URL) -> [(url: URL, manifest: Self)] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        var discovered: [(URL, Self)] = []
        for case let url as URL in enumerator
        where url.lastPathComponent.hasSuffix(".recording.json") {
            guard let manifest = try? load(from: url) else { continue }
            discovered.append((url, manifest))
        }
        return discovered.sorted { $0.0.path < $1.0.path }
    }

    private static func uniqueSegments(_ input: [URL]) -> [URL] {
        var seen = Set<String>()
        return input.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }
}

private extension JSONEncoder {
    nonisolated static var rinkLensManifestEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

private extension JSONDecoder {
    nonisolated static var rinkLensManifestDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
