shader_type spatial;
render_mode diffuse_burley, specular_schlick_ggx, cull_disabled, alpha_to_coverage;
// Cards of foliage fringing the tree crowns (models/scenery/trees.glb, tools/build_scenery.py
// Crown): each is stored as a card_size square in the object's xy plane; here it is turned to
// face the camera about its centre, a little bigger or smaller and rolled at random, so a
// crown's outline is always made of sprays. Lit with the crown's bent normal (NORMAL) so it
// shades as one mass with the clumps behind. UV2.x: baked occlusion, UV2.y: the clump's tone.

uniform sampler2D leaf_tex : source_color, filter_linear_mipmap_anisotropic;   // a spray, alpha = coverage
uniform float card_size = 1.0;
uniform float brightness = 1.0;
uniform float tone_var = 0.3;
uniform vec3 dry_color : source_color = vec3(0.3, 0.24, 0.13);
uniform float dry = 0.1;
uniform float backlight = 0.35;
uniform float sway = 0.06;
uniform float sway_height = 10.0;
instance uniform float seed = 0.0;
instance uniform vec3 tint : source_color = vec3(1.0);

varying vec2 data;

float hash13(vec3 p) {
	p = fract(p * 0.1031);
	p += dot(p, p.zyx + 31.32);
	return fract((p.x + p.y) * p.z);
}

void vertex() {
	data = UV2;
	vec2 corner = vec2(UV.x - 0.5, 0.5 - UV.y);
	vec3 centre = VERTEX - vec3(corner * card_size, 0.0);
	float h = hash13(centre * 7.31);
	float roll = (h - 0.5) * 1.6;
	float size = card_size * (0.8 + 0.45 * fract(h * 13.7));
	vec2 c = mat2(vec2(cos(roll), sin(roll)), vec2(-sin(roll), cos(roll))) * corner * size;
	// the camera's right and up in object space (the model matrix is a rotation and a uniform scale)
	mat3 m = mat3(MODEL_MATRIX);
	float s2 = dot(m[0], m[0]);
	vec3 right = transpose(m) * INV_VIEW_MATRIX[0].xyz / s2;
	vec3 up = transpose(m) * INV_VIEW_MATRIX[1].xyz / s2;
	float scale = sqrt(s2);
	VERTEX = centre + (right * c.x + up * c.y) * scale;
	// a slow sway, stronger up the tree, and a flutter per card
	vec3 root = NODE_POSITION_WORLD;
	float hh = clamp(centre.y / sway_height, 0.0, 2.0);
	float ph = TIME * 0.55 + root.x * 0.043 + root.z * 0.031 + seed * 6.2831;
	float bend = sin(ph) * 0.7 + sin(ph * 2.37 + 1.3) * 0.3;
	float flutter = sin(TIME * 2.9 + h * 40.0);
	VERTEX.xz += vec2(0.8, 0.6) * (bend * sway * hh * hh + flutter * sway * 0.25 * hh);
}

void fragment() {
	vec4 leaf = texture(leaf_tex, UV);
	// keep far cards from thinning out as their mipmaps blur the alpha
	float lod = log2(max(length(dFdx(UV)), length(dFdy(UV))) * float(textureSize(leaf_tex, 0).x));
	ALPHA = clamp(leaf.a * (1.0 + 0.35 * max(lod, 0.0)), 0.0, 1.0);
	ALPHA_SCISSOR_THRESHOLD = 0.5;
	ALPHA_ANTIALIASING_EDGE = 0.25;
	if (!FRONT_FACING) {
		NORMAL = -NORMAL;     // both sides light as the crown's outside
	}
	vec3 col = leaf.rgb * brightness * (1.0 + (data.y - 0.5) * 2.0 * tone_var) * tint;
	float browned = step(1.0 - dry, fract(data.y * 13.7 + seed));
	col = mix(col, dry_color * dot(col, vec3(0.3, 0.6, 0.1)) * 2.2, browned * 0.7);
	float ao = data.x;
	col *= mix(0.45, 1.0, ao);
	ALBEDO = col;
	AO = ao;
	AO_LIGHT_AFFECT = 0.6;
	ROUGHNESS = 0.8;
	SPECULAR = 0.3;
	BACKLIGHT = col * backlight;
}
