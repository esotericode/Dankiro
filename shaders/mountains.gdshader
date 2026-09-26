shader_type spatial;
render_mode diffuse_burley, specular_disabled, fog_disabled;
// The ranges round the horizon (models/scenery/backdrop.glb): forest on the lower slopes, rock,
// snow on the far peaks, mist where they rise out of the cloud sea. The scene's fog would bury
// them, so they skip it and fade to the horizon by layer instead (UV2.y: 0 hills, 1 ridges,
// 2 far range): lit colour is scaled down and the haze added as emission.

uniform sampler2D noise_tex : hint_default_white, filter_linear_mipmap, repeat_enable;
uniform vec3 rock_color : source_color = vec3(0.2, 0.2, 0.22);
uniform vec3 forest_color : source_color = vec3(0.05, 0.075, 0.065);
uniform vec3 snow_color : source_color = vec3(0.72, 0.76, 0.84);
uniform vec3 haze_color : source_color = vec3(0.17, 0.18, 0.27);
uniform vec3 haze_amount = vec3(0.35, 0.58, 0.76);   // per layer
uniform float tree_line = 90.0;
uniform float snow_line = 190.0;
uniform vec3 mist_color : source_color = vec3(0.3, 0.32, 0.42);
uniform float mist_top = 12.0;
uniform float mist_bottom = -12.0;

varying vec3 wpos;
varying vec3 wnrm;
varying float layer;

void vertex() {
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	wnrm = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
	layer = UV2.y;
}

void fragment() {
	float n1 = texture(noise_tex, wpos.xz / 900.0).r;
	float n2 = texture(noise_tex, wpos.xz / 120.0 + vec2(wpos.y / 300.0)).g;
	float n3 = texture(noise_tex, vec2(atan(wpos.x, wpos.z) * 40.0, wpos.y / 25.0)).b;
	vec3 n = normalize(wnrm);
	vec3 col = rock_color * (0.75 + 0.5 * n2);
	float forest = smoothstep(tree_line + 60.0 * n1, tree_line - 30.0 + 60.0 * n1, wpos.y)
			* smoothstep(0.35, 0.6, n.y + 0.15 * n3);
	col = mix(col, forest_color * (0.8 + 0.4 * n2), forest);
	float snow = smoothstep(snow_line + 80.0 * (n1 - 0.5), snow_line + 30.0 + 80.0 * (n1 - 0.5), wpos.y)
			* smoothstep(0.25, 0.55, n.y + 0.3 * (n3 - 0.5));
	col = mix(col, snow_color * (0.85 + 0.2 * n2), snow);
	float h = layer < 0.5 ? haze_amount.x : (layer < 1.5 ? haze_amount.y : haze_amount.z);
	h *= mix(1.0, 0.75, smoothstep(0.0, 350.0, wpos.y));      // clearer air up high
	float mist = smoothstep(mist_top, mist_bottom, wpos.y + 12.0 * (n2 - 0.5));
	ALBEDO = col * (1.0 - h) * (1.0 - mist);
	ROUGHNESS = 1.0;
	EMISSION = mix(haze_color * h, mist_color, mist);
}
