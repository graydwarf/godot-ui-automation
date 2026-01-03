extends RefCounted
class_name UIRecordingEngine
## Recording engine for UI test automation
## Handles event capture and recording indicator UI

signal recording_started
signal recording_stopped(event_count: int, screenshot_count: int)
signal screenshot_capture_requested
signal region_selection_requested

# Required references (set via initialize)
var _tree: SceneTree
var _parent: CanvasLayer

# Recording state
var is_recording: bool = false
var is_recording_paused: bool = false
var recorded_events: Array[Dictionary] = []
var recorded_screenshots: Array[Dictionary] = []
var record_start_time: int = 0

# Mouse state for event capture
var mouse_down_pos: Vector2 = Vector2.ZERO
var mouse_is_down: bool = false
var mouse_is_double_click: bool = false
var mouse_down_ctrl: bool = false
var mouse_down_shift: bool = false

# Middle mouse state for pan capture
var middle_mouse_down_pos: Vector2 = Vector2.ZERO
var middle_mouse_is_down: bool = false

# UI elements (created internally)
var _recording_indicator: Control = null
var _recording_hud_container: HBoxContainer = null
var _btn_clipboard: Button = null
var _btn_capture: Button = null
var _btn_pause: Button = null
var _btn_stop: Button = null

# Test fixture constants
const TEST_IMAGE_PATH = "res://tests/fixtures/test_image.png"

# Initializes the recording engine with required references
func initialize(tree: SceneTree, parent: CanvasLayer) -> void:
	_tree = tree
	_parent = parent

# Helper to find items at a screen position (delegates to parent UITestRunner)
func _find_item_at_position(screen_pos: Vector2) -> Dictionary:
	if _parent and _parent.has_method("find_item_at_screen_pos"):
		return _parent.find_item_at_screen_pos(screen_pos)
	return {}

# ============================================================================
# RECORDING CONTROL
# ============================================================================

func start_recording() -> void:
	is_recording = true
	is_recording_paused = false
	recorded_events.clear()
	recorded_screenshots.clear()
	record_start_time = Time.get_ticks_msec()
	mouse_is_down = false
	_show_recording_indicator()
	recording_started.emit()

func stop_recording() -> void:
	is_recording = false
	is_recording_paused = false
	# Reset mouse state to prevent stale state on next recording
	mouse_is_down = false
	middle_mouse_is_down = false
	_hide_recording_indicator()
	recording_stopped.emit(recorded_events.size(), recorded_screenshots.size())

func cancel_recording() -> void:
	# Cancel without emitting recording_stopped signal (skips save flow)
	is_recording = false
	is_recording_paused = false
	mouse_is_down = false
	middle_mouse_is_down = false
	recorded_events.clear()
	recorded_screenshots.clear()
	_hide_recording_indicator()

func toggle_pause() -> void:
	if not is_recording:
		return

	is_recording_paused = not is_recording_paused
	_update_pause_button()

	if _recording_indicator:
		_recording_indicator.queue_redraw()

func request_screenshot_capture() -> void:
	if not is_recording:
		return
	screenshot_capture_requested.emit()

# ============================================================================
# RECORDING INDICATOR UI
# ============================================================================

func _show_recording_indicator() -> void:
	if not _recording_indicator:
		_create_recording_indicator()
	_recording_indicator.visible = true

func _hide_recording_indicator() -> void:
	if _recording_indicator:
		_recording_indicator.visible = false

func set_indicator_visible(visible: bool) -> void:
	if _recording_indicator:
		_recording_indicator.visible = visible

func _create_recording_indicator() -> void:
	_recording_indicator = Control.new()
	_recording_indicator.name = "RecordingIndicator"
	_recording_indicator.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_recording_indicator.set_anchors_preset(Control.PRESET_FULL_RECT)
	_recording_indicator.process_mode = Node.PROCESS_MODE_ALWAYS
	_recording_indicator.z_index = 20  # Low z-index - visible but below dialogs
	_parent.add_child(_recording_indicator)
	_recording_indicator.draw.connect(_draw_recording_indicator)

	_create_recording_hud()

func _create_recording_hud() -> void:
	_recording_hud_container = HBoxContainer.new()
	_recording_hud_container.name = "RecordingHUD"
	_recording_hud_container.mouse_filter = Control.MOUSE_FILTER_STOP
	_recording_hud_container.process_mode = Node.PROCESS_MODE_ALWAYS
	_recording_hud_container.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	_recording_hud_container.anchor_left = 1.0
	_recording_hud_container.anchor_top = 1.0
	_recording_hud_container.anchor_right = 1.0
	_recording_hud_container.anchor_bottom = 1.0
	_recording_hud_container.offset_left = -303  # Wider to fit 4 buttons
	_recording_hud_container.offset_top = -69
	_recording_hud_container.offset_right = -88
	_recording_hud_container.offset_bottom = -19
	_recording_hud_container.add_theme_constant_override("separation", 12)
	_recording_indicator.add_child(_recording_hud_container)

	# Load icons
	var icon_camera = load("res://addons/ui-test-runner/icons/camera.svg")
	var icon_pause = load("res://addons/ui-test-runner/icons/pause.svg")
	var icon_stop = load("res://addons/ui-test-runner/icons/stop.svg")

	# Clipboard/Test Image button - sets test image to clipboard for Ctrl+V paste
	_btn_clipboard = Button.new()
	_btn_clipboard.name = "ClipboardBtn"
	_btn_clipboard.text = "📋"
	_btn_clipboard.tooltip_text = "Set Test Image to Clipboard (then Ctrl+V to paste)"
	_btn_clipboard.custom_minimum_size = Vector2(45, 45)
	_btn_clipboard.pressed.connect(_on_clipboard_pressed)
	_recording_hud_container.add_child(_btn_clipboard)

	# Capture button
	_btn_capture = Button.new()
	_btn_capture.name = "CaptureBtn"
	_btn_capture.icon = icon_camera
	_btn_capture.tooltip_text = "Capture Screenshot (F10)"
	_btn_capture.custom_minimum_size = Vector2(45, 45)
	_btn_capture.expand_icon = true
	_btn_capture.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_btn_capture.pressed.connect(_on_capture_pressed)
	_recording_hud_container.add_child(_btn_capture)

	# Pause button
	_btn_pause = Button.new()
	_btn_pause.name = "PauseBtn"
	_btn_pause.icon = icon_pause
	_btn_pause.tooltip_text = "Pause Recording"
	_btn_pause.custom_minimum_size = Vector2(45, 45)
	_btn_pause.expand_icon = true
	_btn_pause.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_btn_pause.pressed.connect(_on_pause_pressed)
	_recording_hud_container.add_child(_btn_pause)

	# Stop button
	_btn_stop = Button.new()
	_btn_stop.name = "StopBtn"
	_btn_stop.icon = icon_stop
	_btn_stop.tooltip_text = "Stop Recording (F11)"
	_btn_stop.custom_minimum_size = Vector2(45, 45)
	_btn_stop.expand_icon = true
	_btn_stop.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_btn_stop.pressed.connect(_on_stop_pressed)
	_recording_hud_container.add_child(_btn_stop)

func _draw_recording_indicator() -> void:
	var viewport_size = _parent.get_viewport().get_visible_rect().size
	var indicator_size = 48.0
	var margin = 20.0
	var center = Vector2(
		viewport_size.x - margin - indicator_size / 2,
		viewport_size.y - margin - indicator_size / 2
	)

	var color: Color
	var inner_color: Color
	var label: String

	if is_recording_paused:
		color = Color(1.0, 0.7, 0.2, 0.25)
		inner_color = Color(1.0, 0.8, 0.3, 0.21)
		label = "PAUSED"
	else:
		color = Color(1.0, 0.2, 0.2, 0.25)
		var pulse = (sin(Time.get_ticks_msec() / 300.0) + 1.0) / 2.0
		inner_color = Color(1.0, 0.3, 0.3, 0.13 + pulse * 0.17)
		label = "REC"

	_recording_indicator.draw_circle(center, indicator_size / 2, color)
	_recording_indicator.draw_circle(center, indicator_size / 3, inner_color)

	var font = ThemeDB.fallback_font
	var font_size = 10 if is_recording_paused else 12
	var text_offset = Vector2(-18, 4) if is_recording_paused else Vector2(-12, 4)
	var text_pos = center + text_offset
	_recording_indicator.draw_string(font, text_pos, label, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, Color(1.0, 1.0, 1.0, 0.56))

	if is_recording:
		_recording_indicator.queue_redraw()

func _update_pause_button() -> void:
	if not _btn_pause:
		return
	if is_recording_paused:
		_btn_pause.icon = load("res://addons/ui-test-runner/icons/play.svg")
		_btn_pause.tooltip_text = "Resume Recording"
		print("[UIRecordingEngine] === RECORDING PAUSED ===")
	else:
		_btn_pause.icon = load("res://addons/ui-test-runner/icons/pause.svg")
		_btn_pause.tooltip_text = "Pause Recording"
		print("[UIRecordingEngine] === RECORDING RESUMED ===")

func _on_clipboard_pressed() -> void:
	if not is_recording or is_recording_paused:
		return

	# Ensure test image exists (creates if needed)
	var image = _get_or_create_test_image()
	if not image:
		push_error("[UIRecordingEngine] Failed to create test image")
		return

	# Inject image into UITestRunner - clipboard manager will find it on Ctrl+V
	# This works cross-platform (same mechanism used during playback)
	# Use same lookup as clipboard manager to ensure we set the right instance
	var ui_test_runner = _tree.root.get_node_or_null("UITestRunner")
	if ui_test_runner:
		ui_test_runner.injected_clipboard_image = image
		print("[REC] Image injected into UITestRunner")
	else:
		push_error("[UIRecordingEngine] UITestRunner not found - cannot inject image")

	# Record the event with current mouse position (for paste location during playback)
	var time_offset = Time.get_ticks_msec() - record_start_time
	var mouse_pos = _parent.get_viewport().get_mouse_position()
	recorded_events.append({
		"type": "set_clipboard_image",
		"path": TEST_IMAGE_PATH,
		"mouse_pos": mouse_pos,
		"time": time_offset
	})

	# Visual feedback - briefly change button appearance
	if _btn_clipboard:
		_btn_clipboard.text = "✓"
		_btn_clipboard.modulate = Color(0.3, 1.0, 0.3, 1.0)
		var tween = _tree.create_tween()
		tween.tween_interval(0.5)
		tween.tween_callback(func():
			if _btn_clipboard:
				_btn_clipboard.text = "📋"
				_btn_clipboard.modulate = Color.WHITE
		)

	print("[REC] Injected test image - press Ctrl+V to paste: %s" % TEST_IMAGE_PATH)

func _on_capture_pressed() -> void:
	request_screenshot_capture()

func _on_pause_pressed() -> void:
	toggle_pause()

func _on_stop_pressed() -> void:
	stop_recording()

# Gets existing test image or creates a new one
func _get_or_create_test_image() -> Image:
	# Try to load existing image first
	if ResourceLoader.exists(TEST_IMAGE_PATH):
		var texture = load(TEST_IMAGE_PATH)
		if texture and texture is Texture2D:
			return texture.get_image()

	# Create a new test image (200x200 with checkerboard pattern)
	var image = Image.create(200, 200, false, Image.FORMAT_RGBA8)
	var colors = [Color(0.2, 0.6, 0.9, 1.0), Color(0.9, 0.9, 0.9, 1.0)]  # Blue and white
	var cell_size = 25

	for y in range(200):
		for x in range(200):
			var checker = ((x / cell_size) + (y / cell_size)) % 2
			image.set_pixel(x, y, colors[checker])

	# Add "TEST" text indicator in center (simple pixel art)
	_draw_test_label(image)

	# Save the image
	var global_path = ProjectSettings.globalize_path(TEST_IMAGE_PATH)
	var dir = global_path.get_base_dir()
	if not DirAccess.dir_exists_absolute(dir):
		DirAccess.make_dir_recursive_absolute(dir)
	image.save_png(global_path)
	print("[UIRecordingEngine] Created test image at: ", TEST_IMAGE_PATH)

	return image

# Draws a simple "TEST" label on the image
func _draw_test_label(image: Image) -> void:
	var label_color = Color(0.1, 0.1, 0.1, 1.0)
	var bg_color = Color(1.0, 1.0, 1.0, 0.8)

	# Draw background rectangle
	for y in range(85, 115):
		for x in range(50, 150):
			image.set_pixel(x, y, bg_color)

	# Simple "TEST" text (5x7 pixel font, scaled 2x)
	var letters = {
		"T": [[1,1,1,1,1], [0,0,1,0,0], [0,0,1,0,0], [0,0,1,0,0], [0,0,1,0,0], [0,0,1,0,0], [0,0,1,0,0]],
		"E": [[1,1,1,1,1], [1,0,0,0,0], [1,0,0,0,0], [1,1,1,1,0], [1,0,0,0,0], [1,0,0,0,0], [1,1,1,1,1]],
		"S": [[0,1,1,1,1], [1,0,0,0,0], [1,0,0,0,0], [0,1,1,1,0], [0,0,0,0,1], [0,0,0,0,1], [1,1,1,1,0]],
	}

	var text = ["T", "E", "S", "T"]
	var start_x = 58
	var start_y = 90
	var scale = 2
	var spacing = 12 * scale

	for i in range(text.size()):
		var letter = letters[text[i]]
		var offset_x = start_x + i * spacing
		for row in range(letter.size()):
			for col in range(letter[row].size()):
				if letter[row][col] == 1:
					for sy in range(scale):
						for sx in range(scale):
							image.set_pixel(offset_x + col * scale + sx, start_y + row * scale + sy, label_color)

# ============================================================================
# HUD DETECTION
# ============================================================================

func is_click_on_hud(pos: Vector2) -> bool:
	if not _recording_hud_container:
		return false
	# Check if recording indicator (parent) is visible
	if not _recording_indicator or not _recording_indicator.visible:
		return false
	# Check container rect
	if _recording_hud_container.get_global_rect().has_point(pos):
		return true
	# Also check individual buttons in case they extend beyond container
	if _btn_clipboard and _btn_clipboard.get_global_rect().has_point(pos):
		return true
	if _btn_capture and _btn_capture.get_global_rect().has_point(pos):
		return true
	if _btn_pause and _btn_pause.get_global_rect().has_point(pos):
		return true
	if _btn_stop and _btn_stop.get_global_rect().has_point(pos):
		return true
	return false

# ============================================================================
# EVENT CAPTURE
# ============================================================================

func capture_event(event: InputEvent) -> void:
	if is_recording_paused:
		return

	var time_offset = Time.get_ticks_msec() - record_start_time

	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if is_click_on_hud(event.global_position):
			return

		if event.pressed:
			mouse_down_pos = event.global_position
			mouse_is_down = true
			mouse_is_double_click = event.double_click
			mouse_down_ctrl = event.ctrl_pressed
			mouse_down_shift = event.shift_pressed
		else:
			var distance = event.global_position.distance_to(mouse_down_pos)
			if distance < 5.0:
				if mouse_is_double_click:
					var dbl_event: Dictionary = {
						"type": "double_click",
						"pos": mouse_down_pos,
						"time": time_offset
					}
					if mouse_down_ctrl:
						dbl_event["ctrl"] = true
					if mouse_down_shift:
						dbl_event["shift"] = true
					recorded_events.append(dbl_event)
					var mods = ("Ctrl+" if mouse_down_ctrl else "") + ("Shift+" if mouse_down_shift else "")
					print("[REC] %sDouble-click at %s" % [mods, mouse_down_pos])
				else:
					var click_event: Dictionary = {
						"type": "click",
						"pos": mouse_down_pos,
						"time": time_offset
					}
					if mouse_down_ctrl:
						click_event["ctrl"] = true
					if mouse_down_shift:
						click_event["shift"] = true
					recorded_events.append(click_event)
					var mods = ("Ctrl+" if mouse_down_ctrl else "") + ("Shift+" if mouse_down_shift else "")
					print("[REC] %sClick at %s" % [mods, mouse_down_pos])
			else:
				var drag_event: Dictionary = {
					"type": "drag",
					"from": mouse_down_pos,
					"to": event.global_position,
					"time": time_offset
				}
				# Try to identify the object at the drag start position for robust playback
				var item_info = _find_item_at_position(mouse_down_pos)
				if not item_info.is_empty():
					drag_event["object_type"] = item_info.type
					drag_event["object_id"] = item_info.id
					# Store click offset relative to item's top-left corner
					var click_offset = mouse_down_pos - item_info.screen_pos
					drag_event["click_offset"] = click_offset
					print("[REC] Drag %s:%s from=%s to=%s" % [
						item_info.type, item_info.id.substr(0, 8), mouse_down_pos, event.global_position
					])
					print("  item_screen_pos=%s click_offset=%s delta=%s" % [
						item_info.screen_pos, click_offset, event.global_position - mouse_down_pos
					])
				else:
					# Store world coordinates for resolution-independent playback
					if _parent and _parent.has_method("screen_to_world") and _parent.has_method("world_to_cell"):
						var to_world = _parent.screen_to_world(event.global_position)
						var to_cell = _parent.world_to_cell(to_world)
						# Store both world coords (precise) and cell coords (grid-snapped)
						drag_event["to_world"] = to_world
						drag_event["to_cell"] = to_cell
						print("[REC] Drag (toolbar) from=%s to=%s" % [mouse_down_pos, event.global_position])
						print("  to_world=%s to_cell=(%d, %d)" % [to_world, to_cell.x, to_cell.y])
					else:
						print("[REC] Drag (no object) from=%s to=%s delta=%s" % [
							mouse_down_pos, event.global_position, event.global_position - mouse_down_pos
						])
				recorded_events.append(drag_event)
			mouse_is_down = false
			mouse_is_double_click = false

	# Middle mouse button - pan/scroll
	elif event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_MIDDLE:
		if event.pressed:
			middle_mouse_down_pos = event.global_position
			middle_mouse_is_down = true
		else:
			if middle_mouse_is_down:
				var distance = event.global_position.distance_to(middle_mouse_down_pos)
				if distance >= 5.0:  # Only record if actually panned
					recorded_events.append({
						"type": "pan",
						"from": middle_mouse_down_pos,
						"to": event.global_position,
						"time": time_offset
					})
					print("[REC] Pan from=%s to=%s delta=%s" % [
						middle_mouse_down_pos, event.global_position,
						event.global_position - middle_mouse_down_pos
					])
			middle_mouse_is_down = false

	# Right mouse button - cancel/context menu
	elif event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_RIGHT:
		if event.pressed:
			recorded_events.append({
				"type": "right_click",
				"pos": event.global_position,
				"time": time_offset
			})
			print("[REC] Right-click at %s" % event.global_position)

	# Mouse wheel - zoom/scroll with modifier keys
	elif event is InputEventMouseButton and event.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN]:
		if event.pressed:
			var direction = "in" if event.button_index == MOUSE_BUTTON_WHEEL_UP else "out"
			recorded_events.append({
				"type": "scroll",
				"direction": direction,
				"pos": event.global_position,
				"ctrl": event.ctrl_pressed,
				"shift": event.shift_pressed,
				"alt": event.alt_pressed,
				"factor": event.factor,  # Scroll intensity/amount
				"time": time_offset
			})
			var mods = ""
			if event.ctrl_pressed: mods += "Ctrl+"
			if event.shift_pressed: mods += "Shift+"
			if event.alt_pressed: mods += "Alt+"
			print("[REC] %sScroll %s at %s (factor: %.2f)" % [mods, direction, event.global_position, event.factor])

# Captures key events - returns true if captured, false if should be skipped
func capture_key_event(event: InputEventKey) -> bool:
	if is_recording_paused:
		return false
	if not event.pressed:
		return false
	# Skip control keys that shouldn't be recorded
	if event.keycode in [KEY_F11, KEY_ESCAPE]:
		return false
	if event.keycode in [KEY_CTRL, KEY_SHIFT, KEY_ALT, KEY_META]:
		return false

	# T key during drag = terminate drag segment (record drag but keep mouse down)
	if event.keycode == KEY_T and mouse_is_down:
		terminate_drag_segment()
		return true  # Consume the T key, don't record it

	var time_offset = Time.get_ticks_msec() - record_start_time
	var mouse_pos = _parent.get_viewport().get_mouse_position()
	recorded_events.append({
		"type": "key",
		"keycode": event.keycode,
		"shift": event.shift_pressed,
		"ctrl": event.ctrl_pressed,
		"mouse_pos": mouse_pos,
		"time": time_offset
	})

	var key_name = OS.get_keycode_string(event.keycode)
	var mods = ""
	if event.ctrl_pressed:
		mods += "Ctrl+"
	if event.shift_pressed:
		mods += "Shift+"
	print("[REC] Key: ", mods, key_name)
	return true

# Terminates the current drag segment without releasing the mouse
# Records a drag event with no_drop=true and resets for the next segment
func terminate_drag_segment() -> void:
	if not mouse_is_down:
		return

	var current_pos = _parent.get_viewport().get_mouse_position()
	var distance = current_pos.distance_to(mouse_down_pos)

	# Only record if we actually moved
	if distance < 5.0:
		print("[REC] Drag segment too short, skipping")
		return

	var time_offset = Time.get_ticks_msec() - record_start_time

	var drag_event: Dictionary = {
		"type": "drag",
		"from": mouse_down_pos,
		"to": current_pos,
		"no_drop": true,  # Key flag - don't release mouse at end
		"time": time_offset
	}

	# Try to identify the object at the drag start position
	var item_info = _find_item_at_position(mouse_down_pos)
	if not item_info.is_empty():
		drag_event["object_type"] = item_info.type
		drag_event["object_id"] = item_info.id
		var click_offset = mouse_down_pos - item_info.screen_pos
		drag_event["click_offset"] = click_offset
		print("[REC] Drag SEGMENT %s:%s from=%s to=%s (no_drop)" % [
			item_info.type, item_info.id.substr(0, 8), mouse_down_pos, current_pos
		])
	else:
		print("[REC] Drag SEGMENT from=%s to=%s (no_drop)" % [mouse_down_pos, current_pos])

	recorded_events.append(drag_event)

	# Reset for next segment - keep mouse_is_down true, update start position
	mouse_down_pos = current_pos
	# Preserve ctrl/shift state for the continued drag

# Adds a screenshot record
func add_screenshot_record(path: String, region: Dictionary) -> void:
	var time_offset = Time.get_ticks_msec() - record_start_time
	recorded_screenshots.append({
		"path": path,
		"region": region,
		"after_event_index": recorded_events.size() - 1,
		"time": time_offset
	})

# ============================================================================
# FALLBACK MOUSE UP DETECTION
# ============================================================================

# Called from _process to detect missed mouse up events
func check_missed_mouse_up(viewport: Viewport) -> void:
	if not is_recording or not mouse_is_down:
		return
	if not Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
		print("[REC-PROCESS] Detected missed mouse UP at %s" % viewport.get_mouse_position())
		var fake_event = InputEventMouseButton.new()
		fake_event.button_index = MOUSE_BUTTON_LEFT
		fake_event.pressed = false
		fake_event.global_position = viewport.get_mouse_position()
		fake_event.position = fake_event.global_position
		capture_event(fake_event)
