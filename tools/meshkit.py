"""Python mirror of scripts/rig/mesh_kit.gd (geometry only) for offline previews.

Every builder returns (verts Nx3, tris Mx3). Same parameters and conventions as the
GDScript version so tools/model_preview.py renders what the game builds.
"""
import math

import numpy as np


def _quads(rows, cols, wrap):
    tris = []
    ucount = cols if wrap else cols - 1
    for i in range(rows - 1):
        for j in range(ucount):
            j1 = (j + 1) % cols
            a, b = i * cols + j, i * cols + j1
            c, d = (i + 1) * cols + j, (i + 1) * cols + j1
            tris.append((d, c, a))
            tris.append((d, a, b))
    return tris


def lathe(profile, segments=20, sx=1.0, sz=1.0, flat=False):
    verts = []
    for r, y in profile:
        for j in range(segments):
            a = 2 * math.pi * j / segments
            verts.append((math.cos(a) * r * sx, y, math.sin(a) * r * sz))
    return np.array(verts, float), np.array(_quads(len(profile), segments, True), int)


def sweep(path, radii, segments=12, normal_hint=(0, 0, -1), squash=1.0):
    path = [np.array(p, float) for p in path]
    n = len(path)
    prev_n = np.array(normal_hint, float)
    prev_n /= np.linalg.norm(prev_n)
    verts = []
    for i in range(n):
        if i == 0:
            t = path[1] - path[0]
        elif i == n - 1:
            t = path[n - 1] - path[n - 2]
        else:
            t = path[i + 1] - path[i - 1]
        t = t / max(np.linalg.norm(t), 1e-9)
        nn = prev_n - t * np.dot(prev_n, t)
        if np.linalg.norm(nn) < 1e-4:
            nn = np.cross(t, [1, 0, 0])
        nn = nn / np.linalg.norm(nn)
        prev_n = nn
        b = np.cross(nn, t)
        for j in range(segments):
            a = 2 * math.pi * j / segments
            verts.append(path[i] + (nn * math.cos(a) + b * math.sin(a) * squash) * radii[i])
    return np.array(verts, float), np.array(_quads(n, segments, True), int)


def limb(length, r0, r1, segments=16, sx=1.0, sz=1.0):
    prof = []
    cap = 5
    for i in range(cap + 1):
        a = -math.pi / 2 + (math.pi / 2) * i / cap
        prof.append((math.cos(a) * r1, -length + math.sin(a) * r1 * 0.9))
    for i in range(cap + 1):
        a = (math.pi / 2) * i / cap
        prof.append((math.cos(a) * r0, math.sin(a) * r0 * 0.9))
    return lathe(prof, segments, sx, sz)


def blade(length, width, thickness, curve, kissaki=0.12, steps=16, edge_sign=1.0, tip_width=-1.0):
    tw = width * 0.82 if tip_width < 0 else tip_width
    sec = [(0.5, 0.0), (-0.15, 0.5), (-0.5, 0.32), (-0.5, -0.32), (-0.15, -0.5)]
    verts = []
    for i in range(steps + 1):
        u = i / steps
        y = u * length
        spine_z = curve * u * u * edge_sign
        w = width + (tw - width) * u
        th = thickness * (1.0 + (0.7 - 1.0) * u)
        tip_start = 1.0 - kissaki
        if u > tip_start:
            k = (u - tip_start) / kissaki
            w *= math.sqrt(max(0.0, 1.0 - k * k))
            th *= (1.0 - k * 0.9)
        n = np.array([0, 0, -edge_sign], float)
        t = np.array([0, 1, 2.0 * curve * u * edge_sign / max(length, 0.001)], float)
        t /= np.linalg.norm(t)
        n = n - t * np.dot(n, t)
        n /= np.linalg.norm(n)
        b = np.cross(n, t)
        center = np.array([0, y, spine_z], float)
        for sv in sec:
            verts.append(center + n * (sv[0] * w) + b * (sv[1] * th))
    return np.array(verts, float), np.array(_quads(steps + 1, len(sec), True), int)


def shell(r, arc_deg, y0, y1, thickness, flare=0.0, segments=10, rows=2):
    half = math.radians(arc_deg) * 0.5
    verts, tris = [], []
    base = 0
    cols = segments + 1
    for layer in range(2):
        off = 0.0 if layer == 0 else -thickness
        for i in range(rows + 1):
            vv = i / rows
            y = y0 + (y1 - y0) * vv
            rr = r + flare * (1.0 - vv) + off
            for j in range(segments + 1):
                a = -half + (2 * half) * j / segments
                verts.append((math.sin(a) * rr, y, -math.cos(a) * rr))
        for i in range(rows):
            for j in range(segments):
                a0 = base + i * cols + j
                b0, c0 = a0 + 1, a0 + cols
                d0 = c0 + 1
                if layer == 0:
                    tris += [(d0, c0, a0), (d0, a0, b0)]
                else:
                    tris += [(a0, c0, d0), (b0, a0, d0)]
        base += (rows + 1) * cols
    inner = (rows + 1) * cols
    pairs = []
    for j in range(segments):
        pairs.append((j, j + 1))
        pairs.append((rows * cols + j, rows * cols + j + 1))
    for i in range(rows):
        pairs.append((i * cols, (i + 1) * cols))
        pairs.append((i * cols + segments, (i + 1) * cols + segments))
    for p0, p1 in pairs:
        tris += [(p0, p1, inner + p1), (p0, inner + p1, inner + p0),
                 (inner + p1, p1, p0), (inner + p0, inner + p1, p0)]
    return np.array(verts, float), np.array(tris, int)


def horn(p1, p2, base_radius, steps=12, segments=10, squash=1.0):
    p1, p2 = np.array(p1, float), np.array(p2, float)
    path, radii = [], []
    for i in range(steps + 1):
        t = i / steps
        path.append(2 * (1 - t) * t * p1 + t * t * p2)
        radii.append(base_radius * (1 - t) ** 0.8 + 0.0015)
    return sweep(path, radii, segments, (0, 0, -1), squash)


def box(size):
    sx, sy, sz = (s / 2 for s in size)
    v = np.array([[x, y, z] for x in (-sx, sx) for y in (-sy, sy) for z in (-sz, sz)], float)
    # index = xi*4 + yi*2 + zi
    faces = [(0, 1, 3, 2), (4, 6, 7, 5), (0, 4, 5, 1), (2, 3, 7, 6), (0, 2, 6, 4), (1, 5, 7, 3)]
    tris = []
    for a, b, c, d in faces:
        tris += [(a, b, c), (a, c, d)]
    return v, np.array(tris, int)


def sphere(radius, height=-1.0, segs=18):
    h = radius * 2 if height < 0 else height
    rings = max(8, segs // 2)
    prof = []
    for i in range(rings + 1):
        a = -math.pi / 2 + math.pi * i / rings
        prof.append((math.cos(a) * radius, math.sin(a) * h / 2))
    return lathe(prof, segs)


def cylinder(r_top, r_bottom, height, segs=16):
    prof = [(0.0, -height / 2), (r_bottom, -height / 2), (r_top, height / 2), (0.0, height / 2)]
    return lathe(prof, segs)


def torus(inner, outer, rings=24, ring_segments=8):
    rc = (inner + outer) / 2
    rt = (outer - inner) / 2
    verts = []
    for i in range(rings):
        a = 2 * math.pi * i / rings
        for j in range(ring_segments):
            b = 2 * math.pi * j / ring_segments
            r = rc + rt * math.cos(b)
            verts.append((math.cos(a) * r, rt * math.sin(b), math.sin(a) * r))
    tris = []
    for i in range(rings):
        for j in range(ring_segments):
            i1, j1 = (i + 1) % rings, (j + 1) % ring_segments
            a0, b0 = i * ring_segments + j, i * ring_segments + j1
            c0, d0 = i1 * ring_segments + j, i1 * ring_segments + j1
            tris += [(a0, c0, d0), (a0, d0, b0)]
    return np.array(verts, float), np.array(tris, int)


BUILDERS = {"lathe": lathe, "sweep": sweep, "limb": limb, "blade": blade, "shell": shell,
            "horn": horn, "box": box, "sphere": sphere, "cylinder": cylinder, "torus": torus}


def build(spec):
    kind = spec["type"]
    args = {k: v for k, v in spec.items() if k != "type"}
    return BUILDERS[kind](**args)
