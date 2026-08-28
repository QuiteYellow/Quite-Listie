import Foundation

// Transverse Mercator + WGS84 <-> OSGB36 Helmert 7-parameter datum shift.
// Parameters are those published for EPSG:27700 (British National Grid).
// Accuracy: ~5m across GB (approximate Helmert). For sub-metre accuracy, replace
// the Helmert step with OSTN15 grid interpolation.
enum BNGProjection {
    // Airy 1830 ellipsoid (OSGB36).
    private static let airyA = 6377563.396
    private static let airyB = 6356256.909
    // WGS84 ellipsoid.
    private static let wgsA = 6378137.0
    private static let wgsB = 6356752.3142

    // Transverse Mercator parameters for the National Grid.
    private static let phi0 = 49.0 * .pi / 180.0
    private static let lam0 = -2.0 * .pi / 180.0
    private static let F0 = 0.9996012717
    private static let E0 = 400_000.0
    private static let N0 = -100_000.0

    // Helmert 7-parameter WGS84 -> OSGB36 (approximate).
    private static let tx = -446.448
    private static let ty = 125.157
    private static let tz = -542.06
    private static let sPPM: Double = 20.4894e-6
    private static let rx = -0.1502 * .pi / (180.0 * 3600.0)
    private static let ry = -0.2470 * .pi / (180.0 * 3600.0)
    private static let rz = -0.8421 * .pi / (180.0 * 3600.0)

    /// Rough test that a WGS84 coordinate lies in Great Britain (England,
    /// Scotland, Wales — what EPSG:27700 covers), excluding Northern Ireland,
    /// which uses the Irish Grid. Bounding boxes only — good enough to decide
    /// whether to show a "these layers won't cover you" hint, nothing more.
    static func isLikelyInGreatBritain(lat: Double, lon: Double) -> Bool {
        guard (49.8...61.0).contains(lat), (-8.65...1.80).contains(lon) else { return false }
        // Carve out the island of Ireland — NI *and* the Republic both fall
        // inside the outer box. Latitude tops out at 55.3 so the Mull of
        // Kintyre (55.31) stays in; Donegal's far north slips through, which
        // is fine for a hint.
        let inIreland = (51.3...55.3).contains(lat) && (-8.65 ... -5.35).contains(lon)
        return !inIreland
    }

    /// WGS84 lat/lon (degrees) -> BNG easting/northing (metres).
    static func wgs84ToBNG(lat: Double, lon: Double) -> (e: Double, n: Double) {
        let phi = lat * .pi / 180.0
        let lam = lon * .pi / 180.0
        let osgb = helmert(phi: phi, lam: lam,
                           srcA: wgsA, srcB: wgsB,
                           tx: tx, ty: ty, tz: tz, s: sPPM, rx: rx, ry: ry, rz: rz,
                           dstA: airyA, dstB: airyB)
        return latLonToBNG(lat: osgb.lat, lon: osgb.lon)
    }

    /// BNG easting/northing (metres) -> WGS84 lat/lon (degrees).
    static func bngToWgs84(e: Double, n: Double) -> (lat: Double, lon: Double) {
        let osgb = bngToLatLon(e: e, n: n)
        // Inverse Helmert via negated parameters (small-angle linearisation).
        let wgs = helmert(phi: osgb.lat, lam: osgb.lon,
                          srcA: airyA, srcB: airyB,
                          tx: -tx, ty: -ty, tz: -tz, s: -sPPM, rx: -rx, ry: -ry, rz: -rz,
                          dstA: wgsA, dstB: wgsB)
        return (wgs.lat * 180 / .pi, wgs.lon * 180 / .pi)
    }

    // 7-parameter Helmert via geocentric XYZ. h assumed 0 (surface-only).
    private static func helmert(phi: Double, lam: Double,
                                srcA: Double, srcB: Double,
                                tx: Double, ty: Double, tz: Double, s: Double,
                                rx: Double, ry: Double, rz: Double,
                                dstA: Double, dstB: Double)
        -> (lat: Double, lon: Double)
    {
        let e2s = 1 - (srcB * srcB) / (srcA * srcA)
        let nu = srcA / sqrt(1 - e2s * sin(phi) * sin(phi))
        let x = nu * cos(phi) * cos(lam)
        let y = nu * cos(phi) * sin(lam)
        let z = (1 - e2s) * nu * sin(phi)

        let x2 = tx + (1 + s) * x - rz * y + ry * z
        let y2 = ty + rz * x + (1 + s) * y - rx * z
        let z2 = tz - ry * x + rx * y + (1 + s) * z

        let e2d = 1 - (dstB * dstB) / (dstA * dstA)
        let p = sqrt(x2 * x2 + y2 * y2)
        var lat = atan2(z2, p * (1 - e2d))
        for _ in 0..<6 {
            let nu2 = dstA / sqrt(1 - e2d * sin(lat) * sin(lat))
            lat = atan2(z2 + e2d * nu2 * sin(lat), p)
        }
        let lon = atan2(y2, x2)
        return (lat, lon)
    }

    // OSGB36 lat/lon (radians) -> BNG easting/northing (metres).
    private static func latLonToBNG(lat: Double, lon: Double) -> (e: Double, n: Double) {
        let a = airyA, b = airyB
        let e2 = 1 - (b * b) / (a * a)
        let nCoef = (a - b) / (a + b)
        let sp = sin(lat), cp = cos(lat), tp = sp / cp
        let nu = a * F0 / sqrt(1 - e2 * sp * sp)
        let rho = a * F0 * (1 - e2) / pow(1 - e2 * sp * sp, 1.5)
        let eta2 = nu / rho - 1

        let Ma = (1 + nCoef + 1.25*nCoef*nCoef + 1.25*nCoef*nCoef*nCoef) * (lat - phi0)
        let Mb = (3*nCoef + 3*nCoef*nCoef + 2.625*nCoef*nCoef*nCoef) * sin(lat - phi0) * cos(lat + phi0)
        let Mc = (1.875*nCoef*nCoef + 1.875*nCoef*nCoef*nCoef) * sin(2*(lat - phi0)) * cos(2*(lat + phi0))
        let Md = (35.0/24.0)*nCoef*nCoef*nCoef * sin(3*(lat - phi0)) * cos(3*(lat + phi0))
        let M = b * F0 * (Ma - Mb + Mc - Md)

        let I = M + N0
        let II = nu/2 * sp * cp
        let III = nu/24 * sp * pow(cp, 3) * (5 - tp*tp + 9*eta2)
        let IIIA = nu/720 * sp * pow(cp, 5) * (61 - 58*tp*tp + pow(tp, 4))
        let IV = nu * cp
        let V = nu/6 * pow(cp, 3) * (nu/rho - tp*tp)
        let VI = nu/120 * pow(cp, 5) * (5 - 18*tp*tp + pow(tp, 4) + 14*eta2 - 58*tp*tp*eta2)

        let d = lon - lam0
        let N = I + II*d*d + III*pow(d, 4) + IIIA*pow(d, 6)
        let E = E0 + IV*d + V*pow(d, 3) + VI*pow(d, 5)
        return (E, N)
    }

    // BNG easting/northing (metres) -> OSGB36 lat/lon (radians).
    private static func bngToLatLon(e: Double, n: Double) -> (lat: Double, lon: Double) {
        let a = airyA, b = airyB
        let e2 = 1 - (b * b) / (a * a)
        let nCoef = (a - b) / (a + b)

        var phi = (n - N0) / (a * F0) + phi0
        var M = 0.0
        var iters = 0
        repeat {
            let Ma = (1 + nCoef + 1.25*nCoef*nCoef + 1.25*nCoef*nCoef*nCoef) * (phi - phi0)
            let Mb = (3*nCoef + 3*nCoef*nCoef + 2.625*nCoef*nCoef*nCoef) * sin(phi - phi0) * cos(phi + phi0)
            let Mc = (1.875*nCoef*nCoef + 1.875*nCoef*nCoef*nCoef) * sin(2*(phi - phi0)) * cos(2*(phi + phi0))
            let Md = (35.0/24.0)*nCoef*nCoef*nCoef * sin(3*(phi - phi0)) * cos(3*(phi + phi0))
            M = b * F0 * (Ma - Mb + Mc - Md)
            phi = (n - N0 - M) / (a * F0) + phi
            iters += 1
        } while abs(n - N0 - M) >= 1e-5 && iters < 20

        let sp = sin(phi), cp = cos(phi), tp = sp / cp
        let nu = a * F0 / sqrt(1 - e2 * sp * sp)
        let rho = a * F0 * (1 - e2) / pow(1 - e2 * sp * sp, 1.5)
        let eta2 = nu / rho - 1

        let VII = tp / (2 * rho * nu)
        let VIII = tp / (24 * rho * pow(nu, 3)) * (5 + 3*tp*tp + eta2 - 9*tp*tp*eta2)
        let IX = tp / (720 * rho * pow(nu, 5)) * (61 + 90*tp*tp + 45*pow(tp, 4))
        let X = 1 / (cp * nu)
        let XI = 1 / (6 * cp * pow(nu, 3)) * (nu/rho + 2*tp*tp)
        let XII = 1 / (120 * cp * pow(nu, 5)) * (5 + 28*tp*tp + 24*pow(tp, 4))
        let XIIA = 1 / (5040 * cp * pow(nu, 7)) * (61 + 662*tp*tp + 1320*pow(tp, 4) + 720*pow(tp, 6))

        let d = e - E0
        let lat = phi - VII*d*d + VIII*pow(d, 4) - IX*pow(d, 6)
        let lon = lam0 + X*d - XI*pow(d, 3) + XII*pow(d, 5) - XIIA*pow(d, 7)
        return (lat, lon)
    }
}
