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
	draw_rect(Rect2(Vector2(-3, -3), Vector2(w + 6, h + 6)), Color(0, 0, 0, 0.6))
	draw_rect(Rect2(Vector2(-3, -3), Vector2(w + 6, h + 6)), Color(0.55, 0.47, 0.33, 0.55), false, 1.5)
	draw_rect(Rect2(Vector2.ZERO, Vector2(w, h)), Color(0.06, 0.05, 0.05, 0.85))
	draw_rect(Rect2(Vector2.ZERO, Vector2(w * chip, h)), Color(0.9, 0.82, 0.7, 0.8))
	draw_rect(Rect2(Vector2.ZERO, Vector2(w * ratio, h)), fill_color)
	draw_rect(Rect2(Vector2.ZERO, Vector2(w * ratio, h * 0.3)), Color(1, 1, 1, 0.15))
