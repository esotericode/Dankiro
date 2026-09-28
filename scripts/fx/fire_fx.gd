class_name FireFx
extends RefCounted
## Fire for the Twin Fang (his burning staff from phase 2 on, and the Inferno): shaders, materials,
## meshes and one-shot bursts.
##
## Every flame is drawn by a shader rather than a painted sprite, all of them reading one small
## tileable noise texture (textures/fx/fire_noise.png, tools/gen_fx_textures.py):
##  - FLAME_SHADER: a single tongue of flame on an upright camera-facing quad (the particles).
##    A teardrop bent and torn at its tip by noise scrolling up through it; the colour runs from
##    a white-yellow root through orange to red tips. The particle colour carries its life:
##    r = heat (1 fresh, cooling), g = brightness, a = opacity.
##  - WALL_SHADER: a wall of flame on a strip or band (the Inferno's arms, the ring round him,
##    the blast): tongues of every height licking up along it.
##  - EMBER_SHADER and SMOKE_SHADER for the sparks and the smoke above big fires.
## All additive fire is HDR: its colours stay near 1.0 so the glow blooms it without blowing it
## out to white.

static var _noise: Texture2D
static var _shaders: Dictionary = {}
static var _mats: Dictionary = {}
static var _glow_mats: Dictionary = {}

const NOISE_PATH := "res://textures/fx/fire_noise.png"

## Upright billboard (keeps the particle's scale): flames always burn upward, whatever the
## emitter is doing.
const _BILLBOARD_Y := """
	mat4 bb = mat4(
		vec4(normalize(cross(vec3(0.0, 1.0, 0.0), INV_VIEW_MATRIX[2].xyz)), 0.0),
		vec4(0.0, 1.0, 0.0, 0.0),
		vec4(normalize(cross(INV_VIEW_MATRIX[0].xyz, vec3(0.0, 1.0, 0.0))), 0.0),
		MODEL_MATRIX[3]);
	MODELVIEW_MATRIX = VIEW_MATRIX * bb * mat4(
		vec4(length(MODEL_MATRIX[0].xyz), 0.0, 0.0, 0.0),
		vec4(0.0, length(MODEL_MATRIX[1].xyz), 0.0, 0.0),
		vec4(0.0, 0.0, length(MODEL_MATRIX[2].xyz), 0.0),
		vec4(0.0, 0.0, 0.0, 1.0));
	MODELVIEW_NORMAL_MATRIX = mat3(MODELVIEW_MATRIX);
"""

## Camera-facing billboard (keeps the particle's scale).
const _BILLBOARD := """
	MODELVIEW_MATRIX = VIEW_MATRIX * mat4(INV_VIEW_MATRIX[0], INV_VIEW_MATRIX[1], INV_VIEW_MATRIX[2],
		MODEL_MATRIX[3]) * mat4(
		vec4(length(MODEL_MATRIX[0].xyz), 0.0, 0.0, 0.0),
		vec4(0.0, length(MODEL_MATRIX[1].xyz), 0.0, 0.0),
		vec4(0.0, 0.0, length(MODEL_MATRIX[2].xyz), 0.0),
		vec4(0.0, 0.0, 0.0, 1.0));
	MODELVIEW_NORMAL_MATRIX = mat3(MODELVIEW_MATRIX);
"""

const FLAME_SHADER := """
shader_type spatial;
render_mode unshaded, blend_add, cull_disabled, depth_draw_never, shadows_disabled, fog_disabled;

uniform sampler2D noise_tex : filter_linear_mipmap, repeat_enable;
uniform float intensity = 1.0;
uniform float speed = 1.0;
uniform vec3 col_core : source_color = vec3(1.0, 0.9, 0.64);
uniform vec3 col_mid : source_color = vec3(1.0, 0.52, 0.13);
uniform vec3 col_edge : source_color = vec3(0.75, 0.15, 0.025);

varying float v_seed;
varying vec4 v_life;

void vertex() {
@BILLBOARD_Y@
	v_seed = fract(float(INSTANCE_ID) * 0.618034 + 0.137);
	v_life = COLOR;
}

void fragment() {
	float h = 1.0 - UV.y;                          // 0 at the root, 1 at the tip
	float x = UV.x * 2.0 - 1.0;
	float t = TIME * speed;
	vec2 s = vec2(v_seed * 7.31, v_seed * 3.17);
	float n1 = texture(noise_tex, vec2(UV.x * 0.5, h * 0.7 - t * 0.85) + s).r;
	float n2 = texture(noise_tex, vec2(UV.x * 1.25, h * 1.5 - t * 2.0) + s.yx).g;
	// bent by the noise, more toward the tip
	float xs = x + ((n1 - 0.5) * 1.15 + (n2 - 0.5) * 0.35) * h;
	float width = 0.74 * pow(max(1.0 - h, 0.0), 0.55);
	float body = 1.0 - smoothstep(width * 0.2, width + 0.05, abs(xs));
	// the tip torn into tongues
	float tip = 1.0 - smoothstep(0.32, 0.95, h + (n2 - 0.5) * 0.65 + (n1 - 0.5) * 0.35);
	float root = smoothstep(0.0, 0.18, h);
	float f = body * tip * root;
	float temp = f * (1.12 - 0.6 * h) * mix(0.45, 1.0, v_life.r);
	vec3 c = mix(col_edge, col_mid, smoothstep(0.06, 0.4, temp));
	c = mix(c, col_core, smoothstep(0.42, 0.86, temp));
	ALBEDO = c * intensity * v_life.g;
	ALPHA = clamp(smoothstep(0.0, 0.3, f) * v_life.a, 0.0, 1.0);
}
"""

const WALL_SHADER := """
shader_type spatial;
render_mode unshaded, blend_add, cull_disabled, depth_draw_never, shadows_disabled, fog_disabled;

uniform sampler2D noise_tex : filter_linear_mipmap, repeat_enable;
uniform float heat = 1.0;          // brightness
uniform float height = 1.0;        // flame height as a fraction of the strip
uniform float alpha_mult = 1.0;
uniform float reveal = 1.0;        // 0..1 along the strip: an arm unrolling / retracting
uniform float scale_x = 16.0;      // metres along UV.x (keeps the flames the same size)
uniform float wall_h = 1.0;        // metres from UV.y 0 to 1
uniform float speed = 1.0;
uniform float seed = 0.0;
uniform float loop_x = 0.0;        // 1 for a closed band (ring, blast): no seam, no end fade
uniform vec3 col_core : source_color = vec3(1.0, 0.88, 0.6);
uniform vec3 col_mid : source_color = vec3(1.0, 0.48, 0.11);
uniform vec3 col_edge : source_color = vec3(0.7, 0.13, 0.02);

float flame(vec2 m, float t) {
	// tongues of every height: a slow swell along the wall sets how tall the fire licks
	float swell = texture(noise_tex, vec2(m.x * 0.06 + seed, t * 0.05)).r;
	float top = wall_h * height * (0.45 + 0.8 * swell);
	float n1 = texture(noise_tex, vec2(m.x * 0.23 + seed * 0.37, m.y * 0.42 - t * 0.55)).r;
	float n2 = texture(noise_tex, vec2(m.x * 0.61 - seed * 0.21, m.y * 1.05 - t * 1.35)).g;
	float wisp = texture(noise_tex, vec2(m.x * 0.37 + seed * 0.11, m.y * 0.6 - t * 0.9)).b;
	return 1.0 - m.y / top + (n1 - 0.5) * 1.05 + (n2 - 0.5) * 0.5 + wisp * 0.18;
}

void fragment() {
	vec2 m = vec2(UV.x * scale_x, UV.y * wall_h);
	float t = TIME * speed;
	float f = flame(m, t);
	if (loop_x > 0.5) {
		// blend into the flames from the other end over the last stretch: a seamless loop
		f = mix(f, flame(m - vec2(scale_x, 0.0), t), smoothstep(0.85, 1.0, UV.x));
	}
	float a = smoothstep(0.0, 0.32, f);
	float temp = f * (1.05 - 0.45 * UV.y);
	vec3 c = mix(col_edge, col_mid, smoothstep(0.05, 0.42, temp));
	c = mix(c, col_core, smoothstep(0.45, 0.95, temp));
	float ends = 1.0;
	if (loop_x < 0.5) {
		ends = smoothstep(0.0, 0.012, UV.x) * (1.0 - smoothstep(reveal - 0.025, reveal, UV.x));
	}
	ALBEDO = c * heat;
	ALPHA = clamp(a * alpha_mult * ends * 0.9, 0.0, 1.0);
}
"""

## A burning line on the floor (under each arm): a bed of hot coals, brightest along the middle.
const STRIP_SHADER := """
shader_type spatial;
render_mode unshaded, blend_add, cull_disabled, depth_draw_never, shadows_disabled, fog_disabled;

uniform sampler2D noise_tex : filter_linear_mipmap, repeat_enable;
uniform float heat = 1.0;
uniform float alpha_mult = 1.0;
uniform float reveal = 1.0;
uniform float scale_x = 16.0;
uniform vec3 core : source_color = vec3(1.0, 0.72, 0.36);
uniform vec3 body : source_color = vec3(0.9, 0.22, 0.03);

void fragment() {
	float d = abs(UV.y - 0.5) * 2.0;
	float x = UV.x * scale_x;
	float n = texture(noise_tex, vec2(x * 0.45 - TIME * 0.25, UV.y * 0.35)).g * 0.6
		+ texture(noise_tex, vec2(x * 1.1 + TIME * 0.4, UV.y * 0.8 + 0.3)).r * 0.4;
	float f = (1.0 - d) * (0.5 + 0.8 * n);
	float ends = smoothstep(0.0, 0.012, UV.x) * (1.0 - smoothstep(reveal - 0.025, reveal, UV.x));
	ALBEDO = mix(body, core, smoothstep(0.55, 1.0, f)) * heat;
	ALPHA = clamp(smoothstep(0.18, 0.65, f) * alpha_mult * ends, 0.0, 1.0);
}
"""

const EMBER_SHADER := """
shader_type spatial;
render_mode unshaded, blend_add, cull_disabled, depth_draw_never, shadows_disabled, fog_disabled;

uniform float intensity = 1.2;

varying float v_seed;
varying vec4 v_life;

void vertex() {
@BILLBOARD@
	v_seed = fract(float(INSTANCE_ID) * 0.618034 + 0.41);
	v_life = COLOR;
}

void fragment() {
	vec2 p = UV * 2.0 - 1.0;
	float d = dot(p, p);
	float core = exp(-d * 10.0);
	float halo = exp(-d * 2.5) * 0.35;
	float flicker = 0.65 + 0.35 * sin(TIME * (19.0 + v_seed * 23.0) + v_seed * 40.0);
	vec3 c = mix(vec3(1.0, 0.32, 0.05), vec3(1.0, 0.82, 0.48), core * v_life.r);
	ALBEDO = c * intensity * flicker * v_life.g;
	ALPHA = clamp((core + halo) * v_life.a, 0.0, 1.0);
}
"""

## Smoke above big fires: soft dark puffs, their edges eaten by the noise's cells.
const SMOKE_SHADER := """
shader_type spatial;
render_mode unshaded, blend_mix, cull_disabled, depth_draw_never, shadows_disabled;

uniform sampler2D noise_tex : filter_linear_mipmap, repeat_enable;
uniform vec3 smoke_color : source_color = vec3(0.06, 0.055, 0.05);

varying float v_seed;
varying vec4 v_life;

void vertex() {
@BILLBOARD@
	v_seed = fract(float(INSTANCE_ID) * 0.618034 + 0.73);
	v_life = COLOR;
}

void fragment() {
	vec2 p = UV * 2.0 - 1.0;
	float n = texture(noise_tex, UV * 0.45 + vec2(v_seed * 5.3, v_seed * 2.9 - TIME * 0.04)).a;
	float puff = 1.0 - smoothstep(0.35, 1.0, length(p) + (0.5 - n) * 0.7);
	ALBEDO = smoke_color * (0.7 + 0.6 * n) * v_life.r;
	ALPHA = clamp(puff * v_life.a, 0.0, 1.0);
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
	// jagged spokes: the angle zig-zags with distance so they split the stone like cracks
	float zig = 0.35 * sin(r * 31.0 + a * 5.0) + 0.2 * sin(r * 67.0 - a * 3.0);
	float spoke = pow(abs(sin(a * 9.0 + zig)), 40.0) * smoothstep(0.05, 0.25, r);
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
static func noise_texture() -> Texture2D:
	if _noise == null:
		_noise = load(NOISE_PATH) as Texture2D
	return _noise


static func _shader(key: String, code: String) -> Shader:
	if not _shaders.has(key):
		var sh := Shader.new()
		sh.code = code.replace("@BILLBOARD_Y@", _BILLBOARD_Y).replace("@BILLBOARD@", _BILLBOARD)
		_shaders[key] = sh
	return _shaders[key]


static func _material(key: String, code: String, params := {}, priority := 0) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = _shader(key, code)
	if code.contains("noise_tex"):
		m.set_shader_parameter("noise_tex", noise_texture())
	for k in params:
		m.set_shader_parameter(k, params[k])
	m.render_priority = priority
	return m


## Shared flame material (particles carry heat, brightness and opacity in their colour).
static func flame_material() -> ShaderMaterial:
	if not _mats.has("flame"):
		_mats["flame"] = _material("flame", FLAME_SHADER, {}, 3)
	return _mats["flame"]


static func ember_material() -> ShaderMaterial:
	if not _mats.has("ember"):
		_mats["ember"] = _material("ember", EMBER_SHADER, {}, 4)
	return _mats["ember"]


static func smoke_material() -> ShaderMaterial:
	if not _mats.has("smoke"):
		_mats["smoke"] = _material("smoke", SMOKE_SHADER)
	return _mats["smoke"]


static func wall_material(scale_x: float, loop := false, wall_h := 1.0) -> ShaderMaterial:
	return _material("wall", WALL_SHADER, {"scale_x": scale_x, "loop_x": 1.0 if loop else 0.0, "wall_h": wall_h,
		"seed": randf() * 50.0}, 2)


static func strip_material(scale_x: float) -> ShaderMaterial:
	return _material("strip", STRIP_SHADER, {"scale_x": scale_x}, 1)


static func cracks_material() -> ShaderMaterial:
	return _material("cracks", CRACKS_SHADER, {}, 1)


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
## Loose flames (world-space: they trail behind whatever emits them). `size` is the flame's
## height in metres. Set `color` to (heat, brightness, 1, opacity) to damp them.
static func flames(amount: int, lifetime: float, size: float) -> CPUParticles3D:
	var p := CPUParticles3D.new()
	p.amount = amount
	p.lifetime = lifetime
	p.local_coords = false
	p.direction = Vector3.UP
	p.spread = 12.0
	p.gravity = Vector3(0, 2.2, 0)
	p.initial_velocity_min = 0.25
	p.initial_velocity_max = 0.9
	p.damping_min = 0.4
	p.damping_max = 1.4
	p.scale_amount_min = 0.6
	p.scale_amount_max = 1.1
	p.scale_amount_curve = Fx._curve([Vector2(0.0, 0.45), Vector2(0.25, 1.0), Vector2(1.0, 0.55)])
	var q := QuadMesh.new()
	q.size = Vector2(size * 0.62, size)
	q.center_offset = Vector3(0, size * 0.32, 0)       # the root sits on the emission point
	p.mesh = q
	p.material_override = flame_material()
	# life in the colour: r heat (cooling), g brightness, a opacity
	p.color_ramp = Fx._ramp([Color(1.0, 1.0, 1.0, 0.0), Color(1.0, 1.0, 1.0, 1.0), Color(0.72, 1.0, 1.0, 0.85),
		Color(0.28, 1.0, 1.0, 0.0)], [0.0, 0.12, 0.5, 1.0])
	p.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return p


static func embers(amount: int, lifetime: float) -> CPUParticles3D:
	var p := CPUParticles3D.new()
	p.amount = amount
	p.lifetime = lifetime
	p.local_coords = false
	p.direction = Vector3.UP
	p.spread = 35.0
	p.gravity = Vector3(0, 1.1, 0)
	p.initial_velocity_min = 0.4
	p.initial_velocity_max = 1.8
	p.damping_min = 0.2
	p.damping_max = 1.0
	p.tangential_accel_min = -1.5
	p.tangential_accel_max = 1.5
	p.scale_amount_min = 0.4
	p.scale_amount_max = 1.0
	var q := QuadMesh.new()
	q.size = Vector2(0.05, 0.05)
	p.mesh = q
	p.material_override = ember_material()
	p.color_ramp = Fx._ramp([Color(1.0, 1.0, 1.0, 1.0), Color(0.6, 1.0, 1.0, 0.9), Color(0.1, 1.0, 1.0, 0.0)], [0.0, 0.5, 1.0])
	p.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return p


## Smoke rising off a fire (world-space): dark puffs that swell and thin out.
static func smoke_emitter(amount: int, lifetime: float, size: float) -> CPUParticles3D:
	var p := CPUParticles3D.new()
	p.amount = amount
	p.lifetime = lifetime
	p.local_coords = false
	p.direction = Vector3.UP
	p.spread = 20.0
	p.gravity = Vector3(0, 0.8, 0)
	p.initial_velocity_min = 0.3
	p.initial_velocity_max = 0.8
	p.damping_min = 0.3
	p.damping_max = 0.8
	p.scale_amount_min = 0.8
	p.scale_amount_max = 1.3
	p.scale_amount_curve = Fx._curve([Vector2(0, 0.45), Vector2(0.35, 1.0), Vector2(1, 1.9)])
	var q := QuadMesh.new()
	q.size = Vector2(size, size)
	p.mesh = q
	p.material_override = smoke_material()
	p.color_ramp = Fx._ramp([Color(1.0, 1.0, 1.0, 0.0), Color(1.0, 1.0, 1.0, 0.32), Color(1.3, 1.0, 1.0, 0.0)], [0.0, 0.25, 1.0])
	p.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return p


## One-shot fire burst: a puff of flame, embers and a flash of light. `scale` ~1 for a person-
## sized burst (a burn, your sword glancing off his burning body).
static func burst(parent: Node, pos: Vector3, scale := 1.0) -> void:
	if parent == null or not parent.is_inside_tree():
		return
	var f := flames(int(18 * scale) + 6, 0.5, 0.6 * scale)
	f.one_shot = true
	f.explosiveness = 0.85
	f.emission_shape = CPUParticles3D.EMISSION_SHAPE_SPHERE
	f.emission_sphere_radius = 0.2 * scale
	f.spread = 70.0
	f.initial_velocity_min = 0.6
	f.initial_velocity_max = 2.2 * scale
	Fx._emit_at(parent, f, pos)
	Fx._free_later(f, 1.0)
	var e := embers(int(18 * scale) + 4, 0.8)
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
	var p := smoke_emitter(amount, 1.8, size)
	p.one_shot = true
	p.explosiveness = 0.5
	p.emission_shape = CPUParticles3D.EMISSION_SHAPE_SPHERE
	p.emission_sphere_radius = 0.15
	Fx._emit_at(parent, p, pos)
	Fx._free_later(p, 2.2)
