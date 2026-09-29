class_name LoadingScreen
extends CanvasLayer
## Up while the game gets ready (Warmup): black, the name, and a thin vermilion line drawn out
## under it as the work goes on. Over everything (the HUD and the menus draw under it, unseen);
## finish() fades it away and frees it.

const RULE_HALF := 150.0          ## half the line's length when the work is done

var _root: Control
var _words: Control              ## the name and the line (they go first as it fades)
var _rule: ColorRect
var _progress := 0.0
var _shown := 0.0


func _ready() -> void:
	layer = 100
	process_mode = Node.PROCESS_MODE_ALWAYS
	_root = Control.new()
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_STOP        # clicks meanwhile go nowhere
	add_child(_root)
	var black := ColorRect.new()
	black.color = Color(0, 0, 0)
	black.set_anchors_preset(Control.PRESET_FULL_RECT)
	black.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(black)
	_words = Control.new()
	_words.set_anchors_preset(Control.PRESET_FULL_RECT)
	_words.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(_words)
	var title := UiTheme.label("DANKIRO", UiTheme.serif(500, 26), 64, UiTheme.DIM, HORIZONTAL_ALIGNMENT_CENTER)
	UiTheme.place(title, Vector2(0.5, 0.5), Vector2(-600, -76), Vector2(1200, 90))
	_words.add_child(title)
	_rule = ColorRect.new()
	_rule.color = UiTheme.ACCENT
	_rule.mouse_filter = Control.MOUSE_FILTER_IGNORE
	UiTheme.place(_rule, Vector2(0.5, 0.5), Vector2(0, 34), Vector2(0, 2))
	_words.add_child(_rule)


## How far along the work is, 0..1 (the line eases out toward it; it never goes back).
func set_progress(p: float) -> void:
	_progress = maxf(_progress, clampf(p, 0.0, 1.0))


func _process(delta: float) -> void:
	_shown = lerpf(_shown, _progress, 1.0 - exp(-minf(Game.unscaled(delta), 0.1) * 9.0))
	_rule.offset_left = -RULE_HALF * _shown
	_rule.offset_right = RULE_HALF * _shown


## Draws the line out to its end, lets the words go, then fades the black away over `seconds`
## (the title's own name comes up under it) and frees it.
func finish(seconds := 0.45) -> void:
	set_progress(1.0)
	var tw := _root.create_tween()
	tw.tween_interval(0.15)
	tw.tween_property(_words, "modulate:a", 0.0, 0.2)
	tw.tween_property(_root, "modulate:a", 0.0, seconds).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	tw.tween_callback(queue_free)
