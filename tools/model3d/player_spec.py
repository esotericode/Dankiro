"""Shared between tools/build_player_model.py (Blender) and tools/build_models.py (models.json).

Helper bones as in boss_spec.py: the shoulder guards turn halfway between the chest and the
upper arm, and the jacket's skirt panels between the hips and the thigh behind them (the front
panels follow the thigh most, the back ones least). Each panel hinges at the middle of its
top edge, under the obi.
"""
import math

HEM_TOP = 1.035           # the skirt panels hang from here (under the obi) ...
HEM_BOT = 0.805           # ... to here
HEM_N = 2.4               # superellipse exponent of the skirt's cross-section
HEM_WIDTH = 58.0          # degrees of arc per panel
# helper name, thigh it follows, centre angle (degrees; 0 = front, + = the right), follow factor
HEM_PANELS = [("x_hem_fl", "thigh_l", -32.0, 0.6), ("x_hem_fr", "thigh_r", 32.0, 0.6),
              ("x_hem_sl", "thigh_l", -90.0, 0.35), ("x_hem_sr", "thigh_r", 90.0, 0.35),
              ("x_hem_bl", "thigh_l", -148.0, 0.2), ("x_hem_br", "thigh_r", 148.0, 0.2)]


def hem_dims(y):
    """(half-width, depth to the front, depth to the back) of the skirt at height y."""
    k = min(max((HEM_TOP - y) / (HEM_TOP - HEM_BOT), 0.0), 1.0)
    return 0.156 + 0.064 * k ** 1.2, 0.114 + 0.036 * k, 0.118 + 0.040 * k


def hem_point(theta_deg, y):
    a, bf, bb = hem_dims(y)
    s, c = math.sin(math.radians(theta_deg)), math.cos(math.radians(theta_deg))
    x = a * math.copysign(abs(s) ** (2.0 / HEM_N), s)
    b = bf if c > 0 else bb
    return [x, y, -b * math.copysign(abs(c) ** (2.0 / HEM_N), c)]


HELPERS = {
    "x_sode_l": {"a": "chest", "b": "upper_arm_l", "t": 0.5, "pivot": [-0.19, 1.43, 0.0]},
    "x_sode_r": {"a": "chest", "b": "upper_arm_r", "t": 0.5, "pivot": [0.19, 1.43, 0.0]},
}
for _name, _thigh, _theta, _t in HEM_PANELS:
    HELPERS[_name] = {"a": "hips", "b": _thigh, "t": _t, "pivot": [round(v, 4) for v in hem_point(_theta, HEM_TOP)]}

BODY_GLB = "models/player.glb"
KATANA_GLB = "models/player_katana.glb"
SCARF_PNG = "models/player_scarf.png"
BAND_PNG = "models/player_band.png"
