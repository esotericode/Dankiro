class_name Hud
extends CanvasLayer
## Fight HUD + overlays. Built in code; designed for a 1920x1080 canvas (stretch mode
## canvas_items), anchored so it adapts to other aspect ratios.

const CONTROLS_TEXT := """[b]KEYBOARD / MOUSE[/b]                         [b]GAMEPAD[/b]
Move ............ WASD                        Left stick
Camera .......... Mouse                       Right stick
Attack .......... Left mouse / J              RB
Guard / Deflect . Right mouse / K             LB
Dodge (hold: run) Shift                       B
Jump ............ Space                       A
Lock on ......... Q / Middle mouse            R3
Heal (gourd) .... R                           X
Pause ........... Esc                         Start
Controls ........ F1                          Back
Diagnostics ..... F3     Fullscreen .... F11

[b]HOW TO FIGHT[/b]
- Tap guard just before a blade lands to [color=#ffd27a]DEFLECT[/color] (0.2 s window). Re-pressing within
  0.5 s of letting go shrinks the window; a clean deflect restores it. Holding guard only blocks.
- Your slashes commit: guard can only cut in at the very start of a swing or after it.
- Fill his posture bar with deflects, then press Attack on the red mark: [color=#ff5040]DEATHBLOW[/color].
- [img=26x26]res://textures/kanji_danger_icon.png[/img] Perilous THRUST: he draws the staff back, holds... press Dodge with [i]no direction[/i]
  as he RELEASES for a MIKIRI COUNTER. During the pull-back is too early. Deflecting works; blocking or backing off fails.
- [img=26x26]res://textures/kanji_danger_icon.png[/img] Perilous SWEEP: low and long - you can't back out of it. JUMP, then jump again to kick.
- Shuriken: he leaps back and throws 3 fast + 1 late, or 5 fast. Deflect each one.
- His posture recovers when you back off, and faster while his vitality is high."""

var player: Player
var boss: Boss

var _font: Font
var _root: Control
var _boss_name: Label
var _boss_hp: VitalityBar
var _boss_posture: PostureBar
var _marks: Control
var _player_hp: VitalityBar
var _player_posture: PostureBar
var _heal_label: Label
var _gourd_icon: GourdDisplay
var _callout: Label
var _prompt: Label
var _reticle: Control
var _vignette: TextureRect
var _debug: Label
var _debug_panel: PanelContainer
var _namecard: Control
var _overlay: Control
var _overlay_kanji: TextureRect
var _overlay_title: Label
var _overlay_sub: Label
var _panel: PanelContainer
var _help_visible := false
var _last_timing := "—"
var _tex: Dictionary = {}


func _ready() -> void:
	layer = 10
	process_mode = Node.PROCESS_MODE_ALWAYS
	Game.hud = self
	if ResourceLoader.exists("res://fonts/ui_serif.ttf"):
		_font = load("res://fonts/ui_serif.ttf")
	for k in ["kanji_death", "kanji_execution", "kanji_danger"]:
		var path := "res://textures/%s.png" % k
		if ResourceLoader.exists(path):
			_tex[k] = load(path)
	_root = Control.new()
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_root)
	_build_vignette()
	_build_boss_ui()
	_build_player_ui()
	_build_center()
	_build_overlay()
	_build_panel()
	Game.debug_toggled.connect(func(_on: bool): _debug_panel.visible = Game.debug)


func bind(p: Player, b: Boss) -> void:
	player = p
	boss = b
	_boss_name.text = b.display_name
	p.heal_charges_changed.connect(_set_heal_charges)
	_set_heal_charges(p.heal_charges)
	p.deflect_timed.connect(_on_deflect_timed)
	b.posture_broken.connect(func(): _boss_posture.flash())


# ------------------------------------------------------------------------------ building
func _place(c: Control, anchor: Vector2, pos: Vector2, sz: Vector2) -> void:
	c.anchor_left = anchor.x
	c.anchor_right = anchor.x
	c.anchor_top = anchor.y
	c.anchor_bottom = anchor.y
	c.offset_left = pos.x
	c.offset_top = pos.y
	c.offset_right = pos.x + sz.x
	c.offset_bottom = pos.y + sz.y


func _label(text: String, font_size: int, color: Color, align := HORIZONTAL_ALIGNMENT_LEFT) -> Label:
	var l := Label.new()
	l.text = text
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	l.horizontal_alignment = align
	if _font:
		l.add_theme_font_override("font", _font)
	l.add_theme_font_size_override("font_size", font_size)
	l.add_theme_color_override("font_color", color)
	l.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.8))
	l.add_theme_constant_override("outline_size", maxi(2, font_size / 9))
	return l


func _build_vignette() -> void:
	var g := Gradient.new()
	g.set_color(0, Color(0.6, 0.0, 0.0, 0.0))
	g.set_color(1, Color(0.55, 0.0, 0.0, 0.85))
	g.add_point(0.55, Color(0.6, 0.0, 0.0, 0.0))
	var t := GradientTexture2D.new()
	t.gradient = g
	t.fill = GradientTexture2D.FILL_RADIAL
	t.fill_from = Vector2(0.5, 0.5)
	t.fill_to = Vector2(1.05, 0.5)
	t.width = 256
	t.height = 256
	_vignette = TextureRect.new()
	_vignette.texture = t
	_vignette.stretch_mode = TextureRect.STRETCH_SCALE
	_vignette.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_vignette.set_anchors_preset(Control.PRESET_FULL_RECT)
	_vignette.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_vignette.modulate.a = 0.0
	_root.add_child(_vignette)


func _build_boss_ui() -> void:
	_marks = MarksDisplay.new()
	_place(_marks, Vector2(0, 0), Vector2(60, 47), Vector2(24 * Combat.BOSS_LIVES + 12, 24))
	_root.add_child(_marks)
	_boss_name = _label("", 32, Color(0.95, 0.91, 0.83))
	_place(_boss_name, Vector2(0, 0), Vector2(60 + 24 * Combat.BOSS_LIVES + 22, 36), Vector2(700, 44))
	_root.add_child(_boss_name)
	var vitality := _label("V I T A L I T Y", 16, Color(0.73, 0.61, 0.45))
	_place(vitality, Vector2.ZERO, Vector2(60, 80), Vector2(210, 24))
	_root.add_child(vitality)
	_boss_hp = VitalityBar.new()
	_boss_hp.fill_color = Color(0.73, 0.19, 0.13)
	_place(_boss_hp, Vector2(0, 0), Vector2(60, 108), Vector2(560, 10))
	_root.add_child(_boss_hp)
	_boss_posture = PostureBar.new()
	_place(_boss_posture, Vector2(0.5, 0), Vector2(-300, 46), Vector2(600, 12))
	_root.add_child(_boss_posture)


func _build_player_ui() -> void:
	_player_hp = VitalityBar.new()
	_player_hp.fill_color = Color(0.78, 0.24, 0.16)
	_place(_player_hp, Vector2(0, 1), Vector2(60, -62), Vector2(440, 12))
	_root.add_child(_player_hp)
	var vitality := _label("V I T A L I T Y", 16, Color(0.73, 0.61, 0.45))
	_place(vitality, Vector2(0, 1), Vector2(60, -91), Vector2(210, 24))
	_root.add_child(vitality)
	_gourd_icon = GourdDisplay.new()
	_place(_gourd_icon, Vector2(0, 1), Vector2(56, -178), Vector2(50, 62))
	_root.add_child(_gourd_icon)
	_heal_label = _label("", 25, Color(0.94, 0.87, 0.72))
	_place(_heal_label, Vector2(0, 1), Vector2(114, -164), Vector2(360, 38))
	_root.add_child(_heal_label)
	var heal_key := _label("R  /  X", 16, Color(0.69, 0.66, 0.59))
	_place(heal_key, Vector2(0, 1), Vector2(116, -130), Vector2(180, 22))
	_root.add_child(heal_key)
	_player_posture = PostureBar.new()
	_place(_player_posture, Vector2(0.5, 1), Vector2(-210, -112), Vector2(420, 10))
	_root.add_child(_player_posture)


func _set_heal_charges(n: int) -> void:
	_heal_label.text = "HEALING GOURD    ×%d" % n
	_gourd_icon.modulate.a = 1.0 if n > 0 else 0.42


func _build_center() -> void:
	_callout = _label("", 44, Color(0.98, 0.81, 0.55), HORIZONTAL_ALIGNMENT_CENTER)
	_place(_callout, Vector2(0.5, 0.5), Vector2(-500, -260), Vector2(1000, 60))
	_callout.modulate.a = 0.0
	_root.add_child(_callout)
	_prompt = _label("", 28, Color(1.0, 0.65, 0.48), HORIZONTAL_ALIGNMENT_CENTER)
	_place(_prompt, Vector2(0.5, 1), Vector2(-400, -200), Vector2(800, 40))
	_root.add_child(_prompt)
	_reticle = ReticleDisplay.new()
	_reticle.size = Vector2(24, 24)
	_root.add_child(_reticle)
	_debug_panel = PanelContainer.new()
	_debug_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var dsb := StyleBoxFlat.new()
	dsb.bg_color = Color(0.0, 0.02, 0.0, 0.62)
	dsb.set_content_margin_all(12)
	dsb.set_corner_radius_all(3)
	_debug_panel.add_theme_stylebox_override("panel", dsb)
	_debug_panel.anchor_left = 1.0
	_debug_panel.anchor_right = 1.0
	_debug_panel.offset_left = -812
	_debug_panel.offset_right = -24
	_debug_panel.offset_top = 64
	_debug = Label.new()
	_debug.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var dmono := SystemFont.new()
	dmono.font_names = PackedStringArray(["DejaVu Sans Mono", "Consolas", "Menlo", "Courier New", "monospace"])
	_debug.add_theme_font_override("font", dmono)
	_debug.add_theme_font_size_override("font_size", 16)
	_debug.add_theme_color_override("font_color", Color(0.82, 1.0, 0.82))
	_debug_panel.add_child(_debug)
	_debug_panel.visible = Game.debug
	_root.add_child(_debug_panel)
	_namecard = VBoxContainer.new()
	_namecard.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_place(_namecard, Vector2(0.5, 1), Vector2(-600, -330), Vector2(1200, 150))
	var n1 := _label("Sojin, the Twin Fang", 58, Color(0.96, 0.92, 0.84), HORIZONTAL_ALIGNMENT_CENTER)
	var n2 := _label("Warden of the Moon Gate", 26, Color(0.78, 0.61, 0.4), HORIZONTAL_ALIGNMENT_CENTER)
	_namecard.add_child(n1)
	_namecard.add_child(n2)
	_namecard.modulate.a = 0.0
	_root.add_child(_namecard)


func _build_overlay() -> void:
	_overlay = Control.new()
	_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_overlay.visible = false
	_root.add_child(_overlay)
	var shade := ColorRect.new()
	shade.color = Color(0, 0, 0, 0.55)
	shade.set_anchors_preset(Control.PRESET_FULL_RECT)
	shade.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_overlay.add_child(shade)
	_overlay_kanji = TextureRect.new()
	_overlay_kanji.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_overlay_kanji.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_overlay_kanji.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_place(_overlay_kanji, Vector2(0.5, 0.5), Vector2(-360, -380), Vector2(720, 520))
	_overlay.add_child(_overlay_kanji)
	_overlay_title = _label("", 54, Color(0.95, 0.9, 0.85), HORIZONTAL_ALIGNMENT_CENTER)
	_place(_overlay_title, Vector2(0.5, 0.5), Vector2(-700, 150), Vector2(1400, 70))
	_overlay.add_child(_overlay_title)
	_overlay_sub = _label("", 26, Color(0.85, 0.8, 0.72), HORIZONTAL_ALIGNMENT_CENTER)
	_place(_overlay_sub, Vector2(0.5, 0.5), Vector2(-700, 235), Vector2(1400, 40))
	_overlay.add_child(_overlay_sub)


func _build_panel() -> void:
	_panel = PanelContainer.new()
	_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.03, 0.03, 0.04, 0.88)
	sb.border_color = Color(0.7, 0.58, 0.36, 0.8)
	sb.set_border_width_all(2)
	sb.set_content_margin_all(28)
	sb.set_corner_radius_all(4)
	_panel.add_theme_stylebox_override("panel", sb)
	_place(_panel, Vector2(0.5, 0.5), Vector2(-560, -330), Vector2(1120, 660))
	var rt := RichTextLabel.new()
	rt.bbcode_enabled = true
	rt.fit_content = true
	rt.scroll_active = false
	rt.mouse_filter = Control.MOUSE_FILTER_IGNORE
	rt.add_theme_font_size_override("normal_font_size", 21)
	rt.add_theme_font_size_override("bold_font_size", 22)
	rt.add_theme_color_override("default_color", Color(0.9, 0.87, 0.8))
	var mono := SystemFont.new()
	mono.font_names = PackedStringArray(["DejaVu Sans Mono", "Consolas", "Menlo", "Courier New", "monospace"])
	rt.add_theme_font_override("normal_font", mono)
	rt.text = CONTROLS_TEXT
	_panel.add_child(rt)
	_panel.visible = false
	_root.add_child(_panel)


# ------------------------------------------------------------------------------ runtime
func _process(delta: float) -> void:
	var real_dt := minf(delta / maxf(Engine.time_scale, 0.001), 0.1)
	if player != null:
		_player_hp.set_ratio(player.hp / player.max_hp)
		_player_posture.set_ratio(player.posture / player.max_posture)
	if boss != null:
		_boss_hp.set_ratio(boss.hp / boss.max_hp)
		_boss_posture.set_ratio(boss.posture / boss.max_posture)
		(_marks as MarksDisplay).total = Combat.BOSS_LIVES
		(_marks as MarksDisplay).left = boss.lives_left
		_update_reticle()
		var db_ready := boss.is_deathblow_ready() and player != null and player.distance_to_opponent() < 3.0
		_prompt.text = "[ Attack ]  Deathblow" if db_ready else ""
	if _vignette.modulate.a > 0.0:
		_vignette.modulate.a = maxf(0.0, _vignette.modulate.a - real_dt * 1.8)
	if player != null and player.hp / player.max_hp < 0.25 and player.hp > 0.0:
		_vignette.modulate.a = maxf(_vignette.modulate.a, 0.28 + 0.1 * sin(Time.get_ticks_msec() / 180.0))
	if _debug_panel.visible:
		_update_debug()


func _update_reticle() -> void:
	var cam := get_viewport().get_camera_3d()
	if cam == null or player == null or not player.locked or boss.is_dead():
		_reticle.visible = false
		return
	var p := boss.rig.joint_world("chest") + Vector3(0, 0.1, 0)
	if cam.is_position_behind(p):
		_reticle.visible = false
		return
	_reticle.visible = true
	# unproject_position returns coordinates in the (stretched) canvas space the HUD uses.
	var sp := cam.unproject_position(p)
	_reticle.position = sp - _reticle.size * 0.5


func flash_damage() -> void:
	_vignette.modulate.a = 0.85


func show_callout(text: String) -> void:
	_callout.text = text
	var tw := _callout.create_tween()
	_callout.modulate.a = 0.0
	_callout.scale = Vector2(1.15, 1.15)
	_callout.pivot_offset = _callout.size * 0.5
	tw.set_parallel(true)
	tw.tween_property(_callout, "modulate:a", 1.0, 0.08)
	tw.tween_property(_callout, "scale", Vector2.ONE, 0.18).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tw.chain().tween_interval(0.9)
	tw.chain().tween_property(_callout, "modulate:a", 0.0, 0.4)


func show_namecard() -> void:
	var tw := _namecard.create_tween()
	tw.tween_property(_namecard, "modulate:a", 1.0, 0.8)
	tw.tween_interval(2.0)
	tw.tween_property(_namecard, "modulate:a", 0.0, 1.0)


func show_death() -> void:
	_show_overlay("kanji_death", "DEATH", "Enter / (A)  try again        Esc / (Start)  title menu", Color(0.85, 0.08, 0.06))


func show_victory() -> void:
	_show_overlay("kanji_execution", "SHINOBI EXECUTION", "Enter / (A)  fight again        Esc / (Start)  title menu",
		Color(0.9, 0.12, 0.08))


func hide_overlay() -> void:
	_overlay.visible = false


func _show_overlay(tex_key: String, title: String, sub: String, tint: Color) -> void:
	_overlay.visible = true
	_overlay_kanji.texture = _tex.get(tex_key)
	_overlay_kanji.modulate = tint
	_overlay_title.text = title
	_overlay_sub.text = sub
	_overlay.modulate.a = 0.0
	var tw := _overlay.create_tween()
	tw.tween_property(_overlay, "modulate:a", 1.0, 1.2)


func set_panel_visible(v: bool) -> void:
	_panel.visible = v


func toggle_help() -> void:
	_help_visible = not _help_visible
	_panel.visible = _help_visible


func _on_deflect_timed(ms: float, window_ms: float, result: String) -> void:
	match result:
		"deflect":
			_last_timing = "DEFLECT  pressed %.0f ms before contact  (window %.0f ms)" % [ms, window_ms]
		"early":
			_last_timing = "TOO EARLY  pressed %.0f ms before contact  (window %.0f ms)" % [ms, window_ms]
		"late":
			_last_timing = "TOO LATE  pressed %.0f ms after contact" % [-ms]
		"miss":
			_last_timing = "NOT GUARDING  (last press %.0f ms before contact)" % ms


## The diagnostics readout (Options > Diagnostics, or F3); the 3D part is `Diagnostics`.
func _update_debug() -> void:
	var lines := PackedStringArray()
	lines.append("DIAGNOSTICS (F3)")
	lines.append("hurtbox  green hittable, cyan i-frames, yellow open, grey ignores hits")
	lines.append("weapon   red hit window, orange perilous, yellow your katana")
	lines.append("fire     orange arms/ring/blast (Inferno), flames up to the jump line")
	lines.append("guard    gold deflect window (shrinks), blue block")
	lines.append("last guard: " + _last_timing)
	lines.append("")
	if player:
		var p_regen := Combat.PLAYER_POSTURE_REGEN * (Combat.PLAYER_POSTURE_REGEN_GUARD if player.state == Player.S.GUARD else 1.0) \
			* (0.45 + 0.55 * player.hp / player.max_hp)
		var inv := "  I-FRAMES" if player.is_dodge_invulnerable() else ""
		lines.append("YOU    %s%s   hp %.0f/%.0f   posture %.0f/%.0f (-%.1f/s)" % [Player.S.keys()[player.state], inv,
			player.hp, player.max_hp, player.posture, player.max_posture, p_regen])
		lines.append("       deflect window %.0f ms (spam %d)   chain %d   gourd x%d" % [player.guard_window * 1000.0,
			player.spam_level, player.deflect_chain, player.heal_charges])
	if boss:
		var b_regen := boss.posture_regen * (0.3 + 0.7 * boss.hp / boss.max_hp)
		lines.append("SOJIN  phase %d   lives %d/%d   %s %s   seq %s" % [boss.phase, boss.lives_left, Combat.BOSS_LIVES,
			Boss.S.keys()[boss.state], boss._mode, boss._seq_name if boss._seq_name != "" else "-"])
		lines.append("       hp %.0f/%.0f   posture %.0f/%.0f (-%.1f/s after %.1f s)" % [boss.hp, boss.max_hp,
			boss.posture, boss.max_posture, b_regen, boss.posture_delay])
		lines.append("       cooldown %.2f   reeling %d/%d   guard %d/%d" % [maxf(0.0, boss.cooldown),
			boss._flinches, boss._breakout_after, boss._guard_count, boss._parry_threshold])
		lines.append("       " + _boss_clip_line())
		if boss.inferno != null and (boss.inferno.is_active() or boss.phase >= 2):
			lines.append("       " + _inferno_line())
	if player and boss:
		lines.append("distance %.2f m   fps %d   time scale %.2f" % [player.distance_to_opponent(),
			Engine.get_frames_per_second(), Engine.time_scale])
	_debug.text = "\n".join(lines)


## The Inferno: what stage it's at, passes, when the next arm reaches you; or when he may use it.
func _inferno_line() -> String:
	var inf := boss.inferno
	if not inf.is_active():
		var wait := boss._inferno_at - Game.clock
		return "inferno  used %d   next %s" % [boss.inferno_uses, "ready" if wait <= 0.0 else ("%.0f s" % wait if wait < 1e6 else "-")]
	var s := "INFERNO  %s   passes %d/%d   burned %d   fire top %.2f m   turning %.0f deg/s" % [inf.stage_name(), inf.passes,
		Inferno.PASSES, inf.hits, inf.fire_top, inf._omega]
	var n := inf.next_jump_in()
	if n < INF:
		s += "   jump in %.2f s" % n
	if inf.erupting():
		s += "   ERUPTING"
	return s


## His current clip, and where it is relative to its hit windows.
func _boss_clip_line() -> String:
	var a := boss.anim
	if a.clip == null or a.loco_active:
		return "moving (locomotion)"
	var s := "%s %.2f/%.2f s" % [a.clip.name, a.time, a.clip.length]
	var next := INF
	for i in a.clip.hits.size():
		var h: Dictionary = a.clip.hits[i]
		if a.time >= float(h["from"]) and a.time <= float(h["to"]):
			return s + "   HIT WINDOW %d open (%.2f-%.2f %s)" % [i, float(h["from"]), float(h["to"]),
				str(h.get("kind", "normal"))]
		if float(h["from"]) > a.time:
			next = minf(next, float(h["from"]))
	if next < INF:
		return s + "   next hit in %.2f s" % ((next - a.time) / maxf(a.speed, 0.01))
	return s


# ------------------------------------------------------------------------------ small widgets
class MarksDisplay extends Control:
	var total := Combat.BOSS_LIVES
	var left := Combat.BOSS_LIVES

	func _ready() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func _process(_d: float) -> void:
		queue_redraw()

	func _draw() -> void:
		for i in total:
			var c := Vector2(10 + i * 24, 12)
			draw_circle(c, 9.0, Color(0.025, 0.022, 0.022, 0.9))
			draw_arc(c, 8.0, 0.0, TAU, 24, Color(0.72, 0.53, 0.35, 0.8), 1.2)
			if i < left:
				draw_circle(c, 5.5, Color(0.75, 0.15, 0.1))
				draw_circle(c + Vector2(-1.5, -2), 1.5, Color(1, 0.69, 0.49, 0.75))
			else:
				draw_circle(c, 4.0, Color(0.24, 0.21, 0.19, 0.7))


## A small, scalable ink-and-brass silhouette; drawn in UI space so it stays crisp.
class GourdDisplay extends Control:
	func _ready() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func _draw() -> void:
		var s := size / Vector2(50, 62)
		var shape := PackedVector2Array([
			Vector2(22, 18), Vector2(18, 22), Vector2(17, 28), Vector2(20, 34),
			Vector2(13, 39), Vector2(10, 45), Vector2(11, 52), Vector2(16, 57),
			Vector2(25, 59), Vector2(34, 57), Vector2(39, 52), Vector2(40, 45),
			Vector2(37, 39), Vector2(30, 34), Vector2(33, 28), Vector2(32, 22), Vector2(28, 18)
		])
		for i in shape.size():
			shape[i] *= s
		draw_colored_polygon(shape, Color(0.18, 0.12, 0.08))
		var lit := PackedVector2Array([
			Vector2(22, 20), Vector2(19, 26), Vector2(22, 34), Vector2(15, 41),
			Vector2(13, 49), Vector2(18, 54), Vector2(25, 56), Vector2(33, 54),
			Vector2(37, 49), Vector2(34, 41), Vector2(28, 34), Vector2(31, 26), Vector2(28, 20)
		])
		for i in lit.size():
			lit[i] *= s
		draw_colored_polygon(lit, Color(0.57, 0.35, 0.19))
		shape.append(shape[0])
		draw_polyline(shape, Color(0.92, 0.72, 0.43, 0.9), 1.4)
		# The narrow neck, wooden stopper and tied cord read at HUD size.
		draw_rect(Rect2(Vector2(21, 10) * s, Vector2(8, 11) * s), Color(0.34, 0.23, 0.15))
		draw_rect(Rect2(Vector2(20, 9) * s, Vector2(10, 4) * s), Color(0.75, 0.55, 0.31))
		draw_line(Vector2(19, 18) * s, Vector2(31, 18) * s, Color(0.98, 0.82, 0.53), 2.0)
		draw_line(Vector2(30, 18) * s, Vector2(36, 25) * s, Color(0.86, 0.53, 0.32), 1.5)
		draw_arc(Vector2(25, 42) * s, 11.0 * s.x, 0.15, PI - 0.15, 18, Color(0.9, 0.65, 0.37, 0.65), 1.3)
		draw_line(Vector2(17, 43) * s, Vector2(18, 50) * s, Color(1, 0.78, 0.47, 0.55), 1.4)


class ReticleDisplay extends Control:

	func _ready() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func _process(_d: float) -> void:
		queue_redraw()

	func _draw() -> void:
		var c := size * 0.5
		draw_circle(c, 5.0, Color(0, 0, 0, 0.5))
		draw_circle(c, 3.2, Color(1, 1, 1, 0.9))
