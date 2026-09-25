class_name ClipData
extends RefCounted
## One animation clip: keys resolved into full channel sets and interpolated with
## monotone cubic (PCHIP) curves. Mirrors tools/rigmath.py `Clip`.

var name: String = ""
var rig_name: String = ""
var loop: bool = false
var length: float = 0.0
var times := PackedFloat32Array()
var eases := PackedStringArray()
var values: Dictionary = {}    ## channel -> PackedFloat32Array (key-major, `dim` floats per key)
var tangents: Dictionary = {}  ## channel -> PackedFloat32Array
var events: Array = []         ## Array of Dictionary, sorted by "t"
var hits: Array = []           ## Array of Dictionary with "from"/"to"/"blade"/...
var raw: Dictionary = {}       ## Original clip dictionary (track, vuln, cancel, tags...)


func build(clip_name: String, data: Dictionary, defaults: Dictionary, poses: Dictionary) -> void:
	name = clip_name
	raw = data
	rig_name = str(data.get("rig", ""))
	loop = bool(data.get("loop", false))
	var keys: Array = data.get("keys", [])
	var resolved: Array = []
	var prev: Dictionary = {}
	for key_v in keys:
		var key: Dictionary = key_v
		var base: Dictionary
		if key.has("pose"):
			base = defaults.duplicate(true)
			var p := resolve_pose(poses, str(key["pose"]))
			for ch in p:
				base[ch] = p[ch]
		elif not prev.is_empty():
			base = prev.duplicate(true)
		else:
			base = defaults.duplicate(true)
		var sets: Dictionary = key.get("set", {})
		for ch in sets:
			base[ch] = sets[ch]
		var adds: Dictionary = key.get("add", {})
		for ch in adds:
			if PoseMath.dim(ch) == 1:
				base[ch] = float(base[ch]) + float(adds[ch])
			else:
				var a: Array = base[ch]
				var b: Array = adds[ch]
				base[ch] = [float(a[0]) + float(b[0]), float(a[1]) + float(b[1]), float(a[2]) + float(b[2])]
		for ch in base:
			if not PoseMath.KIND.has(ch):
				push_error("Clip %s: unknown channel '%s'" % [clip_name, ch])
		resolved.append(base)
		prev = base
		times.append(float(key.get("t", 0.0)))
		eases.append(str(key.get("ease", "linear")))
	length = float(data.get("length", times[times.size() - 1] if times.size() > 0 else 0.0))
	for ch in PoseMath.CHANNELS:
		var d := PoseMath.dim(ch)
		var vals := PackedFloat32Array()
		for r in resolved:
			var rd: Dictionary = r
			if d == 1:
				vals.append(float(rd[ch]))
			else:
				var arr: Array = rd[ch]
				vals.append(float(arr[0]))
				vals.append(float(arr[1]))
				vals.append(float(arr[2]))
		values[ch] = vals
		tangents[ch] = _pchip(vals, d)
	events = data.get("events", []).duplicate(true)
	events.sort_custom(func(a, b): return float(a["t"]) < float(b["t"]))
	hits = data.get("hits", []).duplicate(true)


static func resolve_pose(poses: Dictionary, pose_name: String) -> Dictionary:
	var out := {}
	if not poses.has(pose_name):
		push_error("Unknown pose '%s'" % pose_name)
		return out
	var p: Dictionary = poses[pose_name]
	if p.has("base"):
		var b := resolve_pose(poses, str(p["base"]))
		for ch in b:
			out[ch] = b[ch]
	for ch in p:
		if ch != "base":
			out[ch] = p[ch]
	return out


func _pchip(vals: PackedFloat32Array, d: int) -> PackedFloat32Array:
	var n := times.size()
	var m := PackedFloat32Array()
	m.resize(n * d)
	m.fill(0.0)
	if n < 2:
		return m
	for c in d:
		for k in n:
			var d0: float
			var d1: float
			var h0: float
			var h1: float
			if k > 0 and k < n - 1:
				h0 = maxf(times[k] - times[k - 1], 1e-9)
				h1 = maxf(times[k + 1] - times[k], 1e-9)
				d0 = (vals[k * d + c] - vals[(k - 1) * d + c]) / h0
				d1 = (vals[(k + 1) * d + c] - vals[k * d + c]) / h1
			elif loop and n > 2:
				h0 = maxf(times[n - 1] - times[n - 2], 1e-9)
				h1 = maxf(times[1] - times[0], 1e-9)
				d0 = (vals[(n - 1) * d + c] - vals[(n - 2) * d + c]) / h0
				d1 = (vals[d + c] - vals[c]) / h1
			else:
				continue
			if d0 * d1 <= 0.0:
				m[k * d + c] = 0.0
			else:
				var w1 := 2.0 * h1 + h0
				var w2 := h1 + 2.0 * h0
				m[k * d + c] = (w1 + w2) / (w1 / d0 + w2 / d1)
	return m


## Samples the clip. Rotation channels come back as Quaternion, positions and
## pole hints as Vector3, scalars as float.
func sample(t: float) -> Dictionary:
	var out := {}
	var n := times.size()
	if n == 0:
		return out
	if loop and length > 0.0:
		t = fposmod(t, length)
	t = clampf(t, times[0], times[n - 1])
	var k := 0
	while k < n - 2 and t > times[k + 1]:
		k += 1
	var u := 0.0
	var h := 0.0
	var k1 := k
	if n > 1:
		k1 = k + 1
		h = times[k1] - times[k]
		if h > 1e-9:
			u = clampf((t - times[k]) / h, 0.0, 1.0)
		u = PoseMath.ease_value(eases[k1], u)
	for ch in PoseMath.CHANNELS:
		var vals: PackedFloat32Array = values[ch]
		var tans: PackedFloat32Array = tangents[ch]
		var kind: int = PoseMath.KIND[ch]
		if kind == PoseMath.FLT:
			out[ch] = PoseMath.hermite(vals[k], vals[k1], tans[k] * h, tans[k1] * h, u)
			continue
		var i0 := k * 3
		var i1 := k1 * 3
		var v := Vector3(
			PoseMath.hermite(vals[i0], vals[i1], tans[i0] * h, tans[i1] * h, u),
			PoseMath.hermite(vals[i0 + 1], vals[i1 + 1], tans[i0 + 1] * h, tans[i1 + 1] * h, u),
			PoseMath.hermite(vals[i0 + 2], vals[i1 + 2], tans[i0 + 2] * h, tans[i1 + 2] * h, u))
		if kind == PoseMath.ROT:
			out[ch] = PoseMath.euler_deg_to_quat(v)
		else:
			out[ch] = v
	return out


func get_float(key: String, default_value: float = 0.0) -> float:
	return float(raw.get(key, default_value))


func has_tag(tag: String) -> bool:
	var tags: Array = raw.get("tags", [])
	return tags.has(tag)
