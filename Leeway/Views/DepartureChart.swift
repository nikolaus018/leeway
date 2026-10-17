import Charts
import SwiftUI

/// Passage time for every hourly departure over the forecast window, coloured by how rough it gets.
struct DepartureChart: View {
    @Environment(AppModel.self) private var model
    @State private var selection: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let best = model.bestDeparture {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Best departure")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("\(best.departure.formatted(.dateTime.weekday(.abbreviated).hour().minute())) · \(best.duration.hoursMinutes)")
                            .font(.subheadline.weight(.semibold))
                    }
                    Spacer()
                    Button("Use") { model.departure = best.departure }
                        .buttonStyle(.glass)
                        .disabled(abs(model.departure.timeIntervalSince(best.departure)) < 60)
                }
            }

            Chart {
                ForEach(model.departureOptions) { option in
                    BarMark(
                        x: .value("Departure", option.departure, unit: .hour),
                        y: .value("Hours", option.duration / 3600)
                    )
                    .foregroundStyle(by: .value("Conditions", option.rating.rawValue))
                }
                RuleMark(x: .value("Selected", model.departure, unit: .hour))
                    .foregroundStyle(.primary.opacity(0.6))
                    .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [3, 3]))
            }
            .chartForegroundStyleScale([
                DepartureOption.Rating.good.rawValue: Color.green,
                DepartureOption.Rating.fair.rawValue: Color.yellow,
                DepartureOption.Rating.rough.rawValue: Color.red,
            ])
            .chartXAxis {
                AxisMarks(values: .stride(by: .hour, count: 12)) { value in
                    AxisGridLine()
                    AxisValueLabel(format: .dateTime.weekday(.abbreviated).hour())
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading) { value in
                    AxisGridLine()
                    AxisValueLabel { if let h = value.as(Double.self) { Text("\(Int(h))h") } }
                }
            }
            .chartLegend(position: .bottom, alignment: .leading)
            .chartXSelection(value: $selection)
            .frame(height: 150)
            .onChange(of: selection) { _, date in
                guard let date,
                      let nearest = model.departureOptions.min(by: {
                          abs($0.departure.timeIntervalSince(date)) < abs($1.departure.timeIntervalSince(date))
                      })
                else { return }
                if nearest.departure != model.departure {
                    UISelectionFeedbackGenerator().selectionChanged()
                    model.departure = nearest.departure
                }
            }
        }
        .padding(.vertical, 6)
    }
}
