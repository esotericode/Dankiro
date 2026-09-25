"""Thin helpers around bpy: scene reset, numpy meshes -> objects, skeleton, UV atlas, baking,
glTF export. Everything that takes positions takes *game space* (see __init__)."""
import json
import math
import os

import bmesh
import bpy
import numpy as np

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


# ------------------------------------------------------------------------------ space
def to_bl(p):
    """Game space (x, y, z) -> Blender space (x, -z, y)."""
    return (float(p[0]), -float(p[2]), float(p[1]))


def arr_to_bl(a):
    a = np.asarray(a, dtype=float)
    return np.stack([a[:, 0], -a[:, 2], a[:, 1]], axis=1)


# ------------------------------------------------------------------------------ scene
def reset_scene():
    bpy.ops.wm.read_factory_settings(use_empty=True)
    scn = bpy.context.scene
    scn.render.engine = "CYCLES"
    scn.cycles.device = "CPU"
    scn.cycles.samples = 32
    scn.cycles.use_denoising = False
    return scn


def link(obj):
    bpy.context.scene.collection.objects.link(obj)
    return obj


def activate(obj, others=()):
    for o in bpy.context.view_layer.objects:
        o.select_set(False)
    for o in others:
        o.select_set(True)
    obj.select_set(True)
    bpy.context.view_layer.objects.active = obj


# ------------------------------------------------------------------------------ meshes
def mesh_object(name, verts, faces, uv=None, uv_name="pattern", groups=None, smooth_angle=40.0,
                material=None):
    """Creates a mesh object.
    verts: (N, 3) game space. faces: iterable of vertex-index tuples.
    uv: None, per-vertex (N, 2) or per-loop (sum of face sizes, 2).
    groups: {vertex group name: (N,) weights}; zero weights are skipped.
    smooth_angle: shade smooth with sharp edges above this angle (None = flat)."""
    verts = np.asarray(verts, dtype=float)
    faces = [tuple(int(i) for i in f) for f in faces]
    me = bpy.data.meshes.new(name)
    me.from_pydata(arr_to_bl(verts).tolist(), [], faces)
    me.validate(clean_customdata=False)
    if uv is not None:
        uv = np.asarray(uv, dtype=float)
        layer = me.uv_layers.new(name=uv_name)
        loops_v = np.zeros(len(me.loops), dtype=np.int64)
        me.loops.foreach_get("vertex_index", loops_v)
        if len(uv) == len(verts) and len(uv) != len(me.loops):
            luv = uv[loops_v]
        else:
            luv = uv
        layer.data.foreach_set("uv", luv.reshape(-1).astype(np.float32))
    obj = link(bpy.data.objects.new(name, me))
    if smooth_angle is not None:
        me.shade_smooth()
        me.set_sharp_from_angle(angle=math.radians(smooth_angle))
    if groups:
        for gname, w in groups.items():
            vg = obj.vertex_groups.get(gname) or obj.vertex_groups.new(name=gname)
            w = np.asarray(w, dtype=float)
            for val in np.unique(np.round(w, 4)):
                if val <= 0.0:
                    continue
                idx = np.nonzero(np.abs(np.round(w, 4) - val) < 1e-6)[0].tolist()
                vg.add(idx, float(val), "REPLACE")
    if material is not None:
        me.materials.append(material)
    return obj


def apply_modifiers(obj):
    activate(obj)
    for m in list(obj.modifiers):
        if m.type == "ARMATURE":
            continue
        bpy.ops.object.modifier_apply(modifier=m.name)


def join(objs, name):
    objs = [o for o in objs if o is not None]
    activate(objs[0], objs[1:])
    bpy.ops.object.join()
    obj = bpy.context.view_layer.objects.active
    obj.name = name
    obj.data.name = name
    return obj


def mesh_stats(obj):
    me = obj.data
    tris = sum(len(p.vertices) - 2 for p in me.polygons)
    return {"verts": len(me.vertices), "tris": tris}


# ------------------------------------------------------------------------------ skeleton
def load_rig(rig_name):
    with open(os.path.join(ROOT, "data", "rigs.json")) as f:
        data = json.load(f)
    return data["rigs"][rig_name]


def rest_positions(rig):
    """Joint name -> rest position in model space (game space, feet at y=0)."""
    pos = {}
    for j in rig["joints"]:
        off = np.array(j["offset"], dtype=float)
        if j["parent"] == "":
            pos[j["name"]] = np.array([0.0, rig["hips_height"], 0.0]) + off
        else:
            pos[j["name"]] = pos[j["parent"]] + off
    return pos


def make_armature(rig, name="Skeleton"):
    """Bones at the rig's rest joints (identity rotations: arms and legs straight down)."""
    pos = rest_positions(rig)
    children = {}
    for j in rig["joints"]:
        children.setdefault(j["parent"], []).append(j["name"])
    arm = bpy.data.armatures.new(name)
    obj = link(bpy.data.objects.new(name, arm))
    activate(obj)
    bpy.ops.object.mode_set(mode="EDIT")
    ebs = {}
    for j in rig["joints"]:
        jn = j["name"]
        head = pos[jn]
        kids = children.get(jn, [])
        prefer = {"hips": "spine", "chest": "neck"}.get(jn)
        if prefer in kids:
            tail = pos[prefer]
        elif len(kids) == 1:
            tail = pos[kids[0]]
        elif jn == "head":
            tail = head + np.array([0.0, 0.22, 0.0])
        elif jn.startswith("hand"):
            tail = head + np.array([0.0, -0.09, 0.0])
        elif jn.startswith("foot"):
            tail = head + np.array([0.0, -0.06, -0.16])
        else:
            tail = head + np.array([0.0, 0.1, 0.0])
        eb = arm.edit_bones.new(jn)
        eb.head = to_bl(head)
        eb.tail = to_bl(tail)
        if j["parent"]:
            eb.parent = ebs[j["parent"]]
        ebs[jn] = eb
    bpy.ops.object.mode_set(mode="OBJECT")
    return obj, pos


def skin_to(obj, armature):
    """Parents a mesh (already carrying vertex groups named after bones) to the armature."""
    obj.parent = armature
    mod = obj.modifiers.new("Armature", "ARMATURE")
    mod.object = armature


def normalize_weights(obj):
    activate(obj)
    bpy.ops.object.mode_set(mode="WEIGHT_PAINT")
    bpy.ops.object.vertex_group_normalize_all(lock_active=False)
    bpy.ops.object.mode_set(mode="OBJECT")


# ------------------------------------------------------------------------------ UVs
def smart_uv(obj, uv_name="atlas", angle=60.0, margin=0.004, island_scale=None):
    """Adds a fresh UV map unwrapped with Smart UV Project and packs it.
    island_scale: {material index: scale} to give some parts more texels before packing."""
    me = obj.data
    layer = me.uv_layers.get(uv_name) or me.uv_layers.new(name=uv_name)
    me.uv_layers.active = layer
    activate(obj)
    bpy.ops.object.mode_set(mode="EDIT")
    bpy.ops.mesh.select_all(action="SELECT")
    bpy.ops.uv.smart_project(angle_limit=math.radians(angle), island_margin=margin, area_weight=0.0,
                             correct_aspect=True, scale_to_bounds=False)
    bpy.ops.object.mode_set(mode="OBJECT")
    if island_scale:
        bm = bmesh.new()
        bm.from_mesh(me)
        uvl = bm.loops.layers.uv[uv_name]
        for f in bm.faces:
            s = island_scale.get(f.material_index)
            if s:
                for lp in f.loops:
                    lp[uvl].uv = lp[uvl].uv * s
        bm.to_mesh(me)
        bm.free()
    bpy.ops.object.mode_set(mode="EDIT")
    bpy.ops.mesh.select_all(action="SELECT")
    bpy.ops.uv.select_all(action="SELECT")
    bpy.ops.uv.pack_islands(udim_source="CLOSEST_UDIM", rotate=True, margin=margin, shape_method="CONCAVE")
    bpy.ops.object.mode_set(mode="OBJECT")
    return layer


# ------------------------------------------------------------------------------ baking
def new_image(name, size, alpha=False, color=(0, 0, 0, 1)):
    w, h = (size, size) if isinstance(size, int) else size
    img = bpy.data.images.new(name, width=w, height=h, alpha=alpha, float_buffer=False)
    img.generated_color = color
    return img


def bake_emit(obj, image, uv_name="atlas", margin=8, samples=32):
    """Bakes the Emission output of every material on obj into `image` through `uv_name`.
    Each material must contain an Image Texture node named 'BAKE_TARGET' (added here)."""
    scn = bpy.context.scene
    scn.cycles.samples = samples
    obj.data.uv_layers.active = obj.data.uv_layers[uv_name]
    for slot in obj.material_slots:
        nt = slot.material.node_tree
        node = nt.nodes.get("BAKE_TARGET") or nt.nodes.new("ShaderNodeTexImage")
        node.name = "BAKE_TARGET"
        node.image = image
        nt.nodes.active = node
    activate(obj)
    scn.render.bake.margin = margin
    scn.render.bake.margin_type = "EXTEND"
    scn.render.bake.use_clear = True
    bpy.ops.object.bake(type="EMIT", uv_layer=uv_name)


def save_image(image, path):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    image.filepath_raw = path
    image.file_format = "PNG"
    image.save()


def image_to_numpy(image):
    w, h = image.size
    a = np.zeros(w * h * 4, dtype=np.float32)
    image.pixels.foreach_get(a)
    return a.reshape(h, w, 4)[::-1]          # top row first


def numpy_to_image(name, arr, alpha=True):
    """arr: (H, W, 3|4) float 0..1, top row first."""
    arr = np.asarray(arr, dtype=np.float32)
    h, w = arr.shape[:2]
    if arr.shape[2] == 3:
        arr = np.concatenate([arr, np.ones((h, w, 1), np.float32)], axis=2)
    img = bpy.data.images.new(name, width=w, height=h, alpha=alpha)
    img.pixels.foreach_set(arr[::-1].reshape(-1))
    img.pack()
    return img


# ------------------------------------------------------------------------------ export
def export_glb(objs, path):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    for o in bpy.context.view_layer.objects:
        o.select_set(False)
    for o in objs:
        o.select_set(True)
    bpy.context.view_layer.objects.active = objs[0]
    bpy.ops.export_scene.gltf(filepath=path, export_format="GLB", use_selection=True, export_apply=True,
                              export_skins=True, export_animations=False, export_yup=True,
                              export_materials="EXPORT", export_image_format="AUTO", export_extras=False,
                              export_normals=True, export_tangents=False, export_attributes=False)


# ------------------------------------------------------------------------------ previews
def render_views(path, views, target=(0.0, 1.1, 0.0), dist=4.2, fov=30.0, size=(420, 640), samples=24,
                 background=(0.33, 0.36, 0.45)):
    """Renders the scene from several (azimuth deg, elevation deg[, dist, target]) views into
    one horizontal strip PNG. Azimuth 0 = in front of the character (looking at its face)."""
    import tempfile
    from PIL import Image
    scn = bpy.context.scene
    scn.render.engine = "CYCLES"
    scn.cycles.samples = samples
    scn.cycles.use_denoising = True
    scn.render.resolution_x, scn.render.resolution_y = size
    scn.render.film_transparent = False
    world = bpy.data.worlds.get("PreviewWorld") or bpy.data.worlds.new("PreviewWorld")
    world.use_nodes = True
    world.node_tree.nodes["Background"].inputs[0].default_value = (*background, 1.0)
    world.node_tree.nodes["Background"].inputs[1].default_value = 0.6
    scn.world = world
    cam = bpy.data.objects.get("PreviewCam")
    if cam is None:
        cam = link(bpy.data.objects.new("PreviewCam", bpy.data.cameras.new("PreviewCam")))
    cam.data.angle = math.radians(fov)
    scn.camera = cam
    for lname, energy, az, el in (("Key", 4.0, -40, 45), ("Rim", 3.0, 150, 25), ("Fill", 1.2, 60, 10)):
        lo = bpy.data.objects.get("Preview" + lname)
        if lo is None:
            ld = bpy.data.lights.new("Preview" + lname, "SUN")
            lo = link(bpy.data.objects.new("Preview" + lname, ld))
        lo.data.energy = energy
        lo.rotation_euler = (math.radians(90 - el), 0.0, math.radians(az))
    frames = []
    tmp = tempfile.mkdtemp()
    for i, view in enumerate(views):
        az, el = view[0], view[1]
        d = view[2] if len(view) > 2 else dist
        tg = np.asarray(view[3] if len(view) > 3 else target, dtype=float)
        a, e = math.radians(az), math.radians(el)
        # game space camera position: azimuth 0 = in front (-Z side), looking at the target
        cpos = tg + np.array([math.sin(a) * math.cos(e), math.sin(e), -math.cos(a) * math.cos(e)]) * d
        from mathutils import Vector
        cam.location = to_bl(cpos)
        direction = Vector(to_bl(tg)) - Vector(to_bl(cpos))
        cam.rotation_euler = direction.to_track_quat("-Z", "Y").to_euler()
        fp = os.path.join(tmp, "v%d.png" % i)
        scn.render.filepath = fp
        bpy.ops.render.render(write_still=True)
        frames.append(Image.open(fp).convert("RGB"))
    W = sum(f.size[0] for f in frames)
    strip = Image.new("RGB", (W, frames[0].size[1]))
    x = 0
    for f in frames:
        strip.paste(f, (x, 0))
        x += f.size[0]
    os.makedirs(os.path.dirname(path), exist_ok=True)
    strip.save(path)
    return path
