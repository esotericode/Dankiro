"""Render contact sheets of animation clips and report rig problems.

Usage:
  python3 tools/anim_preview.py b_thrust p_attack_1 [--frames 8] [--out DIR]
  python3 tools/anim_preview.py --all --check      # only print IK / reach / spin warnings

Each sheet shows the clip at evenly spaced times in three orthographic views
(side, front, top). Blades are drawn red while a hit window is active. For boss
clips a player-sized hurtbox is drawn at `--target` meters in front.
"""
import argparse
import math
import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import rigmath as rm  # noqa: E402

BONES = [("hips", "spine"), ("spine", "chest"), ("chest", "neck"), ("neck", "head"),
         ("chest", "upper_arm_l"), ("upper_arm_l", "forearm_l"), ("forearm_l", "hand_l"),
         ("chest", "upper_arm_r"), ("upper_arm_r", "forearm_r"), ("forearm_r", "hand_r"),
         ("hips", "thigh_l"), ("thigh_l", "shin_l"), ("shin_l", "foot_l"),
         ("hips", "thigh_r"), ("thigh_r", "shin_r"), ("shin_r", "foot_r")]


def world_frame(clip, ch):
    yaw = math.radians(float(ch["yaw"][0]))
    R = rm.rot_y(yaw)
    root = np.array(ch["root"], dtype=float)
    return R, root


ROOT_CLAMP = {"target": None}


def pose_at(rig, clip, t):
    ch = clip.eval(t)
    tgt = ROOT_CLAMP["target"]
    if tgt is not None and rig.name == "boss":
        ch["root"] = np.array(ch["root"], dtype=float)
        ch["root"][2] = max(ch["root"][2], -(tgt - 1.4))
    chd = {k: (float(v[0]) if rm.DIM[k] == 1 else v) for k, v in ch.items()}
    P, B, WP, WB, err = rm.solve(rig, chd)
    R, root = world_frame(clip, ch)
    Pw = {k: R @ v + root for k, v in P.items()}
    Bw = {k: R @ v for k, v in B.items()}
    WPw, WBw = R @ WP + root, R @ WB
    blades = rm.blade_points(rig, WPw, WBw)
    return Pw, Bw, WPw, WBw, blades, err, chd


def active_hits(clip, t):
    return [h for h in clip.data.get("hits", []) if h["from"] <= t <= h["to"]]


def draw(ax, rig, clip, t, view, target, trail=None):
    Pw, Bw, WPw, WBw, blades, err, chd = pose_at(rig, clip, t)
    ix = {"side": (2, 1), "front": (0, 1), "top": (0, 2), "persp": (0, 1)}[view]
    sgn = {"side": (-1, 1), "front": (1, 1), "top": (1, 1), "persp": (1, 1)}[view]
    VIEW = rm.rot_x(math.radians(12)) @ rm.rot_y(math.radians(-145))

    def pr(p):
        if view == "persp":
            p = VIEW @ p
        return sgn[0] * p[ix[0]], sgn[1] * p[ix[1]]

    col = {"l": "#3070d0", "r": "#d05030"}
    for a, b in BONES:
        side = "r" if a.endswith("_r") or b.endswith("_r") else ("l" if a.endswith("_l") or b.endswith("_l") else "")
        c = col.get(side, "#222")
        pa, pb = pr(Pw[a]), pr(Pw[b])
        ax.plot([pa[0], pb[0]], [pa[1], pb[1]], color=c, lw=2.2, solid_capstyle="round")
    # head
    hc = Pw["head"] + Bw["head"] @ np.array([0, 0.11 if rig.name == "player" else 0.13, 0])
    hp = pr(hc)
    ax.add_patch(__import__("matplotlib").patches.Circle(hp, 0.1 if rig.name == "player" else 0.12, fill=False, color="#222", lw=1.5))
    # nose to show facing
    nose = pr(hc + Bw["head"] @ np.array([0, 0, -0.15]))
    ax.plot([hp[0], nose[0]], [hp[1], nose[1]], color="#222", lw=1)
    # feet (toe direction)
    for s in "lr":
        toe = Pw["foot_" + s] + Bw["foot_" + s] @ np.array([0, -0.06, -0.17])
        a, b = pr(Pw["foot_" + s]), pr(toe)
        ax.plot([a[0], b[0]], [a[1], b[1]], color=col[s], lw=2)
    # weapon shaft
    axis = np.array(rig.weapon["grip_axis"], dtype=float)
    hits = active_hits(clip, t)
    hot = {h.get("blade", "") for h in hits}
    names = list(blades.keys())
    if rig.weapon_name == "twin_staff":
        s0, s1 = WPw + WBw @ (axis * -0.88), WPw + WBw @ (axis * 0.88)
    else:
        s0, s1 = WPw + WBw @ (axis * -0.27), WPw
    a, b = pr(s0), pr(s1)
    ax.plot([a[0], b[0]], [a[1], b[1]], color="#6b4a2a", lw=3)
    for n in names:
        pts = [pr(p) for p in blades[n]]
        c = "#ff1010" if n in hot else "#707a88"
        ax.plot([p[0] for p in pts], [p[1] for p in pts], color=c, lw=2.5 if n in hot else 1.8)
        # edge tick at blade middle
        mid = blades[n][1]
        edge_dir = WBw @ np.array([0, 0, -1.0 if n in ("blade", "upper") else 1.0])
        e = pr(mid + edge_dir * 0.07)
        m = pr(mid)
        ax.plot([m[0], e[0]], [m[1], e[1]], color=c, lw=1)
    # grips
    for s in "lr":
        g = WPw + WBw @ (axis * chd["grip_" + s])
        gp = pr(g)
        ax.plot(gp[0], gp[1], "o", ms=3, color=col[s])
    # target
    if target is not None:
        hb = {"bottom": 0.32, "top": 1.52, "radius": 0.30}
        tp = np.array([0, 0, -target])
        if view == "top":
            ax.add_patch(__import__("matplotlib").patches.Circle(pr(tp), hb["radius"], fill=False, color="#0a0", lw=1))
        else:
            c0 = pr(tp + np.array([0, hb["bottom"], 0]))
            c1 = pr(tp + np.array([0, hb["top"], 0]))
            ax.add_patch(__import__("matplotlib").patches.FancyBboxPatch(
                (c0[0] - hb["radius"], c0[1] - hb["radius"]), 2 * hb["radius"], c1[1] - c0[1] + 2 * hb["radius"],
                boxstyle="round,pad=0,rounding_size=0.3", fill=False, color="#0a0", lw=1))
    if trail:
        for bname, pts in trail.items():
            tp = [pr(p) for p in pts]
            ax.plot([p[0] for p in tp], [p[1] for p in tp], color="#e0a000", lw=0.6, alpha=0.7)
    ax.axhline(0 if view != "top" else 0, color="#aaa", lw=0.5)
    ax.set_aspect("equal")
    return err


def render(clip_name, lib, rigs_data, frames, out_dir, target, times=None):
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    cdata = lib["clips"][clip_name]
    rig = rm.Rig(cdata["rig"], rigs_data)
    clip = rm.Clip(clip_name, cdata, lib, rig)
    if times is None:
        times = list(np.linspace(0, clip.length, frames))
    views = ["side", "persp", "top"]
    fig, axes = plt.subplots(len(views), len(times), figsize=(3.4 * len(times), 3.6 * len(views) + 0.4))
    if len(times) == 1:
        axes = np.array(axes).reshape(len(views), 1)
    tgt = target if cdata["rig"] == "boss" else None
    ROOT_CLAMP["target"] = tgt
    trail = {}
    for tt in np.linspace(0, clip.length, 90):
        _, _, _, _, bl, _, _ = pose_at(rig, clip, tt)
        for bname, pts in bl.items():
            trail.setdefault(bname, []).append(pts[-1])
    for j, t in enumerate(times):
        for i, v in enumerate(views):
            ax = axes[i][j]
            draw(ax, rig, clip, t, v, tgt, trail)
            if v == "top":
                ax.set_xlim(-2.2, 2.2)
                ax.set_ylim(-3.6 if tgt else -2.4, 1.6)
            elif v == "persp":
                ax.set_xlim(-2.0, 2.0)
                ax.set_ylim(-0.6, 2.8 if rig.name == "boss" else 2.3)
            else:
                ax.set_xlim(-1.6, (tgt + 0.6 if tgt else 2.0))
                ax.set_ylim(-0.1, 3.0 if rig.name == "boss" else 2.4)
            ax.tick_params(labelsize=5)
            hits = active_hits(clip, t)
            title = f"{t:.2f}s" + ("  HIT" if hits else "")
            if i == 0:
                ax.set_title(title, fontsize=8, color="red" if hits else "black")
    fig.suptitle(f"{clip_name}   rows: side (forward = right) | 3/4 view from front-right | top (forward = down).  blue = left, red = right", fontsize=9)
    fig.tight_layout()
    os.makedirs(out_dir, exist_ok=True)
    path = os.path.join(out_dir, clip_name + ".png")
    fig.savefig(path, dpi=72)
    plt.close(fig)
    return path


def check(clip_name, lib, rigs_data, steps=60):
    cdata = lib["clips"][clip_name]
    rig = rm.Rig(cdata["rig"], rigs_data)
    clip = rm.Clip(clip_name, cdata, lib, rig)
    worst = {}
    for t in np.linspace(0, clip.length, steps):
        ch = clip.eval(t)
        chd = {k: (float(v[0]) if rm.DIM[k] == 1 else v) for k, v in ch.items()}
        _, _, _, _, err = rm.solve(rig, chd)
        for k, e in err.items():
            if e > worst.get(k, (0, 0))[0]:
                worst[k] = (e, t)
    bad = {k: v for k, v in worst.items() if v[0] > 0.015}
    return bad


def _angle(Ra, Rb):
    c = (np.trace(Ra.T @ Rb) - 1) / 2
    return math.degrees(math.acos(max(-1.0, min(1.0, c))))


def spin_report(clip_name, lib, rigs_data, waste_deg=25.0, whip_speed=18.0):
    """Wasted turns and whips, for boss clips.

    - Between two keys, a rotation interpolated as Euler angles can take the long way round
      (a key whose angles carry the turns of a spin, then his stance in plain angles): the
      weapon then spins in his hands. Reports segments that turn > `waste_deg` more than the
      direct rotation between their keys.
    - After the last hit window (the recovery), a blade tip faster than `whip_speed` m/s
      whips back like another strike."""
    cdata = lib["clips"][clip_name]
    rig = rm.Rig(cdata["rig"], rigs_data)
    clip = rm.Clip(clip_name, cdata, lib, rig)
    out = []
    T = clip.times
    for ch in rm.ROT:
        for k in range(len(T) - 1):
            t0, t1 = T[k], T[k + 1]
            if t1 - t0 < 1e-6:
                continue
            n = max(8, int((t1 - t0) * 480))
            prev, trav = None, 0.0
            for i in range(n + 1):
                R = rm.euler_deg(clip.eval(t0 + (t1 - t0) * i / n)[ch])
                if prev is not None:
                    trav += _angle(prev, R)
                prev = R
            direct = _angle(rm.euler_deg(clip.eval(t0)[ch]), rm.euler_deg(clip.eval(t1)[ch]))
            if trav - direct > waste_deg:
                out.append(f"{ch} turns {trav:.0f} deg at {t0:.2f}-{t1:.2f}s where {direct:.0f} would do")
    hits = cdata.get("hits", [])
    if hits and rig.name == "boss":
        last = max(h["to"] for h in hits)
        prev, fastest = None, (0.0, 0.0)
        dt = 1.0 / 240.0
        for t in np.arange(last, clip.length, dt):
            ch = clip.eval(t)
            _, _, WP, WB, _ = rm.solve(rig, {k: (float(v[0]) if rm.DIM[k] == 1 else v) for k, v in ch.items()})
            pts = rm.blade_points(rig, WP, WB)
            tips = np.array([pts[b][-1] for b in pts])
            if prev is not None:
                v = float(np.max(np.linalg.norm(tips - prev, axis=1))) / dt
                if v > fastest[0]:
                    fastest = (v, float(t))
            prev = tips
        if fastest[0] > whip_speed:
            out.append(f"recovery whip: blade tip {fastest[0]:.1f} m/s at {fastest[1]:.2f}s (after the last hit at {last:.2f}s)")
    return out


def reach_report(clip_name, lib, rigs_data, target_dist):
    """For boss clips: min distance from blade to a player hurtbox placed at target_dist."""
    ROOT_CLAMP["target"] = target_dist
    cdata = lib["clips"][clip_name]
    rig = rm.Rig(cdata["rig"], rigs_data)
    clip = rm.Clip(clip_name, cdata, lib, rig)
    rows = []
    for h in cdata.get("hits", []):
        best = (1e9, 0)
        for t in np.linspace(h["from"], h["to"], 40):
            _, _, _, _, blades, _, _ = pose_at(rig, clip, t)
            pts = blades[h["blade"]]
            hb = rigs_data["rigs"]["player" if rig.name == "boss" else "boss"]["hurtbox"]
            a0 = np.array([0, hb["bottom"], -target_dist])
            a1 = np.array([0, hb["top"], -target_dist])
            for p0, p1 in zip(pts[:-1], pts[1:]):
                d = seg_seg(p0, p1, a0, a1) - hb["radius"]
                if d < best[0]:
                    best = (d, t)
        rows.append((h, best))
    return rows


def seg_seg(p1, q1, p2, q2):
    d1, d2, r = q1 - p1, q2 - p2, p1 - p2
    a, e, f = np.dot(d1, d1), np.dot(d2, d2), np.dot(d2, r)
    c = np.dot(d1, r)
    b = np.dot(d1, d2)
    denom = a * e - b * b
    s = np.clip((b * f - c * e) / denom, 0, 1) if denom > 1e-9 else 0.0
    t = (b * s + f) / e
    if t < 0:
        t, s = 0.0, np.clip(-c / a, 0, 1)
    elif t > 1:
        t, s = 1.0, np.clip((b - c) / a, 0, 1)
    return float(np.linalg.norm((p1 + d1 * s) - (p2 + d2 * t)))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("clips", nargs="*")
    ap.add_argument("--all", action="store_true")
    ap.add_argument("--check", action="store_true")
    ap.add_argument("--frames", type=int, default=8)
    ap.add_argument("--times", type=str, default="")
    ap.add_argument("--target", type=float, default=2.4, help="player distance for boss clips")
    ap.add_argument("--ptarget", type=float, default=1.5, help="boss distance for player clips")
    ap.add_argument("--out", default=os.path.join(rm.ROOT, "tools", "preview_out"))
    args = ap.parse_args()
    lib = rm.load_json("data/animations.json")
    rigs_data = rm.load_json("data/rigs.json")
    names = list(lib["clips"].keys()) if args.all else args.clips
    for n in names:
        bad = check(n, lib, rigs_data)
        if bad:
            print(f"[{n}] IK error: " + ", ".join(f"{k}={v[0]:.3f}m@{v[1]:.2f}s" for k, v in bad.items()))
        if lib["clips"][n]["rig"] == "boss":
            for w in spin_report(n, lib, rigs_data):
                print(f"[{n}] {w}")
        if lib["clips"][n].get("hits") and lib["clips"][n]["hits"][0].get("blade") != "kick":
            tdist = args.target if lib["clips"][n]["rig"] == "boss" else args.ptarget
            for h, (d, t) in reach_report(n, lib, rigs_data, tdist):
                print(f"[{n}] hit {h['from']:.2f}-{h['to']:.2f} {h['blade']}: surface gap {d:.2f}m @ {t:.2f}s (target {tdist}m)")
        if not args.check:
            times = [float(x) for x in args.times.split(",")] if args.times else None
            print(render(n, lib, rigs_data, args.frames, args.out, args.target, times))


if __name__ == "__main__":
    main()
