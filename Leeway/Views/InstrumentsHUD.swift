import SwiftUI

/// Speed and course over ground, Apple-Maps-speedometer style.
struct InstrumentsHUD: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let tracker = model.location
        HStack(spacing: 14) {
            Instrument(title: "SOG", value: tracker.sog.map { String(format: "%.1f", $0) } ?? "–", unit: "kn")
            Instrument(title: "COG", value: tracker.cog.map { String(format: "%03.0f", $0) } ?? "–", unit: "°T")
            if tracker.isRecording {
                Image(systemName: "record.circle")
                    .foregroundStyle(.red)
                    .symbolEffect(.pulse)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
    }
}

private struct Instrument: View {
    var title: String
    var value: String
    var unit: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value)
                    .font(.title3.weight(.semibold).monospacedDigit())
                    .contentTransition(.numericText())
                Text(unit)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
