import MapKit
import SwiftUI

/// Defers the initial region until the view has a size, otherwise MapKit zooms way out.
final class SizedMapView: MKMapView {
    var onFirstLayout: (() -> Void)?

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0, let action = onFirstLayout else { return }
        onFirstLayout = nil
        action()
    }
}

// MARK: - Annotations

final class WaypointAnnotation: NSObject, MKAnnotation {
    let id: Waypoint.ID
    let index: Int
    let count: Int
    @objc dynamic var coordinate: CLLocationCoordinate2D

    init(waypoint: Waypoint, index: Int, count: Int) {
        id = waypoint.id
        self.index = index
        self.count = count
        coordinate = waypoint.coordinate
    }

    var title: String? { index == 0 ? "Start" : index == count - 1 && count > 1 ? "Finish" : "Waypoint \(index + 1)" }
}

final class WaypointView: MKMarkerAnnotationView {
    static let reuseID = "waypoint"

    func configure(_ waypoint: WaypointAnnotation, editing: Bool) {
        let isStart = waypoint.index == 0
        let isEnd = waypoint.index == waypoint.count - 1 && waypoint.count > 1
        markerTintColor = isStart ? .systemGreen : isEnd ? .systemRed : .tintColor
        glyphText = isStart ? nil : isEnd ? nil : "\(waypoint.index + 1)"
        glyphImage = isStart ? UIImage(systemName: "sailboat.fill") : isEnd ? UIImage(systemName: "flag.checkered") : nil
        isDraggable = editing
        canShowCallout = false
        displayPriority = .required
        collisionMode = .circle
    }
}

final class ConditionsAnnotation: NSObject, MKAnnotation {
    let sample: PassageSample
    var coordinate: CLLocationCoordinate2D { sample.coordinate }
    init(_ sample: PassageSample) { self.sample = sample }
}

/// A small wind arrow + speed chip drawn along the route at the time the boat passes.
final class ConditionsView: MKAnnotationView {
    static let reuseID = "conditions"
    private let arrow = UIImageView()
    private let label = UILabel()
    private let background = UIVisualEffectView(effect: UIGlassEffect())

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        frame = CGRect(x: 0, y: 0, width: 54, height: 24)
        background.frame = bounds
        background.cornerConfiguration = .capsule()
        background.clipsToBounds = true
        addSubview(background)

        arrow.image = UIImage(systemName: "location.north.fill")
        arrow.contentMode = .scaleAspectFit
        arrow.frame = CGRect(x: 6, y: 5, width: 14, height: 14)
        label.frame = CGRect(x: 22, y: 0, width: 30, height: 24)
        label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        background.contentView.addSubview(arrow)
        background.contentView.addSubview(label)
        displayPriority = MKFeatureDisplayPriority(rawValue: 600)
        collisionMode = .rectangle
        centerOffset = CGPoint(x: 34, y: 0)
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(_ sample: PassageSample) {
        let c = sample.conditions
        // Arrow points the way the wind is blowing.
        arrow.transform = CGAffineTransform(rotationAngle: (c.windFrom + 180).radians)
        arrow.tintColor = WindScale.uiColor(c.windSpeed)
        label.text = "\(Int(c.windSpeed.rounded()))kn"
    }
}

enum WindScale {
    static func color(_ knots: Double) -> Color { Color(uiColor: uiColor(knots)) }

    static func uiColor(_ knots: Double) -> UIColor {
        switch knots {
        case ..<6: .systemTeal
        case ..<12: .systemGreen
        case ..<18: .systemYellow
        case ..<24: .systemOrange
        case ..<30: .systemRed
        default: .systemPurple
        }
    }
}

/// Harbours, marinas and anchorages from the chart region.
final class SeamarkAnnotation: NSObject, MKAnnotation {
    let seamark: Seamark
    var coordinate: CLLocationCoordinate2D { seamark.coordinate }
    var title: String? { seamark.name }
    init(_ seamark: Seamark) { self.seamark = seamark }
}

final class HarbourView: MKAnnotationView {
    static let reuseID = "harbour"
    private let badge = UIImageView()
    private let glyph = UILabel()

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        frame = CGRect(x: 0, y: 0, width: 22, height: 22)
        backgroundColor = UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 0.15, alpha: 0.9) : UIColor(white: 1, alpha: 0.9) }
        layer.cornerRadius = 11
        layer.borderWidth = 1.5
        badge.frame = bounds.insetBy(dx: 5, dy: 5)
        badge.contentMode = .scaleAspectFit
        addSubview(badge)
        glyph.frame = bounds
        glyph.textAlignment = .center
        glyph.font = .systemFont(ofSize: 13, weight: .bold)
        glyph.text = "⚓︎"
        addSubview(glyph)
        collisionMode = .circle
        displayPriority = MKFeatureDisplayPriority(rawValue: 300)
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(_ seamark: Seamark) {
        let anchorage = seamark.type == "anchorage"
        let colour: UIColor = anchorage ? .systemPurple : .systemIndigo
        badge.image = anchorage ? nil : UIImage(systemName: "sailboat.fill")
        badge.tintColor = colour
        glyph.isHidden = !anchorage
        glyph.textColor = colour
        layer.borderColor = colour.cgColor
        canShowCallout = false
    }
}

/// Crosshair at the point the inspector card describes.
final class InspectAnnotation: NSObject, MKAnnotation {
    @objc dynamic var coordinate: CLLocationCoordinate2D
    init(_ coordinate: CLLocationCoordinate2D) { self.coordinate = coordinate }
}

final class InspectView: MKAnnotationView {
    static let reuseID = "inspect"

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        let image = UIImage(systemName: "plus.viewfinder", withConfiguration: UIImage.SymbolConfiguration(pointSize: 30, weight: .medium))
        self.image = image?.withTintColor(.systemRed, renderingMode: .alwaysOriginal)
        displayPriority = .required
        isUserInteractionEnabled = false
    }

    required init?(coder: NSCoder) { fatalError() }
}
