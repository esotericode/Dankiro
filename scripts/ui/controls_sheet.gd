class_name ControlsSheet
extends PanelContainer
## The controls and a short guide to the fight, set out for reading in the game's serif: the
## bindings as a table of keycaps (keyboard and mouse, gamepad) beside how to fight. Shown by F1
## in the fight and on the menus' Controls page.

const C_TEXT := Color(0.9, 0.86, 0.78)
const C_DIM := Color(0.74, 0.66, 0.52)
const C_HEAD := Color(0.86, 0.7, 0.44)
const FACE_BUTTONS := {"A": Color(0.5, 0.85, 0.42), "B": Color(0.95, 0.4, 0.34), "X": Color(0.45, 0.66, 1.0),
	"Y": Color(0.95, 0.8, 0.3)}

## [action, keyboard and mouse, gamepad]
const BINDINGS := [
	["Move", ["W", "A", "S", "D"], ["L stick"]],
	["Camera", ["Mouse"], ["R stick"]],
	["Attack", ["Left mouse", "J"], ["RB"]],
	["Guard / deflect", ["Right mouse", "K"], ["LB"]],
	["Dodge (hold to run)", ["Shift"], ["B"]],
	["Jump", ["Space"], ["A"]],
	["Lock on", ["Q", "Middle mouse"], ["R3"]],
	["Heal (gourd)", ["R"], ["X"]],
	["Pause", ["Esc"], ["Start"]],
	["Controls", ["F1"], ["Back"]],
	["Diagnostics", ["F3"], []],
	["Fullscreen", ["F11"], []],
]

const GUIDE := """[color=#e8dcc6]Tap guard just before a blade lands to [color=#ffd27a]deflect[/color] (a 0.2 s window). Pressing again within half a second of letting go shrinks the window; a clean deflect restores it. Holding guard only blocks.[/color]

Your slashes commit: guard can only cut in at the very start of a swing, or after it.

Fill his posture bar with deflects, then press Attack on the red mark: [color=#ff6a50]deathblow[/color].

[img=24x24]res://textures/kanji_danger_icon.png[/img] [color=#ffb0a0]Perilous thrust[/color]: he draws the staff back and holds it. Press Dodge with [i]no direction[/i] as he releases for a [color=#ffd27a]mikiri counter[/color]; during the pull-back is too early. Deflecting works; blocking or backing off fails.

[img=24x24]res://textures/kanji_danger_icon.png[/img] [color=#ffb0a0]Perilous sweep[/color]: low and long, and you can't back out of it. Jump, then jump again to kick him.

Shuriken: he leaps back and throws three fast and one late, or five fast. Deflect each one.

His posture recovers when you back off, and faster while his vitality is high."""

var _font: Font


func _init(font: Font) -> void:
	_font = font
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.025, 0.022, 0.03, 0.93)
	sb.border_color = Color(HudStyle.GILT, 0.75)
	sb.set_border_width_all(2)
	sb.set_corner_radius_all(6)
	sb.content_margin_left = 40
	sb.content_margin_right = 40
	sb.content_margin_top = 30
	sb.content_margin_bottom = 30
	sb.shadow_color = Color(0, 0, 0, 0.45)
	sb.shadow_size = 12
	add_theme_stylebox_override("panel", sb)
	var cols := HBoxContainer.new()
	cols.add_theme_constant_override("separation", 56)
	cols.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(cols)
	cols.add_child(_bindings_column())
	cols.add_child(_guide_column())


func _bindings_column() -> Control:
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 14)
	col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(_label("Controls", 34, C_HEAD))
	var grid := GridContainer.new()
	grid.columns = 3
	grid.add_theme_constant_override("h_separation", 22)
	grid.add_theme_constant_override("v_separation", 9)
	grid.mouse_filter = Control.MOUSE_FILTER_IGNORE
	grid.add_child(_label("", 18, C_DIM))
	grid.add_child(_label("Keyboard & mouse", 18, C_DIM))
	grid.add_child(_label("Gamepad", 18, C_DIM))
	for b in BINDINGS:
		var action := _label(str(b[0]), 22, C_TEXT)
		action.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		grid.add_child(action)
		grid.add_child(_keys(b[1]))
		grid.add_child(_keys(b[2]))
	col.add_child(grid)
	return col


func _guide_column() -> Control:
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 14)
	col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(_label("How to fight", 34, C_HEAD))
	var rt := RichTextLabel.new()
	rt.bbcode_enabled = true
	rt.fit_content = true
	rt.scroll_active = false
	rt.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	rt.custom_minimum_size = Vector2(540, 0)
	rt.mouse_filter = Control.MOUSE_FILTER_IGNORE
	rt.add_theme_color_override("default_color", Color(0.86, 0.82, 0.74))
	rt.add_theme_constant_override("line_separation", 2)
	if _font:
		rt.add_theme_font_override("normal_font", _font)
		var bold := FontVariation.new()
		bold.base_font = _font
		bold.variation_embolden = 0.6
		rt.add_theme_font_override("bold_font", bold)
		var italic := FontVariation.new()
		italic.base_font = _font
		italic.variation_transform = Transform2D(Vector2(1, 0), Vector2(0.22, 1), Vector2.ZERO)
		rt.add_theme_font_override("italics_font", italic)
	for k in ["normal_font_size", "bold_font_size", "italics_font_size"]:
		rt.add_theme_font_size_override(k, 22)
	rt.text = GUIDE
	col.add_child(rt)
	return col


## A row of keycaps (an em dash if there's no binding).
func _keys(names: Array) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if names.is_empty():
		row.add_child(_label("—", 20, C_DIM))
		return row
	for n in names:
		row.add_child(_keycap(str(n)))
	return row


func _keycap(text: String) -> Control:
	var cap := PanelContainer.new()
	cap.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.13, 0.115, 0.1, 0.96)
	sb.border_color = Color(HudStyle.GILT, 0.5)
	sb.set_border_width_all(1)
	sb.border_width_bottom = 3
	sb.set_corner_radius_all(5)
	sb.content_margin_left = 10
	sb.content_margin_right = 10
	sb.content_margin_top = 0
	sb.content_margin_bottom = 1
	cap.add_theme_stylebox_override("panel", sb)
	cap.add_child(_label(text, 19, FACE_BUTTONS.get(text, C_TEXT)))
	return cap


func _label(text: String, font_size: int, color: Color) -> Label:
	var l := Label.new()
	l.text = text
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	if _font:
		l.add_theme_font_override("font", _font)
	l.add_theme_font_size_override("font_size", font_size)
	l.add_theme_color_override("font_color", color)
	return l
