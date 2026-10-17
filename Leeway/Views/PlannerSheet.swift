import Charts
import CoreLocation
import SwiftUI

struct PlannerSheet: View {
    @Environment(AppModel.self) private var model
    @Binding var detent: PresentationDetent
    @State private var showingBoat = false

    var body: some View {
        NavigationStack {
            Group {
                if model.route.waypoints.isEmpty && !model.isEditing {
                    HomeList(detent: $detent)
                } else {
                    RouteList()
                }
            }
            .listSectionSpacing(.compact)
            .contentMargins(.top, 4, for: .scrollContent)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Boat", systemImage: "sailboat") { showingBoat = true }
                }
                if !model.route.waypoints.isEmpty || model.isEditing {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Close route", systemImage: "xmark") { model.closeRoute() }
                    }
                }
            }
            .sheet(isPresented: $showingBoat) {
                BoatSettingsView()
            }
        }
    }

    private var title: String {
        if model.isEditing { return model.route.waypoints.count < 2 ? "New route" : model.route.name }
        return model.route.waypoints.isEmpty ? "Leeway" : model.route.name
    }
}

// MARK: - Home

private struct HomeList: View {
    @Environment(AppModel.self) private var model
    @Binding var detent: PresentationDetent

    var body: some View {
        List {
            Section {
                Button {
                    model.startNewRoute()
                } label: {
                    Label("Plan a passage", systemImage: "point.topleft.down.to.point.bottomright.curvepath.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 32)
                }
                .buttonStyle(.glassProminent)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            } footer: {
                Text("Or long-press anywhere on the chart to drop a start point.")
            }

            WeatherHereSection()

            TrackSection()

            if !model.savedRoutes.isEmpty {
                Section("Saved routes") {
                    ForEach(model.savedRoutes) { route in
                        Button {
                            model.open(route)
                            detent = .medium
                        } label: {
                            LabeledContent {
                                Text("\(route.distanceNM, format: .number.precision(.fractionLength(1))) NM")
                            } label: {
                                Text(route.name)
                                Text("\(route.waypoints.count) waypoints · \(route.updatedAt.formatted(.relative(presentation: .named)))")
                            }
                        }
                        .tint(.primary)
                    }
                    .onDelete { model.deleteRoutes(at: $0) }
                }
            }

            Section {
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(model.regions, id: \.id) { region in
                        Text("Offline chart: \(region.name). \(region.attribution) Seamark symbols: OpenSeaMap.")
                    }
                    Text("Not for navigation. Always cross-check with official charts.")
                        .fontWeight(.semibold)
                }
            }
        }
    }
}

private struct WeatherHereSection: View {
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
            Text(model.location.location == nil ? "Weather · Rijeka" : "Weather here")
        } footer: {
            if let model = model.localForecast?.windModels(from: .now, to: .now.addingTimeInterval(86400)).first?.model {
                Text("Wind and gusts (kn), next 24 h · \(model.label)")
            }
        }
        .task(id: model.location.location == nil) { model.refreshLocalWeather() }
    }
}

private struct TrackSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let tracker = model.location
        Section {
            if let started = tracker.recordingStarted {
                LabeledContent("Logged", value: String(format: "%.2f NM", tracker.trackDistance))
                LabeledContent("Since") {
                    Text(started, style: tracker.isRecording ? .timer : .time)
                }
            }
            Button {
                tracker.toggleRecording()
            } label: {
                Label(tracker.isRecording ? "Stop recording" : "Record track",
                      systemImage: tracker.isRecording ? "stop.circle.fill" : "record.circle")
            }
            .tint(tracker.isRecording ? .red : .accentColor)
            if !tracker.isRecording && tracker.recordingStarted != nil {
                Button("Clear track", role: .destructive) { tracker.clearTrack() }
            }
        } header: {
            Text("Track")
        } footer: {
            if tracker.location == nil {
                Text("Waiting for GPS…")
            }
        }
    }
}

// MARK: - Route

private struct RouteList: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        List {
            Section {
                SummaryRow()
                Picker("Routing", selection: $model.routingMode) {
                    ForEach(RoutingMode.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                RoutingStatus()
                ForecastStatus()
            }

            if let plan = model.plan {
                Section("Departure") {
                    DatePicker("Leave at", selection: $model.departure, in: Date.now.addingTimeInterval(-3600)...)
                    if !model.departureOptions.isEmpty {
                        DepartureChart()
                    }
                }

                if plan.usedForecast {
                    Section("Conditions on passage") {
                        ConditionsGrid(plan: plan, boat: model.boat)
                    }
                }

                Section(model.route.mode == .automatic ? "Courses to steer" : "Legs") {
                    ForEach(plan.legs) { leg in
                        LegRow(leg: leg, isLast: leg.index == plan.legs.count - 1, sailing: model.boat.propulsion == .sail,
                               hazard: model.legHazards.indices.contains(leg.index) ? model.legHazards[leg.index] : nil)
                    }
                }
            } else {
                Section {
                    Label("Add at least two waypoints to plan the passage.", systemImage: "mappin.and.ellipse")
                        .foregroundStyle(.secondary)
                }
            }

            if model.isEditing && !model.route.waypoints.isEmpty {
                Section("Waypoints") {
                    ForEach(Array(model.route.waypoints.enumerated()), id: \.element.id) { index, waypoint in
                        LabeledContent(index == 0 ? "Start" : index == model.route.waypoints.count - 1 ? "Finish" : "Waypoint \(index + 1)",
                                       value: waypoint.coordinate.formatted)
                            .monospacedDigit()
                    }
                    .onDelete { offsets in
                        offsets.map { model.route.waypoints[$0].id }.forEach(model.removeWaypoint)
                    }
                }
            }

            Section {
                TextField("Route name", text: $model.route.name)
                if !model.isEditing {
                    Button("Edit waypoints", systemImage: "pencil") { model.isEditing = true }
                }
                Button("Reverse route", systemImage: "arrow.left.arrow.right") { model.reverseRoute() }
                    .disabled(model.route.waypoints.count < 2)
                Button(model.isRouteSaved ? "Saved" : "Save route",
                       systemImage: model.isRouteSaved ? "checkmark.circle.fill" : "square.and.arrow.down") {
                    model.saveRoute()
                }
                .disabled(model.route.waypoints.count < 2 || model.isRouteSaved)
            }
        }
    }
}

private struct SummaryRow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let plan = model.plan
        HStack(alignment: .top) {
            Stat(title: "Distance", value: String(format: "%.1f", plan?.distance ?? Geo.length(of: model.path)), unit: "NM")
            Divider()
            Stat(title: "Passage", value: plan.map { $0.duration.hoursMinutes } ?? "–", unit: nil)
            Divider()
            Stat(title: "Arrive", value: plan.map { $0.arrival.formatted(date: .omitted, time: .shortened) } ?? "–",
                 unit: plan.flatMap { Calendar.current.isDate($0.arrival, inSameDayAs: .now) ? nil : $0.arrival.formatted(.dateTime.weekday(.abbreviated)) })
        }
        .frame(maxWidth: .infinity)
    }
}

private struct Stat: View {
    var title: String
    var value: String
    var unit: String?

    var body: some View {
        VStack(spacing: 2) {
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value)
                    .font(.title2.weight(.semibold).monospacedDigit())
                    .contentTransition(.numericText())
                if let unit {
                    Text(unit)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct RoutingStatus: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let safety = String(format: "%.1f m", model.boat.safetyDepth)
        switch model.routingState {
        case .idle:
            EmptyView()
        case .routing:
            Label {
                Text("Finding a safe route…")
            } icon: {
                ProgressView()
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        case .routed(let shallowEnds):
            VStack(alignment: .leading, spacing: 6) {
                Label("Avoids land, charted rocks and wrecks, and water under \(safety)", systemImage: "checkmark.shield")
                    .foregroundStyle(.green)
                if !shallowEnds.isEmpty {
                    Label("\(names(shallowEnds)) in water shallower than \(safety) — approach with care.",
                          systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            }
            .font(.footnote)
        case .manual:
            let problems = model.legHazards.compactMap { $0 }.count
            if problems > 0 {
                Label("\(problems) \(problems == 1 ? "leg crosses" : "legs cross") land or water under \(safety)",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.red)
            } else {
                Label("Straight legs between your waypoints", systemImage: "line.diagonal")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        case .failed(let message):
            Label("\(message) Showing straight legs.", systemImage: "exclamationmark.triangle")
                .font(.footnote)
                .foregroundStyle(.orange)
        }
        ForEach(model.routeNotes, id: \.self) { note in
            Label(note, systemImage: note.contains("bridge") || note.contains("under") ? "arrow.up.and.down" : "exclamationmark.triangle")
                .font(.footnote)
                .foregroundStyle(.orange)
        }
    }

    private func names(_ indices: [Int]) -> String {
        let count = model.route.waypoints.count
        let list = indices.map { $0 == 0 ? "Start" : $0 == count - 1 ? "Finish" : "Waypoint \($0 + 1)" }
        return ListFormatter.localizedString(byJoining: list) + (list.count == 1 ? " is" : " are")
    }
}

private struct ForecastStatus: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        switch model.forecastState {
        case .idle:
            EmptyView()
        case .loading:
            Label {
                Text("Fetching wind, waves and tidal streams…")
            } icon: {
                ProgressView()
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        case .loaded:
            if let plan = model.plan, let forecast = model.forecast {
                let runs = forecast.windModels(from: plan.departure, to: plan.arrival)
                if !runs.isEmpty {
                    Label("Wind: " + runs.enumerated().map { i, run in
                        i == runs.count - 1 ? run.model.label : "\(run.model.label) until \(run.until.formatted(.dateTime.weekday(.abbreviated).hour()))"
                    }.joined(separator: ", then "), systemImage: "scope")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
            }
            if model.plan?.beyondForecast == true {
                Label("Arrival is beyond the forecast range — later legs use the last forecast hour.", systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            } else {
                Label("Timed with forecast wind and tidal streams", systemImage: "wind")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        case .failed(let message):
            HStack {
                Label(message, systemImage: "wifi.exclamationmark")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Retry") { model.refreshForecast() }
                    .font(.footnote)
            }
        }
    }
}

private struct ConditionsGrid: View {
    var plan: PassagePlan
    var boat: BoatProfile

    var body: some View {
        if plan.buraGust >= 25 {
            Label {
                Text("Bura gusts up to \(Int(plan.buraGust.rounded())) kn. Bura gusts hit suddenly and harder under the mountains (Velebit, Učka) and in the channels; reef early or wait it out.")
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
            }
            .font(.footnote.weight(.medium))
            .foregroundStyle(.orange)
        }
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 10) {
            GridRow {
                Metric(symbol: "wind", title: "Max wind", value: "\(Int(plan.maxWind.rounded())) kn",
                       tint: WindScale.color(plan.maxWind), warning: plan.maxWind > boat.maxWind)
                Metric(symbol: "tornado", title: "Gusts", value: "\(Int(plan.maxGust.rounded())) kn",
                       tint: WindScale.color(plan.maxGust), warning: plan.maxGust > boat.maxGust)
            }
            GridRow {
                Metric(symbol: "water.waves", title: "Max waves",
                       value: plan.maxWave.map { String(format: "%.1f m", $0) } ?? "–",
                       tint: .blue, warning: (plan.maxWave ?? 0) > boat.maxWave)
                if boat.propulsion == .sail {
                    Metric(symbol: "engine.combustion", title: "Motoring",
                           value: "\(Int((plan.motoringFraction * 100).rounded())) %", tint: .gray, warning: false)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

private struct Metric: View {
    var symbol: String
    var title: String
    var value: String
    var tint: Color
    var warning: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.body.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 0) {
                Text(title).font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 4) {
                    Text(value).font(.body.weight(.semibold).monospacedDigit())
                    if warning {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension TimeInterval {
    var hoursMinutes: String {
        let minutes = Int((self / 60).rounded())
        return minutes >= 60 ? "\(minutes / 60)h \(String(format: "%02d", minutes % 60))m" : "\(minutes)m"
    }
}

extension CLLocationCoordinate2D {
    /// Degrees and decimal minutes, the way charts and plotters show positions.
    var formatted: String {
        func dm(_ value: Double, _ pos: String, _ neg: String, _ width: Int) -> String {
            let v = abs(value)
            let minutes = (v - v.rounded(.down)) * 60
            return String(format: "%0\(width)d°%06.3f′%@", Int(v), minutes, value >= 0 ? pos : neg)
        }
        return dm(latitude, "N", "S", 2) + " " + dm(longitude, "E", "W", 3)
    }
}
