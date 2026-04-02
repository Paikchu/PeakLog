import SwiftUI

struct VoiceWaveformView: View {
    let samples: [CGFloat]
    let isTranscribing: Bool

    var body: some View {
        GeometryReader { proxy in
            let values = normalizedSamples
            let width = proxy.size.width
            let spacing = max(2, width / CGFloat(max(values.count, 1)) * 0.16)
            let totalSpacing = spacing * CGFloat(max(values.count - 1, 0))
            let barWidth = max(3, (width - totalSpacing) / CGFloat(max(values.count, 1)))

            HStack(alignment: .center, spacing: spacing) {
                ForEach(Array(values.enumerated()), id: \.offset) { _, sample in
                    Capsule()
                        .fill(isTranscribing ? Color.textMuted : Color.accentValue)
                        .frame(width: barWidth, height: max(8, proxy.size.height * sample))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
        .frame(height: 28)
        .accessibilityLabel(isTranscribing ? String(localized: "Transcribing voice input") : String(localized: "Recording voice input"))
    }

    private var normalizedSamples: [CGFloat] {
        let defaultSamples = Array(repeating: CGFloat(0.18), count: 28)
        let values = samples.isEmpty ? defaultSamples : samples
        return values.map { max(0.12, min($0, 1)) }
    }
}
