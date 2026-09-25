"""Authoring helpers for tools/build_animations.py.

Everything returns plain lists/dicts that serialize straight into
data/animations.json using the channel conventions from rigmath.py.
"""
import math

import numpy as np

import rigmath as rm


def v(*a):
    return np.array(a, dtype=float)


def unit(a):
    a = np.array(a, dtype=float)
    n = np.linalg.norm(a)
    return a / n if n > 1e-9 else a


def axis_angle(axis, deg):
    axis = unit(axis)
    a = math.radians(deg)
    x, y, z = axis
    c, s, C = math.cos(a), math.sin(a), 1 - math.cos(a)
    return np.array([
        [c + x * x * C, x * y * C - z * s, x * z * C + y * s],
        [y * x * C + z * s, c + y * y * C, y * z * C - x * s],
        [z * x * C - y * s, z * y * C + x * s, c + z * z * C],
    ])


def euler_from_basis(m):
    """Inverse of rigmath.euler_deg (YXZ)."""
    x = math.asin(max(-1.0, min(1.0, -m[1, 2])))
    if abs(m[1, 2]) < 0.9999:
        y = math.atan2(m[0, 2], m[2, 2])
        z = math.atan2(m[1, 0], m[1, 1])
    else:
        y = math.atan2(-m[2, 0], m[0, 0])
        z = 0.0
    return [math.degrees(x), math.degrees(y), math.degrees(z)]


def closest_euler(prev, cur):
    """Pick the Euler triple equivalent to `cur` that is nearest to `prev`."""
    if prev is None:
        return cur
    cands = []
    alt = [180 - cur[0], cur[1] + 180, cur[2] + 180]
    for base in (cur, alt):
        c = []
        for i in range(3):
            val = base[i]
            val += 360 * round((prev[i] - val) / 360)
            c.append(val)
        cands.append(c)
    return min(cands, key=lambda c: sum((a - b) ** 2 for a, b in zip(c, prev)))


def weapon_rot(shaft_dir, edge_dir, prev=None):
    """Euler (deg) so weapon local +Y points along shaft_dir and local -Z along edge_dir."""
    y = unit(shaft_dir)
    z = -unit(edge_dir)
    z = unit(z - y * np.dot(z, y))
    x = np.cross(y, z)
    m = np.column_stack([x, y, z])
    return closest_euler(prev, euler_from_basis(m))


def r3(a):
    return [round(float(x), 4) for x in a]


class Pose(dict):
    """A dict of channels with convenience setters."""

    def copy(self):
        return Pose({k: (list(v) if isinstance(v, (list, tuple)) else v) for k, v in self.items()})

    def w(self, pos, shaft, edge, prev=None):
        self["weapon_pos"] = r3(pos)
        self["weapon_rot"] = r3(weapon_rot(shaft, edge, prev))
        return self


def key(t, pose=None, ease=None, **sets):
    k = {"t": round(float(t), 4)}
    if pose is not None:
        if isinstance(pose, str):
            k["pose"] = pose
        else:
            k["set"] = {ch: (r3(val) if isinstance(val, (list, tuple, np.ndarray)) else round(float(val), 4))
                        for ch, val in pose.items()}
    if sets:
        k.setdefault("set", {})
        for ch, val in sets.items():
            k["set"][ch] = r3(val) if isinstance(val, (list, tuple, np.ndarray)) else round(float(val), 4)
    if ease:
        k["ease"] = ease
    return k


def full(pose_dict):
    """Returns a 'set' dict with every channel in pose_dict (for keys without a named pose)."""
    return {ch: (r3(v) if isinstance(v, (list, tuple, np.ndarray)) else round(float(v), 4)) for ch, v in pose_dict.items()}


def lerp(a, b, t):
    return [x + (y - x) * t for x, y in zip(a, b)]


def gait(duration, step_len, direction_deg, feet_base, ankle_h, lift, duty=0.55, samples=8,
         hips_base=None, bob=0.03, sway=0.02, hip_yaw_amp=6.0, heel_pitch=18.0, turn_feet_deg=0.0):
    """Generates looping key data for a walk/run cycle.

    direction_deg: travel direction relative to facing (0 = forward, 90 = right, 180 = back, 270 = left).
    Returns list of (t, channels) with feet, hips_pos and hips rotation.
    Each foot in stance slides backward (relative to travel) at the travel speed so it stays planted.
    """
    a = math.radians(direction_deg)
    d = np.array([math.sin(a), 0.0, -math.cos(a)])  # travel direction in facing space
    speed = step_len / (duty * duration)             # contact must cover half stride... see below
    out = []
    hb = np.array(hips_base, dtype=float)
    for i in range(samples + 1):
        ph = i / samples
        t = ph * duration
        ch = {}
        for s, off in (("l", 0.0), ("r", 0.5)):
            p = (ph + off) % 1.0
            base = np.array(feet_base[s], dtype=float)
            if p < duty:          # stance: from +half to -half along d
                u = p / duty
                disp = step_len * (0.5 - u)
                y = ankle_h
                pitch = 0.0
            else:                 # swing: from -half to +half with lift
                u = (p - duty) / (1 - duty)
                su = 0.5 - 0.5 * math.cos(math.pi * u)
                disp = step_len * (-0.5 + su)
                y = ankle_h + lift * math.sin(math.pi * u)
                pitch = heel_pitch * math.sin(math.pi * u) if u < 0.6 else 0.0
            pos = base + d * disp
            pos[1] = y
            ch["foot_" + s] = r3(pos)
            ch["foot_%s_rot" % s] = r3([-pitch if direction_deg in (0, 360) else 0.0, turn_feet_deg, 0.0])
        # hips: two bobs per cycle, lowest just after each contact
        bob_y = -bob * math.cos(4 * math.pi * (ph - 0.08))
        sway_x = sway * math.sin(2 * math.pi * ph)
        ch["hips_pos"] = r3(hb + np.array([sway_x, bob_y, 0.0]))
        ch["_yaw"] = hip_yaw_amp * math.sin(2 * math.pi * ph)
        out.append((t, ch))
    return out, speed
