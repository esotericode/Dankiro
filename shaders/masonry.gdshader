shader_type spatial;
render_mode diffuse_burley, specular_schlick_ggx;
// Dry-laid stone walls (ishigaki) and shrine gravel: a UV-mapped texture (metres / period) whose
// alpha is height - moss and damp gather low in the gaps and toward the ground - plus baked
// ambient occlusion (UV2.x).

uniform sampler2D albedo_tex : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D normal_tex : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D moss_albedo : source_color, filter_linear_mipmap, repeat_enable;
uniform float period = 3.0;
uniform bool world_xz = false;        // project from above (gravel) instead of UV
uniform vec3 tint : source_color = vec3(1.0);
uniform float moss_amount = 0.5;
uniform float damp_height = 0.8;      // darker and mossier toward the foot
uniform float roughness = 0.9;
uniform float normal_depth = 1.0;

varying vec2 data;
varying vec3 wpos;

void vertex() {
	data = UV2;
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	vec2 uv = (world_xz ? wpos.xz : UV) / period;
	vec4 a = texture(albedo_tex, uv);
	NORMAL_MAP = texture(normal_tex, uv).rgb;
	NORMAL_MAP_DEPTH = normal_depth;
	vec3 col = a.rgb * tint;
	float low = smoothstep(damp_height, 0.0, wpos.y);
	col *= 1.0 - 0.3 * low;
	vec4 moss = texture(moss_albedo, uv * period * 1.4);
	float m = clamp((1.0 - a.a) * 1.2 + low * 0.5 - 0.35, 0.0, 1.0) * moss_amount * (0.5 + moss.a);
	m = smoothstep(0.15, 0.55, m);
	col = mix(col, moss.rgb, m);
	float ao = data.x;
	ALBEDO = col * mix(0.5, 1.0, ao);
	AO = ao;
	AO_LIGHT_AFFECT = 0.35;
	ROUGHNESS = roughness;
	SPECULAR = 0.35;
}
