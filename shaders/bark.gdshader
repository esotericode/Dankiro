shader_type spatial;
render_mode diffuse_burley, specular_schlick_ggx;
// Trunks and limbs (models/scenery/trees.glb). UV runs round the trunk and up it in metres
// (a whole number of tiles round); UV2.x is baked ambient occlusion. Moss and damp creep up from
// the roots on the shaded side.

#include "res://shaders/near_fade.gdshaderinc"

uniform sampler2D bark_albedo : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D bark_normal : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D moss_albedo : source_color, filter_linear_mipmap, repeat_enable;
uniform vec2 period = vec2(1.0, 2.0);     // metres round, metres up per tile
uniform vec3 tint : source_color = vec3(1.0);
uniform float brightness = 1.0;
uniform float moss_height = 2.5;
uniform float moss_amount = 0.6;
uniform vec3 moss_dir = vec3(0.2, 0.0, 1.0);   // the side that stays damp
instance uniform vec3 tree_tint : source_color = vec3(1.0);

varying vec2 data;
varying vec3 opos;
varying vec3 onrm;

void vertex() {
	data = UV2;
	opos = VERTEX;
	onrm = NORMAL;
}

void fragment() {
	if (near_fade_discard(VERTEX, FRAGCOORD.xy, PROJECTION_MATRIX)) {
		discard;
	}
	vec2 uv = UV / period;
	vec3 col = texture(bark_albedo, uv).rgb * tint * tree_tint * brightness;
	NORMAL_MAP = texture(bark_normal, uv).rgb;
	NORMAL_MAP_DEPTH = 1.0;
	// moss and damp: up from the roots, thickest on one side and where the bark is sheltered
	vec4 moss = texture(moss_albedo, uv * 1.7);
	float side = clamp(dot(normalize(onrm.xz), normalize(moss_dir.xz)) * 0.5 + 0.5, 0.0, 1.0);
	float m = smoothstep(moss_height, 0.0, opos.y + (1.0 - side) * moss_height * 0.8) * moss_amount;
	m = smoothstep(0.2, 0.6, m * (0.6 + moss.a));
	col = mix(col * mix(1.0, 0.7, smoothstep(moss_height * 1.5, 0.0, opos.y)), moss.rgb * 0.8, m);
	float ao = data.x;
	ALBEDO = col * mix(0.6, 1.0, ao);
	AO = ao;
	AO_LIGHT_AFFECT = 0.35;
	ROUGHNESS = mix(0.88, 0.95, m);
	SPECULAR = 0.3;
}
