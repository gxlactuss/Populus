# /// script
# requires-python = ">=3.11"
# dependencies = ["numpy", "rasterio", "pyshp"]
# ///
"""Convert GHS-POP 30 arcsec GeoTIFF and Natural Earth places into the app's data files.

Usage: uv run Scripts/build_data.py <ghs.tif> <ne_populated_places_simple.shp> <out_dir>

Output:
  pop_L0.pack  30"   43200 x 21600
  pop_L1.pack  3'     7200 x 3600
  pop_L2.pack  15'    1440 x 720
  pop_L3.pack  1.5deg  240 x 120
  cities.json

Pack layout (little endian):
  "POPG" u32 version, u32 width, u32 height, u32 tileSize, u32 tilesX, u32 tilesY,
  f64 originLon, f64 originLat, f64 cellDeg,
  tilesX*tilesY entries of (u64 offset, u32 length), length 0 = all-zero tile,
  then raw-deflate compressed Float32 tiles (tileSize*tileSize, row major, padded with zeros).
"""
import json
import struct
import sys
import zlib
from pathlib import Path

import numpy as np
import rasterio
import shapefile
from rasterio.windows import Window

W, H = 43200, 21600
CELL = 1 / 120
TILE = 512
BAND = 1536  # rows per read, multiple of TILE and of 6


class PackWriter:
    def __init__(self, path, width, height, cell_deg):
        self.width, self.height = width, height
        self.tx = (width + TILE - 1) // TILE
        self.ty = (height + TILE - 1) // TILE
        self.table = [(0, 0)] * (self.tx * self.ty)
        self.f = open(path, "wb")
        self.header = b"POPG" + struct.pack(
            "<6I3d", 1, width, height, TILE, self.tx, self.ty, -180.0, 90.0, cell_deg
        )
        self.f.write(self.header)
        self.f.write(b"\0" * (12 * len(self.table)))

    def write_rows(self, row0, data):
        """data: float array covering rows row0.. row0+n (row0 multiple of TILE), full width."""
        assert row0 % TILE == 0
        for tr in range(0, data.shape[0], TILE):
            for tc in range(self.tx):
                tile = np.zeros((TILE, TILE), dtype=np.float32)
                block = data[tr : tr + TILE, tc * TILE : (tc + 1) * TILE]
                tile[: block.shape[0], : block.shape[1]] = block
                if not tile.any():
                    continue
                # Round mantissa to 11 bits (0.02% error) so tiles compress far better.
                bits = tile.view(np.uint32)
                bits = ((bits + np.uint32(0x800)) & np.uint32(0xFFFFF000)).astype(np.uint32)
                c = zlib.compressobj(9, zlib.DEFLATED, -15)
                blob = c.compress(bits.astype("<u4").tobytes()) + c.flush()
                idx = ((row0 + tr) // TILE) * self.tx + tc
                self.table[idx] = (self.f.tell(), len(blob))
                self.f.write(blob)

    def close(self):
        self.f.seek(len(self.header))
        for off, length in self.table:
            self.f.write(struct.pack("<QI", off, length))
        self.f.close()


def build_grid(tif_path, out):
    l1 = np.zeros((H // 6, W // 6), dtype=np.float64)
    l0 = PackWriter(out / "pop_L0.pack", W, H, CELL)
    total = 0.0
    with rasterio.open(tif_path) as src:
        x0, dx, y0, dy = src.transform.c, src.transform.a, src.transform.f, src.transform.e
        assert abs(dx - CELL) < 1e-6 and abs(-dy - CELL) < 1e-6, src.transform
        row_off = round((90 - y0) / CELL)
        col_off = round((x0 + 180) / CELL)
        print(f"source {src.width}x{src.height}, offset rows {row_off} cols {col_off}")
        for g0 in range(0, H, BAND):
            g1 = min(H, g0 + BAND)
            band = np.zeros((g1 - g0, W), dtype=np.float32)
            s0, s1 = max(0, g0 - row_off), min(src.height, g1 - row_off)
            if s1 > s0:
                sc0, dc0 = max(0, -col_off), max(0, col_off)
                ncols = min(src.width - sc0, W - dc0)
                data = src.read(1, window=Window(sc0, s0, ncols, s1 - s0)).astype(np.float32)
                data[~np.isfinite(data) | (data < 0)] = 0
                band[s0 + row_off - g0 : s1 + row_off - g0, dc0 : dc0 + ncols] = data
            total += band.sum(dtype=np.float64)
            l0.write_rows(g0, band)
            l1[g0 // 6 : g1 // 6] = band.reshape((g1 - g0) // 6, 6, W // 6, 6).sum(axis=(1, 3), dtype=np.float64)
            print(f"  rows {g0}-{g1}  running total {total / 1e9:.3f} B", flush=True)
    l0.close()

    l2 = l1.reshape(H // 30, 5, W // 30, 5).sum(axis=(1, 3))
    l3 = l2.reshape(H // 180, 6, W // 180, 6).sum(axis=(1, 3))
    for name, arr, cell in (("pop_L1", l1, CELL * 6), ("pop_L2", l2, CELL * 30), ("pop_L3", l3, CELL * 180)):
        w = PackWriter(out / f"{name}.pack", arr.shape[1], arr.shape[0], cell)
        a = arr.astype(np.float32)
        for r in range(0, a.shape[0], TILE):
            w.write_rows(r, a[r : r + TILE])
        w.close()
        print(f"{name}: {arr.shape[1]}x{arr.shape[0]} total {arr.sum() / 1e9:.3f} B")
    print(f"WORLD TOTAL {total / 1e9:.3f} B")


def build_cities(shp_path, out):
    r = shapefile.Reader(str(shp_path), encoding="utf-8", encodingErrors="replace")
    fields = [f[0].lower() for f in r.fields[1:]]
    cities = []
    for rec in r.records():
        d = dict(zip(fields, rec))
        pop = int(d.get("pop_max") or 0)
        if pop < 20000:
            continue
        cities.append({"n": d["name"], "c": d.get("adm0name") or "", "lat": round(float(d["latitude"]), 4),
                       "lon": round(float(d["longitude"]), 4), "p": pop})
    cities.sort(key=lambda c: -c["p"])
    (out / "cities.json").write_text(json.dumps(cities, ensure_ascii=False, separators=(",", ":")))
    print(f"cities: {len(cities)}")


if __name__ == "__main__":
    tif, shp, out = Path(sys.argv[1]), Path(sys.argv[2]), Path(sys.argv[3])
    out.mkdir(parents=True, exist_ok=True)
    build_cities(shp, out)
    build_grid(tif, out)
    for p in sorted(out.iterdir()):
        print(f"{p.name}: {p.stat().st_size / 1e6:.1f} MB")
