class_name Combat
extends RefCounted
## Combat tuning + geometry helpers shared by the player and the boss.
## The rules these numbers implement are documented in docs/SEKIRO_MECHANICS.md.
##
## Deflect timing follows Sekiro: pressing guard opens a 12-frame (0.200 s at 60 fps)
## deflect window. Pressing again within 30 frames (0.5 s) of releasing guard shrinks the
## next window (12 -> 8 -> 6 -> 4 -> 0 frames); the penalty clears after 0.5 s and immediately
## after a successful deflect, so deflecting a combo in rhythm works while mashing doesn't.
## Holding guard past the window (or a tapped guard that is still up) becomes a block.

# --- Deflect -------------------------------------------------------------------------
const DEFLECT_WINDOW := 0.200
## Window used for the n-th quick re-press in a row (index clamps to the last entry).
const DEFLECT_SPAM_WINDOWS := [0.200, 0.1333, 0.100, 0.0667, 0.0]
## A press this soon after releasing guard counts as a quick re-press (30 frames).
const SPAM_RESET := 0.5
## Contact is evaluated at physics-tick resolution; a press registered in the same tick
## as the contact still counts (like frame-based games evaluate input first).
const DEFLECT_GRACE := 1.0 / 120.0
## A tapped guard stays up at least this long (20 frames, > the widest deflect window). An
## attack that lands after the window but while the guard is still up is blocked: pressing too
## early blocks rather than getting you hit, unless you tapped far too early.
const GUARD_MIN_TIME := 0.35
## Attacks from outside this half-angle (degrees) hit through the guard.
const GUARD_HALF_ANGLE := 110.0
## Consecutive deflects (each within this time of the last) deal more posture damage.
const DEFLECT_CHAIN_TIME := 1.2
const DEFLECT_CHAIN_BONUS := 0.12
const DEFLECT_CHAIN_MAX_STEPS := 3

# --- Hit reactions ---------------------------------------------------------------------
const HITSTOP_DEFLECT := 0.075
const HITSTOP_BLOCK := 0.035
const HITSTOP_HIT := 0.06
const HITSTOP_MIKIRI := 0.12
const HITSTOP_POSTURE_BREAK := 0.16
const HITSTOP_DEATHBLOW := 0.14

# --- Player ------------------------------------------------------------------------------
const PLAYER_HP := 100.0
const PLAYER_POSTURE := 100.0
const PLAYER_POSTURE_REGEN := 14.0          ## per second, after the delay
const PLAYER_POSTURE_REGEN_GUARD := 1.6     ## multiplier while holding guard
const PLAYER_POSTURE_DELAY := 0.9
## Hit-stun before your guard can come back up (held or pressed): light blows (flurry hits,
## jabs, shuriken: damage up to LIGHT_HIT_DMG) barely stagger you, so holding guard blocks the
## rest of a string after one missed deflect. Heavy blows (thrusts, sweeps, big finishers)
## knock you down instead.
const LIGHT_HIT_DMG := 20.0
const HIT_STUN_LIGHT := 0.12
const HIT_STUN := 0.22
const HEAL_CHARGES := 3
const HEAL_AMOUNT := 0.55                   ## fraction of max HP

# --- Boss --------------------------------------------------------------------------------
const BOSS_HP := 1100.0
const BOSS_POSTURE := 300.0                 ## deflects, mikiris and kicks fill a third as much as they did at 100
## Per second after the delay (was 9). On the 3x bar, keeping the old on-screen refill speed
## (27/s) or faster left a decent player unable to break him; 12/s punishes backing off harder
## than before while a steady deflect rhythm still breaks him in about a minute.
const BOSS_POSTURE_REGEN := 12.0
const BOSS_POSTURE_DELAY := 1.5
const BOSS_LIVES := 2
const MIKIRI_POSTURE := 32.0
## A Mikiri step may start this long before the thrust's release ("the spear starts going
## forward") and still count; any earlier is a plain dodge into the thrust.
const MIKIRI_EARLY_GRACE := 0.1
const KICK_POSTURE := 16.0
const FINAL_DEFLECT_BONUS := 1.35            ## extra posture for deflecting a combo's last hit

## RESULT_EVADED: dodged through with i-frames. The strike isn't used up: if the blade is still
## on you when the i-frames end, it lands.
enum { RESULT_NONE, RESULT_DEFLECT, RESULT_BLOCK, RESULT_HIT, RESULT_MIKIRI, RESULT_IGNORED, RESULT_EVADED }


## Swept test of a blade polyline against a vertical capsule.
## `prev` and `now` are the blade points last tick and this tick (same length).
## Returns {} when there's no contact, else {"frac": 0..1 within the tick, "point": Vector3}.
static func blade_vs_capsule(prev: PackedVector3Array, now: PackedVector3Array, cap_a: Vector3,
		cap_b: Vector3, radius: float, substeps := 6) -> Dictionary:
	if now.size() < 2:
		return {}
	var use_prev := prev.size() == now.size()
	for s in range(1, substeps + 1):
		var f := float(s) / float(substeps)
		for i in now.size() - 1:
			var p0 := now[i]
			var p1 := now[i + 1]
			if use_prev:
				p0 = prev[i].lerp(now[i], f)
				p1 = prev[i + 1].lerp(now[i + 1], f)
			var cp := Geometry3D.get_closest_points_between_segments(p0, p1, cap_a, cap_b)
			var d := cp[0].distance_to(cp[1])
			if d <= radius:
				var dir := (cp[0] - cp[1])
				var pt := cp[0]
				if dir.length() > 1e-4:
					pt = cp[1] + dir.normalized() * minf(radius * 0.8, dir.length())
				return {"frac": f, "point": pt}
	return {}


## Point-vs-capsule helper (kicks).
static func point_vs_capsule(p: Vector3, cap_a: Vector3, cap_b: Vector3, radius: float) -> bool:
	var q := Geometry3D.get_closest_point_to_segment(p, cap_a, cap_b)
	return q.distance_to(p) <= radius


static func flat(v: Vector3) -> Vector3:
	return Vector3(v.x, 0.0, v.z)


## Angle (degrees) between `facing_dir` and the direction toward `other` on the ground plane.
static func angle_to(from_pos: Vector3, facing_dir: Vector3, other: Vector3) -> float:
	var to := flat(other - from_pos)
	var f := flat(facing_dir)
	if to.length() < 1e-4 or f.length() < 1e-4:
		return 0.0
	return rad_to_deg(f.normalized().angle_to(to.normalized()))


static func yaw_of(dir: Vector3) -> float:
	return atan2(-dir.x, -dir.z)


static func dir_of(yaw: float) -> Vector3:
	return Vector3(-sin(yaw), 0.0, -cos(yaw))
