#!/usr/bin/env python3
"""Builds the shinobi's model: models/player.glb (skinned to the player rig) and
models/player_katana.glb (the sword, in weapon space), plus the textures of the game's ribbons
(models/player_scarf.png, models/player_band.png).

    pip install bpy==4.5.9                          # Blender 4.5 LTS as a Python module (once)
    python3 tools/build_player_model.py             # build + bake + export (~2 min)
    python3 tools/build_player_model.py --preview   # also render tools/preview_out/player_*.png
    python3 tools/build_player_model.py --shapes    # no bake, no export: a quick look at the shapes

Built like the boss (tools/build_boss_model.py): parametric pieces in game space (a lofted hood
and jacket, revolved sleeves and trousers, ribbons and sweeps), skinned by rule (rigid plates,
blended cloth, helper bones for the shoulder guards and the jacket's skirt), then Cycles bakes
the pattern textures with ambient occlusion and worn edges into one atlas. The eyes behind the
slit of the hood are painted in a texture of their own. Then run `godot --headless --editor --quit`.

The design: a hooded, masked shinobi in indigo quilted with sashiko, a crimson obi and scarf,
iron shoulder guards, splinted forearm guards over pale wraps, slim trousers tied into pale
shin wraps, split-toed tabi on straw sandals, an iron plate on his headband and the empty
scabbard at his left hip.
"""
import argparse
import math
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import bpy  # noqa: E402
import numpy as np  # noqa: E402

from model3d import bakemat as BM  # noqa: E402
from model3d import blender_io as B  # noqa: E402
from model3d import geo as G  # noqa: E402
from model3d import textures as T  # noqa: E402
from model3d.blades import blade_mesh  # noqa: E402
from model3d.charkit import SIDES, Part, add_helper_bones, bake_pose, band, part_object, w_chain  # noqa: E402
from model3d.geo import smoothstep  # noqa: E402
from model3d.player_spec import (BAND_PNG, BODY_GLB, HELPERS, HEM_BOT, HEM_PANELS, HEM_TOP,  # noqa: E402
                                 HEM_WIDTH, KATANA_GLB, SCARF_PNG, hem_point)

RIG = B.load_rig("player")
J = B.rest_positions(RIG)
PREVIEW_DIR = os.path.join(B.ROOT, "tools", "preview_out")

INDIGO = (0.070, 0.088, 0.150)      # the jacket
HOOD = (0.055, 0.062, 0.085)        # hood and mask
CHARCOAL = (0.12, 0.12, 0.135)      # trousers
WRAP = (0.40, 0.38, 0.34)           # forearm and shin wraps
CRIMSON = (0.36, 0.05, 0.045)       # obi, scarf, lacing
IRON = (0.15, 0.15, 0.16)
LAME_W = 0.06


# pattern materials: key -> (texture, (tile u, tile v) metres, bake params, atlas texel scale)
def material_table():
    return {
        "sashiko": (T.sashiko(color=INDIGO, thread=(0.22, 0.25, 0.33), cells=10), (0.12, 0.12), dict(edge=0.05, edge_color=(0.22, 0.25, 0.34), ao=0.7, ao_dist=0.08), 1.0),
        "hood": (T.cloth(color=HOOD, weave=0.12, seed=24), (0.06, 0.06), dict(edge=0.0, ao=0.7, ao_dist=0.05), 1.4),
        "trousers": (T.cloth(color=CHARCOAL, weave=0.12, seed=25), (0.08, 0.08), dict(edge=0.0, ao=0.65, ao_dist=0.07), 0.8),
        "wrap": (T.wrap(color=WRAP), (0.12, 0.12), dict(edge=0.0, ao=0.7, ao_dist=0.04), 1.0),
        "obi": (T.obi(color=CRIMSON), (0.10, 1.0), dict(edge=0.04, edge_color=(0.30, 0.10, 0.08), ao=0.6), 1.0),
        "scarf": (T.cloth(color=(0.40, 0.055, 0.05), weave=0.15, seed=26), (0.05, 0.05), dict(edge=0.0, ao=0.6, ao_dist=0.04), 1.0),
        "collar": (T.cloth(color=(0.42, 0.43, 0.46), weave=0.1, seed=27), (0.05, 0.05), dict(edge=0.04, edge_color=(0.5, 0.5, 0.52), ao=0.6), 1.0),
        "band": (T.cloth(color=(0.09, 0.10, 0.16), weave=0.14, seed=29), (0.04, 0.04), dict(edge=0.0, ao=0.6), 1.0),
        "mask": (T.cloth(color=(0.07, 0.08, 0.125), weave=0.12, seed=30), (0.06, 0.06), dict(edge=0.0, ao=0.7, ao_dist=0.05), 1.3),
        "armour": (T.iron(color=(0.10, 0.10, 0.11), rough=0.5, metal=0.55), (0.10, 0.10),
                   dict(edge=0.16, edge_color=(0.34, 0.32, 0.30), ao=0.6), 1.2),
        "tabi": (T.cloth(color=(0.075, 0.08, 0.10), weave=0.1, seed=28), (0.06, 0.06), dict(edge=0.0, ao=0.7), 0.9),
        "iron": (T.iron(color=IRON), (0.10, 0.10), dict(edge=0.18, edge_color=(0.36, 0.34, 0.31), ao=0.6), 1.2),
        "lamellar": (T.lamellar(lace=CRIMSON, lame=(0.06, 0.06, 0.07), tile_w=LAME_W, period=0.012, braid=0.009,
                                edge=(0.30, 0.28, 0.26)), (LAME_W, 1.0), dict(edge=0.2, edge_color=(0.30, 0.20, 0.16)), 1.2),
        "mail": (T.mail(cells=12), (0.05, 0.05), dict(edge=0.1, ao=0.85), 1.0),
        "leather": (T.leather(color=(0.05, 0.042, 0.04)), (0.08, 0.08), dict(edge=0.2, edge_color=(0.20, 0.16, 0.13)), 1.0),
        "lacquer": (T.lacquer(), (0.25, 0.25), dict(edge=0.14, edge_color=(0.22, 0.18, 0.15)), 0.8),
        "cord": (T.cord(c1=(0.10, 0.08, 0.07), c2=(0.05, 0.04, 0.035)), (0.02, 0.02), dict(edge=0.0), 0.6),
        "red_cord": (T.cord(), (0.02, 0.02), dict(edge=0.0), 0.6),
        "straw": (T.straw(), (0.06, 0.06), dict(edge=0.1, edge_color=(0.60, 0.50, 0.35)), 0.9),
        "face": (face_texture(), (1.0, 1.0), dict(edge=0.0, ao=0.8, ao_dist=0.02, top=0.1, grime=0.0), 1.0),
    }


PARTS = []


def add(name, mesh, mat, **kw):
    PARTS.append(Part(name, mesh, mat, **kw))


# ================================================================ shape helpers
def se_ring(th, a, bf, bb, n, y):
    """Points and outward (horizontal) normals on superellipse rings: th are parameter angles
    (0 = front, + toward the right), a / bf / bb (half-width, depth to the front / back) and y
    broadcast against th. Same parameterisation as G.superellipse."""
    th = np.asarray(th, dtype=float)
    a, bf, bb, y = (np.broadcast_to(np.asarray(q, dtype=float), th.shape) for q in (a, bf, bb, y))
    s, c = np.sin(th), np.cos(th)
    e = 2.0 / n
    x = a * np.sign(s) * np.abs(s) ** e
    b = np.where(c > 0, bf, bb)
    z = -b * np.sign(c) * np.abs(c) ** e
    nx = np.sign(x) * np.abs(x / a) ** (n - 1) / a
    nz = np.sign(z) * np.abs(z / b) ** (n - 1) / b
    ln = np.sqrt(nx * nx + nz * nz) + 1e-12
    return np.stack([x, y, z], axis=-1), np.stack([nx / ln, np.zeros_like(x), nz / ln], axis=-1)


def interp_dims(table, y):
    t = np.asarray(sorted(table), dtype=float)
    return [np.interp(y, t[:, 0], t[:, k]) for k in (1, 2, 3)]


def smooth_path(ctrl, n=24):
    """Catmull-Rom through the control points."""
    P = np.asarray(ctrl, dtype=float)
    P = np.vstack([2 * P[0] - P[1], P, 2 * P[-1] - P[-2]])
    out = []
    segs = len(P) - 3
    for i in range(segs):
        p0, p1, p2, p3 = P[i], P[i + 1], P[i + 2], P[i + 3]
        for t in np.linspace(0, 1, max(2, n // segs), endpoint=(i == segs - 1)):
            t2, t3 = t * t, t * t * t
            out.append(0.5 * (2 * p1 + (-p0 + p2) * t + (2 * p0 - 5 * p1 + 4 * p2 - p3) * t2 + (-p0 + 3 * p1 - 3 * p2 + p3) * t3))
    return np.array(out)


def align_y(m, d):
    """Turns a mesh built around +Y so that +Y points along d."""
    d = G.unit(d)
    ax = np.cross([0.0, 1.0, 0.0], d)
    if np.linalg.norm(ax) < 1e-6:
        return m if d[1] > 0 else m.rotate("x", 180)
    ang = math.degrees(math.acos(max(-1.0, min(1.0, d[1]))))
    return m.rotate(ax, ang)


# ================================================================ head
HEAD = [  # (y, half-width, depth to the front, depth to the back) of the hood, crown to neck
    (1.784, 0.004, 0.004, 0.005), (1.781, 0.036, 0.037, 0.042), (1.774, 0.056, 0.060, 0.068),
    (1.762, 0.071, 0.078, 0.087), (1.745, 0.080, 0.091, 0.100), (1.725, 0.084, 0.097, 0.105),
    (1.705, 0.085, 0.100, 0.107), (1.685, 0.086, 0.101, 0.108), (1.665, 0.085, 0.101, 0.107),
    (1.645, 0.083, 0.101, 0.104), (1.625, 0.081, 0.100, 0.100), (1.605, 0.079, 0.098, 0.096),
    (1.585, 0.076, 0.095, 0.091), (1.565, 0.072, 0.090, 0.086), (1.548, 0.067, 0.082, 0.081),
    (1.532, 0.061, 0.069, 0.075), (1.515, 0.056, 0.057, 0.069), (1.495, 0.054, 0.052, 0.064),
    (1.475, 0.060, 0.056, 0.066), (1.455, 0.082, 0.070, 0.076)]
HEAD_N = 2.3
HOOD_SEGS = 60                                    # 6 degrees: the slit's ends fall on columns
SLIT_Y0, SLIT_Y1, SLIT_PHI = 1.622, 1.666, 54.0   # the eye slit
EYE_Y, EYE_X = 1.642, 0.031
FACE_PHI, FACE_Y0, FACE_Y1 = 64.0, 1.612, 1.676   # the painted patch behind the slit
FACE_YC, FACE_HH = 0.5 * (FACE_Y0 + FACE_Y1), 0.5 * (FACE_Y1 - FACE_Y0)


def g(x, x0, w):
    return np.exp(-((np.asarray(x, dtype=float) - x0) / w) ** 2)


def hood_disp(th, y):
    """Outward displacement of the hood (the mask over it follows it): the nose, the ears, the
    headband's pull, wrinkles at the nape and the seam over the crown."""
    th = np.angle(np.exp(1j * np.asarray(th, dtype=float)))       # -pi..pi
    y = np.asarray(y, dtype=float)
    h = np.interp(y, [1.568, 1.585, 1.596, 1.606, 1.624, 1.642], [0.0, 0.005, 0.010, 0.012, 0.0075, 0.0])
    sig = np.interp(y, [1.580, 1.606, 1.628], [0.45, 0.26, 0.14])
    d = h * np.exp(-(th / sig) ** 2)
    ath = np.abs(th)
    d = d + 0.004 * g(ath, math.pi / 2, 0.22) * g(y, 1.628, 0.022)          # ears
    # the headband cinches the cloth: a groove under it, a puff above it
    d = d - 0.0022 * g(y, 1.689, 0.010) + 0.0016 * g(y, 1.716, 0.006)
    # wrinkles at the nape, gathered toward the knot, and the seam over the crown
    d = d + 0.0015 * np.sin(9.0 * (th - math.pi)) * g(ath, math.pi, 0.55) * g(y, 1.63, 0.035)
    d = d + 0.0012 * (g(th, 0.0, 0.03) + g(ath, math.pi, 0.03)) * smoothstep(1.70, 1.74, y)
    return d


def hood_at(th_deg, y, off=0.0):
    th = np.radians(np.asarray(th_deg, dtype=float))
    y = np.broadcast_to(np.asarray(y, dtype=float), th.shape)
    a, bf, bb = interp_dims(HEAD, y)
    P, N = se_ring(th, a, bf, bb, HEAD_N, y)
    return P + N * (hood_disp(th, y) + off)[..., None], N


def head_weights(v):
    """The hood follows the head, the neck and then the chest; the chin stays with the head."""
    y, z = v[:, 1], v[:, 2]
    yt = 1.542 - 0.035 * smoothstep(0.0, -0.07, z)
    th = smoothstep(yt - 0.02, yt + 0.02, y)
    tc = smoothstep(1.49, 1.455, y)
    return {"head": th, "neck": (1 - th) * (1 - tc), "chest": (1 - th) * tc}


def build_hood():
    ys = [y for y in np.linspace(1.455, 1.7835, 31) if min(abs(y - SLIT_Y0), abs(y - SLIT_Y1)) > 0.004]
    ys = sorted(ys + [SLIT_Y0, SLIT_Y1], reverse=True)
    step = 360.0 / HOOD_SEGS
    th = np.arange(HOOD_SEGS) * step
    rings = [hood_at(th, y)[0] for y in ys]
    m = G.loft(rings)
    cols = HOOD_SEGS + 1
    keep = []
    for f in m.f:
        c = min(f) % cols
        ang = ((c + 0.5) * step + 180.0) % 360.0 - 180.0
        yc = m.v[list(f), 1].mean()
        if SLIT_Y0 < yc < SLIT_Y1 and abs(ang) < SLIT_PHI:
            continue
        keep.append(f)
    m.f = keep
    G.fan_cap(m, list(range(HOOD_SEGS)), np.array([0.0, 1.7855, 0.0]), (0, 1, 0))
    m.weights(head_weights)
    add("hood", m, "hood", smooth=70.0)
    # rolled hems round the slit
    r = 4.0
    loop = [(a, SLIT_Y1) for a in np.arange(-SLIT_PHI + r, SLIT_PHI - r + 0.1, 3.0)]
    loop += [(SLIT_PHI - r + r * math.sin(q), SLIT_Y1 - 0.004 + 0.004 * math.cos(q)) for q in np.linspace(0.4, 1.57, 3)]
    loop += [(SLIT_PHI, y) for y in np.linspace(SLIT_Y1 - 0.006, SLIT_Y0 + 0.006, 4)]
    loop += [(SLIT_PHI - r + r * math.cos(q), SLIT_Y0 + 0.004 - 0.004 * math.sin(q)) for q in np.linspace(0.4, 1.57, 3)]
    loop += [(a, SLIT_Y0) for a in np.arange(SLIT_PHI - r, -SLIT_PHI + r - 0.1, -3.0)]
    loop += [(-SLIT_PHI + r - r * math.sin(q), SLIT_Y0 + 0.004 - 0.004 * math.cos(q)) for q in np.linspace(0.4, 1.57, 3)]
    loop += [(-SLIT_PHI, y) for y in np.linspace(SLIT_Y0 + 0.006, SLIT_Y1 - 0.006, 4)]
    loop += [(-SLIT_PHI + r - r * math.cos(q), SLIT_Y1 - 0.004 + 0.004 * math.sin(q)) for q in np.linspace(0.4, 1.57, 3)]
    loop.append(loop[0])
    pts = np.array([hood_at(a, y, 0.0005)[0] for a, y in loop])
    hem = G.sweep(pts, 0.0030, 8)
    hem.weights(head_weights)
    add("slit_hem", hem, "hood", smooth=80.0)


def mask_top(ath_deg):
    """Height of the mask's upper edge: the slit's lower edge, then down past the ears."""
    return np.interp(ath_deg, [0.0, SLIT_PHI, 75.0, 95.0, 120.0], [SLIT_Y0, SLIT_Y0, 1.612, 1.595, 1.572])


def build_mask():
    """The lower-face mask, a separate cloth over the hood from the slit round to behind the
    ears, draping from the nose in soft folds."""
    ths = np.arange(-120.0, 120.1, 3.0)
    ts = np.linspace(0.0, 1.0, 18)
    top = mask_top(np.abs(ths))
    Y = 1.488 + ts[:, None] * (top[None, :] - 1.488)
    TH = np.broadcast_to(ths[None, :], Y.shape)
    ath = np.radians(np.abs(TH))
    folds = np.zeros(Y.shape)
    for y0, depth in ((1.600, 0.0018), (1.578, 0.0024), (1.556, 0.0020), (1.534, 0.0016)):
        yl = y0 - 0.030 * np.clip((ath - 0.25) / 1.3, 0, 1) ** 1.1
        folds += depth * g(Y, yl, 0.0042) * smoothstep(0.18, 0.40, ath) * smoothstep(2.05, 1.7, ath)
    P, _ = hood_at(TH, Y, 0.0028 + folds)
    u = G.arclen(P[len(ts) // 2])
    uv = np.stack(np.broadcast_arrays(u[None, :], Y), axis=2)
    m = G.surface(P, uv)
    G.orient_radial(m, 0.0, 0.0, True)
    m.weights(head_weights)
    add("mask", m, "mask", solidify=0.002, smooth=70.0)


def face_disp(x, y):
    d = np.full(np.shape(x), -0.0078)
    for side in (-1, 1):
        r = np.hypot(x - side * EYE_X, y - EYE_Y)
        d = d + 0.0032 * g(r, 0.0, 0.0105) - 0.0018 * g(r, 0.0165, 0.005)
    d = d + 0.0028 * g(y, 1.6555, 0.0045) * g(np.abs(x), 0.03, 0.03)          # brow ridge
    d = d + 0.0095 * g(x, 0.0, 0.0075) * smoothstep(1.652, 1.626, y)          # bridge of the nose
    return d


def face_coords(s, t):
    """Face patch (s, t in -1..1) -> undisplaced point, normal, x and y."""
    th = np.radians(np.asarray(s, dtype=float) * FACE_PHI)
    y = FACE_YC + np.asarray(t, dtype=float) * FACE_HH
    a, bf, bb = interp_dims(HEAD, y)
    P, N = se_ring(th, a, bf, bb, HEAD_N, y)
    return P, N, P[..., 0], y


def build_face():
    nu, nv = 56, 22
    S, Tt = np.meshgrid(np.linspace(-1, 1, nu + 1), np.linspace(-1, 1, nv + 1))
    P, N, x, y = face_coords(S, Tt)
    P = P + N * face_disp(x, y)[..., None]
    m = G.surface(P, np.stack([(S + 1) / 2, (Tt + 1) / 2], axis=-1))
    G.orient_dir(m, (0, 0, -1))
    m.bone("head")
    add("face", m, "face", uv="unit", smooth=80.0)


def face_texture(n=512):
    """The skin and eyes seen through the slit, painted in the patch's (s, t) space: tanned skin,
    heavy brows, dark lashes, brown irises with a catch light."""
    S, Tt = np.meshgrid(np.linspace(-1, 1, n), np.linspace(1, -1, n))
    _, _, x, y = face_coords(S, Tt)
    nz = T.noise(n, n, 20, seed=73)
    fine = T.noise(n, n, 2, seed=74, octaves=1)
    skin = np.array([0.55, 0.39, 0.30])
    c = skin[None, None, :] * (0.88 + 0.2 * nz + 0.06 * fine)[..., None]
    rough = np.full((n, n), 0.55)
    ax = np.abs(x)
    for side in (-1, 1):
        dx = (x - side * EYE_X) * side                       # + toward the outer corner
        dy = y - EYE_Y - 0.07 * dx                           # the outer corners tilt up
        hw = 0.0135
        k = np.clip(1.0 - (dx / hw) ** 2, 0.0, 1.0)
        top = 0.0056 * k ** 0.7
        bot = -0.0034 * k ** 0.8
        # shadowed sockets, lighter lids
        c *= (1.0 - 0.18 * g(dy, -0.0055, 0.004) * g(dx, 0.0, 0.016))[..., None]
        c *= (1.0 - 0.12 * g(dy, 0.0075, 0.004) * g(dx, 0.002, 0.016))[..., None]
        eye = (dy < top) & (dy > bot) & (np.abs(dx) < hw)
        sclera = np.array([0.78, 0.74, 0.70]) * (0.72 + 0.28 * np.clip((top - dy) / 0.004, 0, 1))[..., None]
        c = np.where(eye[..., None], sclera, c)
        ir = np.hypot(dx + 0.0008, y - EYE_Y - 0.0004)
        iris = eye & (ir < 0.0054)
        ic = np.array([0.20, 0.11, 0.06]) * (0.55 + 0.45 * (ir / 0.0054))[..., None]
        ic = np.where((ir < 0.0022)[..., None], np.array([0.015, 0.01, 0.01]), ic)
        c = np.where(iris[..., None], ic, c)
        glint = eye & (np.hypot(dx + 0.0008 + 0.0017, y - EYE_Y - 0.0004 - 0.0017) < 0.0011)
        c[glint] = [0.95, 0.93, 0.9]
        rough = np.where(eye, 0.2, rough)
        lash = (dy > top - 0.0005) & (dy < top + 0.0011 + 0.0006 * np.clip(dx / hw, 0, 1)) & (dx > -hw * 1.02) & (dx < hw * 1.12)
        c[lash] = [0.03, 0.02, 0.02]
        lower = (dy > bot - 0.0006) & (dy < bot + 0.0002) & (np.abs(dx) < hw * 0.95)
        c[lower] *= 0.55
        crease = np.abs(dy - top - 0.0036) < 0.00045
        c[crease & (np.abs(dx) < hw * 0.9)] *= 0.75
        # brows: heavy, low at the inner end
        bx = np.clip((dx + 0.012) / 0.028, 0.0, 1.0)
        by = 1.6515 + 0.0045 * bx - 0.0012 * bx * bx
        thick = 0.0024 - 0.0010 * bx
        brow = (np.abs(y - by) < thick) & (dx > -0.013) & (dx < 0.017)
        strokes = 0.7 + 0.3 * T.noise(n, n, 1.2, seed=75 + side, octaves=1)
        c = np.where(brow[..., None], (np.array([0.05, 0.035, 0.03]) * strokes[..., None]), c)
    # the bridge of the nose catches a little light
    c *= (1.0 + 0.08 * g(ax, 0.0, 0.006) * smoothstep(1.652, 1.63, y))[..., None]
    return {"color": np.clip(c, 0, 1), "rough": rough, "metal": np.zeros((n, n))}


def build_headband():
    ths = np.linspace(-180.0, 180.0, 73)
    rows = [(1.674, 0.0035), (1.689, 0.0050), (1.704, 0.0035)]
    grid = np.array([hood_at(ths, y, off)[0] for y, off in rows])
    u = G.arclen(grid[1])
    uv = np.stack(np.broadcast_arrays(u[None, :], np.array([0.0, 0.015, 0.03])[:, None]), axis=2)
    m = G.surface(grid, uv)
    G.orient_radial(m, 0.0, 0.0, True)
    m.bone("head")
    add("headband", m, "band", solidify=0.002, smooth=70.0)
    # the iron plate (hachigane) on the forehead, with four rivets and a raised ring
    ths = np.linspace(-36.0, 36.0, 19)
    rows = np.linspace(1.667, 1.711, 5)
    grid = np.array([hood_at(ths, y, 0.0062 + 0.0012 * math.sin(math.pi * k / 4))[0] for k, y in enumerate(rows)])
    u = G.arclen(grid[2])
    uv = np.stack(np.broadcast_arrays(u[None, :], (rows - rows[0])[:, None]), axis=2)
    m = G.surface(grid, uv)
    G.orient_dir(m, (0, 0, -1))
    m.bone("head")
    add("hachigane", m, "iron", solidify=0.0025, bevel=0.0008)
    for a in (-31.0, 31.0):
        for y in (1.673, 1.705):
            p, n = hood_at(a, y, 0.0085)
            rv = G.revolve([(0.0028, 0.0), (0.0022, 0.0014), (0.0, 0.0022)], segs=8)
            align_y(rv, n).translate(p)
            rv.bone("head")
            add("rivet_%d_%d" % (a, y * 1000), rv, "iron")
    p, _ = hood_at(0.0, 1.689, 0.0082)
    ring = G.sweep([p + np.array([0.0085 * math.cos(q), 0.0085 * math.sin(q), 0.0]) for q in np.linspace(0, 2 * math.pi, 19)], 0.0012, 6)
    ring.bone("head")
    add("hachigane_ring", ring, "iron")
    # the knot at the back (the tails are the game's spring chains)
    p, _ = hood_at(180.0, 1.689, 0.011)
    knot = G.box((0.034, 0.024, 0.018), p).bone("head")
    add("headband_knot", knot, "band", subsurf=2)


def build_head():
    build_hood()
    build_mask()
    build_face()
    build_headband()


# ================================================================ torso
TORSO = [(0.93, 0.158, 0.114, 0.122), (1.00, 0.150, 0.106, 0.112), (1.07, 0.142, 0.100, 0.102),
         (1.15, 0.146, 0.104, 0.100), (1.25, 0.160, 0.114, 0.104), (1.33, 0.168, 0.120, 0.107),
         (1.40, 0.172, 0.116, 0.107), (1.45, 0.160, 0.098, 0.098), (1.485, 0.105, 0.072, 0.074),
         (1.505, 0.078, 0.064, 0.068)]
TORSO_N = 2.7


def torso_at(th_deg, y, off=0.0, scale=1.0):
    th = np.radians(np.asarray(th_deg, dtype=float))
    y = np.broadcast_to(np.asarray(y, dtype=float), th.shape)
    a, bf, bb = interp_dims(TORSO, y)
    P, N = se_ring(th, a * scale, bf * scale, bb * scale, TORSO_N, y)
    return P + N * off, N


def torso_weights(v):
    return w_chain(v, ["hips", "spine", "chest"], [(1.06, 0.05), (1.26, 0.07)])


def surface_ribbon(P, N, width):
    """A strip of `width` along the path P lying in the surface whose normals are N."""
    tang = np.gradient(P, axis=0)
    wdir = np.cross(N, tang)
    m = G.ribbon(P, wdir, width)
    G.orient_radial(m, 0.0, 0.0, True)
    return m


def build_torso():
    th = np.arange(48) * 7.5
    m = G.loft([torso_at(th, y)[0] for y in np.linspace(1.505, 0.93, 24)])
    m.weights(torso_weights)
    add("jacket", m, "sashiko")
    # crossed collar: the left panel over the right, pale collar bands meeting at the back
    for side, off, y_end, width, solid in ((-1, 0.0055, 1.105, 0.034, 0.003), (1, 0.0022, 1.30, 0.032, 0.002)):
        pts = [(side * a, 1.494 - 0.008 * (180.0 - a) / 140.0) for a in np.linspace(180.0, 40.0, 10)]
        for k in np.linspace(0.0, 1.0, 17)[1:]:
            y = 1.486 - k * (1.486 - 1.105)
            if y < y_end:
                break
            pts.append((side * (40.0 - 95.0 * k), y))
        P, N = torso_at(np.array([p[0] for p in pts]), np.array([p[1] for p in pts]), off)
        rib = surface_ribbon(P, N, width)
        rib.weights(torso_weights)
        add("collar_%d" % side, rib, "collar", solidify=solid, smooth=60.0)
    # mail in the V between the collars
    rows = np.linspace(1.322, 1.492, 8)
    grid, uvg = [], []
    for y in rows:
        k = max(0.0, (y - 1.335) / 0.15)
        ths = np.linspace(-40.0 * k - 9.0, 40.0 * k + 9.0, 9)
        P, _ = torso_at(ths, y, 0.0012)
        grid.append(P)
        uvg.append(np.stack([G.arclen(P) - G.arclen(P)[-1] / 2, np.full(len(P), y)], axis=1))
    m = G.surface(np.array(grid), np.array(uvg))
    G.orient_radial(m, 0.0, 0.0, True)
    m.weights(torso_weights)
    add("kusari", m, "mail")
    build_obi()
    build_hem()
    build_scarf()


def build_obi():
    ys = [0.992, 1.000, 1.030, 1.070, 1.100, 1.108]
    sc = [1.052, 1.072, 1.078, 1.078, 1.072, 1.052]
    th = np.arange(48) * 7.5
    m = G.loft([torso_at(th, y, 0.0, s)[0] for y, s in zip(ys, sc)])
    m.uv[:, 1] = (m.v[:, 1] - ys[0]) / (ys[-1] - ys[0])
    m.weights(lambda v: w_chain(v, ["hips", "spine"], [(1.06, 0.03)]))
    add("obi", m, "obi", uv="lame")
    # the knot at the back and its two short ends
    knot = G.box((0.11, 0.05, 0.032), (0.0, 1.052, 0.130)).bone("hips")
    add("obi_knot", knot, "obi", subsurf=2)
    for sx in (-1.0, 1.0):
        pts = smooth_path([[0.022 * sx, 1.04, 0.140], [0.036 * sx, 0.99, 0.150], [0.050 * sx, 0.93, 0.154]], 8)
        end = G.ribbon(pts, (1.0, 0.0, 0.25 * sx), 0.036)
        G.orient_dir(end, (0, 0, 1))
        end.bone("hips")
        add("obi_end_%d" % sx, end, "obi", uv="tile", solidify=0.004)


def build_hem():
    """The jacket's skirt below the obi: six panels on helper bones, split at the front, the
    back and between the panels."""
    rows = np.linspace(HEM_TOP, HEM_BOT, 8)
    for name, _, c, _ in HEM_PANELS:
        ths = np.linspace(c - HEM_WIDTH / 2, c + HEM_WIDTH / 2, 10)
        grid = np.array([[hem_point(a, y) for a in ths] for y in rows])
        u = G.arclen(grid[-1])
        uv = np.stack(np.broadcast_arrays(u[None, :], (HEM_TOP - rows)[:, None]), axis=2)
        m = G.surface(grid, uv)
        G.orient_radial(m, 0.0, 0.0, True)
        m.bone(name)
        add("hem_" + name, m, "sashiko", solidify=0.005, bevel=0.0015)


def build_scarf():
    """The scarf wound twice round the neck (its two tails are the game's spring chains)."""
    for k, (y0, rx, rzf, rzb, r, tilt) in enumerate(((1.472, 0.086, 0.074, 0.082, 0.020, 0.010),
                                                    (1.503, 0.080, 0.068, 0.078, 0.019, -0.008))):
        pts = []
        for a in np.linspace(math.pi, 3 * math.pi, 37):      # the seam at the back, under the knot
            z = -math.cos(a) * (rzf if math.cos(a) > 0 else rzb)
            pts.append([math.sin(a) * rx, y0 + tilt * math.cos(a) + 0.003 * math.sin(3 * a + k), z])
        m = G.sweep(pts, r, 10, sx=1.3, sy=1.0)
        m.weights(lambda v: w_chain(v, ["neck", "chest"], [(1.485, 0.02)]))
        add("scarf_%d" % k, m, "scarf", smooth=70.0)
    knot = G.box((0.05, 0.04, 0.03), (0.035, 1.488, 0.090))
    knot.weights(lambda v: w_chain(v, ["neck", "chest"], [(1.485, 0.02)]))
    add("scarf_knot", knot, "scarf", subsurf=2)


# ================================================================ arms
def build_arms():
    for s, sx in SIDES:
        cx = J["upper_arm_" + s][0]
        out = -90.0 if sx < 0 else 90.0
        # sleeve to below the elbow
        prof = [(0.062, 1.095), (0.064, 1.13), (0.066, 1.20), (0.067, 1.30), (0.066, 1.38), (0.062, 1.43),
                (0.051, 1.465), (0.028, 1.485), (0.0, 1.49)]
        m = G.revolve(prof, segs=18, center=(cx, 0, 0))
        m.weights(lambda v, s=s: w_chain(v, ["chest", "upper_arm_" + s, "forearm_" + s], [(1.41, 0.025), (1.14, 0.03)]))
        add("sleeve_" + s, m, "sashiko")
        # shoulder guard: an iron dome over the outside of the shoulder (a shell round the joint)
        # and two laced lames below it, turning halfway with the arm
        cap = G.revolve([(0.086, 1.408), (0.084, 1.438), (0.074, 1.468), (0.058, 1.488), (0.040, 1.497)],
                        out - 62, out + 62, 14, center=(cx, 0, 0))
        cap.bone("x_sode_" + s)
        add("sode_cap_" + s, cap, "armour", solidify=0.004, bevel=0.0015)
        for k in range(2):
            y_top = 1.412 - 0.034 * k
            m = band(out - 58, out + 58, y_top - 0.042, y_top, 0.092 + 0.006 * k, 0.086 + 0.006 * k, segs=12,
                     center=(cx, 0, 0), mid=0.002)
            m.bone("x_sode_" + s)
            add("sode_%s%d" % (s, k), m, "lamellar", uv="lame", solidify=0.004, bevel=0.0012)
        # forearm: pale wraps under three iron splints held by two straps
        m = G.revolve([(0.040, 0.905), (0.042, 0.93), (0.047, 1.00), (0.051, 1.07), (0.053, 1.12), (0.052, 1.16)],
                      segs=16, center=(cx, 0, 0))
        m.weights(lambda v, s=s: w_chain(v, ["forearm_" + s, "hand_" + s], [(0.915, 0.012)]))
        add("forearm_" + s, m, "wrap")
        for k in (-1, 0, 1):
            a = out + 26.0 * k
            sp = band(a - 9, a + 9, 0.94, 1.105, 0.0545, 0.0585, segs=3, center=(cx, 0, 0), mid=0.002)
            sp.uv[:, 1] = sp.v[:, 1]
            sp.bone("forearm_" + s)
            add("splint_%s%d" % (s, k + 1), sp, "iron", solidify=0.004, bevel=0.0015)
        for y in (0.965, 1.075):
            r = 0.0490 + (y - 0.965) * 0.04
            st = G.revolve([(r, y - 0.007), (r + 0.0035, y), (r, y + 0.007)], segs=16, center=(cx, 0, 0))
            st.bone("forearm_" + s)
            add("strap_%s%d" % (s, int(y * 1000)), st, "leather")
        # gloved fist, thumb, and an iron plate over the back of the hand
        fist = G.box((0.068, 0.085, 0.082), (cx, 0.855, -0.004)).bone("hand_" + s)
        add("fist_" + s, fist, "leather", subsurf=2)
        thumb = G.box((0.028, 0.046, 0.030), (cx - sx * 0.016, 0.868, -0.046)).bone("hand_" + s)
        add("thumb_" + s, thumb, "leather", subsurf=2)
        tk = band(out - 50, out + 50, 0.842, 0.905, 0.047, 0.045, segs=8, center=(cx, 0, 0), mid=0.004)
        tk.uv[:, 1] = tk.v[:, 1]
        tk.bone("hand_" + s)
        add("tekko_" + s, tk, "iron", solidify=0.0035, bevel=0.0012)


# ================================================================ legs
def build_legs():
    th = np.linspace(0, 2 * math.pi, 28, endpoint=False)
    for s, sx in SIDES:
        cx = J["thigh_" + s][0]
        # slim trousers, gathered into the shin wraps
        prof = [(1.00, 0.094), (0.93, 0.101), (0.82, 0.106), (0.70, 0.104), (0.60, 0.094), (0.52, 0.080),
                (0.46, 0.068), (0.41, 0.061)]
        rings = []
        for y, r in prof:
            fold = 1.0 + 0.045 * np.sin(5 * th + 1.3 * sx) * smoothstep(0.98, 0.86, y) * smoothstep(0.44, 0.56, y)
            inner = 1.0 - 0.14 * np.clip(-np.sin(th) * sx, 0, 1) ** 1.5
            rings.append(np.stack([cx + np.sin(th) * r * fold * inner, np.full_like(th, y), -np.cos(th) * r * fold], axis=1))
        m = G.loft(rings)
        m.weights(lambda v, s=s: w_chain(v, ["hips", "thigh_" + s, "shin_" + s], [(0.94, 0.05), (0.50, 0.05)]))
        add("trousers_" + s, m, "trousers", smooth=60.0)
        # shin wraps, cross-tied
        cz = 0.004
        wp = [(0.050, 0.096), (0.052, 0.12), (0.055, 0.19), (0.061, 0.28), (0.065, 0.35), (0.066, 0.42), (0.065, 0.458), (0.061, 0.47)]
        m = G.revolve(wp, segs=20, center=(cx, 0, cz))
        m.bone("shin_" + s)
        add("kyahan_" + s, m, "wrap")
        wy = np.array([p[1] for p in wp])
        wr = np.array([p[0] for p in wp])
        for hand in (-1, 1):
            pts = []
            for u in np.linspace(0, 1, 90):
                y = 0.13 + u * 0.30
                a = hand * u * 2.5 * 2 * math.pi + (0.0 if hand > 0 else math.pi)
                r = float(np.interp(y, wy, wr)) + 0.0025
                pts.append([cx + math.sin(a) * r, y, cz - math.cos(a) * r])
            cord = G.sweep(pts, 0.0026, 6)
            cord.bone("shin_" + s)
            add("kyahan_tie_%s%d" % (s, hand), cord, "cord")
        tie = G.revolve([(0.0655, 0.444), (0.0685, 0.450), (0.0655, 0.456)], segs=20, center=(cx, 0, cz))
        tie.bone("shin_" + s)
        add("kyahan_top_" + s, tie, "cord")
        knot = G.box((0.012, 0.016, 0.014), (cx + sx * 0.068, 0.448, cz)).bone("shin_" + s)
        add("kyahan_knot_" + s, knot, "cord", subsurf=1)
        build_foot(s, sx, cx)
    # the seat between the legs
    rings = []
    for y, sc in ((1.00, 1.0), (0.95, 0.97), (0.90, 0.88), (0.865, 0.66), (0.845, 0.3)):
        a, bf, bb = interp_dims(TORSO, 1.0)
        rings.append(se_ring(th, a * sc * 0.95, bf * sc * 0.92, bb * sc, TORSO_N, y)[0])
    m = G.loft(rings)
    G.fan_cap(m, list(range(4 * 29, 4 * 29 + 28)), np.array([0.0, 0.84, 0.0]), (0, -1, 0))
    m.bone("hips")
    add("seat", m, "trousers")


def build_foot(s, sx, cx):
    """Split-toed tabi on a straw sandal (waraji) with its cords."""
    sole = 0.012
    secs = [(0.070, 0.034, 0.080), (0.045, 0.043, 0.112), (0.010, 0.048, 0.126), (-0.030, 0.051, 0.104),
            (-0.075, 0.053, 0.078), (-0.115, 0.051, 0.062), (-0.150, 0.045, 0.052), (-0.175, 0.034, 0.043),
            (-0.190, 0.018, 0.034)]
    th = np.linspace(0, 2 * math.pi, 32, endpoint=False)
    x_split = cx - sx * 0.013
    rings = []
    for z, hw, top in secs:
        c, sn = np.cos(th), np.sin(th)
        e = 2.0 / 3.2
        x = cx + hw * np.sign(c) * np.abs(c) ** e - sx * 0.007 * smoothstep(-0.14, -0.19, z)
        y = sole + top * 0.5 + top * 0.5 * np.sign(sn) * np.abs(sn) ** e
        y = y - 0.016 * smoothstep(-0.12, -0.155, z) * g(x, x_split, 0.006) * smoothstep(0.0, 0.5, sn)
        rings.append(np.stack([x, y, np.full_like(x, z)], axis=1))
    m = G.loft(rings)
    n = len(th) + 1
    last = (len(secs) - 1) * n
    G.fan_cap(m, list(range(0, len(th))), np.array(rings[0]).mean(axis=0), (0, 0, 1))
    G.fan_cap(m, list(range(last, last + len(th))), np.array(rings[-1]).mean(axis=0), (0, 0, -1))

    def fw(v):
        w = smoothstep(0.10, 0.13, v[:, 1]) * smoothstep(-0.045, -0.005, v[:, 2])
        return {"shin_" + s: w, "foot_" + s: 1.0 - w}
    m.weights(fw)
    add("tabi_" + s, m, "tabi")
    # the sandal: a straw slab a little larger than the foot
    zs = [0.082] + [z for z, _, _ in secs] + [-0.200]
    xr = [(float(r[:, 0].min()), float(r[:, 0].max())) for r in rings]
    xr = [xr[0]] + xr + [xr[-1]]
    srings = []
    for i, z in enumerate(zs):
        x0, x1 = xr[i][0] - 0.007, xr[i][1] + 0.007
        if i in (0, len(zs) - 1):
            mid = 0.5 * (x0 + x1)
            x0, x1 = mid - 0.4 * (x1 - x0) * 0.5, mid + 0.4 * (x1 - x0) * 0.5
        top = [(x, sole, z) for x in np.linspace(x0 + 0.004, x1 - 0.004, 5)]
        srings.append(top + [(x1, sole * 0.5, z)] + [(x, 0.0, z) for x in np.linspace(x1 - 0.004, x0 + 0.004, 5)] + [(x0, sole * 0.5, z)])
    ws = G.loft(srings)
    k = len(srings[0]) + 1
    G.fan_cap(ws, list(range(0, k - 1)), np.array(srings[0]).mean(axis=0), (0, 0, 1))
    lastw = (len(srings) - 1) * k
    G.fan_cap(ws, list(range(lastw, lastw + k - 1)), np.array(srings[-1]).mean(axis=0), (0, 0, -1))
    ws.bone("foot_" + s)
    add("waraji_" + s, ws, "straw")
    # cords: from between the toes over the instep to either side, and round the heel
    i = -sx
    toe = [x_split, 0.030, -0.150]
    for side in (1, -1):
        ctrl = [toe, [x_split + side * i * 0.012, 0.062, -0.108], [cx + side * i * 0.050, 0.046, -0.050],
                [cx + side * i * 0.058, sole + 0.004, -0.028]]
        c = G.sweep(smooth_path(ctrl, 18), 0.0035, 6)
        c.bone("foot_" + s)
        add("hanao_%s%d" % (s, side), c, "straw")
    heel = smooth_path([[cx - i * 0.057, 0.024, -0.02], [cx - i * 0.052, 0.034, 0.03], [cx - i * 0.030, 0.038, 0.070],
                        [cx, 0.040, 0.083], [cx + i * 0.030, 0.038, 0.070], [cx + i * 0.052, 0.034, 0.03],
                        [cx + i * 0.057, 0.024, -0.02]], 24)
    c = G.sweep(heel, 0.0035, 6)
    c.bone("foot_" + s)
    add("hanao_heel_" + s, c, "straw")


# ================================================================ gear
def build_gear():
    # the scabbard, through the obi at the left hip, tip low behind him
    p0 = np.array([-0.150, 1.040, -0.078])
    d = G.unit([-0.18, -0.42, 0.89])
    L = 0.80
    ts = np.linspace(0.0, L, 26)
    radius = np.linspace(0.0165, 0.0142, len(ts))
    path = p0[None, :] + d[None, :] * ts[:, None] - np.array([0.0, 0.020, 0.0]) * ((ts / L) ** 2)[:, None]
    saya = G.sweep(path, radius, 12, sx=0.78, sy=1.0, caps=True)
    saya.bone("hips")
    add("saya", saya, "lacquer", smooth=50.0)
    _, fn, fb = G.frames_along(path)          # the sweep's frame: fn the narrow axis, fb the wide one

    def at(t):
        i = int(np.clip(np.searchsorted(ts, t), 0, len(ts) - 1))
        return p0 + d * t - np.array([0.0, 0.020, 0.0]) * (t / L) ** 2, fn[i], fb[i], float(np.interp(t, ts, radius))
    for name, t0, t1, dr in (("koiguchi", 0.0, 0.022, 0.0014), ("kojiri", L - 0.035, L, 0.0012)):
        pp = np.array([at(t)[0] for t in np.linspace(t0, t1, 4)])
        r = np.array([at(t)[3] for t in np.linspace(t0, t1, 4)]) + dr
        fit = G.sweep(pp, r, 12, sx=0.8, sy=1.0, caps=True)
        fit.bone("hips")
        add("saya_" + name, fit, "iron")
    c, n1, _, r = at(0.10)
    kg = G.box((0.010, 0.024, 0.012), c + n1 * (r * 0.78 + 0.004)).bone("hips")
    add("kurigata", kg, "lacquer", subsurf=1)
    # the sageo: wound round the scabbard below the mouth, then tied at the obi
    pts = []
    for u in np.linspace(0.0, 1.0, 40):
        a = u * 3.0 * 2 * math.pi
        c, n1, b1, r = at(0.07 + 0.07 * u)
        pts.append(c + n1 * math.cos(a) * (r * 0.78 + 0.0026) + b1 * math.sin(a) * (r + 0.0026))
    pts += list(smooth_path([pts[-1], at(0.16)[0] + np.array([-0.02, 0.03, 0.0]), [-0.168, 1.075, -0.02],
                             [-0.160, 1.10, 0.03]], 12))[1:]
    sageo = G.sweep(np.array(pts), 0.0028, 6)
    sageo.bone("hips")
    add("sageo", sageo, "red_cord")
    # a pouch hanging from the obi at his right, behind the hip, turned to follow the waist
    surf, nrm = torso_at(125.0, 0.99, 0.0, 1.072)
    pc = surf + nrm * 0.034
    turn = -math.degrees(math.atan2(nrm[2], nrm[0]))
    for name, size, off in (("pouch", (0.040, 0.075, 0.066), (0.0, 0.0, 0.0)), ("pouch_flap", (0.044, 0.030, 0.070), (0.003, 0.028, 0.0))):
        bx = G.box(size, pc + np.array(off)).rotate("y", turn, center=pc)
        bx.bone("hips")
        add(name, bx, "leather", subsurf=1)
    toggle = G.revolve([(0.0, -0.008), (0.008, -0.004), (0.008, 0.004), (0.0, 0.008)], segs=10)
    toggle.translate(surf + nrm * 0.012 + np.array([0.0, 0.07, 0.0])).bone("hips")
    add("pouch_toggle", toggle, "lacquer")


# ================================================================ katana (weapon space)
def build_katana():
    """Origin at the tsuba, blade along +Y (edge toward -Z, curving toward +Z), handle along -Y:
    see data/rigs.json "katana"."""
    table = {
        "katana_steel": T.hamon(steel=(0.50, 0.52, 0.56), groove=False),
        "katana_iron": T.iron(color=(0.09, 0.09, 0.10)),
        "katana_gold": T.gold(color=(0.70, 0.50, 0.24)),
        "katana_wrap": T.tsukamaki(silk=(0.045, 0.045, 0.06), under=(0.74, 0.72, 0.66)),
    }
    mats = {}
    for name, tex in table.items():
        col = B.numpy_to_image(name + "_col", tex["color"])
        orm = B.numpy_to_image(name + "_orm", np.stack([np.ones_like(tex["rough"]), tex["rough"], tex["metal"]], axis=2))
        orm.colorspace_settings.name = "Non-Color"
        mats[name] = BM.textured_material(name, col, orm)
    pieces = []
    blade = blade_mesh(y0=0.030, length=0.780, w0=0.031, w1=0.024, thick=0.0074, curve=0.024, kissaki=0.1, steps=26)
    pieces.append((blade, "katana_steel", (1.0, 1.0)))
    habaki = G.revolve([(0.0135, 0.0), (0.0135, 0.030), (0.0122, 0.036)], segs=16, sx=0.45, sz=1.35)
    pieces.append((habaki, "katana_gold", (0.06, 0.06)))
    for y0 in (-0.0016, -0.0092):
        seppa = G.revolve([(0.0, y0), (0.020, y0), (0.020, y0 + 0.0016), (0.0, y0 + 0.0016)], segs=20, sx=0.72)
        pieces.append((seppa, "katana_gold", (0.06, 0.06)))
    tsuba = G.revolve([(0.0, -0.0076), (0.039, -0.0076), (0.041, -0.0066), (0.041, -0.0026), (0.039, -0.0016),
                       (0.0, -0.0016)], segs=36, sx=0.88)
    pieces.append((tsuba, "katana_iron", (0.08, 0.08)))
    fuchi = G.revolve([(0.0168, -0.022), (0.0176, -0.019), (0.0176, -0.0115), (0.0168, -0.0092)], segs=20, sx=0.8)
    pieces.append((fuchi, "katana_iron", (0.06, 0.06)))
    tsuka = G.revolve([(0.0165, -0.262), (0.0158, -0.20), (0.0153, -0.14), (0.0158, -0.08), (0.0166, -0.022)],
                      segs=20, sx=0.8)
    circ = 2 * math.pi * float(np.mean([0.0165, 0.0158, 0.0153, 0.0158, 0.0166])) * 0.9
    pieces.append((tsuka, "katana_wrap", (circ, 0.034)))
    for sx in (-1.0, 1.0):
        menuki = G.revolve([(0.0, -0.012), (0.0035, -0.008), (0.004, 0.0), (0.0035, 0.008), (0.0, 0.012)], segs=10)
        menuki.scale((0.55, 1.0, 1.0)).translate((sx * 0.0128, -0.128, 0.0))
        pieces.append((menuki, "katana_gold", (0.04, 0.04)))
    kashira = G.revolve([(0.0, -0.277), (0.011, -0.2765), (0.0162, -0.272), (0.0172, -0.266), (0.0170, -0.262)],
                        segs=20, sx=0.8)
    pieces.append((kashira, "katana_iron", (0.06, 0.06)))
    objs = []
    for i, (m, mat, tile) in enumerate(pieces):
        objs.append(B.mesh_object("katana_%d" % i, m.v, m.f, m.uv / np.array(tile), "uv", None, 35.0, mats[mat]))
    katana = B.join(objs, "Katana")
    print("katana:", B.mesh_stats(katana))
    return katana


# ================================================================ Blender assembly
BAKE_SPREAD = [("upper_arm_", 35.0), ("thigh_", 8.0), ("x_sode_", 18.0)]


def build_body(args):
    t0 = time.time()
    table = material_table()
    mats = {key: BM.pattern_material(key, tex, **params) for key, (tex, tile, params, _) in table.items()}
    arm, _ = B.make_armature(RIG, "Skeleton")
    add_helper_bones(arm, HELPERS)
    build_head()
    build_torso()
    build_arms()
    build_legs()
    build_gear()
    body = B.join([part_object(p, mats, table) for p in PARTS if p.mat != "face"], "PlayerBody")
    # the eyes keep their own painted UVs and texture
    face = B.join([part_object(p, mats, table) for p in PARTS if p.mat == "face"], "PlayerFace")
    flay = face.data.uv_layers.new(name="atlas")
    buf = np.zeros(len(face.data.loops) * 2, dtype=np.float32)
    face.data.uv_layers["pattern"].data.foreach_get("uv", buf)
    flay.data.foreach_set("uv", buf)
    face.data.shade_smooth()
    print("body built:", B.mesh_stats(body), B.mesh_stats(face), "%.1fs" % (time.time() - t0))
    for o in (body, face):
        B.skin_to(o, arm)
        B.normalize_weights(o)
    if args.shapes:
        return arm, body, face
    idx = {slot.material.name: i for i, slot in enumerate(body.material_slots)}
    scale = {idx[k]: v[3] for k, v in table.items() if k in idx}
    B.smart_uv(body, "atlas", angle=55.0, margin=0.003, island_scale=scale)
    print("uv done %.1fs" % (time.time() - t0))
    color = B.new_image("player_body", args.atlas)
    orm = B.new_image("player_body_orm", args.atlas // 2)
    orm.colorspace_settings.name = "Non-Color"
    face_color = B.new_image("player_face", 512)
    face_orm = B.new_image("player_face_orm", 256)
    face_orm.colorspace_settings.name = "Non-Color"
    if not args.no_bake:
        bake_pose(arm, BAKE_SPREAD, True)
        BM.set_mode(list(mats.values()), 0)
        B.bake_emit(body, color, "atlas", margin=8, samples=args.samples)
        B.bake_emit(face, face_color, "atlas", margin=8, samples=args.samples)
        print("colour baked %.1fs" % (time.time() - t0))
        BM.set_mode(list(mats.values()), 1)
        B.bake_emit(body, orm, "atlas", margin=4, samples=1)
        B.bake_emit(face, face_orm, "atlas", margin=4, samples=1)
        print("orm baked %.1fs" % (time.time() - t0))
        bake_pose(arm, BAKE_SPREAD, False)
    os.makedirs(PREVIEW_DIR, exist_ok=True)
    B.save_image(color, os.path.join(PREVIEW_DIR, "player_atlas.png"))
    B.save_image(face_color, os.path.join(PREVIEW_DIR, "player_face.png"))
    for img in (color, orm, face_color, face_orm):
        img.pack()
    for obj, name, c_img, o_img in ((body, "player_body", color, orm), (face, "player_face", face_color, face_orm)):
        final = BM.textured_material(name, c_img, o_img)
        obj.data.materials.clear()
        obj.data.materials.append(final)
        for poly in obj.data.polygons:
            poly.material_index = 0
        obj.data.uv_layers.remove(obj.data.uv_layers["pattern"])
    # textures for the game's spring-chain ribbons: the scarf's tails and the headband's
    from PIL import Image
    Image.fromarray(T.to_uint8(T.scarf(silk=(0.30, 0.036, 0.032)))).save(os.path.join(B.ROOT, SCARF_PNG))
    Image.fromarray(T.to_uint8(T.scarf(silk=(0.09, 0.10, 0.16), seed=100))).save(os.path.join(B.ROOT, BAND_PNG))
    return arm, body, face


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--preview", action="store_true")
    ap.add_argument("--no-bake", action="store_true")
    ap.add_argument("--shapes", action="store_true", help="skip the atlas, the bake and the export; render the shapes")
    ap.add_argument("--atlas", type=int, default=2048)
    ap.add_argument("--samples", type=int, default=48)
    args = ap.parse_args()
    B.reset_scene()
    arm, body, face = build_body(args)
    if not args.shapes:
        out = os.path.join(B.ROOT, BODY_GLB)
        B.export_glb([arm, body, face], out)
        print("wrote", out, B.mesh_stats(body), B.mesh_stats(face))
    katana = build_katana()
    if not args.shapes:
        B.export_glb([katana], os.path.join(B.ROOT, KATANA_GLB))
    if args.preview or args.shapes:
        katana.location = (0.45, -0.1, 0.9)
        bpy.context.scene.view_settings.view_transform = "Standard"
        B.render_views(os.path.join(PREVIEW_DIR, "player_views.png"),
                       [(0, 8), (35, 10), (90, 5), (180, 10), (200, 22)], target=(0, 0.95, 0), dist=4.6)
        B.render_views(os.path.join(PREVIEW_DIR, "player_head.png"),
                       [(0, 4, 0.8, (0, 1.63, 0)), (30, 8, 0.8, (0, 1.63, 0)), (90, 4, 0.8, (0, 1.63, 0)),
                        (150, 12, 1.0, (0, 1.6, 0))],
                       size=(480, 480))


if __name__ == "__main__":
    main()
