import SwiftUI

/// Speed and course over ground, charted depth under the boat, and position.
struct InstrumentsHUD: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let tracker = model.location
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 14) {
                Instrument(title: "SOG", value: tracker.sog.map { String(format: "%.1f", $0) } ?? "–", unit: "kn")
                Instrument(title: "COG", value: tracker.cog.map { String(format: "%03.0f", $0) } ?? "–", unit: "°T")
                Instrument(title: "DPT", value: depth, unit: "m")
                if tracker.isRecording {
                    Image(systemName: "record.circle")
                        .foregroundStyle(.red)
                        .symbolEffect(.pulse)
                }
            }
            if let position = tracker.location?.coordinate {
                Text(position.formatted)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
    }

    /// Depth from the offline chart at the boat's position (not a depth sounder).
    private var depth: String {
        guard let here = model.location.location?.coordinate,
              case .depth(let d)? = model.region(containing: [here])?.sounding(at: here) else { return "–" }
        return d >= 100 ? "\(Int(d))" : String(format: "%.1f", d)
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
