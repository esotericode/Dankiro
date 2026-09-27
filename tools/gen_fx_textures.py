#!/usr/bin/env python3
"""Effect textures in textures/fx/:

    python3 tools/gen_fx_textures.py

fire_noise.png: the tileable noise the fire shaders (scripts/fx/fire_fx.gd), the weapon trails
and the dust scroll through. Channels, all tileable at 256 px:
  R  broad, soft noise: bends a flame and sets how tall it licks
  G  finer noise: the flicker along its edges and tips
  B  ridged noise: thin bright tongues and wisps (and the streaks in a weapon trail)
  A  soft cells: puffs of smoke and dust

blood_splat_0..2.png: splatter on the flagstones (decals, Fx.blood): a pool thrown out along +x,
with drops flung further that trail tails, and fine specks. Straight alpha.
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
    for i in range(3):
        path = os.path.join(os.path.dirname(OUT), "blood_splat_%d.png" % i)
        FT.save_rgba(path, blood_splat(11 + i * 7))
        print("wrote", path)


def blood_splat(seed, size=256):
    """RGBA splatter: an irregular pool stretched along +x (the way the blood flew), drops flung
    further along that way with tails pointing out, and fine specks; darker at the rims."""
    rng = np.random.default_rng(seed)
    yy, xx = np.mgrid[0:size, 0:size].astype(float) + 0.5
    cx = cy = size * 0.42
    ang = np.arctan2(yy - cy, xx - cx)
    rad = np.hypot(xx - cx, yy - cy)
    r0 = size * rng.uniform(0.12, 0.16)
    wob = np.zeros_like(ang)
    for k in (2, 3, 5, 8, 13):
        wob += rng.uniform(0.03, 0.1) * np.cos(k * ang + rng.uniform(0.0, 2.0 * np.pi)) / (1.0 + 0.1 * k)
    reach = r0 * (1.0 + wob) * (1.0 + 0.45 * np.clip(np.cos(ang), 0.0, None) ** 2)
    cov = FT.smoothstep(reach + 1.2, reach - 1.2, rad)
    # Drops flung along +x: bigger near the pool, smaller and longer-tailed further out.
    for _ in range(int(rng.integers(18, 30))):
        a = rng.normal(0.0, 0.5)
        d = r0 * rng.uniform(1.15, 3.2)
        r = max(1.2, rng.uniform(2.0, 7.0) * (1.25 - d / (r0 * 3.6)))
        px, py = cx + np.cos(a) * d, cy + np.sin(a) * d
        ux, uy = np.cos(a), np.sin(a)
        dx, dy = xx - px, yy - py
        along = dx * ux + dy * uy
        perp = -dx * uy + dy * ux
        tail = 1.0 + 2.2 * (d / (r0 * 3.2))
        stretch = np.where(along > 0.0, r * tail, r)
        e = (along / stretch) ** 2 + (perp / r) ** 2
        cov = np.maximum(cov, FT.smoothstep(1.15, 0.85, e))
    for _ in range(int(rng.integers(40, 70))):
        a = rng.normal(0.0, 0.8)
        d = r0 * rng.uniform(1.0, 4.2)
        px, py = cx + np.cos(a) * d, cy + np.sin(a) * d
        r = rng.uniform(0.7, 1.8)
        cov = np.maximum(cov, FT.smoothstep(r + 0.7, r - 0.7, np.hypot(xx - px, yy - py)))
    thick = np.clip(FT.blur(cov, 4.0) * 1.3, 0.0, 1.0)
    rim = np.clip(cov - thick, 0.0, 1.0)
    grain = 0.9 + 0.1 * FT.fnoise(size, size, 6.0, seed + 1)
    base = np.array([0.36, 0.015, 0.012])
    col = base[None, None, :] * (grain * (0.8 + 0.3 * thick) * (1.0 - 0.45 * rim))[..., None]
    return np.dstack([np.clip(col, 0.0, 1.0), np.clip(cov * 0.96, 0.0, 1.0)])


if __name__ == "__main__":
    main()
