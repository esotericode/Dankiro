class_name Combatant
extends CharacterBody3D
## Shared plumbing for the player and the boss: rig + animator, facing, root motion,
## gravity, vitality/posture and swept weapon hit detection against an opponent.

signal vitals_changed

const GRAVITY := 22.0

var rig: HumanoidRig
var anim: PoseAnimator
var pivot: Node3D                   ## rotates with `facing`
var facing := 0.0                   ## yaw (radians); forward = Combat.dir_of(facing)
var opponent: Combatant

var hp := 100.0
var max_hp := 100.0
var posture := 0.0
var max_posture := 100.0
var posture_regen := 10.0
var posture_delay := 1.0
var _since_posture_hit := 99.0

var root_scale := 1.0               ## multiplier for clip root motion (leaps)
var root_motion_enabled := true
var min_opponent_distance := 1.1    ## root motion never pushes closer than this
var hurt_bottom := 0.3
var hurt_top := 1.5
var hurt_radius := 0.3

var _blade_prev: Dictionary = {}    ## blade -> PackedVector3Array (last tick)
var _hits_done: Dictionary = {}     ## hit index -> true, reset per clip start
var _hit_clip := ""
var _extra_velocity := Vector3.ZERO ## pushes (knockback), decays
var _was_on_floor := true


func _setup_rig(rig_name: String) -> void:
	pivot = Node3D.new()
	pivot.name = "Pivot"
	add_child(pivot)
	rig = HumanoidRig.new()
	rig.name = "Rig"
	pivot.add_child(rig)
	rig.setup(rig_name)
	anim = PoseAnimator.new(rig)
	anim.event_fired.connect(_on_anim_event)
	var rd := AnimLibrary.get_rig(rig_name)
	var hb: Dictionary = rd.get("hurtbox", {})
	hurt_bottom = float(hb.get("bottom", 0.3))
	hurt_top = float(hb.get("top", 1.5))
	hurt_radius = float(hb.get("radius", 0.3))
	var shape := CapsuleShape3D.new()
	shape.radius = hurt_radius * 0.95
	shape.height = hurt_top + hurt_radius * 0.6
	var cs := CollisionShape3D.new()
	cs.shape = shape
	cs.position = Vector3(0, shape.height * 0.5, 0)
	add_child(cs)
	floor_snap_length = 0.3
	floor_max_angle = deg_to_rad(50.0)


func forward() -> Vector3:
	return Combat.dir_of(facing)


func set_facing(yaw: float) -> void:
	facing = yaw
	if pivot:
		pivot.rotation.y = facing


## Turns toward a world position at up to `rate_deg` per second.
func turn_toward(target: Vector3, rate_deg: float, delta: float) -> void:
	var to := Combat.flat(target - global_position)
	if to.length() < 0.01:
		return
	var want := Combat.yaw_of(to)
	var diff := wrapf(want - facing, -PI, PI)
	var step := deg_to_rad(rate_deg) * delta
	set_facing(facing + clampf(diff, -step, step))


func face_now(target: Vector3) -> void:
	var to := Combat.flat(target - global_position)
	if to.length() > 0.01:
		set_facing(Combat.yaw_of(to))


func hurt_capsule() -> Array:
	var p := global_position
	return [p + Vector3(0, hurt_bottom, 0), p + Vector3(0, hurt_top, 0), hurt_radius]


func distance_to_opponent() -> float:
	if opponent == null:
		return 999.0
	return Combat.flat(opponent.global_position - global_position).length()


## Horizontal velocity from the animator's root motion (facing space -> world).
func root_motion_velocity(delta: float) -> Vector3:
	if not root_motion_enabled or delta <= 0.0:
		return Vector3.ZERO
	var rd := anim.root_delta * root_scale
	var world := Basis(Vector3.UP, facing) * Vector3(rd.x, 0.0, rd.z)
	if opponent != null:
		var to := Combat.flat(opponent.global_position - global_position)
		var dist := to.length()
		if dist > 0.001:
			var n := to / dist
			var toward := world.dot(n)
			var allowed := maxf(0.0, dist - min_opponent_distance)
			if toward > allowed:
				world -= n * (toward - allowed)
	return world / delta


func apply_motion(delta: float, planar: Vector3) -> void:
	_extra_velocity = _extra_velocity.move_toward(Vector3.ZERO, 14.0 * delta)
	velocity.x = planar.x + _extra_velocity.x
	velocity.z = planar.z + _extra_velocity.z
	if not is_on_floor():
		velocity.y -= GRAVITY * delta
	elif velocity.y < 0.0:
		velocity.y = -0.5
	move_and_slide()


func push(v: Vector3) -> void:
	_extra_velocity += Combat.flat(v)


# --- Vitals ------------------------------------------------------------------------------
func add_posture(amount: float, can_break := true) -> bool:
	_since_posture_hit = 0.0
	posture = clampf(posture + amount, 0.0, max_posture if can_break else max_posture - 1.0)
	vitals_changed.emit()
	return can_break and posture >= max_posture


func tick_posture(delta: float, regen_mult := 1.0) -> void:
	_since_posture_hit += delta
	if _since_posture_hit > posture_delay and posture > 0.0:
		posture = maxf(0.0, posture - posture_regen * regen_mult * delta)
		vitals_changed.emit()


func damage(amount: float) -> void:
	hp = maxf(0.0, hp - amount)
	vitals_changed.emit()


# --- Weapon hit detection ------------------------------------------------------------------
## Call every physics tick after the pose is applied. Tests each active hit window of
## the current clip against the opponent's hurtbox and calls `_on_weapon_contact`.
func process_weapon_hits() -> void:
	if anim.clip == null or anim.loco_active:
		_blade_prev.clear()
		return
	if anim.clip.name != _hit_clip:
		_hit_clip = anim.clip.name
		_hits_done.clear()
	var t := anim.time
	var now_pts := {}
	for bname in rig.blades:
		now_pts[bname] = rig.blade_world(bname)
	if opponent != null and opponent.can_be_hit():
		var cap := opponent.hurt_capsule()
		for i in anim.clip.hits.size():
			var h: Dictionary = anim.clip.hits[i]
			if _hits_done.has(i):
				continue
			if t < float(h["from"]) or t > float(h["to"]):
				continue
			var blade := str(h.get("blade", ""))
			if not now_pts.has(blade):
				continue
			var prev: PackedVector3Array = _blade_prev.get(blade, PackedVector3Array())
			var res := Combat.blade_vs_capsule(prev, now_pts[blade], cap[0], cap[1], float(cap[2]) + 0.03)
			if res.is_empty():
				continue
			_hits_done[i] = true
			var info := h.duplicate()
			info["index"] = i
			info["clip"] = anim.clip.name
			info["point"] = res["point"]
			# Contact moment inside this tick (sub-tick precise game time).
			info["time"] = Game.clock - Game.tick_delta * (1.0 - float(res["frac"]))
			_on_weapon_contact(info)
	for bname in now_pts:
		_blade_prev[bname] = now_pts[bname]


## Clears per-clip hit bookkeeping (call when (re)starting a clip).
func reset_hits() -> void:
	_hits_done.clear()
	_blade_prev.clear()
	_hit_clip = anim.clip.name if anim.clip != null else ""


func can_be_hit() -> bool:
	return true


func _on_weapon_contact(_info: Dictionary) -> void:
	pass


func _on_anim_event(_clip: String, _ev: Dictionary) -> void:
	pass
