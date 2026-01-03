# =============================================================================
# UI Test Runner - Visual UI Automation Testing for Godot
# =============================================================================
# MIT License - Copyright (c) 2025 Poplava
#
# Support & Community:
#   Discord: https://discord.gg/9GnrTKXGfq
#   GitHub:  https://github.com/graydwarf/godot-ui-test-runner
#   More Tools: https://poplava.itch.io
# =============================================================================

extends RefCounted
## Playback engine for UI test automation
## Handles mouse/keyboard simulation with visual cursor feedback

const Utils = preload("res://addons/ui-test-runner/utils.gd")
const Speed = Utils.Speed
const SPEED_MULTIPLIERS = Utils.SPEED_MULTIPLIERS

signal action_performed(action: String, details: Dictionary)

# Required references (set via initialize)
var _tree: SceneTree
var _viewport: Viewport
var _virtual_cursor: Node2D

# State
var current_speed: Speed = Speed.NORMAL
var is_running: bool = false
var action_log: Array[Dictionary] = []

# Initializes the playback engine with required references
func initialize(tree: SceneTree, viewport: Viewport, virtual_cursor: Node2D) -> void:
	_tree = tree
	_viewport = viewport
	_virtual_cursor = virtual_cursor

# ============================================================================
# SPEED CONTROL
# ============================================================================

func set_speed(speed: Speed) -> void:
	current_speed = speed
	var speed_name = Speed.keys()[speed]
	print("[UIPlaybackEngine] Speed set to: ", speed_name)

func cycle_speed() -> void:
	var next = (current_speed + 1) % Speed.size()
	set_speed(next)

func get_delay_multiplier() -> float:
	return SPEED_MULTIPLIERS[current_speed]

# ============================================================================
# COORDINATE CONVERSION
# ============================================================================

## Convert world position to screen position (for nodes under Camera2D)
func world_to_screen(world_pos: Vector2) -> Vector2:
	return _viewport.get_canvas_transform() * world_pos

## Convert screen position to world position
func screen_to_world(screen_pos: Vector2) -> Vector2:
	return _viewport.get_canvas_transform().affine_inverse() * screen_pos

## Get screen position of a CanvasItem (handles Node2D and Control)
func get_screen_pos(node: CanvasItem) -> Vector2:
	# For Control nodes, global_position is already in screen space
	if node is Control:
		return node.global_position
	# Check if node is under a CanvasLayer (already screen space)
	var parent = node.get_parent()
	while parent:
		if parent is CanvasLayer:
			return node.global_position
		parent = parent.get_parent()
	# Node is in world space, convert to screen
	return world_to_screen(node.global_position)

# ============================================================================
# CORE ACTIONS - Mouse simulation with visual feedback
# ============================================================================

## Move cursor to position with optional duration
func move_to(pos: Vector2, duration: float = 0.3) -> void:
	var multiplier = get_delay_multiplier()

	if multiplier == 0.0:
		# Instant
		_virtual_cursor.global_position = pos
	elif multiplier < 0.0:
		# Step mode - wait for input
		await _step_wait()
		_virtual_cursor.global_position = pos
	else:
		# Tweened movement
		_virtual_cursor.show_cursor()
		var tween = _tree.create_tween()
		tween.tween_property(_virtual_cursor, "global_position", pos, duration * multiplier)
		await tween.finished

	_log_action("move_to", {"position": pos})

## Click at current position with optional modifiers
func click(ctrl: bool = false, shift: bool = false) -> void:
	var pos = _virtual_cursor.global_position
	_virtual_cursor.show_click()

	# Warp actual mouse to position (required for GUI routing)
	Input.warp_mouse(pos)
	await _tree.process_frame

	# Send motion event first to establish position
	_emit_motion(pos, Vector2.ZERO)
	await _tree.process_frame

	# Press modifier keys BEFORE mouse click (mirrors real user interaction)
	# This ensures Input.is_key_pressed() returns correct state during click processing
	if ctrl:
		_press_modifier_key(KEY_CTRL)
	if shift:
		_press_modifier_key(KEY_SHIFT)
	await _tree.process_frame

	# Mouse down
	var down = InputEventMouseButton.new()
	down.button_index = MOUSE_BUTTON_LEFT
	down.pressed = true
	down.position = pos
	down.global_position = pos
	down.ctrl_pressed = ctrl
	down.shift_pressed = shift
	Input.parse_input_event(down)
	_viewport.push_input(down)

	await _tree.process_frame

	# Mouse up
	var up = InputEventMouseButton.new()
	up.button_index = MOUSE_BUTTON_LEFT
	up.pressed = false
	up.position = pos
	up.global_position = pos
	up.ctrl_pressed = ctrl
	up.shift_pressed = shift
	Input.parse_input_event(up)
	_viewport.push_input(up)

	await _tree.process_frame

	# Release modifier keys AFTER mouse click
	if shift:
		_release_modifier_key(KEY_SHIFT)
	if ctrl:
		_release_modifier_key(KEY_CTRL)
	await _tree.process_frame

	_log_action("click", {"position": pos, "ctrl": ctrl, "shift": shift})

## Click at specific position (move + click) with optional modifiers
func click_at(pos: Vector2, ctrl: bool = false, shift: bool = false) -> void:
	await move_to(pos)
	await click(ctrl, shift)

## Drag from current position to target
## hold_at_end: seconds to keep mouse pressed at target (for hover navigation)
func drag_to(to: Vector2, duration: float = 0.5, hold_at_end: float = 0.0) -> void:
	var from = _virtual_cursor.global_position
	var multiplier = get_delay_multiplier()

	_virtual_cursor.show_cursor()

	# Warp mouse and establish position
	Input.warp_mouse(from)
	_emit_motion(from, Vector2.ZERO)
	await _tree.process_frame

	# Mouse down at start - use parse_input_event to update Input singleton state
	var down = InputEventMouseButton.new()
	down.button_index = MOUSE_BUTTON_LEFT
	down.pressed = true
	down.position = from
	down.global_position = from
	Input.parse_input_event(down)  # Updates Input.is_mouse_button_pressed()
	_viewport.push_input(down)  # Also push to viewport for GUI routing
	await _tree.process_frame

	if multiplier == 0.0:
		# Instant drag
		_virtual_cursor.global_position = to
		Input.warp_mouse(to)
		_emit_motion(to, to - from, true)  # button_held=true
	elif multiplier < 0.0:
		# Step mode
		await _step_wait()
		_virtual_cursor.global_position = to
		Input.warp_mouse(to)
		_emit_motion(to, to - from, true)  # button_held=true
	else:
		# Tweened drag with motion events
		var steps = int(duration * 60 * multiplier)
		steps = max(steps, 5)  # At least 5 steps
		var last_pos = from

		for i in range(steps + 1):
			var t = float(i) / steps
			var pos = from.lerp(to, t)
			_virtual_cursor.global_position = pos
			_virtual_cursor.move_to(pos)
			Input.warp_mouse(pos)
			_emit_motion(pos, pos - last_pos, true)  # button_held=true
			last_pos = pos
			await _tree.process_frame

	# Hold at end position with mouse still pressed (for hover navigation triggers)
	# Note: hold_at_end is user-configured and NOT affected by speed setting
	if hold_at_end > 0.0:
		var elapsed = 0.0
		while elapsed < hold_at_end:
			# Keep sending motion events to maintain drag state
			_emit_motion(to, Vector2.ZERO, true)
			await _tree.process_frame
			elapsed += _tree.root.get_process_delta_time()

	# Mouse up at end
	Input.warp_mouse(to)
	var up = InputEventMouseButton.new()
	up.button_index = MOUSE_BUTTON_LEFT
	up.pressed = false
	up.position = to
	up.global_position = to
	Input.parse_input_event(up)  # Updates Input.is_mouse_button_pressed()
	_viewport.push_input(up)  # Also push to viewport for GUI routing

	await _tree.process_frame
	_log_action("drag_to", {"from": from, "to": to})

## Drag from one position to another (move + drag)
## hold_at_end: seconds to keep mouse pressed at target (for hover navigation)
func drag(from: Vector2, to: Vector2, duration: float = 0.5, hold_at_end: float = 0.0) -> void:
	await move_to(from, 0.2)
	await drag_to(to, duration, hold_at_end)

## Drag segment - drag without releasing mouse (for multi-step drag operations)
## Used when pressing T during recording to terminate a drag segment
## The mouse stays pressed at the end position for continued dragging
func drag_segment(from: Vector2, to: Vector2, duration: float = 0.5) -> void:
	var multiplier = get_delay_multiplier()

	_virtual_cursor.show_cursor()

	# Warp mouse and establish position
	Input.warp_mouse(from)
	_emit_motion(from, Vector2.ZERO)
	await _tree.process_frame

	# Mouse down at start (if not already down)
	if not Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
		var down = InputEventMouseButton.new()
		down.button_index = MOUSE_BUTTON_LEFT
		down.pressed = true
		down.position = from
		down.global_position = from
		Input.parse_input_event(down)
		_viewport.push_input(down)
		await _tree.process_frame

	if multiplier == 0.0:
		# Instant drag
		_virtual_cursor.global_position = to
		Input.warp_mouse(to)
		_emit_motion(to, to - from, true)
	elif multiplier < 0.0:
		# Step mode
		await _step_wait()
		_virtual_cursor.global_position = to
		Input.warp_mouse(to)
		_emit_motion(to, to - from, true)
	else:
		# Tweened drag with motion events
		var steps = int(duration * 60 * multiplier)
		steps = max(steps, 5)
		var last_pos = from

		for i in range(steps + 1):
			var t = float(i) / steps
			var pos = from.lerp(to, t)
			_virtual_cursor.global_position = pos
			_virtual_cursor.move_to(pos)
			Input.warp_mouse(pos)
			_emit_motion(pos, pos - last_pos, true)
			last_pos = pos
			await _tree.process_frame

	# NO mouse up - keep mouse pressed for next segment
	await _tree.process_frame
	_log_action("drag_segment", {"from": from, "to": to, "no_drop": true})

## Continue a drag segment - for segments after the first (mouse already down)
## Moves from current position to target without pressing/releasing mouse
func continue_drag_segment(to: Vector2, duration: float = 0.5) -> void:
	var from = _virtual_cursor.global_position
	var multiplier = get_delay_multiplier()

	if multiplier == 0.0:
		_virtual_cursor.global_position = to
		Input.warp_mouse(to)
		_emit_motion(to, to - from, true)
	elif multiplier < 0.0:
		await _step_wait()
		_virtual_cursor.global_position = to
		Input.warp_mouse(to)
		_emit_motion(to, to - from, true)
	else:
		var steps = int(duration * 60 * multiplier)
		steps = max(steps, 5)
		var last_pos = from

		for i in range(steps + 1):
			var t = float(i) / steps
			var pos = from.lerp(to, t)
			_virtual_cursor.global_position = pos
			_virtual_cursor.move_to(pos)
			Input.warp_mouse(pos)
			_emit_motion(pos, pos - last_pos, true)
			last_pos = pos
			await _tree.process_frame

	await _tree.process_frame
	_log_action("continue_drag_segment", {"from": from, "to": to})

## Complete a drag - release mouse at current position
## Used after drag_segment calls to finalize the drag operation
func complete_drag() -> void:
	var pos = _virtual_cursor.global_position
	Input.warp_mouse(pos)
	var up = InputEventMouseButton.new()
	up.button_index = MOUSE_BUTTON_LEFT
	up.pressed = false
	up.position = pos
	up.global_position = pos
	Input.parse_input_event(up)
	_viewport.push_input(up)
	await _tree.process_frame
	_log_action("complete_drag", {"pos": pos})

## Drag a CanvasItem by offset (handles world-to-screen conversion)
func drag_node(node: CanvasItem, offset: Vector2, duration: float = 0.5) -> void:
	var start_screen = get_screen_pos(node) + Vector2(20, 20)  # Offset into the node
	var end_screen = start_screen + offset
	await drag(start_screen, end_screen, duration)

## Click on a CanvasItem (handles world-to-screen conversion)
func click_node(node: CanvasItem) -> void:
	var screen_pos = get_screen_pos(node) + Vector2(20, 20)
	await click_at(screen_pos)

## Right click at current position
func right_click() -> void:
	var pos = _virtual_cursor.global_position

	# Warp actual mouse to position (required for proper event routing)
	Input.warp_mouse(pos)
	await _tree.process_frame

	# Send motion event first to establish position
	_emit_motion(pos, Vector2.ZERO)
	await _tree.process_frame

	# Mouse down - use parse_input_event to update Input singleton state
	var down = InputEventMouseButton.new()
	down.button_index = MOUSE_BUTTON_RIGHT
	down.pressed = true
	down.position = pos
	down.global_position = pos
	Input.parse_input_event(down)
	_viewport.push_input(down)

	await _tree.process_frame

	# Mouse up
	var up = InputEventMouseButton.new()
	up.button_index = MOUSE_BUTTON_RIGHT
	up.pressed = false
	up.position = pos
	up.global_position = pos
	Input.parse_input_event(up)
	_viewport.push_input(up)

	await _tree.process_frame
	_log_action("right_click", {"position": pos})

## Double click at current position with optional modifiers
func double_click(ctrl: bool = false, shift: bool = false) -> void:
	var pos = _virtual_cursor.global_position

	# Press modifier keys BEFORE double click
	if ctrl:
		_press_modifier_key(KEY_CTRL)
	if shift:
		_press_modifier_key(KEY_SHIFT)
	await _tree.process_frame

	for i in range(2):
		var down = InputEventMouseButton.new()
		down.button_index = MOUSE_BUTTON_LEFT
		down.pressed = true
		down.double_click = (i == 1)
		down.position = pos
		down.global_position = pos
		down.ctrl_pressed = ctrl
		down.shift_pressed = shift
		Input.parse_input_event(down)
		_viewport.push_input(down)
		await _tree.process_frame

		var up = InputEventMouseButton.new()
		up.button_index = MOUSE_BUTTON_LEFT
		up.pressed = false
		up.position = pos
		up.global_position = pos
		up.ctrl_pressed = ctrl
		up.shift_pressed = shift
		Input.parse_input_event(up)
		_viewport.push_input(up)
		await _tree.process_frame

	# Release modifier keys AFTER double click
	if shift:
		_release_modifier_key(KEY_SHIFT)
	if ctrl:
		_release_modifier_key(KEY_CTRL)
	await _tree.process_frame

	_log_action("double_click", {"position": pos, "ctrl": ctrl, "shift": shift})

## Pan from current position to target using middle mouse button
func pan_to(to: Vector2, duration: float = 0.3) -> void:
	var from = _virtual_cursor.global_position

	# Middle mouse down
	var down = InputEventMouseButton.new()
	down.button_index = MOUSE_BUTTON_MIDDLE
	down.pressed = true
	down.position = from
	down.global_position = from
	Input.parse_input_event(down)
	_viewport.push_input(down)
	await _tree.process_frame

	# Smooth movement to target
	var steps = int(duration * 60)  # 60 FPS
	for i in range(steps):
		var t = float(i + 1) / float(steps)
		var pos = from.lerp(to, t)
		_virtual_cursor.global_position = pos

		var motion = InputEventMouseMotion.new()
		motion.position = pos
		motion.global_position = pos
		motion.relative = (to - from) / steps
		_viewport.push_input(motion)
		await _tree.process_frame

	# Middle mouse up
	var up = InputEventMouseButton.new()
	up.button_index = MOUSE_BUTTON_MIDDLE
	up.pressed = false
	up.position = to
	up.global_position = to
	Input.parse_input_event(up)
	_viewport.push_input(up)

	await _tree.process_frame
	_log_action("pan_to", {"from": from, "to": to})

## Pan from one position to another (move + pan)
func pan(from: Vector2, to: Vector2, duration: float = 0.3) -> void:
	await move_to(from, 0.1)
	await pan_to(to, duration)

## Scroll (mouse wheel) at position with optional modifiers
func scroll(pos: Vector2, direction: String = "in", ctrl: bool = false, shift: bool = false, alt: bool = false, factor: float = 1.0) -> void:
	# Move cursor to position (skip if already there)
	if _virtual_cursor.global_position.distance_to(pos) > 5:
		await move_to(pos, 0.1)
	else:
		_virtual_cursor.global_position = pos

	Input.warp_mouse(pos)
	await _tree.process_frame

	_emit_motion(pos, Vector2.ZERO)
	await _tree.process_frame

	# Wheel event with modifiers
	var wheel = InputEventMouseButton.new()
	wheel.button_index = MOUSE_BUTTON_WHEEL_UP if direction == "in" else MOUSE_BUTTON_WHEEL_DOWN
	wheel.pressed = true
	wheel.position = pos
	wheel.global_position = pos
	wheel.factor = factor if factor > 0 else 1.0
	wheel.ctrl_pressed = ctrl
	wheel.shift_pressed = shift
	wheel.alt_pressed = alt
	Input.parse_input_event(wheel)
	await _tree.process_frame

	# WORKAROUND: Godot bug where Input.parse_input_event() with a wheel event
	# that has modifier flags (ctrl_pressed, etc.) leaves internal state stuck,
	# causing Control nodes to stop responding to input. Sending a wheel "release"
	# event with the SAME modifiers clears this stuck state.
	var wheel_release = InputEventMouseButton.new()
	wheel_release.button_index = wheel.button_index
	wheel_release.pressed = false
	wheel_release.position = pos
	wheel_release.global_position = pos
	wheel_release.ctrl_pressed = ctrl
	wheel_release.shift_pressed = shift
	wheel_release.alt_pressed = alt
	Input.parse_input_event(wheel_release)
	await _tree.process_frame

	_log_action("scroll", {"pos": pos, "direction": direction, "ctrl": ctrl, "shift": shift, "alt": alt, "factor": factor})

# ============================================================================
# KEYBOARD SIMULATION
# ============================================================================

func press_key(keycode: int, shift: bool = false, ctrl: bool = false, mouse_pos: Variant = null) -> void:
	# Warp mouse to recorded position if provided (important for paste operations)
	if mouse_pos != null:
		var target_pos: Vector2
		if mouse_pos is Vector2:
			target_pos = mouse_pos
		elif mouse_pos is Dictionary and mouse_pos.has("x") and mouse_pos.has("y"):
			target_pos = Vector2(mouse_pos.x, mouse_pos.y)
		else:
			target_pos = Vector2.ZERO
		if target_pos != Vector2.ZERO:
			Input.warp_mouse(target_pos)
			await _tree.process_frame

	var event = InputEventKey.new()
	event.keycode = keycode
	event.pressed = true
	event.shift_pressed = shift
	event.ctrl_pressed = ctrl

	# Set unicode for printable characters so TextEdit receives text input
	var unicode_char = keycode_to_unicode(keycode, shift)
	if unicode_char > 0:
		event.unicode = unicode_char

	_viewport.push_input(event)
	await _tree.process_frame

	event.pressed = false
	_viewport.push_input(event)
	await _tree.process_frame

	_log_action("press_key", {"keycode": keycode, "shift": shift, "ctrl": ctrl})

## Set an image for paste testing - injects into UITestRunner for clipboard bypass
## Mouse positioning is handled by the subsequent Ctrl+V key event
func set_clipboard_image(image_path: String, _paste_pos: Variant = null) -> void:
	if image_path.is_empty():
		push_warning("[PlaybackEngine] set_clipboard_image called with empty path - skipping")
		return

	var image: Image = null

	# Try to load as texture first (for imported resources)
	if ResourceLoader.exists(image_path):
		var resource = load(image_path)
		if resource is Texture2D:
			image = resource.get_image()
		elif resource is Image:
			image = resource

	# Fall back to loading directly from file
	if not image:
		var global_path = ProjectSettings.globalize_path(image_path)
		image = Image.new()
		var err = image.load(global_path)
		if err != OK:
			push_error("[PlaybackEngine] Failed to load image: %s (error: %d)" % [image_path, err])
			return

	# Inject into UITestRunner - clipboard manager will check this first
	var ui_test_runner = _tree.root.get_node_or_null("UITestRunner")
	if ui_test_runner:
		ui_test_runner.injected_clipboard_image = image
		print("[PlaybackEngine] Injected test image into UITestRunner")
	else:
		push_error("[PlaybackEngine] UITestRunner not found - cannot inject clipboard image")
		return

	# Note: Mouse positioning is now handled by the subsequent key event (Ctrl+V)
	# which stores the mouse position at the time the key was pressed

	await _tree.process_frame
	_log_action("set_clipboard_image", {"path": image_path})

## Converts keycode to unicode character (public for testing)
func keycode_to_unicode(keycode: int, shift: bool) -> int:
	# Letters A-Z
	if keycode >= KEY_A and keycode <= KEY_Z:
		if shift:
			return keycode  # Uppercase A-Z (65-90)
		else:
			return keycode + 32  # Lowercase a-z (97-122)

	# Numbers 0-9 and their shifted symbols
	if keycode >= KEY_0 and keycode <= KEY_9:
		if shift:
			var symbols = [41, 33, 64, 35, 36, 37, 94, 38, 42, 40]  # ) ! @ # $ % ^ & * (
			return symbols[keycode - KEY_0]
		else:
			return keycode  # 0-9 (48-57)

	# Space
	if keycode == KEY_SPACE:
		return 32

	# Common punctuation
	match keycode:
		KEY_PERIOD: return 46 if not shift else 62  # . >
		KEY_COMMA: return 44 if not shift else 60   # , <
		KEY_SLASH: return 47 if not shift else 63   # / ?
		KEY_SEMICOLON: return 59 if not shift else 58  # ; :
		KEY_APOSTROPHE: return 39 if not shift else 34  # ' "
		KEY_BRACKETLEFT: return 91 if not shift else 123  # [ {
		KEY_BRACKETRIGHT: return 93 if not shift else 125  # ] }
		KEY_BACKSLASH: return 92 if not shift else 124  # \ |
		KEY_MINUS: return 45 if not shift else 95  # - _
		KEY_EQUAL: return 61 if not shift else 43  # = +
		KEY_QUOTELEFT: return 96 if not shift else 126  # ` ~

	return 0  # Non-printable

func type_text(text: String, delay_per_char: float = 0.05) -> void:
	var multiplier = get_delay_multiplier()

	for c in text:
		var event = InputEventKey.new()
		event.unicode = c.unicode_at(0)
		event.pressed = true
		_viewport.push_input(event)
		await _tree.process_frame

		event.pressed = false
		_viewport.push_input(event)

		if multiplier > 0:
			await _tree.create_timer(delay_per_char * multiplier).timeout

	_log_action("type_text", {"text": text})

# ============================================================================
# WAIT FUNCTIONS
# ============================================================================

## Waits for the specified duration
## apply_speed_multiplier: If true (default), wait is affected by playback speed
##                         If false, wait runs at real-time (for user-configured explicit waits)
func wait(seconds: float, apply_speed_multiplier: bool = true) -> void:
	var multiplier = get_delay_multiplier() if apply_speed_multiplier else 1.0
	if multiplier > 0:
		await _tree.create_timer(seconds * multiplier).timeout
	elif multiplier < 0:
		await _step_wait()
	# Instant mode with apply_speed_multiplier: no wait
	# Instant mode without apply_speed_multiplier: still waits (explicit user wait)

func _step_wait() -> void:
	print("[UIPlaybackEngine] Step mode - press SPACE to continue")
	while true:
		await _tree.process_frame
		if Input.is_action_just_pressed("ui_accept"):
			break

# ============================================================================
# HELPERS
# ============================================================================

func _emit_motion(pos: Vector2, relative: Vector2, button_held: bool = false) -> void:
	var motion = InputEventMouseMotion.new()
	motion.position = pos
	motion.global_position = pos
	motion.relative = relative
	if button_held:
		motion.button_mask = MOUSE_BUTTON_MASK_LEFT
	_viewport.push_input(motion)

# Press a modifier key (Ctrl, Shift, Alt) to update Input singleton state
func _press_modifier_key(keycode: int) -> void:
	var key_event = InputEventKey.new()
	key_event.keycode = keycode
	key_event.physical_keycode = keycode
	key_event.pressed = true
	Input.parse_input_event(key_event)

# Release a modifier key
func _release_modifier_key(keycode: int) -> void:
	var key_event = InputEventKey.new()
	key_event.keycode = keycode
	key_event.physical_keycode = keycode
	key_event.pressed = false
	Input.parse_input_event(key_event)

func _log_action(action_name: String, details: Dictionary) -> void:
	var entry = {
		"action": action_name,
		"time": Time.get_ticks_msec(),
		"details": details
	}
	action_log.append(entry)
	action_performed.emit(action_name, details)

func clear_action_log() -> void:
	action_log.clear()
