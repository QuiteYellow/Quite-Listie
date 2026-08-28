#!/usr/bin/env python3
"""Regenerate Services/WorldOutlineData.swift — the coastline drawn behind and
around the EPSG:27700 sheet.

    python3 Tools/generate-world-outline.py

Source: Natural Earth 1:50m land polygons, via martynafford/natural-earth-geojson
(CC0). Natural Earth itself is public domain: "No permission is needed to use
Natural Earth. Crediting the authors is unnecessary."

The blob stores WGS84 lon/lat, not projected coordinates, so BNGProjection stays
the single source of truth for the projection — the app projects once at load.

Crop window: the furthest the viewport can ever reach. clampCenter pins the map
centre to sheetBounds and maxRes fits the sheet + 10%, so the worst case is a
corner centre at full zoom-out — roughly 420 km past the E/W edges and 915 km
past N/S, which lands inside the box below with room to spare.
"""
import base64, json, math, struct, urllib.request
from pathlib import Path

SOURCE = ("https://raw.githubusercontent.com/martynafford/natural-earth-geojson"
          "/master/50m/physical/ne_50m_land.json")
# lon_lo, lon_hi, lat_lo, lat_hi.
#
# This has to contain the whole lon/lat *preimage* of the reachable BNG box, and
# that preimage is not a lon/lat rectangle: away from the 2°W central meridian
# the meridians tilt, so a lon/lat box projects to a slanted quad and its corners
# get sliced off. Cropping to a box that merely looked generous put a visible
# diagonal cut through Scandinavia and the North Sea.
#
# How far the viewport reaches depends on the window's aspect ratio, and not
# gently: maxRes fits the whole sheet, so on a wide window it binds on the
# sheet's *height* and leaves enormous horizontal slack. Sweeping aspect ratios
# from 0.35 to 3.2 and walking each reachable BNG box back through
# BNGProjection.bngToWgs84 asks for lon -45.3...41.1.
#
# We cannot supply that, and the limit is not the data — it is the projection.
# Redfearn's series is a truncated polynomial in the offset from the 2°W central
# meridian, and it comes apart as that offset grows. Round-tripping lon -> BNG ->
# lon at 55N: 10 m of error at 20°, 0.6 km at 30°, 17 km at 40°, 309 km at 50°.
# Past roughly 30° off the meridian the coastline would not be in the right place
# in any meaningful sense, so there is nothing worth drawing out there.
#
# So the crop is set to the projection's usable range rather than the viewport's
# reach. That fully covers windows up to about 1.25:1; wider ones can still push
# the western cut edge into view. Fixing *that* means bounding how far the map
# zooms out (maxRes in BNGMapView), not shipping more coastline.
CLIP = (-33.0, 28.0, 36.0, 75.0)
# Reach at a 1.25:1 window — the widest CLIP fully covers. CLIP must contain it.
REQUIRED = (-32.1, 24.9, 40.6, 68.1)
# Douglas-Peucker tolerance, degrees-ish (converted per-ring from metres below).
TOLERANCE_M = 600.0
OUT = Path(__file__).resolve().parent.parent / "Services" / "WorldOutlineData.swift"


def clip_ring(ring):
    """Sutherland-Hodgman against CLIP. The clip box is convex, so this is exact.

    Dropping out-of-window points instead would close a continental ring with a
    chord straight across the map.
    """
    lo_x, hi_x, lo_y, hi_y = CLIP
    edges = [(lambda p: p[0] >= lo_x, 0, lo_x), (lambda p: p[0] <= hi_x, 0, hi_x),
             (lambda p: p[1] >= lo_y, 1, lo_y), (lambda p: p[1] <= hi_y, 1, hi_y)]
    out = list(ring)
    for inside, axis, bound in edges:
        if not out:
            return []
        src, out = out, []
        for i, cur in enumerate(src):
            prev = src[i - 1]
            ci, pi = inside(cur), inside(prev)
            if ci != pi:
                d = cur[axis] - prev[axis]
                t = 0.0 if d == 0 else (bound - prev[axis]) / d
                other = 1 - axis
                pt = [0.0, 0.0]
                pt[axis] = bound
                pt[other] = prev[other] + t * (cur[other] - prev[other])
                out.append(pt)
            if ci:
                out.append(cur)
    return out


def simplify(pts, tol):
    """Douglas-Peucker over a closed ring."""
    if len(pts) < 4:
        return pts
    keep = [False] * len(pts)
    keep[0] = keep[-1] = True
    # pts[0] == pts[-1] on a closed ring, so the first anchor segment is
    # degenerate and every point measures zero distance from it. Seed a third
    # anchor halfway round to get two real segments to recurse into.
    mid = len(pts) // 2
    keep[mid] = True
    stack = [(0, mid), (mid, len(pts) - 1)]
    while stack:
        lo, hi = stack.pop()
        if hi <= lo + 1:
            continue
        ax, ay = pts[lo]
        bx, by = pts[hi]
        dx, dy = bx - ax, by - ay
        norm = math.hypot(dx, dy) or 1e-12
        far, fd = -1, tol
        for i in range(lo + 1, hi):
            px, py = pts[i]
            d = abs(dy * px - dx * py + bx * ay - by * ax) / norm
            if d > fd:
                far, fd = i, d
        if far > 0:
            keep[far] = True
            stack += [(lo, far), (far, hi)]
    return [p for p, k in zip(pts, keep) if k]


def main():
    assert (CLIP[0] < REQUIRED[0] and CLIP[1] > REQUIRED[1]
            and CLIP[2] < REQUIRED[2] and CLIP[3] > REQUIRED[3]), \
        f"CLIP {CLIP} does not contain the reachable window {REQUIRED}"
    print(f"fetching {SOURCE}")
    with urllib.request.urlopen(SOURCE) as r:
        data = json.load(r)

    rings = []
    for feat in data["features"]:
        geom = feat["geometry"]
        polys = (geom["coordinates"] if geom["type"] == "MultiPolygon"
                 else [geom["coordinates"]])
        for poly in polys:
            for ring in poly:
                lons = [p[0] for p in ring]
                lats = [p[1] for p in ring]
                if max(lons) < CLIP[0] or min(lons) > CLIP[1]:
                    continue
                if max(lats) < CLIP[2] or min(lats) > CLIP[3]:
                    continue
                clipped = clip_ring(ring)
                if len(clipped) < 4:
                    continue
                # Tolerance in degrees at this ring's latitude: longitude
                # degrees shrink towards the poles, so a fixed degree tolerance
                # would over-simplify Norway and under-simplify Iberia.
                lat_mid = sum(p[1] for p in clipped) / len(clipped)
                deg = TOLERANCE_M / (111_320.0 * max(0.2, math.cos(math.radians(lat_mid))))
                s = simplify(clipped, deg)
                if len(s) >= 4:
                    rings.append(s)

    blob = struct.pack("<I", len(rings))
    total = 0
    for r in rings:
        blob += struct.pack("<I", len(r))
        for lon, lat in r:
            blob += struct.pack("<ff", lon, lat)
        total += len(r)

    b64 = base64.b64encode(blob).decode()
    lines = "\n".join(b64[i:i + 76] for i in range(0, len(b64), 76))

    OUT.write_text(f'''//
//  WorldOutlineData.swift
//  QuiteListie
//
//  GENERATED — do not edit. Run Tools/generate-world-outline.py to rebuild.
//
//  Natural Earth 1:50m land, cropped to the window the EPSG:27700 viewport can
//  reach and simplified to ~{TOLERANCE_M:.0f} m. Public domain (Natural Earth), obtained via
//  martynafford/natural-earth-geojson (CC0). No attribution required.
//
//  Layout, little-endian: UInt32 ring count, then per ring a UInt32 point count
//  followed by that many (Float32 lon, Float32 lat) pairs, in WGS84 degrees.
//  See WorldOutline.swift for the decoder.
//
//  {len(rings)} rings, {total} points.
//

enum WorldOutlineData {{
    static let base64 = """
{lines}
"""
}}
''')
    print(f"{len(rings)} rings, {total} points, {len(blob)} bytes "
          f"({len(b64)} base64) -> {OUT.relative_to(OUT.parent.parent)}")


if __name__ == "__main__":
    main()
