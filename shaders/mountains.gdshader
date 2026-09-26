shader_type spatial;
render_mode blend_mix, depth_draw_always, cull_back, diffuse_burley, specular_disabled, fog_disabled;
// The ranges round the horizon (models/scenery/backdrop.glb): forest on the lower slopes, rock,
// snow on the high peaks, and mist where they rise out of the cloud sea. The scene's fog would
// bury them at this distance, so they skip it and let the sky behind show through instead: the
// farther the range, the more (`haze`), so their colour always matches the sky they fade into.
// Each range is its own material, drawn farthest first (render_priority).

uniform sampler2D noise_tex : hint_default_white, filter_linear_mipmap, repeat_enable;
uniform vec3 rock_color : source_color = vec3(0.2, 0.2, 0.22);
uniform vec3 forest_color : source_color = vec3(0.05, 0.075, 0.065);
uniform vec3 snow_color : source_color = vec3(0.72, 0.76, 0.84);
uniform float haze = 0.5;             // how much of the sky shows through
uniform vec3 inscatter : source_color = vec3(0.1, 0.11, 0.17);   // the glow of the air in front of them
uniform float tree_line = 90.0;
uniform float snow_line = 190.0;
uniform float mist_top = -8.0;         // they fade into the cloud sea below this height
uniform float mist_bottom = -30.0;

varying vec3 wpos;
varying vec3 wnrm;

void vertex() {
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	wnrm = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
}

void fragment() {
	float n1 = texture(noise_tex, wpos.xz / 900.0).r;
	float n2 = texture(noise_tex, wpos.xz / 120.0 + vec2(wpos.y / 300.0)).g;
	float n3 = texture(noise_tex, wpos.xz / 45.0 + vec2(0.0, wpos.y / 60.0)).b;
	vec3 n = normalize(wnrm);
	float strata = texture(noise_tex, vec2(wpos.x / 700.0 + wpos.z / 900.0, wpos.y / 38.0)).g;
	vec3 col = rock_color * (0.7 + 0.45 * n2) * (0.8 + 0.4 * strata);     // ledges and bands in the rock
	float forest = smoothstep(tree_line + 60.0 * n1, tree_line - 30.0 + 60.0 * n1, wpos.y)
			* smoothstep(0.35, 0.6, n.y + 0.15 * n3);
	col = mix(col, forest_color * (0.8 + 0.4 * n2), forest);
	float snow = smoothstep(snow_line + 80.0 * (n1 - 0.5), snow_line + 30.0 + 80.0 * (n1 - 0.5), wpos.y)
			* smoothstep(0.05, 0.3, n.y + 0.25 * (strata - 0.5));   // it clings even to steep faces up there
	col = mix(col, snow_color * (0.85 + 0.2 * n2), snow);
	float h = haze * mix(1.0, 0.8, smoothstep(0.0, 350.0, wpos.y));      // clearer air up high
	float mist = smoothstep(mist_bottom, mist_top, wpos.y + 10.0 * (n2 - 0.5));
	ALBEDO = col;
	ROUGHNESS = 1.0;
	EMISSION = inscatter;
	ALPHA = (1.0 - h) * mist;
}
