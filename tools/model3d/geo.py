"""Mesh building in numpy (game space: +Y up, the character faces -Z, its right is +X).

Mesh keeps per-vertex UVs and per-vertex bone weights. Builders return Meshes whose UVs are
in metres (so patterns keep a constant physical scale); textures divide by their tile size.
Angles for revolved shapes: theta = 0 at the front (-Z), increasing toward the right (+X).
"""
import math

import numpy as np


class Mesh:
    def __init__(self, v=None, f=None, uv=None):
        self.v = np.zeros((0, 3)) if v is None else np.asarray(v, dtype=float).reshape(-1, 3)
        self.f = [] if f is None else [tuple(int(i) for i in x) for x in f]
        self.uv = np.zeros((len(self.v), 2)) if uv is None else np.asarray(uv, dtype=float).reshape(-1, 2)
        self.w = {}

    # -------------------------------------------------------------- combining
    def copy(self):
        m = Mesh(self.v.copy(), list(self.f), self.uv.copy())
        m.w = {k: v.copy() for k, v in self.w.items()}
        return m

    def add(self, other):
        n0 = len(self.v)
        n1 = len(other.v)
        self.v = np.vstack([self.v, other.v]) if n0 else other.v.copy()
        self.uv = np.vstack([self.uv, other.uv]) if n0 else other.uv.copy()
        self.f += [tuple(i + n0 for i in x) for x in other.f]
        for k in set(self.w) | set(other.w):
            a = self.w.get(k, np.zeros(n0))
            b = other.w.get(k, np.zeros(n1))
            self.w[k] = np.concatenate([a, b])
        return self

    # -------------------------------------------------------------- transforms
    def apply(self, M, t=(0, 0, 0)):
        self.v = self.v @ np.asarray(M, dtype=float).T + np.asarray(t, dtype=float)
        if np.linalg.det(M) < 0:
            self.flip()
        return self

    def translate(self, d):
        self.v = self.v + np.asarray(d, dtype=float)
        return self

    def rotate(self, axis, deg, center=(0, 0, 0)):
        c = np.asarray(center, dtype=float)
        self.v = (self.v - c) @ rot(axis, deg).T + c
        return self

    def scale(self, s, center=(0, 0, 0)):
        c = np.asarray(center, dtype=float)
        s = np.broadcast_to(np.asarray(s, dtype=float), (3,))
        self.v = (self.v - c) * s + c
        if np.prod(s) < 0:
            self.flip()
        return self

    def mirror_x(self):
        m = self.copy()
        m.v[:, 0] *= -1.0
        m.flip()
        return m

    def flip(self):
        self.f = [tuple(reversed(x)) for x in self.f]
        return self

    def uv_scale(self, su, sv=None):
        self.uv = self.uv * np.array([su, su if sv is None else sv])
        return self

    # -------------------------------------------------------------- weights
    def bone(self, name):
        self.w = {name: np.ones(len(self.v))}
        return self

    def weights(self, fn):
        """fn(v: (N,3)) -> {bone: (N,) weights}."""
        self.w = {k: np.asarray(x, dtype=float) for k, x in fn(self.v).items()}
        return self


# ------------------------------------------------------------------ math helpers
def rot(axis, deg):
    if isinstance(axis, str):
        axis = {"x": (1, 0, 0), "y": (0, 1, 0), "z": (0, 0, 1)}[axis]
    a = np.asarray(axis, dtype=float)
    a = a / np.linalg.norm(a)
    t = math.radians(deg)
    c, s = math.cos(t), math.sin(t)
    x, y, z = a
    return np.array([[c + x * x * (1 - c), x * y * (1 - c) - z * s, x * z * (1 - c) + y * s],
                     [y * x * (1 - c) + z * s, c + y * y * (1 - c), y * z * (1 - c) - x * s],
                     [z * x * (1 - c) - y * s, z * y * (1 - c) + x * s, c + z * z * (1 - c)]])


def unit(v):
    v = np.asarray(v, dtype=float)
    return v / np.linalg.norm(v)


def smoothstep(e0, e1, x):
    t = np.clip((np.asarray(x, dtype=float) - e0) / (e1 - e0), 0.0, 1.0)
    return t * t * (3 - 2 * t)


def arclen(pts):
    pts = np.asarray(pts, dtype=float)
    d = np.linalg.norm(np.diff(pts, axis=0), axis=1)
    return np.concatenate([[0.0], np.cumsum(d)])


# ------------------------------------------------------------------ builders
def grid_faces(nu, nv, closed_u=False):
    """Quads for an (nv+1) x (nu+1) vertex grid laid out row by row (v major)."""
    f = []
    cols = nu + 1
    for j in range(nv):
        for i in range(nu):
            a = j * cols + i
            f.append((a, a + 1, a + cols + 1, a + cols))
    return f


def surface(points, uv):
    """points: (nv+1, nu+1, 3) grid; uv: (nv+1, nu+1, 2). Faces wind so that the normal is
    d(points)/du x d(points)/dv."""
    nv1, nu1, _ = points.shape
    m = Mesh(points.reshape(-1, 3), grid_faces(nu1 - 1, nv1 - 1), uv.reshape(-1, 2))
    return m


def revolve(profile, a0=-180.0, a1=180.0, segs=24, sx=1.0, sz=1.0, center=(0, 0, 0), outward=True):
    """Revolves a profile [(r, y), ...] (listed bottom to top) around the Y axis from angle a0
    to a1 (degrees; 0 = front). UVs: u = arc length at the profile's mean radius, v = length
    along the profile, both in metres."""
    prof = np.asarray(profile, dtype=float)
    th = np.radians(np.linspace(a0, a1, segs + 1))
    r = prof[:, 0][:, None]
    y = prof[:, 1][:, None]
    X = np.sin(th)[None, :] * r * sx
    Z = -np.cos(th)[None, :] * r * sz
    Y = np.broadcast_to(y, X.shape)
    pts = np.stack([X, Y, Z], axis=2) + np.asarray(center, dtype=float)
    r_ref = max(float(np.mean(prof[:, 0])), 1e-3)
    u = th * r_ref * 0.5 * (sx + sz)
    v = arclen(prof)
    uv = np.stack(np.broadcast_arrays(u[None, :], v[:, None]), axis=2)
    m = surface(pts, uv)
    orient_radial(m, center[0], center[2], outward)
    return m


def loft(rings, closed=True, v_len=None):
    """rings: list of (M, 3) point loops (same M). Closed loops get a duplicated seam column.
    UVs: u = length along the ring (metres, averaged over rings), v = distance between rings."""
    R = np.asarray(rings, dtype=float)
    if closed:
        R = np.concatenate([R, R[:, :1]], axis=1)
    lens = np.array([arclen(r) for r in R])
    u = lens.mean(axis=0)
    cent = R.mean(axis=1)
    v = arclen(cent) if v_len is None else np.asarray(v_len, dtype=float)
    uv = np.stack(np.broadcast_arrays(u[None, :], v[:, None]), axis=2)
    m = surface(R, uv)
    c = R.reshape(-1, 3).mean(axis=0)
    orient_radial(m, c[0], c[2], True)
    return m


def frames_along(path):
    """Parallel-transport frames (tangent, normal, binormal) along a polyline."""
    P = np.asarray(path, dtype=float)
    T = np.gradient(P, axis=0)
    T = T / np.linalg.norm(T, axis=1, keepdims=True)
    ref = np.array([0.0, 0.0, 1.0]) if abs(T[0][2]) < 0.9 else np.array([1.0, 0.0, 0.0])
    N = np.zeros_like(P)
    n = np.cross(T[0], ref)
    n /= np.linalg.norm(n)
    for i in range(len(P)):
        n = n - T[i] * np.dot(n, T[i])
        n /= np.linalg.norm(n)
        N[i] = n
    B = np.cross(T, N)
    return T, N, B


def sweep(path, radius, segs=12, sx=1.0, sy=1.0, phase=0.0, caps=False):
    """Tube along a polyline. radius: scalar or per-point array. sx/sy squash the section
    along the frame's normal/binormal."""
    P = np.asarray(path, dtype=float)
    r = np.broadcast_to(np.asarray(radius, dtype=float), (len(P),))
    T, N, B = frames_along(P)
    a = np.radians(np.linspace(0, 360, segs + 1)) + math.radians(phase)
    ring = (np.cos(a)[None, :, None] * N[:, None, :] * sx + np.sin(a)[None, :, None] * B[:, None, :] * sy)
    pts = P[:, None, :] + ring * r[:, None, None]
    u = a * float(np.mean(r))
    v = arclen(P)
    uv = np.stack(np.broadcast_arrays(u[None, :], v[:, None]), axis=2)
    m = surface(pts, uv)
    # outward from the path
    fn, fc = face_normals(m)
    nearest = P[np.argmin(np.linalg.norm(fc[:, None, :] - P[None, :, :], axis=2), axis=1)]
    if np.sum(np.einsum("ij,ij->i", fn, fc - nearest)) < 0:
        m.flip()
    if caps:
        for end, sign in ((0, 1), (len(P) - 1, -1)):
            c = Mesh([P[end]], [], [[0.0, 0.0]])
            n0 = len(m.v)
            ring_idx = [end * (segs + 1) + i for i in range(segs)]
            m.add(c)
            for i in range(segs):
                a0, a1 = ring_idx[i], ring_idx[(i + 1) % segs]
                m.f.append((n0, a1, a0) if sign > 0 else (n0, a0, a1))
    return m


def box(size, center=(0, 0, 0)):
    """Axis-aligned box with outward normals; UVs per face in metres."""
    sx, sy, sz = np.asarray(size, dtype=float) * 0.5
    c = np.asarray(center, dtype=float)
    m = Mesh()
    faces = [((1, 0, 0), (0, 0, -1), (0, 1, 0)), ((-1, 0, 0), (0, 0, 1), (0, 1, 0)),
             ((0, 1, 0), (1, 0, 0), (0, 0, -1)), ((0, -1, 0), (1, 0, 0), (0, 0, 1)),
             ((0, 0, 1), (1, 0, 0), (0, 1, 0)), ((0, 0, -1), (-1, 0, 0), (0, 1, 0))]
    half = np.array([sx, sy, sz])
    for n, uax, vax in faces:
        n, uax, vax = (np.array(x, dtype=float) for x in (n, uax, vax))
        hu = abs(np.dot(half, np.abs(uax)))
        hv = abs(np.dot(half, np.abs(vax)))
        hn = abs(np.dot(half, np.abs(n)))
        quad = [n * hn - uax * hu - vax * hv, n * hn + uax * hu - vax * hv,
                n * hn + uax * hu + vax * hv, n * hn - uax * hu + vax * hv]
        uv = [(0, 0), (2 * hu, 0), (2 * hu, 2 * hv), (0, 2 * hv)]
        m.add(Mesh(np.array(quad) + c, [(0, 1, 2, 3)], uv))
    return m


def superellipse(a, b_front, b_back, n=2.6, segs=32, y=0.0, center=(0.0, 0.0), ridge=0.0, ridge_w=0.25):
    """Closed ring at height y: half-width a (x), half-depths toward the front (-z) and back
    (+z), exponent n (2 = ellipse, higher = boxier). Starts at the front, goes to the right.
    ridge: extra outward bump at the front centre (the dō's hatomune ridge)."""
    th = np.linspace(0, 2 * math.pi, segs, endpoint=False)
    s, c = np.sin(th), np.cos(th)
    x = a * np.sign(s) * np.abs(s) ** (2.0 / n)
    bz = np.where(c > 0, b_front, b_back)
    z = -bz * np.sign(c) * np.abs(c) ** (2.0 / n)
    if ridge:
        z = z - ridge * np.exp(-(th - 0.0) ** 2 / ridge_w ** 2) - ridge * np.exp(-(th - 2 * math.pi) ** 2 / ridge_w ** 2)
    return np.stack([x + center[0], np.full_like(x, y), z + center[1]], axis=1)


# ------------------------------------------------------------------ orientation
def face_normals(m):
    """Per-face normals (from the first three corners) and centroids."""
    F = [f[:3] for f in m.f]
    idx = np.array(F)
    a, b, c = m.v[idx[:, 0]], m.v[idx[:, 1]], m.v[idx[:, 2]]
    n = np.cross(b - a, c - a)
    n /= np.linalg.norm(n, axis=1, keepdims=True) + 1e-12
    cen = np.array([m.v[list(f)].mean(axis=0) for f in m.f])
    return n, cen


def orient_radial(m, cx, cz, outward=True):
    """Flips the whole mesh if its faces point toward the vertical axis through (cx, cz)."""
    if not m.f:
        return m
    n, c = face_normals(m)
    radial = c - np.array([cx, 0.0, cz])
    radial[:, 1] = 0.0
    score = np.sum(np.einsum("ij,ij->i", n, radial))
    if (score < 0) == outward:
        m.flip()
    return m


def orient_dir(m, d):
    """Flips the whole mesh unless its faces mostly point along direction d."""
    n, _ = face_normals(m)
    if np.sum(n @ np.asarray(d, dtype=float)) < 0:
        m.flip()
    return m


def ribbon(path, width_dir, width, v_scale=1.0):
    """Flat strip along a polyline, `width` wide across `width_dir` (per point or one vector).
    UVs: u across (0..width metres), v along the path (metres)."""
    P = np.asarray(path, dtype=float)
    W = np.broadcast_to(np.asarray(width, dtype=float), (len(P),))
    D = np.broadcast_to(np.asarray(width_dir, dtype=float), P.shape)
    D = D / np.linalg.norm(D, axis=1, keepdims=True)
    pts = np.stack([P - D * W[:, None] * 0.5, P + D * W[:, None] * 0.5], axis=1)
    v = arclen(P) * v_scale
    u = np.stack([np.zeros(len(P)), W], axis=1)
    uv = np.stack([u, np.broadcast_to(v[:, None], u.shape)], axis=2)
    return surface(pts, uv)


def fan_cap(m, loop_idx, center, outward_dir):
    """Closes a vertex loop with a triangle fan around `center`."""
    n0 = len(m.v)
    m.add(Mesh([center], [], [[0.0, 0.0]]))
    cap = Mesh(m.v, [], m.uv)
    k = len(loop_idx)
    tris = [(n0, loop_idx[i], loop_idx[(i + 1) % k]) for i in range(k)]
    a, b, c = m.v[tris[0][0]], m.v[tris[0][1]], m.v[tris[0][2]]
    if np.dot(np.cross(b - a, c - a), outward_dir) < 0:
        tris = [(t[0], t[2], t[1]) for t in tris]
    m.f += tris
    return m
