import Foundation
import CoreLocation
import Observation
import OSLog

/// Resolves where the user is, and lets them search for a place by name.
///
/// Prayer times are a location-derived quantity, so a wrong or stale location is
/// a wrong prayer time. This service therefore caches the last good fix into
/// settings, so the app has real times the instant it launches instead of
/// showing placeholders until CoreLocation answers.
@MainActor
@Observable
public final class LocationService: NSObject {
    public private(set) var authorization: CLAuthorizationStatus
    public private(set) var isResolving = false
    public private(set) var lastError: String?

    /// Called whenever a new place is resolved, so settings can cache it.
    public var onResolve: ((PlaceSetting) -> Void)?

    private let manager = CLLocationManager()
    private let geocoder = CLGeocoder()
    private let log = Logger(subsystem: Barakah.subsystem, category: "location")

    public override init() {
        authorization = manager.authorizationStatus
        super.init()
        manager.delegate = self
        // Prayer times shift by roughly a minute per 20 km, so kilometre accuracy
        // is ample and far kinder to the battery than best-accuracy tracking.
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
        manager.distanceFilter = 5_000
    }

    public var isAuthorized: Bool {
        authorization == .authorizedAlways
    }

    public var needsPermission: Bool {
        authorization == .notDetermined
    }

    public var isDenied: Bool {
        authorization == .denied || authorization == .restricted
    }

    public func requestPermission() {
        manager.requestAlwaysAuthorization()
    }

    /// Ask for a fresh fix. Harmless to call repeatedly.
    public func refresh() {
        guard isAuthorized else { return }
        isResolving = true
        manager.startUpdatingLocation()
    }

    /// Search for a place by name, for the manual location picker.
    public func search(_ query: String) async -> [PlaceSetting] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return [] }
        do {
            let placemarks = try await geocoder.geocodeAddressString(trimmed)
            return placemarks.compactMap(Self.place(from:))
        } catch {
            log.debug("geocode failed: \(error.localizedDescription)")
            return []
        }
    }

    private static func place(from placemark: CLPlacemark) -> PlaceSetting? {
        guard let coordinate = placemark.location?.coordinate else { return nil }
        let name = [placemark.locality ?? placemark.name, placemark.administrativeArea, placemark.country]
            .compactMap { $0 }
            .removingAdjacentDuplicates()
            .joined(separator: ", ")
        return PlaceSetting(
            name: name.isEmpty ? "Unknown place" : name,
            latitude: coordinate.latitude,
            longitude: coordinate.longitude,
            timeZoneIdentifier: placemark.timeZone?.identifier ?? TimeZone.current.identifier
        )
    }
}

extension LocationService: CLLocationManagerDelegate {
    nonisolated public func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.authorization = status
            if status == .authorizedAlways { self.refresh() }
        }
    }

    nonisolated public func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            manager.stopUpdatingLocation()
            self.isResolving = false
            self.lastError = nil

            // Reverse-geocode for a human name, but never let a failed lookup
            // block the coordinates — the times only need latitude and longitude.
            var place = PlaceSetting(
                name: "Current location",
                latitude: location.coordinate.latitude,
                longitude: location.coordinate.longitude,
                timeZoneIdentifier: TimeZone.current.identifier
            )
            if let placemark = try? await self.geocoder.reverseGeocodeLocation(location).first,
               let resolved = LocationService.place(from: placemark) {
                place = resolved
            }
            self.onResolve?(place)
        }
    }

    nonisolated public func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor [weak self] in
            self?.isResolving = false
            self?.lastError = error.localizedDescription
        }
    }
}

private extension Array where Element == String {
    /// "Cairo, Cairo, Egypt" reads badly; collapse the repetition.
    func removingAdjacentDuplicates() -> [String] {
        reduce(into: [String]()) { result, element in
            if result.last?.caseInsensitiveCompare(element) != .orderedSame {
                result.append(element)
            }
        }
    }
}
