//
//  LocationParser.swift
//  QuiteListie
//
//  Parses Google Maps and Apple Maps share URLs into coordinates.
//  Follows short-URL redirects asynchronously before parsing.
//

import CoreLocation
import Foundation

enum LocationParser {

    /// Parses a URL string (from clipboard) into a `Coordinate`.
    /// Follows redirects for short URLs (e.g. maps.app.goo.gl) before parsing.
    /// Falls back to geocoding when the resolved URL contains only a place name query.
    static func parseCoordinate(from urlString: String) async -> Coordinate? {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)

        // Try parsing immediately first — handles most full URLs
        if let coord = parseDirectURL(trimmed) {
            return coord
        }

        // For short / redirect URLs, resolve the redirect chain first
        guard let url = URL(string: trimmed), needsRedirectResolution(url) else {
            return nil
        }

        guard let resolved = await resolveRedirect(url: url) else { return nil }
        let resolvedString = resolved.absoluteString

        if let coord = parseDirectURL(resolvedString) {
            return coord
        }

        // Final fallback: geocode the place name from the ?q= param
        if let coord = await geocodeQueryParam(resolvedString) {
            return coord
        }

        return nil
    }

    // MARK: - Private

    private static func needsRedirectResolution(_ url: URL) -> Bool {
        let host = url.host ?? ""
        return host.contains("goo.gl") ||
               host.contains("link.maps.apple.com") ||
               host.contains("maps.apple.com") && (url.query?.isEmpty ?? true)
    }

    /// Follows up to 5 redirects and returns the final URL.
    /// Uses a delegate to prevent URLSession auto-following redirects,
    /// so we always know the true final resolved URL.
    private static func resolveRedirect(url: URL) async -> URL? {
        let delegate = NoRedirectDelegate()
        let session = URLSession(
            configuration: {
                let cfg = URLSessionConfiguration.ephemeral
                cfg.timeoutIntervalForRequest = 8
                return cfg
            }(),
            delegate: delegate,
            delegateQueue: nil
        )

        var currentURL = url
        var hops = 0

        while hops < 5 {
            var request = URLRequest(url: currentURL)
            request.httpMethod = "HEAD"

            guard let (_, response) = try? await session.data(for: request),
                  let http = response as? HTTPURLResponse else {
                return nil
            }

            if http.statusCode == 200 {
                return currentURL
            }

            guard (300...399).contains(http.statusCode),
                  let location = http.value(forHTTPHeaderField: "Location"),
                  let next = URL(string: location) else {
                return nil
            }
            currentURL = next
            hops += 1
        }
        return nil
    }

    /// Attempts to extract a coordinate from a fully-resolved URL string.
    private static func parseDirectURL(_ urlString: String) -> Coordinate? {
        // --- Google Maps ---
        // data= section: !3d<lat>!4d<lng> — actual place pin coordinates, more accurate than viewport center
        if let coord = parseGoogleMapsData(urlString) {
            return coord
        }

        // Path pattern: .../@lat,lng,zoom... — viewport center, fallback
        // e.g. https://www.google.com/maps/@51.5074,-0.1278,15z
        if let coord = parseGoogleMapsAt(urlString) {
            return coord
        }

        // Google Maps query param: ?q=lat,lng
        if let coord = parseGoogleMapsQ(urlString) {
            return coord
        }

        // --- Apple Maps ---
        // Query param: ll=lat,lng
        // e.g. https://maps.apple.com/?ll=51.5074,-0.1278
        if let coord = parseAppleMapsLL(urlString) {
            return coord
        }

        return nil
    }

    // MARK: Google Maps data=!3d<lat>!4d<lng>

    /// Extracts place pin coordinates from the encoded data= segment of a Google Maps URL.
    /// These represent the actual location of the pin, not the camera viewport center.
    private static func parseGoogleMapsData(_ urlString: String) -> Coordinate? {
        let pattern = #"!3d(-?\d{1,3}(?:\.\d+)?)!4d(-?\d{1,3}(?:\.\d+)?)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: urlString,
                                           range: NSRange(urlString.startIndex..., in: urlString)),
              match.numberOfRanges == 3,
              let latRange = Range(match.range(at: 1), in: urlString),
              let lngRange = Range(match.range(at: 2), in: urlString),
              let lat = Double(urlString[latRange]),
              let lng = Double(urlString[lngRange]),
              isValidLatLng(lat, lng) else {
            return nil
        }
        return Coordinate(latitude: lat, longitude: lng)
    }

    // MARK: Google Maps @lat,lng

    private static func parseGoogleMapsAt(_ urlString: String) -> Coordinate? {
        // Match @<lat>,<lng> anywhere in the string
        let pattern = #"@(-?\d{1,3}(?:\.\d+)?),(-?\d{1,3}(?:\.\d+)?)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: urlString,
                                           range: NSRange(urlString.startIndex..., in: urlString)),
              match.numberOfRanges == 3,
              let latRange = Range(match.range(at: 1), in: urlString),
              let lngRange = Range(match.range(at: 2), in: urlString),
              let lat = Double(urlString[latRange]),
              let lng = Double(urlString[lngRange]),
              isValidLatLng(lat, lng) else {
            return nil
        }
        return Coordinate(latitude: lat, longitude: lng)
    }

    // MARK: Google Maps ?q=lat,lng

    private static func parseGoogleMapsQ(_ urlString: String) -> Coordinate? {
        guard let components = URLComponents(string: urlString),
              let q = components.queryItems?.first(where: { $0.name == "q" })?.value else {
            return nil
        }
        return parseLatLngPair(q)
    }

    // MARK: Apple Maps ll=lat,lng or center=lat,lng

    private static func parseAppleMapsLL(_ urlString: String) -> Coordinate? {
        guard let components = URLComponents(string: urlString),
              let value = (components.queryItems?.first(where: { $0.name == "ll" })
                        ?? components.queryItems?.first(where: { $0.name == "center" }))?.value else {
            return nil
        }
        return parseLatLngPair(value)
    }

    // MARK: Helpers

    /// Parses a "lat,lng" pair string.
    private static func parseLatLngPair(_ value: String) -> Coordinate? {
        let parts = value.split(separator: ",", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2,
              let lat = Double(parts[0]),
              let lng = Double(parts[1]),
              isValidLatLng(lat, lng) else {
            return nil
        }
        return Coordinate(latitude: lat, longitude: lng)
    }

    // MARK: Geocoding fallback

    /// Geocodes the place name from a ?q= query parameter when no coordinates are embedded in the URL.
    /// Handles Google Maps URLs like: maps.google.com/maps?q=Stonehenge,+Salisbury+SP4+7DE
    private static func geocodeQueryParam(_ urlString: String) async -> Coordinate? {
        guard let components = URLComponents(string: urlString),
              let q = components.queryItems?.first(where: { $0.name == "q" })?.value,
              !q.isEmpty else {
            return nil
        }

        // Skip if q looks like a lat,lng pair — already handled by parseGoogleMapsQ
        if parseLatLngPair(q) != nil { return nil }

        return await withCheckedContinuation { continuation in
            CLGeocoder().geocodeAddressString(q) { placemarks, _ in
                guard let loc = placemarks?.first?.location else {
                    continuation.resume(returning: nil)
                    return
                }
                let coord = Coordinate(latitude: loc.coordinate.latitude,
                                       longitude: loc.coordinate.longitude)
                continuation.resume(returning: coord)
            }
        }
    }

    private static func isValidLatLng(_ lat: Double, _ lng: Double) -> Bool {
        lat >= -90 && lat <= 90 && lng >= -180 && lng <= 180
    }
}

// MARK: - NoRedirectDelegate

/// Prevents URLSession from auto-following redirects so we can track the final URL ourselves.
private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        // Return nil to block the automatic redirect — we handle it manually.
        completionHandler(nil)
    }
}
