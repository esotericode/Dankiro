class_name FireFx
extends RefCounted
## Fire for Sojin's Inferno (phase 2 on): shared textures, materials and meshes, and one-shot
## bursts. Walls of fire (the sweeping arms, the ring round him, the blast) are quads with
## WALL_SHADER: layered scrolling value noise cut off with height, a white-yellow core fading
## through orange to red tips, drawn additively (HDR, so it blooms). Loose flames and embers
## are CPU particles with a procedural flame sprite.

static var _flame_tex: Texture2D
static var _flame_mat: StandardMaterial3D
static var _ember_mat: StandardMaterial3D
static var _smoke_mat: StandardMaterial3D
static var _wall_shader: Shader
static var _strip_shader: Shader
static var _cracks_shader: Shader
static var _glow_mats: Dictionary = {}

const WALL_SHADER := """
shader_type spatial;
render_mode unshaded, blend_add, cull_disabled, depth_draw_never, shadows_disabled, fog_disabled;

uniform float heat = 1.0;          // brightness
uniform float height = 1.0;        // flame height as a fraction of the quad
uniform float alpha_mult = 1.0;
uniform float reveal = 1.0;        // 0..1 along the strip: an arm unrolling / retracting
uniform float scale_x = 16.0;      // metres along UV.x (keeps the noise the same size)
uniform float speed = 1.7;
uniform float seed = 0.0;
uniform float loop_x = 0.0;        // 1 for a closed band (ring, blast): no seam, no end fade
uniform vec3 core : source_color = vec3(1.0, 0.86, 0.55);
uniform vec3 body : source_color = vec3(1.0, 0.42, 0.08);
uniform vec3 tip : source_color = vec3(0.6, 0.08, 0.02);

float hash(vec2 p) {
	p = fract(p * vec2(123.34, 456.21));
	p += dot(p, p + 45.32);
	return fract(p.x * p.y);
}

float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	vec2 u = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash(i), hash(i + vec2(1.0, 0.0)), u.x),
			mix(hash(i + vec2(0.0, 1.0)), hash(i + vec2(1.0, 1.0)), u.x), u.y);
}

float fbm(vec2 p) {
	float v = 0.0;
	float a = 0.55;
	for (int i = 0; i < 4; i++) {
		v += a * vnoise(p);
		p = p * 2.07 + vec2(1.7, 9.2);
		a *= 0.5;
	}
	return v;
}

float flame(float x, float y, float t) {
	float n = fbm(vec2(x * 1.5, y * 1.3 - t));
	float n2 = fbm(vec2(x * 3.3 + 7.1, y * 2.7 - t * 1.6));
	return (0.62 * n + 0.48 * n2) * 1.3 - y * 1.05 + 0.1;
}

void fragment() {
	float x = UV.x * scale_x + seed;
	float y = UV.y / max(height, 0.05);
	float t = TIME * speed;
	float f = flame(x, y, t);
	if (loop_x > 0.5) {
		// blend into the noise from the other end over the last stretch: a seamless loop
		f = mix(f, flame(x - scale_x, y, t), smoothstep(0.85, 1.0, UV.x));
	}
	float a = smoothstep(0.0, 0.22, f);
	vec3 c = mix(tip, body, smoothstep(0.05, 0.40, f));
	c = mix(c, core, smoothstep(0.34, 0.80, f));
	float ends = 1.0;
	if (loop_x < 0.5) {
		ends = smoothstep(0.0, 0.012, UV.x) * (1.0 - smoothstep(reveal - 0.025, reveal, UV.x));
	}
	ALBEDO = c * heat * 1.25;
	ALPHA = clamp(a * alpha_mult * ends * 0.85, 0.0, 1.0);
}
"""

## A burning line on the floor (under each arm): hot core along the middle, flickering edges.
const STRIP_SHADER := """
shader_type spatial;
render_mode unshaded, blend_add, cull_disabled, depth_draw_never, shadows_disabled, fog_disabled;

uniform float heat = 1.0;
uniform float alpha_mult = 1.0;
uniform float reveal = 1.0;
uniform float scale_x = 16.0;
uniform vec3 core : source_color = vec3(1.0, 0.8, 0.45);
uniform vec3 body : source_color = vec3(1.0, 0.32, 0.05);

float hash(vec2 p) {
	p = fract(p * vec2(123.34, 456.21));
	p += dot(p, p + 45.32);
	return fract(p.x * p.y);
}

float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	vec2 u = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash(i), hash(i + vec2(1.0, 0.0)), u.x),
			mix(hash(i + vec2(0.0, 1.0)), hash(i + vec2(1.0, 1.0)), u.x), u.y);
}

void fragment() {
	float d = abs(UV.y - 0.5) * 2.0;
	float x = UV.x * scale_x;
	float n = vnoise(vec2(x * 2.2 - TIME * 3.0, UV.y * 4.0)) * 0.6 + vnoise(vec2(x * 5.0 + TIME * 1.3, UV.y * 9.0)) * 0.4;
	float f = (1.0 - d) * (0.55 + 0.7 * n);
	float ends = smoothstep(0.0, 0.012, UV.x) * (1.0 - smoothstep(reveal - 0.025, reveal, UV.x));
	ALBEDO = mix(body, core, smoothstep(0.55, 0.95, f)) * heat * 1.05;
	ALPHA = clamp(smoothstep(0.15, 0.6, f) * alpha_mult * ends, 0.0, 1.0);
}
"""


## The floor cracking open before the arena erupts: a network of glowing cracks (the edges of
## Voronoi cells) and jagged spokes out from the middle, revealed out to `reveal` (0..1 of the
## disc) with a bright front racing ahead, over a warm glow.
const CRACKS_SHADER := """
shader_type spatial;
render_mode unshaded, blend_add, cull_disabled, depth_draw_never, shadows_disabled, fog_disabled;

uniform float reveal = 1.0;
uniform float glow = 1.0;
uniform float scale = 11.0;
uniform vec3 hot : source_color = vec3(1.0, 0.72, 0.32);
uniform vec3 deep : source_color = vec3(1.0, 0.24, 0.04);

vec2 hash2(vec2 p) {
	p = vec2(dot(p, vec2(127.1, 311.7)), dot(p, vec2(269.5, 183.3)));
	return fract(sin(p) * 43758.5453);
}

float voronoi_edge(vec2 x) {
	vec2 n = floor(x);
	vec2 f = fract(x);
	float f1 = 8.0;
	float f2 = 8.0;
	for (int j = -1; j <= 1; j++) {
		for (int i = -1; i <= 1; i++) {
			vec2 g = vec2(float(i), float(j));
			vec2 r = g + hash2(n + g) - f;
			float d = dot(r, r);
			if (d < f1) {
				f2 = f1;
				f1 = d;
			} else if (d < f2) {
				f2 = d;
			}
		}
	}
	return sqrt(f2) - sqrt(f1);
}

void fragment() {
	vec2 p = UV * 2.0 - 1.0;
	float r = length(p);
	float crack = 1.0 - smoothstep(0.015, 0.07, voronoi_edge(p * scale));
	float a = atan(p.y, p.x);
	float spoke = pow(abs(sin(a * 9.0 + 1.7 * sin(r * 11.0))), 24.0) * smoothstep(0.05, 0.25, r);
	float lines = max(crack * 0.85, spoke);
	float inside = 1.0 - smoothstep(reveal - 0.03, reveal, r);
	float front = exp(-pow((r - reveal) / 0.025, 2.0)) * (1.0 - step(1.0, reveal));
	float edge = 1.0 - smoothstep(0.97, 1.0, r);
	float v = (lines * inside + front * 0.9 + 0.14 * inside) * edge;
	ALBEDO = mix(deep, hot, clamp(lines + front, 0.0, 1.0)) * v * glow * 1.3;
	ALPHA = clamp(v * glow, 0.0, 1.0);
}
"""


# ------------------------------------------------------------------------------ resources
## A flame-shaped sprite: a soft teardrop, broad at the bottom, licked into a point at the top.
static func flame_texture() -> Texture2D:
	if _flame_tex != null:
		return _flame_tex
	var n := 64
	var img := Image.create(n, n, false, Image.FORMAT_RGBA8)
	for py in n:
		for px in n:
			var u := (float(px) + 0.5) / n * 2.0 - 1.0          # -1..1 across
			var v := (float(py) + 0.5) / n                       # 0 top .. 1 bottom
			var h := 1.0 - v                                     # 0 bottom .. 1 top
			# a soft tongue of flame: round and broad low down, rounding off (not a spike) at the top
			var half := 0.78 * pow(maxf(0.0, 1.0 - h), 0.35) * (0.6 + 0.4 * sin(PI * minf(1.0, h * 2.0 + 0.15)))
			var edge := 1.0 - smoothstep(half * 0.05, half + 0.14, absf(u))
			var vert := smoothstep(0.0, 0.3, v) * smoothstep(1.0, 0.62, v)
			var a := clampf(edge * vert, 0.0, 1.0)
			img.set_pixel(px, py, Color(1, 1, 1, a * a * (3.0 - 2.0 * a)))
	_flame_tex = ImageTexture.create_from_image(img)
	return _flame_tex


static func flame_material() -> StandardMaterial3D:
	if _flame_mat == null:
		_flame_mat = StandardMaterial3D.new()
		_flame_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		_flame_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		_flame_mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
		_flame_mat.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
		_flame_mat.vertex_color_use_as_albedo = true
		_flame_mat.albedo_texture = flame_texture()
		_flame_mat.albedo_color = Color(1.3, 1.1, 1.0)
		_flame_mat.disable_receive_shadows = true
	return _flame_mat


static func ember_material() -> StandardMaterial3D:
	if _ember_mat == null:
		_ember_mat = StandardMaterial3D.new()
		_ember_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		_ember_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		_ember_mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
		_ember_mat.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
		_ember_mat.vertex_color_use_as_albedo = true
		_ember_mat.albedo_texture = Fx.radial_texture("ember", Color(1, 1, 1, 1), Color(1, 0.6, 0.2, 0), 32)
		_ember_mat.albedo_color = Color(2.0, 1.5, 1.1)
	return _ember_mat


static func smoke_material() -> StandardMaterial3D:
	if _smoke_mat == null:
		_smoke_mat = StandardMaterial3D.new()
		_smoke_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		_smoke_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		_smoke_mat.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
		_smoke_mat.vertex_color_use_as_albedo = true
		_smoke_mat.albedo_texture = Fx.radial_texture("smoke", Color(1, 1, 1, 1), Color(1, 1, 1, 0), 64)
	return _smoke_mat


static func wall_material(scale_x: float, loop := false) -> ShaderMaterial:
	if _wall_shader == null:
		_wall_shader = Shader.new()
		_wall_shader.code = WALL_SHADER
	var m := ShaderMaterial.new()
	m.shader = _wall_shader
	m.set_shader_parameter("scale_x", scale_x)
	m.set_shader_parameter("loop_x", 1.0 if loop else 0.0)
	m.set_shader_parameter("seed", randf() * 50.0)
	m.render_priority = 2
	return m


static func strip_material(scale_x: float) -> ShaderMaterial:
	if _strip_shader == null:
		_strip_shader = Shader.new()
		_strip_shader.code = STRIP_SHADER
	var m := ShaderMaterial.new()
	m.shader = _strip_shader
	m.set_shader_parameter("scale_x", scale_x)
	m.render_priority = 1
	return m


static func cracks_material() -> ShaderMaterial:
	if _cracks_shader == null:
		_cracks_shader = Shader.new()
		_cracks_shader.code = CRACKS_SHADER
	var m := ShaderMaterial.new()
	m.shader = _cracks_shader
	m.render_priority = 1
	return m


## A flat additive glow for the floor, from a radial gradient (`key` caches it).
static func glow_material(key: String, colors: Array, offsets: Array) -> StandardMaterial3D:
	if _glow_mats.has(key):
		return _glow_mats[key]
	var g := Gradient.new()
	g.offsets = PackedFloat32Array(offsets)
	g.colors = PackedColorArray(colors)
	var t := GradientTexture2D.new()
	t.gradient = g
	t.fill = GradientTexture2D.FILL_RADIAL
	t.fill_from = Vector2(0.5, 0.5)
	t.fill_to = Vector2(1.0, 0.5)
	t.width = 256
	t.height = 256
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	m.albedo_texture = t
	m.disable_receive_shadows = true
	m.render_priority = 1
	_glow_mats[key] = m
	return m


# ------------------------------------------------------------------------------ meshes
## A vertical strip along +X from x0 to x1, `h` tall, standing on the floor (UV.x along it,
## UV.y 0 at the floor and 1 at the top).
static func wall_mesh(x0: float, x1: float, h: float) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var quad := [Vector3(x0, 0, 0), Vector3(x1, 0, 0), Vector3(x1, h, 0), Vector3(x0, h, 0)]
	var uv := [Vector2(0, 0), Vector2(1, 0), Vector2(1, 1), Vector2(0, 1)]
	for i in [0, 1, 2, 0, 2, 3]:
		st.set_uv(uv[i])
		st.add_vertex(quad[i])
	return st.commit()


## A flat strip on the floor along +X, `w` wide (UV.y across it).
static func strip_mesh(x0: float, x1: float, w: float, y := 0.02) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var quad := [Vector3(x0, y, -w * 0.5), Vector3(x1, y, -w * 0.5), Vector3(x1, y, w * 0.5), Vector3(x0, y, w * 0.5)]
	var uv := [Vector2(0, 0), Vector2(1, 0), Vector2(1, 1), Vector2(0, 1)]
	for i in [0, 1, 2, 0, 2, 3]:
		st.set_uv(uv[i])
		st.add_vertex(quad[i])
	return st.commit()


## An open cylinder (a band of fire standing on the floor), radius 1: scale it to size.
static func band_mesh(h: float, segments := 64) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for i in segments:
		var a0 := TAU * float(i) / segments
		var a1 := TAU * float(i + 1) / segments
		var p0 := Vector3(cos(a0), 0, sin(a0))
		var p1 := Vector3(cos(a1), 0, sin(a1))
		var u0 := float(i) / segments
		var u1 := float(i + 1) / segments
		var v := [[p0, Vector2(u0, 0)], [p1, Vector2(u1, 0)], [p1 + Vector3(0, h, 0), Vector2(u1, 1)],
			[p0, Vector2(u0, 0)], [p1 + Vector3(0, h, 0), Vector2(u1, 1)], [p0 + Vector3(0, h, 0), Vector2(u0, 1)]]
		for e in v:
			st.set_uv(e[1])
			st.add_vertex(e[0])
	return st.commit()


## A flat square on the floor, `size` across (for the radial glows).
static func floor_quad(size: float, y := 0.03) -> MeshInstance3D:
	var q := QuadMesh.new()
	q.size = Vector2(size, size)
	q.orientation = PlaneMesh.FACE_Y
	var mi := MeshInstance3D.new()
	mi.mesh = q
	mi.position.y = y
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return mi


# ------------------------------------------------------------------------------ particles
## Loose flames (world-space: they trail behind whatever emits them). `size` is the sprite
## height in metres.
static func flames(amount: int, lifetime: float, size: float) -> CPUParticles3D:
	var p := CPUParticles3D.new()
	p.amount = amount
	p.lifetime = lifetime
	p.local_coords = false
	p.direction = Vector3.UP
	p.spread = 14.0
	p.gravity = Vector3(0, 2.4, 0)
	p.initial_velocity_min = 0.3
	p.initial_velocity_max = 1.1
	p.damping_min = 0.4
	p.damping_max = 1.4
	p.angle_min = -25.0
	p.angle_max = 25.0
	p.scale_amount_min = 0.55
	p.scale_amount_max = 1.1
	p.scale_amount_curve = Fx._curve([Vector2(0.0, 0.35), Vector2(0.22, 1.0), Vector2(1.0, 0.12)])
	var q := QuadMesh.new()
	q.size = Vector2(size * 0.74, size)
	p.mesh = q
	p.material_override = flame_material()
	p.color_ramp = Fx._ramp([Color(1.0, 0.85, 0.55, 0.85), Color(1.0, 0.5, 0.12, 0.8), Color(0.8, 0.18, 0.03, 0.45),
		Color(0.25, 0.03, 0.01, 0.0)], [0.0, 0.2, 0.55, 1.0])
	p.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return p


static func embers(amount: int, lifetime: float) -> CPUParticles3D:
	var p := CPUParticles3D.new()
	p.amount = amount
	p.lifetime = lifetime
	p.local_coords = false
	p.direction = Vector3.UP
	p.spread = 35.0
	p.gravity = Vector3(0, 1.2, 0)
	p.initial_velocity_min = 0.4
	p.initial_velocity_max = 1.8
	p.damping_min = 0.2
	p.damping_max = 1.0
	p.scale_amount_min = 0.5
	p.scale_amount_max = 1.0
	var q := QuadMesh.new()
	q.size = Vector2(0.045, 0.045)
	p.mesh = q
	p.material_override = ember_material()
	p.color_ramp = Fx._ramp([Color(1.0, 0.8, 0.4, 1.0), Color(1.0, 0.4, 0.08, 0.9), Color(0.6, 0.1, 0.02, 0.0)], [0.0, 0.5, 1.0])
	p.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return p


## One-shot fire burst: a puff of flame, embers and a flash of light. `scale` ~1 for a person-
## sized burst (a burn, your sword glancing off his burning body).
static func burst(parent: Node, pos: Vector3, scale := 1.0) -> void:
	if parent == null or not parent.is_inside_tree():
		return
	var f := flames(int(22 * scale) + 6, 0.5, 0.55 * scale)
	f.one_shot = true
	f.explosiveness = 0.85
	f.emission_shape = CPUParticles3D.EMISSION_SHAPE_SPHERE
	f.emission_sphere_radius = 0.18 * scale
	f.spread = 70.0
	f.initial_velocity_min = 0.8
	f.initial_velocity_max = 2.6 * scale
	Fx._emit_at(parent, f, pos)
	Fx._free_later(f, 1.0)
	var e := embers(int(20 * scale) + 4, 0.8)
	e.one_shot = true
	e.explosiveness = 0.9
	e.spread = 80.0
	e.initial_velocity_max = 3.5 * scale
	e.gravity = Vector3(0, -2.0, 0)
	Fx._emit_at(parent, e, pos)
	Fx._free_later(e, 1.3)
	Fx.light_pulse(parent, pos + Vector3(0, 0.2, 0), Color(1.0, 0.5, 0.15), 1.8 * scale, 4.0 * scale, 0.35)


static func smoke(parent: Node, pos: Vector3, amount := 10, size := 0.6) -> void:
	if parent == null or not parent.is_inside_tree():
		return
	var p := CPUParticles3D.new()
	p.one_shot = true
	p.explosiveness = 0.5
	p.amount = amount
	p.lifetime = 1.8
	p.local_coords = false
	p.emission_shape = CPUParticles3D.EMISSION_SHAPE_SPHERE
	p.emission_sphere_radius = 0.15
	p.direction = Vector3.UP
	p.spread = 25.0
	p.gravity = Vector3(0, 0.7, 0)
	p.initial_velocity_min = 0.3
	p.initial_velocity_max = 0.9
	p.damping_min = 0.3
	p.damping_max = 0.8
	p.scale_amount_min = 0.8
	p.scale_amount_max = 1.4
	p.scale_amount_curve = Fx._curve([Vector2(0, 0.4), Vector2(0.3, 1.0), Vector2(1, 1.8)])
	var q := QuadMesh.new()
	q.size = Vector2(size, size)
	p.mesh = q
	p.material_override = smoke_material()
	p.color_ramp = Fx._ramp([Color(0.2, 0.18, 0.17, 0.0), Color(0.22, 0.2, 0.19, 0.4), Color(0.3, 0.29, 0.28, 0.0)], [0.0, 0.2, 1.0])
	p.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	Fx._emit_at(parent, p, pos)
	Fx._free_later(p, 2.2)
