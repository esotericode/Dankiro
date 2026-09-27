// Scenery the camera comes close to dissolves (a dither), so a bush, a crown or a trunk the lock-on
// camera swings into beyond the plaza's fence never fills the view (the camera doesn't collide
// with the fighters' wall at the rim, see Combat.LAYER_BOUNDARY). Nothing grows inside the plaza,
// so this only ever acts out there. Not in the moon's shadow pass (orthographic): shadows stay whole.
const float NEAR_FADE_GONE = 1.2;     // metres from the camera: nothing left nearer than this
const float NEAR_FADE_FULL = 2.4;     // all there beyond this

bool near_fade_discard(vec3 view_pos, vec2 frag_coord, mat4 projection) {
	if (projection[3][3] > 0.5) {
		return false;
	}
	float k = smoothstep(NEAR_FADE_GONE, NEAR_FADE_FULL, length(view_pos));
	float dither = fract(52.9829189 * fract(dot(frag_coord, vec2(0.06711056, 0.00583715))));
	return dither > k;
}
