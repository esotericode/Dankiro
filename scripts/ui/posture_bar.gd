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
	# frame
	draw_rect(Rect2(Vector2(-3, -3), Vector2(w + 6, h + 6)), Color(0.0, 0.0, 0.0, 0.55 * a))
	draw_rect(Rect2(Vector2(-3, -3), Vector2(w + 6, h + 6)), Color(0.72, 0.6, 0.38, 0.55 * a), false, 1.5)
	draw_rect(Rect2(Vector2.ZERO, Vector2(w, h)), Color(0.08, 0.06, 0.05, 0.75 * a))
	# fill from the centre
	var half := cx * shown
	var low := Color(1.0, 0.78, 0.25)
	var high := Color(1.0, 0.22, 0.05)
	var col := low.lerp(high, smoothstep(0.35, 0.95, shown))
	if shown > 0.8:
		var pulse := 0.5 + 0.5 * sin(_t * 14.0)
		col = col.lerp(Color(1.0, 0.9, 0.7), pulse * 0.35)
	if _flash > 0.0:
		col = col.lerp(Color.WHITE, _flash)
		half = cx
	col.a = a
	draw_rect(Rect2(Vector2(cx - half, 0), Vector2(half * 2.0, h)), col)
	# glossy top edge
	draw_rect(Rect2(Vector2(cx - half, 0), Vector2(half * 2.0, h * 0.3)), Color(1, 1, 1, 0.18 * a))
	# centre diamond
	var d := h * 0.9
	var pts := PackedVector2Array([Vector2(cx, -d * 0.35), Vector2(cx + d * 0.5, h * 0.5), Vector2(cx, h + d * 0.35),
		Vector2(cx - d * 0.5, h * 0.5)])
	draw_colored_polygon(pts, Color(0.85, 0.72, 0.45, a))
