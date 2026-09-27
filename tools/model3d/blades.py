"""Blade geometry shared by the model builders (the boss's naginata blades, the player's katana)."""
import math

import numpy as np

from . import geo as G


def blade_mesh(y0=0.905, length=0.70, w0=0.074, w1=0.080, thick=0.014, curve=0.10, kissaki=0.2, steps=22):
    """Curved naginata blade along +Y from y0: edge toward -Z, tip curving toward +Z (the rig's
    blade polylines). Cross-section: edge, ridge line, spine corners. UV u: spine (0) .. edge (1),
    v: base (0) .. tip (1)."""
    sec = [(0.5, 0.0, 1.0), (-0.06, 0.5, 0.45), (-0.5, 0.34, 0.0), (-0.5, -0.34, 0.0), (-0.06, -0.5, 0.45), (0.5, 0.0, 1.0)]
    rows = []
    uvs = []
    for i in range(steps + 1):
        u = i / steps
        y = y0 + u * length
        spine_z = curve * u * u
        w = w0 + (w1 - w0) * u
        th = thick * (1.0 - 0.3 * u)
        tip0 = 1.0 - kissaki
        if u > tip0:
            k = (u - tip0) / kissaki
            w *= math.sqrt(max(0.0, 1.0 - k * k)) * (1.0 - 0.02) + 0.02 * (1 - k)
            th *= (1.0 - 0.85 * k)
        t = G.unit([0.0, 1.0, 2.0 * curve * u / length])
        n = np.array([0.0, 0.0, -1.0])
        n = G.unit(n - t * np.dot(n, t))
        b = np.cross(n, t)
        center = np.array([0.0, y, spine_z])
        rows.append([center + n * (sx * w) + b * (sy * th) for sx, sy, _ in sec])
        uvs.append([[su, u] for _, _, su in sec])
    m = G.surface(np.array(rows), np.array(uvs, dtype=float))
    G.fan_cap(m, list(range(0, len(sec) - 1)), np.array(rows[0][:-1]).mean(axis=0), (0, -1, 0))
    return m
