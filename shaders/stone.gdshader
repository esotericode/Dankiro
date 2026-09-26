shader_type spatial;
render_mode diffuse_burley, specular_schlick_ggx;
// Stonework and boulders round the plaza (models/scenery/*.glb): the plaza's own stone detail
// (textures/floor/stone_*) projected in object space over a base colour, weathering streaks
// running down, and moss on whatever faces up. UV2.x is baked ambient occlusion.

uniform sampler2D stone_albedo : source_color, filter_linear_mipmap_anisotropic, repeat_enable;  // linear detail, mean 0.5
uniform sampler2D stone_normal : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D moss_albedo : source_color, filter_linear_mipmap, repeat_enable;               // alpha = cushion height
uniform sampler2D grime : hint_default_black, filter_linear_mipmap, repeat_enable;               // R streaks, G wear, B fade
uniform vec3 base_color : source_color = vec3(0.34, 0.33, 0.31);
uniform float detail = 0.55;           // how strongly the stone detail varies the base
uniform float period = 2.4;
uniform float moss_amount = 0.5;       // on faces pointing up
uniform float moss_low = 0.0;          // extra moss toward the ground (below moss_low_height)
uniform float moss_low_height = 0.6;
uniform vec3 moss_tint : source_color = vec3(1.0);
uniform float streaks = 0.5;
uniform float roughness = 0.9;
uniform float normal_depth = 1.0;
instance uniform float seed = 0.0;

varying vec3 opos;
varying vec3 onrm;
varying vec3 wnrm;
varying vec2 data;

void vertex() {
	opos = VERTEX + vec3((seed + UV2.y) * 17.0, 0.0, (seed + UV2.y) * 31.0);
	onrm = NORMAL;
	wnrm = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
	data = UV2;
}

void fragment() {
	vec3 n = normalize(onrm);
	vec3 w = pow(abs(n), vec3(4.0));
	w /= w.x + w.y + w.z;
	vec3 p = opos / period;
	vec3 det = (texture(stone_albedo, p.zy).rgb * w.x + texture(stone_albedo, p.xz).rgb * w.y
			+ texture(stone_albedo, p.xy).rgb * w.z) * 2.0;
	// normal detail from the dominant projection, in its own tangent frame
	vec3 nm;
	if (w.y > max(w.x, w.z)) {
		nm = texture(stone_normal, p.xz).rgb;
	} else if (w.x > w.z) {
		nm = texture(stone_normal, p.zy).rgb;
	} else {
		nm = texture(stone_normal, p.xy).rgb;
	}
	NORMAL_MAP = nm;
	NORMAL_MAP_DEPTH = normal_depth;

	vec3 col = base_color * mix(vec3(1.0), det, detail);
	// rain streaks down the sides, lighter wear on edges
	vec3 g = texture(grime, vec2(p.x + p.z, p.y * 0.5)).rgb;
	float side = 1.0 - abs(n.y);
	col *= 1.0 - streaks * side * smoothstep(0.35, 0.75, g.r) * 0.45;
	// moss on what faces up, and creeping up from the ground
	vec4 moss = texture(moss_albedo, opos.xz * 1.2);
	float up = smoothstep(0.35, 0.9, wnrm.y);
	float low = smoothstep(moss_low_height, 0.0, opos.y) * moss_low;
	float m = clamp((up * moss_amount + low) * (0.55 + 0.9 * moss.a) - 0.3, 0.0, 1.0);
	m = smoothstep(0.1, 0.5, m);
	col = mix(col, moss.rgb * moss_tint, m);
	float ao = data.x;
	ALBEDO = col * mix(0.55, 1.0, ao);
	AO = ao;
	AO_LIGHT_AFFECT = 0.3;
	ROUGHNESS = mix(roughness, 0.95, m);
	SPECULAR = 0.35;
}
