class_name PostureBar
extends Control
## Posture, as in Sekiro: fills from the centre outward, amber turning vermilion as it nears
## breaking, glowing when close. Ticks mark the centre and the ends (where it breaks). Flashes
## white on a break, and fades away while empty.

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
	UiTheme.bar_track(self, w, h, a)
	var half := cx * shown
	var col := UiTheme.AMBER.lerp(UiTheme.ACCENT, smoothstep(0.45, 0.95, shown))
	var glow := smoothstep(0.72, 1.0, shown) * (0.7 + 0.3 * sin(_t * 12.0))
	if _flash > 0.0:
		col = col.lerp(Color(1.0, 0.97, 0.92), _flash)
		half = cx
		glow = maxf(glow, _flash)
	if glow > 0.01 and half > 0.5:
		for i in 3:
			var g := 2.0 + 3.0 * i
			draw_rect(Rect2(Vector2(cx - half - g, -g), Vector2(half * 2.0 + g * 2.0, h + g * 2.0)),
				Color(col, 0.11 * glow * a))
	if half > 0.25:
		draw_rect(Rect2(Vector2(cx - half, 0), Vector2(half * 2.0, h)), Color(col, a))
	draw_rect(Rect2(Vector2(cx - 1.0, -4), Vector2(2, h + 8)), Color(UiTheme.TEXT, 0.65 * a))
	for x in [-2.0, w]:
		draw_rect(Rect2(Vector2(x, -4), Vector2(2, h + 8)), Color(UiTheme.TEXT, 0.45 * a))
