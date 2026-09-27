class_name Fx
extends RefCounted
## One-shot visual effects. Everything frees itself.
##
## Deflect sparks are layered: a fast burst of velocity-aligned streaks, a slower shower
## of falling embers, a star-shaped flash billboard and a real light pulse that lights
## both fighters for a few frames. Hit-stop freezes them mid-burst for the classic
## "freeze frame" read.

enum { SPARK_DEFLECT, SPARK_BLOCK, SPARK_PARRY, SPARK_MIKIRI, SPARK_BREAK, SPARK_GROUND }

const SPLAT_TEXTURES := 3      ## textures/fx/blood_splat_*.png (tools/gen_fx_textures.py)
const MAX_SPLATS := 36
const SPLAT_LIFE := 12.0       ## seconds a splatter stays before it fades

const PUFF_SHADER := """
shader_type spatial;
render_mode blend_mix, cull_disabled, depth_draw_never, shadows_disabled, @MODE@;

uniform sampler2D noise_tex : filter_linear_mipmap, repeat_enable;

varying float v_seed;
varying vec4 v_col;

void vertex() {
@BILLBOARD@
	v_seed = fract(float(INSTANCE_ID) * 0.618034 + 0.29);
	v_col = COLOR;
}

void fragment() {
	vec2 p = UV * 2.0 - 1.0;
	vec2 q = UV * 0.5 + vec2(v_seed * 7.1, v_seed * 3.3 - TIME * 0.05);
	float cells = texture(noise_tex, q).a;
	float fine = texture(noise_tex, q * 2.3 + 0.5).g;
	float edge = length(p) + (0.5 - cells) * 0.8 + (0.5 - fine) * 0.25;
	float puff = 1.0 - smoothstep(0.3, 1.0, edge);
	ALBEDO = v_col.rgb * (0.78 + 0.3 * (1.0 - UV.y) + 0.3 * (cells - 0.5));
	ALPHA = clamp(puff * v_col.a, 0.0, 1.0);
}
"""

static var _spark_mat: StandardMaterial3D
static var _blood_mat: StandardMaterial3D
static var _star_mat: StandardMaterial3D
static var _textures: Dictionary = {}
static var _splats: Array = []                        ## live blood decals, oldest first
static var _seed := 7                                 ## cosmetic randomness (see _rand), off the game's RNG


## Cosmetic randomness in [a, b), from its own generator: the game's RNG drives the AI, and the
## splatter comes out the same every run, so captures reproduce.
static func _rand(a := 0.0, b := 1.0) -> float:
	_seed = (_seed * 1103515245 + 12345) & 0x7fffffff
	return a + (b - a) * float(_seed) / 2147483648.0


static func _spark_material() -> StandardMaterial3D:
	if _spark_mat == null:
		_spark_mat = StandardMaterial3D.new()
		_spark_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		_spark_mat.vertex_color_use_as_albedo = true
		_spark_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		_spark_mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
		_spark_mat.albedo_color = Color(2.2, 1.9, 1.5)
	return _spark_mat


static func radial_texture(key: String, inner: Color, outer: Color, size := 128) -> Texture2D:
	if _textures.has(key):
		return _textures[key]
	var g := Gradient.new()
	g.set_color(0, inner)
	g.set_color(1, outer)
	g.add_point(0.35, Color(inner.r, inner.g, inner.b, inner.a * 0.45))
	var t := GradientTexture2D.new()
	t.gradient = g
	t.fill = GradientTexture2D.FILL_RADIAL
	t.fill_from = Vector2(0.5, 0.5)
	t.fill_to = Vector2(1.0, 0.5)
	t.width = size
	t.height = size
	_textures[key] = t
	return t


static func _billboard_material(tex: Texture2D) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	m.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	m.albedo_texture = tex
	m.no_depth_test = true
	m.render_priority = 10
	return m


static func _ramp(colors: Array, offsets: Array) -> Gradient:
	var g := Gradient.new()
	g.offsets = PackedFloat32Array(offsets)
	g.colors = PackedColorArray(colors)
	return g


static func _curve(points: Array) -> Curve:
	var c := Curve.new()
	for p in points:
		c.add_point(p)
	return c


## Makes a tween advance in real time (ignoring Engine.time_scale) where supported,
## so flashes play out during hit-stop freeze frames.
static func _real_time(tw: Tween) -> void:
	if tw.has_method("set_ignore_time_scale"):
		tw.call("set_ignore_time_scale", true)


static func _free_later(node: Node, seconds: float) -> void:
	var tree := node.get_tree()
	if tree == null:
		return
	tree.create_timer(seconds, false).timeout.connect(node.queue_free)


## Starts a one-shot particle burst at `pos`. A CPUParticles3D starts out emitting and runs its
## first update the moment it enters the tree, so it has to be placed first and switched on
## after, or the burst fires from the parent's origin (the middle of the arena).
static func _emit_at(parent: Node, p: CPUParticles3D, pos: Vector3) -> void:
	p.emitting = false
	parent.add_child(p)
	p.global_position = pos
	p.emitting = true


## Spark burst at `pos`. `normal` points away from the struck surface (toward the viewer
## side of the clash); sparks spray around it.
static func sparks(parent: Node, pos: Vector3, normal: Vector3, kind: int) -> void:
	var n := normal.normalized() if normal.length() > 0.001 else Vector3.UP
	var cfg := {
		# Deflect: an intense, compact golden burst with long fast streaks (Sekiro's "perfect"
		# deflect read) - clearly bigger and brighter than a block, without hiding the clash.
		SPARK_DEFLECT: {"amount": 64, "vmin": 6.0, "vmax": 15.0, "life": 0.4, "len": 0.17, "flash": 0.8, "light": 5.0,
			"col": Color(1.0, 0.86, 0.52), "col2": Color(1.0, 0.5, 0.12), "embers": 26, "star": true},
		SPARK_PARRY: {"amount": 50, "vmin": 5.0, "vmax": 12.0, "life": 0.36, "len": 0.14, "flash": 0.7, "light": 4.0,
			"col": Color(1.0, 0.82, 0.5), "col2": Color(1.0, 0.45, 0.1), "embers": 18, "star": true},
		# Block: a small, dull spit of sparks - no flash star, barely any light.
		SPARK_BLOCK: {"amount": 16, "vmin": 2.0, "vmax": 5.0, "life": 0.26, "len": 0.06, "flash": 0.32, "light": 1.2,
			"col": Color(1.0, 0.62, 0.3), "col2": Color(0.8, 0.26, 0.05), "embers": 6, "star": false},
		SPARK_MIKIRI: {"amount": 80, "vmin": 5.0, "vmax": 13.0, "life": 0.5, "len": 0.16, "flash": 1.1, "light": 6.0,
			"col": Color(1.0, 0.88, 0.6), "col2": Color(1.0, 0.5, 0.12), "embers": 32, "star": true},
		SPARK_BREAK: {"amount": 110, "vmin": 5.0, "vmax": 15.0, "life": 0.6, "len": 0.17, "flash": 1.5, "light": 8.0,
			"col": Color(1.0, 0.92, 0.75), "col2": Color(1.0, 0.4, 0.1), "embers": 40, "star": true},
		SPARK_GROUND: {"amount": 26, "vmin": 2.0, "vmax": 6.5, "life": 0.4, "len": 0.08, "flash": 0.7, "light": 3.0,
			"col": Color(1.0, 0.75, 0.4), "col2": Color(0.9, 0.3, 0.05), "embers": 10, "star": false},
	}
	var c: Dictionary = cfg.get(kind, cfg[SPARK_BLOCK])
	# Streaks
	var p := CPUParticles3D.new()
	p.one_shot = true
	p.explosiveness = 1.0
	p.amount = int(c["amount"])
	p.lifetime = float(c["life"])
	p.local_coords = false
	p.direction = n
	p.spread = 70.0
	p.initial_velocity_min = float(c["vmin"])
	p.initial_velocity_max = float(c["vmax"])
	p.gravity = Vector3(0, -9.0, 0)
	p.damping_min = 4.0
	p.damping_max = 9.0
	p.particle_flag_align_y = true
	p.preprocess = 0.018   # already spread into a starburst when the hit-stop freezes the frame
	p.scale_amount_min = 0.6
	p.scale_amount_max = 1.3
	p.scale_amount_curve = _curve([Vector2(0, 1), Vector2(0.6, 0.7), Vector2(1, 0)])
	var streak := BoxMesh.new()
	streak.size = Vector3(0.007, float(c["len"]), 0.007)
	p.mesh = streak
	p.material_override = _spark_material()
	var col: Color = c["col"]
	var col2: Color = c["col2"]
	p.color_ramp = _ramp([col, col2, Color(col2.r, col2.g * 0.4, 0.0, 0.0)], [0.0, 0.45, 1.0])
	_emit_at(parent, p, pos)
	_free_later(p, float(c["life"]) + 0.3)
	# Slower embers that fall and flicker out
	var e := CPUParticles3D.new()
	e.one_shot = true
	e.explosiveness = 0.9
	e.amount = int(c["embers"])
	e.lifetime = float(c["life"]) * 2.2
	e.local_coords = false
	e.direction = n + Vector3(0, 0.6, 0)
	e.spread = 90.0
	e.initial_velocity_min = 1.0
	e.initial_velocity_max = 4.0
	e.gravity = Vector3(0, -6.0, 0)
	e.damping_min = 1.0
	e.damping_max = 3.0
	e.scale_amount_min = 0.5
	e.scale_amount_max = 1.0
	var dot := SphereMesh.new()
	dot.radius = 0.008
	dot.height = 0.016
	dot.radial_segments = 6
	dot.rings = 3
	e.mesh = dot
	e.material_override = _spark_material()
	e.color_ramp = _ramp([col2, Color(col2.r, col2.g * 0.5, 0.0, 0.0)], [0.0, 1.0])
	_emit_at(parent, e, pos)
	_free_later(e, e.lifetime + 0.3)
	# Flash billboard (+ star streaks for deflects)
	flash(parent, pos, float(c["flash"]), col, bool(c["star"]))
	light_pulse(parent, pos + n * 0.15, Color(1.0, 0.7, 0.38), float(c["light"]), 4.0, 0.12)


static func flash(parent: Node, pos: Vector3, size: float, color: Color, star: bool) -> void:
	var fkey := "flash_" + color.to_html()
	if not _textures.has(fkey):
		var fm := _billboard_material(radial_texture("flash", Color(1, 1, 1, 1), Color(1, 0.6, 0.2, 0)))
		fm.albedo_color = Color(color.r * 1.35, color.g * 1.35, color.b * 1.35, 1.0)
		_textures[fkey] = fm
	var q := QuadMesh.new()
	q.size = Vector2(size, size)
	var mi := MeshInstance3D.new()
	mi.mesh = q
	mi.material_override = _textures[fkey]
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(mi)
	mi.global_position = pos
	mi.scale = Vector3.ONE * 0.35
	var tw := mi.create_tween()
	_real_time(tw)   # stays alive during hit-stop freeze frames
	tw.tween_property(mi, "scale", Vector3.ONE, 0.03).set_trans(Tween.TRANS_EXPO).set_ease(Tween.EASE_OUT)
	tw.tween_property(mi, "scale", Vector3.ONE * 0.05, 0.1).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	tw.tween_callback(mi.queue_free)
	if star:
		if _star_mat == null:
			var g := Gradient.new()
			g.set_color(0, Color(1, 1, 1, 1))
			g.set_color(1, Color(1, 0.7, 0.3, 0))
			var t := GradientTexture2D.new()
			t.gradient = g
			t.fill = GradientTexture2D.FILL_RADIAL
			t.fill_from = Vector2(0.5, 0.5)
			t.fill_to = Vector2(0.5, 0.0)
			t.width = 64
			t.height = 64
			_star_mat = _billboard_material(t)
		for k in 2:
			var sq := QuadMesh.new()
			sq.size = Vector2(size * 1.7, size * 0.06)
			var s := MeshInstance3D.new()
			s.mesh = sq
			s.material_override = _star_mat
			s.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			parent.add_child(s)
			s.global_position = pos
			s.rotation.z = deg_to_rad(20.0 + 90.0 * k + randf_range(-15.0, 15.0))
			s.scale = Vector3(0.3, 1.0, 1.0)
			var tw2 := s.create_tween()
			_real_time(tw2)
			tw2.tween_property(s, "scale", Vector3(1.0, 1.0, 1.0), 0.03).set_trans(Tween.TRANS_EXPO).set_ease(Tween.EASE_OUT)
			tw2.tween_property(s, "scale", Vector3(1.25, 0.0, 1.0), 0.11).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
			tw2.tween_callback(s.queue_free)


static func light_pulse(parent: Node, pos: Vector3, color: Color, energy: float, rng: float, duration: float) -> void:
	var l := OmniLight3D.new()
	l.light_color = color
	l.light_energy = energy
	l.omni_range = rng
	l.omni_attenuation = 1.4
	l.shadow_enabled = false
	parent.add_child(l)
	l.global_position = pos
	var tw := l.create_tween()
	_real_time(tw)
	tw.tween_property(l, "light_energy", 0.0, duration).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tw.tween_callback(l.queue_free)


## Blood: a spray of drops that stretch along their flight, a fine mist of droplets and a red
## haze where it bursts out, then splatter on the flagstones where it comes down (decals that
## fade after a while). `dir` is the way it's thrown; `big` for deathblows.
static func blood(parent: Node, pos: Vector3, dir: Vector3, amount := 40, big := false) -> void:
	if parent == null or not parent.is_inside_tree():
		return
	var d := dir.normalized() if dir.length() > 0.001 else Vector3.UP
	var p := CPUParticles3D.new()
	p.one_shot = true
	p.explosiveness = 0.9
	p.amount = amount
	p.lifetime = 0.75
	p.local_coords = false
	p.direction = d + Vector3(0, 0.25, 0)
	p.spread = 32.0 if not big else 50.0
	p.initial_velocity_min = 2.5
	p.initial_velocity_max = 6.5 if not big else 9.5
	p.gravity = Vector3(0, -13.0, 0)
	p.damping_min = 0.3
	p.damping_max = 1.2
	p.particle_flag_align_y = true
	p.preprocess = 0.02
	p.scale_amount_min = 0.6
	p.scale_amount_max = 1.5 if not big else 1.9
	p.scale_amount_curve = _curve([Vector2(0, 1.0), Vector2(0.65, 0.8), Vector2(1, 0.0)])
	var drop := CylinderMesh.new()   # a teardrop streak, stretched along its velocity
	drop.top_radius = 0.004
	drop.bottom_radius = 0.01
	drop.height = 0.075
	drop.radial_segments = 5
	drop.rings = 1
	p.mesh = drop
	p.material_override = _blood_material()
	p.color_ramp = _ramp([Color(0.66, 0.035, 0.03), Color(0.5, 0.012, 0.012), Color(0.34, 0.0, 0.0, 0.0)], [0.0, 0.6, 1.0])
	_emit_at(parent, p, pos)
	_free_later(p, 1.1)
	# Fine spray: many tiny droplets, faster and shorter-lived.
	var f := CPUParticles3D.new()
	f.one_shot = true
	f.explosiveness = 1.0
	f.amount = int(amount * 1.2)
	f.lifetime = 0.45
	f.local_coords = false
	f.direction = d
	f.spread = 28.0 if not big else 40.0
	f.initial_velocity_min = 3.5
	f.initial_velocity_max = 9.0 if not big else 12.0
	f.gravity = Vector3(0, -9.0, 0)
	f.damping_min = 2.0
	f.damping_max = 5.0
	f.particle_flag_align_y = true
	f.scale_amount_min = 0.5
	f.scale_amount_max = 1.0
	var mote := CylinderMesh.new()
	mote.top_radius = 0.002
	mote.bottom_radius = 0.004
	mote.height = 0.04
	mote.radial_segments = 4
	mote.rings = 1
	f.mesh = mote
	f.material_override = _blood_material()
	f.color_ramp = _ramp([Color(0.72, 0.05, 0.04), Color(0.45, 0.01, 0.01, 0.0)], [0.0, 1.0])
	_emit_at(parent, f, pos)
	_free_later(f, 0.8)
	# Red haze where it bursts out.
	var m := CPUParticles3D.new()
	m.one_shot = true
	m.explosiveness = 1.0
	m.amount = 7 if not big else 14
	m.lifetime = 0.7
	m.local_coords = false
	m.direction = d
	m.spread = 40.0
	m.initial_velocity_min = 0.6
	m.initial_velocity_max = 2.0
	m.gravity = Vector3(0, -0.8, 0)
	m.damping_min = 3.0
	m.damping_max = 5.0
	m.scale_amount_min = 0.8
	m.scale_amount_max = 1.6 if not big else 2.2
	m.scale_amount_curve = _curve([Vector2(0, 0.35), Vector2(0.3, 1.0), Vector2(1, 1.3)])
	var q := QuadMesh.new()
	q.size = Vector2(0.3, 0.3)
	m.mesh = q
	m.material_override = _puff_material(false)
	m.color_ramp = _ramp([Color(0.5, 0.02, 0.02, 0.55), Color(0.3, 0.0, 0.0, 0.0)], [0.0, 1.0])
	_emit_at(parent, m, pos)
	_free_later(m, 1.0)
	_splatter(parent, pos, d, big)


static func _blood_material() -> StandardMaterial3D:
	if _blood_mat == null:
		_blood_mat = StandardMaterial3D.new()
		_blood_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED   # reads as red in the dark
		_blood_mat.vertex_color_use_as_albedo = true
		_blood_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	return _blood_mat


## Splatter on the flagstones along the way the blood flew: decals that fade in as the drops
## land, stay a while and fade away. The oldest go first when there are too many.
static func _splatter(parent: Node, pos: Vector3, d: Vector3, big: bool) -> void:
	var flat := Vector3(d.x, 0.0, d.z)
	if flat.length() < 0.05:
		flat = Vector3(_rand(-1.0, 1.0), 0.0, _rand(-1.0, 1.0))
	flat = flat.normalized()
	var ground := Vector3(pos.x, 0.0, pos.z)
	var n := 3 + int(_rand(0.0, 3.0)) if big else 1 + int(_rand(0.0, 2.0))
	for i in n:
		var dist := _rand(0.25, 1.6 if big else 1.0)
		var side := flat.cross(Vector3.UP) * _rand(-0.3, 0.3)
		var way := flat.rotated(Vector3.UP, _rand(-0.5, 0.5))
		var size := _rand(0.5, 0.85) * (1.3 if big else 0.9)
		_add_splat(parent, ground + flat * dist + side, way, size, 0.1 + dist * 0.14)


static func _add_splat(parent: Node, at: Vector3, way: Vector3, size: float, delay: float) -> void:
	var dec := Decal.new()
	dec.texture_albedo = _splat_texture(int(_rand(0.0, float(SPLAT_TEXTURES))))
	dec.size = Vector3(size, 0.14, size)
	dec.albedo_mix = 1.0
	dec.upper_fade = 0.25
	dec.lower_fade = 0.25
	dec.distance_fade_enabled = true
	dec.distance_fade_begin = 30.0
	dec.distance_fade_length = 6.0
	dec.modulate = Color(1, 1, 1, 0)
	parent.add_child(dec)
	# The texture's +x is the way the blood flew.
	dec.global_transform = Transform3D(Basis(Vector3.UP, atan2(-way.z, way.x)), at)
	# (splats go with their scene: drop the ones already freed before counting)
	_splats = _splats.filter(func(x): return is_instance_valid(x))
	_splats.append(dec)
	while _splats.size() > MAX_SPLATS:
		(_splats.pop_front() as Node).queue_free()
	var tw := dec.create_tween()
	tw.tween_interval(delay)
	tw.tween_property(dec, "modulate:a", 1.0, 0.12)
	tw.tween_interval(SPLAT_LIFE)
	tw.tween_property(dec, "modulate:a", 0.0, 3.0)
	tw.tween_callback(func():
		_splats.erase(dec)
		dec.queue_free())


static func _splat_texture(i: int) -> Texture2D:
	var key := "splat_%d" % i
	if not _textures.has(key):
		_textures[key] = load("res://textures/fx/blood_splat_%d.png" % i)
	return _textures[key]


## Dust kicked up by feet, landings and impacts: soft billows lit by the scene, their edges
## eaten by the noise's cells.
static func dust(parent: Node, pos: Vector3, amount := 18, spread_radius := 0.6) -> void:
	if parent == null or not parent.is_inside_tree():
		return
	var p := CPUParticles3D.new()
	p.one_shot = true
	p.explosiveness = 0.95
	p.amount = amount
	p.lifetime = 1.2
	p.local_coords = false
	p.emission_shape = CPUParticles3D.EMISSION_SHAPE_SPHERE
	p.emission_sphere_radius = spread_radius * 0.4
	p.direction = Vector3(0, 0.35, 0)
	p.spread = 85.0
	p.initial_velocity_min = 0.8
	p.initial_velocity_max = 2.6
	p.gravity = Vector3(0, -0.5, 0)
	p.damping_min = 2.0
	p.damping_max = 3.5
	p.scale_amount_min = 1.0
	p.scale_amount_max = 2.0
	p.scale_amount_curve = _curve([Vector2(0, 0.45), Vector2(0.4, 1.0), Vector2(1, 1.5)])
	var q := QuadMesh.new()
	q.size = Vector2(0.42, 0.42)
	p.mesh = q
	p.material_override = _puff_material(true)
	p.color_ramp = _ramp([Color(0.62, 0.6, 0.58, 0.0), Color(0.6, 0.58, 0.56, 0.5), Color(0.52, 0.5, 0.49, 0.0)],
		[0.0, 0.12, 1.0])
	p.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_emit_at(parent, p, pos + Vector3(0, 0.08, 0))
	_free_later(p, 1.6)


## Soft puffs (dust, the haze of blood): a round billboard whose edge is eaten by the noise's
## cells, lumpier and lighter on top. The particle colour is the puff's colour and opacity.
## `lit`: shaded by the scene's lights (dust); otherwise its own colour (blood reads red at night).
static func _puff_material(lit: bool) -> ShaderMaterial:
	var key := "puff_lit" if lit else "puff"
	if not _textures.has(key):
		var sh := Shader.new()
		sh.code = PUFF_SHADER.replace("@MODE@", "diffuse_lambert_wrap, specular_disabled" if lit else "unshaded") \
			.replace("@BILLBOARD@", FireFx._BILLBOARD)
		var m := ShaderMaterial.new()
		m.shader = sh
		m.set_shader_parameter("noise_tex", FireFx.noise_texture())
		_textures[key] = m
	return _textures[key]


## Perilous-attack warning: the brush kanji pops in above the attacker and fades.
static func kanji(attach_to: Node3D, offset: Vector3, texture: Texture2D, color: Color, hold := 0.55, size := 0.0026) -> Sprite3D:
	var s := Sprite3D.new()
	s.texture = texture
	s.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	s.no_depth_test = true
	s.shaded = false
	s.pixel_size = size
	s.modulate = color
	s.render_priority = 20
	s.position = offset
	attach_to.add_child(s)
	s.scale = Vector3.ONE * 1.8
	s.modulate.a = 0.0
	var tw := s.create_tween()
	tw.set_parallel(true)
	tw.tween_property(s, "scale", Vector3.ONE, 0.11).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tw.tween_property(s, "modulate:a", 1.0, 0.06)
	tw.chain().tween_interval(hold)
	tw.chain().tween_property(s, "modulate:a", 0.0, 0.25)
	tw.chain().tween_callback(s.queue_free)
	return s


static func glow_sprite(texture: Texture2D, color: Color, size: float) -> Sprite3D:
	var s := Sprite3D.new()
	s.texture = texture
	s.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	s.no_depth_test = true
	s.shaded = false
	s.pixel_size = size / float(maxi(texture.get_width(), 1))
	s.modulate = color
	s.render_priority = 15
	return s
