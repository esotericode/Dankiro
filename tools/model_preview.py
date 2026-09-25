"""Renders data/models.json on the posed rig (painter's algorithm + backface culling).

Usage: python3 tools/model_preview.py boss [--clip b_idle --t 0.0] [--views front,34,side,back]
       [--zoom head] [--out DIR]
Backface culling uses Godot's clockwise-front convention, so wrong winding shows up as holes.
"""
import argparse
import json
import math
import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import meshkit  # noqa: E402
import rigmath as rm  # noqa: E402


def euler_deg(v):
    return rm.euler_deg(v)


def pose_transforms(rig, clip_name, t, lib):
    clip = rm.Clip(clip_name, lib["clips"][clip_name], lib, rig)
    ch = clip.eval(t)
    chd = {k: (float(v[0]) if rm.DIM[k] == 1 else v) for k, v in ch.items()}
    P, B, WP, WB, _ = rm.solve(rig, chd)
    xf = {j: (B[j], P[j]) for j in P}
    xf["weapon"] = (WB, WP)
    return xf


def build_scene(model, xf):
    holders = {}
    for h in model["holders"]:
        pb, pp = xf[h["parent"]] if h["parent"] in xf else holders[h["parent"]]
        lb = euler_deg(h["rot"])
        holders[h["name"]] = (pb @ lb, pp + pb @ np.array(h["pos"], float))
    tris_all, cols, flags = [], [], []
    for part in model["parts"]:
        par = part["parent"]
        pb, pp = xf[par] if par in xf else holders[par]
        v, t = meshkit.build(part["mesh"])
        S = np.diag(part["scale"])
        L = euler_deg(part["rot"]) @ S
        world = (pb @ (L @ v.T)).T + pp + pb @ np.array(part["pos"], float)
        mat = model["materials"][part["mat"]]
        for tri in t:
            tris_all.append(world[tri])
            cols.append(mat)
            flags.append(bool(mat.get("double_sided", False)))
    return tris_all, cols, flags


def shade(mat, n, light_dir, view_dir):
    base = np.array(mat["color"], float)
    if mat.get("unshaded"):
        e = np.array(mat.get("emission", mat["color"]), float)
        return np.clip(e * 1.2, 0, 1)
    ndl = max(0.0, float(np.dot(n, light_dir)))
    amb = 0.28
    metal = mat.get("metallic", 0.0)
    rough = mat.get("roughness", 0.8)
    h = light_dir + view_dir
    h /= np.linalg.norm(h)
    spec = max(0.0, float(np.dot(n, h))) ** (4 + (1 - rough) * 60) * (0.9 if metal > 0.5 else 0.25) * (1 - rough * 0.7)
    rim = (1 - max(0.0, float(np.dot(n, view_dir)))) ** 3 * mat.get("rim", 0.0) * 0.8
    c = base * (amb + 0.85 * ndl) + spec * (base if metal > 0.5 else 1.0) + rim * 0.6
    if "emission" in mat:
        c = c + np.array(mat["emission"], float) * min(1.0, mat.get("emission_energy", 1.0) * 0.15)
    return np.clip(c, 0, 1)


def render(ax, tris, cols, flags, yaw_deg, pitch_deg, center, span):
    from matplotlib.collections import PolyCollection
    R = rm.rot_x(math.radians(pitch_deg)) @ rm.rot_y(math.radians(yaw_deg))
    cam_dir = R.T @ np.array([0, 0, 1.0])       # direction from scene toward the camera (world)
    light = np.array([0.4, 0.8, 0.45])
    light /= np.linalg.norm(light)
    polys, colors, depth = [], [], []
    for tri, mat, ds in zip(tris, cols, flags):
        n_in = np.cross(tri[1] - tri[0], tri[2] - tri[0])
        nl = np.linalg.norm(n_in)
        if nl < 1e-12:
            continue
        n_out = -n_in / nl
        facing = float(np.dot(n_out, cam_dir))
        if facing < 0:
            if not ds:
                continue
            n_out = -n_out
        p = (R @ (tri - center).T).T
        polys.append(p[:, :2])
        depth.append(p[:, 2].mean())
        colors.append(shade(mat, n_out, light, cam_dir))
    order = np.argsort(depth)
    pc = PolyCollection([polys[i] for i in order], facecolors=[colors[i] for i in order], edgecolors="none",
                        antialiased=False)
    ax.add_collection(pc)
    ax.set_xlim(-span, span)
    ax.set_ylim(-span, span)
    ax.set_aspect("equal")
    ax.set_facecolor((0.55, 0.58, 0.62))
    ax.set_xticks([])
    ax.set_yticks([])


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("model")
    ap.add_argument("--clip", default=None)
    ap.add_argument("--t", type=float, default=0.0)
    ap.add_argument("--views", default="front,34,side,back")
    ap.add_argument("--zoom", default="body")
    ap.add_argument("--out", default=os.path.join(rm.ROOT, "tools", "preview_out"))
    args = ap.parse_args()
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    lib = rm.load_json("data/animations.json")
    rigs = rm.load_json("data/rigs.json")
    models = rm.load_json("data/models.json")
    if models[args.model].get("scenes"):
        # Skinned .glb models (the boss) are built and previewed with Blender, and checked in-engine.
        print("%s is a skinned .glb model: run `python3 tools/build_boss_model.py --preview` (Blender renders in "
              "tools/preview_out/) or the Movie Maker art shots model / model_head / model_face / model_combo "
              "in tests/capture.gd." % args.model)
        return
    rig = rm.Rig(args.model, rigs)
    clip = args.clip or ("b_idle" if args.model == "boss" else "p_idle")
    xf = pose_transforms(rig, clip, args.t, lib)
    tris, cols, flags = build_scene(models[args.model], xf)
    views = {"front": (180, 8), "34": (145, 12), "side": (90, 5), "back": (0, 8), "top": (180, 80), "low": (160, -15)}
    names = args.views.split(",")
    if args.zoom == "head":
        center, span = xf["head"][1] + np.array([0, 0.12, 0]), 0.35
    elif args.zoom == "weapon":
        center, span = xf["weapon"][1], 1.6
    else:
        h = 1.1 if args.model == "boss" else 0.95
        center, span = np.array([0.0, h, 0.0]), 1.25 if args.model == "boss" else 1.05
    fig, axes = plt.subplots(1, len(names), figsize=(4.2 * len(names), 4.6))
    if len(names) == 1:
        axes = [axes]
    for ax, n in zip(axes, names):
        yaw, pitch = views[n]
        render(ax, tris, cols, flags, yaw, pitch, center, span)
        ax.set_title(n, fontsize=9)
    fig.suptitle(f"{args.model}  clip={clip} t={args.t}", fontsize=9)
    fig.tight_layout()
    os.makedirs(args.out, exist_ok=True)
    path = os.path.join(args.out, f"model_{args.model}_{args.zoom}.png")
    fig.savefig(path, dpi=80)
    print(path, len(tris), "tris")


if __name__ == "__main__":
    main()
