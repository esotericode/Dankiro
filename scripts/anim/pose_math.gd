class_name PoseMath
extends RefCounted
## Shared pose math. Mirrors tools/rigmath.py so poses previewed offline match the game.
##
## Conventions: characters face -Z, +X is their right, +Y is up. Rotation channels are
## authored as Euler degrees and converted with Basis.from_euler (YXZ order).

enum { POS, DIR, ROT, FLT }

const KIND := {
	"root": POS, "hips_pos": POS, "foot_l": POS, "foot_r": POS, "weapon_pos": POS,
	"knee_l": DIR, "knee_r": DIR, "elbow_l": DIR, "elbow_r": DIR,
	"hips": ROT, "spine": ROT, "chest": ROT, "neck": ROT, "head": ROT,
	"foot_l_rot": ROT, "foot_r_rot": ROT, "weapon_rot": ROT,
	"upper_arm_l": ROT, "forearm_l": ROT, "hand_l": ROT,
	"upper_arm_r": ROT, "forearm_r": ROT, "hand_r": ROT,
	"yaw": FLT, "ik_l": FLT, "ik_r": FLT, "grip_l": FLT, "grip_r": FLT,
}

const CHANNELS := [
	"root", "hips_pos", "foot_l", "foot_r", "weapon_pos",
	"knee_l", "knee_r", "elbow_l", "elbow_r",
	"hips", "spine", "chest", "neck", "head", "foot_l_rot", "foot_r_rot", "weapon_rot",
	"upper_arm_l", "forearm_l", "hand_l", "upper_arm_r", "forearm_r", "hand_r",
	"yaw", "ik_l", "ik_r", "grip_l", "grip_r",
]

## Channels driven by an upper-body overlay (e.g. guarding while walking).
const UPPER := [
	"spine", "chest", "neck", "head", "weapon_pos", "weapon_rot",
	"upper_arm_l", "forearm_l", "hand_l", "upper_arm_r", "forearm_r", "hand_r",
	"ik_l", "ik_r", "grip_l", "grip_r", "elbow_l", "elbow_r",
]


static func dim(channel: String) -> int:
	var k: int = KIND[channel]
	return 1 if k == FLT else 3


static func euler_deg_to_quat(v: Vector3) -> Quaternion:
	var b := Basis.from_euler(Vector3(deg_to_rad(v.x), deg_to_rad(v.y), deg_to_rad(v.z)))
	return b.get_rotation_quaternion()


static func ease_value(ease_name: String, u: float) -> float:
	match ease_name:
		"linear":
			return u
		"in_quad":
			return u * u
		"out_quad":
			return 1.0 - (1.0 - u) * (1.0 - u)
		"inout_quad":
			return 2.0 * u * u if u < 0.5 else 1.0 - pow(-2.0 * u + 2.0, 2.0) / 2.0
		"in_cubic":
			return u * u * u
		"out_cubic":
			return 1.0 - pow(1.0 - u, 3.0)
		"inout_cubic":
			return 4.0 * u * u * u if u < 0.5 else 1.0 - pow(-2.0 * u + 2.0, 3.0) / 2.0
		"in_quart":
			return u * u * u * u
		"out_quart":
			return 1.0 - pow(1.0 - u, 4.0)
		"in_expo":
			return 0.0 if u <= 0.0 else pow(2.0, 10.0 * u - 10.0)
		"out_expo":
			return 1.0 if u >= 1.0 else 1.0 - pow(2.0, -10.0 * u)
		"inout_sine":
			return 0.5 - 0.5 * cos(PI * u)
		"in_sine":
			return 1.0 - cos(PI * u / 2.0)
		"out_sine":
			return sin(PI * u / 2.0)
		"out_back":
			return 1.0 + 2.70158 * pow(u - 1.0, 3.0) + 1.70158 * pow(u - 1.0, 2.0)
		"in_back":
			return 2.70158 * u * u * u - 1.70158 * u * u
		"hold":
			return 0.0 if u < 1.0 else 1.0
	return u


static func hermite(y0: float, y1: float, m0: float, m1: float, u: float) -> float:
	var u2 := u * u
	var u3 := u2 * u
	return (2.0 * u3 - 3.0 * u2 + 1.0) * y0 + (u3 - 2.0 * u2 + u) * m0 \
		+ (-2.0 * u3 + 3.0 * u2) * y1 + (u3 - u2) * m1


## Blends pose b over pose a with weight w (0 = a, 1 = b) for the given channels.
static func blend(a: Dictionary, b: Dictionary, w: float, channels: Array = CHANNELS) -> Dictionary:
	var out := a.duplicate()
	if w <= 0.0:
		return out
	for ch in channels:
		if not a.has(ch) or not b.has(ch):
			continue
		var k: int = KIND[ch]
		match k:
			POS, DIR:
				var va: Vector3 = a[ch]
				var vb: Vector3 = b[ch]
				out[ch] = va.lerp(vb, w)
			ROT:
				var qa: Quaternion = a[ch]
				var qb: Quaternion = b[ch]
				out[ch] = qa.slerp(qb, w)
			FLT:
				var fa: float = a[ch]
				var fb: float = b[ch]
				out[ch] = lerpf(fa, fb, w)
	return out


## Two-bone IK. Returns [mid, end, hinge]. `pole` is the direction the middle joint bends toward.
static func two_bone(root: Vector3, target: Vector3, l1: float, l2: float, pole: Vector3) -> Array:
	var dv := target - root
	var dist := dv.length()
	var n := dv / dist if dist > 1e-6 else Vector3.DOWN
	var d := clampf(dist, absf(l1 - l2) + 1e-4, l1 + l2 - 1e-4)
	var m := pole - n * pole.dot(n)
	if m.length() < 1e-5:
		m = n.cross(Vector3.RIGHT)
	m = m.normalized()
	var cos_a := (l1 * l1 + d * d - l2 * l2) / (2.0 * l1 * d)
	var a := acos(clampf(cos_a, -1.0, 1.0))
	var mid := root + (n * cos(a) + m * sin(a)) * l1
	var end := root + n * d
	var hinge := n.cross(m).normalized()
	return [mid, end, hinge]


## Basis for a bone that extends along its local -Y, with local +X as the hinge axis.
static func bone_basis(direction: Vector3, x_axis: Vector3) -> Basis:
	var y := -direction.normalized()
	var x := (x_axis - y * x_axis.dot(y)).normalized()
	var z := x.cross(y)
	return Basis(x, y, z)


## Brings a spin channel back into (-180, 180] so crossfades never unwind a full turn.
static func wrap_yaw(pose: Dictionary) -> void:
	if pose.has("yaw"):
		var y: float = pose["yaw"]
		pose["yaw"] = wrapf(y, -180.0, 180.0)
