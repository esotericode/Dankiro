shader_type spatial;
render_mode diffuse_burley, specular_schlick_ggx;
// Painted and bare timber, plaster, rope (models/scenery/*.glb): a colour or a texture (UV in
// metres), weathered with textures/scenery/grime.png - rain streaks running down in world space,
// paint worn through to what's under it, sun-fade - and the baked ambient occlusion in UV2.x.

uniform sampler2D albedo_tex : source_color, hint_default_white, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D normal_tex : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D grime : hint_default_black, filter_linear_mipmap, repeat_enable;   // R streaks, G wear, B fade
uniform bool textured = false;
uniform bool use_normal = false;
uniform vec2 period = vec2(1.0, 1.0);
uniform vec3 color : source_color = vec3(0.5);
uniform vec3 under_color : source_color = vec3(0.06, 0.045, 0.035);   // shows where paint wore off
uniform vec3 fade_color : source_color = vec3(1.0);                    // sun-bleached tint
uniform float wear = 0.25;
uniform float fade = 0.3;
uniform float dirt = 0.45;
uniform float grime_period = 1.6;
uniform float roughness = 0.55;
uniform float specular = 0.5;
uniform float coat = 0.0;            // lacquer's clear coat
uniform float emission_energy = 0.0; // paper lit from behind
uniform vec3 emission_color : source_color = vec3(1.0, 0.62, 0.32);

varying vec2 data;
varying vec3 wpos;

void vertex() {
	data = UV2;
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	vec3 base = color;
	if (textured) {
		base *= texture(albedo_tex, UV / period).rgb;
	}
	if (use_normal) {
		NORMAL_MAP = texture(normal_tex, UV / period).rgb;
	}
	vec3 g = texture(grime, UV / grime_period).rgb;
	// rain streaks follow gravity whatever way the timber runs
	float s = texture(grime, vec2((wpos.x + wpos.z) / grime_period, wpos.y / (grime_period * 2.5))).r;
	float streak = smoothstep(0.45, 0.8, s) * dirt;
	float worn = smoothstep(0.62, 0.8, g.g) * wear;
	base = mix(base, base * fade_color, smoothstep(0.35, 0.75, g.b) * fade);
	base = mix(base, under_color, worn);
	base *= 1.0 - 0.55 * streak;
	float ao = data.x;
	ALBEDO = base * mix(0.55, 1.0, ao);
	AO = ao;
	AO_LIGHT_AFFECT = 0.3;
	ROUGHNESS = clamp(roughness + streak * 0.25 + worn * 0.3, 0.0, 1.0);
	SPECULAR = specular;
	CLEARCOAT = coat * (1.0 - worn) * (1.0 - streak);
	CLEARCOAT_ROUGHNESS = 0.35;
	EMISSION = emission_color * emission_energy;
}
