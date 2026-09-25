"""Bake materials: a pattern texture (through the "pattern" UV map) shaded with real ambient
occlusion, worn convex edges, a soft top light and ground grime, output as Emission so that
Cycles' EMIT bake writes the final painted colour into the atlas. A MODE value switches the
same material to output (1, roughness, metallic) for the second (ORM) bake.

Hand-painted PS2 textures baked their lighting in the same way; the game adds real lighting on
top, so the baked terms are kept moderate.
"""
import bpy
import numpy as np

from . import blender_io as B
from . import textures as T


def _img(name, arr, non_color=False):
    img = B.numpy_to_image(name, arr)
    if non_color:
        img.colorspace_settings.name = "Non-Color"
    return img


class Graph:
    def __init__(self, mat):
        self.nt = mat.node_tree
        self.nt.nodes.clear()

    def node(self, kind, **inputs):
        n = self.nt.nodes.new(kind)
        for k, v in inputs.items():
            if k.startswith("_"):
                setattr(n, k[1:], v)
            else:
                n.inputs[k].default_value = v
        return n

    def link(self, a, b):
        self.nt.links.new(a, b)

    def math(self, op, a, b=None, c=None, *, clamp=False):
        n = self.nt.nodes.new("ShaderNodeMath")
        n.operation = op
        n.use_clamp = bool(clamp)
        for i, x in enumerate((a, b, c)):
            if x is None:
                continue
            if isinstance(x, (int, float)):
                n.inputs[i].default_value = float(x)
            else:
                self.link(x, n.inputs[i])
        return n.outputs[0]

    def mix_rgb(self, blend, fac, a, b):
        n = self.nt.nodes.new("ShaderNodeMix")
        n.data_type = "RGBA"
        n.blend_type = blend
        for sock, x in ((n.inputs[0], fac), (n.inputs[6], a), (n.inputs[7], b)):
            if isinstance(x, (int, float)):
                sock.default_value = float(x)
            elif isinstance(x, tuple):
                sock.default_value = (*x, 1.0) if len(x) == 3 else x
            else:
                self.link(x, sock)
        return n.outputs[2]


def pattern_material(name, tex, ao=0.75, ao_dist=0.10, edge=0.35, edge_color=(0.55, 0.42, 0.25),
                     edge_sharp=14.0, top=0.18, grime=0.25, tint=(1.0, 1.0, 1.0)):
    """tex: a textures.* result dict. Returns the Blender material (with a MODE value node)."""
    mat = bpy.data.materials.new(name)
    mat.use_nodes = True
    g = Graph(mat)
    out = g.node("ShaderNodeOutputMaterial")
    emit = g.node("ShaderNodeEmission", Strength=1.0)
    g.link(emit.outputs[0], out.inputs["Surface"])
    uvn = g.node("ShaderNodeUVMap", _uv_map="pattern")
    color_img = _img(name + "_pat", tex["color"])
    orm = np.stack([np.ones_like(tex["rough"]), tex["rough"], tex["metal"]], axis=2)
    orm_img = _img(name + "_orm", orm, non_color=True)
    tc = g.node("ShaderNodeTexImage", _image=color_img, _interpolation="Linear")
    to = g.node("ShaderNodeTexImage", _image=orm_img, _interpolation="Linear")
    for t in (tc, to):
        g.link(uvn.outputs["UV"], t.inputs["Vector"])
    base = g.mix_rgb("MULTIPLY", 1.0, tc.outputs["Color"], tuple(tint))
    # ambient occlusion
    aon = g.node("ShaderNodeAmbientOcclusion", Distance=ao_dist, _samples=16, _only_local=False)
    ao_f = g.math("ADD", g.math("MULTIPLY", aon.outputs["AO"], ao), 1.0 - ao)
    shaded = g.mix_rgb("MULTIPLY", 1.0, base, ao_f)
    # soft top light: 1 - top + top * (0.5 + 0.5 n.z)   (Blender Z is up)
    geo = g.node("ShaderNodeNewGeometry")
    sep = g.node("ShaderNodeSeparateXYZ")
    g.link(geo.outputs["Normal"], sep.inputs[0])
    up = g.math("MULTIPLY_ADD", sep.outputs["Z"], 0.5 * top, 1.0 - 0.5 * top)
    shaded = g.mix_rgb("MULTIPLY", 1.0, shaded, up)
    # grime toward the ground (world height, Blender Z)
    sep_p = g.node("ShaderNodeSeparateXYZ")
    g.link(geo.outputs["Position"], sep_p.inputs[0])
    gr = g.math("MULTIPLY_ADD", g.math("SUBTRACT", 1.0, g.math("MULTIPLY", sep_p.outputs["Z"], 1.8, clamp=True)),
                -grime, 1.0)
    shaded = g.mix_rgb("MULTIPLY", 1.0, shaded, gr)
    # worn convex edges (pointiness > 0.5 on convex edges)
    e = g.math("MULTIPLY", g.math("SUBTRACT", geo.outputs["Pointiness"], 0.5), edge_sharp, clamp=True)
    e = g.math("MULTIPLY", e, edge)
    shaded = g.mix_rgb("ADD", e, shaded, tuple(edge_color))
    # MODE: 0 = colour, 1 = ORM
    mode = g.node("ShaderNodeValue")
    mode.name = "MODE"
    mode.outputs[0].default_value = 0.0
    final = g.mix_rgb("MIX", mode.outputs[0], shaded, to.outputs["Color"])
    g.link(final, emit.inputs["Color"])
    mat["tile"] = [1.0, 1.0]
    return mat


def set_mode(materials, value):
    for m in materials:
        node = m.node_tree.nodes.get("MODE")
        if node is not None:
            node.outputs[0].default_value = float(value)


def textured_material(name, color_img, orm_img=None, emission_img=None, emission=(0, 0, 0), alpha=False):
    """Final (exported) material: Principled BSDF with the baked textures."""
    mat = bpy.data.materials.new(name)
    mat.use_nodes = True
    nt = mat.node_tree
    bsdf = nt.nodes["Principled BSDF"]
    tc = nt.nodes.new("ShaderNodeTexImage")
    tc.image = color_img
    nt.links.new(tc.outputs["Color"], bsdf.inputs["Base Color"])
    if alpha:
        nt.links.new(tc.outputs["Alpha"], bsdf.inputs["Alpha"])
        mat.blend_method = "CLIP" if hasattr(mat, "blend_method") else None
    if orm_img is not None:
        to = nt.nodes.new("ShaderNodeTexImage")
        to.image = orm_img
        sep = nt.nodes.new("ShaderNodeSeparateColor")
        nt.links.new(to.outputs["Color"], sep.inputs[0])
        nt.links.new(sep.outputs["Green"], bsdf.inputs["Roughness"])
        nt.links.new(sep.outputs["Blue"], bsdf.inputs["Metallic"])
    if emission_img is not None:
        te = nt.nodes.new("ShaderNodeTexImage")
        te.image = emission_img
        nt.links.new(te.outputs["Color"], bsdf.inputs["Emission Color"])
        bsdf.inputs["Emission Strength"].default_value = 1.0
    elif any(emission):
        bsdf.inputs["Emission Color"].default_value = (*emission, 1.0)
        bsdf.inputs["Emission Strength"].default_value = 1.0
    return mat


def flat_material(name, color, roughness=0.5, metallic=0.0, emission=None):
    mat = bpy.data.materials.new(name)
    mat.use_nodes = True
    bsdf = mat.node_tree.nodes["Principled BSDF"]
    bsdf.inputs["Base Color"].default_value = (*color, 1.0)
    bsdf.inputs["Roughness"].default_value = roughness
    bsdf.inputs["Metallic"].default_value = metallic
    if emission is not None:
        bsdf.inputs["Emission Color"].default_value = (*emission, 1.0)
        bsdf.inputs["Emission Strength"].default_value = 1.0
    return mat
