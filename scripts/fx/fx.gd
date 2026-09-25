class_name Fx
extends RefCounted
## One-shot visual effects. Everything frees itself.
##
## Deflect sparks are layered: a fast burst of velocity-aligned streaks, a slower shower
## of falling embers, a star-shaped flash billboard and a real light pulse that lights
## both fighters for a few frames. Hit-stop freezes them mid-burst for the classic
## "freeze frame" read.

enum { SPARK_DEFLECT, SPARK_BLOCK, SPARK_PARRY, SPARK_MIKIRI, SPARK_BREAK, SPARK_GROUND }

static var _spark_mat: StandardMaterial3D
static var _blood_mat: StandardMaterial3D
static var _dust_mat: StandardMaterial3D
static var _star_mat: StandardMaterial3D
static var _textures: Dictionary = {}


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
	parent.add_child(p)
	p.global_position = pos
	p.emitting = true
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
	parent.add_child(e)
	e.global_position = pos
	e.emitting = true
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


static func blood(parent: Node, pos: Vector3, dir: Vector3, amount := 40, big := false) -> void:
	if _blood_mat == null:
		_blood_mat = StandardMaterial3D.new()
		_blood_mat.albedo_color = Color(0.32, 0.01, 0.01)
		_blood_mat.roughness = 0.3
		_blood_mat.metallic_specular = 0.8
		_blood_mat.vertex_color_use_as_albedo = true
	var p := CPUParticles3D.new()
	p.one_shot = true
	p.explosiveness = 0.92
	p.amount = amount
	p.lifetime = 0.9
	p.local_coords = false
	p.direction = dir.normalized() + Vector3(0, 0.35, 0)
	p.spread = 40.0 if not big else 65.0
	p.initial_velocity_min = 2.0
	p.initial_velocity_max = 6.5 if not big else 9.0
	p.gravity = Vector3(0, -12.0, 0)
	p.damping_min = 0.5
	p.damping_max = 2.0
	p.scale_amount_min = 0.5
	p.scale_amount_max = 1.6
	p.scale_amount_curve = _curve([Vector2(0, 1), Vector2(0.7, 0.8), Vector2(1, 0)])
	var s := SphereMesh.new()
	s.radius = 0.016
	s.height = 0.032
	s.radial_segments = 6
	s.rings = 3
	p.mesh = s
	p.material_override = _blood_mat
	p.color_ramp = _ramp([Color(0.55, 0.02, 0.02), Color(0.3, 0.0, 0.0)], [0.0, 1.0])
	parent.add_child(p)
	p.global_position = pos
	p.emitting = true
	_free_later(p, 1.3)
	# mist
	var m := CPUParticles3D.new()
	m.one_shot = true
	m.explosiveness = 1.0
	m.amount = 10 if not big else 18
	m.lifetime = 0.55
	m.local_coords = false
	m.direction = dir.normalized()
	m.spread = 50.0
	m.initial_velocity_min = 0.6
	m.initial_velocity_max = 2.2
	m.gravity = Vector3(0, -1.0, 0)
	m.damping_min = 3.0
	m.damping_max = 5.0
	m.scale_amount_min = 1.0
	m.scale_amount_max = 2.2
	m.scale_amount_curve = _curve([Vector2(0, 0.4), Vector2(0.3, 1.0), Vector2(1, 1.2)])
	var q := QuadMesh.new()
	q.size = Vector2(0.18, 0.18)
	m.mesh = q
	var mm := StandardMaterial3D.new()
	mm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mm.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	mm.vertex_color_use_as_albedo = true
	mm.albedo_texture = radial_texture("mist", Color(1, 1, 1, 1), Color(1, 1, 1, 0), 64)
	m.material_override = mm
	m.color_ramp = _ramp([Color(0.5, 0.02, 0.02, 0.55), Color(0.25, 0.0, 0.0, 0.0)], [0.0, 1.0])
	parent.add_child(m)
	m.global_position = pos
	m.emitting = true
	_free_later(m, 0.9)


static func dust(parent: Node, pos: Vector3, amount := 18, spread_radius := 0.6) -> void:
	if _dust_mat == null:
		_dust_mat = StandardMaterial3D.new()
		_dust_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		_dust_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		_dust_mat.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
		_dust_mat.vertex_color_use_as_albedo = true
		_dust_mat.albedo_texture = radial_texture("dust", Color(1, 1, 1, 1), Color(1, 1, 1, 0), 64)
	var p := CPUParticles3D.new()
	p.one_shot = true
	p.explosiveness = 0.95
	p.amount = amount
	p.lifetime = 1.1
	p.local_coords = false
	p.emission_shape = CPUParticles3D.EMISSION_SHAPE_SPHERE
	p.emission_sphere_radius = spread_radius * 0.4
	p.direction = Vector3(0, 0.4, 0)
	p.spread = 85.0
	p.initial_velocity_min = 0.8
	p.initial_velocity_max = 2.6
	p.gravity = Vector3(0, -0.6, 0)
	p.damping_min = 2.0
	p.damping_max = 3.5
	p.scale_amount_min = 1.0
	p.scale_amount_max = 2.0
	p.scale_amount_curve = _curve([Vector2(0, 0.5), Vector2(0.4, 1.0), Vector2(1, 1.4)])
	var q := QuadMesh.new()
	q.size = Vector2(0.35, 0.35)
	p.mesh = q
	p.material_override = _dust_mat
	p.color_ramp = _ramp([Color(0.55, 0.52, 0.48, 0.45), Color(0.4, 0.38, 0.36, 0.0)], [0.0, 1.0])
	parent.add_child(p)
	p.global_position = pos + Vector3(0, 0.08, 0)
	p.emitting = true
	_free_later(p, 1.5)


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
