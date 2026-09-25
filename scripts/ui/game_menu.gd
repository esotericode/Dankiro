class_name GameMenu
extends CanvasLayer
## Title menu (on boot) and pause menu, with Options and Controls pages. Built in code like the
## HUD, for the same 1920x1080 canvas. Mouse, keyboard (arrows + Enter, Esc to go back) and
## gamepad (D-pad / stick + A, B to go back) all work: the buttons use Godot's focus navigation.
## Options are saved by `Game` (user://settings.cfg).

signal start_pressed
signal resume_pressed
signal restart_pressed
signal title_pressed
signal quit_pressed

const C_TEXT := Color(0.88, 0.84, 0.76)
const C_FOCUS := Color(1.0, 0.8, 0.42)
const C_DIM := Color(0.62, 0.58, 0.52)

var _font: Font
var _root: Control
var _title_shade: TextureRect
var _pause_shade: ColorRect
var _column: VBoxContainer
var _heading: Label
var _subheading: Label
var _buttons: VBoxContainer
var _note: Label
var _hint: Label
var _controls: PanelContainer
var _page := ""
var _root_page := "title"           ## where Back leads from Options / Controls
var _quiet := false                 ## no focus sound while a page is being built


func _ready() -> void:
	layer = 20
	process_mode = Node.PROCESS_MODE_ALWAYS
	if ResourceLoader.exists("res://fonts/ui_serif.ttf"):
		_font = load("res://fonts/ui_serif.ttf")
	_root = Control.new()
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(_root)
	_build()
	visible = false


# ------------------------------------------------------------------------------ building
func _build() -> void:
	# Title: dark to the left, where the menu sits, clear on the right where he stands.
	var g := Gradient.new()
	g.set_color(0, Color(0.01, 0.01, 0.02, 0.92))
	g.set_color(1, Color(0.01, 0.01, 0.02, 0.0))
	g.add_point(0.42, Color(0.01, 0.01, 0.02, 0.7))
	var gt := GradientTexture2D.new()
	gt.gradient = g
	gt.fill_from = Vector2(0, 0.5)
	gt.fill_to = Vector2(0.75, 0.5)
	gt.width = 256
	gt.height = 8
	_title_shade = TextureRect.new()
	_title_shade.texture = gt
	_title_shade.stretch_mode = TextureRect.STRETCH_SCALE
	_title_shade.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_title_shade.set_anchors_preset(Control.PRESET_FULL_RECT)
	_title_shade.mouse_filter = Control.MOUSE_FILTER_STOP     # clicks on the menu stay in the menu
	_root.add_child(_title_shade)
	_pause_shade = ColorRect.new()
	_pause_shade.color = Color(0.0, 0.0, 0.01, 0.62)
	_pause_shade.set_anchors_preset(Control.PRESET_FULL_RECT)
	_pause_shade.mouse_filter = Control.MOUSE_FILTER_STOP
	_root.add_child(_pause_shade)

	_column = VBoxContainer.new()
	_column.anchor_left = 0.0
	_column.anchor_right = 0.0
	_column.anchor_top = 0.0
	_column.anchor_bottom = 1.0
	_column.offset_left = 150
	_column.offset_right = 150 + 860
	_column.offset_top = 170
	_column.offset_bottom = -90
	_column.add_theme_constant_override("separation", 6)
	_root.add_child(_column)
	_heading = _label("", 96, Color(0.95, 0.9, 0.82))
	_column.add_child(_heading)
	_subheading = _label("", 30, Color(0.82, 0.62, 0.4))
	_column.add_child(_subheading)
	var gap := Control.new()
	gap.custom_minimum_size = Vector2(0, 56)
	_column.add_child(gap)
	_buttons = VBoxContainer.new()
	_buttons.add_theme_constant_override("separation", 4)
	_column.add_child(_buttons)
	var gap2 := Control.new()
	gap2.custom_minimum_size = Vector2(0, 26)
	_column.add_child(gap2)
	_note = _label("", 24, C_DIM)
	_note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_note.custom_minimum_size = Vector2(760, 0)
	_column.add_child(_note)

	_hint = _label("Mouse, arrow keys or D-pad    Enter / (A) select    Esc / (B) back", 20, C_DIM)
	_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_hint.anchor_left = 1.0
	_hint.anchor_right = 1.0
	_hint.anchor_top = 1.0
	_hint.anchor_bottom = 1.0
	_hint.offset_left = -1000
	_hint.offset_right = -48
	_hint.offset_top = -64
	_hint.offset_bottom = -30
	_root.add_child(_hint)

	_controls = PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.03, 0.03, 0.04, 0.9)
	sb.border_color = Color(0.7, 0.58, 0.36, 0.8)
	sb.set_border_width_all(2)
	sb.set_content_margin_all(24)
	sb.set_corner_radius_all(4)
	_controls.add_theme_stylebox_override("panel", sb)
	_controls.anchor_left = 0.0
	_controls.anchor_right = 0.0
	_controls.anchor_top = 0.0
	_controls.anchor_bottom = 0.0
	_controls.offset_left = 800
	_controls.offset_right = 1860
	_controls.offset_top = 150
	_controls.offset_bottom = 930
	var rt := RichTextLabel.new()
	rt.bbcode_enabled = true
	rt.fit_content = true
	rt.scroll_active = false
	rt.mouse_filter = Control.MOUSE_FILTER_IGNORE
	rt.add_theme_font_size_override("normal_font_size", 20)
	rt.add_theme_font_size_override("bold_font_size", 21)
	rt.add_theme_color_override("default_color", Color(0.9, 0.87, 0.8))
	var mono := SystemFont.new()
	mono.font_names = PackedStringArray(["DejaVu Sans Mono", "Consolas", "Menlo", "Courier New", "monospace"])
	rt.add_theme_font_override("normal_font", mono)
	rt.text = Hud.CONTROLS_TEXT
	_controls.add_child(rt)
	_root.add_child(_controls)


func _label(text: String, font_size: int, color: Color) -> Label:
	var l := Label.new()
	l.text = text
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if _font:
		l.add_theme_font_override("font", _font)
	l.add_theme_font_size_override("font_size", font_size)
	l.add_theme_color_override("font_color", color)
	l.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.8))
	l.add_theme_constant_override("outline_size", maxi(4, font_size / 8))
	return l


func _button(text: String, on_press: Callable, font_size := 38) -> Button:
	var b := Button.new()
	b.text = text
	b.alignment = HORIZONTAL_ALIGNMENT_LEFT
	b.focus_mode = Control.FOCUS_ALL
	b.custom_minimum_size = Vector2(620, 0)
	b.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	if _font:
		b.add_theme_font_override("font", _font)
	b.add_theme_font_size_override("font_size", font_size)
	b.add_theme_color_override("font_color", C_TEXT)
	for st in ["font_hover_color", "font_focus_color", "font_pressed_color", "font_hover_pressed_color"]:
		b.add_theme_color_override(st, C_FOCUS)
	b.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.8))
	b.add_theme_constant_override("outline_size", 5)
	var normal := StyleBoxEmpty.new()
	normal.content_margin_left = 22
	normal.content_margin_right = 22
	normal.content_margin_top = 6
	normal.content_margin_bottom = 6
	var lit := StyleBoxFlat.new()
	lit.bg_color = Color(0.9, 0.66, 0.3, 0.1)
	lit.border_color = C_FOCUS
	lit.border_width_left = 4
	lit.content_margin_left = 22
	lit.content_margin_right = 22
	lit.content_margin_top = 6
	lit.content_margin_bottom = 6
	b.add_theme_stylebox_override("normal", normal)
	b.add_theme_stylebox_override("hover", lit)
	b.add_theme_stylebox_override("focus", lit)
	b.add_theme_stylebox_override("pressed", lit)
	b.pressed.connect(func():
		Sfx.play_ui("lockon", -6.0)
		on_press.call_deferred())   # deferred: a page switch frees this very button
	b.focus_entered.connect(func():
		if not _quiet:
			Sfx.play_ui("lockon", -14.0))
	b.mouse_entered.connect(func(): b.grab_focus())
	_buttons.add_child(b)
	return b


## An option row: shows "name   < value >"; Enter / click steps forward, left / right step
## either way. `values` are the choices' labels, `get_index` / `set_index` read and store it.
func _option(name: String, values: Array, get_index: Callable, set_index: Callable, note: String) -> Button:
	# Lambdas capture locals by value when they're made, so the button goes in a shared box.
	var box := {}
	var refresh := func():
		(box["b"] as Button).text = "%s     ‹  %s  ›" % [name, str(values[int(get_index.call())])]
	var step := func(dir: int):
		set_index.call(posmod(int(get_index.call()) + dir, values.size()))
		refresh.call()
	var b := _button("", func(): step.call(1), 34)
	box["b"] = b
	refresh.call()
	b.gui_input.connect(func(ev: InputEvent):
		if ev.is_action_pressed("ui_left"):
			step.call(-1)
			Sfx.play_ui("lockon", -8.0)
			b.accept_event()
		elif ev.is_action_pressed("ui_right"):
			step.call(1)
			Sfx.play_ui("lockon", -8.0)
			b.accept_event())
	b.focus_entered.connect(func(): _note.text = note)
	return b


# ------------------------------------------------------------------------------ pages
func open_title() -> void:
	_root_page = "title"
	_show("title")


func open_pause() -> void:
	_root_page = "pause"
	_show("pause")


func close() -> void:
	visible = false
	_page = ""


func is_open() -> bool:
	return visible


## Esc / (B): from Options or Controls back to the menu they came from. Returns false on a
## root page (the caller decides what that means: resume, or nothing on the title).
func back() -> bool:
	if _page == "options" or _page == "controls":
		_show(_root_page)
		return true
	return false


func _show(page: String) -> void:
	_page = page
	visible = true
	_quiet = true
	for c in _buttons.get_children():
		_buttons.remove_child(c)
		c.queue_free()
	_note.text = ""
	_controls.visible = page == "controls"
	_title_shade.visible = _root_page == "title"
	_pause_shade.visible = _root_page == "pause"
	_heading.add_theme_font_size_override("font_size", 96 if page == "title" else 64)
	var first: Button
	match page:
		"title":
			_heading.text = "DANKIRO"
			_subheading.text = "Sojin, the Twin Fang  ·  Warden of the Moon Gate"
			first = _button("Start fight", func(): start_pressed.emit())
			_button("Options", func(): _show("options"))
			_button("Controls", func(): _show("controls"))
			_button("Quit", func(): quit_pressed.emit())
			if Game.start_phase > 1:
				_note.text = "The fight starts in phase %d (Options)." % Game.start_phase
		"pause":
			_heading.text = "Paused"
			_subheading.text = ""
			first = _button("Resume", func(): resume_pressed.emit())
			_button("Restart fight", func(): restart_pressed.emit())
			_button("Options", func(): _show("options"))
			_button("Controls", func(): _show("controls"))
			_button("Quit to title", func(): title_pressed.emit())
		"options":
			_heading.text = "Options"
			_subheading.text = ""
			var later := "" if _root_page == "title" else " Takes effect when you restart the fight."
			first = _option("Starting phase", ["1", "2", "3"],
				func(): return Game.start_phase - 1,
				func(i: int): Game.set_start_phase(i + 1),
				"The phase the fight starts in, for testing: the earlier lives count as taken. " +
				"Phase 3 is the same as phase 2 for now." + later)
			_option("Diagnostics", ["Off", "On"],
				func(): return 1 if Game.debug else 0,
				func(i: int): Game.set_diagnostics(i == 1),
				"Shows hitboxes (hurtboxes, weapons lit while a hit window is open), your guard " +
				"and deflect window, where each blow landed, and a live readout of both fighters. " +
				"F3 toggles it during a fight.")
			_button("Back", func(): back())
		"controls":
			_heading.text = "Controls"
			_subheading.text = ""
			first = _button("Back", func(): back())
	_column.offset_top = 170 if page == "title" else 150
	first.grab_focus()
	_quiet = false
