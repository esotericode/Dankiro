extends Node
## Registers every input action in code, so the project runs without touching
## Project Settings > Input Map. Existing actions (e.g. rebound in the editor) are kept.
##
## Keyboard/mouse follows Sekiro's PC defaults; gamepad follows the console layout.

const MOUSE_SENSITIVITY := 0.0026
const STICK_SENSITIVITY := 3.2


func _enter_tree() -> void:
	_movement()
	_actions()
	_menus()


func _movement() -> void:
	_keys("move_forward", [KEY_W, KEY_UP])
	_keys("move_back", [KEY_S, KEY_DOWN])
	_keys("move_left", [KEY_A, KEY_LEFT])
	_keys("move_right", [KEY_D, KEY_RIGHT])
	_axis("move_forward", JOY_AXIS_LEFT_Y, -1.0)
	_axis("move_back", JOY_AXIS_LEFT_Y, 1.0)
	_axis("move_left", JOY_AXIS_LEFT_X, -1.0)
	_axis("move_right", JOY_AXIS_LEFT_X, 1.0)
	_axis("cam_left", JOY_AXIS_RIGHT_X, -1.0)
	_axis("cam_right", JOY_AXIS_RIGHT_X, 1.0)
	_axis("cam_up", JOY_AXIS_RIGHT_Y, -1.0)
	_axis("cam_down", JOY_AXIS_RIGHT_Y, 1.0)


func _actions() -> void:
	_mouse("attack", MOUSE_BUTTON_LEFT)
	_keys("attack", [KEY_J])
	_button("attack", JOY_BUTTON_RIGHT_SHOULDER)

	_mouse("guard", MOUSE_BUTTON_RIGHT)
	_keys("guard", [KEY_K])
	_button("guard", JOY_BUTTON_LEFT_SHOULDER)

	_keys("dodge", [KEY_SHIFT])
	_button("dodge", JOY_BUTTON_B)

	_keys("jump", [KEY_SPACE])
	_button("jump", JOY_BUTTON_A)

	_keys("lock_on", [KEY_Q])
	_mouse("lock_on", MOUSE_BUTTON_MIDDLE)
	_button("lock_on", JOY_BUTTON_RIGHT_STICK)

	_keys("heal", [KEY_R])
	_button("heal", JOY_BUTTON_X)

	_keys("pause", [KEY_ESCAPE])
	_button("pause", JOY_BUTTON_START)

	_keys("help", [KEY_F1])
	_button("help", JOY_BUTTON_BACK)

	_keys("confirm", [KEY_ENTER, KEY_KP_ENTER])
	_button("confirm", JOY_BUTTON_A)

	_keys("fullscreen", [KEY_F11])
	_keys("debug", [KEY_F3])


## Godot's built-in menu actions have the D-pad and left stick for moving around, but only keys
## for accepting and going back: add A (accept) and B (back) so the menus work on a gamepad.
func _menus() -> void:
	_button("ui_accept", JOY_BUTTON_A)
	_button("ui_cancel", JOY_BUTTON_B)


func _ensure(action: String, deadzone := 0.2) -> void:
	if not InputMap.has_action(action):
		InputMap.add_action(action, deadzone)


func _keys(action: String, keycodes: Array) -> void:
	_ensure(action)
	for kc in keycodes:
		var ev := InputEventKey.new()
		ev.physical_keycode = kc
		InputMap.action_add_event(action, ev)


func _mouse(action: String, button: MouseButton) -> void:
	_ensure(action)
	var ev := InputEventMouseButton.new()
	ev.button_index = button
	InputMap.action_add_event(action, ev)


## Gamepad bindings are for every connected pad (device -1, "all devices"), not just the first.
func _button(action: String, button: JoyButton) -> void:
	_ensure(action)
	var ev := InputEventJoypadButton.new()
	ev.device = -1
	ev.button_index = button
	if not InputMap.action_has_event(action, ev):
		InputMap.action_add_event(action, ev)


func _axis(action: String, axis: JoyAxis, value: float) -> void:
	_ensure(action, 0.22)
	var ev := InputEventJoypadMotion.new()
	ev.device = -1
	ev.axis = axis
	ev.axis_value = value
	if not InputMap.action_has_event(action, ev):
		InputMap.action_add_event(action, ev)
