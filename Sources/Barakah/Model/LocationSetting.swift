import Foundation
import CoreLocation

/// A place prayer times are calculated for.
///
/// Times are always computed in the *location's* timezone, so travelling — or
/// pinning a hometown while abroad — stays correct.
public struct PlaceSetting: Codable, Hashable, Sendable {
    public var name: String
    public var latitude: Double
    public var longitude: Double
    /// IANA identifier, e.g. "Asia/Riyadh". Empty means "use the system timezone".
    public var timeZoneIdentifier: String

    public init(name: String, latitude: Double, longitude: Double, timeZoneIdentifier: String = "") {
        self.name = name
        self.latitude = latitude
        self.longitude = longitude
        self.timeZoneIdentifier = timeZoneIdentifier
    }

    public var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    public var timeZone: TimeZone {
        TimeZone(identifier: timeZoneIdentifier) ?? .current
    }

    /// The Sacred Mosque — a sane, meaningful default before the user grants
    /// location access or picks a city.
    public static let makkah = PlaceSetting(
        name: "Makkah",
        latitude: 21.422510,
        longitude: 39.826168,
        timeZoneIdentifier: "Asia/Riyadh"
    )

    public var shortCoordinateDescription: String {
        String(format: "%.3f°%@, %.3f°%@",
               abs(latitude), latitude >= 0 ? "N" : "S",
               abs(longitude), longitude >= 0 ? "E" : "W")
    }
}

/// Where the place comes from.
public enum LocationMode: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Follow CoreLocation, updating as the machine moves.
    case automatic
    /// Use a city the user searched for and pinned.
    case manual

    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .automatic: "Use my location"
        case .manual: "Set manually"
        }
    }
}
