#!/usr/bin/env python3
# gate-instrument: none - called only by scripts/time_zone_boundaries/build.sh to encode boundary data; it checks nothing about the server.
"""Encode simplified time-zone boundaries into the app's compact binary.

Task 11.331. Input: a GeoJSON FeatureCollection whose features carry a `tzid`
property (timezone-boundary-builder's output, simplified by `build.sh`).
Output: the file `lib/core/time/time_zone_boundaries.dart` reads.

Format, all integers unsigned LEB128 varints unless marked zigzag:

    "TTZB"  magic, 4 bytes
    1       format version, 1 byte
    n       number of zone names, then each: byte length, UTF-8 bytes
    p       number of polygons, then each:
              zone index
              bbox: min lon, min lat, max lon, max lat   (zigzag, 1e-4 degree)
              byte length of the rest of this polygon
              ring count, then each ring:
                point count, then points as (dlon, dlat) deltas from the
                previous point (zigzag, 1e-4 degree), the first from (0, 0)

Coordinates are rounded to 1e-4 degree (about 11 m), finer than the 100 m
simplification, so rounding adds nothing a reader could notice. A ring's
closing point (equal to its first) is dropped; the reader closes every ring.

Usage: encode.py <simplified.geojson> <out.bin>
"""
import json
import sys

SCALE = 10000


def main(src, dst):
    with open(src) as f:
        data = json.load(f)
    names = sorted({f['properties']['tzid'] for f in data['features']})
    index = {name: i for i, name in enumerate(names)}
    out = bytearray()

    def varint(v, buf):
        if v < 0:
            raise ValueError('negative varint')
        while True:
            b = v & 0x7F
            v >>= 7
            if v:
                buf.append(b | 0x80)
            else:
                buf.append(b)
                return

    def zz(v):
        return (v << 1) ^ (v >> 63)

    polygons = []
    for feature in data['features']:
        geometry = feature['geometry']
        zone = index[feature['properties']['tzid']]
        if geometry['type'] == 'Polygon':
            parts = [geometry['coordinates']]
        elif geometry['type'] == 'MultiPolygon':
            parts = geometry['coordinates']
        else:
            raise ValueError('unexpected geometry ' + geometry['type'])
        for part in parts:
            polygons.append((zone, part))

    out += b'TTZB'
    out.append(1)
    varint(len(names), out)
    for name in names:
        raw = name.encode('utf-8')
        varint(len(raw), out)
        out += raw
    varint(len(polygons), out)
    points = 0
    for zone, polygon in polygons:
        rings = []
        for ring in polygon:
            pts = [(round(x * SCALE), round(y * SCALE)) for x, y in ring]
            if len(pts) > 1 and pts[0] == pts[-1]:
                pts = pts[:-1]
            if len(pts) >= 3:
                rings.append(pts)
        if not rings:
            continue
        xs = [x for r in rings for x, _ in r]
        ys = [y for r in rings for _, y in r]
        body = bytearray()
        varint(len(rings), body)
        for ring in rings:
            varint(len(ring), body)
            points += len(ring)
            px = py = 0
            for x, y in ring:
                varint(zz(x - px), body)
                varint(zz(y - py), body)
                px, py = x, y
        varint(zone, out)
        for v in (min(xs), min(ys), max(xs), max(ys)):
            varint(zz(v), out)
        varint(len(body), out)
        out += body
    with open(dst, 'wb') as f:
        f.write(out)
    print(f'{len(names)} zones, {len(polygons)} polygons, {points} points, '
          f'{len(out)} bytes')


if __name__ == '__main__':
    main(sys.argv[1], sys.argv[2])
