import SwiftUI

struct LegRow: View {
    var leg: LegResult
    var isLast: Bool
    var sailing: Bool
    var hazard: String? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(leg.index + 1)")
                .font(.caption.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(hazard != nil ? Color.red : isLast ? Color.red.opacity(0.8) : Color.accentColor, in: .circle)

            VStack(alignment: .leading, spacing: 3) {
                Text("\(String(format: "%03.0f", leg.bearing))°T · \(String(format: "%.1f", leg.distance)) NM")
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                Text(details)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if leg.buraGust >= 25 {
                    Label("Bura gusts to \(Int(leg.buraGust.rounded())) kn", systemImage: "wind")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.orange)
                }
                if let hazard {
                    Label(hazard, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.red)
                }
                if abs(leg.meanCurrentAlong) >= 0.2 {
                    Label(String(format: "%@ tide %.1f kn", leg.meanCurrentAlong > 0 ? "Fair" : "Foul", abs(leg.meanCurrentAlong)),
                          systemImage: leg.meanCurrentAlong > 0 ? "arrow.up.forward" : "arrow.down.backward")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(leg.meanCurrentAlong > 0 ? .green : .orange)
                }
            }

            Spacer(minLength: 0)

            VStack(alignment: .trailing, spacing: 3) {
                Text(leg.duration.hoursMinutes)
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                Text(leg.arrival, format: .dateTime.hour().minute())
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private var details: String {
        var parts = [String(format: "%.1f kn avg", leg.averageSOG)]
        if leg.maxWind > 0 {
            parts.append("\(Int(leg.maxWind.rounded())) kn \(leg.maxWind >= 5 ? (leg.windName ?? "wind").lowercased() : "light airs")")
            if sailing {
                parts.append(leg.motoringFraction > 0.5 ? "Motoring" : leg.tacking ? "Beating" : Polar.pointOfSail(twa: leg.meanTWA))
            }
        }
        return parts.joined(separator: " · ")
    }
}
