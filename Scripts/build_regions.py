# /// script
# requires-python = ">=3.11"
# dependencies = ["numpy", "rasterio", "pyshp", "scipy", "shapely"]
# ///
"""Build the continent and country masks used to lock rounds to a region.

Usage: uv run Scripts/build_regions.py <ne_10m_admin_0_countries.shp> <data_dir>

Reads pop_L1.pack (3', 7200 x 3600) from data_dir for population totals and writes:
  continents.mask / countries.mask  raw-deflate uint8 7200 x 3600, 0 = none, else entry id
  continents.json / countries.json  entries with id, name, population total (and camera bounds for countries)
  continents.outline / countries.outline  vector borders for drawing the region on the map, see write_outline
"""
import json
import struct
import sys
import zlib
from pathlib import Path

import numpy as np
import shapefile
from rasterio import features
from rasterio.transform import from_origin
from scipy import ndimage
from shapely.geometry import Polygon, shape
from shapely.ops import unary_union

CONTINENTS = ["Africa", "Asia", "Europe", "North America", "Oceania", "South America"]
# (Natural Earth ADM0_A3, display name, ISO 3166 alpha-2 for the flag)
COUNTRIES = [
    ("IND", "India", "IN"), ("CHN", "China", "CN"), ("USA", "United States", "US"),
    ("RUS", "Russia", "RU"), ("IDN", "Indonesia", "ID"), ("PAK", "Pakistan", "PK"),
    ("NGA", "Nigeria", "NG"), ("BRA", "Brazil", "BR"), ("BGD", "Bangladesh", "BD"),
    ("MEX", "Mexico", "MX"), ("JPN", "Japan", "JP"), ("PHL", "Philippines", "PH"),
    ("EGY", "Egypt", "EG"), ("IRN", "Iran", "IR"), ("TUR", "Turkey", "TR"),
    ("DEU", "Germany", "DE"), ("THA", "Thailand", "TH"), ("GBR", "United Kingdom", "GB"),
    ("FRA", "France", "FR"), ("ITA", "Italy", "IT"), ("ZAF", "South Africa", "ZA"),
    ("KOR", "South Korea", "KR"), ("ESP", "Spain", "ES"), ("ARG", "Argentina", "AR"),
    ("CAN", "Canada", "CA"), ("AUS", "Australia", "AU"), ("SAU", "Saudi Arabia", "SA"),
    ("UKR", "Ukraine", "UA"), ("POL", "Poland", "PL"), ("NLD", "Netherlands", "NL"),
    ("NOR", "Norway", "NO"),
]
CELL = 0.05
COAST_FILL_CELLS = 10  # give coastal cells just outside the polygons to the nearest region
OUTLINE_TOLERANCE = 0.001  # degrees (~100 m), far below Natural Earth's own 1:10m accuracy
MIN_HOLE_AREA = 0.0005  # square degrees; drops slivers left between neighbours by the union


def read_pack(path):
    b = path.read_bytes()
    assert b[:4] == b"POPG"
    _, w, h, ts, tx, ty = struct.unpack_from("<6I", b, 4)
    out = np.zeros((ty * ts, tx * ts), np.float32)
    for i in range(tx * ty):
        off, length = struct.unpack_from("<QI", b, 52 + i * 12)
        if length:
            tile = np.frombuffer(zlib.decompress(b[off : off + length], -15), "<f4").reshape(ts, ts)
            r, c = divmod(i, tx)
            out[r * ts : (r + 1) * ts, c * ts : (c + 1) * ts] = tile
    return out[:h, :w]


def rasterize(shapes, shape, all_touched):
    mask = features.rasterize(shapes, out_shape=shape, transform=from_origin(-180, 90, CELL, CELL),
                              all_touched=all_touched, dtype="uint16")
    dist, (ri, ci) = ndimage.distance_transform_edt(mask == 0, return_indices=True)
    near = (mask == 0) & (dist <= COAST_FILL_CELLS)
    mask[near] = mask[ri[near], ci[near]]
    return mask


def bounds(pop, sel):
    """Camera box over the main land masses (each with 5%+ of the people), padded, so overseas
    territories and remote islands don't stretch it."""
    labels, n = ndimage.label(ndimage.binary_dilation(sel, iterations=2), structure=np.ones((3, 3)))
    labels = np.where(sel, labels, 0)
    sums = np.asarray(ndimage.sum(pop, labels, index=np.arange(1, n + 1)))
    sel = np.isin(labels, np.nonzero(sums >= 0.05 * sums.sum())[0] + 1)
    rows, cols = np.nonzero(sel)
    weights = pop[rows, cols].astype(np.float64)
    lats = 90 - (rows + 0.5) * CELL
    lons = -180 + (cols + 0.5) * CELL

    def q(v, p):
        order = np.argsort(v)
        cum = np.cumsum(weights[order])
        return float(v[order][np.searchsorted(cum, p * cum[-1])])

    lo_lat, hi_lat, lo_lon, hi_lon = q(lats, 0.005), q(lats, 0.995), q(lons, 0.005), q(lons, 0.995)
    pad_lat = max(1.5, (hi_lat - lo_lat) * 0.15)
    pad_lon = max(1.5, (hi_lon - lo_lon) * 0.15)
    return [round(max(-85, lo_lat - pad_lat), 2), round(min(85, hi_lat + pad_lat), 2),
            round(max(-180, lo_lon - pad_lon), 2), round(min(180, hi_lon + pad_lon), 2)]


def write(data_dir, name, mask, entries):
    c = zlib.compressobj(9, zlib.DEFLATED, -15)
    (data_dir / f"{name}.mask").write_bytes(c.compress(mask.astype(np.uint8).tobytes()) + c.flush())
    h, w = mask.shape
    (data_dir / f"{name}.json").write_text(json.dumps({"width": w, "height": h, "cellDeg": CELL, "entries": entries},
                                                      ensure_ascii=False))


def write_outline(data_dir, name, regions):
    """Raw-deflate little endian: u32 region count, then per region u32 id, u32 polygon count,
    per polygon u32 ring count (exterior first, then holes), per ring u32 point count and
    float32 (lon, lat) pairs without the closing point."""
    out = [struct.pack("<I", len(regions))]
    points = 0
    for rid, geoms in regions:
        geom = unary_union([shape(g) for g in geoms]).simplify(OUTLINE_TOLERANCE, preserve_topology=True)
        polys = [p for p in getattr(geom, "geoms", [geom]) if isinstance(p, Polygon) and not p.is_empty]
        out.append(struct.pack("<II", rid, len(polys)))
        for p in polys:
            rings = [p.exterior, *(r for r in p.interiors if Polygon(r).area >= MIN_HOLE_AREA)]
            out.append(struct.pack("<I", len(rings)))
            for ring in rings:
                xy = np.asarray(ring.coords, "<f4")[:-1]
                out.append(struct.pack("<I", len(xy)) + xy.tobytes())
                points += len(xy)
    c = zlib.compressobj(9, zlib.DEFLATED, -15)
    (data_dir / f"{name}.outline").write_bytes(c.compress(b"".join(out)) + c.flush())
    print(f"{name}.outline: {points} points")


def main(shp, data_dir):
    pop = read_pack(data_dir / "pop_L1.pack")
    reader = shapefile.Reader(str(shp), encoding="utf-8", encodingErrors="replace")
    fields = [f[0] for f in reader.fields[1:]]
    records = [(dict(zip(fields, sr.record)), sr.shape.__geo_interface__) for sr in reader.iterShapeRecords()]

    # Continents
    shapes = [(g, CONTINENTS.index(r["CONTINENT"]) + 1) for r, g in records if r["CONTINENT"] in CONTINENTS]
    mask = rasterize(shapes, pop.shape, all_touched=True)
    entries = []
    for i, name in enumerate(CONTINENTS, start=1):
        t = pop[mask == i].sum(dtype=np.float64)
        entries.append({"id": i, "name": name, "total": round(t)})
        print(f"{name}: {t / 1e6:.0f} M")
    write(data_dir, "continents", mask, entries)
    write_outline(data_dir, "continents",
                  [(i, [g for r, g in records if r["CONTINENT"] == name]) for i, name in enumerate(CONTINENTS, start=1)])

    # Countries: rasterize every country so coastal fill can't spill into unlisted neighbours,
    # then keep only the listed ones.
    codes = [r["ADM0_A3"] for r, _ in records]
    wanted = {a3: i + 1 for i, (a3, _, _) in enumerate(COUNTRIES)}
    missing = set(wanted) - set(codes)
    assert not missing, missing
    shapes = [(g, wanted.get(r["ADM0_A3"], 100 + k)) for k, (r, g) in enumerate(records)]
    full = rasterize(shapes, pop.shape, all_touched=False)
    mask = np.where(full <= len(COUNTRIES), full, 0)
    entries = []
    for i, (a3, name, iso2) in enumerate(COUNTRIES, start=1):
        sel = mask == i
        t = pop[sel].sum(dtype=np.float64)
        entries.append({"id": i, "name": name, "code": iso2, "total": round(t), "bounds": bounds(pop, sel)})
        print(f"{name}: {t / 1e6:.1f} M  {entries[-1]['bounds']}")
    write(data_dir, "countries", mask, entries)
    write_outline(data_dir, "countries",
                  [(i, [g for r, g in records if r["ADM0_A3"] == a3]) for a3, i in wanted.items()])


if __name__ == "__main__":
    main(Path(sys.argv[1]), Path(sys.argv[2]))
