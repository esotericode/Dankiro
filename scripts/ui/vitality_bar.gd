class_name VitalityBar
extends Control
## A vitality bar: an ivory bar on a dark track. Damage just taken shows as a vermilion chip
## that holds for a moment, then drains down to the new value. Below `warn_below` the bar itself
## turns vermilion and breathes (the player's, when a blow or two from death).

var ratio := 1.0
var chip := 1.0
var warn_below := 0.0
var _chip_delay := 0.0
var _t := 0.0


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func set_ratio(r: float) -> void:
	r = clampf(r, 0.0, 1.0)
	if r < ratio - 0.0001:
		_chip_delay = 0.6
	if r > chip:
		chip = r
	ratio = r


func _process(delta: float) -> void:
	var real_dt := minf(Game.unscaled(delta), 0.1)
	_t += real_dt
	if _chip_delay > 0.0:
		_chip_delay -= real_dt
	else:
		chip = move_toward(chip, ratio, real_dt * 0.5)
	queue_redraw()


func _draw() -> void:
	var w := size.x
	var h := size.y
	UiTheme.bar_track(self, w, h)
	var warn := ratio < warn_below and ratio > 0.0
	if chip > ratio:
		var chip_col := Color(1.0, 0.62, 0.5, 0.45) if warn else UiTheme.ACCENT
		draw_rect(Rect2(Vector2(w * ratio, 0), Vector2(w * (chip - ratio), h)), chip_col)
	if ratio > 0.0:
		var col := UiTheme.TEXT
		if warn:
			col = UiTheme.ACCENT.lerp(Color(1.0, 0.62, 0.5), 0.3 + 0.3 * sin(_t * 5.0))
		draw_rect(Rect2(Vector2.ZERO, Vector2(maxf(w * ratio, 1.0), h)), col)
