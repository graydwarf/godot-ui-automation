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

# UI elements (created internally)
var _recording_indicator: Control = null
var _recording_hud_container: HBoxContainer = null
var _btn_capture: Button = null
var _btn_pause: Button = null
var _btn_stop: Button = null

# Initializes the recording engine with required references
func initialize(tree: SceneTree, parent: CanvasLayer) -> void:
	_tree = tree
	_parent = parent

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
	_hide_recording_indicator()
	recording_stopped.emit(recorded_events.size(), recorded_screenshots.size())

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
	_recording_hud_container.offset_left = -180
	_recording_hud_container.offset_top = -56
	_recording_hud_container.offset_right = -70
	_recording_hud_container.offset_bottom = -12
	_recording_hud_container.add_theme_constant_override("separation", 4)
	_recording_indicator.add_child(_recording_hud_container)

	# Load icons
	var icon_camera = load("res://addons/ui-test-runner/icons/camera.svg")
	var icon_pause = load("res://addons/ui-test-runner/icons/pause.svg")
	var icon_stop = load("res://addons/ui-test-runner/icons/stop.svg")

	# Capture button
	_btn_capture = Button.new()
	_btn_capture.name = "CaptureBtn"
	_btn_capture.icon = icon_camera
	_btn_capture.tooltip_text = "Capture Screenshot (F10)"
	_btn_capture.custom_minimum_size = Vector2(36, 36)
	_btn_capture.pressed.connect(_on_capture_pressed)
	_recording_hud_container.add_child(_btn_capture)

	# Pause button
	_btn_pause = Button.new()
	_btn_pause.name = "PauseBtn"
	_btn_pause.icon = icon_pause
	_btn_pause.tooltip_text = "Pause Recording"
	_btn_pause.custom_minimum_size = Vector2(36, 36)
	_btn_pause.pressed.connect(_on_pause_pressed)
	_recording_hud_container.add_child(_btn_pause)

	# Stop button
	_btn_stop = Button.new()
	_btn_stop.name = "StopBtn"
	_btn_stop.icon = icon_stop
	_btn_stop.tooltip_text = "Stop Recording (F11)"
	_btn_stop.custom_minimum_size = Vector2(36, 36)
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
		color = Color(1.0, 0.7, 0.2, 0.6)
		inner_color = Color(1.0, 0.8, 0.3, 0.5)
		label = "PAUSED"
	else:
		color = Color(1.0, 0.2, 0.2, 0.6)
		var pulse = (sin(Time.get_ticks_msec() / 300.0) + 1.0) / 2.0
		inner_color = Color(1.0, 0.3, 0.3, 0.3 + pulse * 0.4)
		label = "REC"

	_recording_indicator.draw_circle(center, indicator_size / 2, color)
	_recording_indicator.draw_circle(center, indicator_size / 3, inner_color)

	var font = ThemeDB.fallback_font
	var font_size = 10 if is_recording_paused else 12
	var text_offset = Vector2(-18, 4) if is_recording_paused else Vector2(-12, 4)
	var text_pos = center + text_offset
	_recording_indicator.draw_string(font, text_pos, label, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, Color.WHITE)

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

func _on_capture_pressed() -> void:
	request_screenshot_capture()

func _on_pause_pressed() -> void:
	toggle_pause()

func _on_stop_pressed() -> void:
	stop_recording()

# ============================================================================
# HUD DETECTION
# ============================================================================

func is_click_on_hud(pos: Vector2) -> bool:
	if not _recording_hud_container or not _recording_hud_container.visible:
		return false
	return _recording_hud_container.get_global_rect().has_point(pos)

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
		else:
			var distance = event.global_position.distance_to(mouse_down_pos)
			if distance < 5.0:
				if mouse_is_double_click:
					recorded_events.append({
						"type": "double_click",
						"pos": mouse_down_pos,
						"time": time_offset
					})
					print("[REC] Double-click at ", mouse_down_pos)
				else:
					recorded_events.append({
						"type": "click",
						"pos": mouse_down_pos,
						"time": time_offset
					})
					print("[REC] Click at ", mouse_down_pos)
			else:
				recorded_events.append({
					"type": "drag",
					"from": mouse_down_pos,
					"to": event.global_position,
					"time": time_offset
				})
				print("[REC] Drag from ", mouse_down_pos, " to ", event.global_position)
			mouse_is_down = false
			mouse_is_double_click = false

# Captures key events - returns true if captured, false if should be skipped
func capture_key_event(event: InputEventKey) -> bool:
	if is_recording_paused:
		return false
	if not event.pressed:
		return false
	if event.keycode == KEY_F11:
		return false
	if event.keycode in [KEY_CTRL, KEY_SHIFT, KEY_ALT, KEY_META]:
		return false

	var time_offset = Time.get_ticks_msec() - record_start_time
	recorded_events.append({
		"type": "key",
		"keycode": event.keycode,
		"shift": event.shift_pressed,
		"ctrl": event.ctrl_pressed,
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
