shader_type spatial;
render_mode diffuse_burley, specular_schlick_ggx;
// The plaza's flagstones: models/arena_floor.glb, built by tools/build_arena_floor.py.
// UV is the stone's own frame in metres. UV2.x is the stone's id; UV2.y packs
// stone type + 8 * crack decal + 64 * condition, plus 0.05 + 0.9 * how far the point is into the
// stone's worn edge (0 inside, 0.5 where the edge starts to round, 1 down the side).
// The plaza masks are planar over [-map_size / 2, map_size / 2] in x and z.

uniform sampler2D stone_albedo : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D stone_normal : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D stone_data : hint_default_white, filter_linear_mipmap_anisotropic, repeat_enable; // roughness, cavity, layering
uniform sampler2D moss_albedo : source_color, filter_linear_mipmap_anisotropic, repeat_enable;       // alpha = cushion height
uniform sampler2D moss_normal : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D cracks : hint_default_black, filter_linear_mipmap_anisotropic, repeat_disable;     // 2x2 decals: crack, halo
uniform sampler2D engraving : hint_default_black, filter_linear_mipmap_anisotropic, repeat_disable;  // depth, chamfer
uniform sampler2D plaza_a : hint_default_white, filter_linear_mipmap, repeat_disable;  // AO, bed AO, dirt, moss
uniform sampler2D plaza_b : hint_default_black, filter_linear_mipmap, repeat_disable;  // wet, soot, polish, lichen

uniform float stone_period = 2.4;
uniform float moss_period = 0.6;
uniform float map_size = 32.0;
uniform float crack_cell = 1.6;
uniform float medallion_size = 1.44;

uniform vec3 granite : source_color = vec3(0.35, 0.335, 0.315);
uniform vec3 slate : source_color = vec3(0.285, 0.285, 0.29);
uniform vec3 sandstone : source_color = vec3(0.375, 0.35, 0.315);
uniform vec3 basalt : source_color = vec3(0.2, 0.2, 0.205);
uniform vec3 medallion : source_color = vec3(0.42, 0.41, 0.39);
uniform vec3 dirt_color : source_color = vec3(0.15, 0.125, 0.095);
uniform vec3 grime_color : source_color = vec3(0.06, 0.055, 0.047);
uniform vec3 soot_color : source_color = vec3(0.04, 0.036, 0.033);
uniform vec3 lichen_color : source_color = vec3(0.47, 0.48, 0.42);
uniform float dirt_strength = 0.6;
uniform float moss_strength = 1.0;

varying vec3 wpos;
varying vec2 sdata;

void vertex() {
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	sdata = UV2;
}

float hash(float n) {
	return fract(sin(n * 91.3458 + 17.13) * 47453.5453);
}

void fragment() {
	float id = floor(sdata.x);
	float code = floor(sdata.y);
	float edge = clamp((sdata.y - code - 0.05) / 0.9, 0.0, 1.0);
	int attrs = int(code + 0.5);
	int stype = attrs % 8;
	int crackv = (attrs / 8) % 8;
	int cond = attrs / 64;
	float h1 = hash(id);
	float h2 = hash(id + 3.17);
	float h3 = hash(id + 7.71);
	float h4 = hash(id + 13.3);
	float h5 = hash(id + 21.9);

	// stone detail, offset and turned per stone
	float ang = h1 * 6.2831853;
	mat2 rot = mat2(vec2(cos(ang), sin(ang)), vec2(-sin(ang), cos(ang)));
	vec2 duv = (rot * UV) / stone_period + vec2(h2, h3) * 3.0;
	vec3 det = texture(stone_albedo, duv).rgb * 2.0;          // linear, mean 1
	vec3 dat = texture(stone_data, duv).rgb;
	vec2 nd = texture(stone_normal, duv).rg * 2.0 - 1.0;
	// the normal map's axes turned back into the stone's frame (y points up the image, -v)
	nd = transpose(rot) * vec2(nd.x, -nd.y);
	nd.y = -nd.y;

	vec3 base = granite;
	float contrast = 0.55;
	float nstr = 1.0;
	float rough_off = 0.0;
	float layer_amt = 0.0;
	if (stype == 1) {
		base = slate; contrast = 0.28; nstr = 0.55; rough_off = -0.08; layer_amt = 0.4;
	} else if (stype == 2) {
		base = sandstone; contrast = 0.32; nstr = 1.3; rough_off = 0.06; layer_amt = 0.25;
	} else if (stype == 3) {
		base = basalt; contrast = 0.3; nstr = 0.85; rough_off = -0.04; layer_amt = 0.15;
	} else if (stype == 4) {
		base = medallion; contrast = 0.75;
	}
	vec3 alb = base * mix(vec3(1.0), det, contrast);
	alb *= mix(1.0, 0.72 + 0.56 * dat.b, layer_amt);
	float tone = 0.86 + 0.26 * h4;
	if (cond == 1) {
		tone *= 1.12;
	} else if (cond == 2) {
		tone *= 0.86;
		nstr *= 1.35;
	}
	alb *= tone * vec3(1.0 + (h5 - 0.5) * 0.07, 1.0, 1.0 - (h5 - 0.5) * 0.07);
	float rough = clamp(0.6 + 0.36 * dat.r + rough_off, 0.5, 1.0);
	float cav = dat.g;
	nd *= nstr;

	float bevel = smoothstep(0.5, 1.0, edge);             // across the rounded edge
	float near_edge = smoothstep(0.0, 0.5, edge);         // toward the edge on the top
	float joint = smoothstep(0.78, 1.0, edge);            // down into the joint
	// worn arrises catch the light paler; grime gathers in a band along the edges and in the joints
	alb *= 1.0 + 0.14 * bevel * (1.0 - joint) * (cond == 2 ? 1.4 : 1.0);
	float band = near_edge * (1.0 - bevel) * (0.55 + 0.45 * smoothstep(0.2, 0.8, dat.b));

	vec2 muv = wpos.xz / map_size + 0.5;
	vec4 pa = texture(plaza_a, muv);
	vec4 pb = texture(plaza_b, muv);
	float ao = pa.r;
	float dirt = pa.b;
	float moss_m = pa.a * moss_strength;
	float wet = pb.r;
	float soot = pb.g;
	float polish = pb.b;
	float lichen = pb.a;

	// hairline crack decal
	float crack = 0.0;
	float halo = 0.0;
	if (crackv > 0) {
		int k = crackv - 1;
		vec2 cuv = UV / crack_cell + 0.5;
		if (cuv.x > 0.0 && cuv.y > 0.0 && cuv.x < 1.0 && cuv.y < 1.0) {
			vec2 auv = vec2(float(k % 2), float(k / 2)) * 0.5 + cuv * 0.5;
			vec2 cr = texture(cracks, auv).rg;
			crack = cr.r;
			halo = cr.g;
			float e = 0.0012;
			float gx = texture(cracks, auv + vec2(e, 0.0)).r - texture(cracks, auv - vec2(e, 0.0)).r;
			float gz = texture(cracks, auv + vec2(0.0, e)).r - texture(cracks, auv - vec2(0.0, e)).r;
			nd += vec2(gx, -gz) * 0.9;
		}
	}
	alb *= 1.0 - 0.8 * crack;
	rough = mix(rough, 1.0, crack);

	// the medallion's carving: grime in the cuts, worn pale arrises
	if (stype == 4) {
		vec2 euv = UV / medallion_size + 0.5;
		vec2 eg = texture(engraving, euv).rg;
		float e = 0.0009;
		float gx = texture(engraving, euv + vec2(e, 0.0)).r - texture(engraving, euv - vec2(e, 0.0)).r;
		float gz = texture(engraving, euv + vec2(0.0, e)).r - texture(engraving, euv - vec2(0.0, e)).r;
		nd += vec2(gx, -gz) * 2.2;
		alb = mix(alb, alb * 0.42, eg.r);
		alb *= 1.0 + 0.14 * eg.g;
		rough = mix(rough, 0.95, eg.r);
		ao *= mix(1.0, 0.55, eg.r);
		halo = max(halo, eg.r * 0.8);
	}

	// dirt in the pits, along edges and cracks; grime in the joints
	float dirt_amt = dirt * (0.45 + 1.1 * cav + 0.5 * near_edge) + halo * 0.35 + band * 0.22;
	if (cond == 1) {
		dirt_amt *= 0.45;
	}
	dirt_amt = clamp(dirt_amt * dirt_strength, 0.0, 1.0);
	alb = mix(alb, dirt_color * (0.8 + 0.4 * det.r * 0.5), dirt_amt * 0.75);
	alb = mix(alb, grime_color, joint * 0.75);
	rough = mix(rough, 0.93, max(dirt_amt * 0.6, joint));
	alb = mix(alb, soot_color, clamp(soot * (0.55 + 0.9 * cav + 0.4 * near_edge), 0.0, 1.0) * 0.85);

	// polished where people walk and fight
	rough = clamp(rough - polish * 0.12 * (1.0 - cav), 0.5, 1.0);
	alb *= 1.0 + polish * 0.05;

	// lichen crusts
	float lich = smoothstep(0.62, 0.8, lichen * (0.45 + 0.9 * dat.b) + (h3 - 0.5) * 0.15) * (1.0 - bevel);
	alb = mix(alb, lichen_color * (0.8 + 0.2 * det.g), lich * 0.3);
	rough = mix(rough, 0.95, lich);

	// moss roots in the joints, cracks and pits; a heavy mask covers the stone
	vec2 mv = wpos.xz / moss_period;
	vec4 ms = texture(moss_albedo, mv);
	vec2 mn = texture(moss_normal, mv).rg * 2.0 - 1.0;
	float site = max(max(smoothstep(0.55, 1.0, edge), halo), cav * 0.7);
	float amount = max(moss_m * mix(0.3, 1.7, site), smoothstep(0.55, 1.0, moss_m) * 0.95);
	float mcov = smoothstep(1.0 - amount, 1.0 - amount + 0.3, ms.a + 0.1) * step(0.02, moss_m);
	vec3 moss_col = mix(vec3(dot(ms.rgb, vec3(0.3, 0.55, 0.15))), ms.rgb, 0.85) * 0.9;
	moss_col *= mix(0.55, 1.0, smoothstep(0.25, 0.9, amount));     // thin moss is dark and young
	alb = mix(alb, moss_col, mcov);
	rough = mix(rough, 0.96, mcov);
	nd = mix(nd, mn, mcov);

	// wet stone: darker, glossy, the surface detail drowned
	float wet_amt = wet * (1.0 - 0.5 * mcov);
	alb *= mix(1.0, 0.58, wet_amt);
	rough = mix(rough, 0.62, wet_amt);
	nd *= 1.0 - 0.65 * wet_amt;

	ao *= mix(1.0, 0.6, joint);
	ALBEDO = alb;
	ROUGHNESS = rough;
	SPECULAR = mix(0.3, 0.5, wet_amt);
	AO = ao;
	AO_LIGHT_AFFECT = 0.35;
	NORMAL_MAP = vec3(clamp(nd, vec2(-0.95), vec2(0.95)) * 0.5 + 0.5, 1.0);
}
