shader_type spatial;
render_mode diffuse_burley, specular_schlick_ggx, alpha_to_coverage;
// The puddle on the settled stones (models/arena_floor.glb). UV is the puddle's outline space
// (length 1 on the modelled outline); the shoreline is cut inside it with noise, so the water
// meets the stones along an irregular edge.
// The sky's radiance carries none of the fog, so a still puddle would mirror a far darker night
// than the hazy one on screen. The shader adds the reflection of that haze itself (a bright
// band at the horizon fading to the dark sky above, by Fresnel); the lanterns and the moon
// streak across the water through the ordinary light specular.

uniform vec3 water_color : source_color = vec3(0.02, 0.022, 0.026);
uniform vec3 horizon_haze : source_color = vec3(0.37, 0.37, 0.5);
uniform vec3 sky_haze : source_color = vec3(0.1, 0.11, 0.17);
uniform float haze_energy = 1.0;
uniform float shore = 0.9;

varying vec3 wpos;

void vertex() {
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

float hash2(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * 0.1031);
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.x + p3.y) * p3.z);
}

float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash2(i), hash2(i + vec2(1.0, 0.0)), f.x), mix(hash2(i + vec2(0.0, 1.0)), hash2(i + vec2(1.0, 1.0)), f.x), f.y);
}

void fragment() {
	vec2 p = wpos.xz;
	float n = vnoise(p * 4.0) * 0.7 + vnoise(p * 11.0) * 0.3;
	float d = length(UV) + (n - 0.5) * 0.18;
	// a soft shoreline, antialiased by alpha to coverage
	ALPHA = smoothstep(shore + 0.012, shore - 0.012, d);
	ALPHA_SCISSOR_THRESHOLD = 0.5;
	ALPHA_ANTIALIASING_EDGE = 0.4;
	// faint wind ripples
	float t = TIME;
	vec2 q = p * 5.0;
	vec2 rip = vec2(sin(q.x * 1.3 + t * 0.9 + sin(q.y * 0.8 + t * 0.3)), cos(q.y * 1.1 - t * 0.7 + sin(q.x * 0.9)));
	rip += vec2(vnoise(p * 11.0 + vec2(t * 0.35, 0.0)), vnoise(p * 11.0 + vec2(0.0, t * 0.3))) * 2.0 - 1.0;
	rip *= 0.015;
	// the haze it mirrors
	vec3 to_eye = normalize((INV_VIEW_MATRIX * vec4(VIEW, 0.0)).xyz);
	vec3 refl = reflect(-to_eye, normalize(vec3(rip.x, 1.0, -rip.y)));
	vec3 env = mix(horizon_haze, sky_haze, smoothstep(0.02, 0.4, refl.y));
	float fresnel = 0.02 + 0.98 * pow(1.0 - clamp(to_eye.y, 0.0, 1.0), 5.0);
	float shallow = smoothstep(shore - 0.25, shore, d);      // thin water over the stone near the shore
	ALBEDO = mix(water_color, water_color * 3.0, shallow);
	EMISSION = env * haze_energy * fresnel * (1.0 - 0.4 * shallow);
	ROUGHNESS = mix(0.09, 0.16, shallow);
	METALLIC = 0.0;
	SPECULAR = 0.35;
	NORMAL_MAP = vec3(rip + 0.5, 1.0);
}
