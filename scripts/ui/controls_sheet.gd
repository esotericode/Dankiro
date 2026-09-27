class_name ControlsSheet
extends HBoxContainer
## The controls and a short guide to the fight: the bindings as a table of key and button glyphs
## (keyboard and mouse, gamepad) beside how to fight. Shown by F1 in the fight and on the menus'
## Controls page; it has no box of its own, whoever shows it puts a blurred backdrop behind it.

## [action, keyboard and mouse, gamepad]
const BINDINGS := [
	["Move", ["W", "A", "S", "D"], ["L stick"]],
	["Camera", ["Mouse"], ["R stick"]],
	["Attack", ["Left mouse", "J"], ["RB"]],
	["Guard / deflect", ["Right mouse", "K"], ["LB"]],
	["Dodge (hold to run)", ["Shift"], ["B"]],
	["Jump", ["Space"], ["A"]],
	["Lock on", ["Middle mouse", "Q"], ["R3"]],
	["Heal (gourd)", ["R"], ["X"]],
	["Pause", ["Esc"], ["Start"]],
	["Controls", ["F1"], ["Back"]],
	["Diagnostics", ["F3"], []],
	["Fullscreen", ["F11"], []],
]

const GUIDE := """[b]Deflect[/b]   Tap guard just before a blade lands, a 0.2 s window. Pressing again within half a second of letting go shrinks it; a clean deflect restores it. Holding guard only blocks.

[b]Commit[/b]   Your slashes commit: guard cuts in only at the very start of a swing, or after it.

[b]Deathblow[/b]   Fill his posture with deflects, then press Attack on the [color=#e8563f]red mark[/color].

[img=20x20]res://textures/kanji_danger_icon.png[/img]  [b]Perilous thrust[/b]   He draws the staff back and holds it. Dodge with no direction as he releases, for a mikiri counter; during the pull-back is too early. Deflecting works; blocking or backing off fails.

[img=20x20]res://textures/kanji_danger_icon.png[/img]  [b]Perilous sweep[/b]   Low and long, and you can't back out of it. Jump, then jump again to kick him.

[img=20x20]res://textures/kanji_danger_icon.png[/img]  [b]Staff snare · phase 3[/b]   He holds the staff across his chest, then hooks at shoulder height. Step sideways as he releases; guard and deflect won't stop it.

[b]Shuriken[/b]   He leaps back and throws three fast and one late, or five fast. Deflect each one.

His posture recovers when you back off, and faster while his vitality is high."""

const COL_ACTION := 230.0
const COL_KEYS := 262.0
const ROW_H := 43.0


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_theme_constant_override("separation", 76)
	add_child(_bindings_column())
	add_child(_guide_column())


func _bindings_column() -> Control:
	var col := VBoxContainer.new()
	col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_theme_constant_override("separation", 0)
	col.add_child(_heading("Bindings"))
	var head := _row()
	head.add_child(_cell(Control.new(), COL_ACTION))
	head.add_child(_cell(UiTheme.label("KEYBOARD & MOUSE", UiTheme.sans(500, 3), 14, UiTheme.FAINT), COL_KEYS))
	head.add_child(UiTheme.label("GAMEPAD", UiTheme.sans(500, 3), 14, UiTheme.FAINT))
	head.custom_minimum_size.y = 34
	col.add_child(head)
	for b in BINDINGS:
		col.add_child(_rule())
		var row := _row()
		row.add_child(_cell(UiTheme.label(str(b[0]), UiTheme.sans(400), 20, UiTheme.TEXT), COL_ACTION))
		row.add_child(_cell(_keys(b[1], false), COL_KEYS))
		row.add_child(_keys(b[2], true))
		col.add_child(row)
	col.add_child(_rule())
	return col


func _guide_column() -> Control:
	var col := VBoxContainer.new()
	col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_theme_constant_override("separation", 0)
	col.add_child(_heading("How to fight"))
	var spacer := Control.new()
	spacer.custom_minimum_size = Vector2(0, 10)
	col.add_child(spacer)
	var rt := RichTextLabel.new()
	rt.bbcode_enabled = true
	rt.fit_content = true
	rt.scroll_active = false
	rt.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	rt.custom_minimum_size = Vector2(560, 0)
	rt.mouse_filter = Control.MOUSE_FILTER_IGNORE
	rt.add_theme_color_override("default_color", Color(UiTheme.TEXT, 0.72))
	rt.add_theme_constant_override("line_separation", 5)
	rt.add_theme_font_override("normal_font", UiTheme.sans(400))
	rt.add_theme_font_override("bold_font", UiTheme.sans(600))
	rt.add_theme_font_size_override("normal_font_size", 19)
	rt.add_theme_font_size_override("bold_font_size", 19)
	rt.text = GUIDE.replace("[b]", "[color=#f2eee4][b]").replace("[/b]", "[/b][/color]")
	col.add_child(rt)
	return col


func _heading(text: String) -> Control:
	var l := UiTheme.label(text, UiTheme.serif(600), 36, UiTheme.TEXT)
	l.custom_minimum_size.y = 64
	l.vertical_alignment = VERTICAL_ALIGNMENT_TOP
	return l


func _row() -> HBoxContainer:
	var row := HBoxContainer.new()
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.custom_minimum_size.y = ROW_H
	row.add_theme_constant_override("separation", 0)
	return row


func _cell(c: Control, width: float) -> Control:
	c.custom_minimum_size.x = width
	return c


func _rule() -> ColorRect:
	var r := ColorRect.new()
	r.color = Color(UiTheme.TEXT, 0.09)
	r.custom_minimum_size = Vector2(0, 1)
	r.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return r


## The glyphs for `names` (a dash if there's no binding).
func _keys(names: Array, pad: bool) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if names.is_empty():
		row.add_child(UiTheme.label("—", UiTheme.sans(400), 18, UiTheme.FAINT))
		return row
	for n in names:
		row.add_child(UiTheme.chip(str(n), pad, 30.0))
	return row
