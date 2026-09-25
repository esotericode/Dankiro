"""Shared between tools/build_boss_model.py (Blender) and tools/build_models.py (models.json).

Helper bones: extra skeleton bones for armour that hangs from one joint but should follow
another part of the way (shoulder guards between the chest and the upper arm, skirt panels
between the hips and the thighs). The game drives each one as a virtual joint at `pivot`
(rest position, game space) whose rotation is slerp(rot(a), rot(b), t) and whose position
follows joint `a`.
"""

HELPERS = {
    "x_sode_l": {"a": "chest", "b": "upper_arm_l", "t": 0.55, "pivot": [-0.27, 1.71, 0.0]},
    "x_sode_r": {"a": "chest", "b": "upper_arm_r", "t": 0.55, "pivot": [0.27, 1.71, 0.0]},
    "x_kusa_fl": {"a": "hips", "b": "thigh_l", "t": 0.55, "pivot": [-0.11, 1.07, -0.17]},
    "x_kusa_fr": {"a": "hips", "b": "thigh_r", "t": 0.55, "pivot": [0.11, 1.07, -0.17]},
    "x_kusa_sl": {"a": "hips", "b": "thigh_l", "t": 0.35, "pivot": [-0.22, 1.07, -0.03]},
    "x_kusa_sr": {"a": "hips", "b": "thigh_r", "t": 0.35, "pivot": [0.22, 1.07, -0.03]},
}

BODY_GLB = "models/boss.glb"
STAFF_GLB = "models/boss_staff.glb"
HAIR_PNG = "models/boss_hair.png"
SASH_PNG = "models/boss_sash.png"
