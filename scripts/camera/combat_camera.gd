class_name CombatCamera
extends Node3D
## Third-person camera. Free orbit (mouse / right stick) or lock-on framing that keeps the
## boss centred behind the player, like Sekiro. Spring arm avoids walls; trauma-based shake.

var player: Player
var target: Node3D
var yaw := PI
var pitch := -0.22
var distance := 4.3
var height := 1.62
## Over-the-shoulder offset (to the right) so the boss stays visible beside you instead of
## being hidden behind your character during his wind-ups.
var shoulder := 0.75
## Lock-on looks this much further down than the line to the boss's chest: the camera rides
## high enough that his arms and staff show above your head at fighting distance.
var lock_tilt := 0.20
var mouse_sensitivity := GameInput.MOUSE_SENSITIVITY
var stick_sensitivity := GameInput.STICK_SENSITIVITY

var arm: SpringArm3D
var cam: Camera3D
## Shadowless key light that follows the camera and only lights the fighters (render layer 2),
## so they read clearly whichever way you face the moon, without flattening the arena.
var character_key: DirectionalLight3D
var _trauma := 0.0
var _trauma_decay := 3.0
var _shake_t := 0.0
var _follow := Vector3.ZERO
var _initialized := false


func _ready() -> void:
	arm = SpringArm3D.new()
	arm.spring_length = distance
	arm.margin = 0.25
	arm.collision_mask = 1
	arm.position = Vector3(shoulder, 0.0, 0.0)
	add_child(arm)
	var probe := SphereShape3D.new()
	probe.radius = 0.2
	arm.shape = probe
	# The spring arm overwrites its direct children's transforms, so shake goes on a grandchild.
	var holder := Node3D.new()
	arm.add_child(holder)
	cam = Camera3D.new()
	cam.fov = 60.0
	cam.near = 0.05
	cam.far = 500.0
	holder.add_child(cam)
	cam.current = true
	Game.camera = self
	process_priority = 100
	character_key = DirectionalLight3D.new()
	character_key.light_color = Color(0.86, 0.89, 1.0)
	character_key.light_energy = 0.85
	character_key.light_specular = 0.6
	character_key.shadow_enabled = false
	character_key.light_cull_mask = 2
	character_key.sky_mode = DirectionalLight3D.SKY_MODE_LIGHT_ONLY
	character_key.top_level = true
	add_child(character_key)


func setup(p: Player, t: Node3D) -> void:
	player = p
	target = t
	arm.clear_excluded_objects()
	arm.add_excluded_object(p.get_rid())
	if t is CollisionObject3D:
		arm.add_excluded_object((t as CollisionObject3D).get_rid())
	_follow = p.global_position + Vector3(0, height, 0)
	global_position = _follow
	if t != null:
		yaw = Combat.yaw_of(Combat.flat(t.global_position - p.global_position))
	_initialized = true


func get_yaw() -> float:
	return yaw


func add_shake(strength: float, duration := 0.25) -> void:
	_trauma = clampf(maxf(_trauma, strength), 0.0, 1.0)
	_trauma_decay = 1.0 / maxf(duration, 0.05)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and (event as InputEventMouseButton).pressed \
			and Input.mouse_mode != Input.MOUSE_MODE_CAPTURED and not get_tree().paused \
			and player != null and player.controls_enabled:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		if player != null and player.locked:
			return
		var mm := event as InputEventMouseMotion
		yaw -= mm.relative.x * mouse_sensitivity
		pitch = clampf(pitch - mm.relative.y * mouse_sensitivity, -1.2, 0.55)


func _process(delta: float) -> void:
	if not _initialized or player == null:
		return
	var real_dt := delta / maxf(Engine.time_scale, 0.001)
	real_dt = minf(real_dt, 0.1)
	var head := player.global_position + Vector3(0, height, 0)
	_follow = _follow.lerp(head, 1.0 - exp(-delta * 14.0))
	global_position = _follow
	if player.locked and target != null:
		var tgt := target.global_position + Vector3(0, 1.25, 0)
		var to := tgt - head
		var flat_d := Combat.flat(to).length()
		if flat_d > 0.35:
			var want_yaw := Combat.yaw_of(Combat.flat(to))
			yaw = lerp_angle(yaw, want_yaw, 1.0 - exp(-delta * 8.0))
		var want_pitch := clampf(atan2(to.y, maxf(flat_d, 0.5)) - lock_tilt, -0.75, 0.3)
		pitch = lerpf(pitch, want_pitch, 1.0 - exp(-delta * 5.0))
	else:
		var look := Input.get_vector("cam_left", "cam_right", "cam_up", "cam_down")
		yaw -= look.x * stick_sensitivity * real_dt
		pitch = clampf(pitch - look.y * stick_sensitivity * 0.7 * real_dt, -1.2, 0.55)
	rotation = Vector3(pitch, yaw, 0.0)
	# Key light from above the camera's right shoulder, looking along the view.
	var key_dir := Basis(Vector3.UP, yaw + 0.35) * Vector3(0.0, -0.62, -1.0)
	character_key.global_basis = Basis.looking_at(key_dir.normalized(), Vector3.UP)
	# Pull in a little when looking up so the ground doesn't fill the screen.
	arm.spring_length = lerpf(distance, distance * 0.8, clampf(pitch / 0.55, 0.0, 1.0))
	_apply_shake(real_dt)


func _apply_shake(real_dt: float) -> void:
	_shake_t += real_dt * 38.0
	_trauma = maxf(0.0, _trauma - _trauma_decay * real_dt)
	var s := _trauma * _trauma
	cam.rotation = Vector3(
		s * 0.045 * sin(_shake_t * 1.13 + 1.7),
		s * 0.045 * sin(_shake_t * 0.97 + 4.1),
		s * 0.03 * sin(_shake_t * 1.31))
	cam.position = Vector3(s * 0.06 * sin(_shake_t * 1.7), s * 0.05 * sin(_shake_t * 2.1 + 0.5), 0.0)
