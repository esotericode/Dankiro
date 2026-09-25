shader_type sky;
// Night sky for the arena: horizon gradient, a large moon placed at the first directional
// light (LIGHT0_DIRECTION points toward the light), stars and slow drifting clouds.

uniform vec3 zenith_color : source_color = vec3(0.010, 0.015, 0.040);
uniform vec3 horizon_color : source_color = vec3(0.105, 0.115, 0.175);
uniform vec3 ground_color : source_color = vec3(0.015, 0.016, 0.022);
uniform vec3 moon_color : source_color = vec3(1.0, 0.93, 0.80);
uniform float moon_radius = 0.055;
uniform float moon_intensity = 5.0;
uniform float star_amount = 0.0022;
uniform vec3 cloud_color : source_color = vec3(0.07, 0.075, 0.105);

float hash13(vec3 p) {
	p = fract(p * 0.3183099 + vec3(0.71, 0.113, 0.419));
	p *= 17.0;
	return fract(p.x * p.y * p.z * (p.x + p.y + p.z));
}

float noise3(vec3 x) {
	vec3 i = floor(x);
	vec3 f = fract(x);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(mix(hash13(i + vec3(0.0, 0.0, 0.0)), hash13(i + vec3(1.0, 0.0, 0.0)), f.x),
				   mix(hash13(i + vec3(0.0, 1.0, 0.0)), hash13(i + vec3(1.0, 1.0, 0.0)), f.x), f.y),
			   mix(mix(hash13(i + vec3(0.0, 0.0, 1.0)), hash13(i + vec3(1.0, 0.0, 1.0)), f.x),
				   mix(hash13(i + vec3(0.0, 1.0, 1.0)), hash13(i + vec3(1.0, 1.0, 1.0)), f.x), f.y), f.z);
}

float fbm(vec3 p) {
	float v = 0.0;
	float a = 0.5;
	for (int i = 0; i < 5; i++) {
		v += a * noise3(p);
		p = p * 2.03 + vec3(1.7, 9.2, 3.1);
		a *= 0.5;
	}
	return v;
}

void sky() {
	vec3 d = normalize(EYEDIR);
	float h = d.y;
	vec3 col = mix(horizon_color, zenith_color, smoothstep(0.0, 0.6, h));
	col = mix(ground_color, col, smoothstep(-0.06, 0.015, h));

	vec3 moon_dir = LIGHT0_ENABLED ? normalize(LIGHT0_DIRECTION) : normalize(vec3(-0.5, 0.45, -0.7));
	float md = dot(d, moon_dir);
	// Halo + glow around the moon
	col += moon_color * (pow(max(md, 0.0), 900.0) * 0.8 + pow(max(md, 0.0), 60.0) * 0.12 + pow(max(md, 0.0), 8.0) * 0.03);

	// Stars (fade near the horizon and near the moon)
	if (h > 0.0) {
		vec3 cell = floor(d * 380.0);
		float s = hash13(cell);
		float star = step(1.0 - star_amount, s) * (0.4 + 0.6 * hash13(cell + 3.7));
		col += vec3(0.85, 0.9, 1.0) * star * smoothstep(0.02, 0.25, h) * (1.0 - smoothstep(0.96, 0.995, md)) * 1.6;
	}

	// Clouds
	if (h > -0.02) {
		vec2 uv = d.xz / (max(h, 0.0) + 0.18);
		float c = fbm(vec3(uv * 1.1 + vec2(TIME * 0.004, TIME * 0.002), 0.0));
		float cover = smoothstep(0.52, 0.82, c) * smoothstep(-0.02, 0.2, h);
		vec3 lit = cloud_color + moon_color * 0.18 * pow(max(md, 0.0), 6.0);
		col = mix(col, lit, cover * 0.75);
	}

	// Moon disc drawn over the clouds, with a little surface mottling
	float disc = smoothstep(cos(moon_radius), cos(moon_radius * 0.94), md);
	if (disc > 0.0) {
		float mott = fbm(d * 90.0);
		vec3 surf = moon_color * (0.78 + 0.35 * mott);
		col = mix(col, surf * moon_intensity, disc);
	}
	COLOR = col;
}
