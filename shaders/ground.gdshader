shader_type spatial;
render_mode diffuse_burley, specular_schlick_ggx;
// Earth and moss around the flagstone plaza (the plaza itself is models/arena_floor.glb).
// World-space, so it tiles seamlessly.

uniform vec3 moss_color : source_color = vec3(0.075, 0.10, 0.06);
uniform vec3 earth_color : source_color = vec3(0.07, 0.065, 0.055);
uniform float bump_strength = 0.35;

varying vec3 wpos;

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
}

void fragment() {
	vec2 p = wpos.xz;
	vec3 col = mix(earth_color, moss_color, smoothstep(0.4, 0.75, fbm(p * 0.5)));
	col *= 0.75 + 0.35 * fbm(p * 3.0);
	float e = 0.02;
	float h0 = fbm(p * 4.0);
	float hx = fbm((p + vec2(e, 0.0)) * 4.0);
	float hz = fbm((p + vec2(0.0, e)) * 4.0);
	vec3 nw = normalize(vec3(-(hx - h0) / e * bump_strength * 0.05, 1.0, -(hz - h0) / e * bump_strength * 0.05));
	NORMAL = normalize((VIEW_MATRIX * vec4(nw, 0.0)).xyz);
	ALBEDO = col;
	ROUGHNESS = 0.97;
	SPECULAR = 0.3;
}
