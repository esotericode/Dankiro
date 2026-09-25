"""Generates data/animations.json (poses + clips for the player and the boss).

Run:  python3 tools/build_animations.py && python3 tools/anim_preview.py --all --check

Conventions (see rigmath.py): facing -Z, +X right, +Y up, meters, Euler degrees (YXZ).
Weapons are animated directly (weapon_pos / weapon_rot in model space); hands grip them with IK.
Gameplay metadata lives next to the motion: hit windows, combo windows, tracking, etc.
"""
import json
import math
import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import rigmath as rm  # noqa: E402
from animkit import (Pose, axis_angle, key, r3, unit, v, weapon_rot, gait)  # noqa: E402

POSES = {}
CLIPS = {}
EASES_PY = rm.EASES
WEAPON_GRIP_R = -0.055      # katana: right hand just below the tsuba (data/rigs.json)


def clip(name, rig, keys, **meta):
    d = {"rig": rig, "keys": keys}
    d.update(meta)
    CLIPS[name] = d


def swing(t0, t1, steps, pivot, axis, deg, w_pos0, shaft0, edge0, prev_rot=None, ease=None, pivot_move=None):
    """Rigid rotation of the weapon around `pivot` (model space). Returns list of keys and last rot."""
    out = []
    for i in range(steps + 1):
        u = i / steps
        ue = u if ease is None else ease(u)
        R = axis_angle(axis, deg * ue)
        piv = np.array(pivot, dtype=float) + (np.array(pivot_move, dtype=float) * ue if pivot_move is not None else 0)
        pos = piv + R @ (np.array(w_pos0, dtype=float) - np.array(pivot, dtype=float))
        rot = weapon_rot(R @ unit(shaft0), R @ unit(edge0), prev_rot)
        prev_rot = rot
        out.append((t0 + (t1 - t0) * u, r3(pos), r3(rot)))
    return out, prev_rot


def in_quad(u):
    return u * u


def out_quad(u):
    return 1 - (1 - u) ** 2


def smooth(u):
    return u * u * (3 - 2 * u)


# =====================================================================================
# PLAYER (1.78 m shinobi, katana)
# =====================================================================================
P_STANCE = Pose({
    "hips_pos": [0.0, 0.93, 0.02], "hips": [0, 10, 0],
    "spine": [-6, -5, 0], "chest": [-4, -5, 0], "neck": [4, 0, 0], "head": [4, 0, 0],
    "foot_r": [0.12, 0.08, -0.18], "foot_r_rot": [0, 5, 0],
    "foot_l": [-0.14, 0.08, 0.20], "foot_l_rot": [0, 25, 0],
    "elbow_l": [-0.35, -1.0, 0.35], "elbow_r": [0.35, -1.0, 0.35],
}).w([0.02, 1.12, -0.32], [0, 0.7, -0.7], [0, -0.7, -0.7])
POSES["p_stance"] = dict(P_STANCE)

P_GUARD = P_STANCE.copy()
P_GUARD.update({"hips_pos": [0.0, 0.89, 0.04], "spine": [-9, -8, 0], "chest": [-7, -8, 0], "neck": [8, 3, 0],
                "head": [6, 3, 0], "foot_r": [0.14, 0.08, -0.20], "foot_l": [-0.17, 0.08, 0.23],
                "elbow_l": [-0.6, -0.8, 0.2], "elbow_r": [0.5, -0.9, 0.1]})
P_GUARD.w([0.10, 1.20, -0.30], [-0.55, 0.78, -0.30], [0.15, 0.25, -1.0])
POSES["p_guard"] = dict(P_GUARD)

# Deflect contact poses: blade meets the incoming strike.
DEFLECT = {
    "high": ([-0.02, 1.48, -0.30], [-1.0, 0.18, -0.10], [0.0, 1.0, -0.25]),
    "right": ([0.20, 1.16, -0.30], [0.12, 1.0, -0.25], [1.0, 0.0, -0.6]),
    "left": ([-0.06, 1.18, -0.33], [-0.30, 1.0, -0.20], [-1.0, 0.0, -0.6]),
    "mid": ([0.08, 1.12, -0.38], [-0.45, 0.55, -0.70], [0.2, -0.2, -1.0]),
}


def build_player():
    # ---------------- idle / guard loops
    clip("p_idle", "player", [
        key(0.0, "p_stance"),
        {"t": 1.3, "pose": "p_stance", "add": {"hips_pos": [0, -0.012, 0], "chest": [2, 0, 0], "weapon_pos": [0, -0.01, 0]}},
        key(2.6, "p_stance"),
    ], loop=True)
    clip("p_guard", "player", [
        key(0.0, "p_guard"),
        {"t": 1.0, "pose": "p_guard", "add": {"hips_pos": [0, -0.008, 0], "chest": [1.5, 0, 0], "weapon_pos": [0, -0.006, 0]}},
        key(2.0, "p_guard"),
    ], loop=True)

    # ---------------- locomotion (lock-on jog cycles keep the katana in guard-ready)
    feet = {"l": [-0.12, 0, 0.02], "r": [0.12, 0, -0.02]}
    for name, deg, step, dur, duty, yaw_twist in (("p_walk_fwd", 0, 0.72, 0.62, 0.42, 0), ("p_walk_back", 180, 0.60, 0.62, 0.45, 0),
                                                  ("p_walk_left", 270, 0.62, 0.60, 0.42, 28), ("p_walk_right", 90, 0.62, 0.60, 0.42, -28)):
        cyc, spd = gait(dur, step, deg, feet, 0.08, 0.12, duty=duty, samples=8, hips_base=[0, 0.92, 0.02],
                        bob=0.022, sway=0.015, hip_yaw_amp=5.0, turn_feet_deg=yaw_twist * 0.8)
        keys = []
        for t, ch in cyc:
            p = P_STANCE.copy()
            p.update({k: val for k, val in ch.items() if not k.startswith("_")})
            p["hips"] = [0, yaw_twist + ch["_yaw"], 0]
            p["spine"] = [-8, -yaw_twist * 0.5, 0]
            p["chest"] = [-6, -yaw_twist * 0.5 - ch["_yaw"] * 0.8, 0]
            p["weapon_pos"] = r3(np.array(P_STANCE["weapon_pos"]) + np.array([0, ch["hips_pos"][1] - 0.92, 0]))
            keys.append(key(t, p))
        clip(name, "player", keys, loop=True, stride_speed=round(spd, 3))

    # Free run: katana trails low in the right hand, left arm swings.
    run_keys = []
    cyc, run_spd = gait(0.62, 0.85, 0, {"l": [-0.11, 0, 0.0], "r": [0.11, 0, 0.0]}, 0.08, 0.26, duty=0.25, samples=8,
                        hips_base=[0, 0.86, -0.05], bob=0.028, sway=0.012, hip_yaw_amp=10.0, heel_pitch=35)
    prev = None
    for i, (t, ch) in enumerate(cyc):
        ph = t / 0.62
        s = math.sin(2 * math.pi * ph)
        p = Pose({k: val for k, val in ch.items() if not k.startswith("_")})
        p["hips"] = [8, ch["_yaw"], 0]
        p["spine"] = [-14, -ch["_yaw"] * 0.4, 0]
        p["chest"] = [-8, -ch["_yaw"] * 0.9, 0]
        p["neck"] = [14, 0, 0]
        p["head"] = [8, 0, 0]
        p["ik_l"] = 0.0
        p["upper_arm_l"] = [55 * s, 0, -12]
        p["forearm_l"] = [70 + 15 * s, 0, 0]
        p["hand_l"] = [0, 0, 0]
        wp = np.array([0.27, 0.86 + 0.02 * s, 0.04 - 0.10 * s])
        prev = weapon_rot([0.10, -0.30, 1.0], [0.1, -1.0, -0.3], prev)
        p["weapon_pos"] = r3(wp)
        p["weapon_rot"] = r3(prev)
        p["elbow_r"] = [0.6, -0.6, 0.6]
        run_keys.append(key(t, p))
    clip("p_run", "player", run_keys, loop=True, stride_speed=round(run_spd, 3))

    # ---------------- deflects (played at contact; snap in 50 ms, settle back to guard)
    for dname, (wpos, shaft, edge) in DEFLECT.items():
        p = P_GUARD.copy().w(wpos, shaft, edge, P_GUARD["weapon_rot"])
        p["chest"] = [-3, -8 + (6 if dname == "left" else -6 if dname == "right" else 0), 0]
        p["spine"] = [-6, -8, 0]
        recoil = p.copy()
        recoil["weapon_pos"] = r3(np.array(wpos) + np.array([0, 0.03, 0.07]))
        recoil["chest"] = [2, p["chest"][1], 0]
        recoil["hips_pos"] = [0, 0.88, 0.07]
        recoil["root"] = [0, 0, 0.10]
        clip("p_deflect_" + dname, "player", [
            key(0.0, "p_guard"),
            key(0.05, p, ease="out_cubic"),
            key(0.11, recoil, ease="out_quad"),
            {"t": 0.34, "pose": "p_guard", "set": {"root": [0, 0, 0.12]}, "ease": "inout_sine"},
        ], tags=["deflect"])

    blocked = P_GUARD.copy()
    blocked["weapon_pos"] = r3(np.array(P_GUARD["weapon_pos"]) + np.array([0, -0.04, 0.10]))
    blocked["chest"] = [4, -8, 0]
    blocked["spine"] = [0, -8, 0]
    blocked["hips_pos"] = [0, 0.86, 0.08]
    blocked["root"] = [0, 0, 0.16]
    end = {"root": [0, 0, 0.26]}
    clip("p_block", "player", [
        key(0.0, "p_guard"),
        key(0.07, blocked, ease="out_cubic"),
        {"t": 0.40, "pose": "p_guard", "set": end, "ease": "inout_sine"},
    ], tags=["guard"])

    # ---------------- attacks
    # Wolf-style slashes: a readable wind-up, a committed swing, a follow-through, then the
    # recovery (which, like the very start of the wind-up, can be cancelled into guard).
    # Rhythm when chained: a slash lands ~0.25 s after the press, the next slash can start
    # ~0.45 s after the previous one (the overhead finisher is slower and heavier).
    GR = WEAPON_GRIP_R

    def slash_attack(name, t_wind, t_load, t_swing_end, t_follow, t_end, pivot0, pivot1, a0, h_hit, over,
                     r=(0.30, 0.50, 0.36), lead=(-35.0, -6.0, 18.0), body=None, step=0.45, extra=None,
                     elbows=((0.7, -0.6, 0.3), (-0.7, -0.6, 0.3)), load_shift=(0.0, 0.03, 0.04)):
        """Builds a slash. The hands orbit `pivot` in the plane spanned by a0 (hands at the
        wind-up) and h_hit (hands at impact), `over` degrees past impact. `lead` is the blade's
        angle ahead of the hands (negative = wrist cocked back) at wind-up / impact / end."""
        a0 = unit(a0)
        h_hit = unit(h_hit)
        n = unit(np.cross(a0, h_hit))
        phi_hit = math.degrees(math.acos(max(-1.0, min(1.0, float(np.dot(a0, h_hit))))))
        phi_end = phi_hit + over
        body = body or (lambda u: {})

        def at(phi, rr, ld, piv, prev):
            h = axis_angle(n, phi) @ a0
            bl = axis_angle(n, phi + ld) @ a0
            edge = unit(np.cross(n, bl))
            hand = np.array(piv, dtype=float) + h * rr
            return r3(hand - bl * GR), weapon_rot(bl, edge, prev)

        def bez(v0, v1, v2, u):
            return (1 - u) ** 2 * v0 + 2 * (1 - u) * u * v1 + u * u * v2

        # wind-up (anticipation) and load (the beat before the release)
        wind = P_STANCE.copy()
        wpos, wrot = at(0.0, r[0], lead[0], pivot0, P_STANCE["weapon_rot"])
        wind.update({"weapon_pos": wpos, "weapon_rot": r3(wrot), "elbow_r": list(elbows[0]), "elbow_l": list(elbows[1])})
        wind.update(body(0.0))
        load = wind.copy()
        lpos, lrot = at(-8.0, r[0], lead[0] - 6.0, np.array(pivot0) + np.array(load_shift), wrot)
        load.update({"weapon_pos": lpos, "weapon_rot": r3(lrot)})
        load.update(body(0.0))
        load.update({"chest": r3(np.array(body(0.0).get("chest", [0, 0, 0])) + np.array([0, -4, 0]))})
        keys = [key(0.0, "p_stance"), key(t_wind, wind, ease="out_quad"), key(t_load, load, ease="inout_sine")]
        prev = lrot
        steps = 10
        for i in range(1, steps + 1):
            u = i / steps
            ue = EASES_PY["inout_cubic"](u)
            phi = -8.0 + (phi_end + 8.0) * ue
            k_hit = min(1.0, max(0.0, (phi + 8.0) / (phi_hit + 8.0)))
            rr = bez(r[0], r[1] * 1.08, r[2], ue) if phi <= phi_hit else r[1] + (r[2] - r[1]) * (phi - phi_hit) / over
            ld = lead[0] + (lead[1] - lead[0]) * k_hit if phi <= phi_hit else lead[1] + (lead[2] - lead[1]) * (phi - phi_hit) / over
            piv = np.array(pivot0) + (np.array(pivot1) - np.array(pivot0)) * smooth(ue)
            pos, prev = at(phi, rr, ld, piv, prev)
            d = {"weapon_pos": pos, "weapon_rot": r3(prev), "root": [0, 0, -step * smooth(ue)],
                 "elbow_r": [0.55, -0.8, 0.35], "elbow_l": [-0.55, -0.8, 0.35]}
            d.update(body(ue))
            keys.append(key(t_load + (t_swing_end - t_load) * u, d))
        follow = {"weapon_pos": r3(np.array(keys[-1]["set"]["weapon_pos"]) + np.array([0.0, -0.03, 0.04])),
                  "root": [0, 0, -step - 0.04]}
        follow.update(body(1.0))
        keys.append(key(t_follow, follow, ease="out_quad"))
        keys.append({"t": t_end, "pose": "p_stance", "set": {"root": [0, 0, -step - 0.05]}, "ease": "inout_sine"})
        meta = dict(extra or {})
        clip(name, "player", keys, **meta)
        return keys

    # Attack 1: kesa-giri, upper right -> lower left, stepping in.
    slash_attack("p_attack_1", 0.13, 0.19, 0.36, 0.48, 0.88,
                 pivot0=[0.08, 1.30, 0.02], pivot1=[-0.04, 1.20, -0.26],
                 a0=[0.45, 0.80, 0.40], h_hit=[-0.10, -0.30, -0.95], over=62,
                 r=(0.28, 0.50, 0.34), lead=(-38.0, -6.0, 20.0), step=0.42,
                 elbows=((0.9, -0.2, 0.4), (-0.3, -1.0, 0.3)),
                 body=lambda u: {"chest": r3([-2 - 12 * u, -34 + 72 * u, 0]), "spine": r3([-2 - 8 * u, -14 + 28 * u, 0]),
                                 "hips": r3([0, -8 + 26 * u, 0]), "neck": r3([4 + 6 * u, 18 - 30 * u, 0]),
                                 "hips_pos": r3([0, 0.94 - 0.07 * u, 0.05 - 0.12 * u]),
                                 "foot_r": r3([0.12, 0.08, -0.18 - 0.18 * smooth(u)]),
                                 "foot_l": r3([-0.14, 0.08, 0.20 + 0.04 * u])},
                 extra={"hits": [{"from": 0.235, "to": 0.345, "blade": "blade", "dmg": 42, "posture": 7}],
                        "combo_at": 0.46, "next": "p_attack_2", "cancel": 0.42, "lunge": [0.0, 0.28], "lunge_to": 1.65,
                        "guard_cancel": [[0.0, 0.08], [0.40, 0.88]],
                        "events": [{"t": 0.19, "type": "swing", "name": "swing_light", "pitch": 0.96}]})

    # Attack 2: rising return cut, lower left -> upper right.
    slash_attack("p_attack_2", 0.12, 0.17, 0.33, 0.45, 0.86,
                 pivot0=[-0.02, 1.18, -0.06], pivot1=[0.06, 1.24, -0.28],
                 a0=[-0.55, -0.60, 0.35], h_hit=[0.10, 0.05, -0.99], over=58,
                 r=(0.30, 0.45, 0.34), lead=(-32.0, -4.0, 16.0), step=0.44,
                 elbows=((0.5, -0.9, 0.3), (-0.9, -0.4, 0.3)),
                 body=lambda u: {"chest": r3([-10 + 8 * u, 30 - 66 * u, 0]), "spine": r3([-8 + 4 * u, 12 - 26 * u, 0]),
                                 "hips": r3([0, 18 - 30 * u, 0]), "neck": r3([6, -14 + 28 * u, 0]),
                                 "hips_pos": r3([0, 0.90 + 0.04 * u, 0.0 - 0.12 * u]),
                                 "foot_r": r3([0.12, 0.08, -0.18 - 0.14 * smooth(u)])},
                 extra={"hits": [{"from": 0.205, "to": 0.315, "blade": "blade", "dmg": 42, "posture": 7}],
                        "combo_at": 0.44, "next": "p_attack_3", "cancel": 0.40, "lunge": [0.0, 0.25], "lunge_to": 1.65,
                        "guard_cancel": [[0.0, 0.07], [0.38, 0.86]],
                        "events": [{"t": 0.17, "type": "swing", "name": "swing_light", "pitch": 1.04}]})

    # Attack 3: shomen, a heavy overhead cut (rises up, then drives down).
    slash_attack("p_attack_3", 0.22, 0.32, 0.48, 0.62, 1.10,
                 pivot0=[0.03, 1.26, 0.04], pivot1=[0.0, 1.12, -0.36],
                 a0=[0.05, 0.96, 0.25], h_hit=[0.0, -0.30, -0.95], over=38,
                 r=(0.40, 0.44, 0.36), lead=(-50.0, -8.0, 14.0), step=0.55,
                 elbows=((0.9, 0.2, 0.3), (-0.9, 0.2, 0.3)), load_shift=(0.0, 0.05, 0.06),
                 body=lambda u: {"chest": r3([12 - 38 * u, -10 + 4 * u, 0]), "spine": r3([8 - 22 * u, -6, 0]),
                                 "hips": r3([0, 6 - 4 * u, 0]), "neck": r3([-8 + 22 * u, 6, 0]),
                                 "hips_pos": r3([0, 0.97 - 0.13 * u, 0.06 - 0.18 * u]),
                                 "foot_r": r3([0.12, 0.08, -0.18 - 0.22 * smooth(u)]),
                                 "foot_l": r3([-0.14, 0.08, 0.20 + 0.06 * u])},
                 extra={"hits": [{"from": 0.365, "to": 0.465, "blade": "blade", "dmg": 58, "posture": 12}],
                        "combo_at": 0.74, "next": "p_attack_1", "cancel": 0.60, "lunge": [0.0, 0.36], "lunge_to": 1.7,
                        "guard_cancel": [[0.0, 0.12], [0.58, 1.10]], "tags": ["heavy"],
                        "events": [{"t": 0.31, "type": "swing", "name": "swing_heavy", "pitch": 1.12}]})

    # Air attack: downward diagonal slash while airborne (no root motion; physics carries us).
    air = P_STANCE.copy()
    air.update({"hips_pos": [0, 0.97, 0.0], "foot_l": [-0.12, 0.32, 0.12], "foot_r": [0.12, 0.42, -0.14],
                "foot_l_rot": [30, 10, 0], "foot_r_rot": [-10, 0, 0]})
    aw = air.copy().w([0.16, 1.70, 0.05], [0.2, 0.6, 0.78], [0.1, 1, -0.4], P_STANCE["weapon_rot"])
    aw.update({"chest": [12, -18, 0], "elbow_r": [0.9, 0.1, 0.4], "elbow_l": [-0.9, 0.1, 0.4]})
    swa, _ = swing(0.14, 0.25, 5, [0.03, 1.30, -0.10], unit([1, 0, 0.35]), -160, aw["weapon_pos"], [0.2, 0.6, 0.78],
                   [0.1, 1, -0.4], aw["weapon_rot"], ease=in_quad, pivot_move=[0, -0.1, -0.2])
    keys = [key(0.0, air), key(0.12, aw, ease="out_quad")]
    for i, (t, pos, rot) in enumerate(swa):
        u = i / (len(swa) - 1)
        keys.append(key(t, {"weapon_pos": pos, "weapon_rot": rot, "chest": [12 - 34 * u, -18 + 30 * u, 0],
                            "elbow_r": [0.5, -0.9, 0.3], "elbow_l": [-0.5, -0.9, 0.3]}))
    keys.append(key(0.36, {"chest": [-24, 12, 0]}, ease="out_quad"))
    keys.append(key(0.55, air, ease="inout_sine"))
    clip("p_air_attack", "player", keys,
         hits=[{"from": 0.15, "to": 0.26, "blade": "blade", "dmg": 50, "posture": 12}], cancel=0.4)

    # ---------------- dodge steps (lock-on relative). Root motion 2.3 m.
    for dname, deg, lean in (("fwd", 0, [-18, 0, 0]), ("back", 180, [10, 0, 0]),
                             ("left", 270, [-6, 0, 10]), ("right", 90, [-6, 0, -10])):
        a = math.radians(deg)
        d = np.array([math.sin(a), 0, -math.cos(a)])
        low = P_STANCE.copy()
        low.update({"hips_pos": r3([0.0, 0.80, 0.02]), "spine": r3([lean[0] - 6, -5, lean[2]]),
                    "chest": r3([lean[0] * 0.5 - 4, -5, lean[2] * 0.6]),
                    "foot_l": r3(np.array([-0.16, 0.08, 0.2]) + d * 0.22), "foot_r": r3(np.array([0.16, 0.08, -0.18]) + d * 0.35)})
        low["weapon_pos"] = r3(np.array(P_STANCE["weapon_pos"]) + np.array([0.04, -0.12, 0.08]))
        mid = low.copy()
        mid.update({"foot_l": r3(np.array([-0.16, 0.14, 0.2]) - d * 0.05), "foot_r": r3(np.array([0.16, 0.08, -0.18]) + d * 0.1)})
        # The forward (and neutral) step is a short step in, not a dash: it is the Mikiri
        # Counter input, and you shouldn't have to run into him to do it.
        dist = 1.3 if dname == "fwd" else 2.35
        keys = [key(0.0, "p_stance"),
                key(0.06, dict(low, root=r3(d * dist * 0.15)), ease="out_quad"),
                key(0.18, dict(mid, root=r3(d * dist * 0.74)), ease="linear"),
                key(0.30, dict(low, root=r3(d * dist * 0.96)), ease="out_quad"),
                {"t": 0.50, "pose": "p_stance", "set": {"root": r3(d * dist)}, "ease": "inout_sine"}]
        clip("p_dodge_" + dname, "player", keys, iframes=[0.02, 0.26], cancel=0.34,
             mikiri=[0.0, 0.33] if dname == "fwd" else None)
        if CLIPS["p_dodge_" + dname].get("mikiri") is None:
            del CLIPS["p_dodge_" + dname]["mikiri"]

    # ---------------- jump
    crouch = P_STANCE.copy()
    crouch.update({"hips_pos": [0, 0.80, 0.04], "chest": [-12, -5, 0], "spine": [-10, -5, 0],
                   "foot_l": [-0.14, 0.08, 0.14], "foot_r": [0.12, 0.08, -0.12]})
    crouch["weapon_pos"] = r3(np.array(P_STANCE["weapon_pos"]) + np.array([0, -0.10, 0.04]))
    tuck = P_STANCE.copy()
    tuck.update({"hips_pos": [0, 0.97, 0.0], "chest": [-10, -5, 0], "spine": [-8, -5, 0],
                 "foot_l": [-0.13, 0.42, 0.16], "foot_r": [0.13, 0.50, -0.10], "foot_l_rot": [35, 15, 0], "foot_r_rot": [-15, 0, 0]})
    tuck["weapon_pos"] = r3(np.array(P_STANCE["weapon_pos"]) + np.array([0.05, 0.08, 0.06]))
    POSES["p_tuck"] = dict(tuck)
    clip("p_jump", "player", [key(0.0, "p_stance"), key(0.06, crouch, ease="out_quad"),
                              key(0.16, dict(tuck, foot_l=[-0.13, 0.20, 0.10], foot_r=[0.13, 0.26, -0.08]), ease="out_quad"),
                              key(0.34, tuck, ease="inout_sine")])
    clip("p_air", "player", [key(0.0, tuck), key(0.5, dict(tuck, hips_pos=[0, 0.96, 0.01], chest=[-8, -5, 0])),
                             key(1.0, tuck)], loop=True)
    land = crouch.copy()
    land.update({"hips_pos": [0, 0.78, 0.03]})
    clip("p_land", "player", [key(0.0, tuck), key(0.07, land, ease="out_quad"), key(0.30, "p_stance", ease="inout_sine")])

    # Jump kick: front kick off the enemy (performed in the air).
    kick_p = tuck.copy()
    kick_p.update({"foot_r": [0.10, 0.95, -0.62], "foot_r_rot": [-70, 0, 0], "foot_l": [-0.12, 0.38, 0.22],
                   "chest": [8, -5, 0], "spine": [6, -5, 0], "hips_pos": [0, 0.97, 0.10]})
    clip("p_jump_kick", "player", [key(0.0, tuck), key(0.08, dict(tuck, foot_r=[0.12, 0.62, -0.22]), ease="out_quad"),
                                   key(0.14, kick_p, ease="out_cubic"), key(0.24, kick_p),
                                   key(0.44, tuck, ease="inout_sine")],
         hits=[{"from": 0.11, "to": 0.22, "blade": "kick"}])

    # ---------------- mikiri counter: step in and stomp the thrust.
    stomp_up = P_STANCE.copy()
    stomp_up.update({"hips_pos": [0, 0.90, -0.10], "foot_r": [0.12, 0.40, -0.48], "foot_r_rot": [0, 0, 0],
                     "foot_l": [-0.14, 0.08, 0.10], "chest": [-12, -8, 0], "spine": [-8, -5, 0], "root": [0, 0, -0.25]})
    stomp_up["weapon_pos"] = r3(np.array(P_STANCE["weapon_pos"]) + np.array([0.10, 0.06, 0.18]))
    stomp = stomp_up.copy()
    stomp.update({"hips_pos": [0, 0.78, -0.16], "foot_r": [0.10, 0.08, -0.52], "chest": [-22, -8, 0], "spine": [-14, -5, 0],
                  "neck": [16, 0, 0], "root": [0, 0, -0.35]})
    stomp["weapon_pos"] = r3(np.array(P_STANCE["weapon_pos"]) + np.array([0.18, -0.08, 0.26]))
    clip("p_mikiri", "player", [
        key(0.0, "p_stance"),
        key(0.08, stomp_up, ease="out_quad"),
        key(0.14, stomp, ease="in_cubic"),
        key(0.55, dict(stomp, hips_pos=[0, 0.80, -0.15])),
        {"t": 0.95, "pose": "p_stance", "set": {"root": [0, 0, -0.1]}, "ease": "inout_sine"},
    ], cancel=0.55, tags=["mikiri"])

    # ---------------- hurt / knockdown / guard break / repelled / death
    hit = P_STANCE.copy()
    hit.update({"hips_pos": [0, 0.90, 0.10], "chest": [14, 12, 6], "spine": [8, 6, 0], "neck": [-10, 0, 0],
                "root": [0, 0, 0.35]})
    hit["weapon_pos"] = r3(np.array(P_STANCE["weapon_pos"]) + np.array([0.12, -0.12, 0.18]))
    clip("p_hit", "player", [key(0.0, "p_stance"), key(0.07, hit, ease="out_cubic"),
                             {"t": 0.48, "pose": "p_stance", "set": {"root": [0, 0, 0.45]}, "ease": "inout_sine"}])

    fall1 = P_STANCE.copy()
    fall1.update({"hips_pos": [0, 0.82, 0.30], "chest": [30, 10, 0], "spine": [20, 5, 0], "neck": [-20, 0, 0],
                  "foot_r": [0.12, 0.30, -0.35], "root": [0, 0, 0.6], "ik_l": 0.0,
                  "upper_arm_l": [-40, 0, -40], "forearm_l": [30, 0, 0]})
    down = fall1.copy()
    down.update({"hips_pos": [0, 0.20, 0.55], "hips": [-70, 10, 0], "spine": [5, 0, 0], "chest": [5, 0, 0], "neck": [30, 0, 0],
                 "foot_l": [-0.16, 0.10, -0.25], "foot_r": [0.16, 0.12, -0.35], "foot_l_rot": [-60, 0, 0], "foot_r_rot": [-60, 0, 0],
                 "root": [0, 0, 1.3], "upper_arm_l": [-10, 0, -60], "forearm_l": [20, 0, 0], "ik_l": 0.0})
    down["weapon_pos"] = [0.55, 0.12, 0.35]
    down["weapon_rot"] = r3(weapon_rot([0.3, 0.0, -1.0], [0, 1, 0], P_STANCE["weapon_rot"]))
    kneel = P_STANCE.copy()
    kneel.update({"hips_pos": [0, 0.55, 0.15], "foot_l": [-0.15, 0.10, 0.45], "foot_l_rot": [-40, 20, 0],
                  "foot_r": [0.13, 0.08, -0.20], "chest": [-20, 0, 0], "spine": [-15, 0, 0], "root": [0, 0, 1.3], "ik_l": 0.0,
                  "upper_arm_l": [20, 0, -20], "forearm_l": [40, 0, 0]})
    kneel["weapon_pos"] = [0.35, 0.60, -0.15]
    clip("p_knockdown", "player", [key(0.0, "p_stance"), key(0.12, fall1, ease="out_quad"), key(0.42, down, ease="in_quad"),
                                   key(0.95, dict(down, root=[0, 0, 1.3])), key(1.25, kneel, ease="inout_sine"),
                                   {"t": 1.6, "pose": "p_stance", "set": {"root": [0, 0, 1.3]}, "ease": "inout_sine"}],
         iframes=[0.9, 1.6])

    gb = P_STANCE.copy()
    gb.update({"hips_pos": [0, 0.84, 0.14], "chest": [22, 18, 0], "spine": [10, 8, 0], "neck": [-14, 0, 0],
               "ik_l": 0.0, "upper_arm_l": [20, 0, -55], "forearm_l": [30, 0, 0], "root": [0, 0, 0.5],
               "foot_l": [-0.18, 0.08, 0.32]})
    gb.w([0.45, 1.25, -0.05], [0.7, 0.7, 0.2], [0.3, -0.2, -1.0], P_STANCE["weapon_rot"])
    slump = gb.copy()
    slump.update({"hips_pos": [0, 0.80, 0.14], "chest": [-24, 5, 0], "spine": [-18, 0, 0], "neck": [18, 0, 0], "root": [0, 0, 0.6]})
    slump.w([0.30, 0.75, -0.20], [0.3, -0.3, -1.0], [0, -1, 0], gb["weapon_rot"])
    clip("p_guard_break", "player", [key(0.0, "p_guard"), key(0.10, gb, ease="out_cubic"), key(0.45, slump, ease="inout_sine"),
                                     key(1.05, dict(slump, hips_pos=[0, 0.82, 0.14])),
                                     {"t": 1.45, "pose": "p_stance", "set": {"root": [0, 0, 0.6]}, "ease": "inout_sine"}])

    rep = P_STANCE.copy()
    rep.update({"hips_pos": [0, 0.90, 0.12], "chest": [16, 14, 0], "spine": [8, 6, 0], "root": [0, 0, 0.35],
                "ik_l": 0.0, "upper_arm_l": [10, 0, -35], "forearm_l": [30, 0, 0]})
    rep.w([0.42, 1.55, -0.05], [0.4, 0.9, 0.3], [0.6, 0.1, -1.0], P_STANCE["weapon_rot"])
    clip("p_repelled", "player", [key(0.0, "p_stance"), key(0.09, rep, ease="out_cubic"), key(0.30, dict(rep, root=[0, 0, 0.45])),
                                  {"t": 0.62, "pose": "p_stance", "set": {"root": [0, 0, 0.48]}, "ease": "inout_sine"}],
         cancel=0.26)

    dk = kneel.copy()
    dk.update({"root": [0, 0, 0.15], "chest": [-35, 0, 0], "spine": [-20, 0, 0], "neck": [-10, 0, 0], "hips_pos": [0, 0.52, 0.18]})
    dead = dk.copy()
    dead.update({"hips_pos": [0, 0.16, -0.25], "hips": [80, 0, 0], "spine": [0, 0, 0], "chest": [0, 0, 5], "neck": [0, 30, 0],
                 "foot_l": [-0.2, 0.06, 0.55], "foot_r": [0.18, 0.06, 0.60], "foot_l_rot": [-90, 0, 0], "foot_r_rot": [-90, 0, 0],
                 "root": [0, 0, 0.15], "upper_arm_l": [150, 0, -30], "forearm_l": [10, 0, 0]})
    dead["weapon_pos"] = [0.55, 0.05, -0.50]
    dead["weapon_rot"] = r3(weapon_rot([1.0, 0.0, -0.3], [0, 1, 0], P_STANCE["weapon_rot"]))
    clip("p_death", "player", [key(0.0, "p_stance"), key(0.15, hit, ease="out_cubic"),
                               key(0.75, dict(dk), ease="inout_sine"), key(1.25, dict(dk, chest=[-40, 0, 0])),
                               key(1.75, dead, ease="in_quad"), key(2.6, dead)])

    # ---------------- heal (gourd in left hand)
    heal_up = P_STANCE.copy()
    heal_up.update({"ik_l": 0.0, "upper_arm_l": [70, 0, -25], "forearm_l": [120, 0, 0], "hand_l": [0, 0, 0], "neck": [-18, 0, 0],
                    "head": [-12, 0, 0], "chest": [4, 0, 0]})
    heal_up["weapon_pos"] = [0.30, 0.95, -0.20]
    heal_up["weapon_rot"] = r3(weapon_rot([0.1, 0.5, -1.0], [0.0, -1.0, -0.4], P_STANCE["weapon_rot"]))
    clip("p_heal", "player", [key(0.0, "p_stance"), key(0.25, heal_up, ease="inout_sine"), key(0.75, heal_up),
                              key(1.1, "p_stance", ease="inout_sine")], cancel=0.95,
         events=[{"t": 0.5, "type": "heal"}, {"t": 0.3, "type": "sfx", "name": "heal"}])

    # ---------------- deathblow: lunge and thrust into the staggered boss.
    db_draw = P_STANCE.copy()
    db_draw.update({"hips_pos": [0, 0.88, 0.08], "chest": [-4, -35, 0], "spine": [-4, -15, 0], "hips": [0, -10, 0]})
    db_draw.w([0.30, 1.28, 0.20], [-0.1, 0.1, -1.0], [0, -1, 0], P_STANCE["weapon_rot"])
    db_stab = P_STANCE.copy()
    db_stab.update({"hips_pos": [0, 0.84, -0.20], "chest": [-18, 5, 0], "spine": [-12, 0, 0], "hips": [0, 10, 0],
                    "foot_r": [0.14, 0.08, -0.60], "root": [0, 0, -0.55], "elbow_r": [0.6, -0.5, 0.6]})
    db_stab.w([0.10, 1.30, -0.62], [-0.08, 0.12, -1.0], [0, -1, 0], P_STANCE["weapon_rot"])
    db_pull = db_stab.copy()
    db_pull.update({"chest": [-2, -30, 0], "hips_pos": [0, 0.88, -0.05], "root": [0, 0, -0.35]})
    db_pull.w([0.45, 1.20, -0.05], [0.8, -0.3, 0.2], [0.3, 0.8, -0.4], db_stab["weapon_rot"])
    db_flick = db_pull.copy()
    db_flick.update({"chest": [-6, -38, 0]})
    db_flick.w([0.52, 0.95, 0.10], [0.85, -0.5, -0.1], [0.1, -1, 0], db_pull["weapon_rot"])
    clip("p_deathblow", "player", [
        key(0.0, "p_stance"), key(0.18, db_draw, ease="out_quad"),
        key(0.30, db_stab, ease="in_cubic"), key(0.85, dict(db_stab, chest=[-20, 8, 0])),
        key(1.05, db_pull, ease="inout_cubic"), key(1.25, db_flick, ease="out_quad"), key(1.5, db_flick),
        {"t": 1.9, "pose": "p_stance", "set": {"root": [0, 0, -0.35]}, "ease": "inout_sine"},
    ], events=[{"t": 0.30, "type": "deathblow_hit"}, {"t": 1.05, "type": "deathblow_pull"},
               {"t": 1.2, "type": "sfx", "name": "flick"}])


# =====================================================================================
# BOSS (2.05 m warrior, twin-bladed staff ~2.9 m)
# =====================================================================================
B_STANCE = Pose({
    "hips_pos": [0.0, 1.02, 0.02], "hips": [0, -20, 0],
    "spine": [-5, 5, 0], "chest": [-5, 5, 0], "neck": [5, 5, 0], "head": [3, 5, 0],
    "foot_l": [-0.16, 0.08, -0.30], "foot_l_rot": [0, -10, 0],
    "foot_r": [0.20, 0.08, 0.28], "foot_r_rot": [0, -40, 0],
    "elbow_l": [-0.4, -1.0, 0.3], "elbow_r": [0.5, -1.0, 0.4],
})
B_STANCE.w([0.05, 1.12, -0.25], [-0.093, 0.45, -0.885], [0, -0.9, -0.45])
POSES["b_stance"] = dict(B_STANCE)


def place(pose, hand_r, shaft, edge, grip_r, grip_l, prev=None):
    """Positions the weapon so the right hand sits at hand_r (model space)."""
    shaft = unit(shaft)
    pose["grip_r"] = grip_r
    pose["grip_l"] = grip_l
    pose["weapon_pos"] = r3(np.array(hand_r, dtype=float) - shaft * grip_r)
    pose["weapon_rot"] = r3(weapon_rot(shaft, edge, prev if prev is not None else pose.get("weapon_rot")))
    return pose


def arc(start_dir, through_dir):
    """Axis + angle (deg) of the great circle from start_dir that passes through through_dir."""
    a, b = unit(start_dir), unit(through_dir)
    axis = unit(np.cross(a, b))
    return axis, math.degrees(math.acos(max(-1.0, min(1.0, float(np.dot(a, b))))))


def hswing(t0, t1, steps, pivot, axis, deg, hand0, shaft0, edge0, grip_r, prev_rot=None, ease=None, pivot_move=None):
    """Rigid swing of the weapon around `pivot`, positioned by the right hand."""
    out = []
    pivot = np.array(pivot, dtype=float)
    for i in range(steps + 1):
        u = i / steps
        ue = u if ease is None else ease(u)
        R = axis_angle(axis, deg * ue)
        piv = pivot + (np.array(pivot_move, dtype=float) * ue if pivot_move is not None else 0)
        hand = piv + R @ (np.array(hand0, dtype=float) - pivot)
        shaft = R @ unit(shaft0)
        rot = weapon_rot(shaft, R @ unit(edge0), prev_rot)
        prev_rot = rot
        out.append((t0 + (t1 - t0) * u, r3(hand - shaft * grip_r), r3(rot)))
    return out, prev_rot


def edge_for(axis, blade_dir, sign=1.0):
    """Edge direction that leads a rotation about `axis` (positive angle) for a blade pointing along blade_dir."""
    return unit(np.cross(unit(axis), unit(blade_dir)) * sign)


def bkeys_from_swing(sw, body_fn):
    out = []
    n = len(sw) - 1
    for i, (t, pos, rot) in enumerate(sw):
        u = i / n
        d = {"weapon_pos": pos, "weapon_rot": rot}
        d.update(body_fn(u))
        out.append(key(t, d))
    return out


def lerp3(a, b, u):
    return [x + (y - x) * u for x, y in zip(a, b)]


def windmill_rot(ang_deg, prev, lean_deg=32.0):
    """Staff spinning in a vertical plane beside the body (angle about the side axis), with the
    plane leaned outward by `lean_deg` so the low blade swings wide of the floor."""
    R = axis_angle([0.0, 0.0, 1.0], lean_deg) @ axis_angle([1.0, 0.0, 0.0], ang_deg)
    return weapon_rot(R @ np.array([0.0, 1.0, 0.0]), R @ np.array([0.0, 0.0, -1.0]), prev)


def build_boss():
    # NOTE: hit "dir" is the side the blade arrives from *as the player sees it* (it picks the
    # player's deflect pose). The boss's right side is the player's left.
    S = B_STANCE
    # ---------------- idle / guard / locomotion
    clip("b_idle", "boss", [
        key(0.0, "b_stance"),
        {"t": 1.5, "pose": "b_stance", "add": {"hips_pos": [0, -0.015, 0], "chest": [2, 0, 0], "weapon_pos": [0, -0.012, 0]}},
        key(3.0, "b_stance"),
    ], loop=True)

    guard = S.copy()
    guard.update({"hips_pos": [0, 0.98, 0.04], "hips": [0, -10, 0], "spine": [-4, 5, 0], "chest": [-2, 5, 0],
                  "foot_l": [-0.20, 0.08, -0.26], "foot_r": [0.24, 0.08, 0.26], "elbow_l": [-0.8, -0.6, 0.2],
                  "elbow_r": [0.8, -0.6, 0.2]})
    guard.w([0.02, 1.42, -0.42], [-1.0, 0.08, 0.0], [0, 1, -0.3], S["weapon_rot"])
    POSES["b_guard"] = dict(guard)
    clip("b_guard", "boss", [key(0.0, "b_guard"),
                             {"t": 1.0, "pose": "b_guard", "add": {"hips_pos": [0, -0.01, 0], "weapon_pos": [0, -0.01, 0]}},
                             key(2.0, "b_guard")], loop=True)
    gh = guard.copy()
    gh.update({"chest": [6, 5, 0], "spine": [2, 5, 0], "hips_pos": [0, 0.96, 0.08], "root": [0, 0, 0.12]})
    gh["weapon_pos"] = r3(np.array(guard["weapon_pos"]) + np.array([0, 0.02, 0.10]))
    clip("b_guard_hit", "boss", [key(0.0, "b_guard"), key(0.07, gh, ease="out_cubic"),
                                 {"t": 0.36, "pose": "b_guard", "set": {"root": [0, 0, 0.16]}, "ease": "inout_sine"}])

    feet = {"l": [-0.16, 0, -0.12], "r": [0.19, 0, 0.12]}
    for name, deg, step, dur, duty in (("b_walk_fwd", 0, 0.78, 0.85, 0.5), ("b_walk_back", 180, 0.62, 0.90, 0.5),
                                       ("b_walk_left", 270, 0.62, 0.85, 0.5), ("b_walk_right", 90, 0.62, 0.85, 0.5)):
        cyc, spd = gait(dur, step, deg, feet, 0.08, 0.12, duty=duty, samples=8, hips_base=[0, 1.02, 0.02],
                        bob=0.025, sway=0.02, hip_yaw_amp=4.0, turn_feet_deg=-15)
        keys = []
        for t, ch in cyc:
            p = S.copy()
            p.update({k: val for k, val in ch.items() if not k.startswith("_")})
            p["hips"] = [0, -20 + ch["_yaw"], 0]
            p["chest"] = [-5, 5 - ch["_yaw"] * 0.7, 0]
            p["weapon_pos"] = r3(np.array(S["weapon_pos"]) + np.array([0, ch["hips_pos"][1] - 1.02, 0]))
            keys.append(key(t, p))
        clip(name, "boss", keys, loop=True, stride_speed=round(spd, 3))

    cyc, spd = gait(0.70, 1.0, 0, {"l": [-0.13, 0, 0], "r": [0.13, 0, 0]}, 0.08, 0.26, duty=0.32, samples=8,
                    hips_base=[0, 0.98, -0.05], bob=0.03, sway=0.015, hip_yaw_amp=9.0, heel_pitch=30)
    keys = []
    prev = None
    for t, ch in cyc:
        ph = t / 0.70
        sn = math.sin(2 * math.pi * ph)
        p = Pose({k: val for k, val in ch.items() if not k.startswith("_")})
        p["hips"] = [8, ch["_yaw"], 0]
        p["spine"] = [-12, -ch["_yaw"] * 0.4, 0]
        p["chest"] = [-8, -ch["_yaw"] * 0.9, 0]
        p["neck"] = [14, 0, 0]
        p["head"] = [6, 0, 0]
        p["ik_l"] = 0.0
        p["upper_arm_l"] = [50 * sn, 0, -10]
        p["forearm_l"] = [65 + 12 * sn, 0, 0]
        prev = weapon_rot([0.1, -0.12, 1.0], [0, -1, 0.1], prev)
        p["weapon_pos"] = r3([0.34, 1.02 + 0.02 * sn, 0.05 - 0.08 * sn])
        p["weapon_rot"] = r3(prev)
        p["grip_r"] = 0.0
        p["elbow_r"] = [0.6, -0.7, 0.5]
        keys.append(key(t, p))
    clip("b_run", "boss", keys, loop=True, stride_speed=round(spd, 3))

    # =========================================================== ATTACKS
    # ---- Combo 1: "Rising Fang" (lower blade rises from low-right-back, through the front, to high-left)
    R0 = [0.40, 1.10, 0.06]
    shaft_w = unit([-0.50, 0.42, -0.76])            # upper blade forward-up-left, lower blade trails back-right-low
    ls = -shaft_w
    ax1, a_front = arc(ls, [0.12, 0.05, -1.0])
    total1 = a_front + 62
    wind = S.copy()
    wind.update({"hips_pos": [0, 0.97, 0.10], "hips": [0, -38, 0], "spine": [-4, -12, 0], "chest": [-2, -28, 0],
                 "neck": [4, 34, 0], "head": [2, 16, 0], "foot_l": [-0.16, 0.08, -0.34], "foot_r": [0.22, 0.08, 0.30],
                 "elbow_l": [-0.5, -1, 0.1], "elbow_r": [0.7, -0.8, 0.5]})
    place(wind, R0, shaft_w, edge_for(ax1, ls, -1.0), -0.05, 0.45, S["weapon_rot"])
    piv = np.array(R0) + shaft_w * 0.25
    sw, last = hswing(0.40, 0.57, 7, piv, ax1, total1, R0, shaft_w, edge_for(ax1, ls, -1.0), -0.05,
                      wind["weapon_rot"], ease=in_quad, pivot_move=[-0.20, 0.12, -0.40])
    keys = [key(0.0, "b_stance"), key(0.30, wind, ease="inout_sine"),
            key(0.40, dict(wind, hips_pos=[0, 0.96, 0.12], chest=[-2, -33, 0], weapon_pos=r3(np.array(wind["weapon_pos"]) + [0.03, -0.02, 0.05])), ease="linear")]
    keys += bkeys_from_swing(sw, lambda u: {
        "hips": [0, -38 + 55 * u, 0], "chest": [-2 - 8 * u, -33 + 75 * u, 0], "spine": [-4 - 4 * u, -12 + 24 * u, 0],
        "neck": [4, 34 - 48 * u, 0], "head": [2, 16 - 24 * u, 0],
        "hips_pos": [0, 0.96 + 0.03 * u, 0.12 - 0.26 * u], "foot_l": lerp3([-0.16, 0.08, -0.34], [-0.18, 0.08, -0.54], smooth(u)),
        "root": [0, 0, -0.8 * u], "elbow_l": [-0.8, -0.6, 0.2], "elbow_r": [0.7, -0.7, 0.4]})
    fol = {"chest": [-12, 46, 0], "hips": [0, 20, 0], "root": [0, 0, -0.9], "neck": [0, -16, 0],
           "weapon_pos": r3(np.array(sw[-1][1]) + np.array([-0.04, 0.04, 0.02]))}
    keys.append(key(0.72, fol, ease="out_quad"))
    keys.append({"t": 1.12, "pose": "b_stance", "set": {"root": [0, 0, -0.95]}, "ease": "inout_sine"})
    clip("b_combo_1", "boss", keys, chain=0.68, close=[0.08, 0.44, 1.9, 3.8], chain_in=0.10, vuln=[0.80, 1.10],
         track=[[0.0, 0.34, 420], [0.34, 0.46, 160]],
         hits=[{"from": 0.45, "to": 0.58, "blade": "lower", "kind": "normal", "dmg": 26, "posture_block": 22,
                "posture_deflect": 7, "boss_posture": 11, "dir": "left"}],
         events=[{"t": 0.38, "type": "sfx", "name": "swing_heavy"}])

    # ---- Combo 2: "Turning Fang" (flat cut, upper blade, right -> left, counter-clockwise from above)
    us = unit([0.85, 0.06, 0.52])
    ax2, a2 = arc(us, [0.0, 0.0, -1.0])
    R2 = [0.36, 1.30, 0.08]
    wind2 = S.copy()
    wind2.update({"hips_pos": [0, 0.98, 0.06], "hips": [0, -40, 0], "spine": [-4, -14, 0], "chest": [-4, -32, 0],
                  "neck": [4, 40, 0], "head": [0, 18, 0], "foot_l": [-0.16, 0.08, -0.32], "foot_r": [0.24, 0.08, 0.28],
                  "elbow_l": [-0.4, -1.0, 0.2], "elbow_r": [0.6, -0.9, 0.5], "root": [0, 0, 0]})
    e2 = edge_for(ax2, us)
    place(wind2, R2, us, e2, 0.15, -0.30, S["weapon_rot"])
    piv2 = np.array(R2) - us * 0.22
    sw2, _ = hswing(0.30, 0.45, 7, piv2, ax2, a2 + 85, R2, us, e2, 0.15, wind2["weapon_rot"], ease=in_quad,
                    pivot_move=[-0.05, 0.0, -0.35])
    keys = [key(0.0, "b_stance"), key(0.22, wind2, ease="inout_sine"),
            key(0.30, dict(wind2, chest=[-4, -36, 0]), ease="linear")]
    keys += bkeys_from_swing(sw2, lambda u: {
        "hips": [0, -40 + 70 * u, 0], "chest": [-4 - 6 * u, -36 + 95 * u, 0], "spine": [-4, -14 + 32 * u, 0],
        "neck": [4, 40 - 60 * u, 0], "head": [0, 18 - 28 * u, 0],
        "hips_pos": [0, 0.98 - 0.02 * u, 0.06 - 0.12 * u], "root": [0, 0, -0.82 * u],
        "foot_r": lerp3([0.24, 0.08, 0.28], [0.26, 0.08, 0.02], smooth(u)),
        "elbow_l": [-0.7, -0.7, 0.3], "elbow_r": [0.5, -0.9, 0.4]})
    keys.append(key(0.62, {"chest": [-10, 62, 0], "hips": [0, 34, 0], "root": [0, 0, -0.88]}, ease="out_quad"))
    keys.append({"t": 1.0, "pose": "b_stance", "set": {"root": [0, 0, -0.92]}, "ease": "inout_sine"})
    clip("b_combo_2", "boss", keys, chain=0.62, close=[0.06, 0.32, 1.9, 3.8], chain_in=0.10, vuln=[0.72, 1.0],
         track=[[0.0, 0.26, 360], [0.26, 0.34, 120]],
         hits=[{"from": 0.33, "to": 0.46, "blade": "upper", "kind": "normal", "dmg": 26, "posture_block": 22,
                "posture_deflect": 7, "boss_posture": 11, "dir": "left"}],
         events=[{"t": 0.28, "type": "sfx", "name": "swing_heavy"}])

    # ---- Combo 3: "Heaven's Fall" (delayed overhead cleave, upper blade)
    ob = unit([0.0, 0.35, 0.94])
    ax3 = [1.0, 0.0, 0.0]
    oe = edge_for(ax3, ob, -1.0)
    R3 = [0.10, 1.98, 0.02]
    up = S.copy()
    up.update({"hips_pos": [0, 1.00, 0.08], "hips": [0, -8, 0], "spine": [8, 0, 0], "chest": [12, 0, 0], "neck": [-8, 0, 0],
               "head": [-6, 0, 0], "foot_l": [-0.16, 0.08, -0.32], "foot_r": [0.20, 0.08, 0.30],
               "elbow_l": [-0.9, 0.0, 0.4], "elbow_r": [0.9, 0.0, 0.4]})
    place(up, R3, ob, oe, -0.10, -0.55, S["weapon_rot"])
    piv3 = np.array([0.08, 1.70, -0.05])
    sw3, _ = hswing(0.62, 0.73, 7, piv3, ax3, -185, R3, ob, oe, -0.10, up["weapon_rot"], ease=in_quad,
                    pivot_move=[0.0, -0.45, -0.45])
    keys = [key(0.0, "b_stance"), key(0.42, up, ease="inout_sine"),
            key(0.62, dict(up, hips_pos=[0, 1.01, 0.10], chest=[15, 0, 0]), ease="out_sine")]
    keys += bkeys_from_swing(sw3, lambda u: {
        "chest": [15 - 42 * u, 0, 0], "spine": [8 - 24 * u, 0, 0], "neck": [-8 + 22 * u, 0, 0],
        "hips_pos": [0, 1.01 - 0.14 * u, 0.10 - 0.28 * u], "root": [0, 0, -0.7 * u],
        "foot_l": lerp3([-0.16, 0.08, -0.32], [-0.16, 0.08, -0.58], smooth(u)),
        "elbow_l": [-0.6, -0.8, 0.3], "elbow_r": [0.6, -0.8, 0.3]})
    keys.append(key(0.86, {"chest": [-28, 0, 0], "root": [0, 0, -0.75]}, ease="out_quad"))
    keys.append(key(1.25, {"chest": [-22, 0, 0], "hips_pos": [0, 0.90, -0.14]}))
    keys.append({"t": 1.62, "pose": "b_stance", "set": {"root": [0, 0, -0.78]}, "ease": "inout_sine"})
    clip("b_combo_3", "boss", keys, chain=1.3, close=[0.20, 0.62, 1.9, 3.5], chain_in=0.14, vuln=[0.88, 1.5],
         track=[[0.0, 0.50, 300], [0.50, 0.66, 90]],
         hits=[{"from": 0.65, "to": 0.75, "blade": "upper", "kind": "normal", "dmg": 34, "posture_block": 30,
                "posture_deflect": 10, "boss_posture": 16, "dir": "high", "final": True}],
         events=[{"t": 0.60, "type": "sfx", "name": "swing_heavy"}, {"t": 0.74, "type": "ground_impact", "blade": "upper"}])

    # ---- Perilous thrust (mikiri counter-able)
    tsh = unit([-0.02, 0.02, -1.0])
    thr = S.copy()
    thr.update({"hips_pos": [0, 0.90, 0.16], "hips": [0, -62, 0], "spine": [-6, -4, 0], "chest": [-4, -8, 0],
                "neck": [2, 52, 0], "head": [0, 20, 0],
                "foot_l": [-0.10, 0.08, -0.42], "foot_l_rot": [0, -30, 0], "foot_r": [0.20, 0.08, 0.34],
                "foot_r_rot": [0, -80, 0], "elbow_l": [-0.3, -1.0, 0.1], "elbow_r": [0.5, -0.8, 0.6]})
    place(thr, [0.32, 1.12, 0.24], tsh, [0, -1, 0], -0.70, -0.25, S["weapon_rot"])
    creep = thr.copy()
    creep.update({"hips_pos": [0, 0.88, 0.20]})
    place(creep, [0.33, 1.10, 0.33], tsh, [0, -1, 0], -0.70, -0.25)
    lunge = thr.copy()
    lunge.update({"hips_pos": [0, 0.92, -0.28], "hips": [0, -45, 0], "chest": [-12, -20, 0], "spine": [-10, -8, 0],
                  "foot_l": [-0.10, 0.08, -0.90], "foot_r": [0.20, 0.08, 0.30], "root": [0, 0, -2.4],
                  "elbow_r": [0.4, -0.9, 0.4]})
    place(lunge, [0.18, 1.22, -0.50], [-0.02, 0.0, -1.0], [0, -1, 0], -0.70, -0.25)
    mid = dict(lunge)
    place(mid := Pose(mid), [0.24, 1.18, -0.05], tsh, [0, -1, 0], -0.70, -0.25)
    keys = [key(0.0, "b_stance"), key(0.45, thr, ease="inout_sine"), key(0.78, creep, ease="inout_sine"),
            key(0.84, dict(mid, root=[0, 0, -0.55], hips_pos=[0, 0.91, 0.0], foot_l=[-0.10, 0.24, -0.52]), ease="in_quad"),
            key(0.92, dict(lunge, root=[0, 0, -1.9]), ease="linear"),
            key(1.00, lunge, ease="out_cubic"),
            key(1.28, dict(lunge, chest=[-10, -18, 0], root=[0, 0, -2.45])),
            {"t": 1.85, "pose": "b_stance", "set": {"root": [0, 0, -2.5]}, "ease": "inout_sine"}]
    clip("b_thrust", "boss", keys, chain=1.6, close=[0.30, 0.78, 3.4, 3.0], vuln=[1.05, 1.75], perilous="thrust",
         track=[[0.0, 0.70, 400], [0.70, 0.84, 80]],
         hits=[{"from": 0.80, "to": 1.00, "blade": "upper", "kind": "thrust", "dmg": 38, "posture_block": 30,
                "posture_deflect": 9, "boss_posture": 14, "dir": "mid", "final": True}],
         events=[{"t": 0.06, "type": "perilous", "kind": "thrust"}, {"t": 0.77, "type": "sfx", "name": "thrust"}])

    # ---- Perilous sweep (jump over it). The whole body spins once (yaw channel).
    coil = S.copy()
    coil.update({"hips_pos": [0, 0.80, 0.06], "hips": [0, 42, 0], "spine": [-10, 16, 0], "chest": [-8, 30, 0],
                 "neck": [8, -40, 0], "head": [4, -26, 0],
                 "foot_l": [-0.34, 0.08, -0.12], "foot_l_rot": [0, 20, 0], "foot_r": [0.30, 0.08, 0.20],
                 "foot_r_rot": [0, -20, 0], "elbow_l": [-0.6, -0.8, 0.5], "elbow_r": [0.4, -1.0, 0.5]})
    sweep_shaft = unit([0.88, 0.40, -0.25])      # lower blade (= -shaft) out to the left, down near the ground
    place(coil, [-0.02, 0.96, 0.10], sweep_shaft, [0, 0, 1], 0.55, 0.10, S["weapon_rot"])
    spin_pose = coil.copy()
    spin_pose.update({"hips_pos": [0, 0.76, 0.0], "hips": [0, 0, 0], "spine": [-14, 0, 0], "chest": [-16, 0, 0],
                      "neck": [12, 0, 0], "head": [4, 0, 0], "ik_l": 0.0, "upper_arm_l": [20, 0, -70],
                      "forearm_l": [20, 0, 0], "foot_l": [-0.34, 0.08, -0.05], "foot_r": [0.34, 0.08, 0.05],
                      "elbow_r": [0.2, -1.0, 0.4]})
    place(spin_pose, [-0.26, 0.82, -0.05], unit([0.95, 0.32, 0.0]), [0, 0, 1], 0.62, 0.10)
    keys = [key(0.0, "b_stance"), key(0.50, coil, ease="inout_sine"),
            key(0.70, dict(coil, hips_pos=[0, 0.78, 0.08], chest=[-8, 34, 0]), ease="linear"),
            key(0.76, dict(spin_pose, yaw=-40.0, root=[0, 0, -0.10]), ease="in_quad"),
            key(0.88, dict(spin_pose, yaw=-170.0, root=[0, 0, -0.30])),
            key(1.00, dict(spin_pose, yaw=-300.0, root=[0, 0, -0.45])),
            key(1.10, dict(spin_pose, yaw=-360.0, root=[0, 0, -0.50], hips_pos=[0, 0.75, 0.0]), ease="out_quad"),
            key(1.30, dict(spin_pose, yaw=-360.0, root=[0, 0, -0.52], hips_pos=[0, 0.78, 0.0])),
            key(1.52, dict(place(S.copy(), [0.12, 1.00, -0.10], [-0.35, 0.50, -0.80], [0, -0.9, -0.45], -0.30, 0.24,
                                 spin_pose["weapon_rot"]), yaw=-360.0, root=[0, 0, -0.54], hips_pos=[0, 0.90, 0.02],
                           chest=[-8, 5, 0]), ease="inout_sine"),
            {"t": 1.80, "pose": "b_stance", "set": {"root": [0, 0, -0.55], "yaw": -360.0}, "ease": "inout_sine"}]
    clip("b_sweep", "boss", keys, chain=1.6, close=[0.20, 0.72, 1.8, 3.2], vuln=[1.12, 1.72], perilous="sweep",
         track=[[0.0, 0.62, 400], [0.62, 0.74, 60]],
         hits=[{"from": 0.74, "to": 1.08, "blade": "lower", "kind": "sweep", "dmg": 40, "posture_block": 0,
                "posture_deflect": 0, "boss_posture": 0, "dir": "low", "final": True}],
         events=[{"t": 0.06, "type": "perilous", "kind": "sweep"}, {"t": 0.72, "type": "sfx", "name": "sweep"}])

    # ---- Whirling Fangs: windmill at the right side (4 hits) + finishing diagonal slash
    wm = S.copy()
    wm.update({"hips_pos": [0, 1.00, 0.02], "hips": [0, -30, 0], "spine": [-6, 0, 0], "chest": [-6, -10, 0],
               "neck": [6, 30, 0], "head": [2, 12, 0], "grip_r": 0.0, "ik_l": 0.0,
               "upper_arm_l": [30, 0, -35], "forearm_l": [50, 0, 0], "elbow_r": [0.8, -0.6, 0.1],
               "foot_l": [-0.18, 0.08, -0.30], "foot_r": [0.22, 0.08, 0.28]})
    base_rot = weapon_rot([0, 1, 0], [0, 0, -1])          # vertical staff, upper edge forward
    # The spin plane leans out to his right so the 3.2 m staff clears the floor at the bottom
    # of each turn; when a blade points straight ahead (the hit frames) the lean changes nothing.
    WR = [0.16, 1.42, -0.46]
    keys = [key(0.0, "b_stance")]
    wm_prev = windmill_rot(40, None)
    keys.append(key(0.34, dict(wm, weapon_pos=WR, weapon_rot=r3(wm_prev)), ease="inout_sine"))
    t0, t1, total = 0.34, 1.54, -760.0
    n = 24
    for i in range(1, n + 1):
        u = i / n
        ang = 40 + total * u
        bob = 0.03 * math.sin(u * math.pi * 8)
        wm_prev = windmill_rot(ang, wm_prev)
        keys.append(key(t0 + (t1 - t0) * u, dict(wm, weapon_pos=[WR[0], WR[1] + bob, WR[2]],
                                                  weapon_rot=r3(wm_prev),
                                                  root=[0, 0, -0.25 - 0.85 * u],
                                                  hips=[0, -30 + 6 * math.sin(u * math.pi * 4), 0],
                                                  foot_l=[-0.18, 0.08, -0.30 - 0.1 * math.sin(u * math.pi * 4) ** 2])))
    keys[1]["set"]["root"] = [0, 0, -0.15]
    # finisher: two-handed diagonal cut, upper blade from high right, through the front, to low left
    fb0 = unit([0.45, 0.60, 0.66])
    axf, af = arc(fb0, [0.05, -0.12, -1.0])
    RF = [0.36, 1.62, 0.12]
    fin_w = S.copy()
    fin_w.update({"hips_pos": [0, 1.02, 0.08], "hips": [0, -35, 0], "chest": [4, -40, 0], "spine": [2, -12, 0],
                  "neck": [0, 40, 0], "head": [0, 16, 0], "root": [0, 0, -1.15],
                  "elbow_r": [0.9, -0.3, 0.5], "elbow_l": [-0.4, -1.0, 0.4]})
    ef = edge_for(axf, fb0)
    place(fin_w, RF, fb0, ef, 0.0, -0.45, keys[-1]["set"]["weapon_rot"])
    pivf = np.array(RF) + np.array([-0.15, -0.2, -0.2])
    swf, _ = hswing(1.84, 1.98, 7, pivf, axf, af + 70, RF, fb0, ef, 0.0, fin_w["weapon_rot"], ease=in_quad,
                    pivot_move=[-0.2, -0.15, -0.45])
    keys.append(key(1.74, fin_w, ease="inout_sine"))
    keys.append(key(1.84, dict(fin_w, chest=[6, -44, 0]), ease="linear"))
    keys += bkeys_from_swing(swf, lambda u: {
        "hips": [0, -35 + 55 * u, 0], "chest": [6 - 20 * u, -44 + 90 * u, 0], "neck": [0, 40 - 55 * u, 0],
        "root": [0, 0, -1.15 - 0.45 * u], "hips_pos": [0, 1.02 - 0.08 * u, 0.08 - 0.2 * u],
        "foot_l": lerp3([-0.18, 0.08, -0.30], [-0.18, 0.08, -0.58], smooth(u)), "elbow_r": [0.6, -0.8, 0.5],
        "elbow_l": [-0.7, -0.7, 0.3]})
    fin_end = S.copy()
    fin_end.update({"chest": [-16, 40, 0], "hips": [0, 15, 0], "root": [0, 0, -1.65], "hips_pos": [0, 0.96, -0.1],
                    "foot_l": [-0.18, 0.08, -0.52], "elbow_l": [-0.7, -0.7, 0.3]})
    place(fin_end, [-0.02, 0.92, -0.35], unit([-0.55, -0.55, -0.62]), [0.0, -0.3, 1.0], 0.0, -0.45, swf[-1][2])
    keys.append(key(2.14, fin_end, ease="out_quad"))
    keys.append({"t": 2.65, "pose": "b_stance", "set": {"root": [0, 0, -1.7]}, "ease": "inout_sine"})

    def whirl_hit(tc, blade):
        return {"from": round(tc - 0.06, 3), "to": round(tc + 0.05, 3), "blade": blade, "kind": "normal", "dmg": 18,
                "posture_block": 16, "posture_deflect": 5, "boss_posture": 7, "dir": "high"}
    # blade passes forward-horizontal when (40 + total*u) == -90 - 180k  ->  u = (130 + 180k)/760
    hits = []
    for k_, blade in ((0, "upper"), (1, "lower"), (2, "upper"), (3, "lower")):
        u = (130 + 180 * k_) / 760.0
        hits.append(whirl_hit(t0 + (t1 - t0) * u, blade))
    hits.append({"from": 1.86, "to": 1.99, "blade": "upper", "kind": "normal", "dmg": 30, "posture_block": 26,
                 "posture_deflect": 9, "boss_posture": 15, "dir": "left", "final": True})
    clip("b_whirl", "boss", keys, chain=2.3, close=[0.20, 1.60, 1.6, 2.4], vuln=[2.2, 2.62], track=[[0.0, 0.3, 360], [0.3, 1.6, 120], [1.6, 1.8, 200]],
         hits=hits, events=[{"t": 0.30, "type": "sfx", "name": "whirl"}, {"t": 1.80, "type": "sfx", "name": "swing_heavy"}])

    # ---- Leaping cleave: gap closer (root motion is scaled by the AI to land on target)
    crouch = S.copy()
    crouch.update({"hips_pos": [0, 0.82, 0.10], "chest": [-14, 0, 0], "spine": [-10, 0, 0], "hips": [0, -15, 0],
                   "foot_l": [-0.18, 0.08, -0.25], "foot_r": [0.22, 0.08, 0.25],
                   "elbow_l": [-0.9, -0.2, 0.4], "elbow_r": [0.9, -0.2, 0.4]})
    place(crouch, [0.14, 1.32, 0.10], unit([0.02, 0.30, 1.0]), [0, 1, -0.3], -0.10, -0.55, S["weapon_rot"])
    air = crouch.copy()
    air.update({"hips_pos": [0, 2.05, -0.10], "chest": [10, 0, 0], "spine": [6, 0, 0], "neck": [-6, 0, 0],
                "foot_l": [-0.16, 1.28, -0.30], "foot_r": [0.20, 1.16, 0.20], "foot_l_rot": [20, 0, 0],
                "foot_r_rot": [50, 0, 0], "root": [0, 0, -2.6]})
    RL = [0.10, 2.98, 0.02]
    place(air, RL, ob, oe, -0.10, -0.55)
    swl, _ = hswing(0.86, 0.96, 7, np.array([0.08, 2.35, -0.05]), ax3, -185, [0.10, 2.62, 0.02], ob, oe, -0.10,
                    air["weapon_rot"], ease=in_quad, pivot_move=[0.0, -0.95, -0.45])
    pre = air.copy()
    pre.update({"hips_pos": [0, 1.62, -0.10], "foot_l": [-0.16, 0.78, -0.40], "foot_r": [0.20, 0.72, 0.20], "root": [0, 0, -4.0]})
    place(pre, [0.10, 2.62, 0.02], ob, oe, -0.10, -0.55)
    keys = [key(0.0, "b_stance"), key(0.32, crouch, ease="inout_sine"),
            key(0.44, dict(crouch, hips_pos=[0, 1.35, 0.0], foot_l=[-0.18, 0.40, -0.30], foot_r=[0.22, 0.30, 0.20],
                           root=[0, 0, -0.5]), ease="out_quad"),
            key(0.66, air, ease="out_sine"),
            key(0.86, pre, ease="in_sine")]
    keys += bkeys_from_swing(swl, lambda u: {
        "hips_pos": [0, 1.62 - 0.80 * u, -0.10 - 0.1 * u], "chest": [10 - 40 * u, 0, 0], "spine": [6 - 20 * u, 0, 0],
        "foot_l": lerp3([-0.16, 0.78, -0.40], [-0.18, 0.08, -0.50], u), "foot_r": lerp3([0.20, 0.72, 0.20], [0.22, 0.08, 0.30], u),
        "foot_l_rot": [0, 0, 0], "foot_r_rot": [0, -30, 0], "root": [0, 0, -4.0 - 0.4 * u],
        "elbow_l": [-0.6, -0.8, 0.3], "elbow_r": [0.6, -0.8, 0.3]})
    keys.append(key(1.10, {"hips_pos": [0, 0.80, -0.16], "chest": [-30, 0, 0]}, ease="out_quad"))
    keys.append(key(1.45, {"chest": [-24, 0, 0], "hips_pos": [0, 0.84, -0.12]}))
    keys.append({"t": 1.85, "pose": "b_stance", "set": {"root": [0, 0, -4.45]}, "ease": "inout_sine"})
    clip("b_leap", "boss", keys, chain=1.6, vuln=[1.0, 1.75], root_scale_window=[0.3, 0.97], nominal_reach=4.4,
         track=[[0.0, 0.40, 360], [0.40, 0.80, 160]],
         hits=[{"from": 0.86, "to": 0.98, "blade": "upper", "kind": "normal", "dmg": 36, "posture_block": 32,
                "posture_deflect": 10, "boss_posture": 16, "dir": "high", "final": True}],
         events=[{"t": 0.34, "type": "sfx", "name": "leap"}, {"t": 0.86, "type": "sfx", "name": "swing_heavy"},
                 {"t": 0.97, "type": "ground_impact", "blade": "upper"}])

    # ---- Fang jabs: quick double thrust (NOT perilous: deflect it, mikiri won't work)
    jb = S.copy()
    jb.update({"hips_pos": [0, 0.98, 0.10], "hips": [0, -45, 0], "chest": [-6, -18, 0], "spine": [-4, -6, 0],
               "neck": [4, 45, 0], "head": [0, 18, 0], "elbow_l": [-0.4, -1.0, 0.3], "elbow_r": [0.6, -0.7, 0.6]})
    place(jb, [0.30, 1.20, 0.18], [-0.03, 0.05, -1.0], [0, -1, 0], -0.70, -0.25, S["weapon_rot"])
    jo = jb.copy()
    jo.update({"hips_pos": [0, 0.97, -0.05], "chest": [-12, -24, 0]})
    place(jo, [0.24, 1.24, -0.42], [-0.03, 0.02, -1.0], [0, -1, 0], -0.70, -0.25)
    keys = [key(0.0, "b_stance"), key(0.24, jb, ease="inout_sine"),
            key(0.33, dict(jo, root=[0, 0, -0.35]), ease="out_cubic"),
            key(0.46, dict(jb, root=[0, 0, -0.45]), ease="inout_sine"),
            key(0.56, dict(jo, root=[0, 0, -0.8]), ease="out_cubic"),
            key(0.70, dict(jo, root=[0, 0, -0.85])),
            {"t": 1.0, "pose": "b_stance", "set": {"root": [0, 0, -0.9]}, "ease": "inout_sine"}]
    clip("b_jab", "boss", keys, chain=0.66, close=[0.04, 0.50, 2.0, 3.8], vuln=[0.75, 1.0], track=[[0.0, 0.22, 400], [0.22, 0.46, 200]],
         hits=[{"from": 0.25, "to": 0.36, "blade": "upper", "kind": "normal", "dmg": 20, "posture_block": 16,
                "posture_deflect": 5, "boss_posture": 8, "dir": "mid"},
               {"from": 0.48, "to": 0.59, "blade": "upper", "kind": "normal", "dmg": 20, "posture_block": 16,
                "posture_deflect": 5, "boss_posture": 9, "dir": "mid"}],
         events=[{"t": 0.24, "type": "sfx", "name": "jab"}, {"t": 0.47, "type": "sfx", "name": "jab"}])

    # ---- Parry + counter: boss deflects the player's attack then punishes (upper blade, right -> left)
    par = guard.copy()
    par.update({"chest": [2, -10, 0]})
    par.w([0.06, 1.48, -0.46], [-1.0, 0.25, -0.1], [0, 1, -0.4], guard["weapon_rot"])
    cs = unit([0.85, 0.10, 0.50])
    axc, ac = arc(cs, [0.0, 0.0, -1.0])
    RC = [0.34, 1.32, 0.06]
    cwind = S.copy()
    cwind.update({"hips_pos": [0, 1.0, 0.05], "hips": [0, -38, 0], "chest": [-4, -30, 0], "spine": [-4, -12, 0],
                  "neck": [4, 38, 0], "elbow_l": [-0.4, -1.0, 0.2], "elbow_r": [0.6, -0.9, 0.5]})
    ec = edge_for(axc, cs)
    place(cwind, RC, cs, ec, 0.15, -0.30, par["weapon_rot"])
    swc, _ = hswing(0.44, 0.57, 7, np.array(RC) - cs * 0.22, axc, ac + 60, RC, cs, ec, 0.15, cwind["weapon_rot"],
                    ease=in_quad, pivot_move=[-0.05, 0, -0.35])
    keys = [key(0.0, "b_guard"), key(0.07, par, ease="out_cubic"), key(0.16, par),
            key(0.38, cwind, ease="inout_sine"), key(0.44, dict(cwind, chest=[-4, -34, 0]))]
    keys += bkeys_from_swing(swc, lambda u: {
        "hips": [0, -38 + 68 * u, 0], "chest": [-4 - 6 * u, -34 + 92 * u, 0], "neck": [4, 38 - 55 * u, 0],
        "root": [0, 0, -0.78 * u], "elbow_r": [0.5, -0.9, 0.4], "elbow_l": [-0.7, -0.7, 0.3]})
    keys.append(key(0.74, {"chest": [-10, 60, 0], "root": [0, 0, -0.84]}, ease="out_quad"))
    keys.append({"t": 1.12, "pose": "b_stance", "set": {"root": [0, 0, -0.86]}, "ease": "inout_sine"})
    clip("b_parry_counter", "boss", keys, chain=0.8, close=[0.16, 0.44, 1.9, 3.8], vuln=[0.8, 1.1], track=[[0.0, 0.36, 400], [0.36, 0.46, 140]],
         hits=[{"from": 0.46, "to": 0.58, "blade": "upper", "kind": "normal", "dmg": 26, "posture_block": 22,
                "posture_deflect": 7, "boss_posture": 12, "dir": "left", "final": True}],
         events=[{"t": 0.0, "type": "boss_parry"}, {"t": 0.42, "type": "sfx", "name": "swing_heavy"}])

    # ---- Backstep hop
    hop = S.copy()
    hop.update({"hips_pos": [0, 1.15, 0.05], "foot_l": [-0.16, 0.30, -0.20], "foot_r": [0.20, 0.25, 0.20],
                "root": [0, 0, 1.4], "chest": [4, 5, 0]})
    landp = S.copy()
    landp.update({"hips_pos": [0, 0.90, 0.06], "root": [0, 0, 2.5], "chest": [-10, 5, 0]})
    clip("b_backstep", "boss", [key(0.0, "b_stance"), key(0.08, dict(S, hips_pos=[0, 0.94, 0.04]), ease="out_quad"),
                                key(0.26, hop, ease="out_quad"), key(0.44, landp, ease="in_quad"),
                                {"t": 0.72, "pose": "b_stance", "set": {"root": [0, 0, 2.6]}, "ease": "inout_sine"}],
         chain=0.5, events=[{"t": 0.05, "type": "sfx", "name": "dodge"}, {"t": 0.44, "type": "sfx", "name": "land"}])

    # ---- Backhand: flat cut from the boss's left to his right (arrives from the player's RIGHT)
    bs_ = unit([-0.85, 0.08, 0.52])
    axb, abk = arc(bs_, [0.0, 0.0, -1.0])
    RB = [0.12, 1.30, 0.08]
    bwind = S.copy()
    bwind.update({"hips_pos": [0, 0.99, 0.04], "hips": [0, 32, 0], "spine": [-4, 14, 0], "chest": [-4, 36, 0],
                  "neck": [4, -36, 0], "head": [0, -16, 0], "foot_l": [-0.18, 0.08, -0.32], "foot_r": [0.22, 0.08, 0.30],
                  "elbow_l": [-0.6, -0.9, 0.3], "elbow_r": [0.4, -1.0, 0.3], "root": [0, 0, 0]})
    eb = edge_for(axb, bs_)
    place(bwind, RB, bs_, eb, -0.30, 0.15, S["weapon_rot"])
    pivb = np.array(RB) + bs_ * 0.2
    swb, _ = hswing(0.36, 0.50, 7, pivb, axb, abk + 80, RB, bs_, eb, -0.30, bwind["weapon_rot"], ease=in_quad,
                    pivot_move=[0.05, 0.0, -0.5])
    keys = [key(0.0, "b_stance"), key(0.26, bwind, ease="inout_sine"),
            key(0.36, dict(bwind, chest=[-4, 40, 0]), ease="linear")]
    keys += bkeys_from_swing(swb, lambda u: {
        "hips": [0, 32 - 64 * u, 0], "chest": [-4 - 6 * u, 40 - 92 * u, 0], "spine": [-4, 14 - 30 * u, 0],
        "neck": [4, -36 + 56 * u, 0], "head": [0, -16 + 26 * u, 0],
        "hips_pos": [0, 0.99 - 0.02 * u, 0.04 - 0.12 * u], "root": [0, 0, -0.85 * u],
        "foot_r": lerp3([0.22, 0.08, 0.30], [0.24, 0.08, 0.02], smooth(u)),
        "elbow_l": [-0.7, -0.7, 0.3], "elbow_r": [0.6, -0.8, 0.4]})
    keys.append(key(0.68, {"chest": [-10, -56, 0], "hips": [0, -30, 0], "root": [0, 0, -0.92]}, ease="out_quad"))
    keys.append({"t": 1.05, "pose": "b_stance", "set": {"root": [0, 0, -0.95]}, "ease": "inout_sine"})
    clip("b_backhand", "boss", keys, chain=0.66, close=[0.08, 0.38, 1.9, 3.8], chain_in=0.12, vuln=[0.76, 1.05],
         track=[[0.0, 0.30, 380], [0.30, 0.40, 120]],
         hits=[{"from": 0.39, "to": 0.52, "blade": "upper", "kind": "normal", "dmg": 26, "posture_block": 22,
                "posture_deflect": 7, "boss_posture": 12, "dir": "right", "final": True}],
         events=[{"t": 0.34, "type": "sfx", "name": "swing_heavy"}])

    # =========================================================== REACTIONS
    rec = S.copy()
    rec.update({"hips_pos": [0, 1.00, 0.16], "chest": [14, 10, 0], "spine": [8, 5, 0], "neck": [-10, 0, 0], "root": [0, 0, 0.35]})
    rec["weapon_pos"] = r3(np.array(S["weapon_pos"]) + np.array([0.10, 0.25, 0.30]))
    rec["weapon_rot"] = r3(np.array(S["weapon_rot"]) + np.array([35, 0, 10]))
    clip("b_recoil", "boss", [key(0.0, "b_stance"), key(0.10, rec, ease="out_cubic"), key(0.30, dict(rec, root=[0, 0, 0.45])),
                              {"t": 0.80, "pose": "b_stance", "set": {"root": [0, 0, 0.5]}, "ease": "inout_sine"}],
         vuln=[0.08, 0.7])

    fl = S.copy()
    fl.update({"hips_pos": [0, 0.99, 0.10], "chest": [10, 14, 6], "spine": [6, 6, 0], "neck": [-12, -10, 0],
               "root": [0, 0, 0.22]})
    fl["weapon_pos"] = r3(np.array(S["weapon_pos"]) + np.array([0.12, -0.05, 0.18]))
    clip("b_flinch", "boss", [key(0.0, "b_stance"), key(0.07, fl, ease="out_cubic"),
                              {"t": 0.48, "pose": "b_stance", "set": {"root": [0, 0, 0.26]}, "ease": "inout_sine"}])

    # Mikiri'd: blade pinned under the player's foot, boss lurches then tears free and stumbles.
    pin = thr.copy()
    pin.update({"hips_pos": [0, 0.84, -0.30], "hips": [0, -45, 0], "chest": [-30, -20, 0], "spine": [-18, -8, 0],
                "neck": [20, 40, 0], "foot_l": [-0.10, 0.08, -0.90], "foot_r": [0.20, 0.08, 0.30], "root": [0, 0, 0.0]})
    pin.w([0.06, 0.68, -0.85], [-0.02, -0.45, -1.0], [0, -1, 0.3], thr["weapon_rot"])
    tear = S.copy()
    tear.update({"hips_pos": [0, 0.98, 0.18], "chest": [16, 12, 0], "spine": [8, 5, 0], "neck": [-12, 0, 0], "root": [0, 0, 0.7]})
    tear["weapon_pos"] = r3(np.array(S["weapon_pos"]) + np.array([0.1, 0.1, 0.35]))
    clip("b_mikiri_react", "boss", [key(0.0, pin), key(0.10, dict(pin, chest=[-34, -22, 0]), ease="out_quad"),
                                    key(0.62, dict(pin, chest=[-26, -18, 0], hips_pos=[0, 0.86, -0.26])),
                                    key(0.82, tear, ease="out_cubic"), key(1.10, dict(tear, root=[0, 0, 0.8])),
                                    {"t": 1.55, "pose": "b_stance", "set": {"root": [0, 0, 0.85]}, "ease": "inout_sine"}],
         vuln=[0.0, 1.45])

    # Posture broken: stagger to one knee (deathblow window), then recover.
    stag = S.copy()
    stag.update({"hips_pos": [0, 1.00, 0.20], "chest": [18, 10, 0], "spine": [10, 5, 0], "neck": [-18, 0, 0], "root": [0, 0, 0.4],
                 "ik_l": 0.0, "upper_arm_l": [-20, 0, -50], "forearm_l": [30, 0, 0]})
    stag.w([0.40, 1.10, 0.25], unit([0.3, 0.5, 0.8]), [0, 1, -0.3], S["weapon_rot"])
    knee = S.copy()
    knee.update({"hips_pos": [0, 0.58, 0.20], "hips": [0, -15, 0], "foot_l": [-0.18, 0.08, -0.30], "foot_r": [0.22, 0.10, 0.62],
                 "foot_r_rot": [-45, -20, 0], "chest": [-30, 5, 0], "spine": [-16, 0, 0], "neck": [10, 0, 0], "head": [18, 0, 0],
                 "root": [0, 0, 0.5], "ik_l": 0.0, "upper_arm_l": [10, 0, -15], "forearm_l": [45, 0, 0], "grip_r": 0.0,
                 "knee_r": [0.3, -0.2, -1.0]})
    knee.w([0.42, 0.62, -0.25], unit([0.05, -0.15, -1.0]), [0, -1, 0], S["weapon_rot"])
    clip("b_posture_break", "boss", [key(0.0, "b_stance"), key(0.12, stag, ease="out_cubic"), key(0.42, dict(stag, root=[0, 0, 0.5])),
                                     key(0.80, knee, ease="in_quad"),
                                     key(1.8, dict(knee, chest=[-28, 5, 0], hips_pos=[0, 0.60, 0.20])),
                                     key(2.7, knee),
                                     {"t": 3.35, "pose": "b_stance", "set": {"root": [0, 0, 0.5]}, "ease": "inout_sine"}],
         events=[{"t": 0.80, "type": "sfx", "name": "kneel"}])

    # Deathblow received (standing variant keeps it simple; lives decide revive/death).
    stab = knee.copy()
    stab.update({"chest": [-8, 5, 0], "spine": [-6, 0, 0], "neck": [-24, 0, 0], "head": [-18, 0, 0], "hips_pos": [0, 0.64, 0.22]})
    slump = knee.copy()
    slump.update({"chest": [-42, 5, 8], "spine": [-26, 0, 0], "neck": [20, 0, 0], "head": [20, 0, 0], "hips_pos": [0, 0.54, 0.22]})
    clip("b_deathblow_react", "boss", [key(0.0, knee), key(0.30, knee), key(0.36, stab, ease="out_cubic"),
                                       key(1.05, stab), key(1.30, slump, ease="inout_sine"), key(2.0, slump)])
    death = slump.copy()
    death.update({"hips_pos": [0, 0.20, -0.30], "hips": [-78, 0, 0], "chest": [0, 0, 0], "spine": [0, 0, 0], "neck": [30, 20, 0],
                  "foot_l": [-0.20, 0.07, 0.80], "foot_r": [0.22, 0.07, 0.85], "foot_l_rot": [-85, 0, 0], "foot_r_rot": [-85, 0, 0],
                  "upper_arm_l": [160, 0, -20]})
    death.w([0.80, 0.08, -0.55], [1.0, 0.02, 0.2], [0, 1, 0], knee["weapon_rot"])
    clip("b_death", "boss", [key(0.0, slump), key(0.7, dict(slump, chest=[-50, 5, 12])), key(1.35, death, ease="in_quad"),
                             key(3.0, death)], events=[{"t": 1.3, "type": "sfx", "name": "body_fall"}])
    rise = S.copy()
    rise.update({"hips_pos": [0, 1.05, 0.0], "chest": [12, 0, 0], "spine": [6, 0, 0], "neck": [-20, 0, 0], "head": [-10, 0, 0]})
    rise.w([0.30, 1.40, -0.10], [0.1, 1.0, 0.1], [0, 0, -1], S["weapon_rot"])
    clip("b_revive", "boss", [key(0.0, slump), key(0.8, knee, ease="inout_sine"), key(1.5, rise, ease="inout_sine"),
                              key(2.3, rise), key(2.8, "b_stance", ease="inout_sine")],
         events=[{"t": 1.5, "type": "roar"}])

    kk = S.copy()
    kk.update({"hips_pos": [0, 1.00, 0.18], "chest": [22, 0, 0], "spine": [10, 0, 0], "neck": [-30, 0, 0], "head": [-20, 0, 0],
               "root": [0, 0, 0.55]})
    kk["weapon_pos"] = r3(np.array(S["weapon_pos"]) + np.array([0.08, 0.20, 0.20]))
    clip("b_kicked", "boss", [key(0.0, "b_stance"), key(0.09, kk, ease="out_cubic"), key(0.40, dict(kk, root=[0, 0, 0.75])),
                              {"t": 0.95, "pose": "b_stance", "set": {"root": [0, 0, 0.8]}, "ease": "inout_sine"}],
         vuln=[0.05, 0.85])

    # Intro flourish: spins the staff and settles into stance.
    ir = windmill_rot(0, None)
    keys = [key(0.0, dict(S, weapon_pos=[0.46, 1.42, -0.30], weapon_rot=r3(ir), grip_r=0.0, ik_l=0.0,
                          upper_arm_l=[20, 0, -30], forearm_l=[40, 0, 0]))]
    for i in range(1, 17):
        u = i / 16
        ir = windmill_rot(-540 * u, ir)
        keys.append(key(0.2 + 1.0 * u, {"weapon_rot": r3(ir)}))
    keys.append(key(1.8, "b_stance", ease="inout_sine"))
    clip("b_intro", "boss", keys, events=[{"t": 0.2, "type": "sfx", "name": "whirl"}])


# Clips where the staff is meant to rest on / dig into the ground.
FLOOR_EXEMPT = {"b_posture_break", "b_death", "b_deathblow_react", "b_revive"}
FLOOR_CLEARANCE = 0.035


def _lowest_blade_point(rig, ch):
    wp = np.array(ch["weapon_pos"], dtype=float)
    pts = rm.blade_points(rig, wp, rm.euler_deg(ch["weapon_rot"]))
    return min(float(p[1]) for poly in pts.values() for p in poly)


def _tilt_off_floor(rig, ch):
    """Weapon pos/rot rotated about the middle of the two grips until nothing is below the
    floor. Rotating (instead of lifting) keeps both hands within reach."""
    wp = np.array(ch["weapon_pos"], dtype=float)
    wb = rm.euler_deg(ch["weapon_rot"])
    shaft, edge = wb[:, 1], -wb[:, 2]
    grip_axis = np.array(rig.weapon["grip_axis"], dtype=float)
    pivot = wp + wb @ (grip_axis * 0.5 * (float(ch["grip_r"][0]) + float(ch["grip_l"][0])))
    horiz = np.cross(shaft, [0.0, 1.0, 0.0])
    if np.linalg.norm(horiz) < 1e-3:
        return None
    best = None
    for sign in (1.0, -1.0):
        for deg in range(3, 91, 3):
            R = axis_angle(horiz, sign * deg)
            cand = dict(ch)
            cand["weapon_pos"] = pivot + R @ (wp - pivot)
            cand["weapon_rot"] = np.array(weapon_rot(R @ shaft, R @ edge, list(ch["weapon_rot"])))
            if _lowest_blade_point(rig, cand) >= FLOOR_CLEARANCE:
                if best is None or deg < best[0]:
                    best = (deg, cand)
                break
    return None if best is None else best[1]


SPLIT_EASE = {"inout_sine": ("in_sine", "out_sine"), "inout_quad": ("in_quad", "out_quad"),
              "inout_cubic": ("in_cubic", "out_cubic"), "in_quad": ("in_quad", "linear"),
              "in_cubic": ("in_cubic", "linear"), "in_sine": ("in_sine", "linear")}


def _bake_key(clip_, key_, i):
    """Replaces key i by its fully resolved channels (so later edits can't change what it inherits)."""
    full = {}
    for ch in rm.ALL:
        val = clip_.values[ch][i]
        full[ch] = round(float(val[0]), 4) if rm.DIM[ch] == 1 else r3(val)
    out = {"t": key_["t"], "set": full}
    if "ease" in key_:
        out["ease"] = key_["ease"]
    return out


def clamp_blades_to_floor(rig_name="boss", passes=24, step=1.0 / 120.0):
    """Keeps the long staff above the floor.

    The clip is sampled finely; at the deepest dip a key is inserted with the staff tilted
    about the hands just enough to clear the stones (the neighbouring keys are untouched,
    so wind-up and strike poses and their hit geometry stay exactly as authored)."""
    rigs_data = rm.load_json("data/rigs.json")
    rig = rm.Rig(rig_name, rigs_data)
    lib = {"poses": POSES}
    inserted = 0
    for name, data in CLIPS.items():
        if data["rig"] != rig_name or name in FLOOR_EXEMPT:
            continue
        keys = data["keys"]
        for _ in range(passes):
            clip_ = rm.Clip(name, data, lib, rig)
            worst = (FLOOR_CLEARANCE, None)
            for t in np.arange(0.0, clip_.length + 1e-6, step):
                low = _lowest_blade_point(rig, clip_.eval(t))
                if low < worst[0] - 1e-4:
                    worst = (low, float(t))
            if worst[1] is None:
                break
            t = worst[1]
            ch = {k: np.array(v, dtype=float) for k, v in clip_.eval(t).items()}
            fix = _tilt_off_floor(rig, ch)
            if fix is None:
                print("  floor clamp: could not clear", name, "at", round(t, 3))
                break
            i1 = next((i for i, k in enumerate(keys) if k["t"] > t + 1e-6), None)
            on_key = next((i for i, k in enumerate(keys) if abs(k["t"] - t) < 1e-6), None)
            if on_key is not None:
                keys[on_key] = _bake_key(clip_, keys[on_key], on_key)
                keys[on_key]["set"]["weapon_pos"] = r3(fix["weapon_pos"])
                keys[on_key]["set"]["weapon_rot"] = r3(fix["weapon_rot"])
                inserted += 1
                continue
            if i1 is None:
                break
            ease = keys[i1].get("ease", "linear")
            e_in, e_out = SPLIT_EASE.get(ease, ("linear", ease))
            keys[i1] = _bake_key(clip_, keys[i1], i1)
            keys[i1]["ease"] = e_out
            new_key = {"t": round(t, 4), "set": {}, "ease": e_in}
            for k_, v_ in fix.items():
                new_key["set"][k_] = round(float(v_[0]), 4) if rm.DIM[k_] == 1 else r3(v_)
            keys.insert(i1, new_key)
            inserted += 1
    return inserted


def main():
    build_player()
    build_boss()
    print("floor clamp: tilted the staff off the floor at", clamp_blades_to_floor(), "boss keys")
    out = {"_doc": "GENERATED by tools/build_animations.py - edit that script and re-run it.",
           "poses": POSES, "clips": CLIPS}
    path = os.path.join(rm.ROOT, "data", "animations.json")
    with open(path, "w") as f:
        json.dump(out, f, indent=1)
    print("wrote", path, len(CLIPS), "clips")


if __name__ == "__main__":
    main()
