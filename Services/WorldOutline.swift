//
//  WorldOutline.swift
//  QuiteListie
//
//  The coastline drawn behind and around the EPSG:27700 sheet, so the map has a
//  world to sit in rather than a flat colour.
//
//  The geometry ships as WGS84 lon/lat (see WorldOutlineData.swift) and is
//  projected here, once, through the same BNGProjection the rest of the map
//  uses. Storing pre-projected metres would have been marginally faster to load
//  and would have quietly forked the projection: a change to BNGProjection would
//  no longer move the coastline with everything else.
//
//  Accuracy is decorative, and that is fine here. Redfearn's series drifts as you
//  leave the 2°W central meridian — by a few kilometres out at the western edge
//  of this data — but you can only see that far west when zoomed out to roughly
//  2 km per point, where the error is a point or two. Zoom in and the visible
//  surround is close to the sheet, where the projection is accurate. The error
//  shrinks exactly as fast as the zoom that would reveal it.
//

import CoreGraphics
import Foundation

enum WorldOutline {

    /// One closed coastline ring in BNG metres, with its bounding box so the
    /// renderer can skip rings nowhere near the viewport.
    struct Ring {
        let points: [(e: Double, n: Double)]
        let bounds: CGRect
    }

    /// Projected rings, built on first use and kept for the process lifetime.
    /// ~3,300 points, so the whole projection pass is well under a millisecond.
    static let rings: [Ring] = decode()

    private static func decode() -> [Ring] {
        guard let data = Data(base64Encoded: WorldOutlineData.base64,
                              options: .ignoreUnknownCharacters) else {
            assertionFailure("WorldOutlineData is not valid base64")
            return []
        }

        return data.withUnsafeBytes { raw -> [Ring] in
            var offset = 0

            func read<T>(_ type: T.Type) -> T? {
                guard offset + MemoryLayout<T>.size <= raw.count else { return nil }
                defer { offset += MemoryLayout<T>.size }
                return raw.loadUnaligned(fromByteOffset: offset, as: T.self)
            }

            guard let ringCount = read(UInt32.self) else { return [] }

            var rings: [Ring] = []
            rings.reserveCapacity(Int(ringCount))

            for _ in 0..<ringCount {
                guard let pointCount = read(UInt32.self) else { break }

                var points: [(e: Double, n: Double)] = []
                points.reserveCapacity(Int(pointCount))
                var minE = Double.greatestFiniteMagnitude, minN = Double.greatestFiniteMagnitude
                var maxE = -Double.greatestFiniteMagnitude, maxN = -Double.greatestFiniteMagnitude

                for _ in 0..<pointCount {
                    guard let lon = read(Float.self), let lat = read(Float.self) else { break }
                    let p = BNGProjection.wgs84ToBNG(lat: Double(lat), lon: Double(lon))
                    points.append(p)
                    minE = min(minE, p.e); maxE = max(maxE, p.e)
                    minN = min(minN, p.n); maxN = max(maxN, p.n)
                }

                guard points.count >= 3 else { continue }
                rings.append(Ring(points: points,
                                  bounds: CGRect(x: minE, y: minN,
                                                 width: maxE - minE, height: maxN - minN)))
            }
            return rings
        }
    }
}
