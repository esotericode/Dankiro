"""Python mirror of the game's pose math (scripts/anim/*.gd).

Keeps exactly the same conventions so poses previewed here match the game:
  * Characters face -Z, +X is their right, +Y is up. Units are meters.
  * Rotations are Euler degrees applied like Godot's Basis.from_euler (YXZ):
    R = Ry * Rx * Rz.
  * Keys are resolved into full channel sets, then interpolated per component
    with monotone cubic Hermite (PCHIP) curves, optionally time-warped by an
    ease on the destination key.
  * Legs and arms use two-bone IK. Hinge frames are built from the bend plane
    so knees/elbows never flip.
"""
import json
import math
import os

import numpy as np

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

POS = ["root", "hips_pos", "foot_l", "foot_r", "weapon_pos"]
DIRS = ["knee_l", "knee_r", "elbow_l", "elbow_r"]
ROT = ["hips", "spine", "chest", "neck", "head", "foot_l_rot", "foot_r_rot", "weapon_rot",
       "upper_arm_l", "forearm_l", "hand_l", "upper_arm_r", "forearm_r", "hand_r"]
FLT = ["yaw", "ik_l", "ik_r", "grip_l", "grip_r"]
ALL = POS + DIRS + ROT + FLT
DIM = {c: (1 if c in FLT else 3) for c in ALL}


def load_json(rel):
    with open(os.path.join(ROOT, rel)) as f:
        return json.load(f)


# ---------------------------------------------------------------- math utils
def rot_x(a):
    c, s = math.cos(a), math.sin(a)
    return np.array([[1, 0, 0], [0, c, -s], [0, s, c]])


def rot_y(a):
    c, s = math.cos(a), math.sin(a)
    return np.array([[c, 0, s], [0, 1, 0], [-s, 0, c]])


def rot_z(a):
    c, s = math.cos(a), math.sin(a)
    return np.array([[c, -s, 0], [s, c, 0], [0, 0, 1]])


def euler_deg(v):
    x, y, z = (math.radians(a) for a in v)
    return rot_y(y) @ rot_x(x) @ rot_z(z)


def norm(v):
    n = np.linalg.norm(v)
    return v / n if n > 1e-9 else v


EASES = {
    "linear": lambda u: u,
    "in_quad": lambda u: u * u,
    "out_quad": lambda u: 1 - (1 - u) ** 2,
    "inout_quad": lambda u: 2 * u * u if u < 0.5 else 1 - (-2 * u + 2) ** 2 / 2,
    "in_cubic": lambda u: u ** 3,
    "out_cubic": lambda u: 1 - (1 - u) ** 3,
    "inout_cubic": lambda u: 4 * u ** 3 if u < 0.5 else 1 - (-2 * u + 2) ** 3 / 2,
    "in_quart": lambda u: u ** 4,
    "out_quart": lambda u: 1 - (1 - u) ** 4,
    "in_expo": lambda u: 0.0 if u <= 0 else 2 ** (10 * u - 10),
    "out_expo": lambda u: 1.0 if u >= 1 else 1 - 2 ** (-10 * u),
    "inout_sine": lambda u: 0.5 - 0.5 * math.cos(math.pi * u),
    "in_sine": lambda u: 1 - math.cos(math.pi * u / 2),
    "out_sine": lambda u: math.sin(math.pi * u / 2),
    "out_back": lambda u: 1 + 2.70158 * (u - 1) ** 3 + 1.70158 * (u - 1) ** 2,
    "in_back": lambda u: 2.70158 * u ** 3 - 1.70158 * u ** 2,
    "hold": lambda u: 0.0 if u < 1 else 1.0,
}


# ------------------------------------------------------------ rig + defaults
class Rig:
    def __init__(self, name, data):
        r = data["rigs"][name]
        self.name = name
        self.hips_height = r["hips_height"]
        self.joints = r["joints"]
        self.offset = {j["name"]: np.array(j["offset"], dtype=float) for j in self.joints}
        self.parent = {j["name"]: j["parent"] for j in self.joints}
        self.weapon = data["weapons"][r["weapon"]]
        self.weapon_name = r["weapon"]
        self.hurtbox = r["hurtbox"]
        self.l_upper = abs(self.offset["forearm_l"][1])
        self.l_fore = abs(self.offset["hand_l"][1])
        self.l_thigh = abs(self.offset["shin_l"][1])
        self.l_shin = abs(self.offset["foot_l"][1])
        self.wrist_offset = 0.04 if name == "boss" else 0.035

    def defaults(self):
        th = self.offset["thigh_l"]
        ankle_h = self.hips_height + th[1] - (self.l_thigh + self.l_shin)
        d = {
            "root": [0, 0, 0], "yaw": 0.0,
            "hips_pos": [0, self.hips_height, 0],
            "foot_l": [th[0], ankle_h, 0], "foot_r": [-th[0], ankle_h, 0],
            "knee_l": [-0.2, 0, -1], "knee_r": [0.2, 0, -1],
            "elbow_l": [-0.35, -1.0, 0.35], "elbow_r": [0.35, -1.0, 0.35],
            "weapon_pos": [0.25, 0.9, -0.3],
            "ik_l": 1.0, "ik_r": 1.0,
            "grip_l": self.weapon["grip_l"], "grip_r": self.weapon["grip_r"],
        }
        for c in ROT:
            d[c] = [0, 0, 0]
        return d


# ------------------------------------------------------------------- clips
class Clip:
    def __init__(self, name, data, lib, rig):
        self.name = name
        self.data = data
        self.loop = bool(data.get("loop", False))
        self.rig = rig
        keys = data["keys"]
        resolved = []
        prev = None
        for k in keys:
            if "pose" in k:
                base = dict(rig.defaults())
                base.update(resolve_pose(lib, k["pose"]))
            elif prev is not None:
                base = dict(prev)
            else:
                base = dict(rig.defaults())
            for ch, v in k.get("set", {}).items():
                base[ch] = v
            for ch, v in k.get("add", {}).items():
                if DIM[ch] == 1:
                    base[ch] = base[ch] + v
                else:
                    base[ch] = [a + b for a, b in zip(base[ch], v)]
            for ch in base:
                if ch not in DIM:
                    raise ValueError(f"{name}: unknown channel {ch}")
            resolved.append(base)
            prev = base
        self.times = np.array([k["t"] for k in keys], dtype=float)
        self.eases = [k.get("ease", "linear") for k in keys]
        self.length = float(data.get("length", self.times[-1]))
        self.values = {}
        self.tangents = {}
        for ch in ALL:
            vals = np.array([np.atleast_1d(np.array(r[ch], dtype=float)) for r in resolved])
            self.values[ch] = vals
            self.tangents[ch] = pchip_tangents(self.times, vals, self.loop, self.length)

    def eval(self, t):
        times = self.times
        n = len(times)
        if self.loop:
            t = t % self.length
        t = min(max(t, times[0]), times[-1])
        k = 0
        while k < n - 2 and t > times[k + 1]:
            k += 1
        if n == 1:
            return {ch: self.values[ch][0].copy() for ch in ALL}
        h = times[k + 1] - times[k]
        u = 0.0 if h <= 1e-9 else (t - times[k]) / h
        u = EASES[self.eases[k + 1]](min(max(u, 0.0), 1.0))
        out = {}
        for ch in ALL:
            y0, y1 = self.values[ch][k], self.values[ch][k + 1]
            m0, m1 = self.tangents[ch][k], self.tangents[ch][k + 1]
            out[ch] = hermite(y0, y1, m0 * h, m1 * h, u)
        return out


def resolve_pose(lib, name, depth=0):
    p = lib["poses"][name]
    out = {}
    if "base" in p:
        out.update(resolve_pose(lib, p["base"], depth + 1))
    for k, v in p.items():
        if k != "base":
            out[k] = v
    return out


def pchip_tangents(t, y, loop, length):
    n = len(t)
    m = np.zeros_like(y)
    if n < 2:
        return m
    h = np.diff(t)
    h[h < 1e-9] = 1e-9
    d = np.diff(y, axis=0) / h[:, None]
    dim = y.shape[1]
    for c in range(dim):
        for k in range(n):
            if 0 < k < n - 1:
                d0, d1, h0, h1 = d[k - 1, c], d[k, c], h[k - 1], h[k]
            elif loop and n > 2:
                d0, d1, h0, h1 = d[n - 2, c], d[0, c], h[n - 2], h[0]
            else:
                m[k, c] = 0.0
                continue
            if d0 * d1 <= 0:
                m[k, c] = 0.0
            else:
                w1 = 2 * h1 + h0
                w2 = h1 + 2 * h0
                m[k, c] = (w1 + w2) / (w1 / d0 + w2 / d1)
    return m


def hermite(y0, y1, m0, m1, u):
    u2, u3 = u * u, u * u * u
    return (2 * u3 - 3 * u2 + 1) * y0 + (u3 - 2 * u2 + u) * m0 + (-2 * u3 + 3 * u2) * y1 + (u3 - u2) * m1


# ---------------------------------------------------------------- solving
def two_bone(root, target, l1, l2, pole):
    dv = target - root
    dist = np.linalg.norm(dv)
    n = dv / dist if dist > 1e-6 else np.array([0.0, -1.0, 0.0])
    d = min(max(dist, abs(l1 - l2) + 1e-4), l1 + l2 - 1e-4)
    m = pole - n * np.dot(pole, n)
    if np.linalg.norm(m) < 1e-5:
        m = np.cross(n, np.array([1.0, 0.0, 0.0]))
    m = norm(m)
    cos_a = (l1 * l1 + d * d - l2 * l2) / (2 * l1 * d)
    a = math.acos(min(max(cos_a, -1.0), 1.0))
    mid = root + l1 * (math.cos(a) * n + math.sin(a) * m)
    end = root + n * d
    hinge = norm(np.cross(n, m))
    return mid, end, hinge


def bone_basis(direction, x_axis):
    y = -norm(direction)
    x = norm(x_axis - y * np.dot(x_axis, y))
    z = np.cross(x, y)
    return np.column_stack([x, y, z])


def solve(rig, ch):
    """Returns dict of model-space joint positions/bases plus weapon transform."""
    P, B = {}, {}
    P["hips"] = np.array(ch["hips_pos"], dtype=float)
    B["hips"] = euler_deg(ch["hips"])
    for j in ["spine", "chest", "neck", "head"]:
        par = rig.parent[j]
        P[j] = P[par] + B[par] @ rig.offset[j]
        B[j] = B[par] @ euler_deg(ch[j])
    errors = {}
    # legs
    for s in ["l", "r"]:
        th = "thigh_" + s
        P[th] = P["hips"] + B["hips"] @ rig.offset[th]
        ankle = np.array(ch["foot_" + s], dtype=float)
        foot_rot = ch["foot_%s_rot" % s]
        pole = rot_y(math.radians(foot_rot[1])) @ norm(np.array(ch["knee_" + s], dtype=float))
        mid, end, hinge = two_bone(P[th], ankle, rig.l_thigh, rig.l_shin, pole)
        B[th] = bone_basis(mid - P[th], hinge)
        P["shin_" + s] = mid
        B["shin_" + s] = bone_basis(end - mid, hinge)
        P["foot_" + s] = end
        B["foot_" + s] = euler_deg(foot_rot)
        errors["leg_" + s] = float(np.linalg.norm(end - ankle))
    # weapon
    WP = np.array(ch["weapon_pos"], dtype=float)
    WB = euler_deg(ch["weapon_rot"])
    axis = np.array(rig.weapon["grip_axis"], dtype=float)
    # arms
    for s in ["l", "r"]:
        ua, fa, hd = "upper_arm_" + s, "forearm_" + s, "hand_" + s
        P[ua] = P["chest"] + B["chest"] @ rig.offset[ua]
        w = float(np.clip(ch["ik_" + s], 0.0, 1.0))
        # FK
        Bu_fk = B["chest"] @ euler_deg(ch[ua])
        Bf_fk = Bu_fk @ euler_deg(ch[fa])
        if w > 0.0:
            grip = WP + WB @ (axis * ch["grip_" + s])
            wrist_t = grip - norm(grip - P[ua]) * rig.wrist_offset
            pole = B["chest"] @ norm(np.array(ch["elbow_" + s], dtype=float))
            mid, end, hinge = two_bone(P[ua], wrist_t, rig.l_upper, rig.l_fore, pole)
            Bu_ik = bone_basis(mid - P[ua], -hinge)
            Bf_ik = bone_basis(end - mid, -hinge)
            errors["arm_" + s] = float(np.linalg.norm(end - wrist_t)) if w > 0.5 else 0.0
            Bu = slerp_basis(Bu_fk, Bu_ik, w)
            # forearm local blend
            lf = slerp_basis(Bu_fk.T @ Bf_fk, Bu_ik.T @ Bf_ik, w)
            Bf = Bu @ lf
        else:
            Bu, Bf = Bu_fk, Bf_fk
            errors["arm_" + s] = 0.0
        B[ua] = Bu
        P[fa] = P[ua] + Bu @ rig.offset[fa]
        B[fa] = Bf
        P[hd] = P[fa] + Bf @ rig.offset[hd]
        B[hd] = Bf @ euler_deg(ch[hd])
    return P, B, WP, WB, errors


def slerp_basis(a, b, w):
    if w <= 0:
        return a
    if w >= 1:
        return b
    qa, qb = mat_to_quat(a), mat_to_quat(b)
    if np.dot(qa, qb) < 0:
        qb = -qb
    ang = math.acos(min(1.0, abs(float(np.dot(qa, qb)))))
    if ang < 1e-5:
        q = qa
    else:
        q = (math.sin((1 - w) * ang) * qa + math.sin(w * ang) * qb) / math.sin(ang)
    return quat_to_mat(norm(q))


def mat_to_quat(m):
    tr = m[0, 0] + m[1, 1] + m[2, 2]
    if tr > 0:
        s = math.sqrt(tr + 1.0) * 2
        return np.array([(m[2, 1] - m[1, 2]) / s, (m[0, 2] - m[2, 0]) / s, (m[1, 0] - m[0, 1]) / s, 0.25 * s])
    if m[0, 0] > m[1, 1] and m[0, 0] > m[2, 2]:
        s = math.sqrt(1.0 + m[0, 0] - m[1, 1] - m[2, 2]) * 2
        return np.array([0.25 * s, (m[0, 1] + m[1, 0]) / s, (m[0, 2] + m[2, 0]) / s, (m[2, 1] - m[1, 2]) / s])
    if m[1, 1] > m[2, 2]:
        s = math.sqrt(1.0 + m[1, 1] - m[0, 0] - m[2, 2]) * 2
        return np.array([(m[0, 1] + m[1, 0]) / s, 0.25 * s, (m[1, 2] + m[2, 1]) / s, (m[0, 2] - m[2, 0]) / s])
    s = math.sqrt(1.0 + m[2, 2] - m[0, 0] - m[1, 1]) * 2
    return np.array([(m[0, 2] + m[2, 0]) / s, (m[1, 2] + m[2, 1]) / s, 0.25 * s, (m[1, 0] - m[0, 1]) / s])


def quat_to_mat(q):
    x, y, z, w = q
    return np.array([
        [1 - 2 * (y * y + z * z), 2 * (x * y - z * w), 2 * (x * z + y * w)],
        [2 * (x * y + z * w), 1 - 2 * (x * x + z * z), 2 * (y * z - x * w)],
        [2 * (x * z - y * w), 2 * (y * z + x * w), 1 - 2 * (x * x + y * y)],
    ])


def blade_points(rig, WP, WB):
    out = {}
    for name, pts in rig.weapon["blades"].items():
        out[name] = [WP + WB @ np.array(p, dtype=float) for p in pts]
    return out
