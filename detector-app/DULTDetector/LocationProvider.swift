import Foundation
import CoreLocation

/// Supplies a human-readable label for the user's current location, used to
/// tag sighting rows so the co-travel heuristic can tell places apart.
///
/// The label is the reverse-geocoded neighborhood/city when available
/// (e.g. "University Park, Los Angeles"), rounded coordinates as a fallback
/// when geocoding fails, and "unknown" until the first fix arrives.
final class LocationProvider: NSObject, ObservableObject, CLLocationManagerDelegate {

    @Published private(set) var currentLabel = "unknown"
    @Published private(set) var statusMessage = "Requesting location permission..."

    private let manager = CLLocationManager()
    private let geocoder = CLGeocoder()
    private var lastGeocodedLocation: CLLocation?
    /// Re-geocode only after moving this far, to respect geocoder rate limits.
    private let regeocodeDistance: CLLocationDistance = 250

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        manager.distanceFilter = 100
        manager.requestWhenInUseAuthorization()
    }

    // MARK: - CLLocationManagerDelegate

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        switch manager.authorizationStatus {
        case .notDetermined:
            statusMessage = "Waiting for location permission..."
        case .restricted, .denied:
            statusMessage = "Location denied - labels stay 'unknown'"
        default:
            // Covers the authorized cases (macOS reports authorizedAlways).
            statusMessage = "Locating..."
            manager.startUpdatingLocation()
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        if let last = lastGeocodedLocation,
           location.distance(from: last) < regeocodeDistance {
            return
        }
        lastGeocodedLocation = location

        // Coordinates rounded to ~100 m; used until geocoding succeeds and
        // as the permanent label if it never does (e.g. offline).
        let fallback = String(format: "%.3f,%.3f",
                              location.coordinate.latitude,
                              location.coordinate.longitude)

        geocoder.cancelGeocode()
        geocoder.reverseGeocodeLocation(location) { [weak self] placemarks, error in
            DispatchQueue.main.async {
                guard let self else { return }
                if let placemark = placemarks?.first,
                   let label = Self.label(from: placemark) {
                    self.currentLabel = label
                    self.statusMessage = label
                } else {
                    self.currentLabel = fallback
                    self.statusMessage = "Geocoder unavailable - using coordinates"
                    if let error {
                        print("[LocationProvider] reverse geocode failed: \(error.localizedDescription)")
                    }
                }
            }
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        print("[LocationProvider] location update failed: \(error.localizedDescription)")
        if currentLabel == "unknown" {
            statusMessage = "Location unavailable"
        }
    }

    /// Prefers neighborhood + city, then either alone, then the place name.
    private static func label(from placemark: CLPlacemark) -> String? {
        switch (placemark.subLocality, placemark.locality) {
        case let (neighborhood?, city?): return "\(neighborhood), \(city)"
        case let (neighborhood?, nil): return neighborhood
        case let (nil, city?): return city
        default: return placemark.name
        }
    }
}
