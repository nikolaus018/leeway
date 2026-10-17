import CoreLocation
import SwiftUI

/// Underway housekeeping: the track being recorded and past ones, the anchor watch, and marks.
struct LogSheet: View {
    @Environment(AppModel.self) private var model
    var close: () -> Void

    var body: some View {
        NavigationStack {
            List {
                TrackSection()
                AnchorWatchSection()
                MarksSection(close: close)
                LogbookSection(close: close)
            }
            .listSectionSpacing(.compact)
            .navigationTitle("Log")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

struct TrackSection: View {
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


/// The user's marks: tap to show on the chart.
private struct MarksSection: View {
    @Environment(AppModel.self) private var model
    var close: () -> Void

    var body: some View {
        Section {
            ForEach(model.marks) { mark in
                Button {
                    model.centre(on: mark.coordinate, zoom: 14)
                    model.inspection = AppModel.Inspection(coordinate: mark.coordinate, mark: mark)
                    close()
                } label: {
                    Label {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(mark.name)
                            Text(mark.coordinate.formatted).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: mark.symbol).foregroundStyle(.orange)
                    }
                }
                .tint(.primary)
            }
            .onDelete { offsets in offsets.map { model.marks[$0] }.forEach(model.deleteMark) }
            Button("Mark boat position", systemImage: "mappin.and.ellipse") { model.markHere() }
                .disabled(model.location.location == nil)
        } header: {
            HStack {
                Text("Marks")
                Spacer()
                if !model.marks.isEmpty {
                    ShareLink(item: GPXFile(marks: model.marks), preview: SharePreview("Leeway marks")) {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
            }
        } footer: {
            Text("Tap the chart and choose Mark to save any spot.")
        }
    }
}

/// Finished passages: distance, time, speeds; show one on the chart or share it as GPX.
private struct LogbookSection: View {
    @Environment(AppModel.self) private var model
    var close: () -> Void

    var body: some View {
        if !model.logbook.isEmpty {
            Section("Logbook") {
                ForEach(model.logbook) { track in
                    Button {
                        model.show(track)
                        close()
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(track.name).font(.subheadline.weight(.semibold))
                                if model.shownTrack?.id == track.id {
                                    Image(systemName: "eye.fill").font(.caption).foregroundStyle(.tint)
                                }
                            }
                            Text(stats(track)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                    .tint(.primary)
                    .swipeActions(edge: .leading) {
                        ShareLink(item: GPXFile(track: track), preview: SharePreview(track.name)) {
                            Label("GPX", systemImage: "square.and.arrow.up")
                        }
                        .tint(.blue)
                    }
                }
                .onDelete { model.logbook.remove(atOffsets: $0) }
                if model.shownTrack != nil {
                    Button("Hide logbook track", systemImage: "eye.slash") { model.shownTrack = nil }
                }
            }
        }
    }

    private func stats(_ t: TrackLog) -> String {
        var parts = [String(format: "%.1f NM", t.distance), t.duration.hoursMinutes]
        if let avg = t.averageSOG { parts.append(String(format: "avg %.1f kn", avg)) }
        if let max = t.maxSOG { parts.append(String(format: "max %.1f kn", max)) }
        return parts.joined(separator: " · ")
    }
}
