#!/usr/bin/env python3
"""Builds Sojin's PS2-style model: models/boss.glb (skinned to the boss rig) and
models/boss_staff.glb (the twin-bladed staff, in weapon space), plus models/boss_hair.png.

    pip install bpy==4.5.9                      # Blender 4.5 LTS as a Python module (once)
    python3 tools/build_boss_model.py           # build + bake + export (~1-2 min)
    python3 tools/build_boss_model.py --preview # also render tools/preview_out/boss_*.png

The armour is modelled from parametric pieces (lathe bands, lofts, ribbons, a displaced grid
for the oni mask) in game space, skinned by rule (rigid plates, blended cloth, helper bones
for the shoulder guards and skirt panels), then Cycles bakes pattern textures, ambient
occlusion and worn edges into one 2048 px atlas, like a hand-painted PS2 texture with baked
lighting. Then run `godot --headless --editor --quit` to import the new .glb files.
"""
import argparse
import math
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import bpy  # noqa: E402
import numpy as np  # noqa: E402
from mathutils import Matrix  # noqa: E402

from model3d import bakemat as BM  # noqa: E402
from model3d import blender_io as B  # noqa: E402
from model3d import geo as G  # noqa: E402
from model3d import textures as T  # noqa: E402
from model3d.boss_spec import BODY_GLB, HAIR_PNG, HELPERS, SASH_PNG, STAFF_GLB  # noqa: E402
from model3d.geo import Mesh, smoothstep  # noqa: E402

RIG = B.load_rig("boss")
J = B.rest_positions(RIG)
SIDES = (("l", -1.0), ("r", 1.0))
PREVIEW_DIR = os.path.join(B.ROOT, "tools", "preview_out")

# pattern materials: key -> (texture, (tile u, tile v) metres, bake params, atlas texel scale)
LAME_W = 0.096
LACE = (0.50, 0.055, 0.045)          # hi-odoshi: deep scarlet silk lacing


def material_table():
    return {
        "lacquer": (T.lacquer(), (0.25, 0.25), dict(edge=0.16, edge_color=(0.24, 0.20, 0.17)), 1.0),
        "lamellar": (T.lamellar(lace=LACE), (LAME_W, 1.0), dict(edge=0.16, edge_color=(0.24, 0.14, 0.10)), 1.0),
        "lamellar_hishi": (T.lamellar(lace=LACE, hishinui=True), (LAME_W, 1.0), dict(edge=0.16, edge_color=(0.24, 0.14, 0.10)), 1.0),
        "gold": (T.gold(), (0.08, 0.08), dict(edge=0.45, edge_color=(0.75, 0.62, 0.35), ao=0.55), 1.0),
        "hakama": (T.cloth(color=(0.22, 0.06, 0.065), weave=0.12, seed=22), (0.10, 0.10),
                   dict(edge=0.0, ao=0.6, ao_dist=0.06), 0.8),
        "cloth_dark": (T.cloth(color=(0.075, 0.068, 0.075), weave=0.12, seed=23), (0.08, 0.08),
                       dict(edge=0.0, ao=0.9), 0.6),
        "brocade": (T.brocade(), (0.09, 0.09), dict(edge=0.1, ao=0.85), 1.0),
        "mail": (T.mail(cells=12), (0.07, 0.07), dict(edge=0.1, ao=0.85), 0.9),
        "leather": (T.leather(), (0.10, 0.10), dict(edge=0.25, edge_color=(0.22, 0.17, 0.13)), 0.9),
        "cord": (T.cord(), (0.03, 0.03), dict(edge=0.0), 0.6),
        "mask": (mask_texture(), (1.0, 1.0), dict(edge=0.10, edge_color=(0.60, 0.18, 0.10), ao=0.7, ao_dist=0.025, top=0.12), 2.6),
        "teeth": (T.lacquer(color=(0.86, 0.80, 0.66), mottle=0.3, rough=0.4), (0.05, 0.05), dict(edge=0.2, edge_color=(0.3, 0.3, 0.3)), 1.5),
        "dark": (T.lacquer(color=(0.01, 0.008, 0.008), mottle=0.0, rough=0.9), (0.2, 0.2), dict(edge=0.0), 0.2),
    }


class Part:
    def __init__(self, name, mesh, mat, uv="tile", solidify=0.0, bevel=0.0, subsurf=0, smooth=40.0):
        self.name, self.mesh, self.mat = name, mesh, mat
        self.uv, self.solidify, self.bevel, self.subsurf, self.smooth = uv, solidify, bevel, subsurf, smooth


PARTS = []      # baked into the atlas
EXTRAS = []     # own materials: ember, hair


def add(name, mesh, mat, **kw):
    PARTS.append(Part(name, mesh, mat, **kw))


def add_extra(name, mesh, mat, **kw):
    EXTRAS.append(Part(name, mesh, mat, **kw))


# ================================================================ weights
def w_chain(v, bones, joints):
    """bones top to bottom; joints [(y, blend)] between consecutive bones (rest pose, Y up)."""
    y = v[:, 1]
    out = {}
    carry = np.ones(len(y))
    for i, b in enumerate(bones):
        t = smoothstep(joints[i][0] + joints[i][1], joints[i][0] - joints[i][1], y) if i < len(joints) else np.zeros(len(y))
        out[b] = out.get(b, 0.0) + carry * (1.0 - t)
        carry = carry * t
    return out


def rigid(bone):
    return lambda v: {bone: np.ones(len(v))}


# ================================================================ shapes
def band(a0, a1, y_bot, y_top, r_bot, r_top, segs=10, center=(0, 0, 0), sz=1.0, mid=0.0):
    """A lame: a narrow revolved band from (r_bot, y_bot) up to (r_top, y_top), UV v normalised
    0 (bottom) .. 1 (top), u in metres. mid bulges the middle outward."""
    ym = 0.5 * (y_bot + y_top)
    prof = [(r_bot, y_bot), (0.5 * (r_bot + r_top) + mid, ym), (r_top, y_top)]
    m = G.revolve(prof, a0, a1, segs, 1.0, sz, center)
    y = m.v[:, 1]
    m.uv[:, 1] = (y - y_bot) / (y_top - y_bot)
    return m


def ring_dims(table, y):
    """Interpolates (a, b_front, b_back) from [(y, a, bf, bb), ...]."""
    t = np.asarray(table, dtype=float)
    return [float(np.interp(y, t[:, 0], t[:, k])) for k in (1, 2, 3)]


# ================================================================ body
TORSO = [(1.02, 0.212, 0.172, 0.160), (1.13, 0.205, 0.166, 0.156), (1.21, 0.207, 0.168, 0.158),
         (1.29, 0.218, 0.178, 0.162), (1.37, 0.234, 0.192, 0.168), (1.45, 0.250, 0.206, 0.176),
         (1.53, 0.254, 0.210, 0.180), (1.60, 0.238, 0.192, 0.172), (1.64, 0.205, 0.160, 0.158)]


def torso_ring(y, scale=1.0, segs=32, ridge=0.0):
    a, bf, bb = ring_dims(TORSO, y)
    return G.superellipse(a * scale, bf * scale, bb * scale, 2.7, segs, y, ridge=ridge)


def torso_weights(v):
    return w_chain(v, ["hips", "spine", "chest"], [(1.17, 0.05), (1.36, 0.08)])


def build_torso():
    # four lamellar rows, each flaring out at its bottom edge
    rows = [(1.035, 1.125), (1.115, 1.205), (1.195, 1.285), (1.275, 1.375)]
    for k, (y0, y1) in enumerate(rows):
        rings = [torso_ring(y1, 1.0), torso_ring(0.5 * (y0 + y1), 1.03), torso_ring(y0, 1.06)]
        m = G.loft(rings)
        m.uv[:, 0] = m.uv[:, 0]
        m.uv[:, 1] = (m.v[:, 1] - y0) / (y1 - y0)
        m.weights(torso_weights)
        add("do_row%d" % k, m, "lamellar_hishi" if k == 0 else "lamellar", uv="lame")
    # chest plate (munaita), with the pigeon-breast ridge
    ys = [1.365, 1.42, 1.48, 1.54, 1.60, 1.63, 1.645]
    rings = [torso_ring(y, 1.0 + (0.004 if y < 1.63 else -0.03 * (y - 1.63) / 0.015), ridge=0.012 * smoothstep(1.62, 1.44, y))
             for y in reversed(ys)]
    m = G.loft(rings)
    m.weights(torso_weights)
    add("do_chest", m, "lacquer")
    # gold trims: bottom of the chest plate and its top rim
    for name, ya, yb, sc in (("do_trim_lo", 1.362, 1.385, 1.012), ("do_trim_hi", 1.625, 1.648, 0.99)):
        m = G.loft([torso_ring(yb, sc, ridge=0.01 * (ya < 1.5)), torso_ring(ya, sc + 0.006, ridge=0.01 * (ya < 1.5))])
        m.weights(torso_weights)
        add(name, m, "gold")
    # shoulder straps (watagami) over each shoulder, back to front
    for s, sx in SIDES:
        path = np.array([[0.150, 1.585, 0.160], [0.158, 1.655, 0.125], [0.165, 1.700, 0.030], [0.165, 1.700, -0.050],
                         [0.160, 1.665, -0.140], [0.152, 1.595, -0.190]])
        path[:, 0] *= sx
        m = G.ribbon(path, (1.0, 0.0, 0.0), 0.075)
        G.orient_dir(m, (0, 1, 0))
        m.bone("chest")
        add("watagami_" + s, m, "lacquer", solidify=0.012, bevel=0.003)
        clasp = G.box((0.05, 0.035, 0.018), (0.152 * sx, 1.585, -0.202)).bone("chest")
        add("clasp_" + s, clasp, "gold", subsurf=1)
    # chest crest (mon): gold disc, red lacquer disc, ember core (extra)
    front_z = -(0.210 + 0.012) - 0.004
    disc = G.revolve([(0.058, -0.006), (0.058, 0.004), (0.050, 0.010), (0.0, 0.011)], segs=24)
    disc.rotate("x", -90).translate((0, 1.50, front_z)).bone("chest")
    add("mon_gold", disc, "gold")
    inner = G.revolve([(0.040, 0.0), (0.040, 0.014), (0.0, 0.015)], segs=20)
    inner.rotate("x", -90).translate((0, 1.50, front_z)).bone("chest")
    add("mon_red", inner, "lamellar", uv="tile")
    core = G.revolve([(0.0, -0.015), (0.012, -0.012), (0.016, 0.0), (0.012, 0.012), (0.0, 0.016)], segs=12)
    core.rotate("x", -90).translate((0, 1.50, front_z - 0.02)).bone("chest")
    add_extra("mon_ember", core, "ember")
    # agemaki ring on the back
    ring = G.sweep([[0.03 * math.cos(a), 1.46 + 0.03 * math.sin(a), 0.19] for a in np.linspace(0, 2 * math.pi, 17)], 0.006, 6)
    ring.bone("chest")
    add("agemaki_ring", ring, "gold")


def build_kusazuri():
    panels = [(-28, 50, "x_kusa_fl"), (28, 50, "x_kusa_fr"), (-82, 48, "x_kusa_sl"), (82, 48, "x_kusa_sr"),
              (-134, 50, None), (134, 50, None), (180, 46, None)]
    for pi, (ac, arc, helper) in enumerate(panels):
        for k in range(5):
            y_top = 1.078 - k * 0.063
            y_bot = y_top - 0.076
            r_top = 0.230 + 0.016 * k
            r_bot = r_top + 0.015
            m = band(ac - arc / 2, ac + arc / 2, y_bot, y_top, r_bot, r_top, segs=6, sz=0.80, mid=0.002)

            def wfn(v, k=k, helper=helper):
                if helper is None:
                    return {"hips": np.ones(len(v))}
                if k == 0:
                    return {"hips": np.full(len(v), 0.55), helper: np.full(len(v), 0.45)}
                return {helper: np.ones(len(v))}
            m.weights(wfn)
            add("kusazuri%d_%d" % (pi, k), m, "lamellar_hishi" if k == 4 else "lamellar", uv="lame",
                solidify=0.005, bevel=0.0015)


def build_legs():
    for s, sx in SIDES:
        cx = J["thigh_" + s][0]
        # hakama: wide pleated trousers, gathered below the knee
        prof = [(1.14, 0.146), (1.02, 0.152), (0.88, 0.156), (0.74, 0.158), (0.62, 0.154), (0.53, 0.138),
                (0.47, 0.112), (0.43, 0.086)]
        rings = []
        th = np.linspace(0, 2 * math.pi, 28, endpoint=False)
        for y, r in prof:
            pleat = 1.0 + 0.085 * np.sin(7 * th + 0.8 * sx) * smoothstep(1.10, 0.80, y) * smoothstep(0.40, 0.52, y)
            inner = np.where(np.sin(th) * sx < 0, 0.80, 1.0)       # flatter between the legs
            x = cx + np.sin(th) * r * pleat * inner
            z = -np.cos(th) * r * pleat
            rings.append(np.stack([x, np.full_like(x, y), z], axis=1))
        m = G.loft(rings)
        m.weights(lambda v, s=s: w_chain(v, ["hips", "thigh_" + s, "shin_" + s], [(1.02, 0.07), (0.55, 0.06)]))
        add("hakama_" + s, m, "hakama")
        # tie below the knee
        tie = G.revolve([(0.090, 0.425), (0.094, 0.44), (0.090, 0.455)], segs=16, center=(cx, 0, 0))
        tie.bone("shin_" + s)
        add("hakama_tie_" + s, tie, "cord")
        # kyahan (gaiter)
        g = G.revolve([(0.060, 0.075), (0.063, 0.16), (0.069, 0.30), (0.073, 0.40), (0.080, 0.47)], segs=16,
                      center=(cx, 0, 0.005))
        g.bone("shin_" + s)
        add("kyahan_" + s, g, "cloth_dark")
        # suneate: three splints with gold ends
        for k, ang in enumerate((-58.0, 0.0, 58.0)):
            sp = band(ang - 24, ang + 24, 0.135, 0.445, 0.080, 0.087, segs=5, center=(cx, 0, 0), mid=0.004)
            sp.uv[:, 1] = sp.v[:, 1]                       # lacquer: plain metres
            sp.bone("shin_" + s)
            add("suneate_%s%d" % (s, k), sp, "lacquer", solidify=0.006, bevel=0.002)
            for (ya, yb, ra) in ((0.43, 0.448, 0.0895), (0.135, 0.152, 0.0825)):
                gb = band(ang - 24.5, ang + 24.5, ya, yb, ra, ra, segs=5, center=(cx, 0, 0))
                gb.uv[:, 1] = gb.v[:, 1]
                gb.bone("shin_" + s)
                add("suneate_gold_%s%d_%d" % (s, k, int(ya * 100)), gb, "gold", solidify=0.004)
        # tateage (knee guard), attached to the shin
        kg = G.revolve([(0.088, 0.455), (0.102, 0.515), (0.100, 0.57), (0.086, 0.625)], -62, 62, 10, 1.0, 1.0,
                       center=(cx, 0, -0.012))
        kg.bone("shin_" + s)
        add("tateage_" + s, kg, "lacquer", solidify=0.006, bevel=0.002)
        kt = band(-63, 63, 0.448, 0.462, 0.089, 0.089, segs=10, center=(cx, 0, -0.012))
        kt.uv[:, 1] = kt.v[:, 1]
        kt.bone("shin_" + s)
        add("tateage_gold_" + s, kt, "gold", solidify=0.004)
        build_foot(s, sx, cx)


def build_foot(s, sx, cx):
    secs = [(0.078, 0.040, 0.090), (0.050, 0.050, 0.125), (0.0, 0.056, 0.138), (-0.050, 0.060, 0.108),
            (-0.100, 0.062, 0.082), (-0.150, 0.058, 0.066), (-0.185, 0.046, 0.054), (-0.205, 0.028, 0.042)]
    th = np.linspace(0, 2 * math.pi, 18, endpoint=False)
    rings = []
    for z, hw, top in secs:
        c, sn = np.cos(th), np.sin(th)
        e = 2.0 / 3.2
        x = cx + hw * np.sign(c) * np.abs(c) ** e
        y = 0.004 + top * 0.5 + (top * 0.5) * np.sign(sn) * np.abs(sn) ** e
        rings.append(np.stack([x, y, np.full_like(x, z)], axis=1))
    m = G.loft(rings)
    n = len(th) + 1
    last = (len(secs) - 1) * n
    G.fan_cap(m, list(range(0, len(th))), np.array(rings[0]).mean(axis=0), (0, 0, 1))
    G.fan_cap(m, list(range(last, last + len(th))), np.array(rings[-1]).mean(axis=0), (0, 0, -1))
    m.bone("foot_" + s)
    add("shoe_" + s, m, "leather")
    # kogake plate over the instep
    plate = G.revolve([(0.066, -0.16), (0.072, -0.10), (0.070, -0.04)], -70, 70, 8, 1.0, 1.0)
    # revolve builds around Y; turn it to lie along -Z over the foot
    plate.rotate("x", -90).translate((cx, 0.012, 0.0))
    plate.v[:, 1] = np.maximum(plate.v[:, 1], 0.02)
    plate.bone("foot_" + s)
    add("kogake_" + s, plate, "lacquer", solidify=0.005, bevel=0.0015)


def build_arms():
    for s, sx in SIDES:
        cx = J["upper_arm_" + s][0]
        out = -90.0 if sx < 0 else 90.0
        # upper sleeve (brocade), blends into the chest at the shoulder and the forearm at the elbow
        m = G.revolve([(0.062, 1.265), (0.068, 1.33), (0.073, 1.45), (0.077, 1.57), (0.074, 1.665)], segs=16,
                      center=(cx, 0, 0))
        m.weights(lambda v, s=s: w_chain(v, ["chest", "upper_arm_" + s, "forearm_" + s], [(1.615, 0.035), (1.30, 0.04)]))
        add("sleeve_" + s, m, "brocade")
        # forearm (mail) + outer plate + wrist cuff
        m = G.revolve([(0.050, 0.992), (0.054, 1.05), (0.060, 1.18), (0.064, 1.28), (0.064, 1.33)], segs=14,
                      center=(cx, 0, 0))
        m.weights(lambda v, s=s: w_chain(v, ["upper_arm_" + s, "forearm_" + s, "hand_" + s], [(1.30, 0.035), (1.0, 0.012)]))
        add("kote_" + s, m, "mail")
        pl = band(out - 58, out + 58, 1.045, 1.265, 0.062, 0.070, segs=8, center=(cx, 0, 0), mid=0.003)
        pl.uv[:, 1] = pl.v[:, 1]
        pl.bone("forearm_" + s)
        add("ikada_" + s, pl, "lacquer", solidify=0.005, bevel=0.0015)
        cuff = G.revolve([(0.057, 1.012), (0.059, 1.026), (0.057, 1.040)], segs=14, center=(cx, 0, 0))
        cuff.bone("forearm_" + s)
        add("cuff_" + s, cuff, "gold")
        # elbow cop
        cap = G.revolve([(0.046, 0.0), (0.040, 0.012), (0.024, 0.022), (0.0, 0.026)], segs=12)
        cap.rotate("z", -out).translate((cx + sx * 0.058, 1.30, 0.0))
        cap.bone("forearm_" + s)
        add("hijigane_" + s, cap, "lacquer", solidify=0.004, bevel=0.0015)
        # fist (gloved) + thumb + hand plate
        fist = G.box((0.080, 0.100, 0.094), (cx, 0.946, -0.004)).bone("hand_" + s)
        add("fist_" + s, fist, "leather", subsurf=2)
        thumb = G.box((0.030, 0.050, 0.032), (cx - sx * 0.018, 0.960, -0.052)).bone("hand_" + s)
        add("thumb_" + s, thumb, "leather", subsurf=2)
        tk = band(out - 50, out + 50, 0.905, 0.995, 0.050, 0.048, segs=8, center=(cx, 0, 0), mid=0.004)
        tk.uv[:, 1] = tk.v[:, 1]
        tk.bone("hand_" + s)
        add("tekko_" + s, tk, "lacquer", solidify=0.004, bevel=0.0015)
        # sode: six lames hanging from the shoulder (helper bone: halfway between chest and arm)
        for k in range(6):
            y_top = 1.742 - 0.056 * k
            y_bot = y_top - 0.070
            r_top = 0.118 + 0.011 * k
            r_bot = r_top + 0.013
            mat = "lacquer" if k == 0 else ("lamellar_hishi" if k == 5 else "lamellar")
            m = band(out - 60, out + 60, y_bot, y_top, r_bot, r_top, segs=8, center=(cx, 0, 0), mid=0.003)
            if mat == "lacquer":
                m.uv[:, 1] = m.v[:, 1]
            m.bone("x_sode_" + s)
            add("sode_%s%d" % (s, k), m, mat, uv="lame" if mat != "lacquer" else "tile", solidify=0.005, bevel=0.0015)
        gt = band(out - 60.5, out + 60.5, 1.735, 1.745, 0.1185, 0.1185, segs=10, center=(cx, 0, 0))
        gt.uv[:, 1] = gt.v[:, 1]
        gt.bone("x_sode_" + s)
        add("sode_gold_" + s, gt, "gold", solidify=0.004)


# ================================================================ head
HEAD_C = np.array([0.0, 1.835, 0.0])


def mask_shape(s, t):
    """Oni mask surface. s: -1 (left) .. 1 (right), t: -1 (chin) .. 1 (brow).
    Returns (points (…, 3), displacement (…)) in game space."""
    s = np.asarray(s, dtype=float)
    t = np.asarray(t, dtype=float)
    phi = s * math.radians(80.0)
    a = np.interp(t, [-1, 0, 1], [0.086, 0.113, 0.108])
    c = np.interp(t, [-1, 0, 1], [0.100, 0.122, 0.118])
    y = HEAD_C[1] - 0.003 + t * 0.10
    as_ = np.abs(s)
    d = np.zeros_like(s)
    g = lambda x, x0, w: np.exp(-((x - x0) / w) ** 2)
    # chin + jaw
    d += 0.013 * g(t, -0.82, 0.18) * g(s, 0, 0.35)
    # nose: bridge widening to the tip, ball tip, flared wings
    win = smoothstep(-0.16, -0.02, t) * smoothstep(0.62, 0.45, t)
    h = 0.016 + 0.034 * np.clip((0.55 - t) / 0.6, 0, 1)
    d += h * g(s, 0, 0.09 + 0.10 * np.clip(0.5 - t, 0, 1)) * win
    d += 0.012 * g(s, 0, 0.12) * g(t, -0.02, 0.10)
    d += 0.016 * g(as_, 0.17, 0.08) * g(t, -0.05, 0.07)
    # angry brows: V shaped ridges, heavy at the inner end
    for side in (-1, 1):
        p0 = np.array([0.10, 0.50])
        p1 = np.array([0.64, 0.80])
        q = np.stack([s * side, t], axis=-1)
        seg = p1 - p0
        u = np.clip(((q - p0) @ seg) / (seg @ seg), 0, 1)
        proj = p0 + u[..., None] * seg
        dist = np.linalg.norm(q - proj, axis=-1)
        hb = 0.026 - 0.010 * u
        d += np.where(s * side > 0, hb * np.exp(-(dist / 0.075) ** 2), 0.0)
    d += 0.009 * g(s, 0, 0.07) * g(t, 0.55, 0.10)                      # glabella
    d -= 0.004 * g(as_, 0.045, 0.02) * g(t, 0.55, 0.10)                 # frown lines
    # eye sockets, cheekbones, nasolabial folds
    d -= 0.020 * g(as_, 0.33, 0.17) * g(t, 0.36, 0.11)
    d += 0.016 * g(as_, 0.52, 0.18) * g(t, 0.15, 0.12)
    fold_t = -0.02 - (as_ - 0.20) * 1.3
    d -= 0.008 * g(t, fold_t, 0.05) * smoothstep(0.16, 0.24, as_) * smoothstep(0.50, 0.40, as_)
    # snarling lips around the mouth opening
    d += 0.012 * g(t, -0.17, 0.06) * smoothstep(0.50, 0.38, as_)
    d += 0.011 * g(t, -0.58, 0.06) * smoothstep(0.46, 0.34, as_)
    d -= 0.008 * g(as_, 0.47, 0.06) * g(t, -0.38, 0.12)
    base = np.stack([a * np.sin(phi), y, -c * np.cos(phi)], axis=-1)
    n = np.stack([np.sin(phi) / a, np.zeros_like(phi), -np.cos(phi) / c], axis=-1)
    n = n / np.linalg.norm(n, axis=-1, keepdims=True)
    d = d * 1.35
    return base + HEAD_C * [1, 0, 1] + n * d[..., None], d


def eye_hole(s, t):
    as_ = np.abs(s)
    k = np.clip((as_ - 0.19) / 0.30, 0, 1)
    tc = 0.36 + 0.07 * k
    hh = 0.070 * np.sin(np.pi * k)
    return (as_ > 0.19) & (as_ < 0.49) & (np.abs(t - tc) < hh)


def mouth_hole(s, t):
    as_ = np.abs(s)
    return (as_ < 0.40 - 0.25 * np.clip((np.abs(t + 0.37) - 0.08) / 0.07, 0, 1)) & (t > -0.52) & (t < -0.22)


def mask_texture(n=512):
    """Painted in the mask's (s, t) space: red lacquer, dark creases, black brows and eye rims."""
    s, t = np.meshgrid(np.linspace(-1, 1, n), np.linspace(1, -1, n))
    _, d = mask_shape(s, t)
    lap = (np.roll(d, 1, 0) + np.roll(d, -1, 0) + np.roll(d, 1, 1) + np.roll(d, -1, 1) - 4 * d) / (2.0 / n) ** 2
    cav = np.clip(lap * 0.25, 0, 1)             # concave creases
    red = np.array([0.62, 0.075, 0.05])
    nz = T.noise(n, n, 18, seed=71)
    c = red[None, None, :] * (0.85 + 0.3 * nz[..., None])
    c *= (1.0 - 0.65 * cav)[..., None]
    rough = np.full((n, n), 0.25)
    # black lacquered brows
    brow = np.zeros((n, n))
    for side in (-1, 1):
        p0 = np.array([0.10, 0.50])
        p1 = np.array([0.64, 0.80])
        q = np.stack([s * side, t], axis=-1)
        seg = p1 - p0
        u = np.clip(((q - p0) @ seg) / (seg @ seg), 0, 1)
        dist = np.linalg.norm(q - (p0 + u[..., None] * seg), axis=-1)
        brow = np.maximum(brow, ((dist < 0.055 - 0.02 * u) & (s * side > 0)).astype(float))
    c = c * (1 - brow[..., None]) + np.array([0.035, 0.02, 0.02]) * brow[..., None]
    # eye rims and mouth interior dark, gold teeth line along the upper lip
    eye = eye_hole(s, (t - 0.39) * 0.8 + 0.39) | eye_hole(s * 1.06, t) | eye_hole(s * 0.95, t)
    c[eye] = [0.02, 0.01, 0.01]
    mouth = mouth_hole(s * 0.96, t)
    c[mouth] = [0.05, 0.01, 0.01]
    lip_gold = (np.abs(t + 0.215) < 0.018) & (np.abs(s) < 0.40)
    c[lip_gold] = [0.80, 0.60, 0.26]
    # wrinkle lines on the cheeks
    for k in range(3):
        wl = np.abs(t - (0.05 - 0.09 * k) - (np.abs(s) - 0.55) * 0.6) < 0.008
        wl &= (np.abs(s) > 0.52) & (np.abs(s) < 0.72)
        c[wl] *= 0.45
    metal = np.where(lip_gold, 1.0, 0.0)
    return {"color": np.clip(c, 0, 1), "rough": rough, "metal": metal}


def build_mask():
    nu, nv = 44, 38
    su = np.linspace(-1, 1, nu + 1)
    tv = np.linspace(-1, 1, nv + 1)
    S, Tt = np.meshgrid(su, tv)
    P, _ = mask_shape(S, Tt)
    uv = np.stack([(S + 1) / 2, (Tt + 1) / 2], axis=-1)
    m = G.surface(P, uv)
    # cut the eye and mouth openings
    keep = []
    for f in m.f:
        c_uv = m.uv[list(f)].mean(axis=0) * 2 - 1
        if eye_hole(c_uv[0], c_uv[1]) or mouth_hole(c_uv[0], c_uv[1]):
            continue
        keep.append(f)
    m.f = keep
    G.orient_dir(m, (0, 0, -1))
    m.bone("head")
    add("menpo", m, "mask", uv="unit", solidify=0.004, bevel=0.0)
    # fangs (upper pair long, lower pair short) and eye embers behind the holes
    def fang(s0, t0, length, down):
        p, _ = mask_shape(np.array(s0), np.array(t0))
        cone = G.revolve([(0.011, 0.0), (0.008, length * 0.5), (0.0, length)], segs=8)
        if down:
            cone.rotate("x", 180)
        cone.rotate("x", -12 if down else 12)
        cone.translate(p + np.array([0, 0, 0.004]))
        cone.bone("head")
        return cone
    for side in (-1, 1):
        add("fang_up_%d" % side, fang(0.29 * side, -0.25, 0.048, True), "teeth")
        add("fang_lo_%d" % side, fang(0.17 * side, -0.49, 0.030, False), "teeth")
        tc = 0.36 + 0.07 * 0.5
        p, _ = mask_shape(np.array(0.335 * side), np.array(tc))
        eye = G.revolve([(0.0, -0.012), (0.016, -0.006), (0.018, 0.0), (0.016, 0.006), (0.0, 0.012)], segs=10)
        eye.scale((1.75, 0.75, 0.55)).rotate("z", -13 * side).translate(p + np.array([0, 0, 0.0045]))
        eye.bone("head")
        add_extra("eye_%d" % side, eye, "ember")
    # teeth row inside the upper lip
    p0, _ = mask_shape(np.array(-0.36), np.array(-0.25))
    p1, _ = mask_shape(np.array(0.36), np.array(-0.25))
    path = [mask_shape(np.array(x), np.array(-0.25))[0] + np.array([0, 0, 0.006]) for x in np.linspace(-0.36, 0.36, 9)]
    teeth = G.ribbon(path, (0, 1, 0), 0.018)
    G.orient_dir(teeth, (0, 0, -1))
    teeth.bone("head")
    add("teeth_row", teeth, "gold", solidify=0.003)


def build_head():
    # dark filler inside the helmet
    m = G.revolve([(0.0, 1.735), (0.062, 1.76), (0.076, 1.82), (0.076, 1.92), (0.060, 1.975), (0.0, 1.99)], segs=16,
                  center=(0, 0, 0.018))
    m.bone("head")
    add("head_dark", m, "dark")
    # neck filler + throat guard (yodare-kake) hanging from the mask
    m = G.revolve([(0.080, 1.595), (0.075, 1.70), (0.072, 1.80), (0.068, 1.86)], segs=14, center=(0, 0, 0.005))
    m.weights(lambda v: w_chain(v, ["chest", "neck", "head"], [(1.68, 0.04), (1.79, 0.04)]))
    add("neck", m, "cloth_dark")
    for k in range(3):
        y_top = 1.748 - 0.040 * k
        m = band(-112, 112, y_top - 0.052, y_top, 0.118 + 0.013 * k + 0.012, 0.106 + 0.013 * k, segs=14,
                 center=(0, 0, 0.012), sz=1.0, mid=0.002)
        m.bone("head")
        add("yodare_%d" % k, m, "lamellar_hishi" if k == 2 else "lamellar", uv="lame", solidify=0.004, bevel=0.0012)
    # helmet bowl (suji-bachi) with raised ridges
    prof = [(0.140, 1.922), (0.143, 1.955), (0.139, 1.99), (0.127, 2.03), (0.104, 2.063), (0.070, 2.088),
            (0.034, 2.100), (0.004, 2.104)]
    bowl = G.revolve(prof, segs=40, sz=1.07)
    th = np.arctan2(bowl.v[:, 0], -bowl.v[:, 2])
    ridge = (np.cos(th * 20) > 0.55).astype(float) * smoothstep(2.09, 2.05, bowl.v[:, 1])
    bowl.v[:, [0, 2]] *= (1.0 + 0.022 * ridge)[:, None]
    bowl.bone("head")
    add("hachi", bowl, "lacquer")
    koshi = G.revolve([(0.1435, 1.915), (0.1455, 1.928), (0.1435, 1.941)], segs=40, sz=1.07)
    koshi.bone("head")
    add("koshimaki", koshi, "gold")
    tehen = G.revolve([(0.036, 2.095), (0.037, 2.104), (0.024, 2.114), (0.010, 2.119), (0.0, 2.12)], segs=16)
    tehen.bone("head")
    add("tehen", tehen, "gold")
    # visor (mabizashi)
    vis = G.revolve([(0.180, 1.906), (0.162, 1.916), (0.146, 1.926)], -78, 78, 16, 1.0, 1.07)
    vis.bone("head")
    add("mabizashi", vis, "lacquer", solidify=0.005, bevel=0.0015)
    # neck guard (shikoro): four flaring lames around the back
    for k in range(3):
        y_top = 1.935 - 0.055 * k
        m = band(56, 304, y_top - 0.072, y_top, 0.150 + 0.019 * k + 0.024, 0.150 + 0.019 * k, segs=16,
                 sz=1.05, mid=0.004)
        m.bone("head")
        add("shikoro_%d" % k, m, "lamellar_hishi" if k == 2 else "lamellar", uv="lame", solidify=0.005, bevel=0.0015)
    # fukigaeshi: turned-back wings beside the face
    for s, sx in SIDES:
        a = math.radians(56)
        base_top = np.array([math.sin(a) * 0.152 * sx, 1.938, -math.cos(a) * 0.152 * 1.05])
        base_bot = np.array([math.sin(a) * 0.178 * sx, 1.872, -math.cos(a) * 0.178 * 1.05])
        out_dir = np.array([0.80 * sx, 0.0, 0.55])            # curls back beside the face
        grid = np.array([[base_bot + out_dir * w * 0.045 + np.array([0, 0, 0.010 * w * w]) for w in (0, 0.5, 1)],
                         [base_top + out_dir * w * 0.055 + np.array([0, 0.003 * w, 0.012 * w * w]) for w in (0, 0.5, 1)]])
        uvg = np.array([[[0, 0], [0.04, 0], [0.08, 0]], [[0, 0.1], [0.04, 0.1], [0.08, 0.1]]])
        m = G.surface(grid, uvg)
        G.orient_dir(m, (0, 0, -1))
        m.bone("head")
        add("fukigaeshi_" + s, m, "lacquer", solidify=0.006, bevel=0.002)

    # kuwagata: two flat gilt blades rising from the brow
    for s, sx in SIDES:
        pts = np.array([[0.030, 1.955, -0.152], [0.075, 2.02, -0.160], [0.125, 2.10, -0.158], [0.162, 2.18, -0.150],
                        [0.183, 2.26, -0.138], [0.190, 2.32, -0.124]])
        pts[:, 0] *= sx
        tang = np.gradient(pts, axis=0)
        wdir = np.cross(tang, np.array([0.0, 0.0, 1.0]))
        m = G.ribbon(pts, wdir, np.array([0.046, 0.040, 0.032, 0.024, 0.016, 0.006]))
        G.orient_dir(m, (0, 0, -1))
        m.bone("head")
        add("kuwagata_" + s, m, "gold", solidify=0.007, bevel=0.0015)
    base = G.box((0.10, 0.034, 0.014), (0.0, 1.958, -0.156)).bone("head")
    add("maedate_base", base, "gold", subsurf=1)
    ring = G.sweep([[0.028 * math.cos(a), 1.978 + 0.028 * math.sin(a), -0.166] for a in np.linspace(0, 2 * math.pi, 17)], 0.006, 6)
    ring.bone("head")
    add("orb_ring", ring, "gold")
    orb = G.revolve([(0.0, -0.021), (0.015, -0.015), (0.021, 0.0), (0.015, 0.015), (0.0, 0.021)], segs=14)
    orb.translate((0.0, 1.978, -0.168)).bone("head")
    add_extra("orb", orb, "ember")
    build_mask()
    build_hair_tuft()


def hair_card(path, width, normal_hint):
    """A curved hair card along `path` (root first), u across, v 0 (root) .. 1 (tip)."""
    P = np.asarray(path, dtype=float)
    tang = np.gradient(P, axis=0)
    wdir = np.cross(tang, np.asarray(normal_hint, dtype=float))
    m = G.ribbon(P, wdir, width)
    m.uv[:, 0] = m.uv[:, 0] / np.maximum(m.uv[:, 0].max(), 1e-6)
    m.uv[:, 1] = m.uv[:, 1] / m.uv[:, 1].max()
    return m


def build_hair_tuft():
    """Static white horsehair (haguma) on the crown, flowing back over the neck guard; the long
    strands are the spring-chain ribbons added by the game."""
    rng = np.random.default_rng(5)
    for layer, (n, length, width) in enumerate(((8, 0.42, 0.095), (5, 0.28, 0.08))):
        for i in range(n):
            th = math.radians(180.0 + (i - (n - 1) / 2) * (110.0 / (n - 1)))
            radial = np.array([math.sin(th), 0.0, -math.cos(th)])
            r0 = 0.105 - 0.012 * layer
            root = np.array([0.0, 2.072 + 0.012 * layer, 0.0]) + radial * r0 * np.array([1.0, 0.0, 1.07])
            pts = []
            for k in range(6):
                u = k / 5
                out = radial * (0.03 + 0.08 * u - 0.02 * u * u)
                pts.append(root + out + np.array([0.0, 0.03 * u - length * u ** 1.5, 0.05 * u]) + rng.normal(0, 0.004, 3))
            m = hair_card(pts, np.linspace(width, width * 0.55, 6), radial)
            m.bone("head")
            add_extra("mane_%d_%d" % (layer, i), m, "hair", smooth=80.0)
    # beard hanging from the chin, mustache under the nose
    for i, sx0 in enumerate((-0.05, 0.0, 0.05)):
        root, _ = mask_shape(np.array(sx0 / 0.15), np.array(-0.78))
        pts = [root + np.array([sx0 * 0.4 * u, -0.17 * u, -0.012 - 0.03 * u + 0.02 * u * u]) for u in np.linspace(0, 1, 5)]
        m = hair_card(pts, np.linspace(0.055, 0.03, 5), (0, 0, -1))
        m.bone("head")
        add_extra("beard_%d" % i, m, "hair", smooth=80.0)
    for side in (-1, 1):
        root, _ = mask_shape(np.array(0.10 * side), np.array(-0.13))
        pts = [root + np.array([side * 0.07 * u, -0.05 * u * u, -0.012 + 0.012 * u]) for u in np.linspace(0, 1, 4)]
        m = hair_card(pts, np.linspace(0.028, 0.012, 4), (0, 0, -1))
        m.bone("head")
        add_extra("mustache_%d" % side, m, "hair", smooth=80.0)


# ================================================================ staff (weapon space)
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


def staff_end():
    """One end of the staff (upper): gold ferrule, horned guard, collar and blade."""
    parts = []
    ferrule = G.revolve([(0.031, 0.835), (0.033, 0.845), (0.040, 0.868), (0.049, 0.892), (0.044, 0.905), (0.0, 0.906)], segs=16)
    parts.append((ferrule, "staff_gold", (0.08, 0.08)))
    for sx in (-1.0, 1.0):
        path = [np.array([0.012 * sx + 0.09 * sx * u ** 0.8, 0.893 + 0.10 * u ** 1.6, 0.0]) for u in np.linspace(0, 1, 7)]
        horn = G.sweep(path, np.linspace(0.013, 0.003, 7), 8, sx=1.0, sy=0.55)
        parts.append((horn, "staff_gold", (0.08, 0.08)))
    habaki = G.revolve([(0.020, 0.902), (0.022, 0.935), (0.0, 0.936)], segs=12)
    habaki.scale((1.6, 1.0, 0.8))
    parts.append((habaki, "staff_gold", (0.08, 0.08)))
    parts.append((blade_mesh(), "blade", (1.0, 1.0)))
    return parts


def build_staff():
    table = {
        "staff_lacquer": T.lacquer(color=(0.03, 0.028, 0.03), mottle=0.3, rough=0.2),
        "staff_gold": T.gold(),
        "staff_wrap": T.tsukamaki(),
        "blade": T.hamon(),
    }
    mats = {}
    for name, tex in table.items():
        col = B.numpy_to_image(name + "_col", tex["color"])
        orm = B.numpy_to_image(name + "_orm", np.stack([np.ones_like(tex["rough"]), tex["rough"], tex["metal"]], axis=2))
        orm.colorspace_settings.name = "Non-Color"
        glow = None
        if "glow" in tex:
            glow = B.numpy_to_image(name + "_glow", np.repeat(tex["glow"][..., None], 3, axis=2))
        mats[name] = BM.textured_material(name, col, orm, emission_img=glow)
    pieces = []
    shaft = G.revolve([(0.029, -0.84), (0.029, 0.84)], segs=14)
    pieces.append((shaft, "staff_lacquer", (0.2, 0.2)))
    circ = 2 * math.pi * 0.0335
    wrap = G.revolve([(0.0335, -0.25), (0.0335, 0.25)], segs=16)
    pieces.append((wrap, "staff_wrap", (circ / 2.0, 0.042)))
    for yv in (-0.76, -0.52, -0.265, 0.265, 0.52, 0.76):
        ring = G.revolve([(0.033, yv - 0.011), (0.035, yv - 0.004), (0.035, yv + 0.004), (0.033, yv + 0.011)], segs=14)
        pieces.append((ring, "staff_gold", (0.08, 0.08)))
    for flip in (False, True):
        for m, mat, tile in staff_end():
            if flip:
                m.rotate("x", 180)
            pieces.append((m, mat, tile))
    objs = []
    for i, (m, mat, tile) in enumerate(pieces):
        uv = m.uv / np.array(tile)
        objs.append(B.mesh_object("staff_%d" % i, m.v, m.f, uv, "uv", None, 35.0, mats[mat]))
    staff = B.join(objs, "TwinFang")
    print("staff:", B.mesh_stats(staff))
    return staff


# ================================================================ Blender assembly
def add_helper_bones(arm):
    B.activate(arm)
    bpy.ops.object.mode_set(mode="EDIT")
    eb = arm.data.edit_bones
    for name, h in HELPERS.items():
        b = eb.new(name)
        p = np.array(h["pivot"], dtype=float)
        b.head = B.to_bl(p)
        b.tail = B.to_bl(p + np.array([0.0, -0.1, 0.0]))
        b.parent = eb[h["a"]]
    bpy.ops.object.mode_set(mode="OBJECT")


def part_object(p, mats, table):
    m = p.mesh
    uv = m.uv.copy()
    if p.mat in table:
        tu, tv = table[p.mat][1]
        if p.uv == "tile":
            uv = uv / np.array([tu, tv])
        elif p.uv == "lame":
            uv[:, 0] = uv[:, 0] / tu
    groups = {k: w for k, w in m.w.items()}
    obj = B.mesh_object(p.name, m.v, m.f, uv, "pattern", groups, p.smooth, mats[p.mat])
    if p.subsurf:
        mod = obj.modifiers.new("sub", "SUBSURF")
        mod.levels = p.subsurf
        mod.render_levels = p.subsurf
    if p.solidify:
        mod = obj.modifiers.new("solid", "SOLIDIFY")
        mod.thickness = p.solidify
        mod.offset = -1.0
        mod.use_even_offset = True
    if p.bevel:
        mod = obj.modifiers.new("bevel", "BEVEL")
        mod.width = p.bevel
        mod.segments = 1
        mod.limit_method = "ANGLE"
        mod.angle_limit = math.radians(50)
    B.apply_modifiers(obj)
    return obj


def bake_pose(arm, on=True):
    """Arms out and legs apart while baking, so occlusion isn't baked into the flanks."""
    C = Matrix(((1, 0, 0), (0, 0, -1), (0, 1, 0)))
    B.activate(arm)
    bpy.ops.object.mode_set(mode="POSE")
    for pb in arm.pose.bones:
        pb.matrix_basis = Matrix.Identity(4)
    if on:
        bpy.context.view_layer.update()
        for s, sx in SIDES:
            for bone, deg in (("upper_arm_" + s, 38.0), ("thigh_" + s, 7.0), ("x_sode_" + s, 20.0)):
                pb = arm.pose.bones[bone]
                piv = pb.bone.head_local
                Rg = Matrix(G.rot("z", -deg * (-sx)).tolist())       # rotate outward about the front axis
                Rb = (C @ Rg @ C.transposed()).to_4x4()
                M = Matrix.Translation(piv) @ Rb @ Matrix.Translation(-piv) @ pb.bone.matrix_local
                pb.matrix = M
                bpy.context.view_layer.update()
    bpy.ops.object.mode_set(mode="OBJECT")
    bpy.context.view_layer.update()


def build_body(args):
    t0 = time.time()
    table = material_table()
    mats = {}
    for key, (tex, tile, params, _) in table.items():
        mats[key] = BM.pattern_material(key, tex, **params)
    arm, _ = B.make_armature(RIG, "Skeleton")
    add_helper_bones(arm)
    build_torso()
    build_kusazuri()
    build_legs()
    build_arms()
    build_head()
    objs = [part_object(p, mats, table) for p in PARTS if p.mat != "mask"]
    body = B.join(objs, "BossBody")
    # the oni mask keeps its own painted UVs and texture (sharper, no seams across the face)
    mask = B.join([part_object(p, mats, table) for p in PARTS if p.mat == "mask"], "BossMask")
    mlay = mask.data.uv_layers.new(name="atlas")
    src = mask.data.uv_layers["pattern"]
    buf = np.zeros(len(mask.data.loops) * 2, dtype=np.float32)
    src.data.foreach_get("uv", buf)
    mlay.data.foreach_set("uv", buf)
    mask.data.shade_smooth()
    me = body.data
    me.shade_smooth()
    me.set_sharp_from_angle(angle=math.radians(40))
    print("body built:", B.mesh_stats(body), "%.1fs" % (time.time() - t0))
    # extras (not baked)
    hair_img = B.numpy_to_image("boss_hair", np.dstack([T.hair()["color"], T.hair()["alpha"]]))
    extra_mats = {
        "ember": BM.flat_material("ember", (1.0, 0.36, 0.08), 1.0, 0.0, emission=(1.0, 0.36, 0.08)),
        "hair": BM.textured_material("hair", hair_img, alpha=True),
    }
    extra_objs = []
    for p in EXTRAS:
        o = B.mesh_object(p.name, p.mesh.v, p.mesh.f, p.mesh.uv, "atlas", dict(p.mesh.w), p.smooth, extra_mats[p.mat])
        extra_objs.append(o)
    extras = B.join(extra_objs, "BossExtras")
    # skin
    for o in (body, mask, extras):
        B.skin_to(o, arm)
        B.normalize_weights(o)
    # atlas UVs with more texels for the face
    idx = {slot.material.name: i for i, slot in enumerate(body.material_slots)}
    scale = {idx[k]: v[3] for k, v in table.items() if k in idx}
    B.smart_uv(body, "atlas", angle=55.0, margin=0.003, island_scale=scale)
    print("uv done %.1fs" % (time.time() - t0))
    size = args.atlas
    color = B.new_image("boss_body", size)
    orm = B.new_image("boss_body_orm", size // 2)
    orm.colorspace_settings.name = "Non-Color"
    mask_color = B.new_image("boss_mask", 1024)
    mask_orm = B.new_image("boss_mask_orm", 512)
    mask_orm.colorspace_settings.name = "Non-Color"
    if not args.no_bake:
        bake_pose(arm, True)
        BM.set_mode(list(mats.values()), 0)
        B.bake_emit(body, color, "atlas", margin=8, samples=args.samples)
        B.bake_emit(mask, mask_color, "atlas", margin=8, samples=args.samples)
        print("colour baked %.1fs" % (time.time() - t0))
        BM.set_mode(list(mats.values()), 1)
        B.bake_emit(body, orm, "atlas", margin=4, samples=1)
        B.bake_emit(mask, mask_orm, "atlas", margin=4, samples=1)
        print("orm baked %.1fs" % (time.time() - t0))
        bake_pose(arm, False)
    os.makedirs(PREVIEW_DIR, exist_ok=True)
    B.save_image(color, os.path.join(PREVIEW_DIR, "boss_atlas.png"))
    B.save_image(orm, os.path.join(PREVIEW_DIR, "boss_atlas_orm.png"))
    B.save_image(mask_color, os.path.join(PREVIEW_DIR, "boss_mask.png"))
    for img in (color, orm, mask_color, mask_orm):
        img.pack()
    for obj, name, c_img, o_img in ((body, "boss_body", color, orm), (mask, "boss_mask", mask_color, mask_orm)):
        final = BM.textured_material(name, c_img, o_img)
        obj.data.materials.clear()
        obj.data.materials.append(final)
        for poly in obj.data.polygons:
            poly.material_index = 0
        obj.data.uv_layers.remove(obj.data.uv_layers["pattern"])
    # textures for the game's spring-chain ribbons: the mane and the silk sashes/tassels
    from PIL import Image
    Image.fromarray(T.to_uint8(T.hair(), alpha=True)).save(os.path.join(B.ROOT, HAIR_PNG))
    Image.fromarray(T.to_uint8(T.sash())).save(os.path.join(B.ROOT, SASH_PNG))
    return arm, body, mask, extras


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--preview", action="store_true")
    ap.add_argument("--no-bake", action="store_true")
    ap.add_argument("--atlas", type=int, default=2048)
    ap.add_argument("--samples", type=int, default=48)
    args = ap.parse_args()
    B.reset_scene()
    arm, body, mask, extras = build_body(args)
    out = os.path.join(B.ROOT, BODY_GLB)
    B.export_glb([arm, body, mask, extras], out)
    print("wrote", out, B.mesh_stats(body), B.mesh_stats(extras))
    staff = build_staff()
    B.export_glb([staff], os.path.join(B.ROOT, STAFF_GLB))
    if args.preview:
        bpy.context.scene.view_settings.view_transform = "Standard"
        B.render_views(os.path.join(PREVIEW_DIR, "boss_views.png"),
                       [(0, 8), (35, 10), (90, 5), (180, 10)], target=(0, 1.1, 0), dist=5.6)
        B.render_views(os.path.join(PREVIEW_DIR, "boss_head.png"),
                       [(0, 5, 1.1, (0, 1.9, 0)), (40, 10, 1.1, (0, 1.9, 0)), (120, 15, 1.3, (0, 1.9, 0))],
                       size=(480, 480))


if __name__ == "__main__":
    main()
