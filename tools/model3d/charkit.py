"""Pieces shared by the character builders (tools/build_boss_model.py, tools/build_player_model.py):
rule-based skin weights, lame bands, turning a Part into a Blender object with its modifiers,
helper bones, and the spread pose used while baking."""
import math

import bpy
import numpy as np
from mathutils import Matrix

from . import blender_io as B
from . import geo as G
from .geo import smoothstep

SIDES = (("l", -1.0), ("r", 1.0))


class Part:
    """One piece of a character: a Mesh (game space, with bone weights), the key of its
    pattern material, how its UVs map onto the pattern ("tile": metres / tile size; "lame": u
    in metres, v already 0..1; "unit": as is) and the modifiers applied to it."""

    def __init__(self, name, mesh, mat, uv="tile", solidify=0.0, bevel=0.0, subsurf=0, smooth=40.0):
        self.name, self.mesh, self.mat = name, mesh, mat
        self.uv, self.solidify, self.bevel, self.subsurf, self.smooth = uv, solidify, bevel, subsurf, smooth


# ================================================================ weights
def w_chain(v, bones, joints):
    """bones top to bottom; joints [(y, blend)] between consecutive bones (rest pose, Y up)."""
    y = v[:, 1]
    out = {}
    carry = np.ones(len(y))
    for i, b in enumerate(bones):
        t = smoothstep(joints[i][0] + joints[i][1], joints[i][0] - joints[i][1], y) if i < len(joints) else np.zeros(len(y))
        out[b] = out.get(b, 0.0) + carry * (1.0 - t)
        carry = carry * t
    return out


def rigid(bone):
    return lambda v: {bone: np.ones(len(v))}


# ================================================================ shapes
def band(a0, a1, y_bot, y_top, r_bot, r_top, segs=10, center=(0, 0, 0), sz=1.0, mid=0.0):
    """A lame: a narrow revolved band from (r_bot, y_bot) up to (r_top, y_top), UV v normalised
    0 (bottom) .. 1 (top), u in metres. mid bulges the middle outward."""
    ym = 0.5 * (y_bot + y_top)
    prof = [(r_bot, y_bot), (0.5 * (r_bot + r_top) + mid, ym), (r_top, y_top)]
    m = G.revolve(prof, a0, a1, segs, 1.0, sz, center)
    y = m.v[:, 1]
    m.uv[:, 1] = (y - y_bot) / (y_top - y_bot)
    return m


def ring_dims(table, y):
    """Interpolates (a, b_front, b_back) from [(y, a, bf, bb), ...]."""
    t = np.asarray(table, dtype=float)
    return [float(np.interp(y, t[:, 0], t[:, k])) for k in (1, 2, 3)]


# ================================================================ Blender
def part_object(p, mats, table):
    """The Part as a Blender object: pattern UVs scaled by its material's tile, vertex groups
    from its weights, modifiers applied."""
    m = p.mesh
    uv = m.uv.copy()
    if p.mat in table:
        tu, tv = table[p.mat][1]
        if p.uv == "tile":
            uv = uv / np.array([tu, tv])
        elif p.uv == "lame":
            uv[:, 0] = uv[:, 0] / tu
    groups = {k: w for k, w in m.w.items()}
    obj = B.mesh_object(p.name, m.v, m.f, uv, "pattern", groups, p.smooth, mats[p.mat])
    if p.subsurf:
        mod = obj.modifiers.new("sub", "SUBSURF")
        mod.levels = p.subsurf
        mod.render_levels = p.subsurf
    if p.solidify:
        mod = obj.modifiers.new("solid", "SOLIDIFY")
        mod.thickness = p.solidify
        mod.offset = -1.0
        mod.use_even_offset = True
    if p.bevel:
        mod = obj.modifiers.new("bevel", "BEVEL")
        mod.width = p.bevel
        mod.segments = 1
        mod.limit_method = "ANGLE"
        mod.angle_limit = math.radians(50)
    B.apply_modifiers(obj)
    return obj


def add_helper_bones(arm, helpers):
    """Adds the helper bones (see boss_spec.py) to the armature, each parented to its joint a."""
    B.activate(arm)
    bpy.ops.object.mode_set(mode="EDIT")
    eb = arm.data.edit_bones
    for name, h in helpers.items():
        b = eb.new(name)
        p = np.array(h["pivot"], dtype=float)
        b.head = B.to_bl(p)
        b.tail = B.to_bl(p + np.array([0.0, -0.1, 0.0]))
        b.parent = eb[h["a"]]
    bpy.ops.object.mode_set(mode="OBJECT")


def bake_pose(arm, spread, on=True):
    """Arms out and legs apart while baking, so occlusion isn't baked into the flanks.
    spread: [(bone prefix, degrees)], each turned outward about the front axis on both sides."""
    C = Matrix(((1, 0, 0), (0, 0, -1), (0, 1, 0)))
    B.activate(arm)
    bpy.ops.object.mode_set(mode="POSE")
    for pb in arm.pose.bones:
        pb.matrix_basis = Matrix.Identity(4)
    if on:
        bpy.context.view_layer.update()
        for s, sx in SIDES:
            for prefix, deg in spread:
                pb = arm.pose.bones[prefix + s]
                piv = pb.bone.head_local
                Rg = Matrix(G.rot("z", -deg * (-sx)).tolist())       # rotate outward about the front axis
                Rb = (C @ Rg @ C.transposed()).to_4x4()
                M = Matrix.Translation(piv) @ Rb @ Matrix.Translation(-piv) @ pb.bone.matrix_local
                pb.matrix = M
                bpy.context.view_layer.update()
    bpy.ops.object.mode_set(mode="OBJECT")
    bpy.context.view_layer.update()
