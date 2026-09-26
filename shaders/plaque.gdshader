shader_type spatial;
render_mode diffuse_burley, specular_schlick_ggx;
// The torii's plaque (textures/scenery/plaque.png): black lacquer, the border and 月門 in gilt
// (the texture's alpha).

uniform sampler2D plaque_tex : source_color, filter_linear_mipmap_anisotropic;

varying vec2 data;

void vertex() {
	data = UV2;
}

void fragment() {
	vec4 t = texture(plaque_tex, UV);
	ALBEDO = t.rgb * mix(0.6, 1.0, data.x);
	METALLIC = t.a * 0.85;
	ROUGHNESS = mix(0.35, 0.32, t.a);
	SPECULAR = 0.5;
	CLEARCOAT = (1.0 - t.a) * 0.4;
	CLEARCOAT_ROUGHNESS = 0.3;
	EMISSION = t.rgb * t.a * 0.05;   // gilt keeps a glint even out of the light
}
