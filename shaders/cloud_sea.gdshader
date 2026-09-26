shader_type spatial;
render_mode diffuse_burley, specular_disabled, fog_disabled, depth_draw_never, cull_disabled;
// The sea of cloud below the summit: a wide plane whose billows are layered noise, drifting.
// Lit by the moon like anything else; faded into the horizon haze with distance, and softened
// where it meets the hills rising through it.

uniform sampler2D noise_tex : hint_default_white, filter_linear_mipmap, repeat_enable;
uniform sampler2D depth_tex : hint_depth_texture, filter_linear_mipmap;
uniform vec3 top_color : source_color = vec3(0.62, 0.65, 0.76);
uniform vec3 trough_color : source_color = vec3(0.22, 0.24, 0.33);
uniform vec3 haze_color : source_color = vec3(0.17, 0.18, 0.27);
uniform float scale = 90.0;
uniform float drift = 1.2;          // m/s
uniform float soft = 10.0;          // metres of soft contact
uniform float haze_far = 1600.0;
uniform float edge = 2300.0;        // fades out before the plane ends

varying vec3 wpos;

float billows(vec2 p, float t) {
	float a = texture(noise_tex, p / (scale * 5.0) + vec2(t * 0.00012, t * 0.00005)).r;
	float b = texture(noise_tex, p / scale + vec2(-t * 0.0006, t * 0.0003)).r;
	float c = texture(noise_tex, p / (scale * 0.3) + vec2(t * 0.0015, -t * 0.001)).g;
	return a * 0.55 + b * 0.33 + c * 0.12;
}

void vertex() {
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	float t = TIME * drift;
	vec2 p = wpos.xz;
	float h0 = billows(p, t);
	float e = 2.0;
	float hx = billows(p + vec2(e, 0.0), t);
	float hz = billows(p + vec2(0.0, e), t);
	vec3 nw = normalize(vec3(-(hx - h0) / e * 40.0, 1.0, -(hz - h0) / e * 40.0));
	NORMAL = normalize((VIEW_MATRIX * vec4(nw, 0.0)).xyz);
	float dist = length(wpos.xz - CAMERA_POSITION_WORLD.xz);
	float haze = smoothstep(0.0, haze_far, dist) * 0.8;
	vec3 col = mix(trough_color, top_color, smoothstep(0.3, 0.75, h0));
	ALBEDO = col * (1.0 - haze);
	EMISSION = haze_color * haze;
	// soft where hills rise through it, gone at the plane's far edge
	float scene = texture(depth_tex, SCREEN_UV).r;
	vec4 v = INV_PROJECTION_MATRIX * vec4(SCREEN_UV * 2.0 - 1.0, scene, 1.0);
	float scene_z = -v.z / v.w;
	float thick = clamp((scene_z + VERTEX.z) / soft, 0.0, 1.0);
	ALPHA = thick * (1.0 - smoothstep(edge * 0.8, edge, length(wpos.xz))) * smoothstep(0.1, 0.45, h0 + 0.25);
}
