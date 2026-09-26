shader_type spatial;
render_mode diffuse_burley, specular_schlick_ggx;
// Copper roofing gone green (textures/scenery/copper*.jpg): standing seams and courses, dark
// streaks washing down the slope, and baked ambient occlusion (UV2.x). UV in metres, v up the slope.

uniform sampler2D copper_albedo : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D copper_normal : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D grime : hint_default_black, filter_linear_mipmap, repeat_enable;
uniform float period = 1.0;
uniform vec3 tint : source_color = vec3(1.0);
uniform float streaks = 0.5;

varying vec2 data;

void vertex() {
	data = UV2;
}

void fragment() {
	vec2 uv = UV / period;
	vec3 col = texture(copper_albedo, uv).rgb * tint;
	NORMAL_MAP = texture(copper_normal, uv).rgb;
	float s = texture(grime, vec2(uv.x * 0.7, uv.y * 0.18)).r;
	col *= 1.0 - streaks * smoothstep(0.45, 0.8, s) * 0.6;
	float ao = data.x;
	ALBEDO = col * mix(0.5, 1.0, ao);
	AO = ao;
	AO_LIGHT_AFFECT = 0.3;
	ROUGHNESS = 0.62;
	METALLIC = 0.15;
	SPECULAR = 0.5;
}
