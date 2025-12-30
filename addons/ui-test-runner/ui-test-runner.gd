extends CanvasLayer
class_name UITestRunnerAutoload
## Visual UI Test Runner - Autoload singleton for automated UI testing
## Provides tweened mouse simulation with visible cursor feedback

signal test_started(test_name: String)
signal test_completed(test_name: String, passed: bool)
signal action_performed(action: String, details: Dictionary)
signal test_mode_changed(active: bool)

# Test mode flag - when true, board should disable auto-panning
var test_mode_active: bool = false:
	set(value):
		test_mode_active = value
		# Set generic automation flag on tree (decoupled from test framework)
		get_tree().set_meta("automation_mode", value)

enum Speed { INSTANT, FAST, NORMAL, SLOW, STEP }

const SPEED_MULTIPLIERS = {
	Speed.INSTANT: 0.0,
	Speed.FAST: 0.25,
	Speed.NORMAL: 1.0,
	Speed.SLOW: 2.5,
	Speed.STEP: -1.0  # Wait for keypress
}

var virtual_cursor: Node2D
var current_speed: Speed = Speed.NORMAL
var is_running: bool = false
var current_test_name: String = ""

# Action log for debugging
var action_log: Array[Dictionary] = []

# Reference to main viewport for coordinate conversion
var main_viewport: Viewport

# Recording state
var is_recording: bool = false
var is_recording_paused: bool = false
var recorded_events: Array[Dictionary] = []
var recorded_screenshots: Array[Dictionary] = []  # Multiple screenshot captures during recording
var record_start_time: int = 0
var last_mouse_pos: Vector2 = Vector2.ZERO
var mouse_down_pos: Vector2 = Vector2.ZERO
var mouse_is_down: bool = false
var mouse_is_double_click: bool = false

# Screenshot selection state
var is_selecting_region: bool = false
var is_capturing_during_recording: bool = false  # True when capturing mid-recording
var was_paused_before_capture: bool = false  # To restore pause state after capture
var selection_start: Vector2 = Vector2.ZERO
var selection_rect: Rect2 = Rect2()
var selection_overlay: Control = null

# Test files
const TESTS_DIR = "res://tests/ui-tests"
const CATEGORIES_FILE = "res://tests/ui-tests/categories.json"
var test_selector_panel: Control = null
var is_selector_open: bool = false

# Category management
var test_categories: Dictionary = {}  # {test_name: category_name}
var collapsed_categories: Dictionary = {}  # {category_name: bool}
var category_test_order: Dictionary = {}  # {category_name: [test_names in order]}
var dragging_test_name: String = ""
var drag_indicator: Control = null
var drop_line: Control = null
var drop_target_category: String = ""
var drop_target_index: int = -1

# Batch test execution
var batch_results: Array[Dictionary] = []  # [{name, passed, baseline_path, actual_path}]
var is_batch_running: bool = false

# Re-recording state (for Update Baseline)
var rerecording_test_name: String = ""  # When non-empty, save will overwrite this test

# Recording indicator and HUD buttons
var recording_indicator: Control = null
var recording_hud_container: HBoxContainer = null
var btn_capture: Button = null
var btn_pause: Button = null
var btn_stop: Button = null

# Comparison viewer
var comparison_viewer: Control = null
var last_baseline_path: String = ""
var last_actual_path: String = ""

# Event editor (post-recording)
var event_editor: Control = null
var pending_baseline_path: String = ""
var pending_baseline_region: Dictionary = {}  # For legacy tests with baseline_region
var pending_test_name: String = ""

# Default delays by event type (ms)
const DEFAULT_DELAYS = {
	"click": 100,
	"double_click": 100,
	"drag": 100,
	"key": 50,
	"wait": 1000
}

func _ready():
	main_viewport = get_viewport()
	layer = 100  # Above everything
	process_mode = Node.PROCESS_MODE_ALWAYS  # Work even when paused
	_setup_virtual_cursor()
	print("[UITestRunner] Ready - F9: demo | F10: speed | F11: record | F12: Test Manager")

func _setup_virtual_cursor():
	var cursor_scene = load("res://addons/ui-test-runner/virtual-cursor.tscn")
	if cursor_scene:
		virtual_cursor = cursor_scene.instantiate()
		add_child(virtual_cursor)
	else:
		push_warning("[UITestRunner] Could not load virtual cursor scene")
		_create_fallback_cursor()

func _create_fallback_cursor():
	virtual_cursor = Node2D.new()
	virtual_cursor.name = "VirtualCursor"
	virtual_cursor.z_index = 4096

	var sprite = Sprite2D.new()
	sprite.name = "Sprite2D"
	# Create a simple circle texture
	var img = Image.create(32, 32, false, Image.FORMAT_RGBA8)
	img.fill(Color(1, 0.4, 0.2, 0.9))
	sprite.texture = ImageTexture.create_from_image(img)
	virtual_cursor.add_child(sprite)

	add_child(virtual_cursor)

func _input(event):
	# Capture ALL input events while recording (before controls handle them)
	if is_recording:
		if event is InputEventMouseButton:
			print("[REC-INPUT] MouseButton pressed=%s at %s" % [event.pressed, event.global_position])
		elif event is InputEventKey and event.pressed:
			print("[REC-INPUT] Key keycode=%d (%s) ctrl=%s shift=%s" % [event.keycode, OS.get_keycode_string(event.keycode), event.ctrl_pressed, event.shift_pressed])
		_capture_event(event)

# Track keys for fallback detection (keys consumed before _input)
var _last_key_state: Dictionary = {}

func _process(_delta):
	# Update drag indicator and drop line position
	if drag_indicator:
		_update_drag_indicator_position()
		_update_drop_line_position()

	# Fallback mouse UP detection for recording - catches events missed by _input()
	# This happens when a Control captures mouse during drag and routes UP to _gui_input()
	if is_recording and mouse_is_down:
		if not Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
			# Mouse was released but we didn't get the event in _input()
			print("[REC-PROCESS] Detected missed mouse UP at %s" % get_viewport().get_mouse_position())
			var fake_event = InputEventMouseButton.new()
			fake_event.button_index = MOUSE_BUTTON_LEFT
			fake_event.pressed = false
			fake_event.global_position = get_viewport().get_mouse_position()
			fake_event.position = fake_event.global_position
			_capture_event(fake_event)

	# Fallback key detection for recording - catches keys consumed by other handlers
	if is_recording:
		_check_fallback_keys()

# Common keys to monitor for fallback detection (keys often consumed by apps)
const FALLBACK_KEYS = [KEY_Z, KEY_Y, KEY_X, KEY_C, KEY_V, KEY_A, KEY_S, KEY_DELETE, KEY_BACKSPACE, KEY_ENTER, KEY_ESCAPE]

func _check_fallback_keys():
	var ctrl = Input.is_key_pressed(KEY_CTRL)
	var shift = Input.is_key_pressed(KEY_SHIFT)

	for keycode in FALLBACK_KEYS:
		var is_pressed = Input.is_key_pressed(keycode)
		var was_pressed = _last_key_state.get(keycode, false)

		# Detect new key press
		if is_pressed and not was_pressed:
			# Check if we already recorded this key via _input
			var already_recorded = _was_key_recently_recorded(keycode, ctrl, shift)
			if not already_recorded:
				print("[REC-FALLBACK] Detected key: %s ctrl=%s shift=%s" % [OS.get_keycode_string(keycode), ctrl, shift])
				var time_offset = (Time.get_ticks_msec() - record_start_time) if record_start_time > 0 else 0
				recorded_events.append({
					"type": "key",
					"keycode": keycode,
					"shift": shift,
					"ctrl": ctrl,
					"time": time_offset
				})
				var mods = ""
				if ctrl:
					mods += "Ctrl+"
				if shift:
					mods += "Shift+"
				print("[REC] Key: ", mods, OS.get_keycode_string(keycode))

		_last_key_state[keycode] = is_pressed

var _recent_recorded_keys: Array = []  # [{keycode, ctrl, shift, time}]

func _was_key_recently_recorded(keycode: int, ctrl: bool, shift: bool) -> bool:
	var now = Time.get_ticks_msec()
	# Clean old entries (older than 100ms)
	_recent_recorded_keys = _recent_recorded_keys.filter(func(k): return now - k.time < 100)
	# Check if this key combo was recorded recently
	for k in _recent_recorded_keys:
		if k.keycode == keycode and k.ctrl == ctrl and k.shift == shift:
			return true
	return false

func _mark_key_recorded(keycode: int, ctrl: bool, shift: bool):
	_recent_recorded_keys.append({"keycode": keycode, "ctrl": ctrl, "shift": shift, "time": Time.get_ticks_msec()})

func _unhandled_input(event):
	# Handle screenshot region selection
	if is_selecting_region:
		_handle_selection_input(event)
		return

	if event is InputEventKey and event.pressed:
		# ESC to close comparison viewer
		if event.keycode == KEY_ESCAPE and comparison_viewer and comparison_viewer.visible:
			_close_comparison_viewer()
			return

		# ESC to close rename dialog
		if event.keycode == KEY_ESCAPE and rename_dialog and rename_dialog.visible:
			_close_rename_dialog()
			return

		# ESC to close test selector
		if event.keycode == KEY_ESCAPE and is_selector_open:
			_close_test_selector()
			return

		if event.keycode == KEY_F9:
			_start_demo_test()
		elif event.keycode == KEY_F10:
			if is_recording:
				# Capture screenshot during recording
				_capture_screenshot_during_recording()
			else:
				cycle_speed()
		elif event.keycode == KEY_F11:
			_toggle_recording()
		elif event.keycode == KEY_F12:
			_toggle_test_selector()

func _start_demo_test():
	print("[UITestRunner] F9 pressed, is_running=", is_running)
	if not is_running:
		# Use call_deferred to run on next frame, avoiding input handler conflicts
		call_deferred("_run_demo_deferred")
	else:
		print("[UITestRunner] Test already running, ignoring")

func _run_demo_deferred():
	run_demo_test()

# ============================================================================
# SPEED CONTROL
# ============================================================================

func set_speed(speed: Speed):
	current_speed = speed
	var speed_name = Speed.keys()[speed]
	print("[UITestRunner] Speed set to: ", speed_name)

func cycle_speed():
	var next = (current_speed + 1) % Speed.size()
	set_speed(next)

func get_delay_multiplier() -> float:
	return SPEED_MULTIPLIERS[current_speed]

# ============================================================================
# COORDINATE CONVERSION
# ============================================================================

## Convert world position to screen position (for nodes under Camera2D)
func world_to_screen(world_pos: Vector2) -> Vector2:
	return main_viewport.get_canvas_transform() * world_pos

## Convert screen position to world position
func screen_to_world(screen_pos: Vector2) -> Vector2:
	return main_viewport.get_canvas_transform().affine_inverse() * screen_pos

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
		virtual_cursor.global_position = pos
	elif multiplier < 0.0:
		# Step mode - wait for input
		await _step_wait()
		virtual_cursor.global_position = pos
	else:
		# Tweened movement
		virtual_cursor.show_cursor()
		var tween = create_tween()
		tween.tween_property(virtual_cursor, "global_position", pos, duration * multiplier)
		await tween.finished

	_log_action("move_to", {"position": pos})

## Click at current position
func click() -> void:
	var pos = virtual_cursor.global_position
	virtual_cursor.show_click()

	# Warp actual mouse to position (required for GUI routing)
	Input.warp_mouse(pos)
	await get_tree().process_frame

	# Send motion event first to establish position
	_emit_motion(pos, Vector2.ZERO)
	await get_tree().process_frame

	# Mouse down
	var down = InputEventMouseButton.new()
	down.button_index = MOUSE_BUTTON_LEFT
	down.pressed = true
	down.position = pos
	down.global_position = pos
	Input.parse_input_event(down)
	get_viewport().push_input(down)

	await get_tree().process_frame

	# Mouse up
	var up = InputEventMouseButton.new()
	up.button_index = MOUSE_BUTTON_LEFT
	up.pressed = false
	up.position = pos
	up.global_position = pos
	Input.parse_input_event(up)
	get_viewport().push_input(up)

	await get_tree().process_frame
	_log_action("click", {"position": pos})

## Click at specific position (move + click)
func click_at(pos: Vector2) -> void:
	await move_to(pos)
	await click()

## Drag from current position to target
## hold_at_end: seconds to keep mouse pressed at target (for hover navigation)
func drag_to(to: Vector2, duration: float = 0.5, hold_at_end: float = 0.0) -> void:
	var from = virtual_cursor.global_position
	var multiplier = get_delay_multiplier()

	virtual_cursor.show_cursor()

	# Warp mouse and establish position
	Input.warp_mouse(from)
	_emit_motion(from, Vector2.ZERO)
	await get_tree().process_frame

	# Mouse down at start - use parse_input_event to update Input singleton state
	var down = InputEventMouseButton.new()
	down.button_index = MOUSE_BUTTON_LEFT
	down.pressed = true
	down.position = from
	down.global_position = from
	Input.parse_input_event(down)  # Updates Input.is_mouse_button_pressed()
	get_viewport().push_input(down)  # Also push to viewport for GUI routing
	await get_tree().process_frame

	if multiplier == 0.0:
		# Instant drag
		virtual_cursor.global_position = to
		Input.warp_mouse(to)
		_emit_motion(to, to - from, true)  # button_held=true
	elif multiplier < 0.0:
		# Step mode
		await _step_wait()
		virtual_cursor.global_position = to
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
			virtual_cursor.global_position = pos
			virtual_cursor.move_to(pos)
			Input.warp_mouse(pos)
			_emit_motion(pos, pos - last_pos, true)  # button_held=true
			last_pos = pos
			await get_tree().process_frame

	# Hold at end position with mouse still pressed (for hover navigation triggers)
	if hold_at_end > 0.0:
		var hold_time = hold_at_end * multiplier if multiplier > 0 else hold_at_end
		var elapsed = 0.0
		while elapsed < hold_time:
			# Keep sending motion events to maintain drag state
			_emit_motion(to, Vector2.ZERO, true)
			await get_tree().process_frame
			elapsed += get_process_delta_time()

	# Mouse up at end
	Input.warp_mouse(to)
	var up = InputEventMouseButton.new()
	up.button_index = MOUSE_BUTTON_LEFT
	up.pressed = false
	up.position = to
	up.global_position = to
	Input.parse_input_event(up)  # Updates Input.is_mouse_button_pressed()
	get_viewport().push_input(up)  # Also push to viewport for GUI routing

	await get_tree().process_frame
	_log_action("drag_to", {"from": from, "to": to})

## Drag from one position to another (move + drag)
## hold_at_end: seconds to keep mouse pressed at target (for hover navigation)
func drag(from: Vector2, to: Vector2, duration: float = 0.5, hold_at_end: float = 0.0) -> void:
	await move_to(from, 0.2)
	await drag_to(to, duration, hold_at_end)

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
	var pos = virtual_cursor.global_position

	var down = InputEventMouseButton.new()
	down.button_index = MOUSE_BUTTON_RIGHT
	down.pressed = true
	down.position = pos
	down.global_position = pos
	get_viewport().push_input(down)

	await get_tree().process_frame

	var up = InputEventMouseButton.new()
	up.button_index = MOUSE_BUTTON_RIGHT
	up.pressed = false
	up.position = pos
	up.global_position = pos
	get_viewport().push_input(up)

	await get_tree().process_frame
	_log_action("right_click", {"position": pos})

## Double click at current position
func double_click() -> void:
	var pos = virtual_cursor.global_position

	for i in range(2):
		var down = InputEventMouseButton.new()
		down.button_index = MOUSE_BUTTON_LEFT
		down.pressed = true
		down.double_click = (i == 1)
		down.position = pos
		down.global_position = pos
		get_viewport().push_input(down)
		await get_tree().process_frame

		var up = InputEventMouseButton.new()
		up.button_index = MOUSE_BUTTON_LEFT
		up.pressed = false
		up.position = pos
		up.global_position = pos
		get_viewport().push_input(up)
		await get_tree().process_frame

	_log_action("double_click", {"position": pos})

# ============================================================================
# KEYBOARD SIMULATION
# ============================================================================

func press_key(keycode: int, shift: bool = false, ctrl: bool = false) -> void:
	var event = InputEventKey.new()
	event.keycode = keycode
	event.pressed = true
	event.shift_pressed = shift
	event.ctrl_pressed = ctrl

	# Set unicode for printable characters so TextEdit receives text input
	var unicode_char = _keycode_to_unicode(keycode, shift)
	if unicode_char > 0:
		event.unicode = unicode_char

	get_viewport().push_input(event)
	await get_tree().process_frame

	event.pressed = false
	get_viewport().push_input(event)
	await get_tree().process_frame

	_log_action("press_key", {"keycode": keycode, "shift": shift, "ctrl": ctrl})

func _keycode_to_unicode(keycode: int, shift: bool) -> int:
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
		get_viewport().push_input(event)
		await get_tree().process_frame

		event.pressed = false
		get_viewport().push_input(event)

		if multiplier > 0:
			await get_tree().create_timer(delay_per_char * multiplier).timeout

	_log_action("type_text", {"text": text})

# ============================================================================
# TEST STRUCTURE
# ============================================================================

func begin_test(test_name: String) -> void:
	current_test_name = test_name
	is_running = true
	test_mode_active = true
	test_mode_changed.emit(true)
	action_log.clear()
	virtual_cursor.visible = true
	virtual_cursor.show_cursor()
	test_started.emit(test_name)
	print("[UITestRunner] === BEGIN: ", test_name, " ===")
	# Ensure cursor is visible before proceeding
	await get_tree().process_frame

func end_test(passed: bool = true) -> void:
	var result = "PASSED" if passed else "FAILED"
	print("[UITestRunner] === END: ", current_test_name, " - ", result, " ===")
	virtual_cursor.hide_cursor()
	is_running = false
	test_mode_active = false
	test_mode_changed.emit(false)
	test_completed.emit(current_test_name, passed)
	current_test_name = ""

func wait(seconds: float) -> void:
	var multiplier = get_delay_multiplier()
	if multiplier > 0:
		await get_tree().create_timer(seconds * multiplier).timeout
	elif multiplier < 0:
		await _step_wait()
	# Instant mode: no wait

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
	get_viewport().push_input(motion)

func _step_wait() -> void:
	print("[UITestRunner] Step mode - press SPACE to continue")
	while true:
		await get_tree().process_frame
		if Input.is_action_just_pressed("ui_accept"):
			break

func _log_action(action_name: String, details: Dictionary) -> void:
	var entry = {
		"action": action_name,
		"time": Time.get_ticks_msec(),
		"details": details
	}
	action_log.append(entry)
	action_performed.emit(action_name, details)

# ============================================================================
# DEMO TEST - Pure coordinate-based demonstration
# ============================================================================

func run_demo_test() -> void:
	if is_running:
		print("[UITestRunner] Test already running")
		return

	await begin_test("Drag Demo")

	var viewport_size = get_viewport().get_visible_rect().size
	var center = viewport_size / 2
	print("[UITestRunner] Viewport: ", viewport_size, " Center: ", center)

	# Pure drag test - no click first, just grab and drag
	# This simulates: move to position, mouse down, drag, mouse up
	print("[UITestRunner] Dragging from center 200px right, 100px down...")
	await drag(center, center + Vector2(200, 100), 1.0)

	await wait(0.5)

	# Drag it back
	print("[UITestRunner] Dragging back to original position...")
	await drag(center + Vector2(200, 100), center, 1.0)

	await wait(0.3)
	end_test(true)
	print("[UITestRunner] Demo complete")

# ============================================================================
# RECORDING
# ============================================================================

func _toggle_recording():
	if is_recording:
		_stop_recording()
	else:
		_start_recording()

func _start_recording():
	is_recording = true
	is_recording_paused = false
	test_mode_active = true
	get_tree().set_meta("automation_is_recording", true)
	test_mode_changed.emit(true)
	recorded_events.clear()
	recorded_screenshots.clear()
	record_start_time = Time.get_ticks_msec()
	mouse_is_down = false
	_show_recording_indicator()
	if rerecording_test_name != "":
		print("[UITestRunner] === RE-RECORDING '%s' === (F11 to stop)" % rerecording_test_name)
	else:
		print("[UITestRunner] === RECORDING STARTED === (F11 to stop)")

func _stop_recording():
	is_recording = false
	is_recording_paused = false
	test_mode_active = false
	get_tree().set_meta("automation_is_recording", false)
	test_mode_changed.emit(false)
	_hide_recording_indicator()
	print("[UITestRunner] === RECORDING STOPPED === (%d events, %d screenshots)" % [recorded_events.size(), recorded_screenshots.size()])

	# If screenshots were captured during recording, skip the final region selection
	if recorded_screenshots.is_empty():
		# Enter selection mode for screenshot region (backwards compatibility)
		_start_region_selection()
	else:
		# Go directly to event editor with captured screenshots
		_show_event_editor()

# ============================================================================
# RECORDING INDICATOR
# ============================================================================

func _show_recording_indicator():
	if not recording_indicator:
		_create_recording_indicator()
	recording_indicator.visible = true

func _hide_recording_indicator():
	if recording_indicator:
		recording_indicator.visible = false

func _create_recording_indicator():
	recording_indicator = Control.new()
	recording_indicator.name = "RecordingIndicator"
	recording_indicator.mouse_filter = Control.MOUSE_FILTER_IGNORE  # Don't interfere with clicks
	recording_indicator.set_anchors_preset(Control.PRESET_FULL_RECT)
	recording_indicator.process_mode = Node.PROCESS_MODE_ALWAYS
	add_child(recording_indicator)
	recording_indicator.draw.connect(_draw_recording_indicator)

	# Create HUD container for buttons
	recording_hud_container = HBoxContainer.new()
	recording_hud_container.name = "RecordingHUD"
	recording_hud_container.mouse_filter = Control.MOUSE_FILTER_STOP
	recording_hud_container.process_mode = Node.PROCESS_MODE_ALWAYS
	recording_hud_container.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	recording_hud_container.anchor_left = 1.0
	recording_hud_container.anchor_top = 1.0
	recording_hud_container.anchor_right = 1.0
	recording_hud_container.anchor_bottom = 1.0
	recording_hud_container.offset_left = -180
	recording_hud_container.offset_top = -56
	recording_hud_container.offset_right = -70  # Leave room for REC indicator
	recording_hud_container.offset_bottom = -12
	recording_hud_container.add_theme_constant_override("separation", 4)
	recording_indicator.add_child(recording_hud_container)

	# Load icons
	var icon_camera = load("res://addons/ui-test-runner/icons/camera.svg")
	var icon_pause = load("res://addons/ui-test-runner/icons/pause.svg")
	var icon_play = load("res://addons/ui-test-runner/icons/play.svg")
	var icon_stop = load("res://addons/ui-test-runner/icons/stop.svg")

	# Create capture button
	btn_capture = Button.new()
	btn_capture.name = "CaptureBtn"
	btn_capture.icon = icon_camera
	btn_capture.tooltip_text = "Capture Screenshot (F10)"
	btn_capture.custom_minimum_size = Vector2(36, 36)
	btn_capture.pressed.connect(_on_hud_capture_pressed)
	recording_hud_container.add_child(btn_capture)

	# Create pause/resume button
	btn_pause = Button.new()
	btn_pause.name = "PauseBtn"
	btn_pause.icon = icon_pause
	btn_pause.tooltip_text = "Pause Recording"
	btn_pause.custom_minimum_size = Vector2(36, 36)
	btn_pause.pressed.connect(_on_hud_pause_pressed)
	recording_hud_container.add_child(btn_pause)

	# Create stop button
	btn_stop = Button.new()
	btn_stop.name = "StopBtn"
	btn_stop.icon = icon_stop
	btn_stop.tooltip_text = "Stop Recording (F11)"
	btn_stop.custom_minimum_size = Vector2(36, 36)
	btn_stop.pressed.connect(_on_hud_stop_pressed)
	recording_hud_container.add_child(btn_stop)

func _draw_recording_indicator():
	var viewport_size = get_viewport().get_visible_rect().size
	var indicator_size = 48.0
	var margin = 20.0
	var center = Vector2(
		viewport_size.x - margin - indicator_size / 2,
		viewport_size.y - margin - indicator_size / 2
	)

	# Color based on paused state
	var color: Color
	var inner_color: Color
	var label: String

	if is_recording_paused:
		# Yellow/orange for paused
		color = Color(1.0, 0.7, 0.2, 0.6)
		inner_color = Color(1.0, 0.8, 0.3, 0.5)
		label = "PAUSED"
	else:
		# Red for recording with pulsing effect
		color = Color(1.0, 0.2, 0.2, 0.6)
		var pulse = (sin(Time.get_ticks_msec() / 300.0) + 1.0) / 2.0  # 0 to 1
		inner_color = Color(1.0, 0.3, 0.3, 0.3 + pulse * 0.4)
		label = "REC"

	recording_indicator.draw_circle(center, indicator_size / 2, color)
	recording_indicator.draw_circle(center, indicator_size / 3, inner_color)

	# Label text
	var font = ThemeDB.fallback_font
	var font_size = 10 if is_recording_paused else 12
	var text_offset = Vector2(-18, 4) if is_recording_paused else Vector2(-12, 4)
	var text_pos = center + text_offset
	recording_indicator.draw_string(font, text_pos, label, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, Color.WHITE)

	# Request redraw for animation
	if is_recording:
		recording_indicator.queue_redraw()

func _on_hud_capture_pressed():
	_capture_screenshot_during_recording()

func _on_hud_pause_pressed():
	_toggle_recording_pause()

func _on_hud_stop_pressed():
	_stop_recording()

func _toggle_recording_pause():
	if not is_recording:
		return

	is_recording_paused = not is_recording_paused

	# Update pause button icon
	if btn_pause:
		if is_recording_paused:
			btn_pause.icon = load("res://addons/ui-test-runner/icons/play.svg")
			btn_pause.tooltip_text = "Resume Recording"
			print("[UITestRunner] === RECORDING PAUSED ===")
		else:
			btn_pause.icon = load("res://addons/ui-test-runner/icons/pause.svg")
			btn_pause.tooltip_text = "Pause Recording"
			print("[UITestRunner] === RECORDING RESUMED ===")

	# Force redraw to update indicator color
	if recording_indicator:
		recording_indicator.queue_redraw()

func _capture_screenshot_during_recording():
	if not is_recording:
		return

	# Temporarily pause to allow region selection without capturing events
	var was_paused = is_recording_paused
	is_recording_paused = true

	# Hide recording indicator temporarily for clean screenshot
	if recording_indicator:
		recording_indicator.visible = false

	# Start region selection for this screenshot
	_start_screenshot_capture_region(was_paused)

func _start_screenshot_capture_region(was_paused: bool):
	is_selecting_region = true
	is_capturing_during_recording = true
	was_paused_before_capture = was_paused
	print("[UITestRunner] Draw a rectangle to capture screenshot (ESC to cancel)")

	# Pause the game for clean capture
	get_tree().paused = true

	# Reuse selection overlay
	if not selection_overlay:
		selection_overlay = Control.new()
		selection_overlay.name = "SelectionOverlay"
		selection_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
		selection_overlay.mouse_filter = Control.MOUSE_FILTER_STOP
		selection_overlay.process_mode = Node.PROCESS_MODE_ALWAYS
		add_child(selection_overlay)
		selection_overlay.draw.connect(_draw_selection_overlay)
		selection_overlay.gui_input.connect(_on_overlay_gui_input)

	selection_overlay.visible = true
	selection_rect = Rect2()
	selection_overlay.queue_redraw()

func _finish_screenshot_capture_during_recording():
	is_selecting_region = false
	is_capturing_during_recording = false
	selection_overlay.visible = false
	get_tree().paused = false

	if selection_rect.size.x < 10 or selection_rect.size.y < 10:
		print("[UITestRunner] Selection too small, cancelled")
		_restore_recording_after_capture()
		return

	# Capture the screenshot asynchronously
	_capture_and_store_screenshot()

func _capture_and_store_screenshot():
	# Wait for overlay to disappear
	await get_tree().process_frame
	await get_tree().process_frame

	var image = get_viewport().get_texture().get_image()
	var cropped = image.get_region(selection_rect)

	# Generate unique filename for this screenshot
	var timestamp = Time.get_datetime_string_from_system().replace(":", "-").replace(" ", "_")
	var screenshot_index = recorded_screenshots.size()
	var filename = "screenshot_%s_%d.png" % [timestamp, screenshot_index]
	var dir_path = "res://tests/baselines"
	var full_path = "%s/%s" % [dir_path, filename]

	# Ensure directory exists
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir_path))

	# Save image
	cropped.save_png(ProjectSettings.globalize_path(full_path))
	print("[UITestRunner] Screenshot %d saved: %s" % [screenshot_index, full_path])

	# Store screenshot info with the event index it relates to
	var time_offset = Time.get_ticks_msec() - record_start_time
	recorded_screenshots.append({
		"path": full_path,
		"region": {
			"x": selection_rect.position.x,
			"y": selection_rect.position.y,
			"w": selection_rect.size.x,
			"h": selection_rect.size.y
		},
		"after_event_index": recorded_events.size() - 1,  # Index of last event before screenshot
		"time": time_offset
	})

	_restore_recording_after_capture()

func _restore_recording_after_capture():
	# Restore recording indicator
	if recording_indicator:
		recording_indicator.visible = true

	# Restore pause state
	is_recording_paused = was_paused_before_capture

	# Update pause button icon
	if btn_pause:
		if is_recording_paused:
			btn_pause.icon = load("res://addons/ui-test-runner/icons/play.svg")
		else:
			btn_pause.icon = load("res://addons/ui-test-runner/icons/pause.svg")

	print("[UITestRunner] === Recording resumed ===")

func _is_click_on_recording_hud(pos: Vector2) -> bool:
	# Check if click is on the recording HUD buttons
	if not recording_hud_container or not recording_hud_container.visible:
		return false
	var hud_rect = recording_hud_container.get_global_rect()
	return hud_rect.has_point(pos)

# ============================================================================
# TEST FILE MANAGEMENT
# ============================================================================

func _save_test(test_name: String, baseline_path: Variant) -> String:
	# Ensure directory exists
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(TESTS_DIR))

	print("[UITestRunner] Saving test with %d recorded events" % recorded_events.size())

	# Convert events to JSON-serializable format (Vector2 -> dict)
	var serializable_events = []
	for event in recorded_events:
		var event_type = event.get("type", "")
		var ser_event = {"type": event_type, "time": event.get("time", 0)}
		match event_type:
			"click", "double_click":
				var pos = event.get("pos", Vector2.ZERO)
				ser_event["pos"] = {"x": pos.x, "y": pos.y}
			"drag":
				var from_pos = event.get("from", Vector2.ZERO)
				var to_pos = event.get("to", Vector2.ZERO)
				ser_event["from"] = {"x": from_pos.x, "y": from_pos.y}
				ser_event["to"] = {"x": to_pos.x, "y": to_pos.y}
			"key":
				ser_event["keycode"] = event.get("keycode", 0)
				ser_event["shift"] = event.get("shift", false)
				ser_event["ctrl"] = event.get("ctrl", false)
			"wait":
				ser_event["duration"] = event.get("duration", 1000)
		# Add wait_after and note for all events
		ser_event["wait_after"] = event.get("wait_after", 100)
		var note = event.get("note", "")
		if not note.is_empty():
			ser_event["note"] = note
		serializable_events.append(ser_event)

	# Build test data with support for multiple screenshots
	var test_data = {
		"name": test_name,
		"created": Time.get_datetime_string_from_system(),
		"events": serializable_events,
		# Legacy single baseline (for backwards compatibility)
		"baseline_path": baseline_path if baseline_path else "",
		"baseline_region": {
			"x": selection_rect.position.x,
			"y": selection_rect.position.y,
			"w": selection_rect.size.x,
			"h": selection_rect.size.y
		} if baseline_path else null,
		# Multiple screenshots captured during recording
		"screenshots": recorded_screenshots.duplicate()
	}

	var filename = test_name.to_snake_case().replace(" ", "_") + ".json"
	var filepath = TESTS_DIR + "/" + filename

	var file = FileAccess.open(filepath, FileAccess.WRITE)
	if file:
		file.store_string(JSON.stringify(test_data, "\t"))
		file.close()
		print("[UITestRunner] Test saved: ", filepath)
		return filepath
	else:
		push_error("[UITestRunner] Failed to save test: " + filepath)
		return ""

func _load_test(filepath: String) -> Dictionary:
	var file = FileAccess.open(filepath, FileAccess.READ)
	if not file:
		push_error("[UITestRunner] Failed to load test: " + filepath)
		return {}

	var json_text = file.get_as_text()
	file.close()

	var json = JSON.new()
	var error = json.parse(json_text)
	if error != OK:
		push_error("[UITestRunner] Failed to parse test JSON: " + filepath)
		return {}

	return json.data

func _get_saved_tests() -> Array:
	var tests = []
	var dir = DirAccess.open(TESTS_DIR)
	if dir:
		dir.list_dir_begin()
		var filename = dir.get_next()
		while filename != "":
			if filename.ends_with(".json") and filename != "categories.json":
				tests.append(filename.replace(".json", ""))
			filename = dir.get_next()
		dir.list_dir_end()
	return tests

func _load_categories():
	test_categories.clear()
	collapsed_categories.clear()
	category_test_order.clear()

	var file = FileAccess.open(CATEGORIES_FILE, FileAccess.READ)
	if not file:
		return  # No categories file yet, that's fine

	var json_text = file.get_as_text()
	file.close()

	var json = JSON.new()
	if json.parse(json_text) == OK:
		var data = json.data
		if data.has("test_categories"):
			test_categories = data.test_categories
		if data.has("collapsed"):
			collapsed_categories = data.collapsed
		if data.has("test_order"):
			category_test_order = data.test_order

	# Clean up stale entries (tests that no longer exist)
	_cleanup_stale_category_entries()

func _cleanup_stale_category_entries():
	var saved_tests = _get_saved_tests()
	var stale_tests: Array = []

	# Find stale test_categories entries
	for test_name in test_categories.keys():
		if test_name not in saved_tests:
			stale_tests.append(test_name)

	# Remove stale entries
	for test_name in stale_tests:
		print("[UITestRunner] Removing stale category entry: ", test_name)
		test_categories.erase(test_name)

	# Clean up category_test_order
	for category_name in category_test_order.keys():
		var order: Array = category_test_order[category_name]
		var cleaned: Array = []
		for test_name in order:
			if test_name in saved_tests:
				cleaned.append(test_name)
		category_test_order[category_name] = cleaned

	# Save if we cleaned anything
	if not stale_tests.is_empty():
		_save_categories()

func _save_categories():
	var data = {
		"test_categories": test_categories,
		"collapsed": collapsed_categories,
		"test_order": category_test_order
	}

	var file = FileAccess.open(CATEGORIES_FILE, FileAccess.WRITE)
	if file:
		file.store_string(JSON.stringify(data, "\t"))
		file.close()

func _get_all_categories() -> Array:
	var categories = []
	for cat in test_categories.values():
		if cat and cat not in categories:
			categories.append(cat)
	categories.sort()
	return categories

func _set_test_category(test_name: String, category: String, insert_index: int = -1):
	var old_category = test_categories.get(test_name, "")

	# Remove from old category order
	if old_category and category_test_order.has(old_category):
		category_test_order[old_category].erase(test_name)

	if category.is_empty():
		test_categories.erase(test_name)
	else:
		test_categories[test_name] = category
		# Add to new category order
		if not category_test_order.has(category):
			category_test_order[category] = []
		if test_name not in category_test_order[category]:
			if insert_index >= 0 and insert_index <= category_test_order[category].size():
				category_test_order[category].insert(insert_index, test_name)
			else:
				category_test_order[category].append(test_name)

	_save_categories()

func _get_ordered_tests(category_name: String, tests: Array) -> Array:
	if not category_test_order.has(category_name):
		return tests

	var order = category_test_order[category_name]
	var ordered: Array = []

	# Add tests in saved order (if they still exist)
	for test_name in order:
		if test_name in tests:
			ordered.append(test_name)

	# Add any remaining tests not in saved order
	for test_name in tests:
		if test_name not in ordered:
			ordered.append(test_name)

	return ordered

func _run_test_from_file(test_name: String):
	var filepath = TESTS_DIR + "/" + test_name + ".json"
	var test_data = _load_test(filepath)
	if test_data.is_empty():
		return

	# Load events into recorded_events for replay, converting JSON dicts to Vector2
	recorded_events.clear()
	for event in test_data.get("events", []):
		var event_type = event.get("type", "")
		var converted_event = {"type": event_type, "time": event.get("time", 0)}

		match event_type:
			"click", "double_click":
				var pos = event.get("pos", {})
				converted_event["pos"] = Vector2(pos.get("x", 0), pos.get("y", 0))
			"drag":
				var from_pos = event.get("from", {})
				var to_pos = event.get("to", {})
				converted_event["from"] = Vector2(from_pos.get("x", 0), from_pos.get("y", 0))
				converted_event["to"] = Vector2(to_pos.get("x", 0), to_pos.get("y", 0))
			"key":
				converted_event["keycode"] = event.get("keycode", 0)
				converted_event["shift"] = event.get("shift", false)
				converted_event["ctrl"] = event.get("ctrl", false)
			"wait":
				converted_event["duration"] = event.get("duration", 1000)

		# Load wait_after (default based on type for backwards compatibility)
		var default_wait = DEFAULT_DELAYS.get(event_type, 100)
		converted_event["wait_after"] = event.get("wait_after", default_wait)

		recorded_events.append(converted_event)

	print("[UITestRunner] Loaded %d events from file" % recorded_events.size())
	# Use call_deferred to start on next frame, then await properly
	# Pass both test_data and filename-based test_name for correct result tracking
	_start_replay_deferred.call_deferred(test_data, test_name)

func _start_replay_deferred(test_data: Dictionary, file_test_name: String = ""):
	_run_replay_with_validation(test_data, file_test_name)

func _run_replay():
	await _run_replay_with_validation({}, "")

func _run_replay_with_validation(test_data: Dictionary, file_test_name: String = ""):
	# Use filename-based name for results, fall back to JSON name for display
	var display_name = test_data.get("name", "Replay")
	var result_name = file_test_name if not file_test_name.is_empty() else display_name
	await begin_test(display_name)

	# Build a map of screenshots by their after_event_index for inline validation
	var screenshots_by_index: Dictionary = {}
	var screenshots = test_data.get("screenshots", [])
	for screenshot in screenshots:
		var after_idx = screenshot.get("after_event_index", -1)
		if not screenshots_by_index.has(after_idx):
			screenshots_by_index[after_idx] = []
		screenshots_by_index[after_idx].append(screenshot)

	var passed = true
	var baseline_path = ""
	var actual_path = ""
	var failed_step_index: int = -1

	print("[UITestRunner] Replaying %d events..." % recorded_events.size())
	for i in range(recorded_events.size()):
		var event = recorded_events[i]
		var event_type = event.get("type", "")
		var wait_after_ms = event.get("wait_after", 100)

		match event_type:
			"click":
				var pos = event.get("pos", Vector2.ZERO)
				print("[REPLAY] Step %d: Click at %s" % [i + 1, pos])
				await click_at(pos)
			"double_click":
				var pos = event.get("pos", Vector2.ZERO)
				print("[REPLAY] Step %d: Double-click at %s" % [i + 1, pos])
				await move_to(pos)
				await double_click()
			"drag":
				var from_pos = event.get("from", Vector2.ZERO)
				var to_pos = event.get("to", Vector2.ZERO)
				var hold_time = wait_after_ms / 1000.0
				print("[REPLAY] Step %d: Drag from %s to %s (hold %.1fs)" % [i + 1, from_pos, to_pos, hold_time])
				await drag(from_pos, to_pos, 0.5, hold_time)
				wait_after_ms = 0
			"key":
				var keycode = event.get("keycode", 0)
				var mods = ""
				if event.get("ctrl", false):
					mods += "Ctrl+"
				if event.get("shift", false):
					mods += "Shift+"
				print("[REPLAY] Step %d: Key %s%s" % [i + 1, mods, OS.get_keycode_string(keycode)])
				await press_key(keycode, event.get("shift", false), event.get("ctrl", false))
			"wait":
				var duration_ms = event.get("duration", 1000)
				print("[REPLAY] Step %d: Wait %.1fs" % [i + 1, duration_ms / 1000.0])
				await wait(duration_ms / 1000.0)

		# Apply wait_after delay
		if wait_after_ms > 0:
			await wait(wait_after_ms / 1000.0)

		# Validate screenshots after this event (inline validation)
		if screenshots_by_index.has(i) and passed:
			for screenshot in screenshots_by_index[i]:
				var screenshot_path = screenshot.get("path", "")
				var screenshot_region = screenshot.get("region", {})
				if screenshot_path and not screenshot_region.is_empty():
					var region = Rect2(
						screenshot_region.get("x", 0),
						screenshot_region.get("y", 0),
						screenshot_region.get("w", 0),
						screenshot_region.get("h", 0)
					)
					print("[REPLAY] Validating screenshot after step %d..." % (i + 1))
					var screenshot_passed = await validate_screenshot(screenshot_path, region)
					if not screenshot_passed:
						passed = false
						baseline_path = screenshot_path
						actual_path = screenshot_path.replace(".png", "_actual.png")
						failed_step_index = i + 1
						print("[REPLAY] Screenshot FAILED at step %d" % failed_step_index)
						break

		# Stop replay if screenshot failed
		if not passed:
			break

	# If no inline screenshots, check legacy single baseline at end
	if screenshots.is_empty() and passed:
		await wait(0.3)
		baseline_path = test_data.get("baseline_path", "")
		var baseline_region = test_data.get("baseline_region")
		if baseline_path and baseline_region:
			var region = Rect2(
				baseline_region.get("x", 0),
				baseline_region.get("y", 0),
				baseline_region.get("w", 0),
				baseline_region.get("h", 0)
			)
			actual_path = baseline_path.replace(".png", "_actual.png")
			passed = await validate_screenshot(baseline_path, region)
			if not passed:
				failed_step_index = recorded_events.size()  # Failed at end

	end_test(passed)
	print("[UITestRunner] Replay complete - ", "PASSED" if passed else "FAILED")

	# Store result and show Test Manager with Results tab (unless in batch mode)
	if not is_batch_running:
		batch_results.clear()
		batch_results.append({
			"name": result_name,
			"passed": passed,
			"baseline_path": baseline_path,
			"actual_path": actual_path,
			"failed_step": failed_step_index
		})
		_show_results_panel()

# ============================================================================
# TEST SELECTOR PANEL
# ============================================================================

func _toggle_test_selector():
	if is_selector_open:
		_close_test_selector()
	else:
		_open_test_selector()

func _open_test_selector():
	if is_running:
		print("[UITestRunner] Cannot open selector - test running")
		return

	is_selector_open = true
	get_tree().paused = true

	if not test_selector_panel:
		_create_test_selector_panel()

	_refresh_test_list()
	test_selector_panel.visible = true

func _close_test_selector():
	is_selector_open = false
	get_tree().paused = false
	if test_selector_panel:
		test_selector_panel.visible = false

func _create_test_selector_panel():
	test_selector_panel = Panel.new()
	test_selector_panel.name = "TestManagerPanel"
	test_selector_panel.process_mode = Node.PROCESS_MODE_ALWAYS

	var viewport_size = get_viewport().get_visible_rect().size
	var panel_size = Vector2(825, 650)
	test_selector_panel.position = (viewport_size - panel_size) / 2
	test_selector_panel.size = panel_size

	# Style
	var style = StyleBoxFlat.new()
	style.bg_color = Color(0.12, 0.12, 0.15, 0.98)
	style.border_color = Color(0.3, 0.6, 1.0, 1.0)
	style.set_border_width_all(2)
	style.set_corner_radius_all(10)
	test_selector_panel.add_theme_stylebox_override("panel", style)

	var vbox = VBoxContainer.new()
	vbox.name = "VBoxContainer"
	vbox.set_anchors_preset(Control.PRESET_FULL_RECT)
	vbox.add_theme_constant_override("separation", 12)
	var margin = 20
	vbox.offset_left = margin
	vbox.offset_top = margin
	vbox.offset_right = -margin
	vbox.offset_bottom = -margin
	test_selector_panel.add_child(vbox)

	# Header row with title and close button
	var header = HBoxContainer.new()
	header.add_theme_constant_override("separation", 10)
	vbox.add_child(header)

	var title = Label.new()
	title.text = "Test Manager"
	title.add_theme_font_size_override("font_size", 24)
	title.add_theme_color_override("font_color", Color(0.9, 0.9, 0.95))
	header.add_child(title)

	var spacer = Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(spacer)

	var close_btn = Button.new()
	close_btn.text = "✕"
	close_btn.tooltip_text = "Close (ESC)"
	close_btn.custom_minimum_size = Vector2(32, 32)
	close_btn.pressed.connect(_close_test_selector)
	header.add_child(close_btn)

	# Tab container
	var tabs = TabContainer.new()
	tabs.name = "TabContainer"
	tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL
	tabs.tab_alignment = TabBar.ALIGNMENT_CENTER
	vbox.add_child(tabs)

	# ========== TESTS TAB ==========
	var tests_tab = VBoxContainer.new()
	tests_tab.name = "Tests"
	tests_tab.add_theme_constant_override("separation", 10)
	tabs.add_child(tests_tab)

	# Action buttons row
	var actions_row = HBoxContainer.new()
	actions_row.add_theme_constant_override("separation", 10)
	tests_tab.add_child(actions_row)

	# Record New Test button
	var record_btn = Button.new()
	record_btn.text = "● Record New Test"
	record_btn.tooltip_text = "Start recording a new UI test (F11)"
	record_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	record_btn.custom_minimum_size = Vector2(0, 36)
	var record_style = StyleBoxFlat.new()
	record_style.bg_color = Color(0.6, 0.2, 0.2, 0.8)
	record_style.set_corner_radius_all(6)
	record_btn.add_theme_stylebox_override("normal", record_style)
	var record_hover = StyleBoxFlat.new()
	record_hover.bg_color = Color(0.7, 0.25, 0.25, 0.9)
	record_hover.set_corner_radius_all(6)
	record_btn.add_theme_stylebox_override("hover", record_hover)
	record_btn.pressed.connect(_on_record_new_test)
	actions_row.add_child(record_btn)

	# Run All Tests button
	var run_all_btn = Button.new()
	run_all_btn.text = "▶ Run All Tests"
	run_all_btn.tooltip_text = "Run all tests in sequence"
	run_all_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	run_all_btn.custom_minimum_size = Vector2(0, 36)
	var run_style = StyleBoxFlat.new()
	run_style.bg_color = Color(0.2, 0.5, 0.3, 0.8)
	run_style.set_corner_radius_all(6)
	run_all_btn.add_theme_stylebox_override("normal", run_style)
	var run_hover = StyleBoxFlat.new()
	run_hover.bg_color = Color(0.25, 0.6, 0.35, 0.9)
	run_hover.set_corner_radius_all(6)
	run_all_btn.add_theme_stylebox_override("hover", run_hover)
	run_all_btn.pressed.connect(_run_all_tests)
	actions_row.add_child(run_all_btn)

	# Tests section header
	var tests_header = HBoxContainer.new()
	tests_header.name = "TestsHeader"
	tests_header.add_theme_constant_override("separation", 10)
	tests_tab.add_child(tests_header)

	var tests_label = Label.new()
	tests_label.name = "TestsLabel"
	tests_label.text = "Total Tests: 0"
	tests_label.add_theme_font_size_override("font_size", 14)
	tests_label.add_theme_color_override("font_color", Color(0.7, 0.7, 0.75))
	tests_header.add_child(tests_label)

	var tests_spacer = Control.new()
	tests_spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	tests_header.add_child(tests_spacer)

	# Legend
	var legend = Label.new()
	legend.text = "↻ Update  ✎ Rename  ✕ Delete"
	legend.add_theme_font_size_override("font_size", 11)
	legend.add_theme_color_override("font_color", Color(0.5, 0.5, 0.55))
	tests_header.add_child(legend)

	# Test list container
	var scroll = ScrollContainer.new()
	scroll.name = "ScrollContainer"
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	tests_tab.add_child(scroll)

	var test_list = VBoxContainer.new()
	test_list.name = "TestList"
	test_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	test_list.add_theme_constant_override("separation", 4)
	scroll.add_child(test_list)

	# ========== RESULTS TAB ==========
	var results_tab = VBoxContainer.new()
	results_tab.name = "Results"
	results_tab.add_theme_constant_override("separation", 10)
	tabs.add_child(results_tab)

	# Results header
	var results_header = HBoxContainer.new()
	results_header.add_theme_constant_override("separation", 10)
	results_tab.add_child(results_header)

	var results_title = Label.new()
	results_title.name = "ResultsTitle"
	results_title.text = "Last Run Results"
	results_title.add_theme_font_size_override("font_size", 16)
	results_title.add_theme_color_override("font_color", Color(0.7, 0.7, 0.75))
	results_header.add_child(results_title)

	var results_spacer = Control.new()
	results_spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	results_header.add_child(results_spacer)

	var clear_results_btn = Button.new()
	clear_results_btn.text = "Clear"
	clear_results_btn.tooltip_text = "Clear results history"
	clear_results_btn.pressed.connect(_clear_results_history)
	results_header.add_child(clear_results_btn)

	# Results summary
	var summary_label = Label.new()
	summary_label.name = "SummaryLabel"
	summary_label.text = "No test runs yet"
	summary_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	summary_label.add_theme_font_size_override("font_size", 14)
	summary_label.add_theme_color_override("font_color", Color(0.6, 0.6, 0.65))
	results_tab.add_child(summary_label)

	# Results list
	var results_scroll = ScrollContainer.new()
	results_scroll.name = "ResultsScroll"
	results_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	results_tab.add_child(results_scroll)

	var results_list = VBoxContainer.new()
	results_list.name = "ResultsList"
	results_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	results_list.add_theme_constant_override("separation", 4)
	results_scroll.add_child(results_list)

	# ========== CONFIG TAB ==========
	var config_tab = VBoxContainer.new()
	config_tab.name = "Config"
	config_tab.add_theme_constant_override("separation", 16)
	tabs.add_child(config_tab)

	# Speed section
	var speed_section = VBoxContainer.new()
	speed_section.add_theme_constant_override("separation", 8)
	config_tab.add_child(speed_section)

	var speed_label = Label.new()
	speed_label.text = "Playback Speed"
	speed_label.add_theme_font_size_override("font_size", 16)
	speed_label.add_theme_color_override("font_color", Color(0.8, 0.8, 0.85))
	speed_section.add_child(speed_label)

	var speed_dropdown = OptionButton.new()
	speed_dropdown.name = "SpeedDropdown"
	speed_dropdown.add_item("Instant", Speed.INSTANT)
	speed_dropdown.add_item("Fast (0.25x delay)", Speed.FAST)
	speed_dropdown.add_item("Normal (1x delay)", Speed.NORMAL)
	speed_dropdown.add_item("Slow (2.5x delay)", Speed.SLOW)
	speed_dropdown.add_item("Step (wait for keypress)", Speed.STEP)
	speed_dropdown.select(_get_speed_index(current_speed))
	speed_dropdown.item_selected.connect(_on_speed_selected)
	speed_section.add_child(speed_dropdown)

	# Comparison section
	var compare_section = VBoxContainer.new()
	compare_section.add_theme_constant_override("separation", 8)
	config_tab.add_child(compare_section)

	var compare_label = Label.new()
	compare_label.text = "Screenshot Comparison"
	compare_label.add_theme_font_size_override("font_size", 16)
	compare_label.add_theme_color_override("font_color", Color(0.8, 0.8, 0.85))
	compare_section.add_child(compare_label)

	var mode_row = HBoxContainer.new()
	mode_row.add_theme_constant_override("separation", 10)
	compare_section.add_child(mode_row)

	var mode_label = Label.new()
	mode_label.text = "Mode:"
	mode_label.add_theme_color_override("font_color", Color(0.7, 0.7, 0.75))
	mode_row.add_child(mode_label)

	var mode_dropdown = OptionButton.new()
	mode_dropdown.name = "CompareMode"
	mode_dropdown.add_item("Pixel Perfect", CompareMode.PIXEL_PERFECT)
	mode_dropdown.add_item("Tolerant", CompareMode.TOLERANT)
	mode_dropdown.select(compare_mode)
	mode_dropdown.item_selected.connect(_on_compare_mode_selected)
	mode_row.add_child(mode_dropdown)

	# Tolerance settings (only relevant for Tolerant mode)
	var tolerance_container = VBoxContainer.new()
	tolerance_container.name = "ToleranceSettings"
	tolerance_container.add_theme_constant_override("separation", 8)
	compare_section.add_child(tolerance_container)

	# Pixel tolerance row
	var pixel_row = HBoxContainer.new()
	pixel_row.add_theme_constant_override("separation", 10)
	tolerance_container.add_child(pixel_row)

	var pixel_label = Label.new()
	pixel_label.text = "Pixel Mismatch %:"
	pixel_label.add_theme_color_override("font_color", Color(0.7, 0.7, 0.75))
	pixel_label.custom_minimum_size.x = 140
	pixel_row.add_child(pixel_label)

	var pixel_slider = HSlider.new()
	pixel_slider.name = "PixelToleranceSlider"
	pixel_slider.min_value = 0.0
	pixel_slider.max_value = 10.0
	pixel_slider.step = 0.1
	pixel_slider.value = compare_tolerance * 100
	pixel_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	pixel_slider.value_changed.connect(_on_pixel_tolerance_changed)
	pixel_row.add_child(pixel_slider)

	var pixel_value = Label.new()
	pixel_value.name = "PixelToleranceValue"
	pixel_value.text = "%.1f%%" % (compare_tolerance * 100)
	pixel_value.custom_minimum_size.x = 50
	pixel_value.add_theme_color_override("font_color", Color(0.9, 0.7, 0.3))
	pixel_row.add_child(pixel_value)

	# Color threshold row
	var color_row = HBoxContainer.new()
	color_row.add_theme_constant_override("separation", 10)
	tolerance_container.add_child(color_row)

	var color_label = Label.new()
	color_label.text = "Color Threshold:"
	color_label.add_theme_color_override("font_color", Color(0.7, 0.7, 0.75))
	color_label.custom_minimum_size.x = 140
	color_row.add_child(color_label)

	var color_slider = HSlider.new()
	color_slider.name = "ColorThresholdSlider"
	color_slider.min_value = 0
	color_slider.max_value = 50
	color_slider.step = 1
	color_slider.value = compare_color_threshold
	color_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	color_slider.value_changed.connect(_on_color_threshold_changed)
	color_row.add_child(color_slider)

	var color_value = Label.new()
	color_value.name = "ColorThresholdValue"
	color_value.text = "%d" % compare_color_threshold
	color_value.custom_minimum_size.x = 50
	color_value.add_theme_color_override("font_color", Color(0.9, 0.7, 0.3))
	color_row.add_child(color_value)

	# Help text
	var help_text = Label.new()
	help_text.text = "Pixel %: How many pixels can differ (0-10%)\nColor: RGB difference allowed per pixel (0-50)"
	help_text.add_theme_font_size_override("font_size", 12)
	help_text.add_theme_color_override("font_color", Color(0.5, 0.5, 0.55))
	tolerance_container.add_child(help_text)

	_update_tolerance_visibility()

	# Footer with keyboard shortcuts
	var footer = Label.new()
	footer.text = "F11: Record  |  ESC: Close"
	footer.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	footer.add_theme_font_size_override("font_size", 12)
	footer.add_theme_color_override("font_color", Color(0.45, 0.45, 0.5))
	vbox.add_child(footer)

	add_child(test_selector_panel)

func _clear_results_history():
	batch_results.clear()
	_update_results_tab()

func _on_record_new_test():
	_close_test_selector()
	# Small delay to let panel close, then start recording
	await get_tree().create_timer(0.1).timeout
	_start_recording()

func _refresh_test_list():
	if not test_selector_panel:
		return
	var test_list = test_selector_panel.get_node_or_null("VBoxContainer/TabContainer/Tests/ScrollContainer/TestList")
	if not test_list:
		return
	var tests_label = test_selector_panel.get_node_or_null("VBoxContainer/TabContainer/Tests/TestsHeader/TestsLabel")

	# Load categories
	_load_categories()

	var tests = _get_saved_tests()
	if tests_label:
		tests_label.text = "Total Tests: %d" % tests.size()

	# Clear existing
	for child in test_list.get_children():
		child.queue_free()

	if tests.is_empty():
		var empty_label = Label.new()
		empty_label.text = "No tests found.\nRecord a test with F11."
		empty_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		empty_label.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6))
		test_list.add_child(empty_label)
		return

	# Group tests by category
	var categorized: Dictionary = {}  # {category_name: [test_names]}
	var uncategorized: Array = []

	for test_name in tests:
		var cat = test_categories.get(test_name, "")
		if cat.is_empty():
			uncategorized.append(test_name)
		else:
			if not categorized.has(cat):
				categorized[cat] = []
			categorized[cat].append(test_name)

	# Add "New Category" button at top
	var new_cat_btn = Button.new()
	new_cat_btn.text = "+ New Category"
	new_cat_btn.tooltip_text = "Create a new category"
	new_cat_btn.add_theme_font_size_override("font_size", 12)
	new_cat_btn.pressed.connect(_on_new_category)
	test_list.add_child(new_cat_btn)

	# Add uncategorized tests first
	if not uncategorized.is_empty():
		_add_category_section(test_list, "", uncategorized)

	# Collect ALL categories (from test assignments + empty categories from collapsed_categories)
	var all_categories: Array = []
	for cat in categorized.keys():
		if cat not in all_categories:
			all_categories.append(cat)
	for cat in collapsed_categories.keys():
		if cat not in all_categories:
			all_categories.append(cat)
	all_categories.sort()

	# Add category sections (including empty ones)
	for cat_name in all_categories:
		var tests_in_cat = categorized.get(cat_name, [])
		# Apply saved order if available
		tests_in_cat = _get_ordered_tests(cat_name, tests_in_cat)
		_add_category_section(test_list, cat_name, tests_in_cat)

func _add_category_section(test_list: Control, category_name: String, test_names: Array):
	if category_name.is_empty():
		# Uncategorized - just add tests directly
		for test_name in test_names:
			_add_test_row(test_list, test_name)
		return

	# Category header
	var header = HBoxContainer.new()
	header.add_theme_constant_override("separation", 5)

	var is_collapsed = collapsed_categories.get(category_name, false)

	# Collapse toggle button
	var toggle_btn = Button.new()
	toggle_btn.text = "▼" if not is_collapsed else "▶"
	toggle_btn.tooltip_text = "Expand/collapse category"
	toggle_btn.custom_minimum_size = Vector2(24, 24)
	toggle_btn.pressed.connect(_on_toggle_category.bind(category_name))
	header.add_child(toggle_btn)

	# Category label (accepts drops)
	var cat_label = Button.new()
	cat_label.text = "%s (%d)" % [category_name, test_names.size()]
	cat_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cat_label.alignment = HORIZONTAL_ALIGNMENT_LEFT
	cat_label.flat = true
	cat_label.add_theme_font_size_override("font_size", 13)
	cat_label.add_theme_color_override("font_color", Color(0.7, 0.85, 0.7))
	cat_label.tooltip_text = "Drag tests here to add to category"
	cat_label.set_meta("category_name", category_name)
	cat_label.mouse_entered.connect(_on_category_mouse_entered.bind(cat_label))
	cat_label.mouse_exited.connect(_on_category_mouse_exited.bind(cat_label))
	header.add_child(cat_label)

	# Play category button
	var play_cat_btn = Button.new()
	play_cat_btn.text = "▶"
	play_cat_btn.tooltip_text = "Run all tests in category"
	play_cat_btn.custom_minimum_size = Vector2(24, 24)
	play_cat_btn.add_theme_color_override("font_color", Color(0.5, 0.8, 0.5))
	play_cat_btn.disabled = test_names.is_empty()
	play_cat_btn.pressed.connect(_on_play_category.bind(category_name))
	header.add_child(play_cat_btn)

	# Delete category button
	var del_cat_btn = Button.new()
	del_cat_btn.text = "✕"
	del_cat_btn.tooltip_text = "Delete category (tests become uncategorized)"
	del_cat_btn.custom_minimum_size = Vector2(24, 24)
	del_cat_btn.add_theme_color_override("font_color", Color(0.7, 0.4, 0.4))
	del_cat_btn.pressed.connect(_on_delete_category.bind(category_name))
	header.add_child(del_cat_btn)

	test_list.add_child(header)

	# Add tests if not collapsed
	if not is_collapsed:
		for test_name in test_names:
			_add_test_row(test_list, test_name, true)  # indented

func _add_test_row(test_list: Control, test_name: String, indented: bool = false):
	var row = HBoxContainer.new()
	row.add_theme_constant_override("separation", 3)
	row.set_meta("test_name", test_name)

	# Load test data to get actual display name
	var filepath = TESTS_DIR + "/" + test_name + ".json"
	var test_data = _load_test(filepath)
	var display_name = _get_display_name(test_data, test_name)

	# Indent spacer for categorized tests
	if indented:
		var spacer = Control.new()
		spacer.custom_minimum_size.x = 20
		row.add_child(spacer)

	# Drag handle
	var drag_handle = Button.new()
	drag_handle.text = "⋮⋮"
	drag_handle.tooltip_text = "Drag to category"
	drag_handle.custom_minimum_size = Vector2(24, 0)
	drag_handle.flat = true
	drag_handle.add_theme_color_override("font_color", Color(0.5, 0.5, 0.5))
	drag_handle.button_down.connect(_on_test_drag_start.bind(test_name))
	drag_handle.button_up.connect(_on_test_drag_end)
	row.add_child(drag_handle)

	# Test name label (not clickable to run anymore)
	var name_label = Label.new()
	name_label.text = display_name
	name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_label.add_theme_color_override("font_color", Color(0.85, 0.85, 0.9))
	row.add_child(name_label)

	# Play button (green)
	var play_btn = Button.new()
	play_btn.text = "▶"
	play_btn.tooltip_text = "Run test"
	play_btn.custom_minimum_size = Vector2(28, 0)
	play_btn.add_theme_color_override("font_color", Color(0.4, 0.9, 0.4))
	play_btn.pressed.connect(_on_test_selected.bind(test_name))
	row.add_child(play_btn)

	# Update baseline button
	var update_btn = Button.new()
	update_btn.text = "↻"
	update_btn.tooltip_text = "Re-record and update baseline"
	update_btn.custom_minimum_size = Vector2(28, 0)
	update_btn.pressed.connect(_on_update_baseline.bind(test_name))
	row.add_child(update_btn)

	# Edit button
	var edit_btn = Button.new()
	edit_btn.text = "📝"
	edit_btn.tooltip_text = "Edit test steps and delays"
	edit_btn.custom_minimum_size = Vector2(28, 0)
	edit_btn.pressed.connect(_on_edit_test.bind(test_name))
	row.add_child(edit_btn)

	# Rename button
	var rename_btn = Button.new()
	rename_btn.text = "✎"
	rename_btn.tooltip_text = "Rename test"
	rename_btn.custom_minimum_size = Vector2(28, 0)
	rename_btn.pressed.connect(_on_rename_test.bind(test_name))
	row.add_child(rename_btn)

	# Delete button
	var delete_btn = Button.new()
	delete_btn.text = "✕"
	delete_btn.tooltip_text = "Delete test and baseline"
	delete_btn.custom_minimum_size = Vector2(28, 0)
	delete_btn.add_theme_color_override("font_color", Color(1, 0.4, 0.4))
	delete_btn.pressed.connect(_on_delete_test.bind(test_name))
	row.add_child(delete_btn)

	test_list.add_child(row)

# Category UI handlers
func _on_toggle_category(category_name: String):
	collapsed_categories[category_name] = not collapsed_categories.get(category_name, false)
	_save_categories()
	_refresh_test_list()

func _on_new_category():
	# Show input dialog for new category name
	_show_new_category_dialog()

func _on_delete_category(category_name: String):
	# Remove category assignment from all tests in this category
	var tests_to_update = []
	for test_name in test_categories.keys():
		if test_categories[test_name] == category_name:
			tests_to_update.append(test_name)

	for test_name in tests_to_update:
		test_categories.erase(test_name)

	collapsed_categories.erase(category_name)
	_save_categories()
	_refresh_test_list()

func _on_play_category(category_name: String):
	# Get all tests in this category (only those that exist on disk)
	var saved_tests = _get_saved_tests()
	var tests_in_category: Array = []
	for test_name in test_categories.keys():
		if test_categories[test_name] == category_name:
			# Validate test file exists
			if test_name in saved_tests:
				tests_in_category.append(test_name)
			else:
				print("[UITestRunner] Skipping missing test: ", test_name)

	if tests_in_category.is_empty():
		print("[UITestRunner] No tests in category: ", category_name)
		return

	# Apply saved order
	tests_in_category = _get_ordered_tests(category_name, tests_in_category)

	_close_test_selector()
	print("[UITestRunner] === RUNNING CATEGORY: %s (%d tests) ===" % [category_name, tests_in_category.size()])

	is_batch_running = true
	batch_results.clear()

	for test_name in tests_in_category:
		print("[UITestRunner] --- Running: %s ---" % test_name)
		var result = await _run_test_and_get_result(test_name)
		batch_results.append(result)
		await get_tree().create_timer(0.3).timeout

	is_batch_running = false
	_show_results_panel()

func _on_test_drag_start(test_name: String):
	dragging_test_name = test_name
	_create_drag_indicator(test_name)

func _on_test_drag_end():
	# Save drop target before clearing
	var target_category = drop_target_category
	var target_index = drop_target_index
	var test_name = dragging_test_name

	_remove_drag_indicator()
	_remove_drop_line()
	dragging_test_name = ""

	if test_name.is_empty():
		return

	# Use tracked drop target if available
	if target_index >= 0:
		_set_test_category(test_name, target_category, target_index)
		_refresh_test_list()
	elif not target_category.is_empty():
		_set_test_category(test_name, target_category)
		_refresh_test_list()
	else:
		# Fallback: Check if mouse is over a category header
		var category_target = _get_category_under_mouse()
		if category_target:
			_set_test_category(test_name, category_target)
			_refresh_test_list()

func _create_drag_indicator(test_name: String):
	_remove_drag_indicator()

	drag_indicator = PanelContainer.new()
	drag_indicator.z_index = 100

	var label = Label.new()
	label.text = "📋 " + test_name.replace("_", " ").capitalize()
	label.add_theme_font_size_override("font_size", 12)
	drag_indicator.add_child(label)

	# Style the panel
	var style = StyleBoxFlat.new()
	style.bg_color = Color(0.2, 0.4, 0.6, 0.9)
	style.set_corner_radius_all(4)
	style.set_content_margin_all(6)
	drag_indicator.add_theme_stylebox_override("panel", style)

	add_child(drag_indicator)
	drag_indicator.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_update_drag_indicator_position()

func _remove_drag_indicator():
	if drag_indicator:
		drag_indicator.queue_free()
		drag_indicator = null

func _update_drag_indicator_position():
	if drag_indicator:
		var mouse_pos = get_viewport().get_mouse_position()
		drag_indicator.global_position = mouse_pos + Vector2(15, 15)

func _create_drop_line():
	if drop_line:
		return
	drop_line = Control.new()
	drop_line.custom_minimum_size = Vector2(200, 3)
	drop_line.z_index = 99
	drop_line.mouse_filter = Control.MOUSE_FILTER_IGNORE

	# Draw a bright line
	drop_line.draw.connect(func():
		drop_line.draw_rect(Rect2(0, 0, drop_line.size.x, 3), Color(0.3, 0.8, 1.0), true)
	)

	add_child(drop_line)
	drop_line.visible = false

func _remove_drop_line():
	if drop_line:
		drop_line.queue_free()
		drop_line = null
	drop_target_category = ""
	drop_target_index = -1

func _update_drop_line_position():
	if not dragging_test_name or not test_selector_panel:
		if drop_line:
			drop_line.visible = false
		return

	var test_list = test_selector_panel.get_node_or_null("VBoxContainer/TabContainer/Tests/ScrollContainer/TestList")
	if not test_list:
		if drop_line:
			drop_line.visible = false
		return

	var mouse_pos = get_viewport().get_mouse_position()
	var found_drop_target = false

	# Find which test row or category we're near
	var current_category = ""
	var index_in_category = 0

	for child in test_list.get_children():
		if child is HBoxContainer:
			# Check if this is a category header
			for subchild in child.get_children():
				if subchild is Button and subchild.has_meta("category_name"):
					current_category = subchild.get_meta("category_name")
					index_in_category = 0
					break

			# Check if this is a test row
			if child.has_meta("test_name"):
				var test_name = child.get_meta("test_name")
				if test_name == dragging_test_name:
					# Don't increment index - we want indices as if this test is removed
					continue

				var rect = child.get_global_rect()
				var mid_y = rect.position.y + rect.size.y / 2

				# If mouse is above midpoint, drop before this test
				if mouse_pos.y < mid_y and mouse_pos.y > rect.position.y - 10:
					if not drop_line:
						_create_drop_line()
					drop_line.visible = true
					drop_line.global_position = Vector2(rect.position.x, rect.position.y - 1)
					drop_line.custom_minimum_size.x = rect.size.x
					drop_line.queue_redraw()
					drop_target_category = current_category
					drop_target_index = index_in_category
					found_drop_target = true
					break
				# If mouse is below midpoint but within row, drop after this test
				elif mouse_pos.y >= mid_y and mouse_pos.y < rect.position.y + rect.size.y + 10:
					if not drop_line:
						_create_drop_line()
					drop_line.visible = true
					drop_line.global_position = Vector2(rect.position.x, rect.position.y + rect.size.y + 1)
					drop_line.custom_minimum_size.x = rect.size.x
					drop_line.queue_redraw()
					drop_target_category = current_category
					drop_target_index = index_in_category + 1
					found_drop_target = true
					break

				index_in_category += 1

	if not found_drop_target:
		if drop_line:
			drop_line.visible = false
		drop_target_category = ""
		drop_target_index = -1

func _on_category_mouse_entered(cat_label: Button):
	if not dragging_test_name.is_empty():
		cat_label.add_theme_color_override("font_color", Color(0.5, 1.0, 0.5))

func _on_category_mouse_exited(cat_label: Button):
	cat_label.add_theme_color_override("font_color", Color(0.7, 0.85, 0.7))

func _get_category_under_mouse() -> String:
	var test_list = test_selector_panel.get_node_or_null("VBoxContainer/TabContainer/Tests/ScrollContainer/TestList")
	if not test_list:
		return ""

	var mouse_pos = test_list.get_global_mouse_position()

	for child in test_list.get_children():
		if child is HBoxContainer:
			for subchild in child.get_children():
				if subchild is Button and subchild.has_meta("category_name"):
					var rect = subchild.get_global_rect()
					if rect.has_point(mouse_pos):
						return subchild.get_meta("category_name")
	return ""

var new_category_dialog: Control = null

func _show_new_category_dialog():
	if new_category_dialog:
		new_category_dialog.queue_free()

	new_category_dialog = Panel.new()
	new_category_dialog.process_mode = Node.PROCESS_MODE_ALWAYS

	var viewport_size = get_viewport().get_visible_rect().size
	var dialog_size = Vector2(300, 120)
	new_category_dialog.position = (viewport_size - dialog_size) / 2
	new_category_dialog.size = dialog_size

	var style = StyleBoxFlat.new()
	style.bg_color = Color(0.15, 0.15, 0.18, 0.98)
	style.border_color = Color(0.4, 0.6, 0.4)
	style.set_border_width_all(2)
	style.set_corner_radius_all(8)
	new_category_dialog.add_theme_stylebox_override("panel", style)

	var vbox = VBoxContainer.new()
	vbox.set_anchors_preset(Control.PRESET_FULL_RECT)
	vbox.add_theme_constant_override("separation", 10)
	vbox.offset_left = 15
	vbox.offset_top = 15
	vbox.offset_right = -15
	vbox.offset_bottom = -15
	new_category_dialog.add_child(vbox)

	var title = Label.new()
	title.text = "New Category"
	title.add_theme_font_size_override("font_size", 16)
	vbox.add_child(title)

	var input = LineEdit.new()
	input.name = "CategoryInput"
	input.placeholder_text = "Category name..."
	input.text_submitted.connect(_on_new_category_submitted)
	vbox.add_child(input)

	var btn_row = HBoxContainer.new()
	btn_row.add_theme_constant_override("separation", 10)
	vbox.add_child(btn_row)

	var cancel_btn = Button.new()
	cancel_btn.text = "Cancel"
	cancel_btn.pressed.connect(_close_new_category_dialog)
	btn_row.add_child(cancel_btn)

	var create_btn = Button.new()
	create_btn.text = "Create"
	create_btn.pressed.connect(func(): _on_new_category_submitted(input.text))
	btn_row.add_child(create_btn)

	add_child(new_category_dialog)
	input.grab_focus()

func _on_new_category_submitted(category_name: String):
	var name = category_name.strip_edges()
	if name.is_empty():
		_close_new_category_dialog()
		return

	# Add empty category (it will appear when tests are dragged into it)
	# For now, just refresh to show it exists
	collapsed_categories[name] = false
	_save_categories()
	_close_new_category_dialog()
	_refresh_test_list()

func _close_new_category_dialog():
	if new_category_dialog:
		new_category_dialog.queue_free()
		new_category_dialog = null

func _on_test_selected(test_name: String):
	print("[UITestRunner] Running test: ", test_name)
	_close_test_selector()
	_run_test_from_file(test_name)

# ============================================================================
# TEST MANAGEMENT
# ============================================================================

var rename_dialog: Control = null
var rename_target_test: String = ""

func _on_delete_test(test_name: String):
	# Load test data to get baseline path
	var filepath = TESTS_DIR + "/" + test_name + ".json"
	var test_data = _load_test(filepath)

	# Delete baseline if exists
	if test_data.has("baseline_path") and test_data.baseline_path:
		var baseline_global = ProjectSettings.globalize_path(test_data.baseline_path)
		_delete_file_and_import(baseline_global)
		print("[UITestRunner] Deleted baseline: ", test_data.baseline_path)

		# Also delete actual screenshot if exists
		var actual_path = test_data.baseline_path.replace(".png", "_actual.png")
		var actual_global = ProjectSettings.globalize_path(actual_path)
		_delete_file_and_import(actual_global)

	# Delete test file
	var test_global = ProjectSettings.globalize_path(filepath)
	if FileAccess.file_exists(test_global):
		DirAccess.remove_absolute(test_global)
		print("[UITestRunner] Deleted test: ", test_name)

	_refresh_test_list()

func _delete_file_and_import(file_path: String):
	# Delete the file itself
	if FileAccess.file_exists(file_path):
		DirAccess.remove_absolute(file_path)
	# Also delete the .import file to prevent Godot reimport errors
	var import_path = file_path + ".import"
	if FileAccess.file_exists(import_path):
		DirAccess.remove_absolute(import_path)

func _on_rename_test(test_name: String):
	rename_target_test = test_name
	# Load test data to get the actual display name (preserves casing)
	var filepath = TESTS_DIR + "/" + test_name + ".json"
	var test_data = _load_test(filepath)
	var display_name = _get_display_name(test_data, test_name)
	_show_rename_dialog(display_name)

# Returns a friendly display name from test data, with smart fallback for old sanitized names
func _get_display_name(test_data: Dictionary, fallback_filename: String) -> String:
	var stored_name = test_data.get("name", "")
	# Use stored name if it looks like a proper display name (not sanitized)
	if stored_name.is_empty() or (stored_name.contains("_") and stored_name == stored_name.to_lower()):
		# Looks like a sanitized filename - format it nicely
		return fallback_filename.replace("_", " ").capitalize()
	else:
		# Use the stored display name as-is
		return stored_name

func _show_rename_dialog(display_name: String):
	if not rename_dialog:
		_create_rename_dialog()

	var input = rename_dialog.get_node("VBox/Input")
	input.text = display_name
	input.select_all()
	rename_dialog.visible = true
	rename_dialog.move_to_front()  # Ensure dialog is on top
	input.grab_focus()

func _create_rename_dialog():
	rename_dialog = Panel.new()
	rename_dialog.name = "RenameDialog"
	rename_dialog.process_mode = Node.PROCESS_MODE_ALWAYS

	var viewport_size = get_viewport().get_visible_rect().size
	var dialog_size = Vector2(350, 150)
	rename_dialog.position = (viewport_size - dialog_size) / 2
	rename_dialog.size = dialog_size

	var style = StyleBoxFlat.new()
	style.bg_color = Color(0.15, 0.15, 0.18, 0.98)
	style.border_color = Color(0.3, 0.6, 1.0, 1.0)
	style.set_border_width_all(2)
	style.set_corner_radius_all(8)
	rename_dialog.add_theme_stylebox_override("panel", style)

	var vbox = VBoxContainer.new()
	vbox.name = "VBox"
	vbox.set_anchors_preset(Control.PRESET_FULL_RECT)
	vbox.add_theme_constant_override("separation", 15)
	var margin = 15
	vbox.offset_left = margin
	vbox.offset_top = margin
	vbox.offset_right = -margin
	vbox.offset_bottom = -margin
	rename_dialog.add_child(vbox)

	var title = Label.new()
	title.text = "Rename Test"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 18)
	vbox.add_child(title)

	var input = LineEdit.new()
	input.name = "Input"
	input.placeholder_text = "Enter new name..."
	input.text_submitted.connect(_on_rename_submitted)
	vbox.add_child(input)

	var button_row = HBoxContainer.new()
	button_row.add_theme_constant_override("separation", 10)
	vbox.add_child(button_row)

	var cancel_btn = Button.new()
	cancel_btn.text = "Cancel"
	cancel_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cancel_btn.pressed.connect(_close_rename_dialog)
	button_row.add_child(cancel_btn)

	var save_btn = Button.new()
	save_btn.text = "Rename"
	save_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	save_btn.pressed.connect(_do_rename)
	button_row.add_child(save_btn)

	add_child(rename_dialog)

func _close_rename_dialog():
	if rename_dialog:
		rename_dialog.visible = false
	rename_target_test = ""

func _on_rename_submitted(_text: String):
	_do_rename()

func _sanitize_filename(text: String) -> String:
	"""Convert text to a safe filename, removing/replacing invalid characters"""
	# First convert to snake_case and replace spaces
	var result = text.to_snake_case().replace(" ", "_")
	# Remove characters invalid in filenames (Windows: \ / : * ? " < > |)
	result = result.replace("/", "_").replace("\\", "_")
	result = result.replace(":", "_").replace("*", "_")
	result = result.replace("?", "_").replace("\"", "_")
	result = result.replace("<", "_").replace(">", "_")
	result = result.replace("|", "_")
	# Collapse multiple underscores
	while result.contains("__"):
		result = result.replace("__", "_")
	# Trim leading/trailing underscores
	result = result.strip_edges().trim_prefix("_").trim_suffix("_")
	return result

func _do_rename():
	if rename_target_test.is_empty():
		return

	var input = rename_dialog.get_node("VBox/Input")
	var display_name = input.text.strip_edges()
	var new_filename = _sanitize_filename(display_name)

	if new_filename.is_empty() or new_filename == rename_target_test:
		_close_rename_dialog()
		return

	# Load old test
	var old_filepath = TESTS_DIR + "/" + rename_target_test + ".json"
	var test_data = _load_test(old_filepath)
	if test_data.is_empty():
		_close_rename_dialog()
		return

	# Update test name in data (preserve display name, not sanitized)
	test_data.name = display_name

	# Rename baseline file if exists (use sanitized filename)
	if test_data.has("baseline_path") and test_data.baseline_path:
		var old_baseline = test_data.baseline_path
		var new_baseline = old_baseline.get_base_dir() + "/baseline_" + new_filename + ".png"

		var old_global = ProjectSettings.globalize_path(old_baseline)
		var new_global = ProjectSettings.globalize_path(new_baseline)

		if FileAccess.file_exists(old_global):
			DirAccess.rename_absolute(old_global, new_global)
			test_data.baseline_path = new_baseline
			print("[UITestRunner] Renamed baseline to: ", new_baseline)

	# Save with new filename (sanitized)
	var new_filepath = TESTS_DIR + "/" + new_filename + ".json"
	var file = FileAccess.open(new_filepath, FileAccess.WRITE)
	if file:
		file.store_string(JSON.stringify(test_data, "\t"))
		file.close()

	# Delete old test file
	var old_global = ProjectSettings.globalize_path(old_filepath)
	if FileAccess.file_exists(old_global):
		DirAccess.remove_absolute(old_global)

	# Preserve category assignment (use filename for category keys)
	var old_category = test_categories.get(rename_target_test, "")
	if old_category:
		test_categories.erase(rename_target_test)
		test_categories[new_filename] = old_category

		# Update order within category
		if category_test_order.has(old_category):
			var order = category_test_order[old_category]
			var idx = order.find(rename_target_test)
			if idx >= 0:
				order[idx] = new_filename

		_save_categories()

	print("[UITestRunner] Renamed test: ", rename_target_test, " -> ", new_filename, " (display: ", display_name, ")")

	_close_rename_dialog()
	_refresh_test_list()

func _on_update_baseline(test_name: String):
	print("[UITestRunner] Re-recording test: ", test_name)
	rerecording_test_name = test_name  # Store name to overwrite on save
	_close_test_selector()
	# Small delay to let panel close, then start recording
	await get_tree().create_timer(0.1).timeout
	_start_recording()

func _on_edit_test(test_name: String):
	print("[UITestRunner] Editing test: ", test_name)
	var filepath = TESTS_DIR + "/" + test_name + ".json"
	var test_data = _load_test(filepath)

	if test_data.is_empty():
		print("[UITestRunner] Failed to load test")
		return

	# Load events into recorded_events, converting JSON dicts to Vector2
	recorded_events.clear()
	for event in test_data.get("events", []):
		var event_type = event.get("type", "")
		var converted_event = {"type": event_type, "time": event.get("time", 0)}

		match event_type:
			"click", "double_click":
				var pos = event.get("pos", {})
				converted_event["pos"] = Vector2(pos.get("x", 0), pos.get("y", 0))
			"drag":
				var from_pos = event.get("from", {})
				var to_pos = event.get("to", {})
				converted_event["from"] = Vector2(from_pos.get("x", 0), from_pos.get("y", 0))
				converted_event["to"] = Vector2(to_pos.get("x", 0), to_pos.get("y", 0))
			"key":
				converted_event["keycode"] = event.get("keycode", 0)
				converted_event["shift"] = event.get("shift", false)
				converted_event["ctrl"] = event.get("ctrl", false)
			"wait":
				converted_event["duration"] = event.get("duration", 1000)

		# Load wait_after and note
		var default_wait = DEFAULT_DELAYS.get(event_type, 100)
		converted_event["wait_after"] = event.get("wait_after", default_wait)
		converted_event["note"] = event.get("note", "")

		recorded_events.append(converted_event)

	# Load baseline region for re-saving
	var baseline_region = test_data.get("baseline_region")
	if baseline_region:
		selection_rect = Rect2(
			baseline_region.get("x", 0),
			baseline_region.get("y", 0),
			baseline_region.get("w", 0),
			baseline_region.get("h", 0)
		)
		pending_baseline_region = baseline_region
	else:
		pending_baseline_region = {}

	# Load screenshots (new format) or leave empty for legacy tests
	recorded_screenshots.clear()
	for screenshot in test_data.get("screenshots", []):
		recorded_screenshots.append(screenshot.duplicate())

	# Set pending data for save (use actual display name from test data)
	pending_test_name = _get_display_name(test_data, test_name)
	pending_baseline_path = test_data.get("baseline_path", "")

	# Close test selector and show event editor
	_close_test_selector()
	await get_tree().create_timer(0.1).timeout
	_show_event_editor()

func _run_test_for_baseline_update(test_name: String):
	var filepath = TESTS_DIR + "/" + test_name + ".json"
	var test_data = _load_test(filepath)

	if test_data.is_empty():
		print("[UITestRunner] Failed to load test")
		return

	# Load events
	recorded_events.clear()
	for event in test_data.get("events", []):
		var event_type = event.get("type", "")
		var converted_event = {"type": event_type, "time": event.get("time", 0)}

		match event_type:
			"click", "double_click":
				var pos = event.get("pos", {})
				converted_event["pos"] = Vector2(pos.get("x", 0), pos.get("y", 0))
			"drag":
				var from_pos = event.get("from", {})
				var to_pos = event.get("to", {})
				converted_event["from"] = Vector2(from_pos.get("x", 0), from_pos.get("y", 0))
				converted_event["to"] = Vector2(to_pos.get("x", 0), to_pos.get("y", 0))
			"key":
				converted_event["keycode"] = event.get("keycode", 0)
				converted_event["shift"] = event.get("shift", false)
				converted_event["ctrl"] = event.get("ctrl", false)
			"wait":
				converted_event["duration"] = event.get("duration", 1000)

		var default_wait = DEFAULT_DELAYS.get(event_type, 100)
		converted_event["wait_after"] = event.get("wait_after", default_wait)
		recorded_events.append(converted_event)

	# Run the test without validation
	await begin_test(test_data.get("name", test_name) + " (Baseline Update)")

	for event in recorded_events:
		var event_type = event.get("type", "")
		var wait_after_ms = event.get("wait_after", 100)

		match event_type:
			"click":
				var pos = event.get("pos", Vector2.ZERO)
				await click_at(pos)
			"double_click":
				var pos = event.get("pos", Vector2.ZERO)
				await move_to(pos)
				await double_click()
			"drag":
				var from_pos = event.get("from", Vector2.ZERO)
				var to_pos = event.get("to", Vector2.ZERO)
				# For drags, use wait_after as hold time (keeps mouse pressed for hover navigation)
				var hold_time = wait_after_ms / 1000.0
				await drag(from_pos, to_pos, 0.5, hold_time)
				wait_after_ms = 0  # Already applied as hold time
			"key":
				var keycode = event.get("keycode", 0)
				await press_key(keycode, event.get("shift", false), event.get("ctrl", false))
			"wait":
				var duration_ms = event.get("duration", 1000)
				await wait(duration_ms / 1000.0)

		# Apply wait_after delay (except for drag which uses it as hold time)
		if wait_after_ms > 0:
			await wait(wait_after_ms / 1000.0)

	await wait(0.3)
	end_test(true)

	# Now capture new baseline using the stored region
	var baseline_region = test_data.get("baseline_region")
	if baseline_region:
		selection_rect = Rect2(
			baseline_region.get("x", 0),
			baseline_region.get("y", 0),
			baseline_region.get("w", 0),
			baseline_region.get("h", 0)
		)

		# Capture new baseline
		var new_baseline = await _capture_baseline_for_update(test_data.get("baseline_path", ""))

		# Update test data with new baseline path (in case filename changed)
		test_data.baseline_path = new_baseline

		# Save updated test
		var file = FileAccess.open(filepath, FileAccess.WRITE)
		if file:
			file.store_string(JSON.stringify(test_data, "\t"))
			file.close()

		print("[UITestRunner] Baseline updated for: ", test_name)
	else:
		print("[UITestRunner] No baseline region found - cannot update")

func _capture_baseline_for_update(existing_path: String) -> String:
	# Hide UI elements
	virtual_cursor.visible = false
	if recording_indicator:
		recording_indicator.visible = false
	if selection_overlay:
		selection_overlay.visible = false

	await get_tree().process_frame
	await get_tree().process_frame
	await get_tree().process_frame

	var image = get_viewport().get_texture().get_image()
	var cropped = image.get_region(selection_rect)

	# Use existing path or generate new one
	var save_path = existing_path
	if save_path.is_empty():
		var timestamp = Time.get_datetime_string_from_system().replace(":", "-").replace(" ", "_")
		save_path = "res://tests/baselines/baseline_%s.png" % timestamp

	# Save image
	cropped.save_png(ProjectSettings.globalize_path(save_path))
	print("[UITestRunner] New baseline saved: ", save_path)

	return save_path

# ============================================================================
# BATCH TEST EXECUTION
# ============================================================================

func _run_all_tests():
	var tests = _get_saved_tests()
	if tests.is_empty():
		print("[UITestRunner] No tests to run")
		return

	_close_test_selector()
	print("[UITestRunner] === RUNNING ALL TESTS (%d tests) ===" % tests.size())

	is_batch_running = true
	batch_results.clear()

	for test_name in tests:
		print("[UITestRunner] --- Running: %s ---" % test_name)
		var result = await _run_test_and_get_result(test_name)
		batch_results.append(result)
		# Small delay between tests
		await get_tree().create_timer(0.3).timeout

	is_batch_running = false
	_show_results_panel()

func _run_test_and_get_result(test_name: String) -> Dictionary:
	var filepath = TESTS_DIR + "/" + test_name + ".json"
	var test_data = _load_test(filepath)

	var result = {
		"name": test_name,
		"passed": false,
		"baseline_path": "",
		"actual_path": "",
		"failed_step": -1
	}

	if test_data.is_empty():
		return result

	# Load events
	recorded_events.clear()
	for event in test_data.get("events", []):
		var event_type = event.get("type", "")
		var converted_event = {"type": event_type, "time": event.get("time", 0)}

		match event_type:
			"click", "double_click":
				var pos = event.get("pos", {})
				converted_event["pos"] = Vector2(pos.get("x", 0), pos.get("y", 0))
			"drag":
				var from_pos = event.get("from", {})
				var to_pos = event.get("to", {})
				converted_event["from"] = Vector2(from_pos.get("x", 0), from_pos.get("y", 0))
				converted_event["to"] = Vector2(to_pos.get("x", 0), to_pos.get("y", 0))
			"key":
				converted_event["keycode"] = event.get("keycode", 0)
				converted_event["shift"] = event.get("shift", false)
				converted_event["ctrl"] = event.get("ctrl", false)
			"wait":
				converted_event["duration"] = event.get("duration", 1000)

		var default_wait = DEFAULT_DELAYS.get(event_type, 100)
		converted_event["wait_after"] = event.get("wait_after", default_wait)
		recorded_events.append(converted_event)

	# Build a map of screenshots by their after_event_index for inline validation
	var screenshots_by_index: Dictionary = {}
	var screenshots = test_data.get("screenshots", [])
	for screenshot in screenshots:
		var after_idx = screenshot.get("after_event_index", -1)
		if not screenshots_by_index.has(after_idx):
			screenshots_by_index[after_idx] = []
		screenshots_by_index[after_idx].append(screenshot)

	# Run the test
	await begin_test(test_data.get("name", test_name))

	var passed = true
	for i in range(recorded_events.size()):
		var event = recorded_events[i]
		var event_type = event.get("type", "")
		var wait_after_ms = event.get("wait_after", 100)

		match event_type:
			"click":
				var pos = event.get("pos", Vector2.ZERO)
				await click_at(pos)
			"double_click":
				var pos = event.get("pos", Vector2.ZERO)
				await move_to(pos)
				await double_click()
			"drag":
				var from_pos = event.get("from", Vector2.ZERO)
				var to_pos = event.get("to", Vector2.ZERO)
				var hold_time = wait_after_ms / 1000.0
				await drag(from_pos, to_pos, 0.5, hold_time)
				wait_after_ms = 0
			"key":
				var keycode = event.get("keycode", 0)
				await press_key(keycode, event.get("shift", false), event.get("ctrl", false))
			"wait":
				var duration_ms = event.get("duration", 1000)
				await wait(duration_ms / 1000.0)

		if wait_after_ms > 0:
			await wait(wait_after_ms / 1000.0)

		# Validate screenshots after this event (inline validation)
		if screenshots_by_index.has(i) and passed:
			for screenshot in screenshots_by_index[i]:
				var screenshot_path = screenshot.get("path", "")
				var screenshot_region = screenshot.get("region", {})
				if screenshot_path and not screenshot_region.is_empty():
					var region = Rect2(
						screenshot_region.get("x", 0),
						screenshot_region.get("y", 0),
						screenshot_region.get("w", 0),
						screenshot_region.get("h", 0)
					)
					var screenshot_passed = await validate_screenshot(screenshot_path, region)
					if not screenshot_passed:
						passed = false
						result["baseline_path"] = screenshot_path
						result["actual_path"] = screenshot_path.replace(".png", "_actual.png")
						result["failed_step"] = i + 1
						break

		if not passed:
			break

	# If no inline screenshots, check legacy single baseline at end
	if screenshots.is_empty() and passed:
		await wait(0.3)
		var baseline_path = test_data.get("baseline_path", "")
		var baseline_region = test_data.get("baseline_region")
		result["baseline_path"] = baseline_path
		if baseline_path and baseline_region:
			var region = Rect2(
				baseline_region.get("x", 0),
				baseline_region.get("y", 0),
				baseline_region.get("w", 0),
				baseline_region.get("h", 0)
			)
			result["actual_path"] = baseline_path.replace(".png", "_actual.png")
			passed = await validate_screenshot(baseline_path, region)
			if not passed:
				result["failed_step"] = recorded_events.size()

	end_test(passed)
	result["passed"] = passed

	return result

func _show_results_panel():
	# Open Test Manager and switch to Results tab
	_open_test_selector()
	_update_results_tab()
	# Switch to Results tab (index 1)
	var tabs = test_selector_panel.get_node_or_null("VBoxContainer/TabContainer")
	if tabs:
		tabs.current_tab = 1

func _close_results_panel():
	# Legacy - now just closes test selector
	_close_test_selector()

func _update_results_tab():
	if not test_selector_panel:
		return

	var results_tab = test_selector_panel.get_node_or_null("VBoxContainer/TabContainer/Results")
	if not results_tab:
		return

	var summary_label = results_tab.get_node_or_null("SummaryLabel")
	var results_list = results_tab.get_node_or_null("ResultsScroll/ResultsList")

	if not summary_label or not results_list:
		return

	# Clear existing results
	for child in results_list.get_children():
		child.queue_free()

	if batch_results.is_empty():
		summary_label.text = "No test runs yet"
		summary_label.add_theme_color_override("font_color", Color(0.6, 0.6, 0.65))
		return

	# Count passed/failed
	var passed_count = 0
	var failed_count = 0
	for result in batch_results:
		if result.passed:
			passed_count += 1
		else:
			failed_count += 1

	# Update summary
	if failed_count == 0:
		summary_label.text = "✓ All %d tests passed!" % batch_results.size()
		summary_label.add_theme_color_override("font_color", Color(0.4, 1, 0.4))
	else:
		summary_label.text = "%d passed, %d failed (%d total)" % [passed_count, failed_count, batch_results.size()]
		summary_label.add_theme_color_override("font_color", Color(1, 0.6, 0.4))

	# Populate results list
	for result in batch_results:
		var row = HBoxContainer.new()
		row.add_theme_constant_override("separation", 10)
		results_list.add_child(row)

		# Status icon
		var status = Label.new()
		if result.passed:
			status.text = "✓"
			status.add_theme_color_override("font_color", Color(0.4, 1, 0.4))
		else:
			status.text = "✗"
			status.add_theme_color_override("font_color", Color(1, 0.4, 0.4))
		status.add_theme_font_size_override("font_size", 18)
		row.add_child(status)

		# Test name
		var name_label = Label.new()
		name_label.text = result.name.replace("_", " ").capitalize()
		name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		if not result.passed:
			name_label.add_theme_color_override("font_color", Color(1, 0.7, 0.7))
		row.add_child(name_label)

		# Failed step indicator (clickable to view steps)
		var failed_step = result.get("failed_step", -1)
		if not result.passed and failed_step > 0:
			var step_btn = Button.new()
			step_btn.text = "Failed at Step %d" % failed_step
			step_btn.tooltip_text = "Click to view test steps"
			step_btn.add_theme_color_override("font_color", Color(1, 0.6, 0.4))
			step_btn.pressed.connect(_on_view_failed_step.bind(result.name, failed_step))
			row.add_child(step_btn)

		# View diff button (only for failed tests)
		if not result.passed and result.baseline_path:
			var diff_btn = Button.new()
			diff_btn.text = "View Diff"
			diff_btn.pressed.connect(_view_failed_test_diff.bind(result))
			row.add_child(diff_btn)

		# Re-run button
		var rerun_btn = Button.new()
		rerun_btn.text = "▶"
		rerun_btn.tooltip_text = "Re-run this test"
		rerun_btn.custom_minimum_size = Vector2(30, 0)
		rerun_btn.pressed.connect(_on_test_selected.bind(result.name))
		row.add_child(rerun_btn)

func _on_view_failed_step(test_name: String, failed_step: int):
	# Load test data and show event editor with the failed step highlighted
	var filepath = TESTS_DIR + "/" + test_name + ".json"
	var test_data = _load_test(filepath)
	if test_data.is_empty():
		return

	# Load events into recorded_events
	recorded_events.clear()
	for event in test_data.get("events", []):
		var event_type = event.get("type", "")
		var converted_event = {"type": event_type, "time": event.get("time", 0)}

		match event_type:
			"click", "double_click":
				var pos = event.get("pos", {})
				converted_event["pos"] = Vector2(pos.get("x", 0), pos.get("y", 0))
			"drag":
				var from_pos = event.get("from", {})
				var to_pos = event.get("to", {})
				converted_event["from"] = Vector2(from_pos.get("x", 0), from_pos.get("y", 0))
				converted_event["to"] = Vector2(to_pos.get("x", 0), to_pos.get("y", 0))
			"key":
				converted_event["keycode"] = event.get("keycode", 0)
				converted_event["shift"] = event.get("shift", false)
				converted_event["ctrl"] = event.get("ctrl", false)
			"wait":
				converted_event["duration"] = event.get("duration", 1000)

		var default_wait = DEFAULT_DELAYS.get(event_type, 100)
		converted_event["wait_after"] = event.get("wait_after", default_wait)
		if event.has("note"):
			converted_event["note"] = event.note
		recorded_events.append(converted_event)

	# Load screenshots
	recorded_screenshots.clear()
	for screenshot in test_data.get("screenshots", []):
		recorded_screenshots.append(screenshot.duplicate())

	# Load baseline region for legacy tests
	var baseline_region = test_data.get("baseline_region")
	if baseline_region:
		pending_baseline_region = baseline_region
	else:
		pending_baseline_region = {}

	# Set up pending data
	pending_test_name = _get_display_name(test_data, test_name)
	pending_baseline_path = test_data.get("baseline_path", "")

	# Close test selector and show event editor
	_close_test_selector()
	_show_event_editor()

	# Highlight the failed step after a brief delay to ensure UI is ready
	_highlight_failed_step.call_deferred(failed_step)

func _highlight_failed_step(step_index: int):
	if not event_editor:
		return

	var event_list = event_editor.get_node_or_null("VBox/EventScroll/EventList")
	var scroll = event_editor.get_node_or_null("VBox/EventScroll")
	if not event_list or not scroll:
		return

	# Find the row for this step (accounting for screenshot rows and insert buttons)
	var target_row: Control = null
	var current_event_index = 0
	for child in event_list.get_children():
		if child.name.begins_with("Panel"):  # Event rows have Panel containers
			current_event_index += 1
			if current_event_index == step_index:
				target_row = child
				break

	if target_row:
		# Highlight with red border
		var style = StyleBoxFlat.new()
		style.bg_color = Color(0.3, 0.15, 0.15, 0.9)
		style.border_color = Color(1, 0.4, 0.4, 1.0)
		style.set_border_width_all(2)
		style.set_corner_radius_all(4)
		target_row.add_theme_stylebox_override("panel", style)

		# Scroll to the failed step
		await get_tree().process_frame
		scroll.ensure_control_visible(target_row)

func _view_failed_test_diff(result: Dictionary):
	last_baseline_path = result.baseline_path
	last_actual_path = result.actual_path
	_close_results_panel()
	_show_comparison_viewer()

func _capture_event(event: InputEvent):
	# Skip capture if recording is paused
	if is_recording_paused:
		return

	var time_offset = Time.get_ticks_msec() - record_start_time

	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		# Skip clicks on HUD buttons
		if _is_click_on_recording_hud(event.global_position):
			return

		if event.pressed:
			mouse_down_pos = event.global_position
			mouse_is_down = true
			mouse_is_double_click = event.double_click
		else:
			# Mouse up - determine if it was a click, double-click, or drag
			var distance = event.global_position.distance_to(mouse_down_pos)
			if distance < 5.0:
				if mouse_is_double_click:
					# Double-click
					recorded_events.append({
						"type": "double_click",
						"pos": mouse_down_pos,
						"time": time_offset
					})
					print("[REC] Double-click at ", mouse_down_pos)
				else:
					# Single click
					recorded_events.append({
						"type": "click",
						"pos": mouse_down_pos,
						"time": time_offset
					})
					print("[REC] Click at ", mouse_down_pos)
			else:
				# Drag
				recorded_events.append({
					"type": "drag",
					"from": mouse_down_pos,
					"to": event.global_position,
					"time": time_offset
				})
				print("[REC] Drag from ", mouse_down_pos, " to ", event.global_position)
			mouse_is_down = false
			mouse_is_double_click = false

	elif event is InputEventKey and event.pressed:
		# Skip F11 (toggle key)
		if event.keycode == KEY_F11:
			return
		# Skip modifier-only key presses (they'll be captured as modifiers on the actual key)
		if event.keycode in [KEY_CTRL, KEY_SHIFT, KEY_ALT, KEY_META]:
			return
		recorded_events.append({
			"type": "key",
			"keycode": event.keycode,
			"shift": event.shift_pressed,
			"ctrl": event.ctrl_pressed,
			"time": time_offset
		})
		# Mark as recorded to prevent duplicate from fallback detection
		_mark_key_recorded(event.keycode, event.ctrl_pressed, event.shift_pressed)
		var key_name = OS.get_keycode_string(event.keycode)
		var mods = ""
		if event.ctrl_pressed:
			mods += "Ctrl+"
		if event.shift_pressed:
			mods += "Shift+"
		print("[REC] Key: ", mods, key_name)

# ============================================================================
# SCREENSHOT REGION SELECTION
# ============================================================================

func _start_region_selection():
	is_selecting_region = true
	print("[UITestRunner] Draw a rectangle to capture baseline screenshot (ESC to cancel)")

	# Try to pause the game/app
	get_tree().paused = true

	# Create full-screen blocking overlay
	if not selection_overlay:
		selection_overlay = Control.new()
		selection_overlay.name = "SelectionOverlay"
		selection_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
		# MOUSE_FILTER_STOP blocks all input to nodes below
		selection_overlay.mouse_filter = Control.MOUSE_FILTER_STOP
		# Must process even when paused
		selection_overlay.process_mode = Node.PROCESS_MODE_ALWAYS
		add_child(selection_overlay)
		selection_overlay.draw.connect(_draw_selection_overlay)
		selection_overlay.gui_input.connect(_on_overlay_gui_input)

	selection_overlay.visible = true
	selection_rect = Rect2()
	selection_overlay.queue_redraw()

func _handle_selection_input(event: InputEvent):
	# Route to overlay handler - kept for compatibility
	pass

func _on_overlay_gui_input(event: InputEvent):
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			selection_start = event.global_position
			selection_rect = Rect2(selection_start, Vector2.ZERO)
		else:
			# Finished selection
			if selection_rect.size.length() > 10:
				_finish_region_selection()

	elif event is InputEventMouseMotion:
		# Update cursor position for crosshair
		selection_overlay.queue_redraw()

		if Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
			var current = event.global_position
			selection_rect = Rect2(
				Vector2(min(selection_start.x, current.x), min(selection_start.y, current.y)),
				Vector2(abs(current.x - selection_start.x), abs(current.y - selection_start.y))
			)

	elif event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		_cancel_region_selection()

func _draw_selection_overlay():
	var viewport_size = get_viewport().get_visible_rect().size
	var overlay_color = Color(0, 0, 0, 0.6)
	var mouse_pos = selection_overlay.get_local_mouse_position()

	if selection_rect.size.length() > 5:
		# Draw darkened areas around selection (Win11 style)
		selection_overlay.draw_rect(Rect2(0, 0, viewport_size.x, selection_rect.position.y), overlay_color)
		selection_overlay.draw_rect(Rect2(0, selection_rect.end.y, viewport_size.x, viewport_size.y - selection_rect.end.y), overlay_color)
		selection_overlay.draw_rect(Rect2(0, selection_rect.position.y, selection_rect.position.x, selection_rect.size.y), overlay_color)
		selection_overlay.draw_rect(Rect2(selection_rect.end.x, selection_rect.position.y, viewport_size.x - selection_rect.end.x, selection_rect.size.y), overlay_color)

		# Draw selection border (green like Win11)
		selection_overlay.draw_rect(selection_rect, Color(0.2, 0.8, 1.0, 1), false, 2.0)

		# Draw corner handles
		var handle_size = 8.0
		var corners = [
			selection_rect.position,
			Vector2(selection_rect.end.x, selection_rect.position.y),
			selection_rect.end,
			Vector2(selection_rect.position.x, selection_rect.end.y)
		]
		for corner in corners:
			selection_overlay.draw_rect(Rect2(corner - Vector2(handle_size/2, handle_size/2), Vector2(handle_size, handle_size)), Color(0.2, 0.8, 1.0, 1), true)

		# Draw size label
		var size_text = "%d x %d" % [int(selection_rect.size.x), int(selection_rect.size.y)]
		var font = ThemeDB.fallback_font
		var font_size = 14
		var text_pos = Vector2(selection_rect.position.x, selection_rect.position.y - 25)
		if text_pos.y < 30:
			text_pos.y = selection_rect.end.y + 20
		selection_overlay.draw_string(font, text_pos, size_text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, Color.WHITE)
	else:
		# No selection yet - draw full overlay with crosshair
		selection_overlay.draw_rect(Rect2(Vector2.ZERO, viewport_size), overlay_color)

		# Draw crosshair at mouse position
		var crosshair_color = Color(1, 1, 1, 0.8)
		var line_width = 1.0
		# Horizontal line
		selection_overlay.draw_line(Vector2(0, mouse_pos.y), Vector2(viewport_size.x, mouse_pos.y), crosshair_color, line_width)
		# Vertical line
		selection_overlay.draw_line(Vector2(mouse_pos.x, 0), Vector2(mouse_pos.x, viewport_size.y), crosshair_color, line_width)

		# Draw coordinate label near cursor
		var coord_text = "(%d, %d)" % [int(mouse_pos.x), int(mouse_pos.y)]
		var font = ThemeDB.fallback_font
		var font_size = 12
		selection_overlay.draw_string(font, mouse_pos + Vector2(15, -10), coord_text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, Color.WHITE)

	# Draw instructions at top
	var instructions = "Drag to select region  |  ESC to cancel"
	var font = ThemeDB.fallback_font
	var font_size = 16
	var text_width = font.get_string_size(instructions, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x
	var text_pos = Vector2((viewport_size.x - text_width) / 2, 40)

	# Draw background for instructions
	var padding = 10
	var bg_rect = Rect2(text_pos.x - padding, text_pos.y - font_size - padding/2, text_width + padding * 2, font_size + padding)
	selection_overlay.draw_rect(bg_rect, Color(0, 0, 0, 0.8), true, -1, 4.0)
	selection_overlay.draw_string(font, text_pos, instructions, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, Color.WHITE)

func _finish_region_selection():
	# Handle during-recording screenshot capture
	if is_capturing_during_recording:
		_finish_screenshot_capture_during_recording()
		return

	is_selecting_region = false
	selection_overlay.visible = false

	# Unpause the game
	get_tree().paused = false

	if selection_rect.size.x < 10 or selection_rect.size.y < 10:
		print("[UITestRunner] Selection too small, cancelled")
		_generate_test_code(null)
		return

	# Capture screenshot of region (async)
	_capture_and_generate()

func _capture_and_generate():
	var baseline_path = await _capture_baseline_screenshot()
	_generate_test_code(baseline_path)

func _cancel_region_selection():
	# Handle during-recording cancel
	if is_capturing_during_recording:
		is_selecting_region = false
		is_capturing_during_recording = false
		selection_overlay.visible = false
		get_tree().paused = false
		print("[UITestRunner] Screenshot capture cancelled")
		_restore_recording_after_capture()
		return

	is_selecting_region = false
	selection_overlay.visible = false

	# Unpause the game
	get_tree().paused = false

	print("[UITestRunner] Selection cancelled")
	_generate_test_code(null)

func _capture_baseline_screenshot() -> String:
	# Hide ALL UI elements that shouldn't be in screenshot
	virtual_cursor.visible = false
	if recording_indicator:
		recording_indicator.visible = false
	if selection_overlay:
		selection_overlay.visible = false

	# Wait for elements to disappear from render
	await get_tree().process_frame
	await get_tree().process_frame
	await get_tree().process_frame  # Extra frame to ensure overlay is gone

	# Debug: print viewport and selection info
	var viewport_size = get_viewport().get_visible_rect().size
	print("[UITestRunner] Viewport size: ", viewport_size)
	print("[UITestRunner] Selection rect: ", selection_rect)

	var image = get_viewport().get_texture().get_image()

	# Crop to selection region
	var cropped = image.get_region(selection_rect)

	# Generate filename
	var timestamp = Time.get_datetime_string_from_system().replace(":", "-").replace(" ", "_")
	var filename = "baseline_%s.png" % timestamp
	var dir_path = "res://tests/baselines"
	var full_path = "%s/%s" % [dir_path, filename]

	# Ensure directory exists
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir_path))

	# Save image
	cropped.save_png(ProjectSettings.globalize_path(full_path))
	print("[UITestRunner] Baseline saved: ", full_path)
	print("[UITestRunner] Region: ", selection_rect)

	return full_path

func _generate_test_code(baseline_path: Variant):
	# Use re-recording name if set (Update Baseline flow), otherwise generate new name
	var test_name: String
	if rerecording_test_name != "":
		test_name = rerecording_test_name
		rerecording_test_name = ""  # Clear after use
		print("[UITestRunner] Re-recording test: ", test_name)
	else:
		# Generate a friendly unique name
		var existing_tests = _get_saved_tests()
		var counter = 1
		test_name = "New Test %d" % counter
		while test_name.to_snake_case().replace(" ", "_") + ".json" in existing_tests:
			counter += 1
			test_name = "New Test %d" % counter

	# Add default delays to recorded events
	for event in recorded_events:
		if not event.has("wait_after"):
			var event_type = event.get("type", "click")
			event["wait_after"] = DEFAULT_DELAYS.get(event_type, 100)

	# Store pending data and show editor
	pending_baseline_path = baseline_path if baseline_path else ""
	pending_test_name = test_name
	_show_event_editor()

# ============================================================================
# SCREENSHOT VALIDATION
# ============================================================================

enum CompareMode { PIXEL_PERFECT, TOLERANT }

# Default comparison settings
var compare_mode: CompareMode = CompareMode.TOLERANT
var compare_tolerance: float = 0.02  # 2% pixel mismatch allowed
var compare_color_threshold: int = 5  # RGB difference allowed (0-255)

func validate_screenshot(baseline_path: String, region: Rect2) -> bool:
	# Hide UI elements before capturing
	var cursor_was_visible = virtual_cursor.visible
	virtual_cursor.visible = false
	if recording_indicator:
		recording_indicator.visible = false

	# Wait for UI to settle and elements to disappear
	await get_tree().process_frame
	await get_tree().process_frame

	# Debug: print capture info
	var viewport_size = get_viewport().get_visible_rect().size
	print("[UITestRunner] Validation - Viewport: ", viewport_size, " Region: ", region)

	# Capture current region
	var image = get_viewport().get_texture().get_image()
	print("[UITestRunner] Captured image size: ", image.get_size())
	var current = image.get_region(region)
	print("[UITestRunner] Cropped region size: ", current.get_size())

	# Restore cursor visibility
	virtual_cursor.visible = cursor_was_visible

	# Load baseline
	var baseline = Image.load_from_file(ProjectSettings.globalize_path(baseline_path))
	if not baseline:
		push_error("[UITestRunner] Could not load baseline: " + baseline_path)
		return false

	# Size check
	if current.get_size() != baseline.get_size():
		print("[UITestRunner] Size mismatch: ", current.get_size(), " vs ", baseline.get_size())
		_save_debug_screenshot(current, baseline_path)
		return false

	var passed = false
	if compare_mode == CompareMode.PIXEL_PERFECT:
		passed = _compare_pixel_perfect(current, baseline, baseline_path)
	else:
		passed = _compare_tolerant(current, baseline, baseline_path)

	return passed

func _compare_pixel_perfect(current: Image, baseline: Image, baseline_path: String) -> bool:
	print("[UITestRunner] Using PIXEL_PERFECT comparison")
	for y in range(current.get_height()):
		for x in range(current.get_width()):
			if current.get_pixel(x, y) != baseline.get_pixel(x, y):
				print("[UITestRunner] Pixel mismatch at (%d, %d)" % [x, y])
				_save_debug_screenshot(current, baseline_path)
				return false
	print("[UITestRunner] Screenshot matches baseline (pixel perfect)!")
	return true

func _compare_tolerant(current: Image, baseline: Image, baseline_path: String) -> bool:
	print("[UITestRunner] Using TOLERANT comparison (%.1f%% threshold, %d color tolerance)" % [compare_tolerance * 100, compare_color_threshold])
	var total_pixels = current.get_width() * current.get_height()
	var mismatched_pixels = 0

	for y in range(current.get_height()):
		for x in range(current.get_width()):
			var c1 = current.get_pixel(x, y)
			var c2 = baseline.get_pixel(x, y)
			if not _colors_match(c1, c2, compare_color_threshold):
				mismatched_pixels += 1

	var mismatch_ratio = float(mismatched_pixels) / total_pixels
	print("[UITestRunner] Screenshot comparison: %.2f%% pixels differ" % [mismatch_ratio * 100])

	if mismatch_ratio <= compare_tolerance:
		print("[UITestRunner] Screenshot matches baseline!")
		return true
	else:
		print("[UITestRunner] Screenshot FAILED - too many differences")
		_save_debug_screenshot(current, baseline_path)
		return false

func _save_debug_screenshot(current: Image, baseline_path: String):
	var debug_path = baseline_path.replace(".png", "_actual.png")
	current.save_png(ProjectSettings.globalize_path(debug_path))
	print("[UITestRunner] Saved actual screenshot to: ", debug_path)

	# Store paths for later viewing
	last_baseline_path = baseline_path
	last_actual_path = debug_path

	# Only show comparison viewer immediately if not running batch tests
	# During batch runs, users can view diffs from the Results tab after completion
	if not is_batch_running:
		call_deferred("_show_comparison_viewer")

func _colors_match(c1: Color, c2: Color, threshold: int) -> bool:
	var t = threshold / 255.0
	return abs(c1.r - c2.r) <= t and abs(c1.g - c2.g) <= t and abs(c1.b - c2.b) <= t and abs(c1.a - c2.a) <= t

func set_compare_mode(mode: CompareMode):
	compare_mode = mode
	print("[UITestRunner] Compare mode: ", CompareMode.keys()[mode])

func set_tolerant_mode(tolerance: float = 0.02, color_threshold: int = 5):
	compare_mode = CompareMode.TOLERANT
	compare_tolerance = tolerance
	compare_color_threshold = color_threshold
	print("[UITestRunner] Tolerant mode: %.1f%% pixel threshold, %d color threshold" % [tolerance * 100, color_threshold])

# ============================================================================
# CONFIG TAB CALLBACKS
# ============================================================================

func _get_speed_index(speed: Speed) -> int:
	# Map Speed enum to dropdown index
	match speed:
		Speed.INSTANT: return 0
		Speed.FAST: return 1
		Speed.NORMAL: return 2
		Speed.SLOW: return 3
		Speed.STEP: return 4
	return 2  # Default to NORMAL

func _on_speed_selected(index: int):
	var speeds = [Speed.INSTANT, Speed.FAST, Speed.NORMAL, Speed.SLOW, Speed.STEP]
	if index >= 0 and index < speeds.size():
		set_speed(speeds[index])

func _on_compare_mode_selected(index: int):
	compare_mode = index as CompareMode
	print("[UITestRunner] Compare mode: ", CompareMode.keys()[compare_mode])
	_update_tolerance_visibility()

func _on_pixel_tolerance_changed(value: float):
	compare_tolerance = value / 100.0
	_update_pixel_tolerance_label()

func _on_color_threshold_changed(value: float):
	compare_color_threshold = int(value)
	_update_color_threshold_label()

func _update_tolerance_visibility():
	if not test_selector_panel:
		return
	var tolerance_settings = test_selector_panel.get_node_or_null("VBoxContainer/TabContainer/Config/VBoxContainer/ToleranceSettings")
	if not tolerance_settings:
		# Try alternate path (directly under compare section)
		var config_tab = test_selector_panel.get_node_or_null("VBoxContainer/TabContainer/Config")
		if config_tab:
			for child in config_tab.get_children():
				var settings = child.get_node_or_null("ToleranceSettings")
				if settings:
					tolerance_settings = settings
					break
	if tolerance_settings:
		tolerance_settings.visible = (compare_mode == CompareMode.TOLERANT)

func _update_pixel_tolerance_label():
	if not test_selector_panel:
		return
	var label = _find_node_recursive(test_selector_panel, "PixelToleranceValue")
	if label:
		label.text = "%.1f%%" % (compare_tolerance * 100)

func _update_color_threshold_label():
	if not test_selector_panel:
		return
	var label = _find_node_recursive(test_selector_panel, "ColorThresholdValue")
	if label:
		label.text = "%d" % compare_color_threshold

func _find_node_recursive(node: Node, node_name: String) -> Node:
	if node.name == node_name:
		return node
	for child in node.get_children():
		var found = _find_node_recursive(child, node_name)
		if found:
			return found
	return null

# ============================================================================
# COMPARISON VIEWER
# ============================================================================

func _show_comparison_viewer():
	if not comparison_viewer:
		_create_comparison_viewer()

	_update_comparison_images()
	comparison_viewer.visible = true
	get_tree().paused = true

func _close_comparison_viewer():
	if comparison_viewer:
		comparison_viewer.visible = false
	get_tree().paused = false

	# Return to test manager results tab
	_open_test_selector()
	var tabs = test_selector_panel.get_node_or_null("VBoxContainer/TabContainer")
	if tabs:
		tabs.current_tab = 1  # Results tab

func _create_comparison_viewer():
	comparison_viewer = Panel.new()
	comparison_viewer.name = "ComparisonViewer"
	comparison_viewer.process_mode = Node.PROCESS_MODE_ALWAYS
	comparison_viewer.set_anchors_preset(Control.PRESET_FULL_RECT)

	# Dark background
	var style = StyleBoxFlat.new()
	style.bg_color = Color(0.1, 0.1, 0.12, 0.98)
	comparison_viewer.add_theme_stylebox_override("panel", style)

	var vbox = VBoxContainer.new()
	vbox.name = "VBox"
	vbox.set_anchors_preset(Control.PRESET_FULL_RECT)
	vbox.add_theme_constant_override("separation", 10)
	var margin = 20
	vbox.offset_left = margin
	vbox.offset_top = margin
	vbox.offset_right = -margin
	vbox.offset_bottom = -margin
	comparison_viewer.add_child(vbox)

	# Header
	var header = HBoxContainer.new()
	header.add_theme_constant_override("separation", 20)
	vbox.add_child(header)

	var title = Label.new()
	title.text = "Screenshot Comparison - FAILED"
	title.add_theme_font_size_override("font_size", 24)
	title.add_theme_color_override("font_color", Color(1, 0.4, 0.4))
	header.add_child(title)

	var spacer = Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(spacer)

	var close_btn = Button.new()
	close_btn.text = "Close (ESC)"
	close_btn.pressed.connect(_close_comparison_viewer)
	header.add_child(close_btn)

	# Labels row
	var labels_row = HBoxContainer.new()
	labels_row.add_theme_constant_override("separation", 20)
	vbox.add_child(labels_row)

	var baseline_label = Label.new()
	baseline_label.text = "BASELINE (Expected)"
	baseline_label.add_theme_font_size_override("font_size", 16)
	baseline_label.add_theme_color_override("font_color", Color(0.4, 1, 0.4))
	baseline_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	baseline_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	labels_row.add_child(baseline_label)

	var actual_label = Label.new()
	actual_label.text = "ACTUAL (Current)"
	actual_label.add_theme_font_size_override("font_size", 16)
	actual_label.add_theme_color_override("font_color", Color(1, 0.4, 0.4))
	actual_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	actual_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	labels_row.add_child(actual_label)

	var diff_label = Label.new()
	diff_label.text = "DIFF (Red = Different)"
	diff_label.add_theme_font_size_override("font_size", 16)
	diff_label.add_theme_color_override("font_color", Color(1, 0.6, 0.2))
	diff_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	diff_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	labels_row.add_child(diff_label)

	# Images container
	var images_container = HBoxContainer.new()
	images_container.name = "ImagesContainer"
	images_container.add_theme_constant_override("separation", 20)
	images_container.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vbox.add_child(images_container)

	# Baseline image
	var baseline_panel = Panel.new()
	baseline_panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	baseline_panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	var baseline_style = StyleBoxFlat.new()
	baseline_style.bg_color = Color(0.15, 0.2, 0.15)
	baseline_style.set_border_width_all(2)
	baseline_style.border_color = Color(0.4, 1, 0.4, 0.5)
	baseline_panel.add_theme_stylebox_override("panel", baseline_style)
	images_container.add_child(baseline_panel)

	var baseline_texture = TextureRect.new()
	baseline_texture.name = "BaselineTexture"
	baseline_texture.set_anchors_preset(Control.PRESET_FULL_RECT)
	baseline_texture.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	baseline_texture.offset_left = 5
	baseline_texture.offset_top = 5
	baseline_texture.offset_right = -5
	baseline_texture.offset_bottom = -5
	baseline_panel.add_child(baseline_texture)

	# Actual image
	var actual_panel = Panel.new()
	actual_panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	actual_panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	var actual_style = StyleBoxFlat.new()
	actual_style.bg_color = Color(0.2, 0.15, 0.15)
	actual_style.set_border_width_all(2)
	actual_style.border_color = Color(1, 0.4, 0.4, 0.5)
	actual_panel.add_theme_stylebox_override("panel", actual_style)
	images_container.add_child(actual_panel)

	var actual_texture = TextureRect.new()
	actual_texture.name = "ActualTexture"
	actual_texture.set_anchors_preset(Control.PRESET_FULL_RECT)
	actual_texture.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	actual_texture.offset_left = 5
	actual_texture.offset_top = 5
	actual_texture.offset_right = -5
	actual_texture.offset_bottom = -5
	actual_panel.add_child(actual_texture)

	# Diff image
	var diff_panel = Panel.new()
	diff_panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	diff_panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	var diff_style = StyleBoxFlat.new()
	diff_style.bg_color = Color(0.18, 0.15, 0.1)
	diff_style.set_border_width_all(2)
	diff_style.border_color = Color(1, 0.6, 0.2, 0.5)
	diff_panel.add_theme_stylebox_override("panel", diff_style)
	images_container.add_child(diff_panel)

	var diff_texture = TextureRect.new()
	diff_texture.name = "DiffTexture"
	diff_texture.set_anchors_preset(Control.PRESET_FULL_RECT)
	diff_texture.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	diff_texture.offset_left = 5
	diff_texture.offset_top = 5
	diff_texture.offset_right = -5
	diff_texture.offset_bottom = -5
	diff_panel.add_child(diff_texture)

	# Footer with file paths
	var footer = VBoxContainer.new()
	footer.name = "Footer"
	footer.add_theme_constant_override("separation", 5)
	vbox.add_child(footer)

	var baseline_path_label = Label.new()
	baseline_path_label.name = "BaselinePathLabel"
	baseline_path_label.add_theme_font_size_override("font_size", 12)
	baseline_path_label.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6))
	footer.add_child(baseline_path_label)

	var actual_path_label = Label.new()
	actual_path_label.name = "ActualPathLabel"
	actual_path_label.add_theme_font_size_override("font_size", 12)
	actual_path_label.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6))
	footer.add_child(actual_path_label)

	add_child(comparison_viewer)

func _update_comparison_images():
	if not comparison_viewer:
		return

	var vbox = comparison_viewer.get_node("VBox")
	var images_container = vbox.get_node("ImagesContainer")
	var footer = vbox.get_node("Footer")

	# Load baseline image
	var baseline_texture_rect = images_container.get_child(0).get_node("BaselineTexture")
	var baseline_image = Image.load_from_file(ProjectSettings.globalize_path(last_baseline_path))
	if baseline_image:
		var baseline_tex = ImageTexture.create_from_image(baseline_image)
		baseline_texture_rect.texture = baseline_tex

	# Load actual image
	var actual_texture_rect = images_container.get_child(1).get_node("ActualTexture")
	var actual_image = Image.load_from_file(ProjectSettings.globalize_path(last_actual_path))
	if actual_image:
		var actual_tex = ImageTexture.create_from_image(actual_image)
		actual_texture_rect.texture = actual_tex

	# Generate and show diff image
	var diff_texture_rect = images_container.get_child(2).get_node("DiffTexture")
	if baseline_image and actual_image:
		var diff_image = _generate_diff_image(baseline_image, actual_image)
		var diff_tex = ImageTexture.create_from_image(diff_image)
		diff_texture_rect.texture = diff_tex

	# Update path labels
	var baseline_path_label = footer.get_node("BaselinePathLabel")
	var actual_path_label = footer.get_node("ActualPathLabel")
	baseline_path_label.text = "Baseline: " + last_baseline_path
	actual_path_label.text = "Actual: " + last_actual_path

func _generate_diff_image(baseline: Image, actual: Image) -> Image:
	# Create diff image - show actual with red overlay where pixels differ
	var width = min(baseline.get_width(), actual.get_width())
	var height = min(baseline.get_height(), actual.get_height())

	var diff = Image.create(width, height, false, Image.FORMAT_RGBA8)

	for y in range(height):
		for x in range(width):
			var b_pixel = baseline.get_pixel(x, y)
			var a_pixel = actual.get_pixel(x, y)

			if b_pixel == a_pixel:
				# Same - show grayscale version of actual
				var gray = (a_pixel.r + a_pixel.g + a_pixel.b) / 3.0
				diff.set_pixel(x, y, Color(gray * 0.5, gray * 0.5, gray * 0.5, 1.0))
			else:
				# Different - show red tinted overlay
				diff.set_pixel(x, y, Color(1.0, 0.2, 0.2, 1.0))

	return diff

func _comparison_input(event: InputEvent):
	if comparison_viewer and comparison_viewer.visible:
		if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
			_close_comparison_viewer()

# ============================================================================
# EVENT EDITOR (Post-Recording)
# ============================================================================

func _show_event_editor():
	if not event_editor:
		_create_event_editor()

	_populate_event_list()
	event_editor.visible = true
	get_tree().paused = true

func _close_event_editor():
	if event_editor:
		event_editor.visible = false
	get_tree().paused = false

func _create_event_editor():
	event_editor = Panel.new()
	event_editor.name = "EventEditor"
	event_editor.process_mode = Node.PROCESS_MODE_ALWAYS

	var viewport_size = get_viewport().get_visible_rect().size
	var panel_size = Vector2(600, 500)
	event_editor.position = (viewport_size - panel_size) / 2
	event_editor.size = panel_size

	# Style
	var style = StyleBoxFlat.new()
	style.bg_color = Color(0.12, 0.12, 0.15, 0.98)
	style.border_color = Color(0.4, 0.8, 0.4, 1.0)
	style.set_border_width_all(2)
	style.set_corner_radius_all(10)
	event_editor.add_theme_stylebox_override("panel", style)

	var vbox = VBoxContainer.new()
	vbox.name = "VBox"
	vbox.set_anchors_preset(Control.PRESET_FULL_RECT)
	vbox.add_theme_constant_override("separation", 12)
	var margin = 20
	vbox.offset_left = margin
	vbox.offset_top = margin
	vbox.offset_right = -margin
	vbox.offset_bottom = -margin
	event_editor.add_child(vbox)

	# Header
	var header = HBoxContainer.new()
	header.name = "Header"
	header.add_theme_constant_override("separation", 10)
	vbox.add_child(header)

	var title = Label.new()
	title.text = "Edit Test Steps"
	title.add_theme_font_size_override("font_size", 20)
	title.add_theme_color_override("font_color", Color(0.9, 0.9, 0.95))
	header.add_child(title)

	var spacer = Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(spacer)

	# Test name row
	var name_row = HBoxContainer.new()
	name_row.name = "NameRow"
	name_row.add_theme_constant_override("separation", 8)
	vbox.add_child(name_row)

	var name_label = Label.new()
	name_label.text = "Test Name:"
	name_label.add_theme_font_size_override("font_size", 14)
	name_label.add_theme_color_override("font_color", Color(0.7, 0.7, 0.75))
	name_row.add_child(name_label)

	var test_name_input = LineEdit.new()
	test_name_input.name = "TestNameInput"
	test_name_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	test_name_input.placeholder_text = "Enter test name..."
	test_name_input.add_theme_font_size_override("font_size", 14)
	test_name_input.text_changed.connect(_on_test_name_changed)
	name_row.add_child(test_name_input)

	# Instructions
	var instructions = Label.new()
	instructions.text = "Adjust delays after each step. Click [+Wait] to insert wait events."
	instructions.add_theme_font_size_override("font_size", 12)
	instructions.add_theme_color_override("font_color", Color(0.6, 0.6, 0.65))
	vbox.add_child(instructions)

	# Event list scroll container
	var scroll = ScrollContainer.new()
	scroll.name = "EventScroll"
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vbox.add_child(scroll)

	var event_list = VBoxContainer.new()
	event_list.name = "EventList"
	event_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	event_list.add_theme_constant_override("separation", 2)
	scroll.add_child(event_list)

	# Button row
	var btn_row = HBoxContainer.new()
	btn_row.add_theme_constant_override("separation", 10)
	vbox.add_child(btn_row)

	var btn_spacer = Control.new()
	btn_spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	btn_row.add_child(btn_spacer)

	var cancel_btn = Button.new()
	cancel_btn.text = "Cancel"
	cancel_btn.custom_minimum_size = Vector2(100, 36)
	cancel_btn.pressed.connect(_on_event_editor_cancel)
	btn_row.add_child(cancel_btn)

	var save_btn = Button.new()
	save_btn.text = "Save Test"
	save_btn.custom_minimum_size = Vector2(100, 36)
	var save_style = StyleBoxFlat.new()
	save_style.bg_color = Color(0.2, 0.5, 0.3, 0.8)
	save_style.set_corner_radius_all(6)
	save_btn.add_theme_stylebox_override("normal", save_style)
	var save_hover = StyleBoxFlat.new()
	save_hover.bg_color = Color(0.25, 0.6, 0.35, 0.9)
	save_hover.set_corner_radius_all(6)
	save_btn.add_theme_stylebox_override("hover", save_hover)
	save_btn.pressed.connect(_on_event_editor_save)
	btn_row.add_child(save_btn)

	add_child(event_editor)

func _populate_event_list():
	var event_list = event_editor.get_node("VBox/EventScroll/EventList")
	var test_name_input = event_editor.get_node("VBox/NameRow/TestNameInput")

	# Update test name input
	test_name_input.text = pending_test_name

	# Clear existing
	for child in event_list.get_children():
		child.queue_free()

	# Build a map of screenshots by their position (after_event_index)
	var screenshots_by_index: Dictionary = {}
	for screenshot in recorded_screenshots:
		var after_idx = screenshot.get("after_event_index", -1)
		if not screenshots_by_index.has(after_idx):
			screenshots_by_index[after_idx] = []
		screenshots_by_index[after_idx].append(screenshot)

	# Add each event as a row
	for i in range(recorded_events.size()):
		var event = recorded_events[i]
		var row = _create_event_row(i, event)
		event_list.add_child(row)

		# Add screenshot markers after this event if any
		if screenshots_by_index.has(i):
			for screenshot in screenshots_by_index[i]:
				var screenshot_row = _create_screenshot_row(screenshot)
				event_list.add_child(screenshot_row)

		# Add insert button after each event
		var insert_btn = Button.new()
		insert_btn.text = "+ Insert Wait"
		insert_btn.add_theme_font_size_override("font_size", 11)
		insert_btn.add_theme_color_override("font_color", Color(0.5, 0.7, 0.5))
		insert_btn.custom_minimum_size = Vector2(0, 24)
		insert_btn.pressed.connect(_on_insert_wait.bind(i + 1))
		event_list.add_child(insert_btn)

	# Show legacy baseline at the end if no inline screenshots and baseline exists
	if recorded_screenshots.is_empty() and not pending_baseline_path.is_empty():
		var legacy_screenshot = {
			"path": pending_baseline_path,
			"region": pending_baseline_region,
			"after_event_index": recorded_events.size() - 1,
			"is_legacy": true
		}
		var screenshot_row = _create_screenshot_row(legacy_screenshot)
		event_list.add_child(screenshot_row)

func _on_test_name_changed(new_text: String):
	pending_test_name = new_text

func _create_screenshot_row(screenshot: Dictionary) -> Control:
	var panel = PanelContainer.new()
	var panel_style = StyleBoxFlat.new()
	panel_style.bg_color = Color(0.15, 0.25, 0.35, 0.9)  # Blue-ish for screenshots
	panel_style.border_color = Color(0.3, 0.6, 0.8, 0.8)
	panel_style.set_border_width_all(1)
	panel_style.set_corner_radius_all(4)
	panel.add_theme_stylebox_override("panel", panel_style)

	var row = HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	panel.add_child(row)

	# Camera icon
	var icon = Label.new()
	icon.text = "📷"
	icon.add_theme_font_size_override("font_size", 16)
	row.add_child(icon)

	# Screenshot thumbnail (clickable)
	var path = screenshot.get("path", "")
	var region = screenshot.get("region", {})
	var region_text = "%dx%d" % [int(region.get("w", 0)), int(region.get("h", 0))]

	var thumb_container = Control.new()
	thumb_container.custom_minimum_size = Vector2(80, 50)
	thumb_container.mouse_filter = Control.MOUSE_FILTER_STOP
	thumb_container.tooltip_text = "Click to view full size"

	# Load and display thumbnail
	if FileAccess.file_exists(path):
		var image = Image.new()
		var err = image.load(path)
		if err == OK:
			var texture = ImageTexture.create_from_image(image)
			var thumb = TextureRect.new()
			thumb.texture = texture
			thumb.expand_mode = TextureRect.EXPAND_FIT_WIDTH_PROPORTIONAL
			thumb.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
			thumb.custom_minimum_size = Vector2(80, 50)
			thumb.mouse_filter = Control.MOUSE_FILTER_IGNORE
			thumb_container.add_child(thumb)
	else:
		# No image - show placeholder
		var placeholder = Label.new()
		placeholder.text = "[No Image]"
		placeholder.add_theme_font_size_override("font_size", 10)
		placeholder.add_theme_color_override("font_color", Color(0.5, 0.5, 0.6))
		thumb_container.add_child(placeholder)

	# Click handler for thumbnail
	thumb_container.gui_input.connect(_on_screenshot_thumbnail_clicked.bind(path))
	row.add_child(thumb_container)

	# Screenshot label
	var label = Label.new()
	label.text = "Screenshot (%s)" % region_text
	label.add_theme_font_size_override("font_size", 12)
	label.add_theme_color_override("font_color", Color(0.7, 0.85, 1.0))
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(label)

	# View button
	var view_btn = Button.new()
	view_btn.text = "👁"
	view_btn.tooltip_text = "View full size"
	view_btn.custom_minimum_size = Vector2(28, 28)
	view_btn.pressed.connect(_show_screenshot_fullsize.bind(path))
	row.add_child(view_btn)

	# Delete button
	var delete_btn = Button.new()
	delete_btn.text = "✕"
	delete_btn.tooltip_text = "Remove screenshot"
	delete_btn.custom_minimum_size = Vector2(28, 28)
	delete_btn.pressed.connect(_on_delete_screenshot.bind(screenshot))
	row.add_child(delete_btn)

	return panel

func _on_screenshot_thumbnail_clicked(event: InputEvent, image_path: String):
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		_show_screenshot_fullsize(image_path)

func _show_screenshot_fullsize(image_path: String):
	if image_path.is_empty() or not FileAccess.file_exists(image_path):
		print("[UITestRunner] Screenshot not found: %s" % image_path)
		return

	# Create fullsize viewer overlay
	var viewer = Panel.new()
	viewer.name = "ScreenshotViewer"

	var viewer_style = StyleBoxFlat.new()
	viewer_style.bg_color = Color(0.05, 0.05, 0.08, 0.95)
	viewer.add_theme_stylebox_override("panel", viewer_style)

	viewer.set_anchors_preset(Control.PRESET_FULL_RECT)
	viewer.process_mode = Node.PROCESS_MODE_ALWAYS

	var vbox = VBoxContainer.new()
	vbox.set_anchors_preset(Control.PRESET_FULL_RECT)
	vbox.set_offsets_preset(Control.PRESET_FULL_RECT, Control.PRESET_MODE_MINSIZE, 20)
	viewer.add_child(vbox)

	# Header with title and close button
	var header = HBoxContainer.new()
	header.add_theme_constant_override("separation", 10)
	vbox.add_child(header)

	var title = Label.new()
	title.text = "Screenshot: %s" % image_path.get_file()
	title.add_theme_font_size_override("font_size", 16)
	title.add_theme_color_override("font_color", Color(0.9, 0.9, 0.95))
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(title)

	var close_btn = Button.new()
	close_btn.text = "✕ Close"
	close_btn.custom_minimum_size = Vector2(80, 32)
	header.add_child(close_btn)

	# Image container with scroll
	var scroll = ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	vbox.add_child(scroll)

	var center = CenterContainer.new()
	center.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	center.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.add_child(center)

	# Load and display full image
	var image = Image.new()
	var err = image.load(image_path)
	if err == OK:
		var texture = ImageTexture.create_from_image(image)
		var img_rect = TextureRect.new()
		img_rect.texture = texture
		img_rect.stretch_mode = TextureRect.STRETCH_KEEP
		center.add_child(img_rect)
	else:
		var error_label = Label.new()
		error_label.text = "Failed to load image"
		error_label.add_theme_color_override("font_color", Color(1, 0.5, 0.5))
		center.add_child(error_label)

	# Add to CanvasLayer to be on top
	var canvas = CanvasLayer.new()
	canvas.layer = 200
	canvas.add_child(viewer)
	get_tree().root.add_child(canvas)

	# Connect close button
	close_btn.pressed.connect(func(): canvas.queue_free())

	# Close on Escape key
	viewer.gui_input.connect(func(ev):
		if ev is InputEventKey and ev.pressed and ev.keycode == KEY_ESCAPE:
			canvas.queue_free()
	)
	viewer.focus_mode = Control.FOCUS_ALL
	viewer.grab_focus()

func _on_delete_screenshot(screenshot: Dictionary):
	var idx = recorded_screenshots.find(screenshot)
	if idx >= 0:
		recorded_screenshots.remove_at(idx)
		_populate_event_list()

func _create_event_row(index: int, event: Dictionary) -> Control:
	var container = VBoxContainer.new()
	container.add_theme_constant_override("separation", 2)

	# Main row background
	var panel = PanelContainer.new()
	panel.name = "Panel"
	var panel_style = StyleBoxFlat.new()
	panel_style.bg_color = Color(0.18, 0.18, 0.22, 0.8)
	panel_style.set_corner_radius_all(4)
	panel.add_theme_stylebox_override("panel", panel_style)

	var inner_row = HBoxContainer.new()
	inner_row.name = "InnerRow"
	inner_row.add_theme_constant_override("separation", 10)
	panel.add_child(inner_row)

	# Index
	var idx_label = Label.new()
	idx_label.text = "%d." % (index + 1)
	idx_label.custom_minimum_size.x = 30
	idx_label.add_theme_color_override("font_color", Color(0.5, 0.5, 0.55))
	inner_row.add_child(idx_label)

	# Event description
	var desc_label = Label.new()
	desc_label.text = _get_event_description(event)
	desc_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	desc_label.add_theme_color_override("font_color", Color(0.85, 0.85, 0.9))
	inner_row.add_child(desc_label)

	# Delay dropdown
	var delay_label = Label.new()
	delay_label.text = "then wait"
	delay_label.add_theme_color_override("font_color", Color(0.6, 0.6, 0.65))
	inner_row.add_child(delay_label)

	var delay_dropdown = OptionButton.new()
	delay_dropdown.name = "DelayDropdown"
	delay_dropdown.custom_minimum_size.x = 90
	var delays = [0, 50, 100, 250, 500, 1000, 1500, 2000, 3000, 5000]
	var current_delay = event.get("wait_after", 100)
	var selected_idx = 0
	for j in range(delays.size()):
		var d = delays[j]
		if d < 1000:
			delay_dropdown.add_item("%dms" % d, d)
		else:
			delay_dropdown.add_item("%.1fs" % (d / 1000.0), d)
		if d == current_delay:
			selected_idx = j
	delay_dropdown.select(selected_idx)
	delay_dropdown.item_selected.connect(_on_delay_changed.bind(index))
	inner_row.add_child(delay_dropdown)

	# Delete button (for wait events only)
	if event.get("type") == "wait":
		var del_btn = Button.new()
		del_btn.text = "✕"
		del_btn.custom_minimum_size = Vector2(28, 0)
		del_btn.pressed.connect(_on_delete_event.bind(index))
		inner_row.add_child(del_btn)

	container.add_child(panel)
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	# Note row (for adding context like "dragging card to column")
	var note_row = HBoxContainer.new()
	note_row.add_theme_constant_override("separation", 5)

	var note_spacer = Control.new()
	note_spacer.custom_minimum_size.x = 30
	note_row.add_child(note_spacer)

	var note_label = Label.new()
	note_label.text = "📝"
	note_label.add_theme_color_override("font_color", Color(0.5, 0.5, 0.55))
	note_row.add_child(note_label)

	var note_input = LineEdit.new()
	note_input.name = "NoteInput"
	note_input.placeholder_text = "Add note (e.g., 'drag card to column')"
	note_input.text = event.get("note", "")
	note_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	note_input.add_theme_font_size_override("font_size", 12)
	note_input.add_theme_color_override("font_placeholder_color", Color(0.4, 0.4, 0.45))
	note_input.text_changed.connect(_on_note_changed.bind(index))
	note_row.add_child(note_input)

	container.add_child(note_row)

	return container

func _get_event_description(event: Dictionary) -> String:
	var event_type = event.get("type", "unknown")
	match event_type:
		"click":
			var pos = event.get("pos", Vector2.ZERO)
			return "Click at (%d, %d)" % [int(pos.x), int(pos.y)]
		"double_click":
			var pos = event.get("pos", Vector2.ZERO)
			return "Double-click at (%d, %d)" % [int(pos.x), int(pos.y)]
		"drag":
			var from_pos = event.get("from", Vector2.ZERO)
			var to_pos = event.get("to", Vector2.ZERO)
			return "Drag (%d,%d) → (%d,%d)" % [int(from_pos.x), int(from_pos.y), int(to_pos.x), int(to_pos.y)]
		"key":
			var keycode = event.get("keycode", 0)
			var key_str = OS.get_keycode_string(keycode)
			var mods = ""
			if event.get("ctrl", false):
				mods += "Ctrl+"
			if event.get("shift", false):
				mods += "Shift+"
			return "Key: %s%s" % [mods, key_str]
		"wait":
			var duration = event.get("duration", 1000)
			if duration < 1000:
				return "⏱ Wait %dms" % duration
			else:
				return "⏱ Wait %.1fs" % (duration / 1000.0)
		_:
			return "Unknown event"

func _on_delay_changed(dropdown_index: int, event_index: int):
	var event_list = event_editor.get_node("VBox/EventScroll/EventList")
	# Find the container (containers are at even indices, insert buttons at odd)
	var container = event_list.get_child(event_index * 2)
	var dropdown = container.get_node("Panel/InnerRow/DelayDropdown")
	var delay_value = dropdown.get_item_id(dropdown_index)
	recorded_events[event_index]["wait_after"] = delay_value

func _on_note_changed(new_text: String, event_index: int):
	recorded_events[event_index]["note"] = new_text

func _on_insert_wait(after_index: int):
	# Insert a wait event at the specified position
	var wait_event = {
		"type": "wait",
		"duration": 1000,
		"wait_after": 0,
		"time": 0
	}
	recorded_events.insert(after_index, wait_event)
	_populate_event_list()

func _on_delete_event(index: int):
	recorded_events.remove_at(index)
	_populate_event_list()

func _on_event_editor_cancel():
	_close_event_editor()
	recorded_events.clear()
	recorded_screenshots.clear()
	pending_baseline_region = {}
	print("[UITestRunner] Test recording cancelled")
	# Return to Test Manager
	_open_test_selector()

func _on_event_editor_save():
	_close_event_editor()

	# Save test to file
	var saved_path = _save_test(pending_test_name, pending_baseline_path if not pending_baseline_path.is_empty() else null)
	if saved_path:
		print("[UITestRunner] Test saved! Run with F12 to replay.")

	# Print code for reference
	_print_test_code(pending_baseline_path)

	# Open Test Manager after save
	_open_test_selector()

func _print_test_code(baseline_path: String):
	print("\n" + "=".repeat(60))
	print("# GENERATED TEST CODE")
	print("=".repeat(60))
	print("")
	print("func test_recorded():")
	print("\tvar runner = UITestRunner")
	print("\tawait runner.begin_test(\"Recorded Test\")")
	print("")

	for event in recorded_events:
		var wait_after = event.get("wait_after", 100)
		match event.get("type", ""):
			"click":
				print("\tawait runner.click_at(Vector2(%d, %d))" % [event.pos.x, event.pos.y])
			"double_click":
				print("\tawait runner.move_to(Vector2(%d, %d))" % [event.pos.x, event.pos.y])
				print("\tawait runner.double_click()")
			"drag":
				print("\tawait runner.drag(Vector2(%d, %d), Vector2(%d, %d))" % [event.from.x, event.from.y, event.to.x, event.to.y])
			"key":
				var key_str = OS.get_keycode_string(event.keycode)
				if event.get("ctrl", false) or event.get("shift", false):
					print("\tawait runner.press_key(KEY_%s, %s, %s)" % [key_str.to_upper(), event.get("shift", false), event.get("ctrl", false)])
				else:
					print("\tawait runner.press_key(KEY_%s)" % key_str.to_upper())
			"wait":
				var duration = event.get("duration", 1000)
				print("\tawait runner.wait(%.2f)" % (duration / 1000.0))

		if wait_after > 0:
			print("\tawait runner.wait(%.2f)" % (wait_after / 1000.0))

	print("")
	if not baseline_path.is_empty():
		print("\t# Visual validation")
		print("\tvar match = await runner.validate_screenshot(\"%s\", Rect2(%d, %d, %d, %d))" % [
			baseline_path, selection_rect.position.x, selection_rect.position.y, selection_rect.size.x, selection_rect.size.y
		])
		print("\tassert(match, \"Screenshot should match baseline\")")
		print("")

	print("\trunner.end_test(true)")
	print("")
	print("=".repeat(60))
