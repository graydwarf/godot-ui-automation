# =============================================================================
# Godot UI Automation - Visual UI Automation Testing for Godot
# =============================================================================
# MIT License - Copyright (c) 2025 Poplava
#
# Support & Community:
#   Discord: https://discord.gg/9GnrTKXGfq
#   GitHub:  https://github.com/graydwarf/godot-ui-automation
#   More Tools: https://poplava.itch.io
# =============================================================================

extends RefCounted
## Handles test playback and validation for Godot UI Automation

const Utils = preload("res://addons/godot-ui-automation/utils/utils.gd")
const FileIO = preload("res://addons/godot-ui-automation/utils/file-io.gd")
const ScreenshotValidator = preload("res://addons/godot-ui-automation/utils/screenshot-validator.gd")
const DEFAULT_DELAYS = Utils.DEFAULT_DELAYS
const TESTS_DIR = Utils.TESTS_DIR

signal test_started(test_name: String)
signal test_completed(test_name: String, passed: bool)
signal test_result_ready(result: Dictionary)
signal action_performed(action: String, details: Dictionary)
signal step_changed(step_index: int, total_steps: int, event: Dictionary)
signal paused_changed(is_paused: bool)
signal position_debug(debug_info: Dictionary)  # Emits position debug data for HUD

var current_test_name: String = ""
var last_position_debug: Dictionary = {}  # Stores last position debug info
var is_running: bool = false
var _cancelled: bool = false  # Set to true to cancel current test
var _restart_requested: bool = false  # Set to true to restart from step 0

# Breakpoint and stepping state
var is_paused: bool = false
var step_mode: bool = false  # When true, pause after each step
var breakpoints: Array[int] = []  # Step indices where we should pause (0-based)
var current_step: int = -1
var total_steps: int = 0
var _step_signal: bool = false  # Set to true to advance one step when paused
var _current_events: Array[Dictionary] = []  # Store events for step info

# External dependencies (set via initialize)
var _tree: SceneTree
var _playback  # PlaybackEngine instance
var _virtual_cursor: Node2D
var _main_runner  # Reference to main UITestRunnerAutoload for state access

func initialize(tree: SceneTree, playback, virtual_cursor: Node2D, main_runner) -> void:
	_tree = tree
	_playback = playback
	_virtual_cursor = virtual_cursor
	_main_runner = main_runner

# Test lifecycle
func begin_test(test_name: String) -> void:
	current_test_name = test_name
	is_running = true
	_cancelled = false
	_playback.is_running = true
	_playback.is_cancelled = false
	_playback.clear_action_log()
	_virtual_cursor.visible = true
	_virtual_cursor.show_cursor()
	# Hide real mouse cursor during automation
	Input.set_mouse_mode(Input.MOUSE_MODE_HIDDEN)
	test_started.emit(test_name)
	print("[TestExecutor] === BEGIN: ", test_name, " ===")
	await _tree.process_frame

func end_test(passed: bool = true) -> void:
	var result = "PASSED" if passed else "FAILED"
	print("[TestExecutor] === END: ", current_test_name, " - ", result, " ===")
	print("[TestExecutor] Step mode: %s" % ("ON" if step_mode else "OFF"))
	_virtual_cursor.hide_cursor()
	# Restore mouse cursor
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
	# Clear any stuck modifier key states from scroll/zoom simulation
	_clear_modifier_states()
	_playback.is_running = false
	is_running = false
	test_completed.emit(current_test_name, passed)
	current_test_name = ""

# Clears stuck input states that can occur from Input.parse_input_event()
func _clear_modifier_states() -> void:
	# Release any stuck modifier keys
	for keycode in [KEY_CTRL, KEY_SHIFT, KEY_ALT, KEY_META]:
		var release = InputEventKey.new()
		release.keycode = keycode
		release.pressed = false
		Input.parse_input_event(release)
	Input.flush_buffered_events()

# Cancel the currently running test
func cancel_test() -> void:
	if is_running:
		print("[TestExecutor] Test cancelled by user")
		_cancelled = true
		_playback.is_cancelled = true

# Restart the test from step 0 without exiting debug mode
func restart_from_beginning() -> void:
	if is_running:
		print("[TestExecutor] Restarting test from beginning")
		_restart_requested = true
		# Unpause to allow the loop to process the restart
		if is_paused:
			is_paused = false

# ============================================================================
# BREAKPOINT AND STEPPING CONTROLS
# ============================================================================

# Toggle breakpoint at step index (0-based)
func toggle_breakpoint(step_index: int) -> bool:
	if step_index in breakpoints:
		breakpoints.erase(step_index)
		print("[TestExecutor] Breakpoint removed at step %d" % (step_index + 1))
		return false
	else:
		breakpoints.append(step_index)
		print("[TestExecutor] Breakpoint set at step %d" % (step_index + 1))
		return true

func clear_breakpoints() -> void:
	breakpoints.clear()
	print("[TestExecutor] All breakpoints cleared")

func has_breakpoint(step_index: int) -> bool:
	return step_index in breakpoints

# Enable/disable step mode (pause after each step)
func set_step_mode(enabled: bool) -> void:
	step_mode = enabled
	print("[TestExecutor] Step mode: %s" % ("ON" if enabled else "OFF"))

# Pause execution at current step
func pause() -> void:
	if is_running and not is_paused:
		is_paused = true
		paused_changed.emit(true)
		print("[TestExecutor] Paused at step %d/%d" % [current_step + 1, total_steps])

# Resume execution (continue until next breakpoint or end)
func resume() -> void:
	if is_running and is_paused:
		step_mode = false
		is_paused = false
		paused_changed.emit(false)
		print("[TestExecutor] Resumed")

# Unpause without disabling step_mode (used for continue-to-end with auto-play)
func unpause() -> void:
	if is_running and is_paused:
		is_paused = false
		paused_changed.emit(false)
		print("[TestExecutor] Unpaused (step_mode still active)")

# Execute single step then pause
func step_forward() -> void:
	if is_running and is_paused:
		_step_signal = true
		print("[TestExecutor] Stepping to next action")

# Get current event info for UI display
func get_current_event() -> Dictionary:
	if current_step >= 0 and current_step < _current_events.size():
		return _current_events[current_step]
	return {}

# Get event description for display
func get_event_description(event: Dictionary) -> String:
	var event_type = event.get("type", "")
	match event_type:
		"click":
			return "Click at %s" % event.get("pos", Vector2.ZERO)
		"double_click":
			return "Double-click at %s" % event.get("pos", Vector2.ZERO)
		"drag":
			var obj_type = event.get("object_type", "")
			var no_drop = event.get("no_drop", false)
			var suffix = " (no drop)" if no_drop else ""
			if obj_type:
				return "Drag %s %s->%s%s" % [obj_type, event.get("from", Vector2.ZERO), event.get("to", Vector2.ZERO), suffix]
			return "Drag %s->%s%s" % [event.get("from", Vector2.ZERO), event.get("to", Vector2.ZERO), suffix]
		"pan":
			return "Pan %s->%s" % [event.get("from", Vector2.ZERO), event.get("to", Vector2.ZERO)]
		"right_click":
			return "Right-click at %s" % event.get("pos", Vector2.ZERO)
		"scroll":
			var dir = event.get("direction", "in")
			var mods = ""
			if event.get("ctrl", false): mods += "Ctrl+"
			if event.get("shift", false): mods += "Shift+"
			if event.get("alt", false): mods += "Alt+"
			return "%sScroll %s at %s" % [mods, dir, event.get("pos", Vector2.ZERO)]
		"key":
			var mods = ""
			if event.get("ctrl", false): mods += "Ctrl+"
			if event.get("shift", false): mods += "Shift+"
			return "Key %s%s" % [mods, OS.get_keycode_string(event.get("keycode", 0))]
		"wait":
			return "Wait %.1fs" % (event.get("duration", 1000) / 1000.0)
		"set_clipboard_image":
			return "Set clipboard image"
		"screenshot_validation":
			var path = event.get("path", "")
			var filename = path.get_file() if path else "unknown"
			return "📷 Validate Screenshot (%s)" % filename
	return "Unknown"

# Run a saved test from file (non-blocking, emits test_result_ready when done)
func run_test_from_file(test_name: String) -> void:
	var filepath = TESTS_DIR + "/" + test_name + ".json"
	var test_data = FileIO.load_test(filepath)
	if test_data.is_empty():
		return

	# Convert JSON events to runtime format
	var recorded_events = _convert_events_from_json(test_data.get("events", []))

	# Backward compatibility: convert old screenshots array to screenshot_validation events
	var screenshots = test_data.get("screenshots", [])
	if not screenshots.is_empty():
		recorded_events = _inject_screenshot_events(recorded_events, screenshots)

	print("[TestExecutor] Loaded %d events from file" % recorded_events.size())

	# Defer start to next frame
	_run_replay_with_validation.call_deferred(test_data, recorded_events, test_name)

# Run a saved test and return result (for batch execution)
func run_test_and_get_result(test_name: String) -> Dictionary:
	var filepath = TESTS_DIR + "/" + test_name + ".json"
	var test_data = FileIO.load_test(filepath)

	var result = {
		"name": test_name,
		"passed": false,
		"baseline_path": "",
		"actual_path": "",
		"failed_step": -1
	}

	if test_data.is_empty():
		return result

	# Convert JSON events to runtime format
	var recorded_events = _convert_events_from_json(test_data.get("events", []))

	# Backward compatibility: convert old screenshots array to screenshot_validation events
	var screenshots = test_data.get("screenshots", [])
	if not screenshots.is_empty():
		recorded_events = _inject_screenshot_events(recorded_events, screenshots)

	print("[TestExecutor] Loaded %d events from file" % recorded_events.size())

	# Run and return result directly (awaitable)
	return await _run_replay_internal(test_data, recorded_events, test_name)

# Backward compatibility: inject screenshot_validation events from old screenshots array
func _inject_screenshot_events(events: Array[Dictionary], screenshots: Array) -> Array[Dictionary]:
	# Sort screenshots by after_event_index in descending order to insert from end
	var sorted_screenshots = screenshots.duplicate()
	sorted_screenshots.sort_custom(func(a, b): return int(a.get("after_event_index", -1)) > int(b.get("after_event_index", -1)))

	for screenshot in sorted_screenshots:
		var after_idx = int(screenshot.get("after_event_index", -1))
		if after_idx >= 0 and after_idx < events.size():
			var validation_event: Dictionary = {
				"type": "screenshot_validation",
				"path": screenshot.get("path", ""),
				"region": screenshot.get("region", {}),
				"time": screenshot.get("time", 0),
				"wait_after": 100
			}
			# Insert after the specified event index
			events.insert(after_idx + 1, validation_event)
			print("[TestExecutor] Injected screenshot_validation after step %d (backward compat)" % (after_idx + 1))

	return events

# Helper to convert position from either Dictionary (JSON) or Vector2 (in-memory) to Vector2
func _to_vector2(value, default := Vector2.ZERO) -> Vector2:
	if value is Vector2:
		return value
	elif value is Dictionary:
		return Vector2(value.get("x", 0), value.get("y", 0))
	return default

# Helper to convert position to Vector2i
func _to_vector2i(value, default := Vector2i.ZERO) -> Vector2i:
	if value is Vector2i:
		return value
	elif value is Vector2:
		return Vector2i(int(value.x), int(value.y))
	elif value is Dictionary:
		return Vector2i(int(value.get("x", 0)), int(value.get("y", 0)))
	return default

func _convert_events_from_json(events: Array) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for event in events:
		var event_type = event.get("type", "")
		var converted_event = {"type": event_type, "time": event.get("time", 0)}

		match event_type:
			"click", "double_click":
				converted_event["pos"] = _to_vector2(event.get("pos", {}))
				converted_event["ctrl"] = event.get("ctrl", false)
				converted_event["shift"] = event.get("shift", false)
			"drag":
				converted_event["from"] = _to_vector2(event.get("from", {}))
				converted_event["to"] = _to_vector2(event.get("to", {}))
				# Modifier keys for multi-select drag
				converted_event["ctrl"] = event.get("ctrl", false)
				converted_event["shift"] = event.get("shift", false)
				# no_drop flag for drag segments (Ctrl+B during recording)
				converted_event["no_drop"] = event.get("no_drop", false)
				# World coordinates for precise resolution-independent playback
				var to_world = event.get("to_world", null)
				if to_world != null:
					converted_event["to_world"] = _to_vector2(to_world)
				# Cell coordinates for grid-snapped playback (fallback)
				var to_cell = event.get("to_cell", null)
				if to_cell != null:
					converted_event["to_cell"] = _to_vector2i(to_cell)
				# Object-relative info for robust playback
				var object_type = event.get("object_type", "")
				if not object_type.is_empty():
					converted_event["object_type"] = object_type
					converted_event["object_id"] = event.get("object_id", "")
					converted_event["click_offset"] = _to_vector2(event.get("click_offset", {}))
			"pan":
				converted_event["from"] = _to_vector2(event.get("from", {}))
				converted_event["to"] = _to_vector2(event.get("to", {}))
			"right_click":
				converted_event["pos"] = _to_vector2(event.get("pos", {}))
			"scroll":
				converted_event["direction"] = event.get("direction", "in")
				converted_event["ctrl"] = event.get("ctrl", false)
				converted_event["shift"] = event.get("shift", false)
				converted_event["alt"] = event.get("alt", false)
				converted_event["factor"] = event.get("factor", 1.0)
				converted_event["pos"] = _to_vector2(event.get("pos", {}))
			"key":
				converted_event["keycode"] = event.get("keycode", 0)
				converted_event["shift"] = event.get("shift", false)
				converted_event["ctrl"] = event.get("ctrl", false)
				if event.has("mouse_pos"):
					converted_event["mouse_pos"] = event.get("mouse_pos")
			"wait":
				converted_event["duration"] = event.get("duration", 1000)
			"set_clipboard_image":
				converted_event["path"] = event.get("path", "")
				if event.has("mouse_pos"):
					converted_event["mouse_pos"] = event.get("mouse_pos")
			"screenshot_validation":
				converted_event["path"] = event.get("path", "")
				var region = event.get("region", {})
				converted_event["region"] = region

		var default_wait = DEFAULT_DELAYS.get(event_type, 100)
		converted_event["wait_after"] = event.get("wait_after", default_wait)
		# Preserve note field if present
		if event.has("note"):
			converted_event["note"] = event.get("note", "")
		result.append(converted_event)

	return result

# Called via call_deferred, emits signal when done
func _run_replay_with_validation(test_data: Dictionary, recorded_events: Array[Dictionary], file_test_name: String = "") -> void:
	var result = await _run_replay_internal(test_data, recorded_events, file_test_name)
	test_result_ready.emit(result)

# Core replay logic - returns result dictionary (used by both deferred and batch)
func _run_replay_internal(test_data: Dictionary, recorded_events: Array[Dictionary], file_test_name: String = "") -> Dictionary:
	var display_name = test_data.get("name", "Replay")
	var result_name = file_test_name if not file_test_name.is_empty() else display_name

	# Initialize step tracking BEFORE begin_test so events are available when test_started emits
	_current_events = recorded_events
	total_steps = recorded_events.size()
	current_step = -1
	is_paused = false
	_step_signal = false

	await begin_test(display_name)

	# Store original window state
	var original_window = _store_window_state()

	# Execute setup actions (e.g., maximize window) BEFORE environment check
	await _execute_setup(test_data)

	# Restore recorded window state (for legacy tests without setup section)
	await _restore_recorded_window(test_data.get("recorded_window", {}))

	# Calculate viewport scaling
	var scale = _calculate_viewport_scale(test_data)

	var passed = true
	var baseline_path = ""
	var actual_path = ""
	var failed_step_index: int = -1

	print("[TestExecutor] Replaying %d events (step_mode=%s)..." % [recorded_events.size(), step_mode])

	# Outer loop to support restart functionality
	while true:
		# If this is a restart (not first run), emit test_started to clear board
		if _restart_requested:
			print("[TestExecutor] Restarting - emitting test_started to clear board")
			test_started.emit(display_name)
			await _tree.process_frame

		_restart_requested = false
		var should_break_outer = false

		for i in range(recorded_events.size()):
			# Bounds check - steps may have been deleted while paused
			if i >= recorded_events.size():
				break
			current_step = i
			var event = recorded_events[i]

			# Emit step changed for UI (use current size, not cached total_steps)
			step_changed.emit(i, recorded_events.size(), event)

			# Check for breakpoint or step mode BEFORE executing
			# Skip pause if step is marked as auto-play
			var should_auto_play = _main_runner and _main_runner.should_auto_play_step(i)
			if (has_breakpoint(i) or step_mode) and not should_auto_play:
				is_paused = true
				paused_changed.emit(true)
				var bp_msg = " (breakpoint)" if has_breakpoint(i) else ""
				print("[TestExecutor] Paused before step %d/%d%s: %s" % [i + 1, total_steps, bp_msg, get_event_description(event)])

			# Wait while paused (check for step, resume, cancel, or restart)
			while is_paused and not _cancelled and not _restart_requested:
				await _tree.process_frame
				if _step_signal:
					_step_signal = false
					break  # Execute this one step, then re-pause after

			# Check for restart request - break inner loop to restart from beginning
			if _restart_requested:
				print("[TestExecutor] Restart requested - returning to step 1")
				current_step = -1
				is_paused = false
				break  # Break inner for loop, continue outer while loop

			# Check for cancellation
			if _cancelled:
				passed = false
				print("[TestExecutor] Test cancelled at step %d" % (i + 1))
				should_break_outer = true
				break

			await _execute_event(event, i, scale)

			# Re-pause after step if in step mode (unless next step is auto-play)
			# Only pause if there's actually a next step - don't pause after final step
			if i + 1 < recorded_events.size():
				var next_step_auto_play = _main_runner and _main_runner.should_auto_play_step(i + 1)
				if step_mode and not _cancelled and not _restart_requested:
					if next_step_auto_play:
						# Clear pause state so next step executes automatically
						is_paused = false
						paused_changed.emit(false)
					else:
						is_paused = true
						paused_changed.emit(true)

			# Check for restart after event execution
			if _restart_requested:
				print("[TestExecutor] Restart requested after step - returning to step 1")
				current_step = -1
				is_paused = false
				break

			# Check for cancellation after event execution
			if _cancelled:
				passed = false
				print("[TestExecutor] Test cancelled at step %d" % (i + 1))
				should_break_outer = true
				break

			# Check if screenshot_validation step failed
			if event.get("_validation_failed", false):
				passed = false
				baseline_path = event.get("_baseline_path", "")
				actual_path = event.get("_actual_path", "")
				failed_step_index = i + 1
				should_break_outer = true
				break

			if not passed:
				should_break_outer = true
				break

		# If we completed the loop without restart, break outer loop
		if not _restart_requested:
			break
		# Otherwise continue outer loop (restart from step 0)

	# Check legacy single baseline at end (skip if cancelled)
	if not _cancelled and test_data.get("screenshots", []).is_empty() and passed:
		await _playback.wait(0.3, true)
		var legacy = await _validate_legacy_baseline(test_data, scale, recorded_events.size())
		passed = legacy.passed
		baseline_path = legacy.baseline_path
		actual_path = legacy.actual_path
		if not passed:
			failed_step_index = recorded_events.size()

	var was_cancelled = _cancelled
	end_test(passed)
	if was_cancelled:
		print("[TestExecutor] Replay cancelled by user")
	else:
		print("[TestExecutor] Replay complete - ", "PASSED" if passed else "FAILED")

	# Window restoration disabled - keep app in fullscreen/maximized state
	# await _restore_window_state(original_window, not test_data.get("recorded_window", {}).is_empty())

	return {
		"name": result_name,
		"passed": passed,
		"cancelled": was_cancelled,
		"baseline_path": baseline_path,
		"actual_path": actual_path,
		"failed_step": failed_step_index
	}

func _store_window_state() -> Dictionary:
	return {
		"mode": DisplayServer.window_get_mode(),
		"pos": DisplayServer.window_get_position(),
		"size": DisplayServer.window_get_size()
	}

func _restore_recorded_window(recorded_window: Dictionary) -> void:
	if recorded_window.is_empty():
		return

	var target_mode = recorded_window.get("mode", DisplayServer.WINDOW_MODE_WINDOWED)

	if target_mode == DisplayServer.WINDOW_MODE_WINDOWED:
		if DisplayServer.window_get_mode() != DisplayServer.WINDOW_MODE_WINDOWED:
			DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
			await _tree.process_frame

		var target_size = Vector2i(recorded_window.get("w", 1280), recorded_window.get("h", 720))
		DisplayServer.window_set_size(target_size)
		# Don't change window position - coordinates are viewport-relative
		print("[TestExecutor] Restored window: windowed %dx%d" % [target_size.x, target_size.y])
	elif target_mode == DisplayServer.WINDOW_MODE_MAXIMIZED:
		if DisplayServer.window_get_mode() != DisplayServer.WINDOW_MODE_MAXIMIZED:
			DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_MAXIMIZED)
			print("[TestExecutor] Restored window: maximized")
		else:
			print("[TestExecutor] Window already maximized, skipping restore")
	elif target_mode == DisplayServer.WINDOW_MODE_FULLSCREEN:
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN)
		print("[TestExecutor] Restored window: fullscreen")

	await _tree.process_frame
	await _tree.process_frame

func _restore_window_state(original: Dictionary, was_changed: bool) -> void:
	if not was_changed:
		return

	if original.mode == DisplayServer.WINDOW_MODE_WINDOWED:
		if DisplayServer.window_get_mode() != DisplayServer.WINDOW_MODE_WINDOWED:
			DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
			await _tree.process_frame
		DisplayServer.window_set_size(original.size)
		# Don't restore position - we never changed it
	else:
		DisplayServer.window_set_mode(original.mode)
	print("[TestExecutor] Restored original window state")

func _calculate_viewport_scale(test_data: Dictionary) -> Vector2:
	var current_viewport = _main_runner.get_viewport().get_visible_rect().size
	var recorded_viewport_data = test_data.get("recorded_viewport", {})
	var recorded_viewport = Vector2(
		recorded_viewport_data.get("w", current_viewport.x),
		recorded_viewport_data.get("h", current_viewport.y)
	)
	var scale = Vector2(
		current_viewport.x / recorded_viewport.x,
		current_viewport.y / recorded_viewport.y
	)

	if scale.x != 1.0 or scale.y != 1.0:
		print("[TestExecutor] Viewport scaling: recorded %s -> current %s (scale: %.2f, %.2f)" % [
			recorded_viewport, current_viewport, scale.x, scale.y
		])

	return scale

# Public function to check environment match for a test (used by UI to show warnings)
func check_environment_match(test_data: Dictionary) -> Dictionary:
	return _check_environment_match(test_data)

# Check if current environment matches the recorded environment
func _check_environment_match(test_data: Dictionary) -> Dictionary:
	var recorded_env = test_data.get("recorded_environment", {})

	# Get current environment
	var screen_idx = DisplayServer.window_get_current_screen()
	var screen_size = DisplayServer.screen_get_size(screen_idx)
	var viewport_size = _main_runner.get_viewport().get_visible_rect().size

	var current_env = {
		"monitor_index": screen_idx,
		"monitor_resolution": {"w": screen_size.x, "h": screen_size.y},
		"viewport": {"w": viewport_size.x, "h": viewport_size.y}
	}

	# No recorded environment = unknown (legacy test)
	if recorded_env.is_empty():
		return {
			"status": "unknown",
			"matches": true,  # Don't block legacy tests
			"message": "Legacy test - no environment info recorded",
			"current": current_env,
			"recorded": {}
		}

	# Compare viewport sizes
	var recorded_viewport = recorded_env.get("viewport", {})
	var viewport_matches = (
		int(viewport_size.x) == int(recorded_viewport.get("w", 0)) and
		int(viewport_size.y) == int(recorded_viewport.get("h", 0))
	)

	# Compare monitor resolution
	var recorded_monitor = recorded_env.get("monitor_resolution", {})
	var monitor_matches = (
		int(screen_size.x) == int(recorded_monitor.get("w", 0)) and
		int(screen_size.y) == int(recorded_monitor.get("h", 0))
	)

	var matches = viewport_matches and monitor_matches
	var message = ""
	if not matches:
		var parts = []
		if not viewport_matches:
			parts.append("viewport %dx%d != recorded %dx%d" % [
				int(viewport_size.x), int(viewport_size.y),
				int(recorded_viewport.get("w", 0)), int(recorded_viewport.get("h", 0))
			])
		if not monitor_matches:
			parts.append("monitor %dx%d != recorded %dx%d" % [
				int(screen_size.x), int(screen_size.y),
				int(recorded_monitor.get("w", 0)), int(recorded_monitor.get("h", 0))
			])
		message = "Environment mismatch: " + ", ".join(parts)

	return {
		"status": "match" if matches else "mismatch",
		"matches": matches,
		"message": message,
		"current": current_env,
		"recorded": recorded_env
	}

# Execute setup actions before test playback
func _execute_setup(test_data: Dictionary) -> void:
	var setup = test_data.get("setup", {})
	if setup.is_empty():
		return

	print("[TestExecutor] Executing setup actions...")

	if setup.get("maximize_window", false):
		if DisplayServer.window_get_mode() != DisplayServer.WINDOW_MODE_MAXIMIZED:
			DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_MAXIMIZED)
			print("[TestExecutor] Setup: Maximized window")
			await _tree.process_frame
			await _tree.process_frame
		else:
			print("[TestExecutor] Setup: Window already maximized")

func _execute_event(event: Dictionary, index: int, scale: Vector2) -> void:
	var event_type = event.get("type", "")
	var wait_after_ms = event.get("wait_after", 100)

	match event_type:
		"click":
			var pos = event.get("pos", Vector2.ZERO)
			var scaled_pos = Vector2(pos.x * scale.x, pos.y * scale.y)
			var ctrl = event.get("ctrl", false)
			var shift = event.get("shift", false)
			last_position_debug = {
				"type": "click",
				"recorded": pos,
				"scaled": scaled_pos,
				"actual": scaled_pos,
				"ctrl": ctrl,
				"shift": shift
			}
			position_debug.emit(last_position_debug)
			var mods = ("Ctrl+" if ctrl else "") + ("Shift+" if shift else "")
			print("[REPLAY] Step %d: %sClick at %s (scaled: %s)" % [index + 1, mods, pos, scaled_pos])
			await _playback.click_at(scaled_pos, ctrl, shift)
		"double_click":
			var pos = event.get("pos", Vector2.ZERO)
			var scaled_pos = Vector2(pos.x * scale.x, pos.y * scale.y)
			var ctrl = event.get("ctrl", false)
			var shift = event.get("shift", false)
			last_position_debug = {
				"type": "double_click",
				"recorded": pos,
				"scaled": scaled_pos,
				"actual": scaled_pos,
				"ctrl": ctrl,
				"shift": shift
			}
			position_debug.emit(last_position_debug)
			var mods = ("Ctrl+" if ctrl else "") + ("Shift+" if shift else "")
			print("[REPLAY] Step %d: %sDouble-click at %s (scaled: %s)" % [index + 1, mods, pos, scaled_pos])
			await _playback.move_to(scaled_pos)
			await _playback.double_click(ctrl, shift)
		"drag":
			var from_pos = event.get("from", Vector2.ZERO)
			var to_pos = event.get("to", Vector2.ZERO)
			var scaled_from = Vector2(from_pos.x * scale.x, from_pos.y * scale.y)
			var scaled_to = Vector2(to_pos.x * scale.x, to_pos.y * scale.y)
			var hold_time = 0.1  # Fixed hold time at end of drag before release
			var delta = scaled_to - scaled_from
			var no_drop = event.get("no_drop", false)
			var drag_ctrl = event.get("ctrl", false)
			var drag_shift = event.get("shift", false)

			# Object-relative coordinate adjustment for robust playback
			var object_type = event.get("object_type", "")
			var object_id = event.get("object_id", "")
			if not object_type.is_empty() and not object_id.is_empty():
				var current_pos = _main_runner.get_item_screen_pos_by_id(object_type, object_id)
				if current_pos != Vector2.ZERO:
					# Object found - adjust coordinates based on its current position
					var click_offset = event.get("click_offset", Vector2.ZERO)
					var adjusted_from = current_pos + click_offset
					var adjusted_to = adjusted_from + delta  # Preserve the movement delta
					last_position_debug = {
						"type": "drag",
						"mode": "object-relative",
						"recorded_from": from_pos,
						"recorded_to": to_pos,
						"scaled_from": scaled_from,
						"scaled_to": scaled_to,
						"object_type": object_type,
						"object_id": object_id,
						"object_screen_pos": current_pos,
						"click_offset": click_offset,
						"delta": delta,
						"actual_from": adjusted_from,
						"actual_to": adjusted_to,
						"no_drop": no_drop
					}
					position_debug.emit(last_position_debug)
					var no_drop_label = " (no drop)" if no_drop else ""
					var mods_label = ("Ctrl+" if drag_ctrl else "") + ("Shift+" if drag_shift else "")
					print("[REPLAY] Step %d: %sDrag%s (object-relative) %s id=%s" % [index + 1, mods_label, no_drop_label, object_type, object_id])
					print("  Object at: %s, click_offset: %s" % [current_pos, click_offset])
					print("  Adjusted: %s->%s (original: %s->%s)" % [adjusted_from, adjusted_to, scaled_from, scaled_to])
					if no_drop:
						await _playback.drag_segment(adjusted_from, adjusted_to, 0.5, drag_ctrl, drag_shift)
					else:
						await _playback.drag(adjusted_from, adjusted_to, 0.5, hold_time, drag_ctrl, drag_shift)
				else:
					# Object not found - fall back to absolute coordinates
					last_position_debug = {
						"type": "drag",
						"mode": "absolute-fallback",
						"recorded_from": from_pos,
						"recorded_to": to_pos,
						"object_type": object_type,
						"object_id": object_id,
						"object_not_found": true,
						"actual_from": scaled_from,
						"actual_to": scaled_to,
						"no_drop": no_drop
					}
					position_debug.emit(last_position_debug)
					var no_drop_label = " (no drop)" if no_drop else ""
					var mods_label = ("Ctrl+" if drag_ctrl else "") + ("Shift+" if drag_shift else "")
					print("[REPLAY] Step %d: %sDrag%s %s->%s (object %s:%s not found, using absolute)" % [
						index + 1, mods_label, no_drop_label, from_pos, to_pos, object_type, object_id])
					if no_drop:
						await _playback.drag_segment(scaled_from, scaled_to, 0.5, drag_ctrl, drag_shift)
					else:
						await _playback.drag(scaled_from, scaled_to, 0.5, hold_time, drag_ctrl, drag_shift)
			else:
				# No object info - check for world/cell coordinates (toolbar drags, etc.)
				var to_world = event.get("to_world", null)
				var to_cell = event.get("to_cell", null)
				var actual_to = scaled_to
				var actual_from = scaled_from  # Default to scaled
				var mode = "absolute"

				if to_world != null and to_world is Vector2:
					# Use world coordinates for precise resolution-independent playback
					# When to_world is present, the drag started from a fixed UI element (toolbar)
					# So DON'T scale the from position - it's at a fixed screen location
					actual_from = from_pos
					actual_to = _main_runner.world_to_screen(to_world)
					mode = "world-coords"
					var no_drop_label = " (no drop)" if no_drop else ""
					var mods_label = ("Ctrl+" if drag_ctrl else "") + ("Shift+" if drag_shift else "")
					print("[REPLAY] Step %d: %sDrag%s (world-coords) from=%s (fixed UI), to_world=%s -> screen=%s" % [
						index + 1, mods_label, no_drop_label, actual_from, to_world, actual_to
					])
				elif to_cell != null and to_cell is Vector2i:
					# Fallback to cell coordinates for grid-snapped playback
					actual_to = _main_runner.cell_to_screen(to_cell)
					mode = "cell-coords"
					var no_drop_label = " (no drop)" if no_drop else ""
					var mods_label = ("Ctrl+" if drag_ctrl else "") + ("Shift+" if drag_shift else "")
					print("[REPLAY] Step %d: %sDrag%s (cell-coords) to_cell=(%d, %d) -> screen=%s" % [
						index + 1, mods_label, no_drop_label, to_cell.x, to_cell.y, actual_to
					])
				else:
					var no_drop_label = " (no drop)" if no_drop else ""
					var mods_label = ("Ctrl+" if drag_ctrl else "") + ("Shift+" if drag_shift else "")
					print("[REPLAY] Step %d: %sDrag%s %s->%s (scaled: %s->%s, delta: %s, hold %.1fs)" % [
						index + 1, mods_label, no_drop_label, from_pos, to_pos, scaled_from, scaled_to, delta, hold_time
					])

				last_position_debug = {
					"type": "drag",
					"mode": mode,
					"recorded_from": from_pos,
					"recorded_to": to_pos,
					"scaled_from": scaled_from,
					"scaled_to": scaled_to,
					"delta": delta,
					"actual_from": actual_from,
					"actual_to": actual_to,
					"no_drop": no_drop
				}
				if to_world != null:
					last_position_debug["to_world"] = to_world
				if to_cell != null:
					last_position_debug["to_cell"] = to_cell
				position_debug.emit(last_position_debug)
				if no_drop:
					await _playback.drag_segment(actual_from, actual_to, 0.5, drag_ctrl, drag_shift)
				else:
					await _playback.drag(actual_from, actual_to, 0.5, hold_time, drag_ctrl, drag_shift)
		"pan":
			var from_pos = event.get("from", Vector2.ZERO)
			var to_pos = event.get("to", Vector2.ZERO)
			var scaled_from = Vector2(from_pos.x * scale.x, from_pos.y * scale.y)
			var scaled_to = Vector2(to_pos.x * scale.x, to_pos.y * scale.y)
			last_position_debug = {
				"type": "pan",
				"recorded_from": from_pos,
				"recorded_to": to_pos,
				"actual_from": scaled_from,
				"actual_to": scaled_to
			}
			position_debug.emit(last_position_debug)
			print("[REPLAY] Step %d: Pan %s->%s (scaled: %s->%s)" % [index + 1, from_pos, to_pos, scaled_from, scaled_to])
			await _playback.pan(scaled_from, scaled_to)
		"right_click":
			var pos = event.get("pos", Vector2.ZERO)
			var scaled_pos = Vector2(pos.x * scale.x, pos.y * scale.y)
			last_position_debug = {
				"type": "right_click",
				"recorded": pos,
				"actual": scaled_pos
			}
			position_debug.emit(last_position_debug)
			print("[REPLAY] Step %d: Right-click at %s (scaled: %s)" % [index + 1, pos, scaled_pos])
			await _playback.move_to(scaled_pos)
			await _playback.right_click()
		"scroll":
			var direction = event.get("direction", "in")
			var ctrl = event.get("ctrl", false)
			var shift = event.get("shift", false)
			var alt = event.get("alt", false)
			var factor = event.get("factor", 1.0)
			var pos = event.get("pos", Vector2.ZERO)
			var scaled_pos = Vector2(pos.x * scale.x, pos.y * scale.y)
			last_position_debug = {
				"type": "scroll",
				"direction": direction,
				"ctrl": ctrl,
				"shift": shift,
				"alt": alt,
				"factor": factor,
				"recorded_pos": pos,
				"actual_pos": scaled_pos
			}
			position_debug.emit(last_position_debug)
			var mods = ""
			if ctrl: mods += "Ctrl+"
			if shift: mods += "Shift+"
			if alt: mods += "Alt+"
			print("[REPLAY] Step %d: %sScroll %s at %s (scaled: %s, factor: %.2f)" % [index + 1, mods, direction, pos, scaled_pos, factor])
			await _playback.scroll(scaled_pos, direction, ctrl, shift, alt, factor)
		"key":
			var keycode = event.get("keycode", 0)
			var mods = ""
			if event.get("ctrl", false):
				mods += "Ctrl+"
			if event.get("shift", false):
				mods += "Shift+"
			var key_mouse_pos = event.get("mouse_pos", null)
			print("[REPLAY] Step %d: Key %s%s" % [index + 1, mods, OS.get_keycode_string(keycode)])
			await _playback.press_key(keycode, event.get("shift", false), event.get("ctrl", false), key_mouse_pos)
		"wait":
			var duration_ms = event.get("duration", 1000)
			print("[REPLAY] Step %d: Wait %.1fs" % [index + 1, duration_ms / 1000.0])
			await _playback.wait(duration_ms / 1000.0, false)
		"set_clipboard_image":
			var image_path = event.get("path", "")
			var paste_pos = event.get("mouse_pos", null)
			print("[REPLAY] Step %d: Set clipboard image: %s" % [index + 1, image_path])
			await _playback.set_clipboard_image(image_path, paste_pos)
		"screenshot_validation":
			var screenshot_path = event.get("path", "")
			var screenshot_region = event.get("region", {})
			print("[REPLAY] Step %d: Validating screenshot: %s" % [index + 1, screenshot_path.get_file()])
			print("[REPLAY] Original region: x=%s y=%s w=%s h=%s" % [
				screenshot_region.get("x", 0), screenshot_region.get("y", 0),
				screenshot_region.get("w", 0), screenshot_region.get("h", 0)])
			print("[REPLAY] Scale factor: x=%.3f y=%.3f" % [scale.x, scale.y])
			if screenshot_path and not screenshot_region.is_empty():
				var region = Rect2(
					screenshot_region.get("x", 0) * scale.x,
					screenshot_region.get("y", 0) * scale.y,
					screenshot_region.get("w", 0) * scale.x,
					screenshot_region.get("h", 0) * scale.y
				)
				print("[REPLAY] Scaled region: %s" % region)
				var passed = await _main_runner.validate_screenshot(screenshot_path, region)
				if not passed:
					# Store validation failure info for caller to handle
					event["_validation_failed"] = true
					event["_baseline_path"] = screenshot_path
					event["_actual_path"] = _main_runner.last_actual_path

	if wait_after_ms > 0:
		await _playback.wait(wait_after_ms / 1000.0, false)

func _validate_legacy_baseline(test_data: Dictionary, scale: Vector2, event_count: int) -> Dictionary:
	var baseline_path = test_data.get("baseline_path", "")
	var baseline_region = test_data.get("baseline_region")

	if not baseline_path or not baseline_region:
		return {"passed": true, "baseline_path": "", "actual_path": ""}

	var region = Rect2(
		baseline_region.get("x", 0) * scale.x,
		baseline_region.get("y", 0) * scale.y,
		baseline_region.get("w", 0) * scale.x,
		baseline_region.get("h", 0) * scale.y
	)
	print("[REPLAY] Validating legacy baseline (region scaled to %s)..." % region)
	var passed = await _main_runner.validate_screenshot(baseline_path, region)

	return {
		"passed": passed,
		"baseline_path": baseline_path,
		"actual_path": _main_runner.last_actual_path
	}
