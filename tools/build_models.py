"""Generates data/models.json: the look of the player and the boss.

Each model = materials + holders (grouping nodes) + mesh parts attached to rig joints
(or to the "weapon" node, or to a holder) + spring-chain ribbons + small lights.
The game builds them with scripts/rig/model_builder.gd; tools/model_preview.py renders them.

Run: python3 tools/build_models.py && python3 tools/model_preview.py boss
"""
import json
import math
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from model3d.boss_spec import BODY_GLB, HAIR_PNG, HELPERS, SASH_PNG, STAFF_GLB  # noqa: E402  (no Blender needed)

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def r4(v):
    if isinstance(v, (list, tuple)):
        return [r4(x) for x in v]
    if isinstance(v, (str, bool, int)) or v is None:
        return v
    return round(float(v), 4)


class Model:
    def __init__(self):
        self.materials = {}
        self.holders = []
        self.parts = []
        self.chains = []
        self.lights = []
        self.scenes = []

    def mat(self, name, color, roughness=0.8, metallic=0.0, **kw):
        d = {"color": r4(color), "roughness": roughness, "metallic": metallic}
        d.update(kw)
        self.materials[name] = d

    def holder(self, name, parent, pos=(0, 0, 0), rot=(0, 0, 0)):
        self.holders.append({"name": name, "parent": parent, "pos": r4(pos), "rot": r4(rot)})
        return name

    def part(self, parent, mesh, mat, pos=(0, 0, 0), rot=(0, 0, 0), scale=(1, 1, 1), shadow=True):
        p = {"parent": parent, "mesh": {k: r4(v) if k not in ("type", "flat") else v for k, v in mesh.items()},
             "mat": mat, "pos": r4(pos), "rot": r4(rot), "scale": r4(scale)}
        if not shadow:
            p["shadow"] = False
        self.parts.append(p)

    def chain(self, anchor, mat, offset, rest_dir, **kw):
        d = {"anchor": anchor, "mat": mat, "offset": r4(offset), "rest_dir": r4(rest_dir)}
        d.update({k: r4(v) if isinstance(v, (list, tuple, float, int)) else v for k, v in kw.items()})
        self.chains.append(d)

    def light(self, parent, pos, color, energy, rng):
        self.lights.append({"parent": parent, "pos": r4(pos), "color": r4(color), "energy": energy, "range": rng})

    def plate(self, parent, name, r, arc, y0, y1, flare, rot_y, main, trim=None, rows=2, offset=(0, 0, 0), tilt_x=0.0):
        h = self.holder(name, parent, offset, (tilt_x, rot_y, 0))
        self.part(h, shell(r, arc, y0, y1, 0.013, flare, 10, rows), main)
        if trim:
            th = min(0.025, (y1 - y0) * 0.25)
            self.part(h, shell(r + flare + 0.004, arc * 0.98, y0, y0 + th, 0.006, 0.002, 10, 1), trim)

    def scene(self, parent, path, **kw):
        d = {"parent": parent, "path": path}
        d.update(kw)
        self.scenes.append(d)

    def data(self):
        d = {"materials": self.materials, "holders": self.holders, "parts": self.parts,
             "chains": self.chains, "lights": self.lights}
        if self.scenes:
            d["scenes"] = self.scenes
        return d


# ---------------------------------------------------------------- mesh spec helpers
def lathe(profile, segments=20, sx=1.0, sz=1.0, flat=False):
    return {"type": "lathe", "profile": [list(p) for p in profile], "segments": segments, "sx": sx, "sz": sz, "flat": flat}


def limb(length, r0, r1, segments=16, sx=1.0, sz=1.0):
    return {"type": "limb", "length": length, "r0": r0, "r1": r1, "segments": segments, "sx": sx, "sz": sz}


def blade(length, width, thickness, curve, kissaki=0.12, steps=16, tip_width=-1.0):
    return {"type": "blade", "length": length, "width": width, "thickness": thickness, "curve": curve,
            "kissaki": kissaki, "steps": steps, "tip_width": tip_width}


def shell(r, arc_deg, y0, y1, thickness, flare=0.0, segments=10, rows=2):
    return {"type": "shell", "r": r, "arc_deg": arc_deg, "y0": y0, "y1": y1, "thickness": thickness,
            "flare": flare, "segments": segments, "rows": rows}


def horn(p1, p2, base_radius, steps=12, segments=10, squash=1.0):
    return {"type": "horn", "p1": list(p1), "p2": list(p2), "base_radius": base_radius, "steps": steps,
            "segments": segments, "squash": squash}


def box(size):
    return {"type": "box", "size": list(size)}


def sphere(radius, segs=18):
    return {"type": "sphere", "radius": radius, "segs": segs}


def cylinder(r_top, r_bottom, height, segs=16):
    return {"type": "cylinder", "r_top": r_top, "r_bottom": r_bottom, "height": height, "segs": segs}


def torus(inner, outer, rings=24, ring_segments=8):
    return {"type": "torus", "inner": inner, "outer": outer, "rings": rings, "ring_segments": ring_segments}


# =====================================================================================
def player():
    m = Model()
    m.mat("cloth", (0.23, 0.225, 0.235), 0.9, rim=0.45, rim_tint=0.6)
    m.mat("cloth2", (0.40, 0.36, 0.30), 0.88, rim=0.35, rim_tint=0.6)
    m.mat("wrap", (0.62, 0.58, 0.50), 0.95)
    m.mat("leather", (0.23, 0.15, 0.095), 0.6, rim=0.25)
    m.mat("scarf", (0.66, 0.12, 0.06), 0.85, rim=0.4, rim_tint=0.3, double_sided=True)
    m.mat("skin", (0.60, 0.44, 0.35), 0.65, subsurface=0.25)
    m.mat("hair", (0.06, 0.052, 0.05), 0.55, double_sided=True, rim=0.3)
    m.mat("iron", (0.09, 0.085, 0.08), 0.45, 0.85)
    m.mat("gold", (0.78, 0.58, 0.28), 0.32, 1.0)
    m.mat("steel", (0.80, 0.82, 0.86), 0.14, 1.0)
    m.mat("saya", (0.05, 0.045, 0.04), 0.25, clearcoat=0.6)
    m.mat("tsuka", (0.86, 0.84, 0.78), 0.9)
    m.mat("tsuka_wrap", (0.05, 0.05, 0.06), 0.6)
    m.mat("eye", (0.02, 0.02, 0.02), 0.2)
    m.mat("sole", (0.07, 0.065, 0.06), 0.8)
    m.mat("gourd", (0.55, 0.28, 0.12), 0.4, clearcoat=0.5)

    # pelvis, belt, scabbard, hakama flaps
    m.part("hips", lathe([(0.0, -0.13), (0.10, -0.12), (0.15, -0.07), (0.16, 0.0), (0.15, 0.08), (0.0, 0.10)], 18, 1.0, 0.78), "cloth")
    m.part("hips", cylinder(0.158, 0.162, 0.07, 20), "leather", (0, 0.05, 0), scale=(1, 1, 0.8))
    m.part("hips", box((0.05, 0.05, 0.03)), "iron", (0.0, 0.05, -0.13))
    m.holder("saya", "hips", (-0.17, 0.03, 0.02), (-62, 0, 8))
    m.part("saya", limb(0.80, 0.019, 0.016, 10, 1.0, 1.6), "saya", (0, 0.12, 0))
    m.part("saya", cylinder(0.022, 0.022, 0.03, 12), "gold", (0, 0.1, 0))
    m.part("hips", shell(0.16, 110.0, -0.30, 0.02, 0.012, 0.06, 8, 2), "cloth2", rot=(0, 180, 0))
    m.part("hips", shell(0.16, 70.0, -0.24, 0.02, 0.012, 0.05, 6, 2), "cloth2")

    # torso
    m.part("spine", lathe([(0.0, -0.02), (0.13, 0.0), (0.14, 0.10), (0.15, 0.20), (0.0, 0.24)], 18, 1.0, 0.76), "cloth")
    m.part("chest", lathe([(0.0, -0.04), (0.15, -0.02), (0.175, 0.08), (0.19, 0.16), (0.16, 0.22), (0.08, 0.25), (0.0, 0.255)], 20, 1.0, 0.72), "cloth")
    m.part("chest", box((0.035, 0.24, 0.02)), "cloth2", (-0.045, 0.12, -0.128), (8, 0, 22))
    m.part("chest", box((0.035, 0.24, 0.02)), "cloth2", (0.045, 0.12, -0.128), (8, 0, -22))
    m.part("chest", box((0.05, 0.36, 0.012)), "leather", (0.02, 0.10, -0.134), (4, 0, 38))
    m.part("chest", box((0.05, 0.36, 0.012)), "leather", (0.02, 0.10, 0.128), (-4, 0, 38))
    m.part("chest", torus(0.06, 0.115, 20, 8), "scarf", (0, 0.235, 0.005), (8, 0, 0), (1, 1.4, 0.95))

    # head
    m.part("neck", cylinder(0.045, 0.05, 0.11, 12), "skin", (0, 0.04, 0))
    m.part("head", lathe([(0.0, 0.0), (0.06, 0.012), (0.092, 0.06), (0.10, 0.11), (0.092, 0.16), (0.06, 0.20), (0.0, 0.215)], 18, 0.92, 1.0), "skin")
    m.part("head", lathe([(0.0, 0.15), (0.097, 0.158), (0.092, 0.185), (0.066, 0.214), (0.0, 0.226)], 18, 0.95, 1.02), "hair", (0, 0, 0.004))
    m.part("head", shell(0.101, 200.0, 0.06, 0.165, 0.012, -0.012, 12, 3), "hair", (0, 0, 0.006), (0, 180, 0))
    m.part("head", shell(0.098, 150.0, 0.005, 0.105, 0.01, 0.01, 10, 2), "cloth", (0, 0, -0.002))
    m.part("head", sphere(0.011, 8), "eye", (-0.033, 0.122, -0.09))
    m.part("head", sphere(0.011, 8), "eye", (0.033, 0.122, -0.09))
    m.part("head", sphere(0.03, 10), "hair", (0, 0.215, 0.05))

    for s in ("l", "r"):
        yaw = -90 if s == "r" else 90
        m.part("upper_arm_" + s, limb(0.28, 0.062, 0.052, 14), "cloth")
        m.part("upper_arm_" + s, shell(0.075, 150.0, -0.2, 0.04, 0.01, 0.03, 8, 2), "cloth2", rot=(0, yaw, 0))
        m.part("forearm_" + s, limb(0.25, 0.047, 0.037, 14), "wrap")
        m.part("forearm_" + s, shell(0.052, 120.0, -0.22, -0.03, 0.008, 0.0, 8, 2), "leather", rot=(0, yaw, 0))
        m.part("hand_" + s, box((0.07, 0.088, 0.085)), "leather", (0, -0.04, -0.005))
        m.part("thigh_" + s, limb(0.42, 0.09, 0.07, 14, 1.05, 1.0), "cloth")
        m.part("shin_" + s, limb(0.41, 0.064, 0.045, 14), "cloth")
        for k in range(4):
            m.part("shin_" + s, cylinder(0.058 - k * 0.004, 0.06 - k * 0.004, 0.035, 12), "wrap",
                   (0, -0.14 - k * 0.055, 0), (4 if k % 2 else -4, 0, 5 if k % 2 == 0 else -3))
        m.part("foot_" + s, box((0.085, 0.055, 0.21)), "sole", (0, -0.045, -0.055))

    # katana: origin at the tsuba, blade along +Y
    m.part("weapon", blade(0.78, 0.033, 0.0078, 0.024, 0.1, 20), "steel", (0, 0.035, 0))
    m.part("weapon", box((0.034, 0.036, 0.013)), "gold", (0, 0.02, 0))
    m.part("weapon", cylinder(0.042, 0.042, 0.008, 20), "iron")
    m.part("weapon", cylinder(0.0155, 0.017, 0.26, 12), "tsuka", (0, -0.135, 0), scale=(1, 1, 1.25))
    for k in range(6):
        m.part("weapon", cylinder(0.0172, 0.0172, 0.01, 10), "tsuka_wrap", (0, -0.03 - k * 0.04, 0), (0, 45, 0), (1, 1, 1.25))
    m.part("weapon", cylinder(0.018, 0.016, 0.016, 12), "iron", (0, -0.27, 0), scale=(1, 1, 1.25))

    # healing gourd (shown while healing)
    m.holder("gourd", "hand_l", (0, -0.07, -0.03), (180, 0, 0))
    m.part("gourd", lathe([(0, -0.06), (0.035, -0.05), (0.045, -0.025), (0.03, 0.0), (0.02, 0.01), (0.028, 0.03),
                           (0.024, 0.045), (0.01, 0.06), (0.0, 0.065)], 12), "gourd")

    body = [["chest", 0.2, [0, 0.1, 0.02]], ["hips", 0.19, [0, 0, 0]]]
    m.chain("chest", "scarf", (0.03, 0.23, 0.08), (0.1, -0.35, 1.0), side_axis=[1, 0, 0], segments=10, seg_len=0.085,
            width_start=0.11, width_end=0.07, stiffness=0.035, gravity=4.0, wind_strength=1.2, colliders=body)
    m.chain("chest", "scarf", (-0.04, 0.22, 0.085), (-0.15, -0.5, 1.0), side_axis=[1, 0, 0], segments=6, seg_len=0.08,
            width_start=0.08, width_end=0.05, stiffness=0.04, gravity=4.5, wind_strength=1.0, colliders=body)
    m.chain("head", "hair", (0, 0.22, 0.07), (0, -0.6, 1.0), side_axis=[1, 0, 0], segments=5, seg_len=0.045,
            width_start=0.05, width_end=0.012, stiffness=0.12, gravity=6.0, wind_strength=0.4, colliders=body)
    return m


# =====================================================================================
def boss():
    m = Model()
    m.mat("lacquer", (0.085, 0.078, 0.09), 0.22, clearcoat=0.9, clearcoat_roughness=0.08, rim=0.5, rim_tint=0.2)
    m.mat("red", (0.46, 0.05, 0.04), 0.3, clearcoat=0.8, clearcoat_roughness=0.1, rim=0.3)
    m.mat("cloth", (0.17, 0.045, 0.05), 0.9, rim=0.45, rim_tint=0.5)
    m.mat("crimson", (1.0, 1.0, 1.0), 0.8, rim=0.35, rim_tint=0.4, double_sided=True, texture="res://" + SASH_PNG)
    m.mat("gold", (0.86, 0.63, 0.26), 0.28, 1.0)
    m.mat("iron", (0.2, 0.19, 0.18), 0.4, 0.9)
    m.mat("hair", (1.0, 1.0, 1.0), 0.72, double_sided=True, rim=0.45, rim_tint=0.2, alpha_scissor=0.35,
          texture="res://" + HAIR_PNG)
    m.mat("dark", (0.012, 0.01, 0.01), 0.9)
    m.mat("fang", (0.92, 0.9, 0.84), 0.4)
    m.mat("ember", (1.0, 0.36, 0.08), 1.0, unshaded=True, emission=[1.0, 0.36, 0.08], emission_energy=7.0, unique=True)
    m.mat("blade", (1.0, 1.0, 1.0), 1.0, 1.0, metallic_specular=0.75, emission=[1.0, 0.30, 0.06],
          emission_energy=0.35, unique=True)          # textures (hamon, edge glow mask) from the glb

    # ---- body: the skinned PS2-style model built by tools/build_boss_model.py (Blender)
    m.mat("boss_body", (1.0, 1.0, 1.0), 1.0, 1.0, metallic_specular=0.5, rim=0.25, rim_tint=0.35)
    m.mat("boss_mask", (1.0, 1.0, 1.0), 1.0, 1.0, metallic_specular=0.5, rim=0.2, rim_tint=0.3)
    m.scene("skin", "res://" + BODY_GLB, helpers=HELPERS)
    m.mat("jewel", (0.45, 0.04, 0.02), 0.12, 0.0, clearcoat=1.0, emission=[1.0, 0.25, 0.08], emission_energy=0.3)
    m.light("head", (0, 0.07, -0.34), (1.0, 0.36, 0.08), 0.2, 0.7)       # ember light at eye level

    # ---- twin-bladed staff (tools/build_boss_model.py): origin at the shaft centre, upper blade
    # toward +Y, 3.2 m tip to tip. The "blade" material glows along the edge (emission mask).
    m.scene("weapon", "res://" + STAFF_GLB)

    body = [["chest", 0.26, [0, 0.1, 0.02]], ["hips", 0.24, [0, -0.05, 0]]]
    mane = [(0.0, 0.25, 0.10), (-0.06, 0.24, 0.10), (0.06, 0.24, 0.10), (-0.10, 0.20, 0.11), (0.10, 0.20, 0.11)]
    for i, off in enumerate(mane):
        side = [1, 0, 0.4 * (1 if off[0] > 0 else -1 if off[0] < 0 else 0)]
        m.chain("head", "hair", off, (off[0] * 1.5, -1.0, 0.5), side_axis=side, segments=8, seg_len=0.075 - i * 0.003,
                width_start=0.13, width_end=0.06, stiffness=0.045, gravity=6.0, wind_strength=0.8, colliders=body)
    for sx in (-1.0, 1.0):
        m.chain("hips", "crimson", (0.07 * sx, 0.04, 0.17), (0.1 * sx, -1.0, 0.25), segments=9, seg_len=0.09,
                width_start=0.09, width_end=0.07, stiffness=0.03, gravity=6.0, wind_strength=1.0, colliders=body)
    for end in (1.0, -1.0):
        m.chain("weapon", "crimson", (0, 0.82 * end, 0.0), (0, -1, 0), side_axis=[0, 0, 1], segments=6, seg_len=0.075,
                width_start=0.045, width_end=0.014, stiffness=0.02, gravity=7.0, damping=0.9, wind_strength=0.5)
    return m


def main():
    out = {"_doc": "GENERATED by tools/build_models.py - edit that script and re-run it.",
           "player": player().data(), "boss": boss().data()}
    path = os.path.join(ROOT, "data", "models.json")
    with open(path, "w") as f:
        json.dump(out, f, indent=1)
    print("wrote", path, {k: len(v["parts"]) for k, v in out.items() if k != "_doc"})


if __name__ == "__main__":
    main()
