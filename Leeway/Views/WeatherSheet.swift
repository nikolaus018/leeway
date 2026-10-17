import Charts
import CoreLocation
import SwiftUI

/// Weather where you are (or where the map is): wind now and the next day, official warnings,
/// the tide, and sun times.
struct WeatherSheet: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationStack {
            List {
                WarningsSection()
                WeatherHereSection()
                TideSection()
                SunSection()
            }
            .listSectionSpacing(.compact)
            .navigationTitle(model.location.location == nil ? "Weather · map centre" : "Weather here")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

struct WeatherHereSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Section {
            if let forecast = model.localForecast, let series = forecast.points.first {
                let now = series.conditions(at: .now)
                let hours = (0...24).map { Date.now.addingTimeInterval(Double($0) * 3600) }
                let outlook = hours.map { ($0, series.conditions(at: $0)) }
                HStack(spacing: 14) {
                    Image(systemName: "location.north.fill")
                        .font(.title)
                        .rotationEffect(.degrees(now.windFrom + 180))
                        .foregroundStyle(WindScale.color(now.windSpeed))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(Int(now.windSpeed.rounded())) kn \(now.description)")
                            .font(.title3.weight(.semibold))
                        Text("From \(Geo.compassPoint(now.windFrom)) · gusts \(Int(now.gust.rounded())) kn"
                             + (now.waveHeight.flatMap { $0 >= 0.1 ? String(format: " · waves %.1f m", $0) : nil } ?? ""))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        if let extras = extras(series) {
                            Text(extras)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Chart {
                    ForEach(outlook, id: \.0) { time, c in
                        AreaMark(x: .value("Time", time), yStart: .value("Wind", c.windSpeed), yEnd: .value("Gusts", c.gust))
                            .foregroundStyle(.orange.opacity(0.25))
                        LineMark(x: .value("Time", time), y: .value("Wind", c.windSpeed))
                            .foregroundStyle(.tint)
                            .interpolationMethod(.catmullRom)
                    }
                }
                .chartXAxis {
                    AxisMarks(values: .stride(by: .hour, count: 6)) { _ in
                        AxisGridLine()
                        AxisValueLabel(format: .dateTime.hour())
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading) { value in
                        AxisGridLine()
                        AxisValueLabel { if let v = value.as(Double.self) { Text("\(Int(v))") } }
                    }
                }
                .frame(height: 110)
                let buraGust = outlook.filter { $0.1.isBura }.map(\.1.gust).max() ?? 0
                if buraGust >= 25 {
                    Label("Bura in the next 24 h, gusts to \(Int(buraGust.rounded())) kn", systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.orange)
                }
            } else {
                Label {
                    Text("Loading forecast…")
                } icon: {
                    ProgressView()
                }
                .foregroundStyle(.secondary)
            }
        } header: {
            Text("Wind")
        } footer: {
            if let forecast = model.localForecast, let wind = forecast.windModels(from: .now, to: .now.addingTimeInterval(86400)).first?.model {
                Text("Wind and gusts (kn), next 24 h · \(wind.label) · via \(forecast.source)")
            }
        }
        .task(id: model.location.location == nil) { model.refreshLocalWeather() }
    }

    /// Air and sea temperature, pressure, wave period and rain now, where the data server has them.
    private func extras(_ series: ForecastSeries) -> String? {
        var parts: [String] = []
        if let air = series.value(series.airTemp, at: .now) { parts.append("Air \(Int(air.rounded()))°") }
        if let sea = series.value(series.seaTemp, at: .now) { parts.append("sea \(Int(sea.rounded()))°") }
        if let pressure = series.value(series.pressure, at: .now) { parts.append("\(Int(pressure.rounded())) hPa") }
        if let period = series.value(series.wavePeriod, at: .now), period > 0 { parts.append(String(format: "%.0f s period", period)) }
        if let rain = series.value(series.precipitation, at: .now), rain >= 0.1 { parts.append(String(format: "rain %.1f mm/h", rain)) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}


/// Official warnings for the area, marine ones first.
private struct WarningsSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let current = model.warnings.filter { ($0.expiresDate ?? .distantFuture) > .now }
            .sorted { $0.isMarine && !$1.isMarine }
        if !current.isEmpty {
            Section {
                ForEach(current.prefix(6)) { warning in
                    DisclosureGroup {
                        if let description = warning.description { Text(description).font(.footnote) }
                        if let instruction = warning.instruction {
                            Text(instruction).font(.caption).foregroundStyle(.secondary)
                        }
                        Text(validity(warning)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(warning.event).font(.subheadline.weight(.semibold))
                                Text(warning.areaName).font(.caption).foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(warning.colour)
                        }
                    }
                }
            } header: {
                Text("Warnings")
            } footer: {
                Text("From the national weather services via MeteoAlarm.")
            }
        }
    }

    private func validity(_ w: WeatherWarning) -> String {
        let format = Date.FormatStyle.dateTime.weekday(.abbreviated).hour().minute()
        return [w.onsetDate.map { "From \($0.formatted(format))" }, w.expiresDate.map { "until \($0.formatted(format))" }]
            .compactMap { $0 }.joined(separator: " ")
    }
}

extension WeatherWarning {
    var colour: Color {
        switch level ?? "" {
        case "red": .red
        case "orange": .orange
        default: severity == "Severe" || severity == "Extreme" ? .orange : .yellow
        }
    }
}

/// Sea level (tide and surge) for the next two days, with highs and lows.
private struct TideSection: View {
    @Environment(AppModel.self) private var model
    @State private var level: SeaLevel?
    @State private var failed = false

    var body: some View {
        Section {
            if let level {
                let window = level.points.filter { $0.0 > .now.addingTimeInterval(-3 * 3600) && $0.0 < .now.addingTimeInterval(45 * 3600) }
                Chart {
                    ForEach(window, id: \.0) { time, height in
                        AreaMark(x: .value("Time", time), y: .value("Height", height))
                            .foregroundStyle(.blue.opacity(0.15))
                            .interpolationMethod(.catmullRom)
                        LineMark(x: .value("Time", time), y: .value("Height", height))
                            .foregroundStyle(.blue)
                            .interpolationMethod(.catmullRom)
                    }
                    RuleMark(x: .value("Now", Date.now))
                        .foregroundStyle(.secondary)
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                }
                .chartXAxis {
                    AxisMarks(values: .stride(by: .hour, count: 6)) { _ in
                        AxisGridLine()
                        AxisValueLabel(format: .dateTime.hour())
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading) { value in
                        AxisGridLine()
                        AxisValueLabel { if let v = value.as(Double.self) { Text(String(format: "%.1f", v)) } }
                    }
                }
                .frame(height: 110)
                let next = level.turningPoints.filter { $0.time > .now }.prefix(4)
                HStack {
                    ForEach(Array(next.enumerated()), id: \.offset) { _, p in
                        VStack(spacing: 1) {
                            Image(systemName: p.high ? "arrow.up" : "arrow.down").font(.caption2.weight(.bold))
                            Text(p.time.formatted(date: .omitted, time: .shortened)).font(.caption.weight(.semibold).monospacedDigit())
                            Text(String(format: "%+.2f m", p.height)).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
            } else if failed {
                Text("No tide data for this spot.").foregroundStyle(.secondary)
            } else {
                Label { Text("Loading tide…") } icon: { ProgressView() }
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Tide")
        } footer: {
            Text("Sea level relative to mean sea level, tide plus surge (Open-Meteo marine model).")
        }
        .task(id: Int(here.latitude * 20) * 10_000 + Int(here.longitude * 20)) {
            failed = false
            do { level = try await Seadata.current.seaLevel(at: here) } catch { failed = true }
        }
    }

    private var here: CLLocationCoordinate2D { model.location.location?.coordinate ?? model.camera.center }
}

/// Dawn, sunrise, sunset and dusk today.
private struct SunSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let here = model.location.location?.coordinate ?? model.camera.center
        let times = Sun.times(at: here, on: .now)
        Section("Sun") {
            HStack {
                SunTime(symbol: "sun.horizon", title: "Dawn", time: times.dawn)
                SunTime(symbol: "sunrise.fill", title: "Sunrise", time: times.sunrise)
                SunTime(symbol: "sunset.fill", title: "Sunset", time: times.sunset)
                SunTime(symbol: "moon.stars", title: "Dusk", time: times.dusk)
            }
        }
    }
}

private struct SunTime: View {
    var symbol: String
    var title: String
    var time: Date?

    var body: some View {
        VStack(spacing: 2) {
            Image(systemName: symbol).foregroundStyle(.orange)
            Text(time.map { $0.formatted(date: .omitted, time: .shortened) } ?? "–")
                .font(.subheadline.weight(.semibold).monospacedDigit())
            Text(title).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}
