class_name Diagnostics
extends Node3D
## Diagnostics overlay (Options > Diagnostics, or F3 in a fight). Draws, over everything:
##  * both fighters' hurtboxes, at the radius the hit tests actually use:
##      green  = can be hit
##      cyan   = i-frames (your dodge: not against sweeps; also after a knockdown / his hop back)
##      yellow = he's open: a hit now makes him reel (recoil, flinch, recovery)
##      grey   = hits are ignored (staggered, getting up, deathblow)
##  * the weapons: dim while idle, lit while a hit window is open (red; orange for a perilous
##    attack; yellow for your katana). His whole staff counts, so all of it lights up.
##  * your guard: a ring at your feet, gold while the deflect window is open (it shrinks as the
##    window runs out), blue when only a block is left.
##  * shuriken in flight (with where they'll be in 0.1 s) and a marker where each blow landed:
##    gold deflect, blue block, red hit, magenta mikiri, cyan dodged.
##  * his Inferno: the blast radius while he channels (and the blast front), each arm of fire
##    as a line at the height you have to clear (orange while it can hit you), the ring round
##    him, and the eruption (rings across the arena at the height to clear; dim while the
##    cracks spread, bright while it burns). His hurtbox is orange while the fire turns your sword.
## The HUD adds the live readout (Hud._update_debug). Keeps drawing while paused.

const C_HURT := Color(0.3, 1.0, 0.45, 0.9)
const C_IFRAMES := Color(0.35, 0.8, 1.0, 0.95)
const C_OPEN := Color(1.0, 0.92, 0.25, 0.95)
const C_IGNORED := Color(0.55, 0.55, 0.6, 0.7)
const C_WEAPON := Color(0.8, 0.8, 0.85, 0.45)
const C_ACTIVE := Color(1.0, 0.18, 0.12, 1.0)
const C_PERILOUS := Color(1.0, 0.5, 0.0, 1.0)
const C_KATANA := Color(1.0, 0.95, 0.3, 1.0)
const C_DEFLECT := Color(1.0, 0.8, 0.25, 1.0)
const C_BLOCK := Color(0.4, 0.62, 1.0, 1.0)
const C_SHURIKEN := Color(1.0, 0.55, 0.2, 1.0)
const C_FIRE := Color(1.0, 0.45, 0.05, 1.0)
const C_MANTLE := Color(1.0, 0.5, 0.1, 0.95)
const MARK_TIME := 0.9

var player: Player
var boss: Boss
var _im: ImmediateMesh
var _mat: StandardMaterial3D
var _pts := PackedVector3Array()
var _cols := PackedColorArray()
var _marks: Array = []              ## [position, colour, seconds left]


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_im = ImmediateMesh.new()
	var mi := MeshInstance3D.new()
	mi.mesh = _im
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.extra_cull_margin = 16384.0
	add_child(mi)
	_mat = StandardMaterial3D.new()
	_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_mat.vertex_color_use_as_albedo = true
	_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_mat.no_depth_test = true
	_mat.render_priority = 20


func bind(p: Player, b: Boss) -> void:
	player = p
	boss = b
	p.hit_resolved.connect(func(info: Dictionary, res: int):
		_mark(info.get("point", p.global_position + Vector3.UP), res))
	b.struck.connect(func(res: int, point: Vector3): _mark(point, res))


func _mark(pos: Vector3, res: int) -> void:
	if not Game.debug:
		return
	var c := Color(1, 1, 1)
	match res:
		Combat.RESULT_DEFLECT:
			c = C_DEFLECT
		Combat.RESULT_BLOCK:
			c = C_BLOCK
		Combat.RESULT_HIT:
			c = C_ACTIVE
		Combat.RESULT_MIKIRI:
			c = Color(1.0, 0.3, 1.0)
		Combat.RESULT_EVADED:
			c = C_IFRAMES
	_marks.append([pos, c, MARK_TIME])


func _process(delta: float) -> void:
	_im.clear_surfaces()
	if not Game.debug or player == null or boss == null:
		_marks.clear()
		return
	var real_dt := minf(delta / maxf(Engine.time_scale, 0.001), 0.1)
	_pts.clear()
	_cols.clear()
	_hurtboxes()
	_weapon(boss, C_ACTIVE)
	_weapon(player, C_KATANA)
	_guard_ring()
	_shuriken()
	_inferno()
	for m in _marks:
		if not get_tree().paused:
			m[2] = float(m[2]) - real_dt
		var c: Color = m[1]
		c.a = clampf(float(m[2]) / MARK_TIME, 0.0, 1.0)
		for o in [Vector3.ZERO, Vector3(0.01, 0.01, 0), Vector3(-0.01, -0.01, 0)]:
			_star(m[0] + o, 0.16, c)
	_marks = _marks.filter(func(m): return float(m[2]) > 0.0)
	if _pts.is_empty():
		return
	_im.surface_begin(Mesh.PRIMITIVE_LINES, _mat)
	for i in _pts.size():
		_im.surface_set_color(_cols[i])
		_im.surface_add_vertex(_pts[i])
	_im.surface_end()


# ------------------------------------------------------------------------------ what to draw
func _hurtboxes() -> void:
	# The blades are tested against the hurtbox inflated by 3 cm (Combatant.process_weapon_hits).
	var pc := C_HURT
	if not player.can_be_hit():
		pc = C_IGNORED
	elif player.is_dodge_invulnerable() or Game.clock < player._invuln_until:
		pc = C_IFRAMES
	_capsule(player.hurt_capsule(), 0.03, pc)
	var bc := C_HURT
	match boss.state:
		Boss.S.INTRO, Boss.S.STAGGER, Boss.S.DEATHBLOWN, Boss.S.REVIVE, Boss.S.DEAD:
			bc = C_IGNORED
		Boss.S.REACT:
			bc = C_OPEN
		Boss.S.INFERNO:
			bc = C_MANTLE
		_:
			if not boss.can_be_hit():
				bc = C_IFRAMES
			elif boss.state == Boss.S.ATTACK and boss._in_vuln():
				bc = C_OPEN
	_capsule(boss.hurt_capsule(), 0.03, bc)


func _weapon(c: Combatant, lit: Color) -> void:
	var active := {}
	var perilous := false
	if c.anim.clip != null and not c.anim.loco_active:
		perilous = str(c.anim.clip.raw.get("perilous", "")) != ""
		for h in c.anim.clip.hits:
			if c.anim.time >= float(h["from"]) and c.anim.time <= float(h["to"]):
				if c.rig.hit_whole_weapon:
					for bn in c.rig.blades:
						active[bn] = true
				else:
					active[str(h.get("blade", ""))] = true
	for bn in c.rig.blades:
		var pts := c.rig.blade_world(bn)
		var col := C_WEAPON
		if active.has(bn):
			col = C_PERILOUS if perilous else lit
		for i in range(pts.size() - 1):
			_thick_line(pts[i], pts[i + 1], col, 0.012 if active.has(bn) else 0.006)
		if active.has(bn) and pts.size() > 0:
			_star(pts[pts.size() - 1], 0.05, col)


func _guard_ring() -> void:
	if not player.is_guard_up():
		return
	var base := player.global_position + Vector3(0, 0.04, 0)
	var left := player.guard_window - (Game.clock - player.guard_start)
	if left >= 0.0 and player.guard_window > 0.0:
		_ring(base, 0.35 + 0.35 * left / player.guard_window, C_DEFLECT)
		_ring(base, 0.72, Color(C_DEFLECT, 0.5))
	else:
		_ring(base, 0.72, C_BLOCK)


func _shuriken() -> void:
	for n in player.get_parent().get_children():
		if n is Shuriken and (n as Shuriken)._flying:
			var s := n as Shuriken
			_star(s.global_position, 0.1, C_SHURIKEN)
			_line(s.global_position, s.global_position + s.velocity * 0.1, Color(C_SHURIKEN, 0.6))


func _inferno() -> void:
	var inf := boss.inferno
	if inf == null or not inf.is_active():
		return
	var c := inf.center + Vector3(0, 0.03, 0)
	if inf.charging():
		_ring(c, Inferno.BLAST_R, Color(C_FIRE, 0.9), 64)
	var br := inf.blast_radius()
	if br > 0.0:
		_ring(c, br, C_FIRE, 64)
	if inf.ring_live():
		_ring(c, Inferno.RING_R, C_FIRE, 48)
	if inf.fusing() or inf.erupting():
		var ec := C_FIRE if inf.erupting() else Color(C_FIRE, 0.35)
		for r in [2.0, 5.0, 8.0, 11.0, 14.0]:
			_ring(c + Vector3(0, 0.1, 0), r, ec, 64)
	if inf.stage == Inferno.St.SPIN or inf.stage == Inferno.St.WIND_DOWN:
		var col := C_FIRE if inf.arms_live() else Color(C_FIRE, 0.35)
		for yaw in inf.arm_yaws():
			var d := Combat.dir_of(float(yaw))
			var a := inf.center + d * Inferno.ARM_FROM
			var b := inf.center + d * Inferno.REACH
			var top := Vector3(0, inf.fire_top, 0)
			_thick_line(a + top, b + top, col, 0.02)
			_line(a + Vector3(0, 0.03, 0), b + Vector3(0, 0.03, 0), Color(col, 0.5))


# ------------------------------------------------------------------------------ primitives
func _line(a: Vector3, b: Vector3, c: Color) -> void:
	_pts.append(a)
	_pts.append(b)
	_cols.append(c)
	_cols.append(c)


## A line drawn as a bundle of five, `w` apart, so it reads as a few pixels wide.
func _thick_line(a: Vector3, b: Vector3, c: Color, w: float) -> void:
	for o in [Vector3.ZERO, Vector3(w, 0, 0), Vector3(-w, 0, 0), Vector3(0, w, 0), Vector3(0, -w, 0)]:
		_line(a + o, b + o, c)


func _ring(center: Vector3, r: float, c: Color, segments := 24) -> void:
	for i in segments:
		var a0 := TAU * float(i) / segments
		var a1 := TAU * float(i + 1) / segments
		_line(center + Vector3(cos(a0), 0, sin(a0)) * r, center + Vector3(cos(a1), 0, sin(a1)) * r, c)


func _star(p: Vector3, s: float, c: Color) -> void:
	_line(p - Vector3(s, 0, 0), p + Vector3(s, 0, 0), c)
	_line(p - Vector3(0, s, 0), p + Vector3(0, s, 0), c)
	_line(p - Vector3(0, 0, s), p + Vector3(0, 0, s), c)


## A vertical capsule [bottom centre, top centre, radius] (+ margin): rings, sides and caps.
func _capsule(cap: Array, margin: float, c: Color) -> void:
	var a: Vector3 = cap[0]
	var b: Vector3 = cap[1]
	var r := float(cap[2]) + margin
	_ring(a, r, c)
	_ring(b, r, c)
	_ring(a.lerp(b, 0.5), r, Color(c, c.a * 0.5))
	for k in 4:
		var d := Vector3(cos(k * PI * 0.5), 0, sin(k * PI * 0.5)) * r
		_line(a + d, b + d, c)
	for k in 2:
		var side := Vector3(cos(k * PI * 0.5), 0, sin(k * PI * 0.5))
		for i in 8:
			var t0 := PI * float(i) / 8.0
			var t1 := PI * float(i + 1) / 8.0
			# top cap arcs over the capsule, bottom cap under it
			_line(b + (side * cos(t0) + Vector3.UP * sin(t0)) * r, b + (side * cos(t1) + Vector3.UP * sin(t1)) * r, c)
			_line(a + (side * cos(t0) - Vector3.UP * sin(t0)) * r, a + (side * cos(t1) - Vector3.UP * sin(t1)) * r, c)
