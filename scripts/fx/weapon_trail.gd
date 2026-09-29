class_name WeaponTrail
extends MeshInstance3D
## Swing trail drawn in world space: a ribbon over the outer part of the blade, shaded by
## TRAIL_SHADER. Its brightest part is a crisp line along the path of the tip; behind that the
## light thins toward the grip and dies away with age, broken into fine streaks by the noise,
## so a slash reads as one quick stroke of light rather than a sheet. Samples are only pushed
## while the tip moves fast (strikes, not idle motion). `style` sets the colours: STEEL (your
## sword: white edge, cold blue behind) or EMBER (his burning blades: white-gold edge, orange,
## red). `force_color` tints perilous attacks red.

enum { STEEL, EMBER }

## UV.x runs along the trail (0 = the oldest sample, 1 = where the blade is now), UV.y across it
## (0 = the inner edge, toward the grip; 1 = the tip's path). COLOR.a carries each sample's
## fade (its age, and how far back along the trail it is).
const TRAIL_SHADER := """
shader_type spatial;
render_mode unshaded, blend_add, cull_disabled, depth_draw_never, shadows_disabled, fog_disabled;

uniform sampler2D noise_tex : filter_linear_mipmap, repeat_enable;
uniform vec3 col_edge : source_color = vec3(1.0, 1.0, 1.0);
uniform vec3 col_body : source_color = vec3(0.45, 0.6, 1.0);
uniform vec3 col_tail : source_color = vec3(0.15, 0.22, 0.6);
uniform float intensity = 1.0;
uniform float seed = 0.0;

varying float v_fade;

void vertex() {
	v_fade = COLOR.a;
}

void fragment() {
	float along = UV.x;
	float across = UV.y;
	// Streaks run with the swing: noise stretched along the trail, fine across it.
	float streak = texture(noise_tex, vec2(along * 0.1 + seed, across * 2.4 + seed * 0.37)).b;
	float edge = smoothstep(0.88, 1.0, across);
	edge *= edge;
	float body = pow(across, 4.0) * (0.05 + 0.95 * streak * streak);
	float k = v_fade;
	vec3 c = mix(col_tail, col_body, smoothstep(0.0, 0.6, k));
	c = mix(c, col_edge, edge * smoothstep(0.15, 0.8, k));
	ALBEDO = c * intensity;
	ALPHA = clamp((body * 0.7 + edge * 1.6) * k, 0.0, 1.0);
}
"""

const PALETTES := {
	STEEL: [Color(1.0, 1.0, 1.0), Color(0.3, 0.42, 0.85), Color(0.08, 0.13, 0.42)],
	EMBER: [Color(1.0, 0.92, 0.7), Color(1.0, 0.45, 0.1), Color(0.7, 0.1, 0.02)],
}

static var _shader: Shader

var source: HumanoidRig
var blade_name := "blade"
var style := STEEL
var max_samples := 18
var min_speed := 4.5          ## m/s of the blade tip before the trail shows
var life := 0.15              ## seconds a sample lives
var inner := 0.3              ## where the ribbon starts along the blade (0 = base, 1 = tip)
var force_color := Color(0, 0, 0, 0)
var active := true            ## false: no new samples (the owner decides when a trail means a strike)
var brightness := 1.25        ## HDR multiplier (the glow pass blooms the edge a little)

var _bases := PackedVector3Array()
var _tips := PackedVector3Array()
var _ages := PackedFloat32Array()
var _starts := PackedInt32Array()   ## 1: this sample starts a stroke (the blade was too slow just before)
var _was_fast := false
var _last_tip := Vector3.ZERO
var _has_last := false
var _im: ImmediateMesh
var _mat: ShaderMaterial
var _tinted := false


func setup(p_source: HumanoidRig, p_blade: String, p_style: int) -> void:
	source = p_source
	blade_name = p_blade
	style = p_style
	top_level = true
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_im = ImmediateMesh.new()
	mesh = _im
	if _shader == null:
		_shader = Shader.new()
		_shader.code = TRAIL_SHADER
	_mat = ShaderMaterial.new()
	_mat.shader = _shader
	_mat.set_shader_parameter("noise_tex", FireFx.noise_texture())
	_mat.set_shader_parameter("seed", float(absi((p_blade + str(p_style)).hash()) % 997) / 997.0)
	_mat.render_priority = 2
	_apply_palette()
	material_override = _mat


func _ready() -> void:
	global_transform = Transform3D.IDENTITY
	_apply_palette()      # `brightness` may have been set after setup()


## The warm-up (Warmup): a short ribbon at `at`, as if the blade had just swept past, so the
## renderer builds the trail's pipelines before the first swing. It fades like any stroke.
func warm_up(at: Vector3) -> void:
	clear_trail()
	for i in 4:
		var p := at + Vector3(0.15 * i - 0.2, 0.0, 0.0)
		_bases.append(p)
		_tips.append(p + Vector3(0.0, 0.45, 0.0))
		_ages.append(0.0)
		_starts.append(1 if i == 0 else 0)
	_draw()


func clear_trail() -> void:
	_bases.clear()
	_tips.clear()
	_ages.clear()
	_starts.clear()
	_has_last = false
	_was_fast = false


func _apply_palette() -> void:
	var pal: Array = PALETTES[style]
	var edge: Color = pal[0]
	var body: Color = pal[1]
	var tail: Color = pal[2]
	if force_color.a > 0.0:
		edge = force_color.lerp(Color.WHITE, 0.55)
		body = force_color
		tail = force_color.darkened(0.55)
	_mat.set_shader_parameter("col_edge", edge)
	_mat.set_shader_parameter("col_body", body)
	_mat.set_shader_parameter("col_tail", tail)
	_mat.set_shader_parameter("intensity", brightness)
	_tinted = force_color.a > 0.0


func _physics_process(delta: float) -> void:
	if source == null or not is_instance_valid(source):
		return
	global_transform = Transform3D.IDENTITY
	if (force_color.a > 0.0) != _tinted:
		_apply_palette()
	for i in _ages.size():
		_ages[i] += delta
	while _ages.size() > 0 and _ages[0] > life:
		_drop_oldest()
	var pts := source.blade_world(blade_name)
	if pts.size() < 2:
		return
	var base := pts[0]
	var tip := pts[pts.size() - 1]
	var spd := 0.0
	if _has_last and delta > 0.0:
		spd = (tip - _last_tip).length() / delta
	_last_tip = tip
	_has_last = true
	var fast := active and spd > min_speed
	if fast:
		_bases.append(base.lerp(tip, inner))
		_tips.append(tip)
		_ages.append(0.0)
		_starts.append(0 if _was_fast else 1)
		if _ages.size() > max_samples:
			_drop_oldest()
	_was_fast = fast
	_draw()


func _drop_oldest() -> void:
	_ages.remove_at(0)
	_bases.remove_at(0)
	_tips.remove_at(0)
	_starts.remove_at(0)


## One ribbon per stroke: samples either side of a moment the blade was too slow to trail are
## never joined (that would stretch one flat quad across the gap).
func _draw() -> void:
	_im.clear_surfaces()
	var n := _ages.size()
	if n < 2:
		return
	var a := 0
	while a < n:
		var b := a + 1
		while b < n and _starts[b] == 0:
			b += 1
		if b - a >= 3:
			_im.surface_begin(Mesh.PRIMITIVE_TRIANGLE_STRIP)
			for i in range(a, b):
				var u := float(i) / float(n - 1)
				var k := _fade(i, u)
				_im.surface_set_color(Color(1, 1, 1, k))
				_im.surface_set_uv(Vector2(u, 0.0))
				_im.surface_add_vertex(_bases[i])
				_im.surface_set_color(Color(1, 1, 1, k))
				_im.surface_set_uv(Vector2(u, 1.0))
				_im.surface_add_vertex(_tips[i])
			_im.surface_end()
		a = b


## A sample's strength: fresh ones and those near the blade are brightest.
func _fade(i: int, along: float) -> float:
	var age := 1.0 - clampf(_ages[i] / life, 0.0, 1.0)
	return pow(age, 1.5) * along
