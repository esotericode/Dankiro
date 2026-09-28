class_name Hud
extends CanvasLayer
## Fight HUD + overlays, built in code for a 1920x1080 canvas (stretch mode canvas_items) and
## anchored so it adapts to other aspect ratios. The look is UiTheme's: flat bars, ivory
## and ink with vermilion for what matters (damage, deathblows, death).
##
## Like Sekiro: his vitality and deathblow marks top left, his posture top centre, yours bottom
## centre, your vitality and the gourd bottom left.


var player: Player
var boss: Boss

var _root: Control
var _boss_name: Label
var _boss_hp: VitalityBar
var _boss_posture: PostureBar
var _marks: LivesMarks
var _player_hp: VitalityBar
var _player_posture: PostureBar
var _heal_label: Label
var _gourd: GourdMark
var _callout: Control
var _callout_text: Label
var _callout_rule: ColorRect
var _prompt: HBoxContainer
var _prompt_alpha := 0.0
var _reticle: Reticle
var _vignette: TextureRect
var _debug: Label
var _debug_panel: PanelContainer
var _namecard: Control
var _namecard_name: Label
var _namecard_rule: ColorRect
var _backdrop: ColorRect
var _overlay: Control
var _overlay_kanji: TextureRect
var _overlay_title: Label
var _overlay_hints: UiTheme.HintBar
var _execution: Control
var _execution_kanji: TextureRect
var _panel: Control
var _help_visible := false
var _last_timing := "—"
var _tex: Dictionary = {}


func _ready() -> void:
	layer = 10
	process_mode = Node.PROCESS_MODE_ALWAYS
	Game.hud = self
	for k in ["kanji_death", "kanji_execution"]:
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
	_build_debug()
	_build_namecard()
	_build_execution()
	_backdrop = UiTheme.backdrop(2.2, 0.5)
	_backdrop.visible = false
	_root.add_child(_backdrop)
	_build_overlay()
	_build_panel()
	Game.debug_toggled.connect(func(_on: bool): _debug_panel.visible = Game.debug)
	GameInput.device_changed.connect(func(_pad: bool): _build_prompt())


func bind(p: Player, b: Boss) -> void:
	player = p
	boss = b
	_boss_name.text = b.display_name
	_namecard_name.text = b.display_name
	p.heal_charges_changed.connect(_show_gourd)
	_show_gourd(p.heal_charges)
	p.deflect_timed.connect(_on_deflect_timed)
	b.posture_broken.connect(func(): _boss_posture.flash())


# ------------------------------------------------------------------------------ building
func _build_vignette() -> void:
	var g := Gradient.new()
	g.set_color(0, Color(0.42, 0.02, 0.02, 0.0))
	g.set_color(1, Color(0.36, 0.01, 0.01, 0.8))
	g.add_point(0.6, Color(0.42, 0.02, 0.02, 0.0))
	var t := GradientTexture2D.new()
	t.gradient = g
	t.fill = GradientTexture2D.FILL_RADIAL
	t.fill_from = Vector2(0.5, 0.5)
	t.fill_to = Vector2(1.08, 0.5)
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
	var m := UiTheme.MARGIN
	_marks = LivesMarks.new()
	UiTheme.place(_marks, Vector2(0, 0), Vector2(m, 60), Vector2(18 * Combat.BOSS_LIVES, 12))
	_root.add_child(_marks)
	_boss_name = UiTheme.label("", UiTheme.serif(600, 1), 30)
	UiTheme.place(_boss_name, Vector2(0, 0), Vector2(m + 18 * Combat.BOSS_LIVES + 8, 44), Vector2(700, 44))
	_root.add_child(_boss_name)
	_boss_hp = VitalityBar.new()
	UiTheme.place(_boss_hp, Vector2(0, 0), Vector2(m, 94), Vector2(600, 8))
	_root.add_child(_boss_hp)
	_boss_posture = PostureBar.new()
	UiTheme.place(_boss_posture, Vector2(0.5, 0), Vector2(-280, 138), Vector2(560, 7))
	_root.add_child(_boss_posture)


func _build_player_ui() -> void:
	var m := UiTheme.MARGIN
	_player_hp = VitalityBar.new()
	_player_hp.warn_below = 0.25
	UiTheme.place(_player_hp, Vector2(0, 1), Vector2(m, -m - 8), Vector2(480, 8))
	_root.add_child(_player_hp)
	_gourd = GourdMark.new()
	UiTheme.place(_gourd, Vector2(0, 1), Vector2(m, -m - 66), Vector2(26, 40))
	_root.add_child(_gourd)
	_heal_label = UiTheme.label("3", UiTheme.sans(500), 30)
	UiTheme.place(_heal_label, Vector2(0, 1), Vector2(m + 38, -m - 68), Vector2(80, 44))
	_root.add_child(_heal_label)
	_player_posture = PostureBar.new()
	UiTheme.place(_player_posture, Vector2(0.5, 1), Vector2(-240, -m - 62), Vector2(480, 7))
	_root.add_child(_player_posture)


func _build_center() -> void:
	_callout = Control.new()
	_callout.mouse_filter = Control.MOUSE_FILTER_IGNORE
	UiTheme.place(_callout, Vector2(0.5, 0.5), Vector2(-500, -290), Vector2(1000, 70))
	_callout.modulate.a = 0.0
	_root.add_child(_callout)
	var spot := UiTheme.shade_spot(0.4)
	UiTheme.place(spot, Vector2(0, 0), Vector2(250, -40), Vector2(500, 150))
	_callout.add_child(spot)
	_callout_text = UiTheme.label("", UiTheme.sans(500, 9), 30, UiTheme.TEXT, HORIZONTAL_ALIGNMENT_CENTER)
	UiTheme.place(_callout_text, Vector2(0, 0), Vector2(0, 0), Vector2(1000, 48))
	_callout.add_child(_callout_text)
	_callout_rule = ColorRect.new()
	_callout_rule.color = UiTheme.ACCENT
	_callout_rule.mouse_filter = Control.MOUSE_FILTER_IGNORE
	UiTheme.place(_callout_rule, Vector2(0, 0), Vector2(500, 58), Vector2(0, 2))
	_callout.add_child(_callout_rule)
	_prompt = HBoxContainer.new()
	_prompt.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_prompt.alignment = BoxContainer.ALIGNMENT_CENTER
	_prompt.add_theme_constant_override("separation", 14)
	UiTheme.place(_prompt, Vector2(0.5, 1), Vector2(-300, -UiTheme.MARGIN - 128), Vector2(600, 40))
	_prompt.modulate.a = 0.0
	_root.add_child(_prompt)
	_build_prompt()
	_reticle = Reticle.new()
	_reticle.size = Vector2(48, 48)
	_root.add_child(_reticle)


## "Deathblow" with the attack button for the device in use.
func _build_prompt() -> void:
	for c in _prompt.get_children():
		_prompt.remove_child(c)
		c.queue_free()
	var pad: bool = GameInput.gamepad
	_prompt.add_child(UiTheme.chip("RB" if pad else "Left mouse", pad, 34.0))
	var words := UiTheme.label("DEATHBLOW", UiTheme.sans(500, 7), 22, UiTheme.TEXT)
	_prompt.add_child(words)


func _build_debug() -> void:
	_debug_panel = PanelContainer.new()
	_debug_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var dsb := StyleBoxFlat.new()
	dsb.bg_color = Color(UiTheme.INK, 0.72)
	dsb.set_content_margin_all(14)
	dsb.set_corner_radius_all(4)
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
	_debug.add_theme_color_override("font_color", Color(0.8, 0.95, 0.82))
	_debug_panel.add_child(_debug)
	_debug_panel.visible = Game.debug
	_root.add_child(_debug_panel)


## His name as the fight begins, like a film's title: the name, and a line drawn out under it.
func _build_namecard() -> void:
	_namecard = Control.new()
	_namecard.mouse_filter = Control.MOUSE_FILTER_IGNORE
	UiTheme.place(_namecard, Vector2(0.5, 1), Vector2(-700, -330), Vector2(1400, 170))
	_namecard.modulate.a = 0.0
	_root.add_child(_namecard)
	var spot := UiTheme.shade_spot(0.55)
	UiTheme.place(spot, Vector2(0, 0), Vector2(200, -60), Vector2(1000, 290))
	_namecard.add_child(spot)
	_namecard_name = UiTheme.label("", UiTheme.serif(500, 2), 68, UiTheme.TEXT, HORIZONTAL_ALIGNMENT_CENTER)
	UiTheme.place(_namecard_name, Vector2(0, 0), Vector2(0, 0), Vector2(1400, 90))
	_namecard.add_child(_namecard_name)
	_namecard_rule = ColorRect.new()
	_namecard_rule.color = Color(UiTheme.TEXT, 0.45)
	_namecard_rule.mouse_filter = Control.MOUSE_FILTER_IGNORE
	UiTheme.place(_namecard_rule, Vector2(0, 0), Vector2(700, 104), Vector2(0, 1))
	_namecard.add_child(_namecard_rule)


## The 忍殺 (shinobi execution) splash for a deathblow: the brush kanji over a darkened screen.
func _build_execution() -> void:
	_execution = Control.new()
	_execution.set_anchors_preset(Control.PRESET_FULL_RECT)
	_execution.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_execution.visible = false
	_root.add_child(_execution)
	var shade := ColorRect.new()
	shade.color = Color(0, 0, 0, 0.28)
	shade.set_anchors_preset(Control.PRESET_FULL_RECT)
	shade.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_execution.add_child(shade)
	_execution_kanji = TextureRect.new()
	_execution_kanji.texture = _tex.get("kanji_execution")
	_execution_kanji.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_execution_kanji.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_execution_kanji.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_execution_kanji.modulate = UiTheme.ACCENT
	# Above the two of you (the deathblow shot frames you in the middle), not over the kill.
	UiTheme.place(_execution_kanji, Vector2(0.5, 0.5), Vector2(-270, -450), Vector2(540, 300))
	_execution_kanji.pivot_offset = Vector2(270, 150)
	_execution.add_child(_execution_kanji)
	var words := UiTheme.label("SHINOBI EXECUTION", UiTheme.sans(400, 12), 20, UiTheme.TEXT, HORIZONTAL_ALIGNMENT_CENTER)
	UiTheme.place(words, Vector2(0.5, 0.5), Vector2(-600, -150), Vector2(1200, 40))
	_execution.add_child(words)


## Death and victory: the kanji over the blurred, drained scene, then what you can do next.
func _build_overlay() -> void:
	_overlay = Control.new()
	_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_overlay.visible = false
	_root.add_child(_overlay)
	_overlay_kanji = TextureRect.new()
	_overlay_kanji.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_overlay_kanji.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_overlay_kanji.mouse_filter = Control.MOUSE_FILTER_IGNORE
	UiTheme.place(_overlay_kanji, Vector2(0.5, 0.5), Vector2(-330, -400), Vector2(660, 520))
	_overlay_kanji.pivot_offset = Vector2(330, 260)
	_overlay.add_child(_overlay_kanji)
	_overlay_title = UiTheme.label("", UiTheme.sans(400, 12), 22, UiTheme.TEXT, HORIZONTAL_ALIGNMENT_CENTER)
	UiTheme.place(_overlay_title, Vector2(0.5, 0.5), Vector2(-700, 150), Vector2(1400, 40))
	_overlay.add_child(_overlay_title)
	_overlay_hints = UiTheme.HintBar.new([], 30.0, 18)
	_overlay_hints.alignment = BoxContainer.ALIGNMENT_CENTER
	UiTheme.place(_overlay_hints, Vector2(0.5, 1), Vector2(-500, -UiTheme.MARGIN - 40), Vector2(1000, 40))
	_overlay.add_child(_overlay_hints)


func _build_panel() -> void:
	_panel = ControlsSheet.new()
	UiTheme.place(_panel, Vector2(0.5, 0.5), Vector2(-642, -370), Vector2(1284, 740))
	_panel.visible = false
	_root.add_child(_panel)


func _show_gourd(n: int) -> void:
	_heal_label.text = str(n)
	_heal_label.modulate.a = 1.0 if n > 0 else 0.4
	_gourd.full = n > 0
	_gourd.queue_redraw()


# ------------------------------------------------------------------------------ runtime
func _process(delta: float) -> void:
	var real_dt := minf(Game.unscaled(delta), 0.1)
	var db_ready := false
	if player != null:
		_player_hp.set_ratio(player.hp / player.max_hp)
		_player_posture.set_ratio(player.posture / player.max_posture)
	if boss != null:
		_boss_hp.set_ratio(boss.hp / boss.max_hp)
		_boss_posture.set_ratio(boss.posture / boss.max_posture)
		_marks.total = Combat.BOSS_LIVES
		_marks.left = boss.lives_left
		_update_reticle()
		db_ready = player != null and player.can_deathblow()   # (the attack's own check: no false offers)
	_prompt_alpha = move_toward(_prompt_alpha, 1.0 if db_ready else 0.0, real_dt * 8.0)
	_prompt.modulate.a = _prompt_alpha
	if _vignette.modulate.a > 0.0:
		_vignette.modulate.a = maxf(0.0, _vignette.modulate.a - real_dt * 1.8)
	if player != null and player.hp / player.max_hp < 0.25 and player.hp > 0.0:
		_vignette.modulate.a = maxf(_vignette.modulate.a, 0.3 + 0.1 * sin(Time.get_ticks_msec() / 260.0))
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
	_reticle.deathblow = boss.is_deathblow_ready()
	# unproject_position returns coordinates in the (stretched) canvas space the HUD uses.
	var sp := cam.unproject_position(p)
	_reticle.position = sp - _reticle.size * 0.5


func flash_damage() -> void:
	_vignette.modulate.a = 0.8


## A word in the middle of the screen (MIKIRI COUNTER), a vermilion line drawn out under it.
func show_callout(text: String) -> void:
	_callout_text.text = text.to_upper()
	var tw := _callout.create_tween()
	_callout.modulate.a = 0.0
	_callout_rule.offset_left = 500
	_callout_rule.offset_right = 500
	tw.set_parallel(true)
	tw.tween_property(_callout, "modulate:a", 1.0, 0.08)
	tw.tween_property(_callout_rule, "offset_left", 400.0, 0.3).set_trans(Tween.TRANS_EXPO).set_ease(Tween.EASE_OUT)
	tw.tween_property(_callout_rule, "offset_right", 600.0, 0.3).set_trans(Tween.TRANS_EXPO).set_ease(Tween.EASE_OUT)
	tw.chain().tween_interval(0.9)
	tw.chain().tween_property(_callout, "modulate:a", 0.0, 0.4)


## A deathblow lands: 忍殺 stamps onto the screen and fades (in real time, through the hit-stop).
func show_execution() -> void:
	_execution.visible = true
	_execution.modulate.a = 0.0
	_execution_kanji.scale = Vector2.ONE * 1.2
	var tw := _execution.create_tween()
	Fx._real_time(tw)
	tw.set_parallel(true)
	tw.tween_property(_execution, "modulate:a", 1.0, 0.1)
	tw.tween_property(_execution_kanji, "scale", Vector2.ONE, 0.4).set_trans(Tween.TRANS_EXPO).set_ease(Tween.EASE_OUT)
	tw.chain().tween_interval(1.1)
	tw.chain().tween_property(_execution, "modulate:a", 0.0, 0.6)
	tw.chain().tween_callback(func(): _execution.visible = false)


func show_namecard() -> void:
	_namecard_rule.offset_left = 700
	_namecard_rule.offset_right = 700
	var tw := _namecard.create_tween()
	tw.set_parallel(true)
	tw.tween_property(_namecard, "modulate:a", 1.0, 0.8)
	tw.tween_property(_namecard_rule, "offset_left", 480.0, 1.2).set_trans(Tween.TRANS_EXPO).set_ease(Tween.EASE_OUT)
	tw.tween_property(_namecard_rule, "offset_right", 920.0, 1.2).set_trans(Tween.TRANS_EXPO).set_ease(Tween.EASE_OUT)
	tw.chain().tween_interval(1.6)
	tw.chain().tween_property(_namecard, "modulate:a", 0.0, 1.0)


func show_death() -> void:
	_show_overlay("kanji_death", "", [[["Enter"], ["A"], "Try again"], [["Esc"], ["Start"], "Title menu"]], 0.8)


func show_victory() -> void:
	_show_overlay("kanji_execution", "SHINOBI EXECUTION",
		[[["Enter"], ["A"], "Fight again"], [["Esc"], ["Start"], "Title menu"]], 0.35)


func hide_overlay() -> void:
	_overlay.visible = false
	_backdrop.visible = _help_visible


func _show_overlay(tex_key: String, title: String, hints: Array, drain: float) -> void:
	_overlay.visible = true
	_overlay_kanji.texture = _tex.get(tex_key)
	_overlay_kanji.modulate = UiTheme.ACCENT
	_overlay_title.text = title
	_overlay_hints.set_items(hints)
	var mat := _backdrop.material as ShaderMaterial
	mat.set_shader_parameter("blur", 1.2)
	mat.set_shader_parameter("darken", 0.45)
	mat.set_shader_parameter("desaturate", drain)
	_backdrop.visible = true
	for c: CanvasItem in [_overlay, _backdrop]:
		c.modulate.a = 0.0
		c.create_tween().tween_property(c, "modulate:a", 1.0, 1.2)
	_overlay_kanji.scale = Vector2.ONE * 1.08
	_overlay_kanji.create_tween().tween_property(_overlay_kanji, "scale", Vector2.ONE, 2.4) \
		.set_trans(Tween.TRANS_EXPO).set_ease(Tween.EASE_OUT)


func set_panel_visible(v: bool) -> void:
	_help_visible = v
	_panel.visible = v
	if not _overlay.visible:
		var mat := _backdrop.material as ShaderMaterial
		mat.set_shader_parameter("blur", 2.2)
		mat.set_shader_parameter("darken", 0.55)
		mat.set_shader_parameter("desaturate", 0.3)
		_backdrop.modulate.a = 1.0
		_backdrop.visible = v


func toggle_help() -> void:
	set_panel_visible(not _help_visible)


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
		lines.append("TWIN FANG  phase %d   lives %d/%d   %s %s   seq %s" % [boss.phase, boss.lives_left, Combat.BOSS_LIVES,
			Boss.S.keys()[boss.state], boss._mode, boss._seq_name if boss._seq_name != "" else "-"])
		lines.append("       hp %.0f/%.0f   posture %.0f/%.0f (-%.1f/s after %.1f s)" % [boss.hp, boss.max_hp,
			boss.posture, boss.max_posture, b_regen, boss.posture_delay])
		lines.append("       cooldown %.2f   reeling %d/%d   guard %d/%d" % [maxf(0.0, boss.cooldown),
			boss._pummel, boss._endure, boss._guard_count, boss._parry_threshold])
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
	if inf.waves_on:
		s += "   waves %d/%d" % [inf.waves_passed, Inferno.WAVE_BEATS.size()]
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
## His lives (deathblow marks): a vermilion dot for each left, a faint ring for each taken.
class LivesMarks extends Control:
	var total := Combat.BOSS_LIVES
	var left := Combat.BOSS_LIVES

	func _ready() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func _process(_d: float) -> void:
		queue_redraw()

	func _draw() -> void:
		var r := size.y * 0.5 - 0.5
		for i in total:
			var c := Vector2(r + 0.5 + i * 18.0, size.y * 0.5)
			if i < left:
				draw_circle(c, r + 1.5, Color(0, 0, 0, 0.35), true, -1.0, true)
				draw_circle(c, r, UiTheme.ACCENT, true, -1.0, true)
			else:
				draw_circle(c, r - 0.6, UiTheme.FAINT, false, 1.2, true)


## The healing gourd as a flat silhouette with a vermilion cord at its waist; an outline when
## it's empty.
class GourdMark extends Control:
	var full := true

	func _ready() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func _draw() -> void:
		var w := size.x
		var h := size.y
		var cx := w * 0.5
		var low := Vector2(cx, h * 0.69)
		var r_low := w * 0.48
		var high := Vector2(cx, h * 0.33)
		var r_high := w * 0.3
		var neck_top := h * 0.1
		# half the width at each height: the two bulbs, the neck above them
		var right := PackedVector2Array()
		var n := 28
		for i in n + 1:
			var y := lerpf(neck_top, low.y + r_low, float(i) / n)
			var hw := 0.0
			if absf(y - low.y) < r_low:
				hw = maxf(hw, sqrt(r_low * r_low - (y - low.y) ** 2))
			if absf(y - high.y) < r_high:
				hw = maxf(hw, sqrt(r_high * r_high - (y - high.y) ** 2))
			if y < high.y:
				hw = maxf(hw, w * 0.11)
			right.append(Vector2(cx + hw, y))
		var pts := PackedVector2Array()
		pts.append_array(right)
		for i in range(right.size() - 1, -1, -1):
			if right[i].x - cx > 0.01:          # the tip at the bottom is already there
				pts.append(Vector2(cx * 2.0 - right[i].x, right[i].y))
		var stopper := Rect2(Vector2(cx - w * 0.13, 0.0), Vector2(w * 0.26, neck_top + 1.0))
		var waist := lerpf(high.y, low.y, 0.5) - 1.0
		if full:
			draw_colored_polygon(pts, UiTheme.TEXT)
			draw_rect(stopper, Color(UiTheme.TEXT, 0.75))
			draw_line(Vector2(cx - w * 0.24, waist), Vector2(cx + w * 0.24, waist), UiTheme.ACCENT, 2.0)
		else:
			pts.append(pts[0])
			draw_polyline(pts, UiTheme.FAINT, 1.2, true)
			draw_rect(stopper, UiTheme.FAINT, false, 1.0)


## Where he is while you're locked on: a small ivory dot; vermilion with a ring pulsing out
## of it when his posture is broken and a deathblow is there for the taking.
class Reticle extends Control:
	var deathblow := false
	var _t := 0.0

	func _ready() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func _process(delta: float) -> void:
		_t += minf(Game.unscaled(delta), 0.1)
		queue_redraw()

	func _draw() -> void:
		var c := size * 0.5
		if deathblow:
			var p := fmod(_t * 1.2, 1.0)
			draw_circle(c, 8.0 + 12.0 * p, Color(UiTheme.ACCENT, 0.7 * (1.0 - p)), false, 1.5, true)
			draw_circle(c, 7.0, Color(0, 0, 0, 0.45), true, -1.0, true)
			draw_circle(c, 5.5, UiTheme.ACCENT, true, -1.0, true)
		else:
			draw_circle(c, 4.5, Color(0, 0, 0, 0.4), true, -1.0, true)
			draw_circle(c, 3.0, UiTheme.TEXT, true, -1.0, true)
