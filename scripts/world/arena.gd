class_name Arena
extends Node3D
## "Moon Gate" courtyard: a circular flagstone plaza on a mountain shrine at night.
## The plaza's stones are a model (tools/build_arena_floor.py); the world round it - forest,
## torii, shrine, lanterns, fence - is Scenery (tools/build_scenery.py).

@export var radius := 15.6
@export var moon_elevation_deg := 44.0
@export var moon_azimuth_deg := -150.0     ## 0 = +Z. Default puts the moon high behind-left of the boss.

const FLOOR_SCENE := "res://models/arena_floor.glb"
const FLOOR_TEX_DIR := "res://textures/floor/"
const FLOOR_TEXTURES := ["stone_albedo.jpg", "stone_normal.jpg", "stone_data.jpg", "moss_albedo.png", "moss_normal.png",
	"cracks.png", "engraving.png", "plaza_a.png", "plaza_b.png"]



func _ready() -> void:
	_build_environment()
	_build_floor()
	_build_boundary()
	var scenery := Scenery.new()
	scenery.name = "Scenery"
	add_child(scenery)
	scenery.build(radius)
	_build_embers()


# ------------------------------------------------------------------------ environment
func _build_environment() -> void:
	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	var sky := Sky.new()
	var sky_mat := ShaderMaterial.new()
	sky_mat.shader = load("res://shaders/night_sky.gdshader")
	sky.sky_material = sky_mat
	sky.radiance_size = Sky.RADIANCE_SIZE_256
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	# A bright moonlit night: readable first, moody second.
	env.ambient_light_energy = 1.0
	env.ambient_light_sky_contribution = 0.45
	env.ambient_light_color = Color(0.36, 0.4, 0.56)
	env.reflected_light_source = Environment.REFLECTION_SOURCE_SKY
	env.tonemap_mode = Environment.TONE_MAPPER_ACES
	env.tonemap_exposure = 1.18
	env.tonemap_white = 6.0
	env.glow_enabled = true
	env.glow_intensity = 0.85
	env.glow_strength = 1.0
	env.glow_bloom = 0.06
	env.glow_hdr_threshold = 0.95
	env.glow_blend_mode = Environment.GLOW_BLEND_MODE_SCREEN
	env.set_glow_level(0, 0.0)
	env.set_glow_level(1, 0.6)
	env.set_glow_level(2, 1.0)
	env.set_glow_level(3, 0.8)
	env.set_glow_level(4, 0.4)
	env.fog_enabled = true
	env.fog_light_color = Color(0.14, 0.16, 0.24)
	env.fog_light_energy = 1.0
	env.fog_density = 0.0065
	env.fog_sky_affect = 0.35
	env.fog_aerial_perspective = 0.25
	env.fog_height = 0.4
	env.fog_height_density = 0.05
	env.volumetric_fog_enabled = true
	env.volumetric_fog_density = 0.008
	env.volumetric_fog_albedo = Color(0.7, 0.75, 0.9)
	env.volumetric_fog_emission = Color(0.012, 0.014, 0.024)
	env.volumetric_fog_anisotropy = 0.35
	env.volumetric_fog_length = 48.0
	env.ssao_enabled = true
	env.ssao_radius = 1.1
	env.ssao_intensity = 1.2
	env.adjustment_enabled = true
	env.adjustment_contrast = 1.08
	env.adjustment_saturation = 0.95
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)

	var moon := DirectionalLight3D.new()
	moon.light_color = Color(0.74, 0.8, 1.0)
	moon.light_energy = 1.45
	moon.shadow_enabled = true
	moon.shadow_blur = 1.5
	moon.directional_shadow_max_distance = 45.0
	moon.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS
	moon.light_angular_distance = 0.6
	moon.light_volumetric_fog_energy = 0.8
	var el := deg_to_rad(moon_elevation_deg)
	var az := deg_to_rad(moon_azimuth_deg)
	var toward_moon := Vector3(sin(az) * cos(el), sin(el), cos(az) * cos(el))
	moon.basis = Basis.looking_at(-toward_moon, Vector3.UP)
	add_child(moon)
	# Weak warm fill from the opposite side so faces never go fully black.
	var fill := DirectionalLight3D.new()
	fill.light_color = Color(0.95, 0.62, 0.42)
	fill.light_energy = 0.4
	fill.shadow_enabled = false
	fill.basis = Basis.looking_at(Vector3(-toward_moon.x, -0.4, -toward_moon.z), Vector3.UP)
	add_child(fill)


# ------------------------------------------------------------------------ floor + walls
## The flagstone plaza is modelled and textured offline (tools/build_arena_floor.py): real slabs
## with rounded, worn edges over a mortar bed, and a puddle. The ground round it is Scenery's.
## Collision stays a flat box at y = 0: the stones sit within millimetres of it.
func _build_floor() -> void:
	var tex := {}
	for f in FLOOR_TEXTURES:
		tex[f.get_basename()] = load(FLOOR_TEX_DIR + f)
	var mats := {
		"Stones": _floor_material("flagstones", tex),
		"Bed": _floor_material("floor_bed", tex),
		"Water": _floor_material("puddle", tex),
	}
	var plaza: Node3D = (load(FLOOR_SCENE) as PackedScene).instantiate()
	plaza.name = "Plaza"
	add_child(plaza)
	for node in plaza.find_children("*", "MeshInstance3D", true, false):
		var mi := node as MeshInstance3D
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		for key in mats:
			if String(mi.name).begins_with(key):
				mi.material_override = mats[key]

	var body := StaticBody3D.new()
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(260, 2, 260)
	cs.shape = box
	cs.position = Vector3(0, -1, 0)
	body.add_child(cs)
	add_child(body)


## A floor shader with every texture it declares bound by name (stone_albedo, plaza_a, ...).
func _floor_material(shader_name: String, tex: Dictionary) -> ShaderMaterial:
	var mat := ShaderMaterial.new()
	mat.shader = load("res://shaders/%s.gdshader" % shader_name)
	for u in mat.shader.get_shader_uniform_list():
		var uname: String = u["name"]
		if tex.has(uname):
			mat.set_shader_parameter(uname, tex[uname])
	return mat


## The invisible wall round the plaza's rim that keeps the fight (and the camera) in; the fence
## you see there is Scenery's.
func _build_boundary() -> void:
	var body := StaticBody3D.new()
	add_child(body)
	var segs := 36
	var wall_r := radius - 0.2
	for i in segs:
		var a2 := TAU * (float(i) + 0.5) / float(segs)
		var cs := CollisionShape3D.new()
		var b := BoxShape3D.new()
		b.size = Vector3(TAU * wall_r / segs + 0.4, 4.0, 0.6)
		cs.shape = b
		cs.position = Vector3(sin(a2) * (wall_r + 0.3), 2.0, cos(a2) * (wall_r + 0.3))
		cs.rotation.y = a2
		body.add_child(cs)


func _build_embers() -> void:
	var p := CPUParticles3D.new()
	p.amount = 90
	p.lifetime = 9.0
	p.preprocess = 9.0
	p.emission_shape = CPUParticles3D.EMISSION_SHAPE_BOX
	p.emission_box_extents = Vector3(radius, 3.0, radius)
	p.position = Vector3(0, 2.5, 0)
	p.direction = Vector3(0.3, 1, 0.1)
	p.spread = 60.0
	p.gravity = Vector3(0.12, 0.05, 0.03)
	p.initial_velocity_min = 0.05
	p.initial_velocity_max = 0.35
	p.scale_amount_min = 0.5
	p.scale_amount_max = 1.4
	var c := Curve.new()
	c.add_point(Vector2(0.0, 0.0))
	c.add_point(Vector2(0.15, 1.0))
	c.add_point(Vector2(0.85, 1.0))
	c.add_point(Vector2(1.0, 0.0))
	p.scale_amount_curve = c
	p.mesh = MeshKit.sphere(0.012, -1.0, 6)
	p.material_override = MeshKit.glow(Color(1.0, 0.5, 0.18), 4.0)
	add_child(p)
