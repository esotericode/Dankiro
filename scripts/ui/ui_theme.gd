class_name UiTheme
extends RefCounted
## The UI's look in one place, shared by the HUD, the menus and the controls sheet: ink and ivory
## with one accent (vermilion), two typefaces (Jost for text, Cormorant Garamond for names and
## titles), thin flat shapes and no ornament. Also the key and button glyphs the prompts use.

const TEXT := Color(0.94, 0.92, 0.87)               ## ivory
const DIM := Color(0.94, 0.92, 0.87, 0.64)
const FAINT := Color(0.94, 0.92, 0.87, 0.34)
const INK := Color(0.03, 0.03, 0.04)
const ACCENT := Color(0.88, 0.25, 0.16)            ## vermilion
const AMBER := Color(0.98, 0.72, 0.3)
const TRACK := Color(0.0, 0.0, 0.0, 0.55)          ## behind a bar
const EDGE := Color(0.0, 0.0, 0.0, 0.3)            ## a hairline round the track: the bar holds its shape on bright stone

const MARGIN := 72.0                                ## from the screen's edges

const SANS := "res://fonts/ui_sans.ttf"
const SERIF := "res://fonts/ui_serif.ttf"

## The gamepad's face buttons, in their usual colours (softened).
const FACE := {"A": Color(0.55, 0.84, 0.48), "B": Color(0.95, 0.44, 0.38), "X": Color(0.48, 0.68, 1.0),
	"Y": Color(0.97, 0.8, 0.38)}

static var _fonts := {}


## Jost at `weight` (100 thin to 900 black), `tracking` extra pixels after each letter.
static func sans(weight := 400, tracking := 0) -> Font:
	return _font(SANS, weight, tracking)


## Cormorant Garamond at `weight` (300 to 700), with lining figures.
static func serif(weight := 600, tracking := 0) -> Font:
	return _font(SERIF, weight, tracking)


static func _font(path: String, weight: int, tracking: int) -> Font:
	var key := "%s %d %d" % [path, weight, tracking]
	if not _fonts.has(key):
		var f: Font = ThemeDB.fallback_font
		if ResourceLoader.exists(path):
			var ts := TextServerManager.get_primary_interface()
			var v := FontVariation.new()
			v.base_font = load(path)
			v.variation_opentype = {ts.name_to_tag("wght"): weight}
			v.opentype_features = {ts.name_to_tag("lnum"): 1}
			v.spacing_glyph = tracking
			f = v
		_fonts[key] = f
	return _fonts[key]


## A label with a soft shadow under it, so it reads over the bright parts of the scene.
static func label(text: String, font: Font, font_size: int, color := TEXT,
		align := HORIZONTAL_ALIGNMENT_LEFT) -> Label:
	var l := Label.new()
	l.text = text
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	l.horizontal_alignment = align
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	l.add_theme_font_override("font", font)
	l.add_theme_font_size_override("font_size", font_size)
	l.add_theme_color_override("font_color", color)
	soft_shadow(l, font_size)
	return l


static func soft_shadow(c: Control, font_size: int) -> void:
	c.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.38))
	c.add_theme_constant_override("shadow_offset_x", 0)
	c.add_theme_constant_override("shadow_offset_y", maxi(1, font_size / 18))
	c.add_theme_constant_override("shadow_outline_size", maxi(3, font_size / 6))


## Puts `c` at `pos` (size `sz`) from the anchor point `anchor` (fractions of the screen).
static func place(c: Control, anchor: Vector2, pos: Vector2, sz: Vector2) -> void:
	c.anchor_left = anchor.x
	c.anchor_right = anchor.x
	c.anchor_top = anchor.y
	c.anchor_bottom = anchor.y
	c.offset_left = pos.x
	c.offset_top = pos.y
	c.offset_right = pos.x + sz.x
	c.offset_bottom = pos.y + sz.y


## A full-screen rect that shows the frame behind it blurred, darkened and drained of colour
## (shaders/ui_backdrop.gdshader): behind the menus and full-screen overlays.
static func backdrop(blur: float, darken: float, desaturate := 0.0) -> ColorRect:
	var r := ColorRect.new()
	r.set_anchors_preset(Control.PRESET_FULL_RECT)
	r.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var m := ShaderMaterial.new()
	m.shader = load("res://shaders/ui_backdrop.gdshader")
	m.set_shader_parameter("blur", blur)
	m.set_shader_parameter("darken", darken)
	m.set_shader_parameter("desaturate", desaturate)
	r.material = m
	return r


## A soft ellipse of ink that fades out to nothing at its edges: under words that sit over the
## scene (the namecard, a callout), so they read whatever is behind them.
static func shade_spot(alpha: float) -> TextureRect:
	var g := Gradient.new()
	g.set_color(0, Color(INK, alpha))
	g.set_color(1, Color(INK, 0.0))
	g.add_point(0.45, Color(INK, alpha * 0.72))
	var t := GradientTexture2D.new()
	t.gradient = g
	t.fill = GradientTexture2D.FILL_RADIAL
	t.fill_from = Vector2(0.5, 0.5)
	t.fill_to = Vector2(1.0, 0.5)
	t.width = 128
	t.height = 128
	var r := TextureRect.new()
	r.texture = t
	r.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	r.stretch_mode = TextureRect.STRETCH_SCALE
	r.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return r


## The dark track behind a (w, h) bar at the canvas item's origin, with a hairline edge round it.
static func bar_track(ci: CanvasItem, w: float, h: float, a := 1.0) -> void:
	ci.draw_rect(Rect2(Vector2(-2, -2), Vector2(w + 4, h + 4)), Color(EDGE, EDGE.a * a))
	ci.draw_rect(Rect2(Vector2(-1, -1), Vector2(w + 2, h + 2)), Color(TRACK, TRACK.a * a))


## A key or button as a small glyph: `key` as ControlsSheet.BINDINGS writes it ("Shift", "Left
## mouse", "RB"...); `pad` says it's a gamepad button (so "A" is the face button, not the key).
static func chip(key: String, pad: bool, height := 30.0) -> Control:
	return Chip.new(key, pad, height)


## A hint: the glyphs of its keys, then what they do.
static func hint(keys: Array, pad: bool, text: String, height := 28.0, font_size := 17) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_theme_constant_override("separation", 5)
	for k in keys:
		row.add_child(chip(str(k), pad, height))
	var words := label(text, sans(400, 1), font_size, DIM)
	words.custom_minimum_size.x = 0
	var gap := Control.new()
	gap.custom_minimum_size = Vector2(5, 0)
	gap.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(gap)
	row.add_child(words)
	return row


## A row of hints that follows the device in use: each item is [keyboard keys, gamepad buttons,
## what they do]; an item with no keys for the device is left out.
class HintBar extends HBoxContainer:
	var items: Array = []
	var chip_height := 28.0
	var font_size := 17

	func _init(hint_items: Array = [], height := 28.0, text_size := 17) -> void:
		items = hint_items
		chip_height = height
		font_size = text_size
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_theme_constant_override("separation", 34)

	func _ready() -> void:
		GameInput.device_changed.connect(_on_device_changed)
		rebuild()

	func set_items(hint_items: Array) -> void:
		items = hint_items
		if is_inside_tree():
			rebuild()

	func _on_device_changed(_pad: bool) -> void:
		rebuild()

	func rebuild() -> void:
		for c in get_children():
			remove_child(c)
			c.queue_free()
		var pad: bool = GameInput.gamepad
		for it in items:
			var keys: Array = it[1] if pad else it[0]
			if not keys.is_empty():
				add_child(UiTheme.hint(keys, pad, str(it[2]), chip_height, font_size))


## One key or button, drawn: keys are rounded squares with their name, arrows get a triangle,
## the mouse is a mouse with the button that matters lit, the face buttons are rings with the
## letter in its colour, the sticks rings within rings, the shoulders and Start / Back pills.
class Chip extends Control:
	var key := ""
	var shape := ""
	var text := ""

	func _init(k: String, pad: bool, height: float) -> void:
		key = k
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		size_flags_vertical = Control.SIZE_SHRINK_CENTER
		if pad:
			if k in UiTheme.FACE:
				shape = "face"
			elif k.ends_with("stick") or k == "L3" or k == "R3":
				shape = "stick"
			elif k == "D-pad":
				shape = "dpad"
			else:
				shape = "pill"
		elif k.ends_with("mouse") or k == "Mouse":
			shape = "mouse"
		elif k in ["Up", "Down", "Left", "Right"]:
			shape = "arrow"
		else:
			shape = "key"
		text = {"L stick": "L", "R stick": "R"}.get(k, k)
		custom_minimum_size = Vector2(_width(height), height)

	func _font_size(h: float) -> int:
		return int(round(h * (0.42 if shape == "stick" else 0.5)))

	func _width(h: float) -> float:
		match shape:
			"face", "stick", "dpad", "arrow":
				return h
			"mouse":
				return h * 0.74
		var tw := UiTheme.sans(500).get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, _font_size(h)).x
		var w := maxf(h, tw + h * 0.66)
		return maxf(w, h * 2.6) if key == "Space" else w

	func _draw() -> void:
		var h := size.y
		var w := size.x
		var c := size * 0.5
		var line := Color(UiTheme.TEXT, 0.5)
		var fill := Color(UiTheme.INK, 0.55)
		match shape:
			"key", "arrow", "pill":
				var sb := StyleBoxFlat.new()
				sb.bg_color = fill
				sb.border_color = line
				sb.set_border_width_all(1)
				sb.set_corner_radius_all(int(h * 0.5) if shape == "pill" else maxi(3, int(h * 0.16)))
				sb.anti_aliasing = true
				draw_style_box(sb, Rect2(Vector2.ZERO, size))
				if shape == "arrow":
					_arrow(c, h * 0.2)
				else:
					_text(text, UiTheme.TEXT)
			"face":
				draw_circle(c, h * 0.5 - 0.5, fill, true, -1.0, true)
				draw_circle(c, h * 0.5 - 1.0, line, false, 1.2, true)
				_text(text, UiTheme.FACE[key], UiTheme.sans(600))
			"stick":
				draw_circle(c, h * 0.5 - 0.5, fill, true, -1.0, true)
				draw_circle(c, h * 0.5 - 1.0, line, false, 1.2, true)
				draw_circle(c, h * 0.3, Color(UiTheme.TEXT, 0.28), false, 1.0, true)
				_text(text, UiTheme.TEXT)
			"dpad":
				var a := h * 0.17
				var r := h * 0.47
				var pts := PackedVector2Array([Vector2(-a, -r), Vector2(a, -r), Vector2(a, -a), Vector2(r, -a),
					Vector2(r, a), Vector2(a, a), Vector2(a, r), Vector2(-a, r), Vector2(-a, a), Vector2(-r, a),
					Vector2(-r, -a), Vector2(-a, -a)])
				for i in pts.size():
					pts[i] += c
				draw_colored_polygon(pts, fill)
				pts.append(pts[0])
				draw_polyline(pts, line, 1.2, true)
			"mouse":
				_mouse(w, h, line, fill)

	## `t` centred on the glyph, its capitals centred on the middle.
	func _text(t: String, col: Color, font: Font = null) -> void:
		var f := font if font != null else UiTheme.sans(500)
		var fs := _font_size(size.y)
		var tw := f.get_string_size(t, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
		var cap := fs * 0.7
		draw_string(f, Vector2((size.x - tw) * 0.5, (size.y + cap) * 0.5), t, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, col)

	func _arrow(c: Vector2, s: float) -> void:
		var d: Vector2 = {"Up": Vector2.UP, "Down": Vector2.DOWN, "Left": Vector2.LEFT, "Right": Vector2.RIGHT}[key]
		var side := Vector2(-d.y, d.x)
		draw_colored_polygon(PackedVector2Array([c + d * s, c - d * s * 0.7 + side * s, c - d * s * 0.7 - side * s]),
			UiTheme.TEXT)

	func _mouse(w: float, h: float, line: Color, fill: Color) -> void:
		var body := Rect2(Vector2(1, 0.5), Vector2(w - 2, h - 1))
		var r := body.size.x * 0.5
		var sb := StyleBoxFlat.new()
		sb.bg_color = fill
		sb.border_color = line
		sb.set_border_width_all(1)
		sb.set_corner_radius_all(int(r))
		sb.anti_aliasing = true
		draw_style_box(sb, body)
		var cx := body.get_center().x
		var split := body.position.y + body.size.y * 0.42
		draw_line(Vector2(cx, body.position.y + 1), Vector2(cx, split), line, 1.0, true)
		draw_line(Vector2(body.position.x + 1, split), Vector2(body.end.x - 1, split), line, 1.0, true)
		var lit := Color(UiTheme.TEXT, 0.9)
		var top := body.position.y + r
		if key == "Left mouse" or key == "Right mouse":
			# the button's quarter: down the side, round the top corner, back down the middle
			var sgn := -1.0 if key == "Left mouse" else 1.0
			var rr := r - 2.0
			var meet := acos(1.5 / rr)            # where the curve reaches the middle line
			var pts := PackedVector2Array()
			pts.append(Vector2(cx + sgn * 1.5, split - 1.5))
			pts.append(Vector2(cx + sgn * rr, split - 1.5))
			for i in 9:
				var ang := meet * float(i) / 8.0
				pts.append(Vector2(cx + sgn * rr * cos(ang), top - rr * sin(ang)))
			draw_colored_polygon(pts, lit)
		elif key == "Middle mouse":
			draw_rect(Rect2(Vector2(cx - 1.5, body.position.y + h * 0.14), Vector2(3, h * 0.2)), lit)
