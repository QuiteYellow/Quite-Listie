//
//  LocationParser.swift
//  QuiteListie
//
//  Parses Google Maps and Apple Maps share URLs into coordinates.
//  Follows short-URL redirects asynchronously before parsing.
//

import CoreLocation
import Foundation
import MapKit
import os

enum LocationParser {

    /// Parses a URL string (from clipboard) into a `Coordinate`.
    /// Follows redirects for short URLs (e.g. maps.app.goo.gl) before parsing.
    /// Falls back to geocoding when the resolved URL contains only a place name query.
    static func parseCoordinate(from urlString: String) async -> Coordinate? {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)

        let log = AppLogger.location

        // Try parsing immediately first — handles most full URLs
        if let coord = parseDirectURL(trimmed) {
            log.debug("parseCoordinate: direct parse succeeded")
            return coord
        }

        // Direct Google Maps place URL with no embedded coordinates — geocode the place name
        if let coord = await geocodePlaceFromGoogleMapsPath(trimmed) {
            log.debug("parseCoordinate: place-name geocode succeeded (direct)")
            return coord
        }

        // For short / redirect URLs, resolve the redirect chain first
        guard let url = URL(string: trimmed) else {
            log.warning("parseCoordinate: could not construct URL from input")
            return nil
        }
        guard needsRedirectResolution(url) else {
            log.debug("parseCoordinate: no redirect needed and no match — giving up (host: \(url.host ?? "nil", privacy: .public))")
            return nil
        }

        log.debug("parseCoordinate: resolving redirect for \(trimmed, privacy: .public)")
        guard let resolved = await resolveRedirect(url: url) else {
            log.warning("parseCoordinate: redirect resolution failed")
            return nil
        }
        // If Google redirected to a consent page, the real Maps URL is in the `continue` param
        let effectiveURL = googleConsentContinueURL(resolved) ?? resolved
        let resolvedString = effectiveURL.absoluteString
        log.debug("parseCoordinate: resolved to \(resolvedString, privacy: .public)")

        if let coord = parseDirectURL(resolvedString) {
            log.debug("parseCoordinate: direct parse succeeded after redirect")
            return coord
        }

        // Fallback: geocode the place name from the ?q= param
        if let coord = await geocodeQueryParam(resolvedString) {
            log.debug("parseCoordinate: q-param geocode succeeded after redirect")
            return coord
        }

        // Fallback: geocode from Google Maps place name in path
        if let coord = await geocodePlaceFromGoogleMapsPath(resolvedString) {
            log.debug("parseCoordinate: place-name geocode succeeded after redirect")
            return coord
        }

        log.warning("parseCoordinate: all strategies exhausted")
        return nil
    }

    // MARK: - Private

    private static func needsRedirectResolution(_ url: URL) -> Bool {
        let host = url.host ?? ""
        return host.contains("goo.gl") ||
               host.contains("link.maps.apple.com") ||
               host == "maps.apple" ||
               host.contains("maps.apple.com") && (url.query?.isEmpty ?? true)
    }

    /// Follows the redirect chain and returns the final URL.
    /// Lets URLSession handle redirects automatically; the final URL is read from the response.
    private static func resolveRedirect(url: URL) async -> URL? {
        var request = URLRequest(url: url)
        request.setValue(
            "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1",
            forHTTPHeaderField: "User-Agent"
        )

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        let session = URLSession(configuration: config)

        do {
            let (_, response) = try await session.data(for: request)
            guard let finalURL = response.url else {
                AppLogger.location.warning("resolveRedirect: response.url was nil for \(url, privacy: .public)")
                return nil
            }
            AppLogger.location.debug("resolveRedirect: \(url.host ?? "", privacy: .public) → \(finalURL.absoluteString, privacy: .public)")
            return finalURL
        } catch {
            AppLogger.location.warning("resolveRedirect: request failed — \(error.localizedDescription, privacy: .public)")
            return nil
        }
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

    // MARK: Google consent page unwrapping

    /// When Google redirects through consent.google.com, the real destination is in the `continue` param.
    private static func googleConsentContinueURL(_ url: URL) -> URL? {
        guard url.host?.contains("consent.google.com") == true,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let continueValue = components.queryItems?.first(where: { $0.name == "continue" })?.value,
              let continueURL = URL(string: continueValue) else {
            return nil
        }
        return continueURL
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
              lat != 0 || lng != 0, // Skip @0,0 placeholder used when only a CID is embedded
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

    // MARK: Apple Maps ll=, center=, or coordinate= param

    private static func parseAppleMapsLL(_ urlString: String) -> Coordinate? {
        guard let components = URLComponents(string: urlString),
              let value = (components.queryItems?.first(where: { $0.name == "ll" })
                        ?? components.queryItems?.first(where: { $0.name == "center" })
                        ?? components.queryItems?.first(where: { $0.name == "coordinate" }))?.value else {
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

    // MARK: Google Maps place-name geocoding

    /// Geocodes the place name embedded in a Google Maps `/place/PLACE_NAME/` URL path.
    /// Used when the URL contains only a CID (e.g. `@0,0,22z`) with no real coordinates.
    /// Tries the full name first, then progressively shorter suffixes (after each comma)
    /// so that "Short Stay Car Pk, Bristol BS48 3DY" falls back to "Bristol BS48 3DY".
    private static func geocodePlaceFromGoogleMapsPath(_ urlString: String) async -> Coordinate? {
        guard let url = URL(string: urlString),
              url.host?.contains("google.com") == true else { return nil }

        let components = url.pathComponents
        guard let placeIdx = components.firstIndex(of: "place"),
              placeIdx + 1 < components.count else { return nil }

        let rawName = (components[placeIdx + 1]
            .removingPercentEncoding ?? components[placeIdx + 1])
            .replacingOccurrences(of: "+", with: " ")
        guard !rawName.isEmpty, rawName != "@" else { return nil }

        return await geocodeWithFallback(rawName)
    }

    /// Geocodes a place name string, trying progressively shorter comma-delimited suffixes
    /// so that e.g. "Short Stay Car Pk, Bristol BS48 3DY" falls back to "Bristol BS48 3DY".
    private static func geocodeWithFallback(_ name: String) async -> Coordinate? {
        var candidates: [String] = [name]
        let parts = name.components(separatedBy: ",")
        for i in 1..<parts.count {
            let suffix = parts[i...].joined(separator: ",").trimmingCharacters(in: .whitespaces)
            if !suffix.isEmpty { candidates.append(suffix) }
        }
        for candidate in candidates {
            if let coord = await geocodeString(candidate) { return coord }
        }
        return nil
    }

    private static func geocodeString(_ query: String) async -> Coordinate? {
        guard let request = MKGeocodingRequest(addressString: query) else { return nil }
        do {
            let items = try await request.mapItems
            guard let loc = items.first?.location else { return nil }
            return Coordinate(latitude: loc.coordinate.latitude, longitude: loc.coordinate.longitude)
        } catch {
            AppLogger.location.warning("geocodeString('\(query)') failed: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: Geocoding fallback

    /// Geocodes the place name from a ?q= query parameter when no coordinates are embedded in the URL.
    /// Handles Google Maps URLs like: maps.google.com/maps?q=Stonehenge,+Salisbury+SP4+7DE
    private static func geocodeQueryParam(_ urlString: String) async -> Coordinate? {
        guard let components = URLComponents(string: urlString),
              let rawQ = components.queryItems?.first(where: { $0.name == "q" })?.value,
              !rawQ.isEmpty else {
            return nil
        }

        // URLComponents doesn't decode + as space (form-encoding); do it manually
        let q = rawQ.replacingOccurrences(of: "+", with: " ")

        // Skip if q looks like a lat,lng pair — already handled by parseGoogleMapsQ
        if parseLatLngPair(q) != nil { return nil }

        return await geocodeWithFallback(q)
    }

    private static func isValidLatLng(_ lat: Double, _ lng: Double) -> Bool {
        lat >= -90 && lat <= 90 && lng >= -180 && lng <= 180
    }
}

