class_name Arena
extends Node3D
## "Moon Gate" courtyard: a circular flagstone plaza on a mountain shrine at night.
## The plaza's stones are a model (tools/build_arena_floor.py); everything else is procedural.

@export var radius := 15.6
@export var lantern_count := 8
@export var moon_elevation_deg := 44.0
@export var moon_azimuth_deg := -150.0     ## 0 = +Z. Default puts the moon high behind-left of the boss.
@export var tree_count := 34

const FLOOR_SCENE := "res://models/arena_floor.glb"
const FLOOR_TEX_DIR := "res://textures/floor/"
const FLOOR_TEXTURES := ["stone_albedo.jpg", "stone_normal.jpg", "stone_data.jpg", "moss_albedo.png", "moss_normal.png",
	"cracks.png", "engraving.png", "plaza_a.png", "plaza_b.png"]

var _lanterns: Array = []   ## Array of [OmniLight3D, base_energy, seed]
var _t := 0.0


func _ready() -> void:
	_build_environment()
	_build_floor()
	_build_boundary()
	_build_lanterns()
	_build_torii()
	_build_shrine()
	_build_trees()
	_build_mountains()
	_build_embers()


func _process(delta: float) -> void:
	_t += delta
	for l in _lanterns:
		var light: OmniLight3D = l[0]
		var base: float = l[1]
		var sd: float = l[2]
		var f := 0.86 + 0.08 * sin(_t * 7.3 + sd) + 0.06 * sin(_t * 17.1 + sd * 2.3) + 0.03 * sin(_t * 31.0 + sd * 0.7)
		light.light_energy = base * f


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
## with rounded, worn edges over a mortar bed, and a puddle. The earth around it is a shader on a
## plane just below. Collision stays a flat box at y = 0: the stones sit within millimetres of it.
func _build_floor() -> void:
	var ground := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(260, 260)
	plane.subdivide_width = 8
	plane.subdivide_depth = 8
	ground.mesh = plane
	var ground_mat := ShaderMaterial.new()
	ground_mat.shader = load("res://shaders/ground.gdshader")
	ground.material_override = ground_mat
	ground.position.y = -0.06
	ground.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(ground)

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


func _build_boundary() -> void:
	var stone := MeshKit.mat(Color(0.25, 0.245, 0.24), 0.9, 0.0, {"rim": 0.1})
	var wood := MeshKit.mat(Color(0.33, 0.06, 0.035), 0.55, 0.0, {"clearcoat": 0.3})
	var body := StaticBody3D.new()
	add_child(body)
	var segs := 36
	var wall_r := radius - 0.2
	for i in segs:
		var a := TAU * float(i) / float(segs)
		var a2 := TAU * (float(i) + 0.5) / float(segs)
		var cs := CollisionShape3D.new()
		var b := BoxShape3D.new()
		b.size = Vector3(TAU * wall_r / segs + 0.4, 4.0, 0.6)
		cs.shape = b
		cs.position = Vector3(sin(a2) * (wall_r + 0.3), 2.0, cos(a2) * (wall_r + 0.3))
		cs.rotation.y = a2
		body.add_child(cs)
		# posts
		var post := MeshInstance3D.new()
		post.mesh = MeshKit.box(Vector3(0.22, 0.95, 0.22))
		post.material_override = stone
		post.position = Vector3(sin(a) * wall_r, 0.475, cos(a) * wall_r)
		post.rotation.y = a
		add_child(post)
		var cap := MeshInstance3D.new()
		cap.mesh = MeshKit.box(Vector3(0.3, 0.08, 0.3))
		cap.material_override = stone
		cap.position = Vector3(sin(a) * wall_r, 0.99, cos(a) * wall_r)
		cap.rotation.y = a
		add_child(cap)
		# rails
		for yv in [0.45, 0.85]:
			var rail := MeshInstance3D.new()
			rail.mesh = MeshKit.box(Vector3(TAU * wall_r / segs - 0.2, 0.07, 0.07))
			rail.material_override = wood
			rail.position = Vector3(sin(a2) * wall_r, yv, cos(a2) * wall_r)
			rail.rotation.y = a2
			add_child(rail)


func _build_lanterns() -> void:
	var stone := MeshKit.mat(Color(0.3, 0.29, 0.28), 0.92)
	var paper := MeshKit.glow(Color(1.0, 0.62, 0.3), 2.2)
	var lathe := PackedVector2Array([Vector2(0, 0), Vector2(0.34, 0.0), Vector2(0.34, 0.1), Vector2(0.22, 0.14),
		Vector2(0.12, 0.2), Vector2(0.1, 0.8), Vector2(0.2, 0.86), Vector2(0.26, 0.92), Vector2(0.0, 0.92)])
	var base_mesh := MeshKit.lathe(lathe, 6, 1.0, 1.0, true)
	var roof_mesh := MeshKit.cylinder(0.05, 0.42, 0.26, 6)
	for i in lantern_count:
		var a := TAU * (float(i) + 0.5) / float(lantern_count)
		var pos := Vector3(sin(a) * (radius - 1.1), 0, cos(a) * (radius - 1.1))
		var root := Node3D.new()
		root.position = pos
		root.rotation.y = a
		add_child(root)
		MeshKit.add_mesh(root, base_mesh, stone)
		MeshKit.add_mesh(root, MeshKit.box(Vector3(0.36, 0.34, 0.36)), stone, Vector3(0, 1.1, 0))
		MeshKit.add_mesh(root, MeshKit.box(Vector3(0.26, 0.24, 0.38)), paper, Vector3(0, 1.1, 0), Vector3.ZERO, Vector3.ONE, false)
		MeshKit.add_mesh(root, MeshKit.box(Vector3(0.38, 0.24, 0.26)), paper, Vector3(0, 1.1, 0), Vector3.ZERO, Vector3.ONE, false)
		MeshKit.add_mesh(root, roof_mesh, stone, Vector3(0, 1.41, 0), Vector3(0, 30, 0))
		MeshKit.add_mesh(root, MeshKit.sphere(0.07, -1.0, 8), stone, Vector3(0, 1.6, 0))
		var l := OmniLight3D.new()
		l.light_color = Color(1.0, 0.58, 0.28)
		l.light_energy = 2.8
		l.omni_range = 9.0
		l.omni_attenuation = 1.3
		l.light_volumetric_fog_energy = 0.6
		l.shadow_enabled = i % 4 == 0
		l.position = Vector3(0, 1.1, 0)
		root.add_child(l)
		_lanterns.append([l, 2.8, randf() * 10.0])


func _build_torii() -> void:
	var red := MeshKit.mat(Color(0.52, 0.075, 0.04), 0.45, 0.0, {"clearcoat": 0.25, "rim": 0.15})
	var black := MeshKit.mat(Color(0.03, 0.03, 0.03), 0.5)
	var root := Node3D.new()
	root.position = Vector3(0, 0, -(radius + 9.0))
	add_child(root)
	for sx in [-1.0, 1.0]:
		MeshKit.add_mesh(root, MeshKit.cylinder(0.3, 0.36, 7.0, 16), red, Vector3(2.9 * sx, 3.5, 0))
		MeshKit.add_mesh(root, MeshKit.cylinder(0.42, 0.42, 0.5, 16), black, Vector3(2.9 * sx, 0.25, 0))
	# kasagi (top beam), slightly curved up at the ends
	var path := PackedVector3Array()
	var radii := PackedFloat32Array()
	for i in 13:
		var u := float(i) / 12.0 * 2.0 - 1.0
		path.append(Vector3(u * 4.6, 7.25 + 0.35 * u * u * u * u, 0))
		radii.append(0.3)
	MeshKit.add_mesh(root, MeshKit.sweep(path, radii, 8, Vector3(0, 1, 0), 0.55), black)
	var path2 := PackedVector3Array()
	for i in 13:
		var u := float(i) / 12.0 * 2.0 - 1.0
		path2.append(Vector3(u * 4.3, 6.9 + 0.25 * u * u * u * u, 0))
	MeshKit.add_mesh(root, MeshKit.sweep(path2, radii, 8, Vector3(0, 1, 0), 0.5), red)
	MeshKit.add_mesh(root, MeshKit.box(Vector3(7.2, 0.4, 0.3)), red, Vector3(0, 5.6, 0))
	MeshKit.add_mesh(root, MeshKit.box(Vector3(0.35, 1.1, 0.25)), red, Vector3(0, 6.2, 0))
	MeshKit.add_mesh(root, MeshKit.box(Vector3(1.0, 0.7, 0.08)), black, Vector3(0, 6.2, 0.16))


func _build_shrine() -> void:
	var wood := MeshKit.mat(Color(0.12, 0.07, 0.05), 0.8)
	var roof := MeshKit.mat(Color(0.05, 0.055, 0.06), 0.6)
	var glow := MeshKit.glow(Color(1.0, 0.55, 0.25), 1.6)
	var root := Node3D.new()
	root.position = Vector3(0, 0, -(radius + 22.0))
	add_child(root)
	MeshKit.add_mesh(root, MeshKit.box(Vector3(11, 0.8, 8)), MeshKit.mat(Color(0.2, 0.19, 0.18), 0.9), Vector3(0, 0.4, 0))
	MeshKit.add_mesh(root, MeshKit.box(Vector3(9, 3.6, 6)), wood, Vector3(0, 2.6, 0))
	MeshKit.add_mesh(root, MeshKit.cylinder(0.6, 7.6, 2.8, 4), roof, Vector3(0, 5.8, 0), Vector3(0, 45, 0), Vector3(1.0, 1.0, 0.75))
	MeshKit.add_mesh(root, MeshKit.box(Vector3(5.5, 1.6, 0.1)), glow, Vector3(0, 2.2, -3.02), Vector3.ZERO, Vector3.ONE, false)
	var l := OmniLight3D.new()
	l.light_color = Color(1.0, 0.55, 0.28)
	l.light_energy = 3.0
	l.omni_range = 12.0
	l.position = Vector3(0, 2.4, -4.0)
	root.add_child(l)


func _build_trees() -> void:
	var needles := MeshKit.mat(Color(0.03, 0.05, 0.04), 0.95)
	var bark := MeshKit.mat(Color(0.07, 0.05, 0.04), 0.95)
	var rng := RandomNumberGenerator.new()
	rng.seed = 1337
	for i in tree_count:
		var a := rng.randf() * TAU
		var d := rng.randf_range(radius + 5.0, radius + 34.0)
		var pos := Vector3(sin(a) * d, 0, cos(a) * d)
		if absf(pos.x) < 9.0 and pos.z < -(radius + 3.0) and pos.z > -(radius + 30.0):
			continue   # keep the torii / shrine view clear
		var s := rng.randf_range(0.8, 1.6)
		var root := Node3D.new()
		root.position = pos
		root.scale = Vector3.ONE * s
		root.rotation.y = rng.randf() * TAU
		add_child(root)
		MeshKit.add_mesh(root, MeshKit.cylinder(0.18, 0.3, 4.0, 8), bark, Vector3(0, 2.0, 0))
		for k in 4:
			var h := 3.0 + k * 2.1
			MeshKit.add_mesh(root, MeshKit.cylinder(0.05, 2.6 - k * 0.5, 3.0, 9), needles, Vector3(0, h, 0))


func _build_mountains() -> void:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.05, 0.06, 0.085)
	mat.roughness = 1.0
	var rng := RandomNumberGenerator.new()
	rng.seed = 42
	for i in 14:
		var a := TAU * float(i) / 14.0 + rng.randf_range(-0.15, 0.15)
		var d := rng.randf_range(170.0, 230.0)
		var h := rng.randf_range(45.0, 95.0)
		var mi := MeshInstance3D.new()
		mi.mesh = MeshKit.cylinder(rng.randf_range(2.0, 8.0), rng.randf_range(60.0, 110.0), h, 7)
		mi.material_override = mat
		mi.position = Vector3(sin(a) * d, h * 0.5 - 12.0, cos(a) * d)
		mi.rotation.y = rng.randf() * TAU
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(mi)


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
