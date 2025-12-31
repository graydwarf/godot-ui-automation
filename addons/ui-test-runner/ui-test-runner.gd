extends CanvasLayer
class_name UITestRunnerAutoload
## Visual UI Test Runner - Autoload singleton for automated UI testing
## Provides tweened mouse simulation with visible cursor feedback

# Import shared utilities
const Utils = preload("res://addons/ui-test-runner/utils.gd")
const FileIO = preload("res://addons/ui-test-runner/file-io.gd")
const CategoryManager = preload("res://addons/ui-test-runner/category-manager.gd")
const ScreenshotValidator = preload("res://addons/ui-test-runner/screenshot-validator.gd")
const PlaybackEngine = preload("res://addons/ui-test-runner/playback-engine.gd")
const RecordingEngine = preload("res://addons/ui-test-runner/recording-engine.gd")
const RegionSelector = preload("res://addons/ui-test-runner/region-selector.gd")
const TestExecutor = preload("res://addons/ui-test-runner/test-executor.gd")
const ComparisonViewer = preload("res://addons/ui-test-runner/ui/comparison-viewer.gd")
const EventEditor = preload("res://addons/ui-test-runner/ui/event-editor.gd")
const TestManager = preload("res://addons/ui-test-runner/ui/test-manager.gd")
const Speed = Utils.Speed
const CompareMode = Utils.CompareMode
const SPEED_MULTIPLIERS = Utils.SPEED_MULTIPLIERS
const DEFAULT_DELAYS = Utils.DEFAULT_DELAYS
const TESTS_DIR = Utils.TESTS_DIR
const CATEGORIES_FILE = Utils.CATEGORIES_FILE

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

var virtual_cursor: Node2D
var current_test_name: String = ""

# Playback engine instance (uses const type to avoid class_name resolution issues)
var _playback: PlaybackEngine

# Recording engine instance
var _recording: RecordingEngine

# Region selector instance
var _region_selector: RegionSelector

# Test executor instance
var _executor: TestExecutor

# UI components
var _comparison_viewer: ComparisonViewer
var _event_editor: EventEditor
var _test_manager: TestManager

# Reference to main viewport for coordinate conversion
var main_viewport: Viewport

# Recording state (delegated to _recording engine)
var is_recording: bool:
	get: return _recording.is_recording if _recording else false
	set(value): if _recording: _recording.is_recording = value

var is_recording_paused: bool:
	get: return _recording.is_recording_paused if _recording else false
	set(value): if _recording: _recording.is_recording_paused = value

var recorded_events: Array[Dictionary]:
	get: return _recording.recorded_events if _recording else []

var recorded_screenshots: Array[Dictionary]:
	get: return _recording.recorded_screenshots if _recording else []

# Legacy mouse state for compatibility (still used in some places)
var last_mouse_pos: Vector2 = Vector2.ZERO

# Screenshot selection state (delegates to _region_selector)
var is_selecting_region: bool:
	get: return _region_selector.is_selecting if _region_selector else false
	set(value): if _region_selector: _region_selector.is_selecting = value

var selection_rect: Rect2:
	get: return _region_selector.selection_rect if _region_selector else Rect2()

# Business logic flags for during-recording capture (remain in main file)
var is_capturing_during_recording: bool = false  # True when capturing mid-recording
var was_paused_before_capture: bool = false  # To restore pause state after capture

# Test files (constants imported from Utils)
var test_selector_panel: Control = null
var is_selector_open: bool = false

# Batch test execution
var batch_results: Array[Dictionary] = []  # [{name, passed, baseline_path, actual_path}]
var is_batch_running: bool = false

# Re-recording state (for Update Baseline)
var rerecording_test_name: String = ""  # When non-empty, save will overwrite this test

# Recording indicator and HUD (now managed by _recording engine)
# Kept for backwards compatibility with any code referencing these
var recording_indicator: Control:
	get: return _recording._recording_indicator if _recording else null

# Comparison viewer
var comparison_viewer: Control = null
var last_baseline_path: String = ""
var last_actual_path: String = ""

# Event editor (post-recording)
var pending_baseline_path: String = ""
var pending_baseline_region: Dictionary = {}  # For legacy tests with baseline_region
var pending_test_name: String = ""
var pending_screenshots: Array[Dictionary] = []  # Screenshots for editing (independent of recording engine)

func _ready():
	main_viewport = get_viewport()
	layer = 100  # Above everything
	process_mode = Node.PROCESS_MODE_ALWAYS  # Work even when paused
	_setup_virtual_cursor()
	_setup_playback_engine()
	_setup_recording_engine()
	_setup_region_selector()
	_setup_test_executor()
	_setup_comparison_viewer()
	_setup_event_editor()
	_setup_test_manager()
	ScreenshotValidator.load_config()
	# Apply loaded playback speed
	_playback.set_speed(ScreenshotValidator.playback_speed as Speed)
	print("[UITestRunner] Ready - F9: demo | F10: speed | F11: record | F12: Test Manager")

func _setup_playback_engine():
	_playback = PlaybackEngine.new()
	_playback.initialize(get_tree(), main_viewport, virtual_cursor)
	_playback.action_performed.connect(_on_playback_action_performed)

func _on_playback_action_performed(action: String, details: Dictionary):
	action_performed.emit(action, details)

func _setup_recording_engine():
	_recording = RecordingEngine.new()
	_recording.initialize(get_tree(), self)
	_recording.recording_started.connect(_on_recording_started)
	_recording.recording_stopped.connect(_on_recording_stopped)
	_recording.screenshot_capture_requested.connect(_on_screenshot_capture_requested)

func _setup_region_selector():
	_region_selector = RegionSelector.new()
	_region_selector.initialize(get_tree(), self)
	_region_selector.selection_completed.connect(_on_region_selection_completed)
	_region_selector.selection_cancelled.connect(_on_region_selection_cancelled)

func _setup_test_executor():
	_executor = TestExecutor.new()
	_executor.initialize(get_tree(), _playback, virtual_cursor, self)
	_executor.test_started.connect(_on_executor_test_started)
	_executor.test_completed.connect(_on_executor_test_completed)
	_executor.test_result_ready.connect(_on_executor_test_result)

func _on_executor_test_started(test_name: String):
	current_test_name = test_name
	test_mode_active = true
	test_mode_changed.emit(true)
	test_started.emit(test_name)

func _on_executor_test_completed(test_name: String, passed: bool):
	test_mode_active = false
	test_mode_changed.emit(false)
	test_completed.emit(test_name, passed)
	current_test_name = ""

func _on_executor_test_result(result: Dictionary):
	# Store result and show panel (unless in batch mode)
	if not is_batch_running:
		batch_results.clear()
		batch_results.append(result)
		_show_results_panel()

func _setup_comparison_viewer():
	_comparison_viewer = ComparisonViewer.new()
	_comparison_viewer.initialize(get_tree(), self)
	_comparison_viewer.closed.connect(_on_comparison_viewer_closed)

func _on_comparison_viewer_closed():
	# Return to test manager results tab
	_open_test_selector()
	var tabs = test_selector_panel.get_node_or_null("VBoxContainer/TabContainer")
	if tabs:
		tabs.current_tab = 1  # Results tab

func _setup_event_editor():
	_event_editor = EventEditor.new()
	_event_editor.initialize(get_tree(), self)
	_event_editor.cancelled.connect(_on_event_editor_cancelled)
	_event_editor.save_requested.connect(_on_event_editor_save_requested)

func _on_event_editor_cancelled():
	# Return to Test Manager
	_open_test_selector()

func _on_event_editor_save_requested(test_name: String):
	# Save test to file
	var saved_path = _save_test(test_name, pending_baseline_path if not pending_baseline_path.is_empty() else null)
	if saved_path:
		print("[UITestRunner] Test saved! Run with F12 to replay.")

	# Print code for reference
	_event_editor.print_test_code()

	# Open Test Manager after save
	_open_test_selector()

func _setup_test_manager():
	_test_manager = TestManager.new()
	_test_manager.initialize(get_tree(), self)
	_test_manager.test_selected.connect(_on_manager_test_selected)
	_test_manager.test_run_requested.connect(_on_manager_test_run)
	_test_manager.test_delete_requested.connect(_on_delete_test)
	_test_manager.test_rename_requested.connect(_on_rename_test)
	_test_manager.test_edit_requested.connect(_on_edit_test)
	_test_manager.test_update_baseline_requested.connect(_on_update_baseline)
	_test_manager.record_new_requested.connect(_on_record_new_test)
	_test_manager.run_all_requested.connect(_run_all_tests)
	_test_manager.category_play_requested.connect(_on_play_category)
	_test_manager.results_clear_requested.connect(_clear_results_history)
	_test_manager.view_failed_step_requested.connect(_on_view_failed_step)
	_test_manager.view_diff_requested.connect(_view_failed_test_diff)
	_test_manager.closed.connect(_on_test_manager_closed)

func _on_manager_test_selected(test_name: String):
	_on_test_selected(test_name)

func _on_manager_test_run(test_name: String):
	_run_test_from_file(test_name)

func _on_test_manager_closed():
	is_selector_open = false

func _on_region_selection_completed(rect: Rect2):
	# Handle during-recording screenshot capture
	if is_capturing_during_recording:
		_finish_screenshot_capture_during_recording()
	else:
		# Normal selection - capture and generate test code
		_on_normal_selection_completed()

func _on_region_selection_cancelled():
	# Handle during-recording cancel
	if is_capturing_during_recording:
		is_capturing_during_recording = false
		print("[UITestRunner] Screenshot capture cancelled")
		_restore_recording_after_capture()
	else:
		print("[UITestRunner] Selection cancelled")
		_generate_test_code(null)

func _on_normal_selection_completed():
	if selection_rect.size.x < 10 or selection_rect.size.y < 10:
		print("[UITestRunner] Selection too small, cancelled")
		_generate_test_code(null)
		return
	# Capture screenshot of region (async)
	_capture_and_generate()

func _on_recording_started():
	test_mode_active = true
	get_tree().set_meta("automation_is_recording", true)
	test_mode_changed.emit(true)
	if rerecording_test_name != "":
		print("[UITestRunner] === RE-RECORDING '%s' === (F11 to stop)" % rerecording_test_name)
	else:
		print("[UITestRunner] === RECORDING STARTED === (F11 to stop)")

func _on_recording_stopped(event_count: int, screenshot_count: int):
	test_mode_active = false
	get_tree().set_meta("automation_is_recording", false)
	test_mode_changed.emit(false)
	print("[UITestRunner] === RECORDING STOPPED === (%d events, %d screenshots)" % [event_count, screenshot_count])

	# If screenshots were captured during recording, skip the final region selection
	if _recording.recorded_screenshots.is_empty():
		_start_region_selection()
	else:
		# Generate test name and show editor (pass null for baseline since screenshots exist)
		_generate_test_code(null)

func _on_screenshot_capture_requested():
	_capture_screenshot_during_recording()

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
	if is_recording and _recording:
		if event is InputEventMouseButton:
			print("[REC-INPUT] MouseButton pressed=%s at %s" % [event.pressed, event.global_position])
			_recording.capture_event(event)
		elif event is InputEventKey and event.pressed:
			print("[REC-INPUT] Key keycode=%d (%s) ctrl=%s shift=%s" % [event.keycode, OS.get_keycode_string(event.keycode), event.ctrl_pressed, event.shift_pressed])
			if _recording.capture_key_event(event):
				_mark_key_recorded(event.keycode, event.ctrl_pressed, event.shift_pressed)

# Track keys for fallback detection (keys consumed before _input)
var _last_key_state: Dictionary = {}

func _process(_delta):
	# Fallback mouse UP detection for recording - catches events missed by _input()
	if is_recording and _recording:
		_recording.check_missed_mouse_up(get_viewport())

	# Fallback key detection for recording - catches keys consumed by other handlers
	if is_recording:
		_check_fallback_keys()

# Common keys to monitor for fallback detection (keys often consumed by apps)
const FALLBACK_KEYS = [KEY_Z, KEY_Y, KEY_X, KEY_C, KEY_V, KEY_A, KEY_S, KEY_DELETE, KEY_BACKSPACE, KEY_ENTER, KEY_ESCAPE]

func _check_fallback_keys():
	if not _recording:
		return

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
				var time_offset = (Time.get_ticks_msec() - _recording.record_start_time) if _recording.record_start_time > 0 else 0
				_recording.recorded_events.append({
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
	# Note: Region selection input is handled by region selector's overlay

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
# PLAYBACK ENGINE DELEGATES - Forward to UIPlaybackEngine
# ============================================================================

# Property accessors for playback engine state
var is_running: bool:
	get: return _playback.is_running if _playback else false
	set(value): if _playback: _playback.is_running = value

var current_speed: Speed:
	get: return _playback.current_speed if _playback else Speed.NORMAL
	set(value): if _playback: _playback.current_speed = value

var action_log: Array[Dictionary]:
	get: return _playback.action_log if _playback else []

# Speed control
func set_speed(speed: Speed) -> void:
	_playback.set_speed(speed)
	ScreenshotValidator.playback_speed = speed as int
	ScreenshotValidator.save_config()

func cycle_speed() -> void:
	_playback.cycle_speed()
	ScreenshotValidator.playback_speed = _playback.current_speed as int
	ScreenshotValidator.save_config()

func get_delay_multiplier() -> float:
	return _playback.get_delay_multiplier()

# Coordinate conversion
func world_to_screen(world_pos: Vector2) -> Vector2:
	return _playback.world_to_screen(world_pos)

func screen_to_world(screen_pos: Vector2) -> Vector2:
	return _playback.screen_to_world(screen_pos)

func get_screen_pos(node: CanvasItem) -> Vector2:
	return _playback.get_screen_pos(node)

# Mouse actions
func move_to(pos: Vector2, duration: float = 0.3) -> void:
	await _playback.move_to(pos, duration)

func click() -> void:
	await _playback.click()

func click_at(pos: Vector2) -> void:
	await _playback.click_at(pos)

func drag_to(to: Vector2, duration: float = 0.5, hold_at_end: float = 0.0) -> void:
	await _playback.drag_to(to, duration, hold_at_end)

func drag(from: Vector2, to: Vector2, duration: float = 0.5, hold_at_end: float = 0.0) -> void:
	await _playback.drag(from, to, duration, hold_at_end)

func drag_node(node: CanvasItem, offset: Vector2, duration: float = 0.5) -> void:
	await _playback.drag_node(node, offset, duration)

func click_node(node: CanvasItem) -> void:
	await _playback.click_node(node)

func right_click() -> void:
	await _playback.right_click()

func double_click() -> void:
	await _playback.double_click()

# Keyboard actions
func press_key(keycode: int, shift: bool = false, ctrl: bool = false) -> void:
	await _playback.press_key(keycode, shift, ctrl)

func type_text(text: String, delay_per_char: float = 0.05) -> void:
	await _playback.type_text(text, delay_per_char)

# Wait
func wait(seconds: float, apply_speed_multiplier: bool = true) -> void:
	await _playback.wait(seconds, apply_speed_multiplier)

# ============================================================================
# TEST STRUCTURE
# ============================================================================

func begin_test(test_name: String) -> void:
	current_test_name = test_name
	_playback.is_running = true
	test_mode_active = true
	test_mode_changed.emit(true)
	_playback.clear_action_log()
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
	_playback.is_running = false
	test_mode_active = false
	test_mode_changed.emit(false)
	test_completed.emit(current_test_name, passed)
	current_test_name = ""

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
# RECORDING - Delegates to RecordingEngine
# ============================================================================

func _toggle_recording():
	if is_recording:
		_recording.stop_recording()
	else:
		_recording.start_recording()

func _toggle_recording_pause():
	_recording.toggle_pause()

func _capture_screenshot_during_recording():
	if not is_recording or not _recording:
		return

	# Temporarily pause to allow region selection without capturing events
	var was_paused = is_recording_paused
	is_recording_paused = true

	# Hide recording indicator temporarily for clean screenshot
	_recording.set_indicator_visible(false)

	# Start region selection for this screenshot
	_start_screenshot_capture_region(was_paused)

func _start_screenshot_capture_region(was_paused: bool):
	# Set business logic flags before starting selection
	is_capturing_during_recording = true
	was_paused_before_capture = was_paused
	# Delegate to region selector
	_region_selector.start_selection()

func _finish_screenshot_capture_during_recording():
	# Region selector already hid overlay and unpaused, just reset flags
	is_capturing_during_recording = false

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

	# Store screenshot info via recording engine
	_recording.add_screenshot_record(full_path, {
		"x": selection_rect.position.x,
		"y": selection_rect.position.y,
		"w": selection_rect.size.x,
		"h": selection_rect.size.y
	})

	_restore_recording_after_capture()

func _restore_recording_after_capture():
	# Restore recording indicator
	if _recording:
		_recording.set_indicator_visible(true)

	# Restore pause state
	is_recording_paused = was_paused_before_capture

	print("[UITestRunner] === Recording resumed ===")

func _is_click_on_recording_hud(pos: Vector2) -> bool:
	if not _recording:
		return false
	return _recording.is_click_on_hud(pos)

# ============================================================================
# TEST FILE MANAGEMENT
# ============================================================================

func _save_test(test_name: String, baseline_path: Variant) -> String:
	print("[UITestRunner] Saving test with %d recorded events" % recorded_events.size())

	# Convert events to JSON-serializable format (Vector2 -> dict)
	var serializable_events = _serialize_events(recorded_events)

	# Store viewport size for coordinate scaling during playback
	var viewport_size = get_viewport().get_visible_rect().size

	# Store window state for restoration during playback
	var window_mode = DisplayServer.window_get_mode()
	var window_pos = DisplayServer.window_get_position()
	var window_size = DisplayServer.window_get_size()

	# Build test data with support for multiple screenshots
	var test_data = {
		"name": test_name,
		"created": Time.get_datetime_string_from_system(),
		"recorded_viewport": {"w": viewport_size.x, "h": viewport_size.y},
		"recorded_window": {
			"mode": window_mode,
			"x": window_pos.x,
			"y": window_pos.y,
			"w": window_size.x,
			"h": window_size.y
		},
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
		"screenshots": pending_screenshots.duplicate()
	}

	var filename = test_name.to_snake_case().replace(" ", "_") + ".json"
	return FileIO.save_test_data(filename, test_data)

# Converts recorded events to JSON-serializable format
func _serialize_events(events: Array) -> Array:
	var serializable_events = []
	for event in events:
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
	return serializable_events

func _load_test(filepath: String) -> Dictionary:
	return FileIO.load_test(filepath)

func _get_saved_tests() -> Array:
	return FileIO.get_saved_tests()

# Category management delegated to CategoryManager
func _load_categories():
	CategoryManager.load_categories()

func _save_categories():
	CategoryManager.save_categories()

func _get_all_categories() -> Array:
	return CategoryManager.get_all_categories()

func _set_test_category(test_name: String, category: String, insert_index: int = -1):
	CategoryManager.set_test_category(test_name, category, insert_index)

func _get_ordered_tests(category_name: String, tests: Array) -> Array:
	return CategoryManager.get_ordered_tests(category_name, tests)

func _run_test_from_file(test_name: String):
	# Delegate to TestExecutor
	_executor.run_test_from_file(test_name)

# ============================================================================
# TEST SELECTOR PANEL
# ============================================================================

func _toggle_test_selector():
	_test_manager.toggle()
	is_selector_open = _test_manager.is_open
	# Keep test_selector_panel in sync for backward compatibility
	test_selector_panel = _test_manager.get_panel()

func _open_test_selector():
	if is_running:
		print("[UITestRunner] Cannot open selector - test running")
		return

	_test_manager.batch_results = batch_results
	_test_manager.open()
	is_selector_open = true
	# Keep test_selector_panel in sync for backward compatibility
	test_selector_panel = _test_manager.get_panel()

func _close_test_selector():
	_test_manager.close()
	is_selector_open = false


func _clear_results_history():
	batch_results.clear()
	_update_results_tab()

func _on_record_new_test():
	_close_test_selector()
	# Small delay to let panel close, then start recording
	await get_tree().create_timer(0.1).timeout
	_recording.start_recording()

func _refresh_test_list():
	_test_manager.refresh_test_list()

func _on_play_category(category_name: String):
	# Get all tests in this category (only those that exist on disk)
	var saved_tests = _get_saved_tests()
	var tests_in_category: Array = []
	for test_name in CategoryManager.test_categories.keys():
		if CategoryManager.test_categories[test_name] == category_name:
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
	FileIO.delete_file_and_import(file_path)

func _on_rename_test(test_name: String):
	rename_target_test = test_name
	# Load test data to get the actual display name (preserves casing)
	var filepath = TESTS_DIR + "/" + test_name + ".json"
	var test_data = _load_test(filepath)
	var display_name = _get_display_name(test_data, test_name)
	_show_rename_dialog(display_name)

# Returns a friendly display name from test data, with smart fallback for old sanitized names
func _get_display_name(test_data: Dictionary, fallback_filename: String) -> String:
	return Utils.get_display_name(test_data, fallback_filename)

func _show_rename_dialog(display_name: String):
	if not rename_dialog:
		_create_rename_dialog()

	# Hide test selector so it doesn't block the rename dialog
	if test_selector_panel:
		test_selector_panel.visible = false

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
	# Restore test selector panel
	if test_selector_panel:
		test_selector_panel.visible = true

func _on_rename_submitted(_text: String):
	_do_rename()

func _sanitize_filename(text: String) -> String:
	return Utils.sanitize_filename(text)

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
	var old_category = CategoryManager.test_categories.get(rename_target_test, "")
	if old_category:
		CategoryManager.test_categories.erase(rename_target_test)
		CategoryManager.test_categories[new_filename] = old_category

		# Update order within category
		if CategoryManager.category_test_order.has(old_category):
			var order = CategoryManager.category_test_order[old_category]
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
	_recording.start_recording()

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
	pending_screenshots.clear()
	for screenshot in test_data.get("screenshots", []):
		pending_screenshots.append(screenshot.duplicate())
	print("[UITestRunner] Loaded %d screenshots for editing" % pending_screenshots.size())

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
				await wait(duration_ms / 1000.0, false)  # Explicit waits ignore speed setting

		# Apply wait_after delay (user-configured, not affected by speed)
		if wait_after_ms > 0:
			await wait(wait_after_ms / 1000.0, false)

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
	_region_selector.hide_overlay()

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
	# Delegate to TestExecutor
	return await _executor.run_test_and_get_result(test_name)

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
	_test_manager.batch_results = batch_results
	_test_manager.update_results_tab()

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
	pending_screenshots.clear()
	for screenshot in test_data.get("screenshots", []):
		pending_screenshots.append(screenshot.duplicate())

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
	_event_editor.highlight_failed_step(step_index)

func _view_failed_test_diff(result: Dictionary):
	last_baseline_path = result.baseline_path
	last_actual_path = result.actual_path
	_close_results_panel()
	_show_comparison_viewer()

# ============================================================================
# SCREENSHOT REGION SELECTION
# ============================================================================

func _start_region_selection():
	# Delegate to region selector (handles overlay, pause, and input)
	_region_selector.start_selection()

func _capture_and_generate():
	var baseline_path = await _capture_baseline_screenshot()
	_generate_test_code(baseline_path)

func _capture_baseline_screenshot() -> String:
	# Hide ALL UI elements that shouldn't be in screenshot
	virtual_cursor.visible = false
	if recording_indicator:
		recording_indicator.visible = false
	_region_selector.hide_overlay()

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
		# existing_tests returns filenames without .json, so don't add it
		while test_name.to_snake_case().replace(" ", "_") in existing_tests:
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

	# Copy screenshots from recording engine to pending array
	pending_screenshots.clear()
	for screenshot in recorded_screenshots:
		pending_screenshots.append(screenshot.duplicate())
	print("[UITestRunner] Prepared %d screenshots for editing" % pending_screenshots.size())

	_show_event_editor()

# ============================================================================
# SCREENSHOT VALIDATION
# ============================================================================

# Comparison settings delegated to ScreenshotValidator
# Access via: ScreenshotValidator.compare_mode, ScreenshotValidator.compare_tolerance, etc.

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

	# Use ScreenshotValidator for comparison
	var result = ScreenshotValidator.compare_images(current, baseline)
	print("[UITestRunner] ", result.message)

	if not result.passed:
		_save_debug_screenshot(current, baseline_path)

	return result.passed

func _save_debug_screenshot(current: Image, baseline_path: String):
	var debug_path = ScreenshotValidator.save_debug_screenshot(current, baseline_path)

	# Store paths for later viewing
	last_baseline_path = baseline_path
	last_actual_path = debug_path

	# Only show comparison viewer immediately if not running batch tests
	if not is_batch_running:
		call_deferred("_show_comparison_viewer")

func set_compare_mode(mode: CompareMode):
	ScreenshotValidator.set_compare_mode(mode)

func set_tolerant_mode(tolerance: float = 0.02, color_threshold: int = 5):
	ScreenshotValidator.set_tolerant_mode(tolerance, color_threshold)

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
	ScreenshotValidator.compare_mode = index as CompareMode
	print("[UITestRunner] Compare mode: ", CompareMode.keys()[ScreenshotValidator.compare_mode])
	_update_tolerance_visibility()
	ScreenshotValidator.save_config()

func _on_pixel_tolerance_changed(value: float):
	ScreenshotValidator.compare_tolerance = value / 100.0
	_update_pixel_tolerance_label()
	ScreenshotValidator.save_config()

func _on_color_threshold_changed(value: float):
	ScreenshotValidator.compare_color_threshold = int(value)
	_update_color_threshold_label()
	ScreenshotValidator.save_config()

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
		tolerance_settings.visible = (ScreenshotValidator.compare_mode == CompareMode.TOLERANT)

func _update_pixel_tolerance_label():
	if not test_selector_panel:
		return
	var label = _find_node_recursive(test_selector_panel, "PixelToleranceValue")
	if label:
		label.text = "%.1f%%" % (ScreenshotValidator.compare_tolerance * 100)

func _update_color_threshold_label():
	if not test_selector_panel:
		return
	var label = _find_node_recursive(test_selector_panel, "ColorThresholdValue")
	if label:
		label.text = "%d" % ScreenshotValidator.compare_color_threshold

func _find_node_recursive(node: Node, node_name: String) -> Node:
	return Utils.find_node_recursive(node, node_name)

# ============================================================================
# COMPARISON VIEWER (delegated to ComparisonViewer)
# ============================================================================

func _show_comparison_viewer():
	_comparison_viewer.show_comparison(last_baseline_path, last_actual_path)

func _close_comparison_viewer():
	_comparison_viewer.close()

func _comparison_input(event: InputEvent):
	if _comparison_viewer.is_visible():
		if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
			_close_comparison_viewer()

# ============================================================================
# EVENT EDITOR (delegated to EventEditor)
# ============================================================================

func _show_event_editor():
	# Transfer state to event editor module
	_event_editor.recorded_events = recorded_events.duplicate()
	_event_editor.pending_screenshots = pending_screenshots.duplicate()
	_event_editor.pending_test_name = pending_test_name
	_event_editor.pending_baseline_path = pending_baseline_path
	_event_editor.pending_baseline_region = pending_baseline_region.duplicate()
	_event_editor.selection_rect = selection_rect
	_event_editor.show_editor()

func _close_event_editor():
	_event_editor.close()
