shader_type spatial;
render_mode diffuse_burley, specular_schlick_ggx;
// Lattice doors and transoms of the shrine hall and the paper in the stone lanterns, lit from
// within. UV is in metres from the panel's lower left; the lattice is drawn here.

uniform vec2 panel = vec2(1.5, 1.94);   // the panel's size (m), for the frame round it
uniform vec2 cell = vec2(0.3, 0.36);    // lattice spacing (m)
uniform float bar = 0.024;
uniform float frame = 0.05;
uniform vec3 wood_color : source_color = vec3(0.09, 0.06, 0.045);
uniform vec3 paper_color : source_color = vec3(0.75, 0.68, 0.55);
uniform vec3 glow_color : source_color = vec3(1.0, 0.6, 0.3);
uniform float glow = 1.6;
uniform float flicker = 0.08;
uniform bool lattice = true;
instance uniform float seed = 0.0;

varying vec2 data;

void vertex() {
	data = UV2;
}

float hash(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

void fragment() {
	vec2 uv = UV;
	float wood = 0.0;
	if (lattice) {
		vec2 g = abs(fract(uv / cell + 0.5) - 0.5) * cell;
		wood = 1.0 - smoothstep(bar * 0.5, bar * 0.5 + 0.004, min(g.x, g.y));
		vec2 e = min(uv, panel - uv);
		wood = max(wood, 1.0 - smoothstep(frame, frame + 0.004, min(e.x, e.y)));
	}
	// paper: a warm glow, brightest low in the middle (the lamps within), a little patchy
	vec2 c = (uv / panel - vec2(0.5, 0.35));
	float lamp = 0.75 + 0.35 * exp(-dot(c, c) * 3.0);
	float patch = 0.9 + 0.1 * hash(floor(uv / cell));
	float t = TIME * 7.0 + seed * 40.0;
	float fl = 1.0 - flicker + flicker * (0.6 + 0.25 * sin(t) + 0.15 * sin(t * 2.7 + 1.3));
	vec3 paper = paper_color;
	ALBEDO = mix(paper * 0.4, wood_color, wood) * mix(0.6, 1.0, data.x);
	ROUGHNESS = mix(0.85, 0.6, wood);
	SPECULAR = 0.3;
	EMISSION = glow_color * glow * lamp * patch * fl * (1.0 - wood);
}
