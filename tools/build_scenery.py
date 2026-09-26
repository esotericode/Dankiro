#!/usr/bin/env python3
"""Builds the world round the arena: models/scenery/*.glb and textures/scenery/.

    pip install bpy==4.5.9                        # Blender 4.5 LTS as a Python module (once)
    python3 tools/build_scenery.py                # everything (about a minute with the occlusion bakes)
    python3 tools/build_scenery.py --only trees   # some families: textures trees torii props approach backdrop
    python3 tools/build_scenery.py --preview      # also render Blender previews to tools/preview_out/
    godot --headless --editor --quit              # import

Everything is modelled here in numpy (model3d/geo) and handed to Blender, which bakes ambient
occlusion into the vertices (Cycles, to a colour attribute, copied into the second UV channel
beside a per-part value the shaders use) and exports the glb. The material names on the parts
are what the game keys its shaders on (MATERIALS in scripts/world/scenery.gd).

 - trees.glb: Japanese cedars (sugi) in three shapes and an old sacred one roped with a
   shimenawa, two black pines, two red maples, shrubs, ferns and boulders. A crown is clumps of
   foliage (normals bent out from its middle, so it lights as one mass) under cards of leaf
   sprays that the game turns to face the camera (Crown).
 - torii.glb: a myojin torii with its plaque (月門, "Moon Gate").
 - props.glb: the hexagonal kasuga stone lantern and its paper, a fence post and a rail.
 - approach.glb: the path, the walled court with its steps, and the shrine hall with its
   irimoya roof, modelled in place (world coordinates).
 - backdrop.glb: the summit's ground, falling away to the east (edge_radius), and three rings
   of mountains from hills to snowy peaks.
"""
import argparse
import math
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import numpy as np  # noqa: E402

from model3d import floor_textures as FT  # noqa: E402
from model3d import geo as G  # noqa: E402
from model3d import scenery_textures as ST  # noqa: E402
from model3d.geo import Mesh  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "models", "scenery")
TEX = os.path.join(ROOT, "textures", "scenery")
PREVIEW_DIR = os.path.join(ROOT, "tools", "preview_out")


# ================================================================== primitives
class Part:
    """A piece of an asset: a mesh, the material it's drawn with, a per-vertex value for the
    shader (UV2.y) and optionally custom per-vertex normals. Cards (leaf sprays) take no part in
    the occlusion bake; each vertex copies the occlusion of a vertex of `ao_part` (ao_src)."""

    def __init__(self, mesh, material, extra=0.0, normals=None):
        self.mesh = mesh
        self.material = material
        self.extra = np.broadcast_to(np.asarray(extra, dtype=float), (len(mesh.v),)).copy()
        self.normals = None if normals is None else np.asarray(normals, dtype=float)
        self.card = False
        self.ao_part = None
        self.ao_src = None


def icosphere(subdiv=2):
    t = (1.0 + 5 ** 0.5) / 2.0
    V = [(-1, t, 0), (1, t, 0), (-1, -t, 0), (1, -t, 0), (0, -1, t), (0, 1, t), (0, -1, -t), (0, 1, -t),
         (t, 0, -1), (t, 0, 1), (-t, 0, -1), (-t, 0, 1)]
    F = [(0, 11, 5), (0, 5, 1), (0, 1, 7), (0, 7, 10), (0, 10, 11), (1, 5, 9), (5, 11, 4), (11, 10, 2),
         (10, 7, 6), (7, 1, 8), (3, 9, 4), (3, 4, 2), (3, 2, 6), (3, 6, 8), (3, 8, 9), (4, 9, 5), (2, 4, 11),
         (6, 2, 10), (8, 6, 7), (9, 8, 1)]
    V = [np.array(v, dtype=float) / np.linalg.norm(v) for v in V]
    for _ in range(subdiv):
        cache = {}
        F2 = []

        def mid(a, b):
            k = (min(a, b), max(a, b))
            if k not in cache:
                m = V[a] + V[b]
                V.append(m / np.linalg.norm(m))
                cache[k] = len(V) - 1
            return cache[k]
        for a, b, c in F:
            ab, bc, ca = mid(a, b), mid(b, c), mid(c, a)
            F2 += [(a, ab, ca), (b, bc, ab), (c, ca, bc), (ab, bc, ca)]
        F = F2
    return np.array(V), F


_ICO = {}


def ico(subdiv):
    if subdiv not in _ICO:
        _ICO[subdiv] = icosphere(subdiv)
    return _ICO[subdiv]


def noise3(p, seed, scale, octaves=3, waves=5):
    """Smooth 3D noise (sums of random plane waves), about -1..1. scale: feature size (m)."""
    rng = np.random.default_rng(seed)
    p = np.asarray(p, dtype=float)
    out = np.zeros(len(p))
    amp, tot = 1.0, 0.0
    for o in range(octaves):
        for _ in range(waves):
            d = rng.normal(size=3)
            d /= np.linalg.norm(d)
            f = 2 * math.pi / (scale / 2 ** o) * rng.uniform(0.8, 1.25)
            out += amp * np.sin(p @ d * f + rng.uniform(0, 2 * math.pi))
            tot += amp
        amp *= 0.5
    return out / (tot ** 0.5 * 1.1)


def rot_y(deg):
    return G.rot("y", deg)


def clump(center, radii, yaw, seed, rough=0.28, flat_bottom=None, subdiv=1, droop=0.0):
    """A lumpy foliage mass: an icosphere scaled to `radii`, displaced by noise, turned `yaw`
    degrees. flat_bottom: squash its underside to this fraction of its height (pine pads)."""
    V, F = ico(subdiv)
    r = np.asarray(radii, dtype=float)
    d = 1.0 + rough * noise3(V * 1.3, seed, 0.9, 3)
    P = V * d[:, None] * r
    if flat_bottom is not None:
        P[:, 1] = np.maximum(P[:, 1], -r[1] * flat_bottom) + np.minimum(P[:, 1] + r[1] * flat_bottom, 0) * 0.15
    if droop:
        P[:, 1] -= droop * (P[:, 0] / max(r[0], 1e-3)) ** 2 * r[1]
    P = P @ rot_y(yaw).T + np.asarray(center, dtype=float)
    return Mesh(P, [tuple(f) for f in F], np.zeros((len(P), 2)))


def bend_normals(mesh, centers, weight=0.55, up=0.25):
    """Normals for foliage: each clump's own normal bent toward `centers` - the direction from the
    crown's middle out to the vertex (per vertex) - so a crown lights as one soft mass."""
    own = vertex_normals(mesh)
    out = mesh.v - centers
    out[:, 1] += up * np.linalg.norm(out, axis=1)
    out /= np.linalg.norm(out, axis=1, keepdims=True) + 1e-9
    n = own * (1.0 - weight) + out * weight
    return n / (np.linalg.norm(n, axis=1, keepdims=True) + 1e-9)


class Crown:
    """Collects a tree's clumps of foliage, then makes its parts: the clumps themselves, shrunk a
    little, as the crown's inner mass (normals bent out from the crown's middle), and cards of
    foliage over their outer faces. A card is a square in the object's xy plane centred on its
    spot; the leaves shader turns it to face the camera (it finds the centre from UV and the
    card size), so the crown's outline is always made of sprays."""

    def __init__(self, seed):
        self.rng = np.random.default_rng(seed)
        self.blobs = []

    def add(self, mesh, centre):
        self.blobs.append((mesh, np.asarray(centre, dtype=float), self.rng.random()))

    def parts(self, material, card_material, card_size, density, weight=0.55, up=0.3, shrink=0.85):
        fol = Mesh()
        cent, tone = [], []
        spans = []
        for m, c, t in self.blobs:
            m2 = m.copy()
            mc = m2.v.mean(axis=0)
            m2.v = mc + (m2.v - mc) * shrink
            spans.append((len(fol.v), len(fol.f), len(m2.v), len(m2.f)))
            fol.add(m2)
            cent.append(np.repeat(c[None, :], len(m2.v), 0))
            tone.append(np.full(len(m2.v), t))
        cent = np.concatenate(cent)
        tone = np.concatenate(tone)
        nrm = bend_normals(fol, cent, weight, up)
        blob = Part(fol, material, tone, nrm)
        rng = self.rng
        hs = card_size * 0.5
        V, F, UV, N, T, SRC = [], [], [], [], [], []
        for (v0, f0, nv, nf), (m, c, t) in zip(spans, self.blobs):
            faces = np.array([f[:3] for f in fol.f[f0:f0 + nf]])
            a, b, cc = fol.v[faces[:, 0]], fol.v[faces[:, 1]], fol.v[faces[:, 2]]
            area = 0.5 * np.linalg.norm(np.cross(b - a, cc - a), axis=1)
            fc = (a + b + cc) / 3.0
            out = fc - c
            out[:, 1] += up * np.linalg.norm(out, axis=1)
            fn = nrm[faces].mean(axis=1)
            ok = np.einsum("ij,ij->i", fn, out) > 0.0
            if not ok.any():
                continue
            w = area * ok
            k = max(2, int(round(w.sum() / shrink ** 2 * density)))
            pick = rng.choice(len(faces), size=k, p=w / w.sum())
            for fi in pick:
                r1, r2 = rng.random(2)
                if r1 + r2 > 1.0:
                    r1, r2 = 1.0 - r1, 1.0 - r2
                i0, i1, i2 = faces[fi]
                p = fol.v[i0] + (fol.v[i1] - fol.v[i0]) * r1 + (fol.v[i2] - fol.v[i0]) * r2
                n = nrm[i0] + (nrm[i1] - nrm[i0]) * r1 + (nrm[i2] - nrm[i0]) * r2
                n /= np.linalg.norm(n) + 1e-9
                p = p + n * card_size * 0.1
                base = len(V)
                V += [p + (-hs, -hs, 0.0), p + (hs, -hs, 0.0), p + (hs, hs, 0.0), p + (-hs, hs, 0.0)]
                UV += [(0.0, 1.0), (1.0, 1.0), (1.0, 0.0), (0.0, 0.0)]
                F.append((base, base + 1, base + 2, base + 3))
                N += [n] * 4
                T += [t] * 4
                SRC += [i0] * 4
        cards = Part(Mesh(np.array(V), F, np.array(UV)), card_material, np.array(T), np.array(N))
        cards.card = True
        cards.ao_part = blob
        cards.ao_src = np.array(SRC)
        return [blob, cards]


def vertex_normals(mesh):
    V = mesh.v
    n = np.zeros_like(V)
    for f in mesh.f:
        for i in range(1, len(f) - 1):
            a, b, c = f[0], f[i], f[i + 1]
            fn = np.cross(V[b] - V[a], V[c] - V[a])
            n[[a, b, c]] += fn
    return n / (np.linalg.norm(n, axis=1, keepdims=True) + 1e-9)


def tube(path, radius, segs=10, caps=False, tile=1.0):
    """A swept tube whose u runs round it a whole number of `tile`s (so the bark has no seam) and v
    up it in metres."""
    m = G.sweep(path, radius, segs=segs, caps=caps)
    n_ring = len(np.asarray(path)) * (segs + 1)
    k = max(1, int(round(2 * math.pi * float(np.mean(radius)) / tile)))
    j = np.arange(n_ring) % (segs + 1)
    m.uv[:n_ring, 0] = j / segs * k * tile
    return m


def path_at(path, y):
    """Point on a mostly vertical polyline at height y."""
    P = np.asarray(path, dtype=float)
    return np.array([np.interp(y, P[:, 1], P[:, 0]), y, np.interp(y, P[:, 1], P[:, 2])])


# ================================================================== trees
def sugi(seed, H=19.0, girth=1.0, sacred=False):
    """Japanese cedar: a tall straight trunk, bare below, and a narrow ragged cone of foliage.
    sacred: an old giant (shinboku) with a straw rope round it."""
    rng = np.random.default_rng(seed)
    lean = rng.normal(0.0, 0.01, 2)
    ph = rng.uniform(0, 6.28, 2)
    ys = np.linspace(0.0, H * 0.97, 20)
    path = np.stack([lean[0] * ys + 0.06 * np.sin(ys * 0.35 + ph[0]), ys,
                     lean[1] * ys + 0.06 * np.cos(ys * 0.3 + ph[1])], 1)
    r = (0.31 * (1.0 - ys / H) ** 0.9 + 0.035 + 0.2 * np.exp(-ys / 0.5)) * girth
    trunk = tube(path, r, segs=16 if sacred else 12)
    parts = [Part(trunk, "bark_sugi", 0.0)]
    if sacred:
        parts.extend(shimenawa(2.4, float(np.interp(2.4, ys, r)) + 0.06, seed))
    y0 = H * rng.uniform(0.3, 0.4) * (1.3 if sacred else 1.0)
    R0 = rng.uniform(2.0, 2.6) * (1.25 if sacred else 1.0)
    crown = Crown(seed)
    y = y0
    k = 0
    while y < H * 0.93:
        t = (y - y0) / (H - y0)
        Rc = R0 * (1.0 - t) ** 0.85 + 0.3
        n = max(1, int(round(2 * math.pi * Rc * 0.62 / 1.25)))
        phase = rng.uniform(0, 360)
        axis = path_at(path, y)
        for j in range(n):
            if rng.random() < 0.12:
                continue                                       # a gap in the tier
            a = phase + j * 360.0 / n + rng.uniform(-18, 18)
            rr = Rc * rng.uniform(0.45, 0.8)
            c = axis + np.array([math.sin(math.radians(a)) * rr, rng.uniform(-0.2, 0.2), math.cos(math.radians(a)) * rr])
            sc = rng.uniform(0.85, 1.15) * (0.55 + 0.55 * (1.0 - t))
            crown.add(clump(c, (sc * 1.15, sc * 0.72, sc * 0.95), a, seed * 100 + k, droop=0.35), axis)
            k += 1
        y += rng.uniform(0.75, 1.0)
    for j in range(2):                                         # the pointed top
        ytop = H * (0.93 + 0.035 * j)
        axis = path_at(path, ytop)
        m = clump(axis + np.array([0, 0.3, 0]), (0.5 - 0.15 * j, 0.95, 0.5 - 0.15 * j), 0, seed * 100 + k + j)
        crown.add(m, axis - np.array([0, 0.8, 0]))
    parts.extend(crown.parts("foliage_sugi", "leaves_sugi", 1.15, 2.0, 0.6, 0.35))
    return parts


def pine(seed, H=9.0):
    """Japanese black pine: a trunk leaning and bending as the wind has left it, near-level limbs,
    and a cloud-like pad of needles at the end of each (several clumps, domed on top, flat below)."""
    rng = np.random.default_rng(seed)
    la = rng.uniform(0, 2 * math.pi)
    lean = np.array([math.cos(la), 0.0, math.sin(la)])
    perp = np.array([-lean[2], 0.0, lean[0]])
    ys = np.linspace(0.0, H, 18)
    t = ys / H
    off = lean[None, :] * (1.9 * t ** 1.3)[:, None] + perp[None, :] * (0.45 * np.sin(math.pi * t * 1.6))[:, None]
    path = np.stack([np.zeros_like(ys), ys, np.zeros_like(ys)], 1) + off
    r = 0.25 * (1.0 - t) ** 0.8 + 0.06 + 0.14 * np.exp(-ys / 0.35)
    wood = tube(path, r, segs=12)
    crown = Crown(seed)
    k = 0

    def pad(c, R, yaw):
        nonlocal k
        pc = c - np.array([0.0, 0.5, 0.0])
        n = int(rng.integers(4, 7))
        for q in range(n + 1):
            if q == n:
                o = np.array([0.0, 0.16, 0.0])
                sz = R * 0.62
            else:
                a = yaw + 2 * math.pi * q / n + rng.uniform(-0.3, 0.3)
                o = np.array([math.cos(a), 0.0, math.sin(a)]) * R * rng.uniform(0.45, 0.7)
                sz = R * rng.uniform(0.42, 0.58)
            m = clump(c + o, (sz * 1.15, sz * rng.uniform(0.42, 0.55), sz), rng.uniform(0, 360), seed * 100 + k,
                      rough=0.3, flat_bottom=0.5)
            crown.add(m, pc)
            k += 1

    n_limbs = int(rng.integers(5, 8))
    for i in range(n_limbs):
        f = i / max(1, n_limbs - 1)
        yb = H * (0.36 + 0.52 * f) + rng.uniform(-0.25, 0.25)
        base = path_at(path, yb)
        a = la + math.pi * (0.35 + 1.3 * rng.random()) * (1 if i % 2 else -1)
        d = np.array([math.cos(a), 0.0, math.sin(a)])
        ln = rng.uniform(2.0, 3.4) * (1.15 - 0.5 * f)
        s = np.linspace(0.0, 1.0, 8)
        rise = ln * (0.32 * s ** 2.2 - 0.12 * s)
        lp = base[None, :] + d[None, :] * (s * ln)[:, None] + np.array([0.0, 1.0, 0.0])[None, :] * rise[:, None]
        wood.add(tube(lp, 0.11 * (1.0 - 0.7 * s) + 0.025, segs=7))
        pad(lp[-1] + np.array([0.0, 0.3, 0.0]), rng.uniform(1.0, 1.45) * (1.1 - 0.3 * f), a)
        if ln > 2.6:
            j = 4
            side = np.cross(d, [0.0, 1.0, 0.0]) * (1 if rng.random() < 0.5 else -1)
            tip = lp[j] + side * 0.9 + np.array([0.0, 0.35, 0.0])
            wood.add(tube(np.array([lp[j], (lp[j] + tip) / 2 + np.array([0.0, 0.1, 0.0]), tip]),
                          np.array([0.06, 0.045, 0.03]), segs=6))
            pad(tip + np.array([0.0, 0.25, 0.0]), rng.uniform(0.7, 0.95), a)
    pad(path_at(path, H) + np.array([0.0, 0.25, 0.0]), rng.uniform(1.1, 1.4), la)
    return [Part(wood, "bark_pine", 0.0)] + crown.parts("foliage_pine", "leaves_pine", 1.0, 2.2, 0.5, 0.9)


def maple(seed, H=6.5):
    """Japanese maple in autumn: a short crooked trunk forking into limbs that arch outward, each
    ending in layered sprays of red leaves, so the crown is broad, tiered and full of gaps."""
    rng = np.random.default_rng(seed)
    fork = H * rng.uniform(0.28, 0.35)
    ys = np.linspace(0.0, fork, 8)
    lean = rng.normal(0.0, 0.07, 2)
    path = np.stack([lean[0] * ys + 0.07 * np.sin(ys * 2.1), ys, lean[1] * ys + 0.07 * np.cos(ys * 1.7)], 1)
    wood = tube(path, 0.19 - 0.05 * ys / fork + 0.11 * np.exp(-ys / 0.25), segs=12)
    base = path[-1]
    crown = Crown(seed)
    clumps = []
    k = 0
    n_limbs = int(rng.integers(4, 6))
    for i in range(n_limbs):
        az = 2 * math.pi * i / n_limbs + rng.uniform(-0.4, 0.4)
        el = rng.uniform(0.6, 1.0)
        L = H * rng.uniform(0.42, 0.55)
        out = np.array([math.cos(az), 0.0, math.sin(az)])
        d = np.array([math.cos(el) * out[0], math.sin(el), math.cos(el) * out[2]])
        pts = [base.copy()]
        for j in range(6):
            d = d + out * 0.22 - np.array([0.0, 0.1, 0.0])
            d /= np.linalg.norm(d)
            pts.append(pts[-1] + d * L / 6)
        lp = np.array(pts)
        s = np.linspace(0.0, 1.0, len(lp))
        wood.add(tube(lp, 0.1 * (1.0 - 0.75 * s) + 0.025, segs=7))
        tips = [lp[-1]]
        for j in (2, 4):
            side = np.cross(lp[j + 1] - lp[j], [0.0, 1.0, 0.0])
            side = side / (np.linalg.norm(side) + 1e-9) * (1 if rng.random() < 0.5 else -1)
            end = lp[j] + side * L * rng.uniform(0.22, 0.34) + out * L * 0.1 + np.array([0.0, L * 0.12, 0.0])
            wood.add(tube(np.array([lp[j], (lp[j] + end) / 2 + np.array([0.0, 0.08, 0.0]), end]),
                          np.array([0.05, 0.035, 0.02]), segs=5))
            tips.append(end)
        for tip in tips:
            for q in range(int(rng.integers(3, 5))):
                c = tip + rng.normal(0.0, 0.42, 3) * np.array([1.0, 0.25, 1.0]) + np.array([0.0, 0.12, 0.0])
                sz = rng.uniform(0.55, 0.8)
                clumps.append((c, sz))
    top = np.mean([c for c, _ in clumps], axis=0)
    for q in range(3):
        clumps.append((top + np.array([rng.normal(0, 0.5), 0.35 + 0.2 * q, rng.normal(0, 0.5)]), rng.uniform(0.6, 0.8)))
    cc = top - np.array([0.0, 0.6, 0.0])
    for c, sz in clumps:
        crown.add(clump(c, (sz * 1.15, sz * 0.5, sz), rng.uniform(0, 360), seed * 100 + k, rough=0.38, droop=0.3), cc)
        k += 1
    return [Part(wood, "bark_maple", 0.0)] + crown.parts("foliage_maple", "leaves_maple", 0.8, 3.2, 0.5, 0.35)


def shimenawa(y, radius, seed=0):
    """A sacred straw rope tied round a trunk at height y, with paper streamers hanging from it."""
    rng = np.random.default_rng(seed)
    a = np.linspace(0.0, 2 * math.pi, 33)
    ring = np.stack([np.sin(a) * radius, y + 0.04 * np.sin(a * 3.0), np.cos(a) * radius], 1)
    parts = [Part(tube(ring, 0.085, segs=10, tile=0.4), "rope")]
    for i in range(5):
        ang = 2 * math.pi * i / 5 + rng.uniform(-0.2, 0.2)
        x, z = math.sin(ang) * (radius + 0.08), math.cos(ang) * (radius + 0.08)
        m = shide(0.0, y - 0.08, 0.0)
        m.rotate("y", math.degrees(ang)).translate((x, 0.0, z))
        parts.append(Part(m, "shide"))
    return parts


def shrub(seed):
    rng = np.random.default_rng(seed)
    crown = Crown(seed)
    c0 = np.array([0.0, 0.35, 0.0])
    for k in range(int(rng.integers(3, 6))):
        c = c0 + np.array([rng.uniform(-0.7, 0.7), rng.uniform(0.0, 0.3), rng.uniform(-0.7, 0.7)])
        sz = rng.uniform(0.5, 0.8)
        crown.add(clump(c, (sz, sz * 0.8, sz), rng.uniform(0, 360), seed * 100 + k, rough=0.3, flat_bottom=0.6), c0)
    return crown.parts("foliage_shrub", "leaves_shrub", 0.55, 5.0, 0.5, 0.5)


def fern(seed):
    """A low clump of ferns: a flat hidden core with fern cards over it."""
    rng = np.random.default_rng(seed)
    crown = Crown(seed)
    c0 = np.array([0.0, 0.1, 0.0])
    for k in range(int(rng.integers(2, 4))):
        c = c0 + np.array([rng.uniform(-0.3, 0.3), rng.uniform(0.1, 0.2), rng.uniform(-0.3, 0.3)])
        sz = rng.uniform(0.35, 0.5)
        crown.add(clump(c, (sz, sz * 0.45, sz), rng.uniform(0, 360), seed * 100 + k, rough=0.2, flat_bottom=0.6), c0)
    return crown.parts("foliage_fern", "leaves_fern", 0.75, 7.0, 0.4, 0.8, shrink=0.7)


def boulder(seed, size=1.0):
    rng = np.random.default_rng(seed)
    V, F = ico(3)
    d = 1.0 + 0.22 * noise3(V, seed, 1.2, 3) + 0.06 * noise3(V, seed + 1, 0.35, 2)
    P = V * d[:, None] * np.array([1.0, 0.62, 0.85]) * size
    P[:, 1] = np.maximum(P[:, 1], -0.25 * size)
    P = P @ rot_y(rng.uniform(0, 360)).T
    m = Mesh(P, [tuple(f) for f in F], np.stack([np.arctan2(P[:, 0], P[:, 2]) * size, P[:, 1]], 1))
    return [Part(m, "rock", 0.0)]


def trees():
    assets = {}
    for i, (seed, H) in enumerate(((11, 19.0), (12, 22.0), (13, 16.5))):
        assets["sugi_%s" % "abc"[i]] = sugi(seed, H)
    assets["sugi_sacred"] = sugi(14, 27.0, girth=2.4, sacred=True)
    for i, (seed, H) in enumerate(((21, 9.0), (22, 7.5))):
        assets["pine_%s" % "ab"[i]] = pine(seed, H)
    for i, (seed, H) in enumerate(((31, 6.5), (32, 5.5))):
        assets["maple_%s" % "ab"[i]] = maple(seed, H)
    for i, seed in enumerate((41, 42)):
        assets["shrub_%s" % "ab"[i]] = shrub(seed)
    for i, (seed, s) in enumerate(((51, 1.1), (52, 0.7))):
        assets["rock_%s" % "ab"[i]] = boulder(seed, s)
    for i, seed in enumerate((61, 62)):
        assets["fern_%s" % "ab"[i]] = fern(seed)
    return assets


# ================================================================== building blocks
def section_rect(w, h, chamfer=0.02, top_w=None):
    """Closed (a, b) outline of a w-wide, h-tall section centred on the origin (a across, b up),
    corners chamfered; top_w makes it a trapezoid (wider on top)."""
    hw, hh, c = w / 2.0, h / 2.0, chamfer
    tw = hw if top_w is None else top_w / 2.0
    return [(hw, -hh + c), (tw, hh - c), (tw - c, hh), (-tw + c, hh), (-tw, hh - c), (-hw, -hh + c),
            (-hw + c, -hh), (hw - c, -hh)]


def beam(path, section, up=(0.0, 1.0, 0.0), caps=True, slant=(0.0, 0.0)):
    """A section swept along a polyline, kept upright (the section's b axis stays in the plane of
    `up` and the path, as a timber would be; it does not twist with the curve). slant: how far
    the end faces lean out per metre of height (a torii's kasagi ends are cut on a slope).
    UVs: u round the section, v along the path, in metres."""
    P = np.asarray(path, dtype=float)
    S = np.asarray(section, dtype=float)
    up = np.asarray(up, dtype=float)
    T = np.gradient(P, axis=0)
    T /= np.linalg.norm(T, axis=1, keepdims=True)
    side = np.cross(up[None, :], T)
    side /= np.linalg.norm(side, axis=1, keepdims=True)
    upv = np.cross(T, side)
    ring = P[:, None, :] + S[None, :, 0:1] * side[:, None, :] + S[None, :, 1:2] * upv[:, None, :]
    b0 = S[:, 1].min()
    for end, sgn in ((0, -1.0), (len(P) - 1, 1.0)):
        ring[end] += sgn * slant[0 if end == 0 else 1] * (S[:, 1] - b0)[:, None] * T[end][None, :]
    closed = np.concatenate([ring, ring[:, :1]], axis=1)
    u = G.arclen(np.concatenate([S, S[:1]]))
    v = G.arclen(P)
    uv = np.stack(np.broadcast_arrays(u[None, :], v[:, None]), axis=2)
    m = G.surface(closed, uv)
    fn, fc = G.face_normals(m)
    nearest = P[np.argmin(np.linalg.norm(fc[:, None, :] - P[None, :, :], axis=2), axis=1)]
    if np.sum(np.einsum("ij,ij->i", fn, fc - nearest)) < 0:
        m.flip()
    if caps:
        k = len(S)
        for end, sgn in ((0, -1.0), (len(P) - 1, 1.0)):
            n0 = len(m.v)
            m.add(Mesh(ring[end], [], S.copy()))
            f = tuple(range(n0, n0 + k))
            a, b, c = m.v[n0], m.v[n0 + 1], m.v[n0 + 2]
            nrm = np.cross(b - a, c - a)
            if np.dot(nrm, T[end] * sgn) < 0:
                f = f[::-1]
            m.f.append(f)
    return m


def cbox(size, center=(0, 0, 0), chamfer=0.02):
    """Box with chamfered edges along its length (x) - a timber or a stone block."""
    sx, sy, sz = size
    c = np.asarray(center, dtype=float)
    return beam([c - (sx / 2, 0, 0), c + (sx / 2, 0, 0)], section_rect(sz, sy, chamfer))


def prism(outline, y0, y1):
    """Vertical prism over a closed outline [(x, z), ...] (caps included)."""
    O = np.asarray(outline, dtype=float)
    k = len(O)
    rings = [np.stack([O[:, 0], np.full(k, y), O[:, 1]], 1) for y in (y0, y1)]
    closed = [np.concatenate([r, r[:1]]) for r in rings]
    u = G.arclen(np.concatenate([O, O[:1]]))
    uv = np.stack(np.broadcast_arrays(u[None, :], np.array([0.0, y1 - y0])[:, None]), axis=2)
    m = G.surface(np.array(closed), uv)
    G.orient_radial(m, O[:, 0].mean(), O[:, 1].mean(), True)
    for y, d in ((y0, -1.0), (y1, 1.0)):
        n0 = len(m.v)
        m.add(Mesh(np.stack([O[:, 0], np.full(k, y), O[:, 1]], 1), [], O.copy()))
        f = tuple(range(n0, n0 + k))
        a, b, c = m.v[n0], m.v[n0 + 1], m.v[n0 + 2]
        if np.cross(b - a, c - a)[1] * d < 0:
            f = f[::-1]
        m.f.append(f)
    return m


def hexagon(r, rot=0.0):
    return [(r * math.sin(math.radians(rot + 60 * i)), -r * math.cos(math.radians(rot + 60 * i))) for i in range(6)]


def lathe(profile, segs=6, a0=-180.0):
    """A solid of revolution closed at both ends (profile bottom to top, starting and ending on
    the axis); segs=6 gives the hexagonal stonework of a lantern."""
    return G.revolve(profile, a0=a0, a1=a0 + 360.0, segs=segs)


# ================================================================== torii
TORII_W = 5.8          # between the pillars' feet (centres)
TORII_LEAN = 0.14      # each pillar leans in this much over its height (uchikorobi)


def torii():
    """A myojin torii, vermilion lacquer with black kasagi and feet, on stone footings; its plaque
    reads 月門 (Moon Gate). Front (+z) faces the plaza."""
    parts = []
    H = 7.0                                      # pillar tops (under the shimaki)
    x_foot = TORII_W / 2.0

    def pillar_x(y):
        return x_foot - TORII_LEAN * y / H

    for sx in (-1.0, 1.0):
        ys = np.linspace(0.3, H + 0.05, 14)
        path = np.stack([sx * np.array([pillar_x(y) for y in ys]), ys, np.zeros_like(ys)], 1)
        r = 0.31 - 0.05 * (ys / H)
        parts.append(Part(tube(path, r, segs=24, tile=1.0), "lacquer_red"))
        # the black sleeve at the foot, a bead at its top, and the stone footing
        ys2 = np.array([0.3, 1.05])
        p2 = np.stack([sx * np.array([pillar_x(y) for y in ys2]), ys2, np.zeros(2)], 1)
        parts.append(Part(tube(p2, 0.355, segs=24, caps=True), "lacquer_black"))
        p3 = np.stack([sx * np.array([pillar_x(1.05)] * 2), [1.05, 1.1], np.zeros(2)], 1)
        parts.append(Part(tube(p3, np.array([0.345, 0.325]), segs=24, caps=True), "lacquer_black"))
        foot = lathe([(0.0, -0.1), (0.62, -0.1), (0.62, 0.12), (0.56, 0.24), (0.44, 0.31), (0.0, 0.31)], segs=28)
        foot.translate((sx * x_foot, 0.0, 0.0))
        parts.append(Part(foot, "stone"))
        # daiwa: the ring where the pillar meets the shimaki
        p4 = np.stack([sx * np.array([pillar_x(H - 0.25)] * 2), [H - 0.25, H + 0.02], np.zeros(2)], 1)
        parts.append(Part(tube(p4, np.array([0.305, 0.33]), segs=24, caps=True), "lacquer_red"))
    # nuki: the tie beam through the pillars, its ends standing proud, wedges beside the pillars
    y_nuki = 5.45
    parts.append(Part(beam([(-4.0, y_nuki, 0.0), (4.0, y_nuki, 0.0)], section_rect(0.3, 0.5, 0.03)), "lacquer_red"))
    for sx in (-1.0, 1.0):
        xw = sx * (pillar_x(y_nuki) + 0.3 + 0.08)
        parts.append(Part(cbox((0.16, 0.32, 0.36), (xw, y_nuki, 0.0), 0.015), "lacquer_black"))
    # shimaki and kasagi: the double lintel, sweeping up toward its ends (sori)
    L = 5.3

    def sori(x):
        return 0.42 * (abs(x) / L) ** 2.3

    xs = np.linspace(-4.75, 4.75, 41)
    y_sh = H + 0.2
    parts.append(Part(beam(np.stack([xs, y_sh + np.array([sori(x) for x in xs]), np.zeros_like(xs)], 1),
                           section_rect(0.42, 0.4, 0.03)), "lacquer_red"))
    xs = np.linspace(-L, L, 49)
    y_ka = y_sh + 0.2 + 0.24
    parts.append(Part(beam(np.stack([xs, y_ka + np.array([sori(x) for x in xs]) * 1.05, np.zeros_like(xs)], 1),
                           section_rect(0.5, 0.48, 0.035, top_w=0.66), slant=(0.35, 0.35)), "lacquer_black"))
    # gakuzuka: the strut between nuki and shimaki, and the plaque hung on it
    y0, y1 = y_nuki + 0.25, y_sh - 0.2
    parts.append(Part(cbox((0.36, y1 - y0, 0.26), (0.0, (y0 + y1) / 2, 0.0), 0.02), "lacquer_red"))
    parts.extend(plaque_parts(((y0 + y1) / 2) - 0.02, 0.17))
    return parts


def plaque_parts(yc, z0, w=0.84, h=1.4, t=0.12, tilt=7.0):
    """The gaku: a black lacquered board whose face (+z) carries the plaque texture (UV 0..1 over
    the face), leaning out at the top."""
    body = cbox((t, h, w), (0.0, 0.0, 0.0), 0.02)
    body.rotate("y", 90.0)                      # length along z -> depth t along z, width w along x
    body.translate((0.0, 0.0, t / 2.0))
    face = Mesh([(-w / 2 + 0.01, -h / 2 + 0.01, t + 0.002), (w / 2 - 0.01, -h / 2 + 0.01, t + 0.002),
                 (w / 2 - 0.01, h / 2 - 0.01, t + 0.002), (-w / 2 + 0.01, h / 2 - 0.01, t + 0.002)],
                [(0, 1, 2, 3)], [(0, 1), (1, 1), (1, 0), (0, 0)])     # the image's top row at v = 0
    out = []
    for m, mat in ((body, "lacquer_black"), (face, "plaque")):
        m.rotate("x", tilt)
        m.translate((0.0, yc, z0))
        out.append(Part(m, mat))
    return out


# ================================================================== shrine
def grid(P, U, V, up=None):
    """A surface from a (rows, cols, 3) point grid with (rows, cols) u and v in metres; flipped so
    its normals lean toward `up` if given."""
    m = G.surface(np.asarray(P, dtype=float), np.stack([U, V], 2))
    if up is not None:
        G.orient_dir(m, up)
    return m


SH_EX, SH_EZ = 6.3, 4.8      # half extents of the eave outline
SH_YE = 4.5                  # eave height at the middle of a side (above the hall's base)
SH_DG = 1.9                  # how far the hips climb before the gables begin
SH_WX, SH_WZ = 4.5, 3.0      # the walls (post centres)


def roof_rise(d):
    """Height of the roof above its eave at d metres in from the eave: shallow at the eave,
    steepening toward the ridge (the curve of a Japanese roof)."""
    return 0.3 * d + 0.12 * d * d


def roof_lift(x, z):
    """The corners sweep up (sori): most at the eave corners, fading within ~4 m of them."""
    dc = np.hypot(SH_EX - np.abs(x), SH_EZ - np.abs(z))
    return 0.5 * np.clip(1.0 - dc / 4.2, 0.0, 1.0) ** 2.2


def roof_y(x, z, d):
    return SH_YE + roof_rise(d) + roof_lift(x, z)


def irimoya():
    """The hall's hip-and-gable roof (irimoya): copper sheet on four curved slopes, gables of dark
    boards, the eave's thick edge and its underside back to the walls. Returns parts."""
    parts = []
    xg = SH_EX - SH_DG
    nu, nv = 36, 10
    # lower slopes: front/back run along x, the hip ends along z; rows climb by depth d
    for sgn in (1.0, -1.0):
        d = np.linspace(0.0, SH_DG, nv + 1)[:, None]
        t = np.linspace(-1.0, 1.0, nu + 1)[None, :]
        X = t * (SH_EX - d)
        Z = np.broadcast_to(sgn * (SH_EZ - d), X.shape)
        Y = roof_y(X, Z, d)
        P = np.stack([X, Y, Z], 2)
        V = np.cumsum(np.concatenate([np.zeros((1, nu + 1)), np.linalg.norm(np.diff(P, axis=0), axis=2)]), axis=0)
        parts.append(Part(grid(P, X, V, (0, 1, 0)), "copper"))
        Z = t * (SH_EZ - d)
        X = np.broadcast_to(sgn * (SH_EX - d), Z.shape)
        Y = roof_y(X, Z, d)
        P = np.stack([X, Y, Z], 2)
        V = np.cumsum(np.concatenate([np.zeros((1, nu + 1)), np.linalg.norm(np.diff(P, axis=0), axis=2)]), axis=0)
        parts.append(Part(grid(P, Z, V, (0, 1, 0)), "copper"))
        # upper slope, front or back, to the ridge
        d = np.linspace(SH_DG, SH_EZ, 14)[:, None]
        X = np.broadcast_to(np.linspace(-xg, xg, nu + 1)[None, :], (14, nu + 1))
        Z = np.broadcast_to(sgn * (SH_EZ - d), X.shape)
        Y = roof_y(X, Z, d)
        P = np.stack([X, Y, Z], 2)
        V = SH_DG * 1.3 + np.cumsum(np.concatenate([np.zeros((1, nu + 1)), np.linalg.norm(np.diff(P, axis=0), axis=2)]), axis=0)
        parts.append(Part(grid(P, X, V, (0, 1, 0)), "copper"))
    # gables: from the top of the hip up to the roof line
    zg = SH_EZ - SH_DG
    for sx in (1.0, -1.0):
        zs = np.linspace(-zg, zg, 25)
        bot = roof_y(sx * xg, zs, SH_DG)
        top = roof_y(sx * xg, zs, SH_EZ - np.abs(zs))
        fr = np.linspace(0.0, 1.0, 8)[:, None]
        Y = bot[None, :] * (1 - fr) + top[None, :] * fr
        Z = np.broadcast_to(zs[None, :], Y.shape)
        X = np.full(Y.shape, sx * (xg - 0.02))
        parts.append(Part(grid(np.stack([X, Y, Z], 2), Z, Y, (sx, 0, 0)), "wood"))
        # bargeboards along the gable's roof line, crossing above the ridge as chigi
        zz = np.concatenate([np.linspace(zg + 0.25, 0.0, 16), [-0.6, -1.25]])
        yy = roof_y(sx * xg, np.abs(zz), SH_EZ - np.abs(zz))
        yy[-2:] = yy[-3] + (yy[-3] - yy[-4]) / (zz[-3] - zz[-4]) * (zz[-2:] - zz[-3])
        for zsgn in (1.0, -1.0):
            path = np.stack([np.full(len(zz), sx * (xg + 0.06)), yy + 0.12, zz * zsgn], 1)
            parts.append(Part(beam(path, section_rect(0.12, 0.34, 0.015), up=(0.0, 1.0, 0.0)), "wood"))
    # the thick eave edge and its underside
    loop = eave_loop()
    y_edge = 0.32
    lower = loop - np.array([0.0, y_edge, 0.0])
    fascia = G.loft([loop, lower], closed=True)
    parts.append(Part(fascia, "wood"))
    inner = rect_loop(SH_WX + 0.15, SH_WZ + 0.15, EAVE_K[0], EAVE_K[1], 4.85)
    soffit = G.loft([lower, inner], closed=True)
    G.orient_dir(soffit, (0, -1, 0))
    parts.append(Part(soffit, "rafters"))
    # the ridge, its end boards, and the logs across it (katsuogi)
    yr = roof_y(0.0, 0.0, SH_EZ)
    parts.append(Part(cbox((2 * xg + 0.5, 0.55, 0.5), (0.0, yr + 0.18, 0.0), 0.04), "copper"))
    for sx in (1.0, -1.0):
        parts.append(Part(cbox((0.3, 0.9, 0.75), (sx * (xg + 0.2), yr + 0.3, 0.0), 0.04), "copper"))
    for x in (-3.0, -1.5, 0.0, 1.5, 3.0):
        p = np.array([[x, yr + 0.62, -0.72], [x, yr + 0.62, 0.72]])
        parts.append(Part(tube(p, 0.15, segs=12, caps=True, tile=0.6), "wood"))
    return parts


def rect_loop(hx, hz, k_x, k_z, y):
    """Points round a rectangle (half extents hx, hz) at height y: 2 k_x along the front and back,
    2 k_z along the sides, corners on samples, starting at the front middle and heading -x."""
    pts = []
    for i in range(2 * k_x):
        pts.append((hx - hx * i / k_x, hz))
    for i in range(2 * k_z):
        pts.append((-hx, hz - hz * i / k_z))
    for i in range(2 * k_x):
        pts.append((-hx + hx * i / k_x, -hz))
    for i in range(2 * k_z):
        pts.append((hx, -hz + hz * i / k_z))
    P = np.roll(np.array(pts), -k_x, axis=0)
    return np.stack([P[:, 0], np.full(len(P), float(y)), P[:, 1]], 1)


EAVE_K = (24, 18)


def eave_loop():
    """The eave's outline: the rectangle of the eave with its corners swept up."""
    P = rect_loop(SH_EX, SH_EZ, EAVE_K[0], EAVE_K[1], 0.0)
    P[:, 1] = SH_YE + roof_lift(P[:, 0], P[:, 2])
    return P


def shrine_hall():
    """The shrine's hall (haiden), front (+z) toward the plaza: a stone footing, a raised veranda
    with a railing and steps, vermilion posts and beams, plaster walls, lattice doors that glow
    from within, a straw rope across the front, and the irimoya roof. Base at y = 0."""
    parts = [Part(cbox((11.8, 0.6, 8.8), (0.0, 0.25, 0.0), 0.04), "stone")]
    parts.append(Part(cbox((10.9, 0.28, 7.9), (0.0, 0.68, 0.0), 0.02), "wood"))
    parts.append(Part(cbox((11.2, 0.12, 8.2), (0.0, 0.86, 0.0), 0.015), "wood"))
    xs = [-4.5, -2.7, -0.9, 0.9, 2.7, 4.5]
    posts = [(x, z) for x in xs for z in (-SH_WZ, SH_WZ)] + [(x, z) for x in (-SH_WX, SH_WX) for z in (-1.0, 1.0)]
    for x, z in posts:
        parts.append(Part(tube(np.array([[x, 0.9, z], [x, 4.05, z]]), 0.16, segs=14, tile=0.5), "lacquer_red"))
        parts.append(Part(cbox((0.36, 0.2, 0.36), (x, 4.12, z), 0.02), "lacquer_red"))
    # beams round the walls: sill, door head, wall plate
    for y, hgt, dep in ((1.0, 0.2, 0.2), (3.15, 0.22, 0.2), (3.95, 0.3, 0.24)):
        for z in (-SH_WZ, SH_WZ):
            parts.append(Part(cbox((2 * SH_WX + 0.4, hgt, dep), (0.0, y, z), 0.02), "lacquer_red"))
        for x in (-SH_WX, SH_WX):
            b = cbox((2 * SH_WZ + 0.4, hgt, dep), (0.0, y, 0.0), 0.02)
            b.rotate("y", 90.0).translate((x, 0.0, 0.0))
            parts.append(Part(b, "lacquer_red"))
    # the band of brackets under the eaves
    parts.append(Part(cbox((2 * SH_WX + 0.3, 0.75, 2 * SH_WZ + 0.3), (0.0, 4.5, 0.0), 0.02), "wood"))
    for x in xs:
        for z in (-SH_WZ - 0.12, SH_WZ + 0.12):
            parts.append(Part(cbox((0.3, 0.22, 0.3), (x, 4.62, z), 0.02), "lacquer_red"))
    # front: lattice doors in the middle three bays, plaster either side; lattice transoms above
    for i in range(5):
        xc = -3.6 + 1.8 * i
        mat = "shoji" if 1 <= i <= 3 else "plaster"
        parts.append(Part(panel(xc, 1.1, 3.04, 1.5, SH_WZ), mat))
        parts.append(Part(panel(xc, 3.26, 3.8, 1.5, SH_WZ), "ranma"))
        parts.append(Part(panel(xc, 1.1, 3.8, 1.5, -SH_WZ, back=True), "plaster"))
    for x in (-SH_WX, SH_WX):
        for zc in (-2.0, 0.0, 2.0):
            m = panel(zc, 1.1, 3.8, 1.7, 0.0)
            m.rotate("y", 90.0 if x > 0 else -90.0).translate((x, 0.0, 0.0))
            parts.append(Part(m, "plaster"))
    # veranda railing, open at the steps
    rail_y = (1.2, 1.48)
    for z in (-3.95, 3.95):
        for x0, x1 in ((-5.45, -1.45), (1.45, 5.45)) if z > 0 else ((-5.45, 5.45),):
            for y in rail_y:
                parts.append(Part(cbox((x1 - x0, 0.07, 0.08), ((x0 + x1) / 2, y, z), 0.01), "lacquer_red"))
            for x in np.linspace(x0, x1, max(2, int(round((x1 - x0) / 1.35)) + 1)):
                parts.append(Part(cbox((0.11, 0.66, 0.11), (x, 1.24, z), 0.01), "lacquer_red"))
    for x in (-5.45, 5.45):
        for y in rail_y:
            b = cbox((7.9, 0.07, 0.08), (0.0, y, 0.0), 0.01)
            b.rotate("y", 90.0).translate((x, 0.0, 0.0))
            parts.append(Part(b, "lacquer_red"))
    # steps up to the veranda
    for k in range(5):
        y = 0.18 * (k + 1)
        z = 4.1 + 0.34 * (4 - k) + 0.17
        parts.append(Part(cbox((2.7, 0.07, 0.36), (0.0, y - 0.035, z), 0.01), "wood"))
    for x in (-1.42, 1.42):
        path = np.array([[x, 0.1, 5.95], [x, 0.98, 4.05]])
        parts.append(Part(beam(path, section_rect(0.1, 0.3, 0.015)), "lacquer_red"))
    # the rope (shimenawa) sagging across the front, with zigzag paper streamers
    xs_r = np.linspace(-2.75, 2.75, 23)
    rope = np.stack([xs_r, 3.72 - 0.22 * (1.0 - (xs_r / 2.75) ** 2), np.full_like(xs_r, SH_WZ + 0.3)], 1)
    parts.append(Part(tube(rope, 0.1 + 0.035 * (1.0 - (xs_r / 2.75) ** 2), segs=10, caps=True, tile=0.4), "rope"))
    for x in (-1.8, -0.6, 0.6, 1.8):
        parts.append(Part(shide(x, float(3.72 - 0.22 * (1.0 - (x / 2.75) ** 2)) - 0.1, SH_WZ + 0.36), "shide"))
    parts.extend(irimoya())
    return parts


def panel(xc, y0, y1, w, z, back=False):
    """A flat wall panel facing +z (or -z), UV in metres from its lower left."""
    hw = w / 2.0
    m = Mesh([(xc - hw, y0, z), (xc + hw, y0, z), (xc + hw, y1, z), (xc - hw, y1, z)], [(0, 1, 2, 3)],
             [(0.0, 0.0), (w, 0.0), (w, y1 - y0), (0.0, y1 - y0)])
    if back:
        m.flip()
    return m


def shide(x, y, z, n=4, w=0.09, step=0.13):
    """A zigzag paper streamer hanging from y."""
    m = Mesh()
    for i in range(n):
        off = (0.05 if i % 2 else -0.05)
        ya, yb = y - step * i, y - step * (i + 1)
        m.add(Mesh([(x + off - w / 2, yb, z), (x + off + w / 2, yb, z), (x + off + w / 2, ya, z), (x + off - w / 2, ya, z)],
                   [(0, 1, 2, 3)], [(0, 0), (1, 0), (1, 1), (0, 1)]))
    return m


def terrace():
    """The raised court the shrine stands on: dry-laid stone walls (ishigaki) leaning back, coping
    along the top, a flight of stone steps up from the approach, white gravel on top.
    World coordinates."""
    parts = []
    y_top, z_front, hx, z_back = 2.4, -33.0, 15.0, -60.0
    lean = 0.16                                  # the wall leans back this much per metre of height
    y0 = -0.4

    def wall_face(p0, p1, outward):
        # a battered wall between two plan points, split into a grid for the occlusion bake
        n = max(2, int(np.linalg.norm(np.subtract(p1, p0)) / 0.75))
        t = np.linspace(0.0, 1.0, n + 1)[None, :]
        hh = np.linspace(y0, y_top, 5)[:, None]
        o = np.asarray(outward, dtype=float)
        base = np.asarray(p0)[None, None, :] * (1 - t[..., None]) + np.asarray(p1)[None, None, :] * t[..., None]
        X = base[..., 0] - o[0] * lean * (hh - y0)
        Z = base[..., 1] - o[1] * lean * (hh - y0)
        Y = np.broadcast_to(hh, X.shape)
        U = np.broadcast_to(t * np.linalg.norm(np.subtract(p1, p0)), X.shape)
        V = np.broadcast_to((hh - y0) * math.sqrt(1 + lean * lean), X.shape)
        return grid(np.stack([X, Y, Z], 2), U, V, (o[0], 0.0, o[1]))

    parts.append(Part(wall_face((-hx, z_front), (-2.45, z_front), (0, 1)), "ishigaki"))
    parts.append(Part(wall_face((2.45, z_front), (hx, z_front), (0, 1)), "ishigaki"))
    for sx in (-1.0, 1.0):
        parts.append(Part(wall_face((sx * hx, z_front), (sx * hx, z_back), (sx, 0)), "ishigaki"))
    # gravel on top
    xs = np.linspace(-hx + lean * (y_top - y0), hx - lean * (y_top - y0), 31)
    zs = np.linspace(z_front - lean * (y_top - y0), z_back, 28)
    X, Z = np.meshgrid(xs, zs)
    parts.append(Part(grid(np.stack([X, np.full_like(X, y_top), Z], 2), X, Z, (0, 1, 0)), "gravel"))
    # coping along the front edge (either side of the steps)
    zc = z_front - lean * (y_top - y0) + 0.05
    for x0, x1 in ((-hx + 0.4, -2.45), (2.45, hx - 0.4)):
        n = int(round((x1 - x0) / 0.9))
        for i in range(n):
            a, b = x0 + (x1 - x0) * i / n, x0 + (x1 - x0) * (i + 1) / n
            parts.append(Part(cbox((b - a - 0.02, 0.28, 0.62), ((a + b) / 2, y_top + 0.1, zc - 0.2), 0.035), "stone"))
    # the steps: twelve risers from the approach up to the court, walled either side
    n = 12
    rise = y_top / n
    run = 0.38
    z_bot = zc + n * run
    for k in range(n):
        y = rise * (k + 1)
        z = z_bot - run * k - run / 2
        parts.append(Part(cbox((4.4, rise + 0.08, run + 0.06), (0.0, y - (rise + 0.08) / 2, z), 0.025), "stone"))
    for sx in (-1.0, 1.0):
        x = sx * 2.5
        parts.append(Part(slanted_block(x - 0.3, x + 0.3, z_bot + 0.15, zc - 0.3, y0, 0.45, y_top + 0.45), "ishigaki"))
        parts.append(Part(slanted_cap(x, 0.66, z_bot + 0.2, zc - 0.3, 0.45, y_top + 0.45), "stone"))
    return parts


def slanted_block(x0, x1, z0, z1, yb, yt0, yt1):
    """A block from yb up to a top sloping from yt0 (at z0) to yt1 (at z1)."""
    V = [(x0, yb, z0), (x1, yb, z0), (x1, yb, z1), (x0, yb, z1),
         (x0, yt0, z0), (x1, yt0, z0), (x1, yt1, z1), (x0, yt1, z1)]
    m = Mesh()
    quads = [(0, 1, 5, 4), (1, 2, 6, 5), (2, 3, 7, 6), (3, 0, 4, 7), (4, 5, 6, 7), (3, 2, 1, 0)]
    for q in quads:
        pts = np.array([V[i] for i in q])
        e1 = pts[1] - pts[0]
        e2 = pts[3] - pts[0]
        uv = [(0.0, 0.0), (np.linalg.norm(e1), 0.0), (np.linalg.norm(e1), np.linalg.norm(e2)), (0.0, np.linalg.norm(e2))]
        f = Mesh(pts, [(0, 1, 2, 3)], uv)
        c = pts.mean(axis=0)
        n, _ = G.face_normals(f)
        if np.dot(n[0], c - np.array([(x0 + x1) / 2, (yb + max(yt0, yt1)) / 2, (z0 + z1) / 2])) < 0:
            f.flip()
        m.add(f)
    return m


def slanted_cap(x, w, z0, z1, y0, y1):
    """Coping along the top of a stair wall."""
    path = np.array([[x, y0 + 0.08, z0], [x, y1 + 0.08, z1]])
    return beam(path, section_rect(w, 0.18, 0.03))


def approach_path(z0=-15.75, z1=None, width=3.0, seed=5):
    """Stone slabs laid in courses from the plaza's edge to the foot of the steps."""
    rng = np.random.default_rng(seed)
    z1 = -33.0 - 0.16 * 2.8 + 0.05 + 12 * 0.38 if z1 is None else z1
    parts = []
    z = z0
    row = 0
    while z > z1 + 0.1:
        dz = min(rng.uniform(0.55, 0.75), z - z1)
        x = -width / 2
        first = True
        while x < width / 2 - 0.05:
            w = rng.uniform(0.7, 1.3) * (0.6 if first and row % 2 else 1.0)
            w = min(w, width / 2 - x)
            if width / 2 - (x + w) < 0.35:
                w = width / 2 - x
            h = rng.uniform(0.0, 0.015)
            yaw = rng.normal(0.0, 0.6)
            b = cbox((w - 0.035, 0.12, dz - 0.035), (0.0, 0.0, 0.0), 0.025)
            b.rotate("y", yaw).translate((x + w / 2, -0.04 + h, z - dz / 2))
            parts.append(Part(b, "path_stone", rng.random()))
            x += w
            first = False
        z -= dz
        row += 1
    return parts


def approach():
    hall = shrine_hall()
    for p in hall:
        p.mesh.translate((0.0, 2.4, -44.0))
    return {"shrine": hall, "terrace": terrace(), "path": approach_path()}


# ================================================================== props
def lantern():
    """A hexagonal kasuga stone lantern, 2 m tall: footing, pole, platform, fire box (glowing paper
    between six corner posts), a roof with curled corners and a jewel on top."""
    parts = []
    stone = "lantern_stone"
    parts.append(Part(lathe([(0.0, 0.0), (0.4, 0.0), (0.4, 0.1), (0.37, 0.13), (0.29, 0.16), (0.25, 0.23),
                             (0.16, 0.27), (0.0, 0.27)]), stone))
    parts.append(Part(lathe([(0.0, 0.26), (0.125, 0.26), (0.118, 0.6), (0.142, 0.615), (0.142, 0.66),
                             (0.118, 0.675), (0.108, 1.0), (0.0, 1.0)], segs=16), stone))
    parts.append(Part(lathe([(0.0, 0.98), (0.12, 0.98), (0.17, 1.03), (0.29, 1.1), (0.31, 1.125), (0.31, 1.16),
                             (0.0, 1.16)]), stone))
    # the fire box: rails top and bottom, six corner posts, the paper within
    for y0, y1 in ((1.16, 1.2), (1.47, 1.51)):
        parts.append(Part(prism(hexagon(0.225), y0, y1), stone))
    for i in range(6):
        a = math.radians(-180.0 + 60.0 * i)
        cx, cz = 0.2 * math.sin(a), -0.2 * math.cos(a)
        parts.append(Part(prism(hexagon(0.04, rot=-180.0 + 60.0 * i), 1.2, 1.47).translate((cx, 0.0, cz)), stone))
    # the roof: a thin eave rising to a concave hip, then a curl up at each corner (warabite)
    parts.append(Part(lathe([(0.0, 1.51), (0.46, 1.51), (0.48, 1.555), (0.36, 1.6), (0.24, 1.66), (0.15, 1.73),
                             (0.1, 1.78), (0.0, 1.78)]), stone))
    for i in range(6):
        a = math.radians(-180.0 + 60.0 * i)
        d = np.array([math.sin(a), 0.0, -math.cos(a)])
        pts = [d * 0.44 + (0, 1.545, 0), d * 0.5 + (0, 1.575, 0), d * 0.515 + (0, 1.62, 0), d * 0.49 + (0, 1.645, 0)]
        parts.append(Part(tube(np.array(pts), np.array([0.03, 0.028, 0.025, 0.02]), segs=8, caps=True, tile=0.3),
                          stone))
    parts.append(Part(lathe([(0.0, 1.77), (0.1, 1.78), (0.11, 1.81), (0.07, 1.835), (0.075, 1.85), (0.092, 1.9),
                             (0.08, 1.95), (0.045, 1.99), (0.012, 2.02), (0.0, 2.025)], segs=14), stone))
    return parts


def lantern_paper():
    """The paper within the lantern's fire box: its own asset, so it casts no shadow over the
    light inside."""
    return [Part(prism(hexagon(0.17), 1.2, 1.47), "lantern_paper")]


def fence_post():
    """A granite post of the plaza fence: tapered, with a pyramidal cap."""
    m = beam([(0.0, 0.0, 0.0), (0.0, 0.9, 0.0)], section_rect(0.22, 0.22, 0.015), up=(0.0, 0.0, 1.0))
    cap = beam([(0.0, 0.9, 0.0), (0.0, 0.97, 0.0)], section_rect(0.28, 0.28, 0.012), up=(0.0, 0.0, 1.0))
    top = G.revolve([(0.2, 0.97), (0.0, 1.07)], segs=4, a0=-135.0, a1=225.0)
    return [Part(m, "fence_stone"), Part(cap, "fence_stone"), Part(top, "fence_stone")]


def fence_rail():
    """One metre of lacquered rail (scaled along x to fit between posts)."""
    return [Part(cbox((1.0, 0.1, 0.075), (0.0, 0.0, 0.0), 0.015), "lacquer_red")]


def props():
    return {"lantern": lantern(), "lantern_paper": lantern_paper(), "fence_post": fence_post(),
            "fence_rail": fence_rail()}


# ================================================================== backdrop
# The plaza sits on a wooded summit. To the east (+x) the wood stops at a cliff a few metres past
# the fence and the view opens over a sea of cloud (Scenery puts it at CLOUD_Y) to ranges of
# mountains; elsewhere the mountains show over the trees. scripts/world/scenery.gd repeats
# edge_radius() to keep the trees back from the drop.
VISTA_AT = 90.0        # degrees; 0 = +z, 90 = +x (the arena's angle convention)
VISTA_HALF = 42.0
EDGE_NEAR = 22.0       # the cliff's edge at the middle of the vista (plaza radius 15.6)
EDGE_FAR = 125.0       # the summit's edge elsewhere, deep in the wood


def edge_radius(a_deg):
    """Distance from the plaza's centre to the summit's edge at angle a (degrees)."""
    d = (np.asarray(a_deg, dtype=float) - VISTA_AT + 180.0) % 360.0 - 180.0
    t = np.clip(np.abs(d) / VISTA_HALF, 0.0, 1.0)
    w = 0.5 + 0.5 * np.cos(np.pi * t)               # 1 at the middle of the vista, 0 at its sides
    wob = 1.6 * np.sin(np.radians(a_deg) * 7.0 + 1.3) + 0.9 * np.sin(np.radians(a_deg) * 13.0 + 0.4)
    return EDGE_FAR + (EDGE_NEAR - EDGE_FAR) * w ** 0.6 + wob * w


def terrain():
    """The summit round the plaza: flat wood floor out to edge_radius(), then a broken rock face
    falling away (below the clouds). Polar grid from just under the plaza's rim."""
    n_a = 360
    a = np.linspace(0.0, 360.0, n_a + 1)
    r0, r_max = 15.45, 150.0
    rs = [r0]
    while rs[-1] < r_max:
        rs.append(rs[-1] + min(0.45 + 0.06 * (rs[-1] - r0), 6.0))
    rs = np.array(rs)
    re = edge_radius(a)
    A, Rr = np.meshgrid(np.radians(a), rs)
    E = np.broadcast_to(re[None, :], Rr.shape)
    flat = np.stack([np.sin(A) * Rr, np.zeros_like(Rr), np.cos(A) * Rr], 2).reshape(-1, 3)
    nz = (noise3(flat, 3, 9.0, 3, 12) + 0.5 * noise3(flat, 4, 2.5, 2, 12)).reshape(Rr.shape)
    # the drop: a lip, a steep broken face, and on down under the clouds
    x = (Rr - E) / 7.0
    drop = np.where(x > 0, -62.0 * (1.0 - np.exp(-x * 1.2)) - 2.0 * x, 0.0)
    rough = np.clip(x + 0.3, 0.0, 1.0) * nz * 2.2
    und = 0.18 * nz * np.clip((Rr - 19.0) / 6.0, 0.0, 1.0)
    Y = -0.06 + drop + rough + und
    Rd = Rr + np.clip(x, 0.0, 1.0) * nz * 1.5                      # a ragged face, not a clean wall
    X = np.sin(A) * Rd
    Z = np.cos(A) * Rd
    P = np.stack([X, Y, Z], 2)
    m = grid(P, X, Z, (0, 1, 0))
    return {"terrain": [Part(m, "terrain")]}


def ridge_band(seed, dist, dist_var, crest, crest_var, front, back, base_y, peaks=(), n_a=720, n_r=16,
               layer=0.0, relief=0.25, material="mountains", jag=0.0):
    """One ring of mountains round the whole horizon as a polar height field: a crest line at
    distance dist(a) and height crest(a), slopes falling to base_y in front and behind, carved with
    ridged noise. peaks: (angle deg, extra height, width deg), cusped; jag: metres of fine
    raggedness along the crest. UV2.y carries `layer`."""
    rng = np.random.default_rng(seed)
    a = np.linspace(0.0, 2 * math.pi, n_a + 1)
    D = np.full_like(a, float(dist))
    H = np.full_like(a, float(crest))
    for k in range(1, 9):
        D += dist_var * rng.normal(0, 1) / k * np.sin(k * a + rng.uniform(0, 6.28))
        H += crest_var * rng.normal(0, 1) / k ** 0.8 * np.sin(k * a + rng.uniform(0, 6.28))
    for k in range(9, 90):
        H += jag * rng.normal(0, 1) / (k / 9.0) ** 0.9 * np.sin(k * a + rng.uniform(0, 6.28))
    for ang, hgt, wid in peaks:
        dd = np.abs(((np.degrees(a) - ang + 180.0) % 360.0) - 180.0)
        H += hgt * np.exp(-dd / wid)
    s = np.linspace(-1.0, 1.0, n_r + 1)[:, None]
    wdt = np.where(s < 0, front, back)
    Rr = D[None, :] + s * wdt
    prof = (1.0 - np.abs(s)) ** 1.7
    Y = base_y + (H[None, :] - base_y) * prof
    A = np.broadcast_to(a[None, :], Y.shape)
    flat = np.stack([np.sin(A) * Rr, np.zeros_like(Rr), np.cos(A) * Rr], 2).reshape(-1, 3)
    sc = float(dist) * 0.09
    rid = (1.0 - np.abs(noise3(flat, seed + 7, sc, 4, 12))).reshape(Y.shape)
    rid2 = (1.0 - np.abs(noise3(flat * np.array([1.0, 0.0, 1.0]) + Y.reshape(-1, 1) * np.array([0.0, 1.0, 0.0]),
                                seed + 8, sc * 0.35, 3, 12))).reshape(Y.shape)
    Y = Y + relief * (H[None, :] - base_y) * (0.7 * rid + 0.3 * rid2 - 0.6) * prof ** 0.6 * (1.0 - prof ** 3)
    A = np.broadcast_to(a[None, :], Y.shape)
    X = np.sin(A) * Rr
    Z = np.cos(A) * Rr
    P = np.stack([X, Y, Z], 2)
    U = A * float(dist)
    m = grid(P, U, np.broadcast_to(s, Y.shape) * 100.0, (0, 1, 0))     # a height field: normals up
    return Part(m, material, layer)


def mountains():
    far = ridge_band(71, 1200.0, 120.0, 250.0, 70.0, 420.0, 260.0, -150.0, n_a=1440, n_r=36, layer=2.0, relief=0.32,
                     material="range_far", jag=14.0,
                     peaks=((-160.0, 230.0, 4.0), (-128.0, 150.0, 3.0), (-95.0, 120.0, 5.0), (-60.0, 110.0, 4.0),
                            (-18.0, 160.0, 3.5), (15.0, 90.0, 5.0), (40.0, 250.0, 3.5), (72.0, 130.0, 4.0),
                            (98.0, 190.0, 3.0), (122.0, 110.0, 5.0), (150.0, 210.0, 4.0), (178.0, 120.0, 4.5)))
    mid = ridge_band(72, 560.0, 90.0, 45.0, 30.0, 170.0, 150.0, -80.0, n_a=1080, n_r=30, layer=1.0, relief=0.2,
                     material="range_mid", jag=7.0,
                     peaks=((70.0, 70.0, 5.0), (115.0, 55.0, 4.0), (-140.0, 60.0, 6.0), (-40.0, 45.0, 7.0),
                            (160.0, 50.0, 5.0), (20.0, 40.0, 6.0)))
    near = ridge_band(73, 230.0, 45.0, -8.0, 12.0, 70.0, 60.0, -60.0, n_a=540, n_r=24, layer=0.0, relief=0.2,
                      material="range_near", jag=2.5, peaks=((65.0, 22.0, 7.0), (110.0, 16.0, 6.0), (88.0, 10.0, 4.0)))
    return {"mountains_far": [far], "mountains_mid": [mid], "hills": [near]}


# ================================================================== Blender
def gltf_uv(uv):
    """Blender's glTF exporter writes (u, 1 - v); pre-flip so Godot reads the values we mean."""
    uv = np.array(uv, dtype=float)
    uv[:, 1] = 1.0 - uv[:, 1]
    return uv


def to_blender(name, parts, ao=None):
    """One object per asset: a material slot per material name, UVMap (metres) and data (AO,
    extra) UV layers, custom normals where the parts have them. ao: baked occlusion per vertex of
    the asset's solid (non-card) parts, in order; cards copy theirs from their source vertices."""
    import bpy
    from model3d import blender_io as B
    V, F, UV, EX, NR, MI = [], [], [], [], [], []
    mats = []
    base = 0
    any_custom = any(p.normals is not None for p in parts)
    for p in parts:
        m = p.mesh
        if p.material not in mats:
            mats.append(p.material)
        V.append(m.v)
        UV.append(m.uv)
        EX.append(p.extra)
        NR.append(p.normals if p.normals is not None else vertex_normals(m))
        F.extend([[base + i for i in f] for f in m.f])
        MI.extend([mats.index(p.material)] * len(m.f))
        base += len(m.v)
    V = np.concatenate(V)
    me = bpy.data.meshes.new(name)
    me.from_pydata(B.arr_to_bl(V).tolist(), [], F)
    me.validate(clean_customdata=False)
    obj = B.link(bpy.data.objects.new(name, me))
    for mn in mats:
        mat = bpy.data.materials.get(mn) or bpy.data.materials.new(mn)
        me.materials.append(mat)
    me.polygons.foreach_set("material_index", np.array(MI, dtype=np.int32))
    loops_v = np.zeros(len(me.loops), dtype=np.int64)
    me.loops.foreach_get("vertex_index", loops_v)
    uv0 = gltf_uv(np.concatenate(UV))
    l0 = me.uv_layers.new(name="UVMap")
    l0.data.foreach_set("uv", uv0[loops_v].astype(np.float32).reshape(-1))
    ex = np.concatenate(EX)
    occ = np.ones(len(V))
    if ao is not None:
        solid_base, base = {}, 0
        for p in parts:
            if not p.card:
                solid_base[id(p)] = base
                base += len(p.mesh.v)
        solid_ao = np.asarray(ao, dtype=float)
        at = 0
        for p in parts:
            n = len(p.mesh.v)
            if p.card:
                src = solid_ao[solid_base[id(p.ao_part)] + p.ao_src]
                occ[at:at + n] = 0.25 + 0.75 * src          # cards stand out of the clump: a little lighter
            else:
                occ[at:at + n] = solid_ao[solid_base[id(p)]:solid_base[id(p)] + n]
            at += n
    l1 = me.uv_layers.new(name="data")
    l1.data.foreach_set("uv", gltf_uv(np.stack([occ, ex], 1))[loops_v].astype(np.float32).reshape(-1))
    me.shade_smooth()
    if any_custom:
        nrm = B.arr_to_bl(np.concatenate(NR))
        me.normals_split_custom_set_from_vertices([tuple(n) for n in nrm])
    else:
        me.set_sharp_from_angle(angle=math.radians(50))
    obj["ex"] = 1
    return obj


def bake_ao(obj, distance, samples=48):
    """Cycles AO into a vertex colour, then into UV2.x (the data layer)."""
    import bpy
    from model3d import blender_io as B
    me = obj.data
    attr = me.color_attributes.new(name="ao", type="FLOAT_COLOR", domain="POINT")
    me.color_attributes.active_color = attr
    scn = bpy.context.scene
    world = scn.world or bpy.data.worlds.new("AO")
    scn.world = world
    world.light_settings.distance = distance
    scn.cycles.samples = samples
    scn.render.bake.target = "VERTEX_COLORS"
    B.activate(obj)
    bpy.ops.object.bake(type="AO")
    ao = np.zeros(len(me.vertices) * 4, dtype=np.float32)
    attr.data.foreach_get("color", ao)
    ao = ao.reshape(-1, 4)[:, 0]
    loops_v = np.zeros(len(me.loops), dtype=np.int64)
    me.loops.foreach_get("vertex_index", loops_v)
    lay = me.uv_layers["data"]
    buf = np.zeros(len(me.loops) * 2, dtype=np.float32)
    lay.data.foreach_get("uv", buf)
    buf = buf.reshape(-1, 2)
    buf[:, 0] = ao[loops_v]
    lay.data.foreach_set("uv", buf.reshape(-1))
    me.color_attributes.remove(attr)
    return ao


def export(objs, path):
    import bpy
    os.makedirs(os.path.dirname(path), exist_ok=True)
    for o in bpy.context.scene.objects:
        o.select_set(False)
    for o in objs:
        o.select_set(True)
    bpy.context.view_layer.objects.active = objs[0]
    bpy.ops.export_scene.gltf(filepath=path, export_format="GLB", use_selection=True, export_apply=True,
                              export_skins=False, export_animations=False, export_yup=True,
                              export_materials="EXPORT", export_vertex_color="NONE", export_texcoords=True,
                              export_normals=True, export_tangents=False, export_attributes=False,
                              export_extras=False)
    print("wrote %s (%.2f MB)" % (os.path.relpath(path, ROOT), os.path.getsize(path) / 1e6))


def build_family(fname, assets, ao_dist, args, spacing=12.0, views=None):
    """Builds and exports a family of assets (one glb, one object each), side by side while baking
    so they don't shade each other."""
    import bpy
    from model3d import blender_io as B
    B.reset_scene()
    aos = {}
    if not args.no_bake:
        tmp = []
        for i, (name, parts) in enumerate(assets.items()):
            solid = [p for p in parts if not p.card]
            obj = to_blender(name + "_bake", solid)
            obj.location.x = i * spacing
            tmp.append((name, obj))
        for name, obj in tmp:
            aos[name] = bake_ao(obj, ao_dist, args.samples)
        for _, obj in tmp:
            bpy.data.objects.remove(obj, do_unlink=True)
        bpy.context.view_layer.update()
    objs = []
    for i, (name, parts) in enumerate(assets.items()):
        obj = to_blender(name, parts, aos.get(name))
        objs.append(obj)
        print("  %s: %d verts" % (name, len(obj.data.vertices)))
    if args.preview:
        preview(fname, objs, spacing, views)
    export(objs, os.path.join(OUT, fname + ".glb"))


def preview(fname, objs, spacing, views=None):
    import bpy
    from model3d import blender_io as B
    cols = {"bark": (0.25, 0.15, 0.1), "foliage": (0.06, 0.13, 0.05), "rock": (0.3, 0.3, 0.3),
            "lacquer_red": (0.5, 0.06, 0.03), "lacquer_black": (0.03, 0.03, 0.03), "stone": (0.35, 0.34, 0.32),
            "lantern_stone": (0.4, 0.39, 0.37), "fence_stone": (0.35, 0.34, 0.32), "plaque": (0.6, 0.45, 0.15),
            "lantern_paper": (0.9, 0.7, 0.4), "copper": (0.2, 0.4, 0.35), "wood": (0.2, 0.12, 0.08)}
    for m in bpy.data.materials:
        key = next((k for k in cols if m.name.startswith(k)), None)
        m.use_nodes = True
        bsdf = m.node_tree.nodes.get("Principled BSDF")
        if bsdf is None:
            continue
        c = cols.get(key, (0.5, 0.2, 0.1))
        if m.name == "foliage_maple":
            c = (0.45, 0.06, 0.03)
        bsdf.inputs["Base Color"].default_value = (*c, 1.0)
    for i, o in enumerate(objs):
        o.location.x = i * spacing
    bpy.context.scene.view_settings.view_transform = "Standard"
    if views is None:
        # three assets to a view, from the front (azimuth 0 looks from -Z; +X is on the left)
        views = []
        per = 3
        for g in range(0, len(objs), per):
            idx = list(range(g, min(g + per, len(objs))))
            h = max(max(v.co.z for v in objs[i].data.vertices) for i in idx)
            cx = (idx[0] + idx[-1]) * 0.5 * spacing
            w = (len(idx) - 1) * spacing + spacing * 0.8
            d = max(h * 0.62 / math.tan(math.radians(20.0)), w * 0.5 / (math.tan(math.radians(20.0)) * 0.8))
            views.append((0, 4, d, (cx, h * 0.5, 0.0)))
    B.render_views(os.path.join(PREVIEW_DIR, "scenery_%s.png" % fname), views, size=(560, 700),
                   samples=16, fov=40.0, background=(0.5, 0.55, 0.65))
    for o in objs:
        o.location.x = 0.0


# ================================================================== textures
def write_textures():
    os.makedirs(TEX, exist_ok=True)
    a, n, _ = ST.bark_sugi()
    FT.save_rgb(os.path.join(TEX, "bark_sugi.jpg"), a, 90)
    FT.save_rgb(os.path.join(TEX, "bark_sugi_n.jpg"), n, 92)
    a, n, _ = ST.bark_pine()
    FT.save_rgb(os.path.join(TEX, "bark_pine.jpg"), a, 90)
    FT.save_rgb(os.path.join(TEX, "bark_pine_n.jpg"), n, 92)
    FT.save_rgba(os.path.join(TEX, "needles.png"), ST.needles())
    for kind, fn in (("sugi", ST.sugi_spray), ("pine", ST.pine_spray), ("maple", ST.maple_spray), ("shrub", ST.shrub_spray),
                     ("fern", ST.fern_spray)):
        FT.save_rgba(os.path.join(TEX, "spray_%s.png" % kind), fn())
    FT.save_rgba(os.path.join(TEX, "maple_leaves.png"), ST.maple_leaves())
    FT.save_rgb(os.path.join(TEX, "grime.png"), ST.grime())
    c, cn = ST.copper_roof()
    FT.save_rgb(os.path.join(TEX, "copper.jpg"), c, 90)
    FT.save_rgb(os.path.join(TEX, "copper_n.jpg"), cn, 92)
    a, n = ST.wood()
    FT.save_rgb(os.path.join(TEX, "wood.jpg"), a, 90)
    FT.save_rgb(os.path.join(TEX, "wood_n.jpg"), n, 92)
    a, n = ST.ishigaki()
    FT.save_rgba(os.path.join(TEX, "ishigaki.png"), a)
    FT.save_rgb(os.path.join(TEX, "ishigaki_n.jpg"), n, 92)
    a, n = ST.gravel()
    FT.save_rgb(os.path.join(TEX, "gravel.jpg"), a, 90)
    FT.save_rgb(os.path.join(TEX, "gravel_n.jpg"), n, 92)
    import gen_textures
    font, _ = gen_textures.fetch_font("yuji-boku")
    FT.save_rgba(os.path.join(TEX, "plaque.png"), ST.plaque(font))
    print("textures written")


FAMILIES = ["textures", "trees", "torii", "props", "approach", "backdrop"]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--only", nargs="*", default=None, help="families: " + " ".join(FAMILIES))
    ap.add_argument("--no-bake", action="store_true")
    ap.add_argument("--preview", action="store_true")
    ap.add_argument("--samples", type=int, default=48)
    args = ap.parse_args()
    todo = args.only or FAMILIES
    t0 = time.time()
    if "textures" in todo:
        write_textures()
    if "trees" in todo:
        build_family("trees", trees(), 1.6, args, spacing=12.0)
    if "torii" in todo:
        build_family("torii", {"torii": torii()}, 1.5, args, spacing=14.0)
    if "props" in todo:
        build_family("props", props(), 0.6, args, spacing=2.0)
    if "backdrop" in todo:
        assets = terrain()
        assets.update(mountains())
        a2 = argparse.Namespace(**vars(args))
        a2.no_bake = True
        build_family("backdrop", assets, 1.0, a2, spacing=0.0,
                     views=[(270, 3, 60.0, (0.0, 2.0, 0.0)), (270, 8, 400.0, (0.0, 20.0, 0.0)), (0, 35, 900.0, (0.0, 0.0, 0.0))])
    if "approach" in todo:
        build_family("approach", approach(), 2.0, args, spacing=0.0,
                     views=[(180, 10, 34, (0.0, 4.0, -36.0)), (140, 18, 22, (0.0, 5.5, -42.0)), (200, 4, 12, (0.0, 4.5, -40.0))])
    print("done (%.1fs)" % (time.time() - t0))


if __name__ == "__main__":
    main()
