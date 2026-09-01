import Foundation

/// CaptureEngine-owned, value-only projection of the external video topology.
/// Counts advance at the physical AVFoundation notification boundary.
nonisolated struct RinkLensExternalOCRTopology: Equatable, Sendable {
    let revision: UInt64
    let deviceID: String?
    let isDiscoverable: Bool
    let disconnectCount: Int
    let reconnectCount: Int

    static let unavailable = Self(
        revision: 0,
        deviceID: nil,
        isDiscoverable: false,
        disconnectCount: 0,
        reconnectCount: 0
    )
}

/// Immutable request emitted by CaptureEngine when the writer protection
/// boundary prevents it from restoring an otherwise available OCR branch.
nonisolated struct RinkLensOCRRecoveryRequirement: Equatable, Sendable {
    let deviceID: String
    let topologyRevision: UInt64
    let captureGeneration: Int

    static func make(
        topology: RinkLensExternalOCRTopology,
        captureGeneration: Int,
        ocrIsDesired: Bool,
        broadcastIsHealthy: Bool,
        writerContractIsOpen: Bool
    ) -> Self? {
        guard topology.isDiscoverable,
              let deviceID = topology.deviceID,
              ocrIsDesired,
              broadcastIsHealthy,
              writerContractIsOpen else { return nil }
        return Self(
            deviceID: deviceID,
            topologyRevision: topology.revision,
            captureGeneration: captureGeneration
        )
    }
}

nonisolated struct RinkLensOCRBranchRecoveryResult: Equatable, Sendable {
    let requestedDeviceID: String
    let topologyRevision: UInt64
    let captureGeneration: Int
    let structurallyAttached: Bool
    let freshFrameVerified: Bool
    let broadcastPreserved: Bool
    let statusText: String
}

