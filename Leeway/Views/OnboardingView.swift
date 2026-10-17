import SwiftUI

/// First launch: what Leeway does, and the one thing every sailor has to accept before relying on
/// it. Location is asked for only after this, when the reason is clear.
struct OnboardingView: View {
    var accept: () -> Void
    @State private var understood = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Image(systemName: "sailboat.fill")
                    .font(.system(.largeTitle, design: .default).weight(.regular))
                    .imageScale(.large)
                    .accessibilityHidden(true)
                    .foregroundStyle(.tint)
                    .padding(.top, 40)
                Text("Leeway")
                    .font(.largeTitle.weight(.bold))
                VStack(alignment: .leading, spacing: 16) {
                    Feature(symbol: "map", title: "One chart for the whole sea",
                            text: "Depths, contours, lights and buoys, with detailed offline charts for the Croatian coast.")
                    Feature(symbol: "point.topleft.down.to.point.bottomright.curvepath", title: "Safe and fast routes",
                            text: "Around land, shallows and charted dangers, timed and optimised with the forecast wind.")
                    Feature(symbol: "location.north.line", title: "Underway",
                            text: "Navigation, AIS ships and collision alarm, anchor watch, man overboard, logbook.")
                }
                VStack(alignment: .leading, spacing: 10) {
                    Label("Not for navigation", systemImage: "exclamationmark.triangle.fill")
                        .font(.headline)
                        .foregroundStyle(.orange)
                    Text("Leeway's charts are built from open data and do not show every rock, wreck or shoal. Routes, depths, ship positions and forecasts can be wrong or out of date. Always use official charts and publications, keep a proper lookout, and rely on your own judgement.")
                        .font(.subheadline)
                    Toggle("I understand that Leeway is a planning aid, not a certified navigation system.", isOn: $understood)
                        .font(.subheadline.weight(.semibold))
                }
                .padding(16)
                .background(.orange.opacity(0.1), in: .rect(cornerRadius: 18))
                Button {
                    accept()
                } label: {
                    Text("Continue")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 34)
                }
                .buttonStyle(.glassProminent)
                .disabled(!understood)
                Text("Next, Leeway asks to use your location: to show your boat on the chart, record your track and run the anchor and collision alarms. Your position is only sent to Leeway's data server to fetch the forecast and ships around you.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 30)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
        }
        .interactiveDismissDisabled()
    }
}

private struct Feature: View {
    var symbol: String
    var title: String
    var text: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(text).font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
