shader_type spatial;
render_mode diffuse_burley, specular_schlick_ggx;
// The inner mass of the tree crowns (models/scenery/trees.glb, tools/build_scenery.py Crown):
// lumpy clumps whose normals are bent out from the middle of the crown, so a crown lights as
// one soft mass; the cards of leaves over them (leaves.gdshader) make the outline. UV2.x is baked
// ambient occlusion, UV2.y a random tone per clump. The leaf texture is projected in object space.
// In the moon's shadow pass the mass is full of holes and only half there (every other texel of
// the shadow map, which the shadow filter smooths into half strength), so a tree's shadow on the
// plaza is a dappled shade like foliage's rather than one solid blot. The trunks cast in full.

uniform sampler2D leaf_tex : source_color, filter_linear_mipmap, repeat_enable;   // alpha = coverage
uniform float leaf_period = 1.6;        // metres per tile of the leaf texture
uniform float brightness = 1.0;        // the leaf card's colour is the albedo; this scales it
uniform float tone_var = 0.3;           // how far clumps differ in shade
uniform vec3 dry_color : source_color = vec3(0.3, 0.24, 0.13);
uniform float dry = 0.1;                // the share of clumps gone brown (old needles)
uniform float depth_shade = 0.75;       // the mass sits under the cards: a little darker
uniform float backlight = 0.35;
uniform float ao_strength = 1.0;
uniform float sway = 0.06;              // metres at the top of a 10 m tree
uniform float sway_height = 10.0;
instance uniform float seed = 0.0;
instance uniform vec3 tint : source_color = vec3(1.0);

varying vec3 opos;
varying vec3 onrm;
varying vec2 data;

void vertex() {
	opos = VERTEX;
	onrm = NORMAL;
	data = UV2;
	// a slow sway, stronger up the tree (the cards on it sway the same, plus a flutter)
	vec3 root = NODE_POSITION_WORLD;
	float h = clamp(VERTEX.y / sway_height, 0.0, 2.0);
	float ph = TIME * 0.55 + root.x * 0.043 + root.z * 0.031 + seed * 6.2831;
	float bend = sin(ph) * 0.7 + sin(ph * 2.37 + 1.3) * 0.3;
	VERTEX.xz += vec2(0.8, 0.6) * bend * sway * h * h;
}

float hash31(vec3 p) {
	p = fract(p * 0.1031);
	p += dot(p, p.zyx + 31.32);
	return fract((p.x + p.y) * p.z);
}

float vnoise(vec3 p) {
	vec3 i = floor(p);
	vec3 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(mix(hash31(i), hash31(i + vec3(1, 0, 0)), f.x), mix(hash31(i + vec3(0, 1, 0)), hash31(i + vec3(1, 1, 0)), f.x), f.y),
		mix(mix(hash31(i + vec3(0, 0, 1)), hash31(i + vec3(1, 0, 1)), f.x), mix(hash31(i + vec3(0, 1, 1)), hash31(i + vec3(1, 1, 1)), f.x), f.y), f.z);
}

vec4 triplanar(sampler2D tex, vec3 p, vec3 w) {
	return texture(tex, p.zy) * w.x + texture(tex, p.xz) * w.y + texture(tex, p.xy) * w.z;
}

void fragment() {
	// An orthographic projection is the moon's shadow map (the cameras are all perspective).
	if (PROJECTION_MATRIX[3][3] > 0.5) {
		float gaps = vnoise(opos * 1.25 + seed * 17.0) * 0.65 + vnoise(opos * 3.4) * 0.35;
		if (gaps < 0.5 || mod(floor(FRAGCOORD.x) + floor(FRAGCOORD.y), 2.0) < 1.0) {
			discard;
		}
	}
	vec3 w = pow(abs(normalize(onrm)), vec3(4.0));
	w /= w.x + w.y + w.z;
	vec4 leaf = triplanar(leaf_tex, opos / leaf_period, w);

	vec3 col = leaf.rgb * brightness * depth_shade * (1.0 + (data.y - 0.5) * 2.0 * tone_var) * tint;
	float browned = step(1.0 - dry, fract(data.y * 13.7 + seed));
	col = mix(col, dry_color * dot(col, vec3(0.3, 0.6, 0.1)) * 2.2, browned * 0.7);
	float ao = mix(1.0, data.x, ao_strength);
	col *= mix(0.5, 1.0, ao);
	ALBEDO = col;
	AO = ao;
	AO_LIGHT_AFFECT = 0.6;
	ROUGHNESS = 0.85;
	SPECULAR = 0.25;
	BACKLIGHT = col * backlight;
}
