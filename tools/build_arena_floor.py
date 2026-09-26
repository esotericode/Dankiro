#!/usr/bin/env python3
"""Builds the arena floor: models/arena_floor.glb (the flagstones, their mortar bed and a puddle)
and its textures in textures/floor/.

    pip install bpy==4.5.9 shapely              # Blender 4.5 LTS as a Python module (once)
    python3 tools/build_arena_floor.py          # layout, geometry, Cycles AO bake, textures (~2 min)
    python3 tools/build_arena_floor.py --no-bake    # flat AO (quick layout iterations)
    godot --headless --editor --quit            # import the new .glb and textures

The plaza keeps the old procedural floor's plan: a carved moon medallion at the centre, eight
wedge stones around it, twelve rings of flagstones and a raised basalt curb under the fence.
Every stone is a real slab with rounded, worn edges and a 12 mm joint down to a dark mortar
bed, set a few millimetres off level. Some are chipped, some cracked right through, one is
broken with its rubble lying in the hole, and a few settled stones hold a puddle.

Per-stone data rides in the second UV channel (id, stone type, crack decal, condition, and how
far a vertex is into the worn edge), so the Godot shader (shaders/flagstones.gdshader) can give
each stone its own texture offset, rotation, tint and wear. Cycles bakes ambient occlusion
(joints, curb, lantern and fence-post contact shadows) into plaza-wide masks alongside painted
dirt, moss, wetness, soot, polish and lichen.
"""
import argparse
import math
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import numpy as np  # noqa: E402
from PIL import Image, ImageDraw  # noqa: E402
from scipy import ndimage  # noqa: E402
from shapely import contains_xy  # noqa: E402
from shapely.geometry import LineString, Point, Polygon  # noqa: E402
from shapely.ops import polylabel, split as shp_split  # noqa: E402

from model3d import floor_textures as FT  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GLB = "models/arena_floor.glb"
TEX = "textures/floor"
PREVIEW_DIR = os.path.join(ROOT, "tools", "preview_out")

# ------------------------------------------------------------------ plan (metres; game space:
# x right, z toward the player's start, y up; angle a puts a point at (sin a, cos a) * r)
R_MED = 0.72
R_WEDGE = 1.55
R_CURB = 14.85
R_PLAZA = 15.6
N_RINGS = 12
TILE_ARC = 1.22          # target stone length along a ring
ARC_SEG = 0.15           # arc discretisation
GAP = 0.012              # joint width
Y_BED = -0.026
Y_SIDE = -0.05
CURB_TOP = 0.022
WATER_Y = -0.004
K_BEVEL = 3              # segments in a stone's rounded edge
MAP = 32.0               # plaza masks span [-16, 16] in x and z
LANTERN_R = R_PLAZA - 1.1
POST_R = R_PLAZA - 0.2
LANTERNS = [(math.sin(a) * LANTERN_R, math.cos(a) * LANTERN_R) for a in ((i + 0.5) / 8 * 2 * math.pi for i in range(8))]
POSTS = [2 * math.pi * i / 36 for i in range(36)]
PUDDLE_C = (-3.7, -8.2)
PUDDLE_R = (1.0, 0.6)
PUDDLE_ANG = 0.45
MOSSY_AT = (7.5, -9.6)
BROKEN_AT = (-11.7, -4.4)

# stone types (the shader's palette) and conditions
GRANITE, SLATE, SANDSTONE, BASALT, MEDALLION = 0, 1, 2, 3, 4
NORMAL, NEW, WORN = 0, 1, 2
JOINT, CRACK, BREAK = 0, 1, 2


class Stone:
    def __init__(self, poly, labels, kind, stype, axes, cond=NORMAL):
        self.poly = np.asarray(poly, dtype=float)
        self.labels = list(labels)          # per edge: (inset, bevel, edge kind)
        self.kind = kind
        self.stype = stype
        self.cond = cond
        self.axes = axes                    # (centre, tangent axis, radial axis) for the local UV
        self.crack = 0                      # hairline decal 1..4
        self.h0 = 0.0
        self.grad = np.zeros(2)
        self.bottom = Y_SIDE
        self.pillow = 0.0012
        self.rim = 0.045
        self.id = -1
        self.tags = set()

    @property
    def centroid(self):
        return np.asarray(Polygon(self.poly).centroid.coords[0])

    def height(self, p):
        c = self.axes[0]
        return self.h0 + (p[..., 0] - c[0]) * self.grad[0] + (p[..., 1] - c[1]) * self.grad[1]

    def shape(self):
        return Polygon(self.poly)


# ------------------------------------------------------------------ polygon helpers
def signed_area(P):
    x, z = P[:, 0], P[:, 1]
    return 0.5 * float(np.sum(x * np.roll(z, -1) - np.roll(x, -1) * z))


def ccw(P, labels):
    if signed_area(P) < 0:
        P = P[::-1].copy()
        labels = list(np.roll(np.array(labels, dtype=object)[::-1], -1, axis=0))
        labels = [tuple(x) for x in labels]
    return P, labels


def arc(r, a0, a1):
    n = max(1, int(math.ceil(abs(a1 - a0) * r / ARC_SEG)))
    a = np.linspace(a0, a1, n + 1)
    return np.stack([r * np.sin(a), r * np.cos(a)], 1)


def from_groups(groups):
    """groups: [(points (k, 2), label)], each group's last point = the next group's first."""
    pts, labels = [], []
    for g, lab in groups:
        g = np.asarray(g, dtype=float)
        for i in range(len(g) - 1):
            pts.append(g[i])
            labels.append(lab)
    return ccw(np.array(pts), labels)


def seg_dist(p, a, b):
    ab = b - a
    t = np.clip(np.dot(p - a, ab) / max(np.dot(ab, ab), 1e-18), 0.0, 1.0)
    return float(np.linalg.norm(a + t * ab - p))


def relabel(shape, P, labels, cut_label):
    """Per-edge labels for a polygon produced by cutting (P, labels): edges lying on an old edge
    keep its label, new ones get cut_label."""
    Q = np.asarray(shape.exterior.coords)[:-1]
    out = []
    for j in range(len(Q)):
        a, b = Q[j], Q[(j + 1) % len(Q)]
        lab = cut_label
        for k in range(len(P)):
            p, q = P[k], P[(k + 1) % len(P)]
            if seg_dist(a, p, q) < 1e-6 and seg_dist(b, p, q) < 1e-6:
                lab = labels[k]
                break
        out.append(lab)
    return ccw(Q, out)


def pieces(geom):
    if geom.geom_type == "Polygon":
        return [geom]
    return [g for g in getattr(geom, "geoms", []) if g.geom_type == "Polygon"]


def offset_poly(P, d):
    """Mitre offset of a CCW polygon, inward by per-edge distances d (edge i: P[i] -> P[i+1])."""
    E = np.roll(P, -1, 0) - P
    T = E / np.linalg.norm(E, axis=1, keepdims=True)
    Nin = np.stack([-T[:, 1], T[:, 0]], 1)
    out = np.zeros_like(P)
    for i in range(len(P)):
        n1, n2 = Nin[i - 1], Nin[i]
        M = np.array([n1, n2])
        det = n1[0] * n2[1] - n1[1] * n2[0]
        if abs(det) < 1e-5:
            out[i] = P[i] + 0.5 * (n1 * d[i - 1] + n2 * d[i])
        else:
            out[i] = np.linalg.solve(M, [n1 @ P[i] + d[i - 1], n2 @ P[i] + d[i]])
    return out


def jagged(a, b, rng, amp, step=0.035, extend=0.25):
    a, b = np.asarray(a, float), np.asarray(b, float)
    d = b - a
    L = float(np.linalg.norm(d))
    u = d / L
    nrm = np.array([-u[1], u[0]])
    n = max(3, int(L / step))
    t = np.linspace(0.0, 1.0, n + 1)
    walk = np.cumsum(rng.normal(0.0, amp, n + 1))
    walk -= walk[0] + (walk[-1] - walk[0]) * t          # pinned at both ends
    pts = a[None] + t[:, None] * d[None] + walk[:, None] * nrm[None]
    pts = np.vstack([a - u * extend, pts, b + u * extend])
    return pts


def blob(c, r, ang, n=72, seed=0, wob=(0.13, 0.07, 0.04)):
    rng = np.random.default_rng(seed)
    ph = rng.uniform(0, 2 * math.pi, 3)
    t = np.linspace(0, 2 * math.pi, n, endpoint=False)
    k = 1.0 + wob[0] * np.sin(2 * t + ph[0]) + wob[1] * np.sin(3 * t + ph[1]) + wob[2] * np.sin(5 * t + ph[2])
    x = r[0] * np.cos(t) * k
    z = r[1] * np.sin(t) * k
    ca, sa = math.cos(ang), math.sin(ang)
    return np.stack([c[0] + x * ca - z * sa, c[1] + x * sa + z * ca], 1)


# ------------------------------------------------------------------ layout
def joint_label(rng, bevel):
    return (GAP * 0.5 + rng.uniform(-0.0022, 0.0022), bevel, JOINT)


def stone_bevel(rng, cond):
    if cond == NEW:
        return rng.uniform(0.004, 0.007)
    if cond == WORN:
        return rng.uniform(0.022, 0.030)
    return rng.uniform(0.012, 0.018)


def pick_type(rng):
    u = rng.random()
    return GRANITE if u < 0.84 else (SLATE if u < 0.94 else SANDSTONE)


def pick_cond(rng):
    u = rng.random()
    return NEW if u < 0.05 else (WORN if u < 0.17 else NORMAL)


def ring_axes(a, r):
    c = np.array([math.sin(a) * r, math.cos(a) * r])
    return (c, np.array([math.cos(a), -math.sin(a)]), np.array([math.sin(a), math.cos(a)]))


def layout(rng):
    stones = []
    # the medallion
    cond = NORMAL
    circ = arc(R_MED, 0.0, 2 * math.pi)
    P, L = from_groups([(circ, (GAP * 0.5, 0.012, JOINT))])
    stones.append(Stone(P, L, "medallion", MEDALLION, (np.zeros(2), np.array([1.0, 0.0]), np.array([0.0, 1.0])), cond))
    # eight wedges
    a0 = math.pi / 8
    for i in range(8):
        aa, ab = a0 + i * math.pi / 4, a0 + (i + 1) * math.pi / 4
        cond = pick_cond(rng) if i % 3 == 1 else NORMAL
        bev = stone_bevel(rng, cond)
        inner, outer = arc(R_MED, aa, ab), arc(R_WEDGE, ab, aa)
        P, L = from_groups([(inner, joint_label(rng, bev)), (np.array([inner[-1], outer[0]]), joint_label(rng, bev)),
                            (outer, joint_label(rng, bev)), (np.array([outer[-1], inner[0]]), joint_label(rng, bev))])
        am = 0.5 * (aa + ab)
        stones.append(Stone(P, L, "wedge", GRANITE if i % 2 == 0 else SLATE, ring_axes(am, 0.5 * (R_MED + R_WEDGE)), cond))
    # rings
    radii = np.linspace(R_WEDGE, R_CURB, N_RINGS + 1)
    for k in range(N_RINGS):
        r0, r1 = radii[k], radii[k + 1]
        rm = 0.5 * (r0 + r1)
        n = int(round(2 * math.pi * rm / TILE_ARC))
        wts = rng.uniform(0.7, 1.32, n)
        cum = np.concatenate([[0.0], np.cumsum(wts)]) / wts.sum() * 2 * math.pi
        phase = rng.uniform(0, 2 * math.pi)
        skew = rng.uniform(-0.04, 0.04, n) / rm
        joints = [(phase + cum[i] - 0.5 * skew[i], phase + cum[i] + 0.5 * skew[i]) for i in range(n)]
        joints.append((joints[0][0] + 2 * math.pi, joints[0][1] + 2 * math.pi))

        def ang(j, r):
            return j[0] + (j[1] - j[0]) * (r - r0) / (r1 - r0)

        for i in range(n):
            ja, jb = joints[i], joints[i + 1]
            spans = [(r0, r1)]
            if rng.random() < 0.06:                         # a short pair of stones across the ring
                rs = r0 + (r1 - r0) * rng.uniform(0.4, 0.6)
                spans = [(r0, rs), (rs, r1)]
            for ra, rb in spans:
                cond = pick_cond(rng)
                bev = stone_bevel(rng, cond)
                inner = arc(ra, ang(ja, ra), ang(jb, ra))
                outer = arc(rb, ang(jb, rb), ang(ja, rb))
                P, L = from_groups([(inner, joint_label(rng, bev)), (np.array([inner[-1], outer[0]]), joint_label(rng, bev)),
                                    (outer, joint_label(rng, bev)), (np.array([outer[-1], inner[0]]), joint_label(rng, bev))])
                am = 0.5 * (ang(ja, 0.5 * (ra + rb)) + ang(jb, 0.5 * (ra + rb)))
                st = Stone(P, L, "ring", pick_type(rng), ring_axes(am, 0.5 * (ra + rb)), cond)
                st.ring = k
                stones.append(st)
    # the curb: 72 basalt blocks, one fence post on every other block
    cj = np.radians(2.5 + 5.0 * np.arange(72) + rng.uniform(-0.35, 0.35, 72))
    cj = np.append(cj, cj[0] + 2 * math.pi)
    for i in range(72):
        aa, ab = cj[i], cj[i + 1]
        bev = rng.uniform(0.016, 0.024)
        inner, outer = arc(R_CURB, aa, ab), arc(R_PLAZA, ab, aa)
        outer_lab = (0.0, bev, JOINT)
        P, L = from_groups([(inner, joint_label(rng, bev)), (np.array([inner[-1], outer[0]]), joint_label(rng, bev)),
                            (outer, outer_lab), (np.array([outer[-1], inner[0]]), joint_label(rng, bev))])
        st = Stone(P, L, "curb", BASALT, ring_axes(0.5 * (aa + ab), 0.5 * (R_CURB + R_PLAZA)), NORMAL)
        st.bottom = -0.075
        stones.append(st)
    return stones


def find_stone(stones, p, kinds=("ring",)):
    q = Point(p)
    for st in stones:
        if st.kind in kinds and st.shape().contains(q):
            return st
    raise ValueError("no stone at %s" % (p,))


def replace(stones, st, new):
    i = stones.index(st)
    stones[i:i + 1] = new


def clone(st, P, L):
    s = Stone(P, L, st.kind, st.stype, st.axes, st.cond)
    s.crack, s.bottom, s.pillow, s.rim, s.tags = st.crack, st.bottom, st.pillow, st.rim, set(st.tags)
    s.ring = getattr(st, "ring", -1)
    return s


def crack_through(st, rng, amp=0.006):
    """Splits a stone in two along a jagged line: returns the pieces, or None."""
    shp = st.shape()
    minx, miny, maxx, maxy = shp.bounds
    c = np.asarray(shp.centroid.coords[0])
    for _ in range(12):
        a = rng.uniform(0, math.pi)
        d = np.array([math.cos(a), math.sin(a)])
        off = rng.uniform(-0.18, 0.18) * np.array([-d[1], d[0]])
        span = max(maxx - minx, maxy - miny)
        line = jagged(c + off - d * span, c + off + d * span, rng, amp)
        parts = pieces(shp_split(shp, LineString(line)))
        if len(parts) == 2 and min(p.area for p in parts) > 0.12 * shp.area:
            out = []
            for p in parts:
                P, L = relabel(p, st.poly, st.labels, (0.0011, 0.0016, CRACK))
                out.append(clone(st, P, L))
            return out
    return None


def chip(st, rng):
    """Knocks a small bite out of one corner."""
    corners = [i for i in range(len(st.poly)) if st.labels[i] != st.labels[i - 1]]
    if not corners:
        return False
    i = int(rng.choice(corners))
    p = st.poly[i]
    rad = rng.uniform(0.04, 0.09)
    t = np.linspace(0, 2 * math.pi, 7, endpoint=False) + rng.uniform(0, 1)
    k = rng.uniform(0.75, 1.2, len(t))
    bite = Polygon(np.stack([p[0] + np.cos(t) * rad * k, p[1] + np.sin(t) * rad * k], 1))
    res = pieces(st.shape().difference(bite))
    if not res:
        return False
    res = max(res, key=lambda g: g.area)
    if res.area < 0.9 * st.shape().area or res.geom_type != "Polygon":
        return False
    st.poly, st.labels = relabel(res, st.poly, st.labels, (0.002, 0.004, BREAK))
    st.tags.add("chipped")
    return True


def break_stone(st, rng):
    """Breaks a stone: a corner piece is gone (its rubble lies in the hole), the rest is cracked.
    Returns (remaining pieces, rubble stones, hole polygon)."""
    shp = st.shape()
    minx, miny, maxx, maxy = shp.bounds
    c = np.asarray(shp.centroid.coords[0])
    far = st.poly[np.argmax(np.linalg.norm(st.poly - c, axis=1))]
    d = far - c
    d /= np.linalg.norm(d)
    nrm = np.array([-d[1], d[0]])
    mid = c + d * 0.18
    line = jagged(mid - nrm * 1.2, mid + nrm * 1.2, rng, 0.012, step=0.03)
    parts = sorted(pieces(shp_split(shp, LineString(line))), key=lambda g: g.area)
    hole, keep = parts[0], parts[-1]
    P, L = relabel(keep, st.poly, st.labels, (0.0, 0.004, BREAK))
    rest = clone(st, P, L)
    rest.tags.add("broken")
    halves = crack_through(rest, rng, amp=0.01) or [rest]
    rubble = []
    inner = hole.buffer(-0.035)
    for j in range(40):
        if len(rubble) >= 5 or inner.is_empty:
            break
        minx, miny, maxx, maxy = inner.bounds
        q = np.array([rng.uniform(minx, maxx), rng.uniform(miny, maxy)])
        if not inner.contains(Point(q)):
            continue
        rad = rng.uniform(0.03, 0.075) if j > 0 else 0.1
        t = np.sort(rng.uniform(0, 2 * math.pi, 6))
        poly = np.stack([q[0] + np.cos(t) * rad * rng.uniform(0.6, 1.2, 6), q[1] + np.sin(t) * rad * rng.uniform(0.6, 1.2, 6)], 1)
        pg = Polygon(poly)
        if not pg.is_valid or any(pg.intersects(r.shape().buffer(0.006)) for r in rubble):
            continue
        P, L = ccw(poly, [(0.0, 0.003, BREAK)] * len(poly))
        axes = (q, np.array([1.0, 0.0]), np.array([0.0, 1.0]))
        rb = Stone(P, L, "rubble", st.stype, axes, WORN)
        rb.h0 = rng.uniform(-0.012, -0.003)
        rb.grad = rng.normal(0.0, 0.12, 2)
        rb.bottom = Y_BED - 0.01
        rb.rim = 0.008
        rb.pillow = 0.0
        rubble.append(rb)
    return halves, rubble, hole


def settle(stones, rng):
    """Heights and tilts: a few millimetres off level, lower where worn."""
    for st in stones:
        if st.kind == "rubble":
            continue
        if st.kind == "curb":
            st.h0 = CURB_TOP + rng.uniform(-0.003, 0.002)
            st.grad = rng.normal(0.0, 0.002, 2)
            st.pillow = 0.002
            continue
        st.h0 = rng.uniform(-0.0025, 0.0012) - (0.0015 if st.cond == WORN else 0.0)
        g = rng.uniform(0.0, 0.0035)
        a = rng.uniform(0, 2 * math.pi)
        st.grad = np.array([math.cos(a), math.sin(a)]) * g
        if st.cond == WORN:
            st.pillow = 0.002
        elif st.cond == NEW:
            st.pillow = 0.0005


def sink_puddle(stones, water):
    """Stones under the puddle settle below the water line, tilting up toward its shore."""
    wshape = Polygon(water)
    c = np.array(PUDDLE_C)
    for st in stones:
        shp = st.shape()
        if st.kind not in ("ring",) or not shp.intersects(wshape.buffer(0.08)):
            continue
        P = st.poly
        # target: 12 mm down at the puddle's heart, rising to the shore and beyond
        rel = P - c
        ca, sa = math.cos(-PUDDLE_ANG), math.sin(-PUDDLE_ANG)
        lx = (rel[:, 0] * ca - rel[:, 1] * sa) / PUDDLE_R[0]
        lz = (rel[:, 0] * sa + rel[:, 1] * ca) / PUDDLE_R[1]
        e = np.sqrt(lx * lx + lz * lz)
        target = -0.0125 * np.clip(1.25 - e * 0.8, 0.0, 1.0) - 0.0015
        A = np.stack([np.ones(len(P)), P[:, 0] - st.axes[0][0], P[:, 1] - st.axes[0][1]], 1)
        sol, *_ = np.linalg.lstsq(A, target, rcond=None)
        st.h0, st.grad = sol[0], np.clip(sol[1:], -0.012, 0.012)
        # everything under the water must sit below it (the stone's corners and a grid inside it)
        wet = wshape.buffer(0.02)
        minx, miny, maxx, maxy = shp.bounds
        gx, gz = np.meshgrid(np.linspace(minx, maxx, 16), np.linspace(miny, maxy, 16))
        grid = np.vstack([np.stack([gx.ravel(), gz.ravel()], 1), P])
        m = contains_xy(wet, grid[:, 0], grid[:, 1]) & contains_xy(shp.buffer(1e-6), grid[:, 0], grid[:, 1])
        samples = grid[m]
        if len(samples):
            top = float(np.max(st.height(samples)))
            if top > WATER_Y - 0.0015:
                st.h0 -= top - (WATER_Y - 0.0015)
        st.tags.add("puddle")
        st.pillow = 0.0008


def clamp_tops(stones):
    for st in stones:
        if st.kind in ("rubble", "curb"):
            continue
        top = float(np.max(st.height(st.poly)))
        if top > 0.0045:
            st.h0 -= top - 0.0045


# ------------------------------------------------------------------ geometry
def valid_ring(R):
    if signed_area(R) <= 1e-7:
        return False
    return Polygon(R).is_valid


def edge_rows(P, ins, bev, rim, ths):
    """Offset rows from the inner top out to the side: exact mitre offsets of the outline
    (per-edge joint widths and edge radii)."""
    ds = ([ins + bev + rim] if rim > 1e-4 else []) + [ins + bev]
    ds += [ins + bev * (1.0 - math.sin(th)) for th in ths]
    return [offset_poly(P, d) for d in ds]


def radial_rows(P, ins, bev, rim, ths):
    """Fallback for outlines with short, jagged edges (chips, cracks), where mitre offsets fold
    over: the side row is the joint offset, the others shrink it toward the stone's most
    interior point. Always simple for star-shaped pieces."""
    side = offset_poly(P, ins)
    if not valid_ring(side):
        side = P.copy()
    c = np.asarray(polylabel(Polygon(side), tolerance=0.002).coords[0])
    v = side - c
    r = np.linalg.norm(v, axis=1)
    bv = np.minimum(bev, np.roll(bev, 1))

    def shrink(delta):
        delta = np.minimum(delta, 0.8 * r)
        return c + v * (1.0 - delta / r)[:, None]

    rows = ([shrink(bv + rim)] if rim > 1e-4 else []) + [shrink(bv)]
    rows += [shrink(bv * (1.0 - math.sin(th))) for th in ths]
    return rows


def slab(st):
    """Rows from the inner top outward: the top (pillowed rim), the rounded edge, the side down to
    the bed. Returns verts, faces, local uv, data uv, atlas uv."""
    P = st.poly
    M = len(P)
    ins = np.array([l[0] for l in st.labels])
    bev0 = np.array([l[1] for l in st.labels])
    rim0 = st.rim
    ths = [j / K_BEVEL * math.pi / 2 for j in range(1, K_BEVEL + 1)]
    rows = None
    for attempt in range(6):
        rim = rim0 * [1.0, 1.0, 0.6, 0.3, 0.0, 0.0][attempt]
        bev = bev0 * [1.0, 1.0, 1.0, 0.6, 0.4, 0.15][attempt]
        maker = edge_rows if attempt == 0 else radial_rows
        cand = maker(P, ins, bev, rim, ths)
        if all(valid_ring(r) for r in cand):
            rows = cand
            break
    if rows is None:
        raise RuntimeError("could not offset stone %d" % st.id)
    has_rim = rim > 1e-4
    bv = np.minimum(bev, np.roll(bev, 1))
    top = rows[1] if has_rim else rows[0]
    ys = ([st.height(rows[0])] if has_rim else []) + [st.height(top) - st.pillow]
    for j, th in enumerate(ths):
        ys.append(st.height(rows[j + (2 if has_rim else 1)]) - st.pillow - bv * (1.0 - math.cos(th)))
    edges = ([0.0] if has_rim else []) + [0.5] + [0.5 + 0.5 * (j + 1) / K_BEVEL for j in range(K_BEVEL)]
    # the side, down into the bed
    rows.append(rows[-1].copy())
    ys.append(np.full(M, st.bottom))
    edges.append(1.0)
    V = np.concatenate([np.stack([r[:, 0], y, r[:, 1]], 1) for r, y in zip(rows, ys)])
    c, ta, na = st.axes

    def local(p):
        q = p - c
        return np.stack([q @ ta, q @ na], 1)

    out_dir = rows[-2] - top
    out_dir /= np.maximum(np.linalg.norm(out_dir, axis=1, keepdims=True), 1e-9)
    drop = (ys[-2] - ys[-1])[:, None]
    uv0 = [local(r) for r in rows[:-1]] + [local(rows[-2] + out_dir * drop)]
    attrs = st.stype + 8 * st.crack + 64 * st.cond
    uv1 = [np.stack([np.full(M, st.id + 0.5), np.full(M, attrs + 0.05 + 0.9 * e)], 1) for e in edges]

    def plan(p):
        return np.stack([p[:, 0] / MAP + 0.5, 1.0 - (p[:, 1] / MAP + 0.5)], 1)

    uva = [plan(r) for r in rows[:-1]] + [plan(rows[-2])]
    F = [list(range(M))[::-1]]
    for r in range(len(rows) - 1):
        for i in range(M):
            i2 = (i + 1) % M
            F.append([r * M + i, r * M + i2, (r + 1) * M + i2, (r + 1) * M + i])
    return V, F, gltf_uv(np.concatenate(uv0)), gltf_uv(np.concatenate(uv1)), np.concatenate(uva)


def gltf_uv(uv):
    """Blender's glTF exporter writes (u, 1 - v); pre-flip so Godot reads the values we mean."""
    uv = np.array(uv, dtype=float)
    uv[:, 1] = 1.0 - uv[:, 1]
    return uv


def bed_mesh():
    rs = np.concatenate([[0.0], np.arange(0.3, R_PLAZA + 0.1, 0.3), [R_PLAZA + 0.05]])
    seg = 160
    t = np.linspace(0, 2 * math.pi, seg, endpoint=False)
    V = [[0.0, Y_BED, 0.0]]
    for r in rs[1:]:
        for a in t:
            V.append([math.sin(a) * r, Y_BED, math.cos(a) * r])
    V = np.array(V)
    F = []
    for i in range(seg):
        F.append([0, 1 + (i + 1) % seg, 1 + i])
    for k in range(len(rs) - 2):
        b0, b1 = 1 + k * seg, 1 + (k + 1) * seg
        for i in range(seg):
            i2 = (i + 1) % seg
            F.append([b0 + i, b0 + i2, b1 + i2, b1 + i])
    # faces must point up: check the first quad
    uva = np.stack([V[:, 0] / MAP + 0.5, 1.0 - (V[:, 2] / MAP + 0.5)], 1)
    return V, F, uva


def water_mesh(outline):
    c = np.array(PUDDLE_C)
    n = len(outline)
    V = [[c[0], WATER_Y, c[1]]]
    uv = [[0.0, 0.0]]
    fr = [0.35, 0.7, 1.0]
    t = np.linspace(0, 2 * math.pi, n, endpoint=False)
    for f in fr:
        for i in range(n):
            p = c + (outline[i] - c) * f
            V.append([p[0], WATER_Y, p[1]])
            uv.append([math.cos(t[i]) * f, math.sin(t[i]) * f])
    F = []
    for i in range(n):
        F.append([0, 1 + (i + 1) % n, 1 + i])
    for k in range(len(fr) - 1):
        b0, b1 = 1 + k * n, 1 + (k + 1) * n
        for i in range(n):
            i2 = (i + 1) % n
            F.append([b0 + i, b0 + i2, b1 + i2, b1 + i])
    return np.array(V), F, gltf_uv(np.array(uv))


def face_up(V, F):
    """Flips every face whose normal points down (the bed and water are flat)."""
    out = []
    for f in F:
        a, b, c = V[f[0]], V[f[1]], V[f[2]]
        n = np.cross(b - a, c - a)
        out.append(f if n[1] >= 0 else f[::-1])
    return out


# ------------------------------------------------------------------ plan
def build_plan(seed=11):
    rng = np.random.default_rng(seed)
    stones = layout(rng)
    # hairline crack decals and a few special stones
    for st in stones:
        if st.kind in ("ring", "wedge") and rng.random() < 0.17:
            st.crack = int(rng.integers(1, 5))
        elif st.kind == "curb" and rng.random() < 0.12:
            st.crack = int(rng.integers(1, 5))
    mossy = find_stone(stones, MOSSY_AT)
    mossy.cond, mossy.stype = WORN, GRANITE
    mossy.tags.add("mossy")
    broken = find_stone(stones, BROKEN_AT)
    broken.cond = WORN
    halves, rubble, hole = break_stone(broken, rng)
    replace(stones, broken, halves)
    stones.extend(rubble)
    # cracked right through
    cands = [s for s in stones if s.kind == "ring" and not s.tags and np.linalg.norm(s.centroid) > 3.0]
    for st in rng.choice(cands, 7, replace=False):
        parts = crack_through(st, rng)
        if parts:
            for p in parts:
                p.tags.add("split")
            replace(stones, st, parts)
    # chipped corners
    for st in stones:
        if st.kind in ("ring", "curb", "wedge") and "mossy" not in st.tags and rng.random() < (0.12 if st.kind != "curb" else 0.16):
            chip(st, rng)
    settle(stones, rng)
    water = blob(PUDDLE_C, PUDDLE_R, PUDDLE_ANG, seed=4)
    sink_puddle(stones, water)
    # stones around the broken one have shifted a little
    for st in stones:
        if st.kind == "ring" and st.shape().distance(hole) < 0.05 and "broken" not in st.tags:
            d = st.centroid - np.asarray(hole.centroid.coords[0])
            st.grad = st.grad - 0.004 * d / max(np.linalg.norm(d), 1e-6)
            st.h0 -= 0.0015
    clamp_tops(stones)
    for i, st in enumerate(stones):
        st.id = i
    return stones, water, hole, mossy


def summarize(stones):
    kinds = {}
    for st in stones:
        kinds[st.kind] = kinds.get(st.kind, 0) + 1
    tags = {}
    for st in stones:
        for t in st.tags:
            tags[t] = tags.get(t, 0) + 1
    return kinds, tags


# ------------------------------------------------------------------ masks
def raster(polys, n, fill=1.0, ss=2):
    img = Image.new("L", (n * ss, n * ss), 0)
    d = ImageDraw.Draw(img)
    for P in polys:
        pts = [((x / MAP + 0.5) * n * ss, (z / MAP + 0.5) * n * ss) for x, z in P]
        d.polygon(pts, fill=int(255 * fill))
    return np.asarray(img.resize((n, n), Image.BILINEAR), dtype=float) / 255.0


def plaza_masks(n, stones, water, hole, mossy, ao_st, ao_bed, seed=21):
    px = MAP / n
    c = (np.arange(n) + 0.5) * px - MAP / 2
    X, Z = np.meshgrid(c, c)
    R = np.sqrt(X * X + Z * Z)
    ss = FT.smoothstep

    def nz(scale_m, s, octv=3):
        return FT.fnoise(n, n, scale_m / px, seed + s, octaves=octv)

    def n01(scale_m, s, octv=3):
        return np.clip(0.5 + 0.2 * nz(scale_m, s, octv), 0.0, 1.0)

    dl = np.min([np.sqrt((X - lx) ** 2 + (Z - lz) ** 2) for lx, lz in LANTERNS], axis=0)
    post_d = np.min([np.sqrt((X - math.sin(a) * POST_R) ** 2 + (Z - math.cos(a) * POST_R) ** 2) for a in POSTS], axis=0)
    wmask = raster([water], n)
    wdist = ndimage.distance_transform_edt(wmask < 0.5) * px          # metres outside the water
    hmask = raster([np.asarray(hole.exterior.coords)], n)
    hdist = ndimage.distance_transform_edt(hmask < 0.5) * px
    mmask = raster([mossy.poly], n)
    mdist = ndimage.distance_transform_edt(mmask < 0.5) * px

    # dirt: blown against the curb and the fence, under the lanterns, silt round the puddle,
    # debris by the broken stone, swept thin in the middle where people walk
    dirt = 0.16 + 0.1 * nz(3.0, 1) + 0.06 * nz(0.5, 2)
    dirt += 0.3 * ss(12.0, 15.3, R) * n01(1.1, 3) * 1.6
    # water stains: soft-edged blotches with a darker tide line
    st_n = n01(0.35, 19)
    dirt += 0.22 * ss(0.62, 0.7, st_n) + 0.12 * np.exp(-((st_n - 0.66) / 0.012) ** 2)
    dirt += 0.3 * np.exp(-(dl / 0.8) ** 2) + 0.25 * np.exp(-(post_d / 0.35) ** 2)
    dirt += 0.45 * np.exp(-((wdist - 0.1) / 0.12) ** 2) * (wmask < 0.5)
    dirt += 0.5 * np.exp(-(hdist / 0.35) ** 2)
    dirt -= 0.14 * np.exp(-(R / 7.0) ** 2)
    # a few dirty stones
    rng = np.random.default_rng(seed)
    dirty = [s for s in stones if s.kind == "ring" and not s.tags and rng.random() < 0.05]
    dirt += 0.35 * raster([s.poly for s in dirty], n) * n01(0.4, 4)
    dirt = np.clip(dirt, 0.0, 1.0)

    # moss: the shady rim, lantern bases, damp joints by the puddle, the broken hole, one old stone
    moss = 0.55 * ss(13.2, 14.95, R) * ss(0.35, 0.75, n01(0.8, 5)) + 0.25 * ss(14.8, 15.2, R)
    moss += 0.6 * np.exp(-(dl / 0.55) ** 2) * (0.55 + 0.45 * n01(0.3, 6))
    moss += 0.5 * np.exp(-((wdist - 0.35) / 0.3) ** 2) * (wmask < 0.5) * n01(0.35, 7)
    moss += 0.75 * np.exp(-(hdist / 0.25) ** 2)
    moss += 0.4 * ss(0.62, 0.8, n01(1.6, 8)) * ss(3.0, 6.0, R)
    patch = ss(0.25, 0.85, 0.7 * n01(0.22, 9) + 0.3 * n01(0.07, 20))
    moss_tile = np.clip(ss(0.1, 0.0, mdist) * (0.22 + 0.78 * patch) + 0.3 * ss(0.03, 0.0, mdist), 0.0, 1.0)
    moss_tile = np.maximum(moss_tile, 0.6 * np.exp(-(mdist / 0.5) ** 2) * n01(0.3, 10))
    moss = np.clip(np.maximum(moss, moss_tile), 0.0, 1.0)

    # wetness: the puddle and a damp halo; the hole stays damp
    wet = np.maximum(wmask, np.exp(-(wdist / 0.14) ** 2) * (0.7 + 0.3 * n01(0.2, 11)))
    wet = np.maximum(wet, 0.5 * np.exp(-(hdist / 0.2) ** 2))
    wet = np.clip(wet, 0.0, 1.0)

    # soot: old fires round the medallion, with a few licks running outward
    ang = np.arctan2(X, Z)
    ph = rng.uniform(0, 2 * math.pi, 3)
    lick = (np.sin(ang * 7 + ph[0]) + np.sin(ang * 12 + ph[1]) * 0.7 + np.sin(ang * 19 + ph[2]) * 0.5) / 2.2
    lick = ss(0.45, 0.85, lick + 0.25 * nz(0.25, 12, 2)) * ss(4.8, 1.8, R + 0.6 * nz(0.8, 17, 2)) * ss(0.9, 1.6, R)
    soot = ss(3.3, 0.9, R + 0.9 * nz(0.9, 18, 2)) * (0.45 + 0.55 * n01(0.45, 13))
    soot = np.clip(np.maximum(soot, 0.6 * lick) * 0.85, 0.0, 1.0)

    # polish: the fighting ground in the middle is worn smooth
    wear = np.clip(0.75 * np.exp(-(R / 7.5) ** 2) * (0.8 + 0.2 * n01(1.5, 14)), 0.0, 1.0)

    # lichen: pale crusts where nobody walks
    lichen = ss(0.6, 0.78, n01(0.12, 15, 2)) * (0.2 + 0.8 * ss(9.5, 14.0, R))
    lichen *= ss(0.3, 0.6, n01(3.0, 16, 2))
    lichen = np.clip(lichen, 0.0, 1.0)

    a = np.stack([ao_st, ao_bed, dirt, moss], 2)
    b = np.stack([wet, soot, wear, lichen], 2)
    return a, b


# ------------------------------------------------------------------ Blender
def blender_build(stones, water, args):
    import bpy
    from model3d import blender_io as B

    B.reset_scene()
    t0 = time.time()
    Vs, Fs, U0, U1, UA = [], [], [], [], []
    base = 0
    for st in stones:
        V, F, uv0, uv1, uva = slab(st)
        Vs.append(V)
        Fs.extend([[base + i for i in f] for f in F])
        U0.append(uv0)
        U1.append(uv1)
        UA.append(uva)
        base += len(V)
    V = np.concatenate(Vs)
    stones_obj = B.mesh_object("Stones", V, Fs, np.concatenate(U0), "UVMap", smooth_angle=40.0)
    add_uv(stones_obj, "data", np.concatenate(U1))
    add_uv(stones_obj, "atlas", np.concatenate(UA))
    print("stones: %d verts, %d faces (%.1fs)" % (len(V), len(Fs), time.time() - t0))
    bv, bf, bua = bed_mesh()
    bed = B.mesh_object("Bed", bv, face_up(bv, bf), bua, "atlas", smooth_angle=None)
    wv, wf, wuv = water_mesh(water)
    wat = B.mesh_object("Water", wv, face_up(wv, wf), wuv, "UVMap", smooth_angle=None)
    proxies = bake_proxies(B)
    wat.hide_render = True
    n = args.ao
    if args.no_bake:
        ao_st = np.ones((n, n))
        ao_bed = np.full((n, n), 0.3)
    else:
        scn = bpy.context.scene
        world = bpy.data.worlds.new("AO")
        scn.world = world
        world.light_settings.distance = 0.8
        ao_st = bake_ao(B, stones_obj, "ao_stones", n, args.samples)
        print("stones AO baked (%.1fs)" % (time.time() - t0))
        ao_bed = bake_ao(B, bed, "ao_bed", n, max(16, args.samples // 2))
        print("bed AO baked (%.1fs)" % (time.time() - t0))
    for o in proxies:
        bpy.data.objects.remove(o, do_unlink=True)
    wat.hide_render = False
    stones_obj.data.uv_layers.remove(stones_obj.data.uv_layers["atlas"])
    bed.data.uv_layers.remove(bed.data.uv_layers["atlas"])
    for o in (stones_obj, bed, wat):
        o.data.materials.clear()
    path = os.path.join(ROOT, GLB)
    for o in bpy.context.view_layer.objects:
        o.select_set(False)
    for o in (stones_obj, bed, wat):
        o.select_set(True)
    bpy.context.view_layer.objects.active = stones_obj
    bpy.ops.export_scene.gltf(filepath=path, export_format="GLB", use_selection=True, export_apply=True,
                              export_skins=False, export_animations=False, export_yup=True,
                              export_materials="NONE", export_vertex_color="NONE", export_texcoords=True,
                              export_normals=True, export_tangents=False, export_attributes=False,
                              export_extras=False)
    print("wrote %s (%.1f MB)" % (path, os.path.getsize(path) / 1e6))
    return blur_ao(ao_st), blur_ao(ao_bed)


def blur_ao(a):
    return np.clip(ndimage.gaussian_filter(a, 0.6), 0.0, 1.0)


def add_uv(obj, name, per_vertex):
    me = obj.data
    layer = me.uv_layers.new(name=name)
    loops_v = np.zeros(len(me.loops), dtype=np.int64)
    me.loops.foreach_get("vertex_index", loops_v)
    layer.data.foreach_set("uv", np.asarray(per_vertex, dtype=np.float32)[loops_v].reshape(-1))
    return layer


def bake_proxies(B):
    """Stand-ins for the lanterns, fence posts and rails (built in Godot) so the bake darkens
    the stones around them."""
    objs = []
    t = np.linspace(0, 2 * math.pi, 24, endpoint=False)
    prof = [(0.33, 0.0), (0.33, 0.1), (0.22, 0.14), (0.12, 0.2), (0.1, 0.8), (0.2, 0.86), (0.26, 0.92)]
    for lx, lz in LANTERNS:
        V, F = [], []
        for r, y in prof:
            for a in t:
                V.append([lx + math.sin(a) * r, y, lz + math.cos(a) * r])
        m = len(t)
        for k in range(len(prof) - 1):
            for i in range(m):
                i2 = (i + 1) % m
                F.append([k * m + i, k * m + i2, (k + 1) * m + i2, (k + 1) * m + i])
        V.append([lx, 0.92, lz])
        top = len(V) - 1
        last = (len(prof) - 1) * m
        for i in range(m):
            F.append([last + i, last + (i + 1) % m, top])
        objs.append(B.mesh_object("lantern_proxy", np.array(V), F, smooth_angle=None))
        objs.append(box(B, (lx, 1.1, lz), (0.36, 0.34, 0.36), 0.0))
    for a in POSTS:
        objs.append(box(B, (math.sin(a) * POST_R, 0.475, math.cos(a) * POST_R), (0.22, 0.95, 0.22), a))
        a2 = a + math.pi / 36
        for yv in (0.45, 0.85):
            objs.append(box(B, (math.sin(a2) * POST_R, yv, math.cos(a2) * POST_R),
                            (2 * math.pi * POST_R / 36 - 0.2, 0.07, 0.07), a2))
    return objs


def box(B, c, s, yaw):
    hx, hy, hz = s[0] / 2, s[1] / 2, s[2] / 2
    corners = np.array([[x, y, z] for x in (-hx, hx) for y in (-hy, hy) for z in (-hz, hz)])
    ca, sa = math.cos(yaw), math.sin(yaw)
    rot = np.array([[ca, 0, sa], [0, 1, 0], [-sa, 0, ca]])
    V = corners @ rot.T + np.array(c)
    F = [[0, 1, 3, 2], [4, 6, 7, 5], [0, 4, 5, 1], [2, 3, 7, 6], [0, 2, 6, 4], [1, 5, 7, 3]]
    return B.mesh_object("box_proxy", V, F, smooth_angle=None)


def bake_ao(B, obj, name, n, samples):
    import bpy
    img = bpy.data.images.new(name, width=n, height=n, alpha=False, float_buffer=True)
    img.colorspace_settings.name = "Non-Color"
    mat = bpy.data.materials.new("bake_" + name)
    mat.use_nodes = True
    node = mat.node_tree.nodes.new("ShaderNodeTexImage")
    node.image = img
    mat.node_tree.nodes.active = node
    obj.data.materials.clear()
    obj.data.materials.append(mat)
    scn = bpy.context.scene
    scn.cycles.samples = samples
    obj.data.uv_layers.active = obj.data.uv_layers["atlas"]
    B.activate(obj)
    scn.render.bake.margin = 2
    scn.render.bake.margin_type = "EXTEND"
    scn.render.bake.use_clear = True
    bpy.ops.object.bake(type="AO", uv_layer="atlas")
    return B.image_to_numpy(img)[..., 0].astype(float)


# ------------------------------------------------------------------ main
def write_textures(args):
    out = os.path.join(ROOT, TEX)
    os.makedirs(out, exist_ok=True)
    t0 = time.time()
    alb, nrm, data = FT.stone_detail(args.detail, seed=3, period_m=2.4)
    FT.save_rgb(os.path.join(out, "stone_albedo.jpg"), alb, quality=90)
    FT.save_rgb(os.path.join(out, "stone_normal.jpg"), nrm, quality=94)
    small = data.reshape(data.shape[0] // 2, 2, data.shape[1] // 2, 2, 3).mean(axis=(1, 3))
    FT.save_rgb(os.path.join(out, "stone_data.jpg"), small, quality=92)
    rgba, mn = FT.moss(512)
    FT.save_rgba(os.path.join(out, "moss_albedo.png"), rgba)
    FT.save_rgb(os.path.join(out, "moss_normal.png"), mn)
    FT.save_rgb(os.path.join(out, "cracks.png"), FT.cracks(2048))
    FT.save_rgb(os.path.join(out, "engraving.png"), FT.engraving(1024, R_MED))
    print("textures written (%.1fs)" % (time.time() - t0))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--no-bake", action="store_true", help="skip the Cycles AO bake")
    ap.add_argument("--textures", action="store_true", help="only (re)write the tiling textures")
    ap.add_argument("--ao", type=int, default=2048, help="plaza mask resolution")
    ap.add_argument("--samples", type=int, default=64)
    ap.add_argument("--detail", type=int, default=2048, help="stone detail texture size")
    ap.add_argument("--seed", type=int, default=11)
    args = ap.parse_args()
    if args.textures:
        write_textures(args)
        return
    t0 = time.time()
    stones, water, hole, mossy = build_plan(args.seed)
    kinds, tags = summarize(stones)
    print("plan: %s %s (%.1fs)" % (kinds, tags, time.time() - t0))
    ao_st, ao_bed = blender_build(stones, water, args)
    a, b = plaza_masks(args.ao, stones, water, hole, mossy, ao_st, ao_bed)
    out = os.path.join(ROOT, TEX)
    os.makedirs(out, exist_ok=True)
    FT.save_rgba(os.path.join(out, "plaza_a.png"), a)
    FT.save_rgba(os.path.join(out, "plaza_b.png"), b)
    os.makedirs(PREVIEW_DIR, exist_ok=True)
    Image.fromarray((np.clip(ao_st, 0, 1) * 255).astype(np.uint8)).save(os.path.join(PREVIEW_DIR, "floor_ao.png"))
    write_textures(args)
    print("done (%.1fs)" % (time.time() - t0))


if __name__ == "__main__":
    main()
