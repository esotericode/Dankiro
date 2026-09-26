#!/usr/bin/env python3
"""Effect textures: textures/fx/fire_noise.png, the tileable noise the fire shaders scroll
through (scripts/fx/fire_fx.gd).

    python3 tools/gen_fx_textures.py

Channels, all tileable at 256 px:
  R  broad, soft noise: bends a flame and sets how tall it licks
  G  finer noise: the flicker along its edges and tips
  B  ridged noise: thin bright tongues and wisps
  A  soft cells: puffs of smoke
"""
import os
import sys

import numpy as np
from PIL import Image

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from model3d import floor_textures as FT  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "textures", "fx", "fire_noise.png")
N = 256


def unit(a):
    a = a - a.min()
    return a / max(a.max(), 1e-9)


def main():
    broad = unit(np.clip(0.5 + 0.2 * FT.fnoise(N, N, 38.0, 1, octaves=4, gain=0.55), 0.0, 1.0))
    fine = unit(np.clip(0.5 + 0.2 * FT.fnoise(N, N, 12.0, 2, octaves=3, gain=0.5), 0.0, 1.0))
    ridge = 1.0 - np.abs(FT.fnoise(N, N, 26.0, 3, octaves=3, gain=0.5))
    ridge = unit(np.clip(ridge, 0.0, None) ** 2.2)
    d1, d2, _, _ = FT.voronoi(N, N, 60, 4, warp=6.0, warp_scale=18.0)
    cells = unit(1.0 - unit(d1)) ** 1.5
    cells = unit(cells * (0.75 + 0.25 * unit(FT.fnoise(N, N, 8.0, 5))))
    img = np.stack([broad, fine, ridge, cells], 2)
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    Image.fromarray((img * 255.0 + 0.5).astype(np.uint8), "RGBA").save(OUT, optimize=True)
    print("wrote", OUT)


if __name__ == "__main__":
    main()
