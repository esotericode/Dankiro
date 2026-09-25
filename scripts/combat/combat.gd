class_name Combat
extends RefCounted
## Combat tuning + geometry helpers shared by the player and the boss.
##
## Deflect timing follows Sekiro: pressing guard opens a 12-frame (0.200 s at 60 fps)
## deflect window. Pressing again soon after (mashing) shrinks the next window, but a
## successful deflect restores the full window, so rhythmically deflecting a combo works
## while blind mashing is punished. Holding guard past the window becomes a normal block.

# --- Deflect -------------------------------------------------------------------------
const DEFLECT_WINDOW := 0.200
## Window used for the n-th rapid press in a row (index clamps to the last entry).
const DEFLECT_SPAM_WINDOWS := [0.200, 0.133, 0.100, 0.083, 0.067]
## A press this soon after the previous one counts as mashing.
const SPAM_INTERVAL := 0.45
## Contact is evaluated at physics-tick resolution; a press registered in the same tick
## as the contact still counts (like frame-based games evaluate input first).
const DEFLECT_GRACE := 1.0 / 120.0
## A tapped guard stays up at least this long (>= the widest deflect window).
const GUARD_MIN_TIME := 0.23
## Attacks from outside this half-angle (degrees) hit through the guard.
const GUARD_HALF_ANGLE := 110.0

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
const HEAL_CHARGES := 3
const HEAL_AMOUNT := 0.55                   ## fraction of max HP

# --- Boss --------------------------------------------------------------------------------
const BOSS_HP := 1100.0
const BOSS_POSTURE := 100.0
const BOSS_POSTURE_REGEN := 9.0
const BOSS_POSTURE_DELAY := 1.5
const BOSS_LIVES := 2
const MIKIRI_POSTURE := 32.0
const KICK_POSTURE := 16.0
const FINAL_DEFLECT_BONUS := 1.35            ## extra posture for deflecting a combo's last hit

enum { RESULT_NONE, RESULT_DEFLECT, RESULT_BLOCK, RESULT_HIT, RESULT_MIKIRI, RESULT_IGNORED }


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
