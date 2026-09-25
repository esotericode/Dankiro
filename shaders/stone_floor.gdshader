shader_type spatial;
render_mode diffuse_burley, specular_schlick_ggx;
// Procedural courtyard floor: concentric rings of flagstones inside `plaza_radius`,
// a heavy curb ring at the edge, mossy earth outside. World-space so it tiles seamlessly.

uniform vec3 stone_a : source_color = vec3(0.34, 0.33, 0.32);
uniform vec3 stone_b : source_color = vec3(0.21, 0.205, 0.20);
uniform vec3 grout_color : source_color = vec3(0.06, 0.058, 0.055);
uniform vec3 moss_color : source_color = vec3(0.075, 0.10, 0.06);
uniform vec3 earth_color : source_color = vec3(0.07, 0.065, 0.055);
uniform float ring_width = 1.3;
uniform float plaza_radius = 15.6;
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

// Returns grout mask (1 in the joint) and writes a per-stone id.
float stones(vec2 p, out vec2 cell) {
	float r = length(p);
	float a = atan(p.y, p.x + 1e-5);
	if (r < ring_width * 1.2) {
		cell = vec2(0.0);
		return 1.0 - smoothstep(0.018, 0.04, abs(r - ring_width * 1.2));
	}
	float ring = floor(r / ring_width);
	float rf = fract(r / ring_width);
	float circ = 6.2831853 * (ring + 0.5) * ring_width;
	float count = max(8.0, floor(circ / 1.55));
	float sfv = (a / 6.2831853 + 0.5) * count + ring * 0.37;
	float seg = floor(sfv);
	float sf = fract(sfv);
	cell = vec2(ring, mod(seg, count));
	float jr = min(rf, 1.0 - rf) * ring_width;
	float ja = min(sf, 1.0 - sf) * circ / count;
	float j = min(jr, ja) + (vnoise(p * 9.0) - 0.5) * 0.012;
	return 1.0 - smoothstep(0.016, 0.042, j);
}

float height_at(vec2 p) {
	vec2 cell;
	float g = stones(p, cell);
	return fbm(p * 5.0) * 0.6 + hash12(cell) * 0.4 - g * 1.2;
}

void fragment() {
	vec2 p = wpos.xz;
	float r = length(p);
	vec2 cell;
	float g = stones(p, cell);
	float h = hash12(cell);
	float n = fbm(p * 1.6) * 0.55 + fbm(p * 6.5) * 0.45;
	vec3 col = mix(stone_a, stone_b, clamp(h * 0.75 + (n - 0.5) * 0.7, 0.0, 1.0));
	col *= 0.9 + 0.2 * fbm(p * 0.35 + 11.0);
	// worn, lighter centre where fights happen
	col *= 1.0 + 0.08 * (1.0 - smoothstep(0.0, 9.0, r));
	col = mix(col, grout_color, g);
	float moss = smoothstep(0.58, 0.82, fbm(p * 0.8 + 17.0)) * (0.35 + 0.65 * g);
	col = mix(col, moss_color, moss * 0.7);
	float rough = mix(0.8, 0.96, g);

	// Curb ring at the edge
	float curb = smoothstep(plaza_radius - 0.75, plaza_radius - 0.7, r) * (1.0 - smoothstep(plaza_radius - 0.02, plaza_radius, r));
	float curb_seg = fract(atan(p.y, p.x + 1e-5) / 6.2831853 * 72.0);
	float curb_joint = 1.0 - smoothstep(0.02, 0.05, min(abs(r - (plaza_radius - 0.72)), (0.5 - abs(curb_seg - 0.5)) * 1.33));
	vec3 curb_col = mix(vec3(0.27, 0.26, 0.25), grout_color, curb_joint) * (0.85 + 0.3 * n);
	col = mix(col, curb_col, curb);

	// Earth + moss outside the plaza
	float outside = smoothstep(plaza_radius, plaza_radius + 0.08, r);
	vec3 earth = mix(earth_color, moss_color, smoothstep(0.4, 0.75, fbm(p * 0.5)));
	earth *= 0.75 + 0.35 * fbm(p * 3.0);
	col = mix(col, earth, outside);
	rough = mix(rough, 0.97, outside);

	// Bump from the height field
	float e = 0.015;
	float h0 = height_at(p);
	float hx = height_at(p + vec2(e, 0.0));
	float hz = height_at(p + vec2(0.0, e));
	vec3 nw = normalize(vec3(-(hx - h0) / e * bump_strength * 0.02, 1.0, -(hz - h0) / e * bump_strength * 0.02));
	NORMAL = normalize((VIEW_MATRIX * vec4(nw, 0.0)).xyz);

	ALBEDO = col;
	ROUGHNESS = rough;
	SPECULAR = 0.35;
}
