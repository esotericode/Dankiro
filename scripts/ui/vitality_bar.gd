class_name VitalityBar
extends Control
## Health bar with a delayed pale "chip" showing recent damage.

var ratio := 1.0
var chip := 1.0
var fill_color := Color(0.62, 0.07, 0.06)
var _chip_delay := 0.0


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func set_ratio(r: float) -> void:
	r = clampf(r, 0.0, 1.0)
	if r < ratio:
		_chip_delay = 0.55
	elif r > chip:
		chip = r
	ratio = r


func _process(delta: float) -> void:
	var real_dt := minf(delta / maxf(Engine.time_scale, 0.001), 0.1)
	if _chip_delay > 0.0:
		_chip_delay -= real_dt
	else:
		chip = move_toward(chip, ratio, real_dt * 0.6)
	queue_redraw()


func _draw() -> void:
	var w := size.x
	var h := size.y
	var frame := Rect2(Vector2(-4, -4), Vector2(w + 8, h + 8))
	draw_rect(frame, Color(0.015, 0.014, 0.015, 0.78))
	draw_rect(frame, Color(0.55, 0.43, 0.31, 0.62), false, 1.0)
	draw_rect(Rect2(Vector2.ZERO, size), Color(0.12, 0.105, 0.1, 0.95))
	draw_rect(Rect2(Vector2.ZERO, Vector2(w * chip, h)), Color(0.86, 0.76, 0.59, 0.86))
	draw_rect(Rect2(Vector2.ZERO, Vector2(w * ratio, h)), fill_color)
	draw_line(Vector2(0, 1), Vector2(w * ratio, 1), Color(1.0, 0.7, 0.5, 0.48), 1.0)
	for i in range(1, 4):
		var x := w * float(i) / 4.0
		draw_line(Vector2(x, 0), Vector2(x, h), Color(0.04, 0.035, 0.035, 0.5), 1.0)
