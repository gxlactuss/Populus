# /// script
# requires-python = ">=3.11"
# dependencies = ["numpy", "rasterio"]
# ///
"""Cut 100 m (3 arcsec) GHS-POP 2025 boxes around each city for city rounds.

Usage: uv run Scripts/build_metros.py <tile_cache_dir> <data_dir>

Cities already in data_dir/metros.json with the same id are kept as they are.

Downloads only the 10° GHS-POP 3ss tiles the cities need into tile_cache_dir, then writes
metro_<id>.pack (same pack format as pop_L*.pack, with the box's own origin) and metros.json.
"""
import json
import math
import struct
import subprocess
import sys
import zipfile
import zlib
from pathlib import Path

import numpy as np
import rasterio
from rasterio.windows import Window

BASE = "https://jeodpp.jrc.ec.europa.eu/ftp/jrc-opendata/GHSL/GHS_POP_GLOBE_R2023A/GHS_POP_E2025_GLOBE_R2023A_4326_3ss/V1-0/tiles"
NAME = "GHS_POP_E2025_GLOBE_R2023A_4326_3ss_V1_0_R{r}_C{c}"
CELL = 1 / 1200
TILE_PX = 12000
X0 = -180.00791666  # left edge of column C1
Y0 = 89.09958333  # top edge of row R1
TILE = 512

# (name, country, lat, lon, radius_km): the capitals of the game's countries plus famous big cities.
METROS = [
    ("Tokyo", "Japan", 35.68, 139.77, 60), ("Delhi", "India", 28.61, 77.21, 45),
    ("Shanghai", "China", 31.23, 121.47, 55), ("Dhaka", "Bangladesh", 23.81, 90.41, 35),
    ("São Paulo", "Brazil", -23.55, -46.63, 50), ("Mexico City", "Mexico", 19.43, -99.13, 45),
    ("Cairo", "Egypt", 30.04, 31.24, 40), ("Beijing", "China", 39.90, 116.40, 50),
    ("Mumbai", "India", 19.08, 72.88, 40), ("Osaka", "Japan", 34.69, 135.50, 45),
    ("Karachi", "Pakistan", 24.86, 67.01, 35), ("Istanbul", "Turkey", 41.01, 28.98, 45),
    ("Manila", "Philippines", 14.60, 120.98, 40), ("Lagos", "Nigeria", 6.52, 3.38, 40),
    ("Buenos Aires", "Argentina", -34.60, -58.38, 45), ("Rio de Janeiro", "Brazil", -22.91, -43.17, 45),
    ("Moscow", "Russia", 55.76, 37.62, 50), ("Paris", "France", 48.86, 2.35, 45),
    ("London", "United Kingdom", 51.51, -0.13, 45), ("Jakarta", "Indonesia", -6.20, 106.85, 50),
    ("Seoul", "South Korea", 37.57, 126.98, 50), ("Bangkok", "Thailand", 13.76, 100.50, 45),
    ("New York", "United States", 40.71, -74.01, 55), ("Los Angeles", "United States", 34.05, -118.24, 60),
    ("Chicago", "United States", 41.88, -87.63, 45), ("Tehran", "Iran", 35.69, 51.39, 40),
    ("Johannesburg", "South Africa", -26.20, 28.05, 50), ("Sydney", "Australia", -33.87, 151.21, 50),
    ("Toronto", "Canada", 43.65, -79.38, 45), ("Singapore", "Singapore", 1.35, 103.82, 25),
    ("Berlin", "Germany", 52.52, 13.40, 40), ("Madrid", "Spain", 40.42, -3.70, 40),
    ("Amsterdam", "Netherlands", 52.37, 4.90, 40), ("Washington", "United States", 38.90, -77.04, 40),
    ("Islamabad", "Pakistan", 33.69, 73.05, 30), ("Abuja", "Nigeria", 9.06, 7.49, 35),
    ("Brasília", "Brazil", -15.79, -47.88, 40), ("Ankara", "Turkey", 39.93, 32.86, 35),
    ("Rome", "Italy", 41.90, 12.50, 35), ("Pretoria", "South Africa", -25.75, 28.19, 30),
    ("Ottawa", "Canada", 45.42, -75.70, 30), ("Canberra", "Australia", -35.28, 149.13, 25),
    ("Riyadh", "Saudi Arabia", 24.71, 46.68, 40), ("Kyiv", "Ukraine", 50.45, 30.52, 35),
    ("Warsaw", "Poland", 52.23, 21.01, 35), ("Oslo", "Norway", 59.91, 10.75, 30),
    ("San Francisco", "United States", 37.77, -122.42, 45), ("Hong Kong", "China", 22.32, 114.17, 30),
    ("Barcelona", "Spain", 41.39, 2.17, 30), ("Melbourne", "Australia", -37.81, 144.96, 45),
    ("Dubai", "United Arab Emirates", 25.20, 55.27, 40),
    ("Ho Chi Minh City", "Vietnam", 10.78, 106.70, 40), ("Taipei", "Taiwan", 25.03, 121.57, 35),
    ("Doha", "Qatar", 25.29, 51.53, 30), ("Vienna", "Austria", 48.21, 16.37, 30),
    ("Prague", "Czechia", 50.08, 14.44, 25), ("Budapest", "Hungary", 47.50, 19.04, 30),
    ("Athens", "Greece", 37.98, 23.73, 30), ("Lisbon", "Portugal", 38.72, -9.14, 30),
    ("Stockholm", "Sweden", 59.33, 18.07, 30), ("Copenhagen", "Denmark", 55.68, 12.57, 30),
    ("Dublin", "Ireland", 53.35, -6.26, 25), ("Brussels", "Belgium", 50.85, 4.35, 25),
    ("Zurich", "Switzerland", 47.38, 8.54, 25), ("Nairobi", "Kenya", -1.29, 36.82, 30),
    ("Santiago", "Chile", -33.45, -70.67, 40), ("Auckland", "New Zealand", -36.85, 174.76, 35),
    ("Helsinki", "Finland", 60.17, 24.94, 30), ("Geneva", "Switzerland", 46.20, 6.15, 20),
    ("Bucharest", "Romania", 44.43, 26.10, 30), ("Belgrade", "Serbia", 44.79, 20.45, 30),
    ("Milan", "Italy", 45.46, 9.19, 35), ("Munich", "Germany", 48.14, 11.58, 35),
    ("Saint Petersburg", "Russia", 59.94, 30.31, 40), ("Manchester", "United Kingdom", 53.48, -2.24, 30),
    ("Edinburgh", "United Kingdom", 55.95, -3.19, 20), ("Venice", "Italy", 45.44, 12.33, 20),
]


def tile_path(cache, r, c):
    name = NAME.format(r=r, c=c)
    tif = cache / name / f"{name}.tif"
    if not tif.exists():
        z = cache / f"{name}.zip"
        print(f"  downloading R{r} C{c}", flush=True)
        subprocess.run(["curl", "-sSfL", "-o", str(z), f"{BASE}/{name}.zip"], check=True)
        with zipfile.ZipFile(z) as zf:
            zf.extract(f"{name}.tif", cache / name)
        z.unlink()
    return tif


def write_pack(path, data, origin_lon, origin_lat):
    h, w = data.shape
    tx, ty = (w + TILE - 1) // TILE, (h + TILE - 1) // TILE
    table = []
    blobs = bytearray()
    header_len = 52 + 12 * tx * ty
    for r in range(ty):
        for c in range(tx):
            tile = np.zeros((TILE, TILE), np.float32)
            block = data[r * TILE : (r + 1) * TILE, c * TILE : (c + 1) * TILE]
            tile[: block.shape[0], : block.shape[1]] = block
            if not tile.any():
                table.append((0, 0))
                continue
            co = zlib.compressobj(9, zlib.DEFLATED, -15)
            blob = co.compress(tile.astype("<f4").tobytes()) + co.flush()
            table.append((header_len + len(blobs), len(blob)))
            blobs += blob
    with open(path, "wb") as f:
        f.write(b"POPG" + struct.pack("<6I3d", 1, w, h, TILE, tx, ty, origin_lon, origin_lat, CELL))
        for off, length in table:
            f.write(struct.pack("<QI", off, length))
        f.write(blobs)


def main(cache, out):
    cache.mkdir(parents=True, exist_ok=True)
    # Reuse cities already built into out, so adding a city only downloads what it needs.
    meta = out / "metros.json"
    built = {e["name"]: e for e in json.loads(meta.read_text())["entries"]} if meta.exists() else {}
    entries = []
    for i, (name, country, lat, lon, radius) in enumerate(METROS, start=1):
        if built.get(name, {}).get("id") == i and (out / f"metro_{i}.pack").exists():
            entries.append(built[name])
            continue
        dlat = radius / 111.32
        dlon = radius / (111.32 * math.cos(math.radians(lat)))
        # Global 3ss pixel indices of the box.
        row0 = math.floor((Y0 - (lat + dlat)) / CELL)
        row1 = math.ceil((Y0 - (lat - dlat)) / CELL)
        col0 = math.floor(((lon - dlon) - X0) / CELL)
        col1 = math.ceil(((lon + dlon) - X0) / CELL)
        data = np.zeros((row1 - row0, col1 - col0), np.float32)
        for r in range(row0 // TILE_PX, (row1 - 1) // TILE_PX + 1):
            for c in range(col0 // TILE_PX, (col1 - 1) // TILE_PX + 1):
                tr0, tr1 = max(row0, r * TILE_PX), min(row1, (r + 1) * TILE_PX)
                tc0, tc1 = max(col0, c * TILE_PX), min(col1, (c + 1) * TILE_PX)
                with rasterio.open(tile_path(cache, r + 1, c + 1)) as src:
                    block = src.read(1, window=Window(tc0 - c * TILE_PX, tr0 - r * TILE_PX, tc1 - tc0, tr1 - tr0))
                block = np.nan_to_num(block, nan=0).clip(min=0).astype(np.float32)
                data[tr0 - row0 : tr1 - row0, tc0 - col0 : tc1 - col0] = block
        origin_lon, origin_lat = X0 + col0 * CELL, Y0 - row0 * CELL
        write_pack(out / f"metro_{i}.pack", data, origin_lon, origin_lat)
        total = float(data.sum(dtype=np.float64))
        bounds = [round(origin_lat - data.shape[0] * CELL, 5), round(origin_lat, 5),
                  round(origin_lon, 5), round(origin_lon + data.shape[1] * CELL, 5)]
        entries.append({"id": i, "name": name, "country": country, "total": round(total), "bounds": bounds})
        size = (out / f"metro_{i}.pack").stat().st_size / 1e6
        print(f"{name}: {total / 1e6:.1f} M in {data.shape[1]}x{data.shape[0]} ({size:.1f} MB)", flush=True)
    (out / "metros.json").write_text(json.dumps({"entries": entries}, ensure_ascii=False))


if __name__ == "__main__":
    main(Path(sys.argv[1]), Path(sys.argv[2]))
