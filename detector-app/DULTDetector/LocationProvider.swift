import Foundation
import CoreLocation
import MapKit

/// Supplies a human-readable label for the user's current location, used to
/// tag sighting rows so the co-travel heuristic can tell places apart.
///
/// The label is reverse-geocoded via MapKit (MKReverseGeocodingRequest,
/// which replaces the CLGeocoder API deprecated in macOS 26), e.g.
/// "W 30th St, Los Angeles". Rounded coordinates serve as a fallback when
/// geocoding fails, and "unknown" until the first fix arrives.
final class LocationProvider: NSObject, ObservableObject, CLLocationManagerDelegate {

    @Published private(set) var currentLabel = "unknown"
    @Published private(set) var statusMessage = "Requesting location permission..."

    private let manager = CLLocationManager()
    private var activeGeocodingRequest: MKReverseGeocodingRequest?
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

        activeGeocodingRequest?.cancel()
        guard let request = MKReverseGeocodingRequest(location: location) else {
            currentLabel = fallback
            statusMessage = "Geocoder unavailable - using coordinates"
            return
        }
        activeGeocodingRequest = request
        // The completion handler is delivered on the main actor.
        request.getMapItems { [weak self] mapItems, error in
            guard let self else { return }
            if let item = mapItems?.first, let label = Self.label(from: item) {
                self.currentLabel = label
                self.statusMessage = label
            } else {
                self.currentLabel = fallback
                self.statusMessage = "Geocoder unavailable - using coordinates"
                if let error {
                    print("[LocationProvider] reverse geocode failed: \(error.localizedDescription)")
                }
            }
            self.activeGeocodingRequest = nil
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        print("[LocationProvider] location update failed: \(error.localizedDescription)")
        if currentLabel == "unknown" {
            statusMessage = "Location unavailable"
        }
    }

    /// Prefers place name + city for sub-city distinctness (the MapKit
    /// geocoder has no neighborhood field), then city alone.
    private static func label(from item: MKMapItem) -> String? {
        let representations = item.addressRepresentations
        switch (item.name, representations?.cityName) {
        case let (name?, city?) where !name.isEmpty:
            return "\(name), \(city)"
        case let (name?, nil) where !name.isEmpty:
            return name
        default:
            return representations?.cityWithContext ?? representations?.cityName
        }
    }
}
