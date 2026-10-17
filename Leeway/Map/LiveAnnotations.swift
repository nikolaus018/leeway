import MapKit
import UIKit

// MARK: - Wind arrows

/// Wind at one grid point at the chosen hour.
struct WindArrow: Equatable {
    var latitude: Double
    var longitude: Double
    var speed: Double
    var from: Double
    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: latitude, longitude: longitude) }
}

final class WindArrowAnnotation: NSObject, MKAnnotation {
    let arrow: WindArrow
    var coordinate: CLLocationCoordinate2D { arrow.coordinate }
    init(_ arrow: WindArrow) { self.arrow = arrow }
}

/// An arrow the way the wind blows, coloured by strength, with the speed in knots.
final class WindArrowView: MKAnnotationView {
    static let reuseID = "windArrow"
    private let arrow = UIImageView()
    private let label = UILabel()

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        frame = CGRect(x: 0, y: 0, width: 34, height: 40)
        arrow.image = UIImage(systemName: "arrow.up", withConfiguration: UIImage.SymbolConfiguration(pointSize: 20, weight: .heavy))
        arrow.contentMode = .center
        arrow.frame = CGRect(x: 0, y: 0, width: 34, height: 26)
        arrow.layer.shadowColor = UIColor.black.cgColor
        arrow.layer.shadowOpacity = 0.35
        arrow.layer.shadowRadius = 1.5
        arrow.layer.shadowOffset = .zero
        label.frame = CGRect(x: 0, y: 25, width: 34, height: 14)
        label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .bold)
        label.textAlignment = .center
        label.layer.shadowColor = UIColor.systemBackground.cgColor
        label.layer.shadowOpacity = 1
        label.layer.shadowRadius = 2
        label.layer.shadowOffset = .zero
        addSubview(arrow)
        addSubview(label)
        isUserInteractionEnabled = false
        displayPriority = MKFeatureDisplayPriority(rawValue: 200)
        collisionMode = .circle
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(_ wind: WindArrow) {
        arrow.transform = CGAffineTransform(rotationAngle: (wind.from + 180).radians)
        arrow.tintColor = WindScale.uiColor(wind.speed)
        label.text = "\(Int(wind.speed.rounded()))"
        label.textColor = .label
    }
}

// MARK: - AIS vessels

/// A ship on the map; `danger` when it will pass close to us soon.
struct VesselMarker: Equatable {
    var vessel: Vessel
    var danger: Bool
}

final class VesselAnnotation: NSObject, MKAnnotation {
    var marker: VesselMarker
    @objc dynamic var coordinate: CLLocationCoordinate2D
    var title: String? { marker.vessel.displayName }

    init(_ marker: VesselMarker) {
        self.marker = marker
        coordinate = marker.vessel.coordinate
    }
}

/// A pointed hull along the ship's heading while under way, a dot when stopped.
final class VesselView: MKAnnotationView {
    static let reuseID = "vessel"
    private let hull = UIImageView()

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        frame = CGRect(x: 0, y: 0, width: 30, height: 30)
        hull.frame = bounds
        addSubview(hull)
        canShowCallout = false
        collisionMode = .circle
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(_ marker: VesselMarker) {
        let vessel = marker.vessel
        let moving = vessel.isUnderway && vessel.course != nil
        hull.image = Self.image(moving: moving, fill: marker.danger ? .systemRed : Self.colour(vessel.category))
        hull.transform = moving ? CGAffineTransform(rotationAngle: (vessel.course ?? 0).radians) : .identity
        displayPriority = marker.danger ? .required : MKFeatureDisplayPriority(rawValue: 650)
        zPriority = marker.danger ? .max : .defaultUnselected
    }

    private static func colour(_ category: Vessel.Category) -> UIColor {
        switch category {
        case .sailing, .pleasure: .systemPurple
        case .passenger, .highSpeed: .systemBlue
        case .cargo: .systemGreen
        case .tanker: .systemBrown
        case .fishing: .systemOrange
        case .service: .systemTeal
        case .other: .systemGray
        }
    }

    private static func image(moving: Bool, fill: UIColor) -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 30, height: 30)).image { _ in
            let path: UIBezierPath
            if moving {
                path = UIBezierPath()
                path.move(to: CGPoint(x: 15, y: 3))
                path.addLine(to: CGPoint(x: 22, y: 25))
                path.addLine(to: CGPoint(x: 15, y: 21))
                path.addLine(to: CGPoint(x: 8, y: 25))
                path.close()
            } else {
                path = UIBezierPath(ovalIn: CGRect(x: 9, y: 9, width: 12, height: 12))
            }
            fill.setFill()
            UIColor.white.setStroke()
            path.lineWidth = 2
            path.lineJoinStyle = .round
            path.stroke()
            path.fill()
        }
    }
}
