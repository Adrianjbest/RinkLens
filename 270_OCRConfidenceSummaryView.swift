// BUILD 697 STATE CONTRACT: authoritative mutations pass through the declared domain owner/reducer; local values are drafts, projections, snapshots or caches only.
#if canImport(SwiftUI)
import SwiftUI

// STYLE2 central design system migration: operator chrome/fonts use RinkLensDesignSystem where safe.

// MARK: - Phase 4 OCR Confidence Display

struct OCRConfidenceSummaryView: View {
    let summary: OCRTrustSummary
    let fieldConfidence: [OCRRegionKey: OCRFieldConfidence]
    var compact: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 6 : 10) {
            HStack(spacing: 8) {
                Circle()
                    .fill(summary.publicOverlayTrusted ? Color.green : Color.yellow)
                    .frame(width: 9, height: 9)
                Text(summary.statusText)
                    .font(RinkLensDesignSystem.font(.caption))
                    .foregroundStyle(.white)
                Spacer(minLength: 8)
                if summary.fieldCount > 0 {
                    Text("\(summary.acceptedCount)/\(summary.fieldCount) accepted")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.white.opacity(0.75))
                }
            }

            if !compact {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 138), spacing: 8)], spacing: 8) {
                    ForEach(OCRRegionKey.productionOCRCases) { key in
                        if let confidence = fieldConfidence[key] {
                            OCRConfidencePill(confidence: confidence)
                        }
                    }
                }
            }
        }
        .padding(10)
        .background(.black.opacity(0.62), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(summary.publicOverlayTrusted ? Color.green.opacity(0.45) : Color.yellow.opacity(0.45), lineWidth: 1)
        )
    }
}

private struct OCRConfidencePill: View {
    let confidence: OCRFieldConfidence

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(indicatorColor)
                .frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 2) {
                Text(confidence.key.likelyTitle)
                    .font(RinkLensDesignSystem.font(.micro))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text("\(confidence.displayValue) · \(confidence.trustLabel) · \(Int(confidence.confidence * 100))%")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.72))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var indicatorColor: Color {
        if !confidence.isAccepted { return .yellow }
        if confidence.confidence >= 0.75 { return .green }
        if confidence.confidence >= 0.55 { return .orange }
        return .red
    }
}

#endif
