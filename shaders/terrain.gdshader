shader_type spatial;
render_mode diffuse_burley, specular_schlick_ggx;
// The summit round the plaza (models/scenery/backdrop.glb, "terrain"): earth, moss and fallen
// cedar needles on the level, bare rock where the ground falls away. World-space, so it tiles
// seamlessly.

uniform sampler2D stone_albedo : source_color, filter_linear_mipmap_anisotropic, repeat_enable;   // linear detail, mean 0.5
uniform sampler2D stone_normal : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform vec3 moss_color : source_color = vec3(0.075, 0.10, 0.06);
uniform vec3 earth_color : source_color = vec3(0.07, 0.065, 0.055);
uniform vec3 needle_color : source_color = vec3(0.13, 0.085, 0.06);
uniform vec3 rock_color : source_color = vec3(0.23, 0.225, 0.22);
uniform float bump_strength = 0.35;
uniform float rock_period = 3.0;

varying vec3 wpos;
varying vec3 wnrm;

float hash12(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * 0.1031);
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.x + p3.y) * p3.z);
}

float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	float a = hash12(i);
	float b = hash12(i + vec2(1.0, 0.0));
	float c = hash12(i + vec2(0.0, 1.0));
	float d = hash12(i + vec2(1.0, 1.0));
	return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

float fbm(vec2 p) {
	float v = 0.0;
	float a = 0.5;
	for (int i = 0; i < 4; i++) {
		v += a * vnoise(p);
		p = p * 2.07 + vec2(5.3, 1.7);
		a *= 0.5;
	}
	return v;
}

void vertex() {
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	wnrm = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
}

void fragment() {
	vec2 p = wpos.xz;
	// the level: earth and moss, with needle litter drifted under the trees
	vec3 col = mix(earth_color, moss_color, smoothstep(0.4, 0.75, fbm(p * 0.5)));
	col = mix(col, needle_color, smoothstep(0.45, 0.7, fbm(p * 0.13 + 7.0)) * 0.8);
	col *= 0.75 + 0.35 * fbm(p * 3.0);
	float e = 0.02;
	float h0 = fbm(p * 4.0);
	float hx = fbm((p + vec2(e, 0.0)) * 4.0);
	float hz = fbm((p + vec2(0.0, e)) * 4.0);
	vec3 n = normalize(wnrm);
	vec3 bump = normalize(n + vec3(-(hx - h0) / e, 0.0, -(hz - h0) / e) * bump_strength * 0.05);
	// rock where it's steep
	float rock = smoothstep(0.8, 0.55, n.y + 0.15 * (fbm(p * 0.4) - 0.5));
	vec3 w = pow(abs(n), vec3(4.0));
	w /= w.x + w.y + w.z;
	vec3 q = wpos / rock_period;
	vec3 det = (texture(stone_albedo, q.zy).rgb * w.x + texture(stone_albedo, q.xz).rgb * w.y
			+ texture(stone_albedo, q.xy).rgb * w.z) * 2.0;
	vec3 rc = rock_color * det * (0.8 + 0.4 * fbm(wpos.xy * 0.3 + wpos.zy * 0.2));
	col = mix(col, rc, rock);
	NORMAL = normalize((VIEW_MATRIX * vec4(mix(bump, n, rock), 0.0)).xyz);
	ALBEDO = col;
	ROUGHNESS = mix(0.97, 0.9, rock);
	SPECULAR = 0.3;
}
