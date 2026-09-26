shader_type spatial;
render_mode diffuse_burley, specular_schlick_ggx, cull_disabled, alpha_to_coverage;
// Tree crowns (models/scenery/trees.glb, tools/build_scenery.py): lumpy clumps whose normals are
// bent out from the middle of the crown, so a crown lights as one soft mass. UV2.x is baked
// ambient occlusion, UV2.y a random tone per clump. The leaf card (needles or maple leaves) is
// projected in object space; toward the silhouette its alpha cuts the clump's edge into sprays,
// and the insides of the clumps (back faces) show dark through the gaps.

uniform sampler2D leaf_tex : source_color, filter_linear_mipmap, repeat_enable;   // alpha = coverage
uniform sampler2D noise_tex : hint_default_white, filter_linear_mipmap, repeat_enable;
uniform float leaf_period = 1.6;        // metres per tile of the leaf card
uniform float spray_period = 3.0;       // metres per tile of the noise that breaks the edges up
uniform float brightness = 1.0;        // the leaf card's colour is the albedo; this scales it
uniform float tone_var = 0.3;           // how far clumps differ in shade
uniform vec3 dry_color : source_color = vec3(0.3, 0.24, 0.13);
uniform float dry = 0.1;                // the share of clumps gone brown (old needles)
uniform float fringe = 0.85;            // how deep the silhouette is cut
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
	// a slow sway, stronger up the tree, and a faster flutter per clump
	vec3 root = NODE_POSITION_WORLD;
	float h = clamp(VERTEX.y / sway_height, 0.0, 2.0);
	float ph = TIME * 0.55 + root.x * 0.043 + root.z * 0.031 + seed * 6.2831;
	float bend = sin(ph) * 0.7 + sin(ph * 2.37 + 1.3) * 0.3;
	float flutter = sin(TIME * 2.3 + dot(VERTEX, vec3(1.7, 0.9, 1.3)) + data.y * 12.0);
	VERTEX.xz += vec2(0.8, 0.6) * (bend * sway * h * h + flutter * sway * 0.12 * h);
}

vec4 triplanar(sampler2D tex, vec3 p, vec3 w) {
	return texture(tex, p.zy) * w.x + texture(tex, p.xz) * w.y + texture(tex, p.xy) * w.z;
}

void fragment() {
	vec3 w = pow(abs(normalize(onrm)), vec3(4.0));
	w /= w.x + w.y + w.z;
	vec4 leaf = triplanar(leaf_tex, opos / leaf_period, w);
	float spray = triplanar(noise_tex, opos / spray_period + vec3(data.y * 7.0), w).r;

	// the silhouette: how edge-on the (faceted) surface is to the eye
	vec3 geo = normalize(cross(dFdx(VERTEX), dFdy(VERTEX)));
	float edge = 1.0 - abs(dot(geo, VIEW));
	float cut = smoothstep(0.25, 0.9, edge) * fringe;
	float cover = clamp(leaf.a * 0.6 + spray * 0.7 - 0.1, 0.0, 1.0);
	ALPHA = 1.0 - cut * (1.0 - cover);
	ALPHA_SCISSOR_THRESHOLD = 0.5;
	ALPHA_ANTIALIASING_EDGE = 0.3;

	vec3 col = leaf.rgb * brightness * (1.0 + (data.y - 0.5) * 2.0 * tone_var) * tint;
	float browned = step(1.0 - dry, fract(data.y * 13.7 + seed));
	col = mix(col, dry_color * dot(col, vec3(0.3, 0.6, 0.1)) * 2.2, browned * 0.7);
	float ao = mix(1.0, data.x, ao_strength);
	col *= mix(0.5, 1.0, ao);
	ALBEDO = FRONT_FACING ? col : col * 0.4;   // the inside of a clump, seen through a gap
	AO = ao;
	AO_LIGHT_AFFECT = 0.6;
	ROUGHNESS = 0.85;
	SPECULAR = 0.25;
	BACKLIGHT = col * backlight;
}
