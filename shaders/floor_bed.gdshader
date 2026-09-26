shader_type spatial;
render_mode diffuse_burley, specular_schlick_ggx;
// The mortar bed under the flagstones (models/arena_floor.glb): seen in the joints, chipped
// corners and the broken stone's hole. The baked bed AO keeps the narrow joints dark even in
// direct light.

uniform sampler2D stone_albedo : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D stone_data : hint_default_white, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D moss_albedo : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D plaza_a : hint_default_white, filter_linear_mipmap, repeat_disable;  // AO, bed AO, dirt, moss
uniform sampler2D plaza_b : hint_default_black, filter_linear_mipmap, repeat_disable;  // wet, soot, polish, lichen
uniform float map_size = 32.0;
uniform float moss_period = 0.6;
uniform vec3 bed_color : source_color = vec3(0.12, 0.105, 0.088);

varying vec3 wpos;

void vertex() {
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	vec2 muv = wpos.xz / map_size + 0.5;
	vec4 pa = texture(plaza_a, muv);
	vec4 pb = texture(plaza_b, muv);
	// grit: the stone detail at a coarser scale reads as sand and small gravel
	vec3 grit = texture(stone_albedo, wpos.xz * 1.9).rgb * 2.0;
	float lump = texture(stone_data, wpos.xz * 0.7 + vec2(0.3, 0.1)).g;
	vec3 col = bed_color * mix(vec3(1.0), grit, 0.55) * (0.85 + 0.5 * lump);
	vec4 ms = texture(moss_albedo, wpos.xz / moss_period);
	float moss = smoothstep(0.35, 0.6, pa.a * 1.3 + ms.a * 0.4 - 0.2);
	col = mix(col, ms.rgb, moss);
	col *= mix(1.0, 0.5, pb.r);
	float ao = pa.g;
	ALBEDO = col * mix(0.18, 1.0, ao);
	ROUGHNESS = mix(0.95, 0.5, pb.r);
	SPECULAR = 0.3;
	AO = ao;
	AO_LIGHT_AFFECT = 0.8;
}
