shader_type canvas_item;
// Behind the menus and the full-screen overlays (UiTheme.backdrop): the frame behind, blurred,
// drained of colour and darkened toward ink, a little more at the edges.

uniform sampler2D screen_texture : hint_screen_texture, filter_linear_mipmap;
uniform float blur = 2.0;               // 0 sharp .. 4 very soft (mip level)
uniform float darken = 0.5;             // 0 .. 1 toward `ink`
uniform float desaturate = 0.0;         // 0 .. 1
uniform vec3 ink : source_color = vec3(0.02, 0.02, 0.028);

void fragment() {
	// Twelve taps on a ring round the pixel plus the pixel itself, each read from the (already
	// soft) mip level, so the blur has no blocky steps.
	vec2 step_uv = SCREEN_PIXEL_SIZE * exp2(blur) * 1.2;
	vec3 c = textureLod(screen_texture, SCREEN_UV, blur).rgb * 0.16;
	for (int i = 0; i < 12; i++) {
		float a = float(i) * 0.5235988 + 0.26;
		float r = (i % 2 == 0) ? 1.0 : 1.9;
		c += textureLod(screen_texture, SCREEN_UV + vec2(cos(a), sin(a)) * r * step_uv, blur).rgb * 0.07;
	}
	float luma = dot(c, vec3(0.299, 0.587, 0.114));
	c = mix(c, vec3(luma), desaturate);
	vec2 q = SCREEN_UV - 0.5;
	float edge = smoothstep(0.2, 0.75, length(q * vec2(1.0, 0.8)));
	c = mix(c, ink, clamp(darken + edge * 0.25 * darken, 0.0, 1.0));
	COLOR = vec4(c, COLOR.a);
}
