class_name PostureBar
extends Control
## Sekiro-style posture gauge: fills from the centre outward, shifts from amber to an angry
## red as it nears breaking, pulses when close, flashes white on a break. Fades out when empty.

var ratio := 0.0
var shown := 0.0
var _alpha := 0.0
var _flash := 0.0
var _t := 0.0


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func set_ratio(r: float) -> void:
	ratio = clampf(r, 0.0, 1.0)


func flash() -> void:
	_flash = 1.0


func _process(delta: float) -> void:
	var real_dt := minf(delta / maxf(Engine.time_scale, 0.001), 0.1)
	_t += real_dt
	shown = lerpf(shown, ratio, 1.0 - exp(-real_dt * 14.0))
	var want_alpha := 1.0 if ratio > 0.005 or _flash > 0.0 else 0.0
	_alpha = move_toward(_alpha, want_alpha, real_dt * (6.0 if want_alpha > _alpha else 1.5))
	_flash = maxf(0.0, _flash - real_dt * 1.6)
	queue_redraw()


func _draw() -> void:
	if _alpha <= 0.001:
		return
	var w := size.x
	var h := size.y
	var cx := w * 0.5
	var a := _alpha
	var frame := Rect2(Vector2(-4, -4), Vector2(w + 8, h + 8))
	draw_rect(frame, Color(0.015, 0.014, 0.015, 0.72 * a))
	draw_rect(frame, Color(0.58, 0.45, 0.3, 0.6 * a), false, 1.0)
	draw_rect(Rect2(Vector2.ZERO, size), Color(0.11, 0.09, 0.075, 0.82 * a))
	# fill from the centre
	var half := cx * shown
	var low := Color(0.92, 0.64, 0.3)
	var high := Color(0.93, 0.22, 0.1)
	var col := low.lerp(high, smoothstep(0.35, 0.95, shown))
	if shown > 0.8:
		var pulse := 0.5 + 0.5 * sin(_t * 14.0)
		col = col.lerp(Color(1.0, 0.9, 0.7), pulse * 0.35)
	if _flash > 0.0:
		col = col.lerp(Color.WHITE, _flash)
		half = cx
	col.a = a
	draw_rect(Rect2(Vector2(cx - half, 0), Vector2(half * 2.0, h)), col)
	draw_line(Vector2(cx - half, 1), Vector2(cx + half, 1), Color(1, 0.86, 0.62, 0.42 * a), 1.0)
	# centre diamond
	var d := h * 0.9
	var pts := PackedVector2Array([Vector2(cx, -d * 0.35), Vector2(cx + d * 0.5, h * 0.5), Vector2(cx, h + d * 0.35),
		Vector2(cx - d * 0.5, h * 0.5)])
	draw_colored_polygon(pts, Color(0.89, 0.74, 0.48, a))
