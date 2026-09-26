class_name Scenery
extends Node3D
## The world round the plaza: the forest, the approach with its torii and shrine, stone lanterns,
## the fence and the mountains. The models are built offline (tools/build_scenery.py, one glb per
## family in models/scenery/); here their materials are swapped for the game's shaders, keyed by
## the material names the build gives them, and the pieces are placed.

const MODEL_DIR := "res://models/scenery/"
const TEX_DIR := "res://textures/scenery/"
const FLOOR_TEX := "res://textures/floor/"
const NOISE := "res://textures/fx/fire_noise.png"

## material name -> [shader, {uniform: value}]. A value naming an image is loaded from
## textures/scenery/ ("floor/..." from textures/floor/, "fx/..." from textures/fx/).
const MATERIALS := {
	"bark_sugi": ["bark", {"bark_albedo": "bark_sugi.jpg", "bark_normal": "bark_sugi_n.jpg",
		"moss_albedo": "floor/moss_albedo.png", "period": Vector2(1.0, 2.0)}],
	"bark_pine": ["bark", {"bark_albedo": "bark_pine.jpg", "bark_normal": "bark_pine_n.jpg",
		"moss_albedo": "floor/moss_albedo.png", "period": Vector2(1.0, 1.5)}],
	"bark_maple": ["bark", {"bark_albedo": "bark_pine.jpg", "bark_normal": "bark_pine_n.jpg",
		"moss_albedo": "floor/moss_albedo.png", "period": Vector2(0.6, 0.9), "tint": Color(0.8, 0.8, 0.85),
		"moss_height": 1.2}],
	"foliage_sugi": ["foliage", {"leaf_tex": "needles.png"}],
	"foliage_pine": ["foliage", {"leaf_tex": "needles.png", "brightness": 0.85,
		"dry": 0.05, "sway_height": 6.0}],
	"foliage_maple": ["foliage", {"leaf_tex": "maple_leaves.png", "dry": 0.0, "brightness": 0.72,
		"leaf_period": 1.2, "backlight": 0.5, "sway_height": 5.0}],
	"foliage_shrub": ["foliage", {"leaf_tex": "needles.png", "brightness": 1.1,
		"leaf_period": 1.0, "dry": 0.0, "sway": 0.0}],
	"leaves_sugi": ["leaves", {"leaf_tex": "spray_sugi.png", "card_size": 1.15}],
	"leaves_pine": ["leaves", {"leaf_tex": "spray_pine.png", "card_size": 1.0, "dry": 0.05, "sway_height": 6.0}],
	"leaves_maple": ["leaves", {"leaf_tex": "spray_maple.png", "card_size": 0.8, "dry": 0.0, "backlight": 0.4,
		"brightness": 0.72,
		"sway_height": 5.0}],
	"leaves_shrub": ["leaves", {"leaf_tex": "spray_shrub.png", "card_size": 0.55, "dry": 0.0, "sway": 0.0}],
	"foliage_fern": ["foliage", {"leaf_tex": "needles.png", "brightness": 0.8, "dry": 0.0, "sway": 0.0}],
	"leaves_fern": ["leaves", {"leaf_tex": "spray_fern.png", "card_size": 0.75, "dry": 0.15, "sway": 0.02,
		"sway_height": 1.0}],
	"rock": ["stone", {"stone_albedo": "floor/stone_albedo.jpg", "stone_normal": "floor/stone_normal.jpg",
		"moss_albedo": "floor/moss_albedo.png", "grime": "grime.png", "base_color": Color(0.3, 0.3, 0.29),
		"moss_amount": 0.9}],
	"stone": ["stone", {"stone_albedo": "floor/stone_albedo.jpg", "stone_normal": "floor/stone_normal.jpg",
		"moss_albedo": "floor/moss_albedo.png", "grime": "grime.png", "base_color": Color(0.36, 0.35, 0.33),
		"moss_amount": 0.45, "moss_low": 0.4}],
	"path_stone": ["stone", {"stone_albedo": "floor/stone_albedo.jpg", "stone_normal": "floor/stone_normal.jpg",
		"moss_albedo": "floor/moss_albedo.png", "grime": "grime.png", "base_color": Color(0.34, 0.33, 0.31),
		"moss_amount": 0.25, "streaks": 0.0}],
	"lantern_stone": ["stone", {"stone_albedo": "floor/stone_albedo.jpg", "stone_normal": "floor/stone_normal.jpg",
		"moss_albedo": "floor/moss_albedo.png", "grime": "grime.png", "base_color": Color(0.37, 0.36, 0.345),
		"period": 1.2, "moss_amount": 0.7, "streaks": 0.7, "moss_low": 0.5, "moss_low_height": 0.35}],
	"fence_stone": ["stone", {"stone_albedo": "floor/stone_albedo.jpg", "stone_normal": "floor/stone_normal.jpg",
		"moss_albedo": "floor/moss_albedo.png", "grime": "grime.png", "base_color": Color(0.38, 0.37, 0.35),
		"period": 1.2, "moss_amount": 0.6, "streaks": 0.6, "moss_low": 0.5, "moss_low_height": 0.3}],
	"lacquer_red": ["painted", {"grime": "grime.png", "color": Color(0.6, 0.11, 0.05), "under_color": Color(0.09, 0.05, 0.04),
		"fade_color": Color(1.12, 1.3, 1.35), "fade": 0.35, "wear": 0.3, "dirt": 0.45, "roughness": 0.42, "coat": 0.35}],
	"lacquer_black": ["painted", {"grime": "grime.png", "color": Color(0.035, 0.032, 0.032),
		"under_color": Color(0.14, 0.1, 0.08), "fade": 0.0, "wear": 0.2, "dirt": 0.3, "roughness": 0.35, "coat": 0.4}],
	"wood": ["painted", {"grime": "grime.png", "albedo_tex": "wood.jpg", "normal_tex": "wood_n.jpg", "textured": true,
		"use_normal": true, "color": Color(0.9, 0.88, 0.86), "wear": 0.0, "fade": 0.0, "dirt": 0.35, "roughness": 0.85,
		"specular": 0.3}],
	"rafters": ["painted", {"grime": "grime.png", "albedo_tex": "wood.jpg", "normal_tex": "wood_n.jpg", "textured": true,
		"use_normal": true, "period": Vector2(0.5, 1.0), "color": Color(0.55, 0.5, 0.48), "wear": 0.0, "fade": 0.0,
		"dirt": 0.2, "roughness": 0.9, "specular": 0.25}],
	"plaster": ["painted", {"grime": "grime.png", "color": Color(0.74, 0.72, 0.66), "under_color": Color(0.42, 0.36, 0.3),
		"fade": 0.0, "wear": 0.15, "dirt": 0.7, "roughness": 0.92, "specular": 0.3}],
	"rope": ["painted", {"grime": "grime.png", "color": Color(0.6, 0.52, 0.34), "wear": 0.0, "fade": 0.0, "dirt": 0.35,
		"roughness": 0.95, "specular": 0.2, "grime_period": 0.5}],
	"shide": ["painted", {"grime": "grime.png", "color": Color(0.88, 0.87, 0.83), "wear": 0.0, "fade": 0.0, "dirt": 0.2,
		"roughness": 0.8, "specular": 0.3}],
	"copper": ["roof", {"copper_albedo": "copper.jpg", "copper_normal": "copper_n.jpg", "grime": "grime.png"}],
	"shoji": ["shoji", {"panel": Vector2(1.5, 1.94)}],
	"ranma": ["shoji", {"panel": Vector2(1.5, 0.54), "cell": Vector2(0.125, 0.135), "glow": 1.3}],
	"lantern_paper": ["shoji", {"lattice": false, "glow": 2.4, "flicker": 0.14, "paper_color": Color(0.8, 0.7, 0.55)}],
	"plaque": ["plaque", {"plaque_tex": "plaque.png"}],
	"ishigaki": ["masonry", {"albedo_tex": "ishigaki.png", "normal_tex": "ishigaki_n.jpg",
		"moss_albedo": "floor/moss_albedo.png", "period": 3.0, "moss_amount": 0.6}],
	"terrain": ["terrain", {"stone_albedo": "floor/stone_albedo.jpg", "stone_normal": "floor/stone_normal.jpg"}],
	"range_far": ["mountains", {"noise_tex": "fx/fire_noise.png", "haze": 0.7, "snow_line": 215.0, "tree_line": 40.0,
		"snow_color": Color(0.56, 0.59, 0.68), "_priority": -3}],
	"range_mid": ["mountains", {"noise_tex": "fx/fire_noise.png", "haze": 0.5, "snow_line": 1000.0, "_priority": -2}],
	"range_near": ["mountains", {"noise_tex": "fx/fire_noise.png", "haze": 0.22, "snow_line": 1000.0, "_priority": -1}],
	"gravel": ["masonry", {"albedo_tex": "gravel.jpg", "normal_tex": "gravel_n.jpg", "moss_albedo": "floor/moss_albedo.png",
		"period": 0.8, "world_xz": true, "moss_amount": 0.0, "damp_height": -10.0, "tint": Color(0.62, 0.62, 0.62),
		"normal_depth": 0.6}],
}

## Where the approach runs: the torii, the steps and the shrine's court (see tools/build_scenery.py).
const TORII_Z := -24.6
const COURT := Rect2(-16.0, -61.0, 32.0, 29.5)   ## x, z of the terrace's footprint, with a margin
const LANTERN_LIGHT := Color(1.0, 0.58, 0.28)
## The summit's edge (tools/build_scenery.py edge_radius()): east of the plaza the ground drops
## away a few metres past the fence and the view opens over the cloud sea.
const VISTA_AT := 90.0
const VISTA_HALF := 42.0
const EDGE_NEAR := 22.0
const EDGE_FAR := 125.0
const CLOUD_Y := -30.0
const SHADOW_REACH := 58.0   ## trees farther out than this can't shadow anything the moon's shadow map covers

var radius := 15.6
var _assets := {}      ## asset name -> Mesh
var _materials := {}   ## material name -> Material
var _textures := {}
var _rng := RandomNumberGenerator.new()
var _taken: Array = []   ## [Vector2 position, clearance] of everything planted, so nothing overlaps
var _lights: Array = []  ## [OmniLight3D, base energy, seed]: lantern flames, flickering
var _t := 0.0


func build(arena_radius: float) -> void:
	radius = arena_radius
	for family in ["trees", "torii", "props", "approach", "backdrop"]:
		_load(family)
	_build_backdrop()
	_build_approach()
	_build_fence()
	_build_lanterns()
	_build_forest()


func _process(delta: float) -> void:
	_t += delta
	for l in _lights:
		var light: OmniLight3D = l[0]
		var sd: float = l[2]
		var f := 0.86 + 0.08 * sin(_t * 7.3 + sd) + 0.06 * sin(_t * 17.1 + sd * 2.3) + 0.03 * sin(_t * 31.0 + sd * 0.7)
		light.light_energy = float(l[1]) * f


# ------------------------------------------------------------------------ loading
func _load(family: String) -> void:
	var scene: Node = (load(MODEL_DIR + family + ".glb") as PackedScene).instantiate()
	for node in scene.find_children("*", "MeshInstance3D", true, false):
		var mesh := (node as MeshInstance3D).mesh as ArrayMesh
		for i in mesh.get_surface_count():
			var m := mesh.surface_get_material(i)
			mesh.surface_set_material(i, _material(m.resource_name if m != null else ""))
		_assets[String(node.name)] = mesh
	scene.free()


func _material(mname: String) -> Material:
	if _materials.has(mname):
		return _materials[mname]
	var spec: Array = MATERIALS.get(mname, [])
	var mat: Material
	if spec.is_empty():
		push_warning("Scenery: no material for '%s'" % mname)
		mat = StandardMaterial3D.new()
	else:
		var sm := ShaderMaterial.new()
		sm.resource_name = mname     # the meshes are shared: a scene reload maps them back by name
		sm.shader = load("res://shaders/%s.gdshader" % spec[0])
		var params: Dictionary = spec[1]
		for key in params:
			var v = params[key]
			if key == "_priority":
				sm.render_priority = int(v)
				continue
			if v is String:
				v = _texture(v)
			sm.set_shader_parameter(key, v)
		mat = sm
	_materials[mname] = mat
	return mat


func _texture(path: String) -> Texture2D:
	if not _textures.has(path):
		var full := TEX_DIR + path
		if path.begins_with("floor/"):
			full = FLOOR_TEX + path.trim_prefix("floor/")
		elif path.begins_with("fx/"):
			full = "res://textures/fx/" + path.trim_prefix("fx/")
		_textures[path] = load(full)
	return _textures[path]


func _place(asset: String, pos: Vector3, yaw := 0.0, s := 1.0, params := {}) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = _assets[asset]
	mi.position = pos
	mi.rotation.y = yaw
	mi.scale = Vector3.ONE * s
	add_child(mi)
	for k in params:
		mi.set_instance_shader_parameter(k, params[k])
	return mi


# ------------------------------------------------------------------------ land and sky
## Distance from the plaza's centre to where the summit falls away, at angle a (radians, 0 = +z).
func edge_radius(a: float) -> float:
	var d := fposmod(rad_to_deg(a) - VISTA_AT + 180.0, 360.0) - 180.0
	var t := clampf(absf(d) / VISTA_HALF, 0.0, 1.0)
	var w := 0.5 + 0.5 * cos(PI * t)
	var wob := 1.6 * sin(a * 7.0 + 1.3) + 0.9 * sin(a * 13.0 + 0.4)
	return EDGE_FAR + (EDGE_NEAR - EDGE_FAR) * pow(w, 0.6) + wob * w


## The summit's ground, the three rings of mountains, and the sea of cloud they rise out of.
func _build_backdrop() -> void:
	for n in ["terrain", "hills", "mountains_mid", "mountains_far"]:
		var mi := _place(n, Vector3.ZERO)
		if n != "terrain":
			mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var sea := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(5000.0, 5000.0)
	sea.mesh = plane
	sea.position = Vector3(0.0, CLOUD_Y, 0.0)
	var mat := ShaderMaterial.new()
	mat.shader = load("res://shaders/cloud_sea.gdshader")
	mat.set_shader_parameter("noise_tex", _texture("fx/fire_noise.png"))
	sea.material_override = mat
	sea.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(sea)


# ------------------------------------------------------------------------ built things
## The torii astride the approach, the path of slabs up to a flight of steps, and the shrine hall
## on its walled court (all modelled in place, in world coordinates, except the torii).
func _build_approach() -> void:
	_place("torii", Vector3(0.0, 0.0, TORII_Z))
	for n in ["path", "terrace", "shrine"]:
		_place(n, Vector3.ZERO)
	# lamplight inside the hall, spilling out through the lattice doors
	var l := OmniLight3D.new()
	l.light_color = Color(1.0, 0.6, 0.3)
	l.light_energy = 2.2
	l.omni_range = 11.0
	l.omni_attenuation = 1.2
	l.shadow_enabled = false
	l.position = Vector3(0.0, 4.4, -39.6)
	add_child(l)
	_lights.append([l, 2.2, 3.3])


## Granite posts round the plaza's rim with two lacquered rails between each pair.
## (The wall that keeps the fight in is Arena._build_boundary; this is only what you see.)
func _build_fence() -> void:
	var segs := 36
	var r := radius - 0.2
	var chord := 2.0 * r * sin(PI / segs)
	for i in segs:
		var a := TAU * float(i) / float(segs)
		_place("fence_post", Vector3(sin(a) * r, 0.0, cos(a) * r), a, 1.0, {"seed": _rng.randf()})
		var a2 := TAU * (float(i) + 0.5) / float(segs)
		var rm := r * cos(PI / segs)
		for y in [0.45, 0.85]:
			var rail := _place("fence_rail", Vector3(sin(a2) * rm, y, cos(a2) * rm), a2)
			rail.scale = Vector3(chord - 0.2, 1.0, 1.0)


## Stone lanterns: eight round the plaza, pairs along the approach and before the hall.
func _build_lanterns() -> void:
	var n := 8
	for i in n:
		var a := TAU * (float(i) + 0.5) / float(n)
		_lantern(Vector3(sin(a) * (radius - 1.1), 0.0, cos(a) * (radius - 1.1)), a, 2.8, 9.0, i % 4 == 0)
	for p in [Vector2(2.35, -19.4), Vector2(3.5, -27.9), Vector2(4.3, -35.8)]:
		for sx in [-1.0, 1.0]:
			var y := 2.4 if p.y < -33.0 else 0.0
			_lantern(Vector3(p.x * sx, y, p.y), PI, 1.6, 6.5, false, 0.25)


func _lantern(pos: Vector3, yaw: float, energy: float, reach: float, shadow: bool, fog := 0.6) -> void:
	var sd := _rng.randf()
	_place("lantern", pos, yaw, 1.0, {"seed": sd})
	var paper := _place("lantern_paper", pos, yaw, 1.0, {"seed": sd})
	paper.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var l := OmniLight3D.new()
	l.light_color = LANTERN_LIGHT
	l.light_energy = energy
	l.omni_range = reach
	l.omni_attenuation = 1.3
	l.light_volumetric_fog_energy = fog
	l.shadow_enabled = shadow
	l.position = pos + Vector3(0.0, 1.335, 0.0)
	add_child(l)
	_lights.append([l, energy, sd * 10.0])


# ------------------------------------------------------------------------ forest
## Whether a spot is kept clear: the approach to the torii and the shrine, straight north.
func _clear(p: Vector2, margin: float) -> bool:
	if p.y < -radius + 2.0 and p.y > COURT.position.y and absf(p.x) < 7.0 + margin:
		return true     # the approach
	return Rect2(COURT.position - Vector2.ONE * margin, COURT.size + Vector2.ONE * margin * 2.0).has_point(p)


func _free_spot(p: Vector2, clearance: float) -> bool:
	for t in _taken:
		if p.distance_to(t[0]) < clearance + float(t[1]):
			return false
	return true


func _plant(asset: String, p: Vector2, clearance: float, s := 1.0, tint := Color.WHITE) -> void:
	_taken.append([p, clearance])
	var params := {"seed": _rng.randf(), "tint": tint}
	if asset.begins_with("sugi") or asset.begins_with("pine") or asset.begins_with("maple"):
		params["tree_tint"] = tint
	var mi := _place(asset, Vector3(p.x, -0.05, p.y), _rng.randf() * TAU, s, params)
	if p.length() > SHADOW_REACH:
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF


## Scatters `count` of the assets (picked by weight) between radii r0 and r1 from the plaza's
## centre, keeping `clearance` metres between trunks.
func _scatter(count: int, r0: float, r1: float, choices: Dictionary, clearance: float, s0 := 0.85, s1 := 1.15,
		open_vista := true) -> void:
	var names: Array = choices.keys()
	var total := 0.0
	for k in names:
		total += float(choices[k])
	var tries := 0
	var planted := 0
	while planted < count and tries < count * 40:
		tries += 1
		var a := _rng.randf() * TAU
		var d := sqrt(lerpf(r0 * r0, r1 * r1, _rng.randf()))
		var p := Vector2(sin(a) * d, cos(a) * d)
		if _clear(p, clearance) or not _free_spot(p, clearance) or d > edge_radius(a) - clearance - 1.0:
			continue
		if open_vista and absf(fposmod(rad_to_deg(a) - VISTA_AT + 180.0, 360.0) - 180.0) < VISTA_HALF * 0.8:
			continue    # nothing tall in front of the view east
		var pick := _rng.randf() * total
		var asset: String = names[0]
		for k in names:
			pick -= float(choices[k])
			if pick <= 0.0:
				asset = k
				break
		var tone := _rng.randf_range(0.85, 1.1)
		_plant(asset, p, clearance, _rng.randf_range(s0, s1), Color(tone, tone, tone))
		planted += 1


func _build_forest() -> void:
	_rng.seed = 20260926
	# the old sacred cedar beside the steps, roped with a shimenawa
	_plant("sugi_sacred", Vector2(-10.5, -29.0), 4.0)
	# the near ring: maples and pines by the fence, shrubs and rocks between
	_scatter(4, radius + 3.0, radius + 7.0, {"maple_a": 1.0, "maple_b": 1.0}, 3.2)
	_scatter(5, radius + 8.0, radius + 20.0, {"maple_a": 1.0, "maple_b": 1.0}, 3.2, 0.9, 1.25)
	_scatter(4, radius + 3.0, radius + 9.0, {"pine_a": 1.0, "pine_b": 1.0}, 3.0)
	_scatter(4, radius + 9.0, radius + 24.0, {"pine_a": 1.0, "pine_b": 1.0}, 3.0, 1.0, 1.3)
	# the cedar wood
	_scatter(34, radius + 7.0, radius + 30.0, {"sugi_a": 1.0, "sugi_b": 1.0, "sugi_c": 1.0}, 3.4)
	_scatter(22, radius + 28.0, radius + 55.0, {"sugi_a": 1.0, "sugi_b": 1.0, "sugi_c": 1.0}, 4.0, 1.0, 1.3)
	# under the trees
	_scatter(22, radius + 2.2, radius + 14.0, {"shrub_a": 1.0, "shrub_b": 1.0}, 1.2, 0.8, 1.4, false)
	_scatter(14, radius + 2.2, radius + 20.0, {"rock_a": 1.0, "rock_b": 1.0}, 1.4, 0.6, 1.6, false)
	_scatter(46, radius + 1.2, radius + 16.0, {"fern_a": 1.0, "fern_b": 1.0}, 0.9, 0.8, 1.3, false)
	_build_cliff_edge()


## Rocks along the lip of the drop, and a pair of pines clinging to it.
func _build_cliff_edge() -> void:
	var a := deg_to_rad(VISTA_AT - VISTA_HALF * 0.8)
	var a1 := deg_to_rad(VISTA_AT + VISTA_HALF * 0.8)
	while a < a1:
		var e := edge_radius(a)
		var d := e - _rng.randf_range(0.2, 1.4)
		var p := Vector2(sin(a) * d, cos(a) * d)
		if _free_spot(p, 0.6):
			_taken.append([p, 0.6])
			_place("rock_a" if _rng.randf() < 0.5 else "rock_b", Vector3(p.x, -0.25, p.y), _rng.randf() * TAU,
				_rng.randf_range(1.0, 2.6), {"seed": _rng.randf()})
		a += _rng.randf_range(2.4, 4.5) / e
	for deg in [VISTA_AT - 19.0, VISTA_AT + 24.0]:
		var ar := deg_to_rad(deg)
		var d := edge_radius(ar) - 2.2
		_plant("pine_a" if deg < VISTA_AT else "pine_b", Vector2(sin(ar) * d, cos(ar) * d), 2.5, 1.1)
