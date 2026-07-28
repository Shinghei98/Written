import CoreLocation
import Foundation

/// Where the person is, to the district — not to the metre.
///
/// A dating profile needs a neighbourhood, and nothing here keeps anything
/// finer: the coordinate is used to look up a placemark and then dropped. What
/// is stored is "Shibuya, Tokyo", which is what the profile shows anyway.
///
/// One fix, no tracking. `CLLocationManager` is asked for a single reading
/// rather than a stream of updates, so nothing follows the user around.
@MainActor
final class LocationDistiller: NSObject {

    private let manager = CLLocationManager()
    private var pending: CheckedContinuation<CLLocation, Error>?

    enum LocationError: LocalizedError {
        case denied
        case unavailable

        var errorDescription: String? {
            switch self {
            case .denied:
                return "Written can't read your location. Turn it on in Settings › Privacy › Location Services."
            case .unavailable:
                return "Couldn't work out where you are."
            }
        }
    }

    override init() {
        super.init()
        manager.delegate = self
        // A district needs a kilometre, not a metre, and the coarser fix is
        // faster and cheaper.
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
    }

    var isDenied: Bool {
        [.denied, .restricted].contains(manager.authorizationStatus)
    }

    var needsPermission: Bool {
        manager.authorizationStatus == .notDetermined
    }

    /// Asks, fixes, reverse-geocodes, and returns the one record worth keeping.
    func distill() async throws -> DistilledRecord {
        if needsPermission {
            manager.requestWhenInUseAuthorization()
            // The delegate resumes `pending` when the answer arrives; a fix
            // requested before then is simply ignored by CoreLocation.
            try await waitForAuthorization()
        }
        guard !isDenied else { throw LocationError.denied }
        return try await place(at: try await currentCoordinate())
    }

    /// Where the device is now, without naming it.
    func currentCoordinate() async throws -> CLLocationCoordinate2D {
        if needsPermission {
            manager.requestWhenInUseAuthorization()
            try await waitForAuthorization()
        }
        guard !isDenied else { throw LocationError.denied }
        return try await fix().coordinate
    }

    /// The record for any point — the device's own fix, or somewhere the user
    /// dropped a pin. The same reverse geocode either way, and the same rule
    /// about what is kept: a district and a city, never the coordinate.
    func place(at coordinate: CLLocationCoordinate2D) async throws -> DistilledRecord {
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        let placemarks = try await CLGeocoder().reverseGeocodeLocation(location)
        guard let place = placemarks.first else { throw LocationError.unavailable }

        // District then city, dropping whichever the geocoder didn't supply —
        // plenty of places have no sub-locality at all.
        let parts = [place.subLocality, place.locality].compactMap { $0 }
        let name = parts.isEmpty ? (place.administrativeArea ?? "") : parts.joined(separator: ", ")
        guard !name.isEmpty else { throw LocationError.unavailable }

        var extras: [String] = []
        if let district = place.subLocality { extras.append("district=\(district)") }
        if let city = place.locality { extras.append("city=\(city)") }
        if let region = place.administrativeArea { extras.append("region=\(region)") }
        if let country = place.country { extras.append("country=\(country)") }

        return DistilledRecord(
            source: "location", dataType: "place", itemID: "current",
            name: name, creator: "", detail: place.country ?? "",
            extra: extras.joined(separator: ";"), collectedAt: Date()
        )
    }

    // MARK: - Bridging the delegate to async

    private var authorizationWaiters: [CheckedContinuation<Void, Never>] = []

    private func waitForAuthorization() async throws {
        await withCheckedContinuation { continuation in
            authorizationWaiters.append(continuation)
        }
    }

    private func fix() async throws -> CLLocation {
        try await withCheckedThrowingContinuation { continuation in
            pending = continuation
            manager.requestLocation()
        }
    }
}

extension LocationDistiller: CLLocationManagerDelegate {
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            guard manager.authorizationStatus != .notDetermined else { return }
            let waiters = authorizationWaiters
            authorizationWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        Task { @MainActor in
            guard let location = locations.last else { return }
            pending?.resume(returning: location)
            pending = nil
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            pending?.resume(throwing: error)
            pending = nil
        }
    }
}
