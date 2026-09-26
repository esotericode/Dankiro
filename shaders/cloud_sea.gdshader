shader_type spatial;
render_mode diffuse_burley, specular_disabled, depth_draw_never, cull_disabled;
// The sea of cloud below the summit: a wide plane whose billows are layered noise, drifting.
// Lit by the moon and fogged like anything else, soft where hills rise through it, and gone
// before the plane ends (the sky below the horizon carries on in the same haze).

uniform sampler2D noise_tex : hint_default_white, filter_linear_mipmap, repeat_enable;
uniform sampler2D depth_tex : hint_depth_texture, filter_linear_mipmap;
uniform vec3 top_color : source_color = vec3(0.34, 0.36, 0.45);
uniform vec3 trough_color : source_color = vec3(0.13, 0.14, 0.2);
uniform float scale = 150.0;
uniform float drift = 1.2;          // m/s
uniform float soft = 10.0;          // metres of soft contact
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
	ALBEDO = mix(trough_color, top_color, smoothstep(0.3, 0.75, h0));
	// soft where hills rise through it, gone at the plane's far edge
	float scene = texture(depth_tex, SCREEN_UV).r;
	vec4 v = INV_PROJECTION_MATRIX * vec4(SCREEN_UV * 2.0 - 1.0, scene, 1.0);
	float scene_z = -v.z / v.w;
	float thick = clamp((scene_z + VERTEX.z) / soft, 0.0, 1.0);
	// thin in the troughs, so the valley shows through between the billows
	ALPHA = thick * (1.0 - smoothstep(edge * 0.6, edge, length(wpos.xz))) * smoothstep(0.2, 0.7, h0) * 0.85;
}
