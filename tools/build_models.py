"""Generates data/models.json: the look of the player and the boss.

Each model = materials + holders (grouping nodes) + mesh parts attached to rig joints
(or to the "weapon" node, or to a holder) + spring-chain ribbons + small lights + scenes (the
.glb models from tools/build_player_model.py and tools/build_boss_model.py, restyled by
material name). The game builds them with scripts/rig/model_builder.gd; tools/model_preview.py
renders the mesh parts.

Run: python3 tools/build_models.py
"""
import json
import math
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from model3d import player_spec  # noqa: E402  (no Blender needed)
from model3d.boss_spec import BODY_GLB, HAIR_PNG, HELPERS, SASH_PNG, STAFF_GLB  # noqa: E402

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
# How each kind of chain moves (SpringChain, in physical units): gravity (m/s^2); sway_hz and
# sway_damping, the natural frequency and damping ratio of the pull toward its rest shape; air_drag
# (1/s) across a ribbon's face (strand: across a strand of hair every way round) and edge_drag edge-on
# and along it: real cloth is damped hard face-on and hardly at all edge-on, so it trails and ripples
# instead of whipping; breeze (m/s), the wind at rest; flutter (per m/s of air across it) and
# flutter_hz, the wave that runs down it; max_speed (m/s), a cap on any point's speed relative to its
# anchor. Cloth sways at about 1 Hz; faster reads as buzzing, and a flutter near the sway's own
# frequency resonates into big swings.
SCARF = dict(gravity=5.0, sway_hz=1.0, sway_damping=0.4, air_drag=8.0, edge_drag=1.0, breeze=1.0, flutter=7.5,
             flutter_hz=1.6, max_speed=4.5)
BAND = dict(gravity=6.0, sway_hz=1.4, sway_damping=0.45, air_drag=9.0, edge_drag=1.5, breeze=0.6, flutter=5.0,
            flutter_hz=2.2, max_speed=4.0)
MANE = dict(gravity=7.0, sway_hz=0.9, sway_damping=0.55, air_drag=5.0, edge_drag=0.8, strand=True, breeze=0.5,
            flutter=2.0, flutter_hz=1.6, max_speed=4.0)
SASH = dict(gravity=6.5, sway_hz=0.85, sway_damping=0.45, air_drag=7.0, edge_drag=1.0, breeze=0.5, flutter=5.0,
            flutter_hz=1.6, max_speed=4.5)
TASSEL = dict(gravity=8.0, sway_hz=1.3, sway_damping=0.5, air_drag=6.0, edge_drag=1.0, strand=True, breeze=0.5,
              flutter=2.0, flutter_hz=2.0, max_speed=5.0)


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
    # ---- body: the skinned shinobi built by tools/build_player_model.py (Blender)
    m.mat("player_body", (1.0, 1.0, 1.0), 1.0, 1.0, metallic_specular=0.5, rim=0.25, rim_tint=0.4)
    m.mat("player_face", (1.0, 1.0, 1.0), 1.0, 0.0, rim=0.15, rim_tint=0.3)
    m.scene("skin", "res://" + player_spec.BODY_GLB, helpers=player_spec.HELPERS)

    # ---- katana (tools/build_player_model.py): origin at the tsuba, blade along +Y
    # only partly metallic: a fully metallic blade mirrors the black night sky and reads as a black line
    m.mat("katana_steel", (1.0, 1.0, 1.0), 1.0, 0.3, metallic_specular=0.8, rim=0.3, rim_tint=0.1)
    m.scene("weapon", "res://" + player_spec.KATANA_GLB)

    # healing gourd (shown while healing)
    m.mat("gourd", (0.55, 0.28, 0.12), 0.4, clearcoat=0.5)
    m.holder("gourd", "hand_l", (0, -0.07, -0.03), (180, 0, 0))
    m.part("gourd", lathe([(0, -0.06), (0.035, -0.05), (0.045, -0.025), (0.03, 0.0), (0.02, 0.01), (0.028, 0.03),
                           (0.024, 0.045), (0.01, 0.06), (0.0, 0.065)], 12), "gourd")

    # ribbons: the scarf's two tails from its knot at the back of his neck, the headband's two
    # little specular: the camera's key light sits behind the lens, so a ribbon facing the camera
    # would take a broad white sheen that washes the red out to pink
    m.mat("scarf", (1.0, 1.0, 1.0), 0.9, metallic_specular=0.12, rim=0.25, rim_tint=0.6, double_sided=True,
          texture="res://" + player_spec.SCARF_PNG)
    m.mat("band", (1.0, 1.0, 1.0), 0.9, metallic_specular=0.12, rim=0.3, rim_tint=0.5, double_sided=True,
          texture="res://" + player_spec.BAND_PNG)
    body = [["chest", 0.2, [0, 0.1, 0.02]], ["hips", 0.19, [0, 0, 0]]]
    m.chain("chest", "scarf", (0.04, 0.215, 0.10), (0.1, -0.35, 1.0), side_axis=[1, 0, 0], segments=10, seg_len=0.085,
            width_start=0.085, width_end=0.065, **SCARF, colliders=body)
    m.chain("chest", "scarf", (0.02, 0.21, 0.10), (-0.15, -0.5, 1.0), side_axis=[1, 0, 0], segments=7, seg_len=0.08,
            width_start=0.075, width_end=0.055, **dict(SCARF, sway_hz=1.1, flutter=6.0, flutter_hz=1.4), colliders=body)
    head = [["head", 0.105, [0, 0.12, 0.0]], ["neck", 0.085, [0, 0.0, 0.0]]]
    for sx in (-1.0, 1.0):
        m.chain("head", "band", (0.01 * sx, 0.129, 0.12), (0.25 * sx, -1.0, 0.45), side_axis=[1, 0, 0], segments=4,
                seg_len=0.045, width_start=0.026, width_end=0.021, **BAND, colliders=head)
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
                width_start=0.13, width_end=0.06, **MANE, colliders=body)
    for sx in (-1.0, 1.0):
        m.chain("hips", "crimson", (0.07 * sx, 0.04, 0.17), (0.1 * sx, -1.0, 0.25), segments=9, seg_len=0.09,
                width_start=0.09, width_end=0.07, **SASH, colliders=body)
    for end in (1.0, -1.0):
        m.chain("weapon", "crimson", (0, 0.82 * end, 0.0), (0, -1, 0), side_axis=[0, 0, 1], segments=6, seg_len=0.075,
                width_start=0.045, width_end=0.014, **TASSEL)
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
