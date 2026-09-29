class_name GameMenu
extends CanvasLayer
## Title menu (on boot) and pause menu, with Options, Controls and Lore pages. Built in code like the
## HUD, for the same 1920x1080 canvas, in UiTheme's look: words on the left, no boxes, a
## vermilion line gliding to the highlighted one; the pause menu sits over the fight, blurred.
## Mouse, keyboard (arrows + Enter, Esc to go back) and gamepad (D-pad or left stick + A, B to
## go back) all work. Keyboard and gamepad navigation is handled here (not left to Godot's focus
## system) so a stick push moves exactly one row, left / right change an option, and A presses
## the highlighted item. Options live in `Game` (the music volume is saved to user://settings.cfg;
## the testing options start every session at their defaults).

signal start_pressed
signal resume_pressed
signal restart_pressed
signal title_pressed
signal quit_pressed

const COLUMN_X := 136.0
const ITEM_W := 560.0
const SUBTITLE := "The Twin Fang"

## The hint bar's items for each page: [keyboard keys, gamepad buttons, what they do].
const MOVE := [["Up", "Down"], ["D-pad"], "Move"]
const SELECT := [["Enter"], ["A"], "Select"]
const HINTS := {
	"title": [MOVE, SELECT],
	"pause": [MOVE, SELECT, [["Esc"], ["B"], "Resume"]],
	"options": [MOVE, [["Left", "Right"], ["D-pad"], "Change"], SELECT, [["Esc"], ["B"], "Back"]],
	"controls": [SELECT, [["Esc"], ["B"], "Back"]],
	"lore": [SELECT, [["Esc"], ["B"], "Back"]],
}

var _root: Control
var _title_shade: TextureRect
var _backdrop: ColorRect
var _column: VBoxContainer
var _heading: Label
var _subheading: Label
var _rule: ColorRect
var _buttons: VBoxContainer
var _note: Label
var _hints: UiTheme.HintBar
var _controls: ControlsSheet
var _lore: LoreSheet
var _marker: ColorRect
var _marker_y := -1.0
var _page := ""
var _root_page := "title"           ## where Back leads from Options / Controls / Lore
var _quiet := false                 ## no focus sound while a page is being built
var _stick := {JOY_AXIS_LEFT_X: 0, JOY_AXIS_LEFT_Y: 0}   ## left stick direction held past the threshold


func _ready() -> void:
	layer = 20
	process_mode = Node.PROCESS_MODE_ALWAYS
	_root = Control.new()
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(_root)
	_build()
	visible = false


# ------------------------------------------------------------------------------ building
func _build() -> void:
	# Title: ink to the left, where the menu sits, clear on the right where he stands.
	var g := Gradient.new()
	g.set_color(0, Color(UiTheme.INK, 0.9))
	g.set_color(1, Color(UiTheme.INK, 0.0))
	g.add_point(0.45, Color(UiTheme.INK, 0.62))
	var gt := GradientTexture2D.new()
	gt.gradient = g
	gt.fill_from = Vector2(0, 0.5)
	gt.fill_to = Vector2(0.72, 0.5)
	gt.width = 256
	gt.height = 8
	_title_shade = TextureRect.new()
	_title_shade.texture = gt
	_title_shade.stretch_mode = TextureRect.STRETCH_SCALE
	_title_shade.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_title_shade.set_anchors_preset(Control.PRESET_FULL_RECT)
	_title_shade.mouse_filter = Control.MOUSE_FILTER_STOP     # clicks on the menu stay in the menu
	_root.add_child(_title_shade)
	_backdrop = UiTheme.backdrop(2.4, 0.5, 0.25)
	_backdrop.mouse_filter = Control.MOUSE_FILTER_STOP
	_root.add_child(_backdrop)

	_column = VBoxContainer.new()
	_column.anchor_left = 0.0
	_column.anchor_right = 0.0
	_column.anchor_top = 0.0
	_column.anchor_bottom = 1.0
	_column.offset_left = COLUMN_X
	_column.offset_right = COLUMN_X + 760
	_column.offset_top = 170
	_column.offset_bottom = -90
	_column.add_theme_constant_override("separation", 0)
	_root.add_child(_column)
	_heading = UiTheme.label("", UiTheme.serif(500), 72)
	_column.add_child(_heading)
	_subheading = UiTheme.label("", UiTheme.sans(400, 6), 16, UiTheme.DIM)
	_column.add_child(_subheading)
	_column.add_child(_gap(30))
	_rule = ColorRect.new()
	_rule.color = UiTheme.ACCENT
	_rule.custom_minimum_size = Vector2(44, 2)
	_rule.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	_rule.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_column.add_child(_rule)
	_column.add_child(_gap(40))
	_buttons = VBoxContainer.new()
	_buttons.add_theme_constant_override("separation", 4)
	_column.add_child(_buttons)
	_column.add_child(_gap(30))
	_note = UiTheme.label("", UiTheme.sans(400), 19, UiTheme.DIM)
	_note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_note.vertical_alignment = VERTICAL_ALIGNMENT_TOP
	_note.custom_minimum_size = Vector2(ITEM_W, 0)
	_note.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	_column.add_child(_note)

	_marker = ColorRect.new()
	_marker.color = UiTheme.ACCENT
	_marker.size = Vector2(26, 2)
	_marker.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_marker.visible = false
	_root.add_child(_marker)

	_hints = UiTheme.HintBar.new([], 28.0, 17)
	_hints.alignment = BoxContainer.ALIGNMENT_END
	UiTheme.place(_hints, Vector2(1, 1), Vector2(-1400 - UiTheme.MARGIN, -UiTheme.MARGIN - 28), Vector2(1400, 28))
	_root.add_child(_hints)

	_controls = ControlsSheet.new()
	UiTheme.place(_controls, Vector2(0, 0), Vector2(566, 128), Vector2(1284, 760))
	_root.add_child(_controls)
	_lore = LoreSheet.new()
	UiTheme.place(_lore, Vector2(0, 0), Vector2(566, 176), Vector2(LoreSheet.WIDTH, 780))   # (level with the heading)
	_root.add_child(_lore)


func _gap(h: float) -> Control:
	var c := Control.new()
	c.custom_minimum_size = Vector2(0, h)
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return c


func _button(text: String, on_press: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.alignment = HORIZONTAL_ALIGNMENT_LEFT
	b.focus_mode = Control.FOCUS_ALL
	b.custom_minimum_size = Vector2(ITEM_W, 54)
	b.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	b.add_theme_font_override("font", UiTheme.sans(400, 2))
	b.add_theme_font_size_override("font_size", 30)
	b.add_theme_color_override("font_color", UiTheme.DIM)
	for st in ["font_hover_color", "font_focus_color", "font_pressed_color", "font_hover_pressed_color"]:
		b.add_theme_color_override(st, UiTheme.TEXT)
	UiTheme.soft_shadow(b, 30)
	# One box for every state, so the text keeps its place; it slides right when highlighted.
	var sb := StyleBoxEmpty.new()
	for st in ["normal", "hover", "pressed", "hover_pressed", "disabled"]:
		b.add_theme_stylebox_override(st, sb)
	b.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	b.pressed.connect(func():
		Sfx.play_ui("lockon", -6.0)
		on_press.call_deferred())   # deferred: a page switch frees this very button
	b.focus_entered.connect(func():
		_slide(b, sb, 16.0)
		if not _quiet:
			Sfx.play_ui("lockon", -14.0))
	b.focus_exited.connect(func(): _slide(b, sb, 0.0))
	b.mouse_entered.connect(func(): b.grab_focus())
	_buttons.add_child(b)
	return b


func _slide(b: Button, sb: StyleBoxEmpty, to: float) -> void:
	if not b.is_inside_tree() or _quiet:
		sb.content_margin_left = to
		return
	b.create_tween().tween_property(sb, "content_margin_left", to, 0.16).set_trans(Tween.TRANS_CUBIC) \
		.set_ease(Tween.EASE_OUT)


## An option row: its name, and its value at the right ("‹  2  ›" while highlighted); Enter /
## click steps forward, left / right step either way. `values` are the choices' labels,
## `get_index` / `set_index` read and store it.
func _option(name: String, values: Array, get_index: Callable, set_index: Callable, note: String) -> Button:
	var b := _button(name, func(): pass)
	var value := UiTheme.label("", UiTheme.sans(400, 2), 28, UiTheme.DIM, HORIZONTAL_ALIGNMENT_RIGHT)
	value.set_anchors_preset(Control.PRESET_FULL_RECT)
	b.add_child(value)
	var refresh := func():
		var v := str(values[int(get_index.call())])
		var lit := b.has_focus()
		value.text = "\u2039    %s    \u203a" % v if lit else v
		value.add_theme_color_override("font_color", UiTheme.TEXT if lit else UiTheme.DIM)
	var step := func(dir: int):
		set_index.call(posmod(int(get_index.call()) + dir, values.size()))
		refresh.call()
	b.pressed.connect(func(): step.call(1))
	b.set_meta("step", step)           # left / right (see _input)
	b.focus_entered.connect(func():
		_note.text = note
		refresh.call())
	b.focus_exited.connect(refresh)
	refresh.call()
	return b


## A slider row: its name, and at the right a thin bar with its value (0 to 100), arrows round
## it while highlighted. Left / right move it a `step` (0..1) at a time, no further than the
## ends; a click or a drag on the bar sets it. `get_value` / `set_value` read and store it (0..1).
func _slider(name: String, get_value: Callable, set_value: Callable, step: float, note: String) -> Button:
	var b := _button(name, func(): pass)
	var bar := SliderBar.new()
	bar.row = b
	bar.get_value = get_value
	bar.set_value = set_value
	bar.anchor_left = 1.0
	bar.anchor_right = 1.0
	bar.anchor_bottom = 1.0
	bar.offset_left = -SliderBar.WIDTH
	b.add_child(bar)
	b.set_meta("step", func(dir: int):
		set_value.call(clampf(float(get_value.call()) + dir * step, 0.0, 1.0))
		bar.queue_redraw())
	b.focus_entered.connect(func():
		_note.text = note
		bar.queue_redraw())
	b.focus_exited.connect(bar.queue_redraw)
	return b


func _process(delta: float) -> void:
	if not visible:
		return
	# The marker glides to the highlighted item.
	var f := _focused()
	_marker.visible = f != null
	if f == null:
		_marker_y = -1.0
		return
	var r := f.get_global_rect()
	var y := r.position.y + r.size.y * 0.5 - 1.0
	var real_dt := minf(Game.unscaled(delta), 0.1)
	_marker_y = y if _marker_y < 0.0 else lerpf(_marker_y, y, 1.0 - exp(-real_dt * 18.0))
	_marker.position = Vector2(_column.position.x - 52.0, _marker_y)


# ------------------------------------------------------------------------------ keyboard + gamepad
func _input(event: InputEvent) -> void:
	if not visible or _page == "":
		return
	GameInput.notice(event)
	# Every direction and accept event is ours while a menu is open, even the ones that don't
	# move anything (a stick still held over, a release): Godot's own focus navigation must
	# not see them, or a stick push moves two rows.
	var ours := event.is_action("ui_up") or event.is_action("ui_down") or event.is_action("ui_left") \
		or event.is_action("ui_right") or event.is_action("ui_accept") \
		or (event is InputEventJoypadMotion and _stick.has((event as InputEventJoypadMotion).axis))
	var nav := _nav(event)
	if nav.y != 0:
		_move_focus(nav.y)
	elif nav.x != 0:
		var f := _focused()
		if f != null and f.has_meta("step"):
			(f.get_meta("step") as Callable).call(nav.x)
			Sfx.play_ui("lockon", -8.0)
	elif event.is_action_pressed("ui_accept"):
		var f := _focused()
		if f == null:
			_move_focus(0)              # nothing highlighted (a stray click): highlight first
		else:
			f.pressed.emit()
	if ours:
		get_viewport().set_input_as_handled()


## One step per press: arrow keys (with key repeat), the D-pad, and the left stick, which is
## latched so a push moves one row instead of one per stick event.
func _nav(event: InputEvent) -> Vector2i:
	if event is InputEventJoypadMotion:
		var jm := event as InputEventJoypadMotion
		if not _stick.has(jm.axis):
			return Vector2i.ZERO
		var d := 0
		if jm.axis_value > 0.6:
			d = 1
		elif jm.axis_value < -0.6:
			d = -1
		elif absf(jm.axis_value) > 0.35:
			return Vector2i.ZERO            # between the thresholds: stay as we were
		if d == int(_stick[jm.axis]):
			return Vector2i.ZERO
		_stick[jm.axis] = d
		if d == 0:
			return Vector2i.ZERO
		return Vector2i(d, 0) if jm.axis == JOY_AXIS_LEFT_X else Vector2i(0, d)
	if event.is_action_pressed("ui_up", true):
		return Vector2i(0, -1)
	if event.is_action_pressed("ui_down", true):
		return Vector2i(0, 1)
	if event.is_action_pressed("ui_left", true):
		return Vector2i(-1, 0)
	if event.is_action_pressed("ui_right", true):
		return Vector2i(1, 0)
	return Vector2i.ZERO


## The highlighted menu item, if any.
func _focused() -> Button:
	var f := get_viewport().gui_get_focus_owner()
	if f is Button and _buttons.is_ancestor_of(f):
		return f as Button
	return null


## Highlights the item `dir` rows away (wrapping around); 0 = the first item.
func _move_focus(dir: int) -> void:
	var items := _buttons.get_children().filter(func(c): return c is Button and not c.is_queued_for_deletion())
	if items.is_empty():
		return
	var i := items.find(_focused())
	i = 0 if i < 0 or dir == 0 else posmod(i + dir, items.size())
	(items[i] as Button).grab_focus()


# ------------------------------------------------------------------------------ pages
func open_title() -> void:
	_root_page = "title"
	_show("title")


func open_pause() -> void:
	_root_page = "pause"
	_show("pause")


func close() -> void:
	# Let go of the highlight, or the buttons (hidden, still focused) would take A presses.
	if _focused() != null:
		get_viewport().gui_release_focus()
	visible = false
	_page = ""
	Music.end_preview()


func is_open() -> bool:
	return visible


## Esc / (B): from Options, Controls or Lore back to the menu they came from. Returns false on
## a root page (the caller decides what that means: resume, or nothing on the title).
func back() -> bool:
	if _page in ["options", "controls", "lore"]:
		_show(_root_page, _page.capitalize())
		return true
	return false


## Builds `page`; `focus_on` highlights the item with that text (the one you came back from),
## otherwise the first.
func _show(page: String, focus_on := "") -> void:
	_page = page
	visible = true
	_quiet = true
	if page != "options":
		Music.end_preview()          # (the music played on the title's Options page to set its volume)
	for c in _buttons.get_children():
		_buttons.remove_child(c)
		c.queue_free()
	_note.text = ""
	_controls.visible = page == "controls"
	_lore.visible = page == "lore"
	_title_shade.visible = _root_page == "title" and page != "controls" and page != "lore"
	_backdrop.visible = not _title_shade.visible
	_hints.set_items(HINTS[page])
	var title := page == "title"
	_heading.add_theme_font_override("font", UiTheme.serif(500, 26) if title else UiTheme.serif(500, 2))
	_heading.add_theme_font_size_override("font_size", 128 if title else 72)
	_subheading.visible = title
	var first: Button
	match page:
		"title":
			_heading.text = "DANKIRO"
			_subheading.text = SUBTITLE.to_upper()
			first = _button("Start fight", func(): start_pressed.emit())
			_button("Options", func(): _show("options"))
			_button("Controls", func(): _show("controls"))
			_button("Lore", func(): _show("lore"))
			_button("Quit", func(): quit_pressed.emit())
			if Game.start_phase > 1:
				_note.text = "The fight starts in phase %d (Options)." % Game.start_phase
		"pause":
			_heading.text = "Paused"
			first = _button("Resume", func(): resume_pressed.emit())
			_button("Restart fight", func(): restart_pressed.emit())
			_button("Options", func(): _show("options"))
			_button("Controls", func(): _show("controls"))
			_button("Lore", func(): _show("lore"))
			_button("Quit to title", func(): title_pressed.emit())
		"options":
			_heading.text = "Options"
			var later := "" if _root_page == "title" else " Takes effect when you restart the fight."
			var on_title := _root_page == "title"
			var set_music := func(v: float):
				Game.set_music_volume(v)
				if on_title:
					Music.preview()        # (the title is quiet: play some, so you hear what you set)
			first = _slider("Music", func(): return Game.music_volume, set_music, Game.MUSIC_VOLUME_STEP,
				"How loud the music is: a track for each phase, crossfading as he rises into the " +
				"next. %d by default, quietly under the fight." % roundi(Game.DEFAULT_MUSIC_VOLUME * 100.0))
			_option("Starting phase", ["1", "2", "3"],
				func(): return Game.start_phase - 1,
				func(i: int): Game.set_start_phase(i + 1),
				"The phase the fight starts in, for testing: the earlier lives count as taken. " +
				"Phase 3 adds the Tempest of Fangs and waves of fire in the Inferno. Back to 1 " +
				"each time the game starts." + later)
			_option("Diagnostics", ["Off", "On"],
				func(): return 1 if Game.debug else 0,
				func(i: int): Game.set_diagnostics(i == 1),
				"Shows hitboxes (hurtboxes, weapons lit while a hit window is open), your guard " +
				"and deflect window, where each blow landed, and a live readout of both fighters. " +
				"F3 toggles it during a fight. Off each time the game starts.")
			_button("Back", func(): back())
		"controls":
			_heading.text = "Controls"
			first = _button("Back", func(): back())
		"lore":
			_heading.text = "Lore"
			first = _button("Back", func(): back())
	_column.offset_top = 200 if title else 150
	for c in _buttons.get_children():
		if focus_on != "" and c is Button and (c as Button).text == focus_on:
			first = c
	first.grab_focus()
	_quiet = false
	# The page eases in from a little to the left.
	_column.modulate.a = 0.0
	_column.offset_left = COLUMN_X - 18.0
	var tw := _column.create_tween().set_parallel(true)
	tw.tween_property(_column, "modulate:a", 1.0, 0.22)
	tw.tween_property(_column, "offset_left", COLUMN_X, 0.3).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	_marker_y = -1.0


## The slider's bar and value, at the right of its row (see _slider): a thin line, lit up to the
## value, with a dot on it and the value after it; the arrows either side while the row is
## highlighted. Clicks and drags on it set the value (and highlight the row).
class SliderBar extends Control:
	const WIDTH := 330.0
	const LINE_FROM := 34.0            ## the line, from here...
	const LINE_TO := 230.0             ## ...to here; then the value, then the right arrow
	var row: Button
	var get_value: Callable
	var set_value: Callable
	var _dragging := false

	func _ready() -> void:
		mouse_filter = Control.MOUSE_FILTER_STOP

	func _gui_input(event: InputEvent) -> void:
		if event is InputEventMouseButton and (event as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT:
			_dragging = (event as InputEventMouseButton).pressed
			if _dragging:
				_set_from((event as InputEventMouseButton).position.x)
			accept_event()
		elif event is InputEventMouseMotion:
			if not row.has_focus():
				row.grab_focus()
			if _dragging:
				_set_from((event as InputEventMouseMotion).position.x)
				accept_event()

	func _set_from(x: float) -> void:
		var v := clampf((x - LINE_FROM) / (LINE_TO - LINE_FROM), 0.0, 1.0)
		if not is_equal_approx(v, float(get_value.call())):
			set_value.call(v)
			queue_redraw()

	func _draw() -> void:
		var lit := row.has_focus()
		var v := clampf(float(get_value.call()), 0.0, 1.0)
		var y := size.y * 0.5
		var font := UiTheme.sans(400, 2)
		var col := UiTheme.TEXT if lit else UiTheme.DIM
		var base := y + 28.0 * 0.35              # (the capitals centred on the line)
		var x := lerpf(LINE_FROM, LINE_TO, v)
		draw_line(Vector2(LINE_FROM, y), Vector2(LINE_TO, y), UiTheme.FAINT, 2.0)
		if v > 0.0:
			draw_line(Vector2(LINE_FROM, y), Vector2(x, y), col, 2.0)
		draw_circle(Vector2(x, y), 7.0 if lit else 5.0, col, true, -1.0, true)
		draw_string(font, Vector2(LINE_TO + 16.0, base), str(roundi(v * 100.0)), HORIZONTAL_ALIGNMENT_RIGHT, 56.0, 28, col)
		if lit:
			draw_string(font, Vector2(0.0, base), "\u2039", HORIZONTAL_ALIGNMENT_LEFT, -1, 28, col)
			draw_string(font, Vector2(size.x - 12.0, base), "\u203a", HORIZONTAL_ALIGNMENT_LEFT, -1, 28, col)
