extends RefCounted
class_name TestExecutor
## Handles test playback and validation for the UI Test Runner

const Utils = preload("res://addons/ui-test-runner/utils.gd")
const FileIO = preload("res://addons/ui-test-runner/file-io.gd")
const ScreenshotValidator = preload("res://addons/ui-test-runner/screenshot-validator.gd")
const DEFAULT_DELAYS = Utils.DEFAULT_DELAYS
const TESTS_DIR = Utils.TESTS_DIR

signal test_started(test_name: String)
signal test_completed(test_name: String, passed: bool)
signal test_result_ready(result: Dictionary)
signal action_performed(action: String, details: Dictionary)

var current_test_name: String = ""
var is_running: bool = false

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
	_playback.is_running = true
	_playback.clear_action_log()
	_virtual_cursor.visible = true
	_virtual_cursor.show_cursor()
	test_started.emit(test_name)
	print("[TestExecutor] === BEGIN: ", test_name, " ===")
	await _tree.process_frame

func end_test(passed: bool = true) -> void:
	var result = "PASSED" if passed else "FAILED"
	print("[TestExecutor] === END: ", current_test_name, " - ", result, " ===")
	_virtual_cursor.hide_cursor()
	_playback.is_running = false
	is_running = false
	test_completed.emit(current_test_name, passed)
	current_test_name = ""

# Run a saved test from file (non-blocking, emits test_result_ready when done)
func run_test_from_file(test_name: String) -> void:
	var filepath = TESTS_DIR + "/" + test_name + ".json"
	var test_data = FileIO.load_test(filepath)
	if test_data.is_empty():
		return

	# Convert JSON events to runtime format
	var recorded_events = _convert_events_from_json(test_data.get("events", []))
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
	print("[TestExecutor] Loaded %d events from file" % recorded_events.size())

	# Run and return result directly (awaitable)
	return await _run_replay_internal(test_data, recorded_events, test_name)

func _convert_events_from_json(events: Array) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for event in events:
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
	await begin_test(display_name)

	# Store and restore window state
	var original_window = _store_window_state()
	await _restore_recorded_window(test_data.get("recorded_window", {}))

	# Calculate viewport scaling
	var scale = _calculate_viewport_scale(test_data)

	# Build screenshot validation map
	var screenshots_by_index = _build_screenshot_map(test_data.get("screenshots", []))

	var passed = true
	var baseline_path = ""
	var actual_path = ""
	var failed_step_index: int = -1

	print("[TestExecutor] Replaying %d events..." % recorded_events.size())
	for i in range(recorded_events.size()):
		var event = recorded_events[i]
		await _execute_event(event, i, scale)

		# Validate screenshots after this event
		if screenshots_by_index.has(i) and passed:
			var validation = await _validate_screenshots_at_index(screenshots_by_index[i], i, scale)
			if not validation.passed:
				passed = false
				baseline_path = validation.baseline_path
				actual_path = validation.actual_path
				failed_step_index = i + 1
				break

		if not passed:
			break

	# Check legacy single baseline at end
	if test_data.get("screenshots", []).is_empty() and passed:
		await _playback.wait(0.3, true)
		var legacy = await _validate_legacy_baseline(test_data, scale, recorded_events.size())
		passed = legacy.passed
		baseline_path = legacy.baseline_path
		actual_path = legacy.actual_path
		if not passed:
			failed_step_index = recorded_events.size()

	end_test(passed)
	print("[TestExecutor] Replay complete - ", "PASSED" if passed else "FAILED")

	# Restore original window
	await _restore_window_state(original_window, not test_data.get("recorded_window", {}).is_empty())

	return {
		"name": result_name,
		"passed": passed,
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
		var target_pos = Vector2i(recorded_window.get("x", 100), recorded_window.get("y", 100))
		DisplayServer.window_set_size(target_size)
		DisplayServer.window_set_position(target_pos)
		print("[TestExecutor] Restored window: windowed %dx%d at (%d,%d)" % [target_size.x, target_size.y, target_pos.x, target_pos.y])
	elif target_mode == DisplayServer.WINDOW_MODE_MAXIMIZED:
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_MAXIMIZED)
		print("[TestExecutor] Restored window: maximized")
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
		DisplayServer.window_set_position(original.pos)
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

func _build_screenshot_map(screenshots: Array) -> Dictionary:
	var result: Dictionary = {}
	print("[TestExecutor] Building validation map from %d screenshots in test data" % screenshots.size())
	for screenshot in screenshots:
		var after_idx = int(screenshot.get("after_event_index", -1))
		if not result.has(after_idx):
			result[after_idx] = []
		result[after_idx].append(screenshot)
	return result

func _execute_event(event: Dictionary, index: int, scale: Vector2) -> void:
	var event_type = event.get("type", "")
	var wait_after_ms = event.get("wait_after", 100)

	match event_type:
		"click":
			var pos = event.get("pos", Vector2.ZERO)
			var scaled_pos = Vector2(pos.x * scale.x, pos.y * scale.y)
			print("[REPLAY] Step %d: Click at %s (scaled: %s)" % [index + 1, pos, scaled_pos])
			await _playback.click_at(scaled_pos)
		"double_click":
			var pos = event.get("pos", Vector2.ZERO)
			var scaled_pos = Vector2(pos.x * scale.x, pos.y * scale.y)
			print("[REPLAY] Step %d: Double-click at %s (scaled: %s)" % [index + 1, pos, scaled_pos])
			await _playback.move_to(scaled_pos)
			await _playback.double_click()
		"drag":
			var from_pos = event.get("from", Vector2.ZERO)
			var to_pos = event.get("to", Vector2.ZERO)
			var scaled_from = Vector2(from_pos.x * scale.x, from_pos.y * scale.y)
			var scaled_to = Vector2(to_pos.x * scale.x, to_pos.y * scale.y)
			var hold_time = wait_after_ms / 1000.0
			print("[REPLAY] Step %d: Drag %s->%s (scaled: %s->%s, hold %.1fs)" % [index + 1, from_pos, to_pos, scaled_from, scaled_to, hold_time])
			await _playback.drag(scaled_from, scaled_to, 0.5, hold_time)
			wait_after_ms = 0
		"key":
			var keycode = event.get("keycode", 0)
			var mods = ""
			if event.get("ctrl", false):
				mods += "Ctrl+"
			if event.get("shift", false):
				mods += "Shift+"
			print("[REPLAY] Step %d: Key %s%s" % [index + 1, mods, OS.get_keycode_string(keycode)])
			await _playback.press_key(keycode, event.get("shift", false), event.get("ctrl", false))
		"wait":
			var duration_ms = event.get("duration", 1000)
			print("[REPLAY] Step %d: Wait %.1fs" % [index + 1, duration_ms / 1000.0])
			await _playback.wait(duration_ms / 1000.0, false)

	if wait_after_ms > 0:
		await _playback.wait(wait_after_ms / 1000.0, false)

func _validate_screenshots_at_index(screenshots: Array, index: int, scale: Vector2) -> Dictionary:
	for screenshot in screenshots:
		var screenshot_path = screenshot.get("path", "")
		var screenshot_region = screenshot.get("region", {})
		if screenshot_path and not screenshot_region.is_empty():
			var region = Rect2(
				screenshot_region.get("x", 0) * scale.x,
				screenshot_region.get("y", 0) * scale.y,
				screenshot_region.get("w", 0) * scale.x,
				screenshot_region.get("h", 0) * scale.y
			)
			print("[REPLAY] Validating screenshot after step %d (region scaled to %s)..." % [index + 1, region])
			var passed = await _main_runner.validate_screenshot(screenshot_path, region)
			if not passed:
				return {
					"passed": false,
					"baseline_path": screenshot_path,
					"actual_path": screenshot_path.replace(".png", "_actual.png")
				}
	return {"passed": true, "baseline_path": "", "actual_path": ""}

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
	var actual_path = baseline_path.replace(".png", "_actual.png")
	print("[REPLAY] Validating legacy baseline (region scaled to %s)..." % region)
	var passed = await _main_runner.validate_screenshot(baseline_path, region)

	return {
		"passed": passed,
		"baseline_path": baseline_path,
		"actual_path": actual_path
	}
