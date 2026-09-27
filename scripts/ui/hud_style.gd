class_name HudStyle
extends RefCounted
## Shared drawing for the HUD's gauges: a dark lacquer backing in a thin gilt frame with pointed
## end caps (like a sword's guard), and fills lit from above.

const GILT := Color(0.8, 0.66, 0.42)
const BACK := Color(0.045, 0.038, 0.036)


## The backing and frame of a (w, h) gauge drawn at the canvas item's origin, `a` its opacity.
static func frame(ci: CanvasItem, w: float, h: float, a: float) -> void:
	var pad := 3.0
	var outer := Rect2(Vector2(-pad, -pad), Vector2(w + pad * 2.0, h + pad * 2.0))
	ci.draw_rect(Rect2(outer.position + Vector2(0, 2), outer.size), Color(0, 0, 0, 0.35 * a))
	ci.draw_rect(outer, Color(BACK, 0.82 * a))
	ci.draw_rect(outer, Color(GILT, 0.62 * a), false, 1.2)
	var cy := h * 0.5
	var s := h * 0.5 + pad + 3.5
	for x in [-pad, w + pad]:
		var pts := PackedVector2Array([Vector2(x, cy - s), Vector2(x + s * 0.6, cy), Vector2(x, cy + s),
			Vector2(x - s * 0.6, cy), Vector2(x, cy - s)])
		ci.draw_colored_polygon(pts.slice(0, 4), Color(BACK, 0.95 * a))
		ci.draw_polyline(pts, Color(GILT, 0.9 * a), 1.3, true)


## A fill lit from above: lighter along its top, darker below, with a fine highlight line.
static func fill(ci: CanvasItem, r: Rect2, c: Color, a: float) -> void:
	if r.size.x <= 0.5:
		return
	var top := c.lightened(0.2)
	var bottom := c.darkened(0.4)
	top.a = a
	bottom.a = a
	ci.draw_polygon(PackedVector2Array([r.position, Vector2(r.end.x, r.position.y), r.end, Vector2(r.position.x, r.end.y)]),
		PackedColorArray([top, top, bottom, bottom]))
	ci.draw_line(r.position + Vector2(0, 0.75), Vector2(r.end.x, r.position.y + 0.75), Color(1, 1, 1, 0.25 * a), 1.0)
