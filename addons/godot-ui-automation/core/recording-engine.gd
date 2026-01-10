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
## Recording engine for UI test automation
## Handles event capture and recording indicator UI

const ScreenshotValidator = preload("res://addons/godot-ui-automation/utils/screenshot-validator.gd")
const UITestSettings = preload("res://addons/godot-ui-automation/ui/ui-settings.gd")
const UITestHelp = preload("res://addons/godot-ui-automation/ui/ui-help.gd")
const UITestAbout = preload("res://addons/godot-ui-automation/ui/ui-about.gd")

signal recording_started
signal recording_stopped(event_count: int, screenshot_count: int)
signal recording_cancelled
signal screenshot_capture_requested
signal region_selection_requested
signal replay_requested(events: Array)  # Request to replay recorded steps so far

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

# Window state tracking for auto-maximize
var _was_maximized_before_recording: bool = true

# UI elements (created internally)
var _recording_indicator: Control = null
var _recording_panel: Panel = null  # Main panel container
var _recording_header: HBoxContainer = null  # Header with controls (always visible)
var _recording_body_container: VBoxContainer = null  # Collapsible body with live steps
var _recording_details_btn: Button = null  # Toggle body visibility
var _recording_event_count_label: Label = null  # Event count in header
var _recording_steps_scroll: ScrollContainer = null  # Scrollable step list
var _recording_steps_list: VBoxContainer = null  # Container for step rows
var _recording_step_rows: Array[Control] = []  # References to step row controls
var _recording_collapsed: bool = true  # Body collapsed state (default collapsed)
var _btn_replay: Button = null
var _btn_clipboard: Button = null
var _btn_capture: Button = null
var _btn_stop: Button = null
var _btn_settings: Button = null
var _btn_exit: Button = null
var _is_replaying: bool = false  # Track if we're currently replaying
var _settings_panel: PanelContainer = null
var _ui_settings: UITestSettings = null

# Test fixture constants
const TEST_IMAGE_PATH = "res://tests/fixtures/test_image.png"

# Wait delay options (same as Test Editor)
const RECORDING_DELAY_OPTIONS = [0, 50, 100, 250, 350, 500, 1000, 1500, 2000, 3000, 5000]

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
	_clear_recording_steps_ui()  # Clear live steps UI
	record_start_time = Time.get_ticks_msec()
	mouse_is_down = false
	# Auto-maximize window if setting enabled
	if ScreenshotValidator.auto_maximize_recording:
		var window = _tree.root
		if window.mode != Window.MODE_MAXIMIZED:
			_was_maximized_before_recording = false
			window.mode = Window.MODE_MAXIMIZED
		else:
			_was_maximized_before_recording = true
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
	recording_cancelled.emit()

func toggle_pause() -> void:
	if not is_recording:
		return

	is_recording_paused = not is_recording_paused

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

# Get/set collapse state for syncing between Recording UI and Playback UI
func is_collapsed() -> bool:
	return _recording_collapsed

func set_collapsed(collapsed: bool) -> void:
	if _recording_collapsed == collapsed:
		return
	_recording_collapsed = collapsed
	if _recording_body_container:
		_recording_body_container.visible = not collapsed
	if _recording_details_btn:
		_recording_details_btn.text = "▼ Details" if not collapsed else "▶ Details"
	_update_recording_panel_height()

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
	# Main panel container - styled like Test Editor HUD
	_recording_panel = Panel.new()
	_recording_panel.name = "RecordingHUD"
	_recording_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	_recording_panel.process_mode = Node.PROCESS_MODE_ALWAYS
	_recording_panel.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	_recording_panel.anchor_left = 1.0
	_recording_panel.anchor_top = 1.0
	_recording_panel.anchor_right = 1.0
	_recording_panel.anchor_bottom = 1.0
	_recording_panel.offset_left = -436
	_recording_panel.offset_top = -70  # Start collapsed
	_recording_panel.offset_right = -10
	_recording_panel.offset_bottom = -10

	# Style: dark background with red border (recording state)
	var panel_style = StyleBoxFlat.new()
	panel_style.bg_color = Color(0.12, 0.12, 0.15, 0.98)
	panel_style.border_color = Color(0.9, 0.3, 0.3, 1.0)  # Red for recording
	panel_style.set_border_width_all(2)
	panel_style.set_corner_radius_all(10)
	_recording_panel.add_theme_stylebox_override("panel", panel_style)
	_recording_indicator.add_child(_recording_panel)

	# Main VBox with margins
	var margin = MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	margin.add_theme_constant_override("margin_left", 12)
	margin.add_theme_constant_override("margin_right", 12)
	margin.add_theme_constant_override("margin_top", 10)
	margin.add_theme_constant_override("margin_bottom", 10)
	_recording_panel.add_child(margin)

	var vbox = VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 8)
	vbox.mouse_filter = Control.MOUSE_FILTER_STOP
	margin.add_child(vbox)

	# === HEADER ROW === (always visible, contains controls)
	_recording_header = HBoxContainer.new()
	_recording_header.add_theme_constant_override("separation", 8)
	vbox.add_child(_recording_header)

	# Load icons
	var icon_play = load("res://addons/godot-ui-automation/icons/play.svg")
	var icon_camera = load("res://addons/godot-ui-automation/icons/camera.svg")
	var icon_stop = load("res://addons/godot-ui-automation/icons/stop.svg")
	var icon_image = load("res://addons/godot-ui-automation/icons/image.svg")
	var icon_settings = load("res://addons/godot-ui-automation/icons/settings.svg")
	var icon_exit = load("res://addons/godot-ui-automation/icons/exit.svg")

	# REC indicator label
	var rec_label = Label.new()
	rec_label.text = "● REC"
	rec_label.add_theme_font_size_override("font_size", 14)
	rec_label.add_theme_color_override("font_color", Color(1.0, 0.3, 0.3))  # Red
	_recording_header.add_child(rec_label)

	# Replay button - replay recorded steps then continue recording
	_btn_replay = Button.new()
	_btn_replay.name = "ReplayBtn"
	_btn_replay.icon = icon_play
	_btn_replay.tooltip_text = "Replay steps, then continue recording"
	_btn_replay.custom_minimum_size = Vector2(40, 40)
	_btn_replay.expand_icon = true
	_btn_replay.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_btn_replay.focus_mode = Control.FOCUS_NONE
	_btn_replay.pressed.connect(_on_replay_pressed)
	_recording_header.add_child(_btn_replay)

	# Clipboard/Test Image button - sets test image to clipboard for Ctrl+V paste
	_btn_clipboard = Button.new()
	_btn_clipboard.name = "ClipboardBtn"
	_btn_clipboard.icon = icon_image
	_btn_clipboard.tooltip_text = "Set Test Image to Clipboard (then Ctrl+V to paste)"
	_btn_clipboard.custom_minimum_size = Vector2(40, 40)
	_btn_clipboard.expand_icon = true
	_btn_clipboard.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_btn_clipboard.focus_mode = Control.FOCUS_NONE
	_btn_clipboard.pressed.connect(_on_clipboard_pressed)
	_recording_header.add_child(_btn_clipboard)

	# Capture button
	_btn_capture = Button.new()
	_btn_capture.name = "CaptureBtn"
	_btn_capture.icon = icon_camera
	_btn_capture.tooltip_text = "Capture Screenshot (F10)"
	_btn_capture.custom_minimum_size = Vector2(40, 40)
	_btn_capture.expand_icon = true
	_btn_capture.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_btn_capture.focus_mode = Control.FOCUS_NONE
	_btn_capture.pressed.connect(_on_capture_pressed)
	_recording_header.add_child(_btn_capture)

	# Stop button
	_btn_stop = Button.new()
	_btn_stop.name = "StopBtn"
	_btn_stop.icon = icon_stop
	_btn_stop.tooltip_text = "Stop Recording (F11)"
	_btn_stop.custom_minimum_size = Vector2(40, 40)
	_btn_stop.expand_icon = true
	_btn_stop.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_btn_stop.focus_mode = Control.FOCUS_NONE
	_btn_stop.pressed.connect(_on_stop_pressed)
	_recording_header.add_child(_btn_stop)

	# Settings button
	_btn_settings = Button.new()
	_btn_settings.name = "SettingsBtn"
	_btn_settings.icon = icon_settings
	_btn_settings.tooltip_text = "Recording Settings"
	_btn_settings.custom_minimum_size = Vector2(40, 40)
	_btn_settings.expand_icon = true
	_btn_settings.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_btn_settings.focus_mode = Control.FOCUS_NONE
	_btn_settings.pressed.connect(_on_settings_pressed)
	_recording_header.add_child(_btn_settings)

	# Exit button - cancel recording without saving
	_btn_exit = Button.new()
	_btn_exit.name = "ExitBtn"
	_btn_exit.icon = icon_exit
	_btn_exit.tooltip_text = "Exit Recording (ESC)"
	_btn_exit.custom_minimum_size = Vector2(40, 40)
	_btn_exit.expand_icon = true
	_btn_exit.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_btn_exit.focus_mode = Control.FOCUS_NONE
	_btn_exit.pressed.connect(_on_exit_pressed)
	_recording_header.add_child(_btn_exit)

	var header_spacer = Control.new()
	header_spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_recording_header.add_child(header_spacer)

	# Details toggle button
	_recording_details_btn = Button.new()
	_recording_details_btn.text = "▶ Details"
	_recording_details_btn.tooltip_text = "Show/hide recorded steps"
	_recording_details_btn.custom_minimum_size = Vector2(90, 36)
	_recording_details_btn.focus_mode = Control.FOCUS_NONE
	_recording_details_btn.pressed.connect(_on_recording_toggle_details)
	_recording_header.add_child(_recording_details_btn)

	# Event count label
	_recording_event_count_label = Label.new()
	_recording_event_count_label.text = "(0)"
	_recording_event_count_label.add_theme_font_size_override("font_size", 12)
	_recording_event_count_label.add_theme_color_override("font_color", Color(0.7, 0.7, 0.75))
	_recording_header.add_child(_recording_event_count_label)

	# === BODY CONTAINER === (collapsible, hidden by default)
	_recording_body_container = VBoxContainer.new()
	_recording_body_container.visible = false  # Start collapsed
	_recording_body_container.add_theme_constant_override("separation", 8)
	_recording_body_container.mouse_filter = Control.MOUSE_FILTER_STOP
	vbox.add_child(_recording_body_container)

	# Body separator
	var body_sep = HSeparator.new()
	var sep_style = StyleBoxFlat.new()
	sep_style.bg_color = Color(0.35, 0.35, 0.4, 0.6)
	sep_style.set_content_margin(SIDE_TOP, 1)
	sep_style.set_content_margin(SIDE_BOTTOM, 1)
	body_sep.add_theme_stylebox_override("separator", sep_style)
	_recording_body_container.add_child(body_sep)

	# Scrollable step list
	_recording_steps_scroll = ScrollContainer.new()
	_recording_steps_scroll.custom_minimum_size.y = 350
	_recording_steps_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_recording_steps_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_recording_steps_scroll.mouse_filter = Control.MOUSE_FILTER_STOP
	_recording_body_container.add_child(_recording_steps_scroll)

	# Style wider scrollbar (2x default width ~24px)
	var vscroll = _recording_steps_scroll.get_v_scroll_bar()
	if vscroll:
		vscroll.custom_minimum_size.x = 24
		# Style the grabber
		var grabber_style = StyleBoxFlat.new()
		grabber_style.bg_color = Color(0.5, 0.5, 0.55, 0.8)
		grabber_style.set_corner_radius_all(4)
		vscroll.add_theme_stylebox_override("grabber", grabber_style)
		vscroll.add_theme_stylebox_override("grabber_highlight", grabber_style)
		vscroll.add_theme_stylebox_override("grabber_pressed", grabber_style)
		# Style the scroll track
		var scroll_style = StyleBoxFlat.new()
		scroll_style.bg_color = Color(0.2, 0.2, 0.25, 0.5)
		scroll_style.set_corner_radius_all(4)
		vscroll.add_theme_stylebox_override("scroll", scroll_style)

	# Margin container for step list (right margin accounts for 24px scrollbar)
	var steps_margin = MarginContainer.new()
	steps_margin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	steps_margin.add_theme_constant_override("margin_right", 28)
	_recording_steps_scroll.add_child(steps_margin)

	_recording_steps_list = VBoxContainer.new()
	_recording_steps_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_recording_steps_list.add_theme_constant_override("separation", 4)
	steps_margin.add_child(_recording_steps_list)

	# Apply button visibility from config
	_update_button_visibility()

	# Create settings panel (hidden by default)
	_create_settings_panel()

func _update_button_visibility() -> void:
	if _btn_clipboard:
		_btn_clipboard.visible = ScreenshotValidator.show_clipboard_button
	if _btn_capture:
		_btn_capture.visible = ScreenshotValidator.show_capture_button
	_update_hud_width()

func _update_hud_width() -> void:
	# Panel width is now fixed - handled by _update_recording_panel_height()
	pass

func _update_recording_panel_height() -> void:
	if not _recording_panel:
		return

	if _recording_collapsed:
		# Collapsed: header only
		_recording_panel.offset_top = -70
		_recording_panel.offset_left = -436
	else:
		# Expanded: header + body with steps (matches Playback UI size)
		_recording_panel.offset_top = -580
		_recording_panel.offset_left = -618

func _on_recording_toggle_details() -> void:
	if not _recording_body_container or not _recording_details_btn:
		return

	_recording_collapsed = not _recording_collapsed
	_recording_body_container.visible = not _recording_collapsed
	_recording_details_btn.text = "▼ Details" if not _recording_collapsed else "▶ Details"

	# Adjust panel height
	_update_recording_panel_height()

func _clear_recording_steps_ui() -> void:
	# Clear step rows from UI
	if _recording_steps_list:
		for child in _recording_steps_list.get_children():
			child.queue_free()
	_recording_step_rows.clear()
	_update_recording_event_count()

func _update_recording_event_count() -> void:
	if _recording_event_count_label:
		_recording_event_count_label.text = "(%d)" % recorded_events.size()

func _add_recording_step_row(event: Dictionary) -> void:
	if not _recording_steps_list:
		return

	var index = recorded_events.size()
	var row = _create_recording_step_row(index, event)
	_recording_steps_list.add_child(row)
	_recording_step_rows.append(row)

	# Auto-scroll to newest step
	if _recording_steps_scroll:
		_recording_steps_scroll.call_deferred("ensure_control_visible", row)

	# Update event count
	_update_recording_event_count()

func _create_recording_step_row(index: int, event: Dictionary) -> Control:
	var container = VBoxContainer.new()
	container.add_theme_constant_override("separation", 2)

	# Main row panel - styled like Test Editor
	var panel = PanelContainer.new()
	panel.name = "StepPanel"
	var panel_style = StyleBoxFlat.new()
	panel_style.bg_color = Color(0.18, 0.18, 0.22, 0.9)
	panel_style.set_corner_radius_all(4)
	panel.add_theme_stylebox_override("panel", panel_style)

	var inner_row = HBoxContainer.new()
	inner_row.name = "InnerRow"
	inner_row.add_theme_constant_override("separation", 10)
	panel.add_child(inner_row)

	# Index label - left margin spacer
	var idx_spacer = Control.new()
	idx_spacer.custom_minimum_size.x = 3
	inner_row.add_child(idx_spacer)

	# Index label
	var idx_label = Label.new()
	idx_label.text = "%d." % index
	idx_label.custom_minimum_size.x = 28
	idx_label.add_theme_font_size_override("font_size", 15)
	idx_label.add_theme_color_override("font_color", Color(0.6, 0.6, 0.65))
	idx_label.label_settings = LabelSettings.new()
	idx_label.label_settings.font_size = 15
	idx_label.label_settings.font_color = Color(0.6, 0.6, 0.65)
	idx_label.label_settings.outline_size = 1
	idx_label.label_settings.outline_color = Color(0.6, 0.6, 0.65)
	inner_row.add_child(idx_label)

	# Event description
	var desc_label = Label.new()
	desc_label.name = "DescLabel"
	desc_label.text = _get_event_description(event)
	desc_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	desc_label.add_theme_font_size_override("font_size", 13)
	desc_label.add_theme_color_override("font_color", Color(0.85, 0.85, 0.9))
	inner_row.add_child(desc_label)

	# "then wait" label
	var wait_label = Label.new()
	wait_label.text = "then wait"
	wait_label.add_theme_font_size_override("font_size", 12)
	wait_label.add_theme_color_override("font_color", Color(0.6, 0.6, 0.65))
	inner_row.add_child(wait_label)

	# Wait dropdown
	var delay_dropdown = OptionButton.new()
	delay_dropdown.name = "DelayDropdown"
	delay_dropdown.custom_minimum_size.x = 80
	delay_dropdown.focus_mode = Control.FOCUS_NONE
	var current_delay = event.get("wait_after", 100)
	var selected_idx = 0
	for j in range(RECORDING_DELAY_OPTIONS.size()):
		var d = RECORDING_DELAY_OPTIONS[j]
		if d < 1000:
			delay_dropdown.add_item("%dms" % d, d)
		else:
			delay_dropdown.add_item("%.1fs" % (d / 1000.0), d)
		if d == current_delay:
			selected_idx = j
	delay_dropdown.select(selected_idx)
	delay_dropdown.item_selected.connect(_on_recording_step_delay_changed.bind(index - 1))  # -1 for 0-based array
	inner_row.add_child(delay_dropdown)

	# Delete step button (red X)
	var delete_btn = Button.new()
	delete_btn.name = "DeleteBtn"
	delete_btn.icon = load("res://addons/godot-ui-automation/icons/delete_x.svg")
	delete_btn.tooltip_text = "Delete step"
	delete_btn.custom_minimum_size = Vector2(29, 29)
	delete_btn.expand_icon = true
	delete_btn.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
	delete_btn.focus_mode = Control.FOCUS_NONE
	delete_btn.flat = true
	delete_btn.pressed.connect(_on_recording_step_delete.bind(index - 1))  # -1 for 0-based array
	inner_row.add_child(delete_btn)

	# Right margin spacer
	var right_spacer = Control.new()
	right_spacer.custom_minimum_size.x = 4
	inner_row.add_child(right_spacer)

	container.add_child(panel)

	# Note row with icon
	var note_row = HBoxContainer.new()
	note_row.add_theme_constant_override("separation", 5)

	var note_spacer = Control.new()
	note_spacer.custom_minimum_size.x = 28
	note_row.add_child(note_spacer)

	var note_icon = Label.new()
	note_icon.text = "📝"
	note_icon.add_theme_color_override("font_color", Color(0.5, 0.5, 0.55))
	note_row.add_child(note_icon)

	var note_input = LineEdit.new()
	note_input.name = "NoteInput"
	note_input.placeholder_text = "Add note (e.g., 'drag card to column')"
	note_input.text = event.get("note", "")
	note_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	note_input.add_theme_font_size_override("font_size", 12)
	note_input.add_theme_color_override("font_placeholder_color", Color(0.4, 0.4, 0.45))
	note_input.focus_mode = Control.FOCUS_CLICK
	note_input.text_changed.connect(_on_recording_step_note_changed.bind(index - 1))  # -1 for 0-based array
	note_row.add_child(note_input)

	container.add_child(note_row)
	return container

func _get_event_description(event: Dictionary) -> String:
	var event_type = event.get("type", "unknown")
	match event_type:
		"click":
			var pos = event.get("pos", Vector2.ZERO)
			var mods = ""
			if event.get("ctrl", false): mods += "Ctrl+"
			if event.get("shift", false): mods += "Shift+"
			return "%sClick at (%d, %d)" % [mods, int(pos.x), int(pos.y)]
		"double_click":
			var pos = event.get("pos", Vector2.ZERO)
			var mods = ""
			if event.get("ctrl", false): mods += "Ctrl+"
			if event.get("shift", false): mods += "Shift+"
			return "%sDouble-click at (%d, %d)" % [mods, int(pos.x), int(pos.y)]
		"right_click":
			var pos = event.get("pos", Vector2.ZERO)
			return "Right-click at (%d, %d)" % [int(pos.x), int(pos.y)]
		"drag":
			var from_pos = event.get("from", Vector2.ZERO)
			var to_pos = event.get("to", Vector2.ZERO)
			var mods = ""
			if event.get("ctrl", false): mods += "Ctrl+"
			if event.get("shift", false): mods += "Shift+"
			var suffix = " (segment)" if event.get("no_drop", false) else ""
			return "%sDrag (%d,%d) → (%d,%d)%s" % [mods, int(from_pos.x), int(from_pos.y), int(to_pos.x), int(to_pos.y), suffix]
		"pan":
			var from_pos = event.get("from", Vector2.ZERO)
			var to_pos = event.get("to", Vector2.ZERO)
			return "Pan (%d,%d) → (%d,%d)" % [int(from_pos.x), int(from_pos.y), int(to_pos.x), int(to_pos.y)]
		"scroll":
			var direction = event.get("direction", "")
			var mods = ""
			if event.get("ctrl", false): mods += "Ctrl+"
			if event.get("shift", false): mods += "Shift+"
			if event.get("alt", false): mods += "Alt+"
			return "%sScroll %s" % [mods, direction]
		"key":
			var keycode = event.get("keycode", 0)
			var key_name = OS.get_keycode_string(keycode) if keycode > 0 else "?"
			var mods = ""
			if event.get("ctrl", false): mods += "Ctrl+"
			if event.get("shift", false): mods += "Shift+"
			return "Key: %s%s" % [mods, key_name]
		"screenshot_validation":
			return "Screenshot validation"
		"set_clipboard_image":
			return "Set clipboard image"
		_:
			return event_type

func _on_recording_step_delete(event_index: int) -> void:
	# Remove event from array
	if event_index >= 0 and event_index < recorded_events.size():
		recorded_events.remove_at(event_index)

	# Rebuild step rows UI
	_rebuild_recording_steps_ui()

func _rebuild_recording_steps_ui() -> void:
	# Clear and rebuild all step rows
	if _recording_steps_list:
		for child in _recording_steps_list.get_children():
			child.queue_free()
	_recording_step_rows.clear()

	# Recreate rows for all events
	for i in range(recorded_events.size()):
		var event = recorded_events[i]
		var row = _create_recording_step_row(i + 1, event)
		_recording_steps_list.add_child(row)
		_recording_step_rows.append(row)

	_update_recording_event_count()

func _on_recording_step_delay_changed(dropdown_index: int, event_index: int) -> void:
	# Update the wait_after value in the recorded event
	if event_index >= 0 and event_index < recorded_events.size():
		var delay_value = RECORDING_DELAY_OPTIONS[dropdown_index]
		recorded_events[event_index]["wait_after"] = delay_value

func _on_recording_step_note_changed(new_text: String, event_index: int) -> void:
	# Update the note in the recorded event
	if event_index >= 0 and event_index < recorded_events.size():
		recorded_events[event_index]["note"] = new_text

func _on_replay_pressed() -> void:
	# Pause recording and request replay of recorded steps
	if recorded_events.is_empty():
		print("[REC] No steps to replay")
		return

	_is_replaying = true
	is_recording_paused = true

	# Disable buttons during replay
	_set_replay_mode_ui(true)

	# Emit signal to request replay - main plugin will handle playback
	replay_requested.emit(recorded_events.duplicate(true))

# Called by main plugin when replay completes
func on_replay_completed() -> void:
	_is_replaying = false
	is_recording_paused = false
	_set_replay_mode_ui(false)
	print("[REC] Replay complete - continuing recording")

func _set_replay_mode_ui(replaying: bool) -> void:
	# Update UI for replay mode
	if _btn_replay:
		_btn_replay.disabled = replaying
	if _btn_clipboard:
		_btn_clipboard.disabled = replaying
	if _btn_capture:
		_btn_capture.disabled = replaying
	if _btn_stop:
		_btn_stop.disabled = replaying
	if _btn_settings:
		_btn_settings.disabled = replaying

func _create_settings_panel() -> void:
	_settings_panel = PanelContainer.new()
	_settings_panel.name = "SettingsPanel"
	_settings_panel.visible = false
	_settings_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	_settings_panel.process_mode = Node.PROCESS_MODE_ALWAYS
	_settings_panel.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	_settings_panel.anchor_left = 1.0
	_settings_panel.anchor_top = 1.0
	_settings_panel.anchor_right = 1.0
	_settings_panel.anchor_bottom = 1.0
	_settings_panel.offset_left = -940
	_settings_panel.offset_top = -838
	_settings_panel.offset_right = -20
	_settings_panel.offset_bottom = -75
	_recording_indicator.add_child(_settings_panel)

	# Style the panel like other dialogs
	var style = StyleBoxFlat.new()
	style.bg_color = Color(0.12, 0.12, 0.15, 0.98)
	style.border_color = Color(0.3, 0.6, 1.0, 1.0)
	style.set_border_width_all(2)
	style.set_corner_radius_all(10)
	_settings_panel.add_theme_stylebox_override("panel", style)

	var main_vbox = VBoxContainer.new()
	main_vbox.set_anchors_preset(Control.PRESET_FULL_RECT)
	main_vbox.add_theme_constant_override("separation", 12)
	var margin = 16
	main_vbox.offset_left = margin
	main_vbox.offset_top = margin
	main_vbox.offset_right = -margin
	main_vbox.offset_bottom = -margin
	_settings_panel.add_child(main_vbox)

	# Header with title and close button
	var header = HBoxContainer.new()
	header.add_theme_constant_override("separation", 8)
	main_vbox.add_child(header)

	# Title with left margin spacer and vertical offset
	var title_container = VBoxContainer.new()
	title_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(title_container)

	var title_v_spacer = Control.new()
	title_v_spacer.custom_minimum_size = Vector2(0, 3)
	title_container.add_child(title_v_spacer)

	var title_hbox = HBoxContainer.new()
	title_container.add_child(title_hbox)

	var title_spacer = Control.new()
	title_spacer.custom_minimum_size = Vector2(10, 0)
	title_hbox.add_child(title_spacer)

	var title = Label.new()
	title.text = "Settings"
	title.add_theme_font_size_override("font_size", 22)
	title.add_theme_color_override("font_color", Color(0.9, 0.9, 0.95))
	title_hbox.add_child(title)

	# Close button
	var close_container = VBoxContainer.new()
	header.add_child(close_container)

	var close_v_spacer = Control.new()
	close_v_spacer.custom_minimum_size = Vector2(0, 4)
	close_container.add_child(close_v_spacer)

	var close_hbox = HBoxContainer.new()
	close_container.add_child(close_hbox)

	var close_btn = Button.new()
	close_btn.icon = load("res://addons/godot-ui-automation/icons/dismiss_circle.svg")
	close_btn.tooltip_text = "Close"
	close_btn.custom_minimum_size = Vector2(40, 40)
	close_btn.expand_icon = true
	close_btn.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
	close_btn.focus_mode = Control.FOCUS_NONE
	close_btn.flat = true
	close_btn.pressed.connect(_close_settings_panel)
	close_hbox.add_child(close_btn)

	var close_h_spacer = Control.new()
	close_h_spacer.custom_minimum_size = Vector2(4, 0)
	close_hbox.add_child(close_h_spacer)

	# Create TabContainer for Settings, Help, About
	var tabs = TabContainer.new()
	tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL
	tabs.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	main_vbox.add_child(tabs)

	# Settings tab with margins
	var settings_tab = MarginContainer.new()
	settings_tab.name = "Settings"
	settings_tab.add_theme_constant_override("margin_left", 10)
	settings_tab.add_theme_constant_override("margin_right", 10)
	settings_tab.add_theme_constant_override("margin_bottom", 10)
	tabs.add_child(settings_tab)

	_ui_settings = UITestSettings.new()
	_ui_settings.initialize(_tree)
	_ui_settings.set_button_visibility_callback(_update_button_visibility)
	var settings_content = _ui_settings.create_settings_content()
	settings_content.size_flags_vertical = Control.SIZE_EXPAND_FILL
	settings_tab.add_child(settings_content)

	# Help tab with margins
	var help_tab = MarginContainer.new()
	help_tab.name = "Help"
	help_tab.add_theme_constant_override("margin_left", 10)
	help_tab.add_theme_constant_override("margin_right", 10)
	help_tab.add_theme_constant_override("margin_bottom", 10)
	tabs.add_child(help_tab)

	var ui_help = UITestHelp.new()
	ui_help.initialize(_tree)
	var help_content = ui_help.create_help_content()
	help_content.size_flags_vertical = Control.SIZE_EXPAND_FILL
	help_tab.add_child(help_content)

	# About tab with margins
	var about_tab = MarginContainer.new()
	about_tab.name = "About"
	about_tab.add_theme_constant_override("margin_left", 10)
	about_tab.add_theme_constant_override("margin_right", 10)
	about_tab.add_theme_constant_override("margin_bottom", 10)
	tabs.add_child(about_tab)

	var ui_about = UITestAbout.new()
	ui_about.initialize(_tree)
	var about_content = ui_about.create_about_content()
	about_tab.add_child(about_content)

func _close_settings_panel() -> void:
	if _settings_panel:
		_settings_panel.visible = false
		is_recording_paused = false
		_set_hud_buttons_enabled(true)

func _on_settings_pressed() -> void:
	if _settings_panel:
		if _settings_panel.visible:
			_close_settings_panel()
		else:
			_settings_panel.visible = true
			is_recording_paused = true
			_set_hud_buttons_enabled(false)

func _set_hud_buttons_enabled(enabled: bool) -> void:
	# Disable/enable other HUD buttons while settings is open
	if _btn_clipboard:
		_btn_clipboard.disabled = not enabled
	if _btn_capture:
		_btn_capture.disabled = not enabled
	if _btn_stop:
		_btn_stop.disabled = not enabled

func _draw_recording_indicator() -> void:
	var viewport_size = _parent.get_viewport().get_visible_rect().size
	var base_size = 53.0  # 10% bigger than original 48
	var margin = 20.0

	# Gentle pulse animation (0.95 to 1.05 scale range)
	var pulse_time = Time.get_ticks_msec() / 800.0  # Slower pulse
	var pulse_scale = 1.0 + sin(pulse_time) * 0.05  # 5% scale variation
	var indicator_size = base_size * pulse_scale

	# Moved 2px left
	var center = Vector2(
		viewport_size.x - margin - indicator_size / 2 - 2,
		viewport_size.y - margin - indicator_size / 2
	)

	# Outer circle with subtle alpha pulse
	var alpha_pulse = 0.22 + sin(pulse_time) * 0.03
	var color = Color(1.0, 0.2, 0.2, alpha_pulse)

	# Inner circle with stronger pulse
	var inner_pulse = (sin(pulse_time) + 1.0) / 2.0
	var inner_color = Color(1.0, 0.3, 0.3, 0.13 + inner_pulse * 0.17)

	_recording_indicator.draw_circle(center, indicator_size / 2, color)
	_recording_indicator.draw_circle(center, indicator_size / 3, inner_color)

	var font = ThemeDB.fallback_font
	var text_pos = center + Vector2(-14, 5)  # Adjusted for larger size
	_recording_indicator.draw_string(font, text_pos, "REC", HORIZONTAL_ALIGNMENT_LEFT, -1, 13, Color(1.0, 1.0, 1.0, 0.56))

	if is_recording:
		_recording_indicator.queue_redraw()

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
	var clipboard_event = {
		"type": "set_clipboard_image",
		"path": TEST_IMAGE_PATH,
		"mouse_pos": mouse_pos,
		"time": time_offset
	}
	recorded_events.append(clipboard_event)
	_add_recording_step_row(clipboard_event)

	# Visual feedback - briefly flash button green
	if _btn_clipboard:
		_btn_clipboard.modulate = Color(0.3, 1.0, 0.3, 1.0)
		var tween = _tree.create_tween()
		tween.tween_interval(0.5)
		tween.tween_callback(func():
			if _btn_clipboard:
				_btn_clipboard.modulate = Color.WHITE
		)

	print("[REC] Injected test image - press Ctrl+V to paste: %s" % TEST_IMAGE_PATH)

func _on_capture_pressed() -> void:
	request_screenshot_capture()

func _on_stop_pressed() -> void:
	stop_recording()

func _on_exit_pressed() -> void:
	cancel_recording()

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

func _is_typing_in_hud() -> bool:
	# Check if any text input in the recording panel has focus
	if not _recording_panel or not _recording_indicator or not _recording_indicator.visible:
		return false

	var focused = _recording_panel.get_viewport().gui_get_focus_owner()
	if focused == null:
		return false

	# Check if the focused control is a text input within our panel
	if focused is LineEdit or focused is TextEdit:
		# Check if it's a child of our recording panel
		var parent = focused.get_parent()
		while parent:
			if parent == _recording_panel or parent == _settings_panel:
				return true
			parent = parent.get_parent()

	return false

func is_click_on_hud(pos: Vector2) -> bool:
	if not _recording_panel:
		return false
	# Check if recording indicator (parent) is visible
	if not _recording_indicator or not _recording_indicator.visible:
		return false
	# Check panel rect
	if _recording_panel.get_global_rect().has_point(pos):
		return true
	# Check settings panel
	if _settings_panel and _settings_panel.visible and _settings_panel.get_global_rect().has_point(pos):
		return true
	# Also check individual buttons in case they extend beyond container
	if _btn_replay and _btn_replay.get_global_rect().has_point(pos):
		return true
	if _btn_clipboard and _btn_clipboard.visible and _btn_clipboard.get_global_rect().has_point(pos):
		return true
	if _btn_capture and _btn_capture.visible and _btn_capture.get_global_rect().has_point(pos):
		return true
	if _btn_stop and _btn_stop.get_global_rect().has_point(pos):
		return true
	if _btn_settings and _btn_settings.get_global_rect().has_point(pos):
		return true
	if _btn_exit and _btn_exit.get_global_rect().has_point(pos):
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
						"time": time_offset,
						"wait_after": ScreenshotValidator.default_click_delay
					}
					if mouse_down_ctrl:
						dbl_event["ctrl"] = true
					if mouse_down_shift:
						dbl_event["shift"] = true
					recorded_events.append(dbl_event)
					_add_recording_step_row(dbl_event)
					var mods = ("Ctrl+" if mouse_down_ctrl else "") + ("Shift+" if mouse_down_shift else "")
					print("[REC] %sDouble-click at %s" % [mods, mouse_down_pos])
				else:
					var click_event: Dictionary = {
						"type": "click",
						"pos": mouse_down_pos,
						"time": time_offset,
						"wait_after": ScreenshotValidator.default_click_delay
					}
					if mouse_down_ctrl:
						click_event["ctrl"] = true
					if mouse_down_shift:
						click_event["shift"] = true
					recorded_events.append(click_event)
					_add_recording_step_row(click_event)
					var mods = ("Ctrl+" if mouse_down_ctrl else "") + ("Shift+" if mouse_down_shift else "")
					print("[REC] %sClick at %s" % [mods, mouse_down_pos])
			else:
				var drag_event: Dictionary = {
					"type": "drag",
					"from": mouse_down_pos,
					"to": event.global_position,
					"time": time_offset
				}
				# Add modifier keys if pressed
				if mouse_down_ctrl:
					drag_event["ctrl"] = true
				if mouse_down_shift:
					drag_event["shift"] = true
				# Try to identify the object at the drag start position for robust playback
				var item_info = _find_item_at_position(mouse_down_pos)
				var mods = ("Ctrl+" if mouse_down_ctrl else "") + ("Shift+" if mouse_down_shift else "")
				print("[REC] Drag start: from=%s to=%s, item_info=%s" % [mouse_down_pos, event.global_position, item_info])
				if not item_info.is_empty():
					drag_event["object_type"] = item_info.type
					drag_event["object_id"] = item_info.id
					# Store click offset relative to item's top-left corner
					var click_offset = mouse_down_pos - item_info.screen_pos
					drag_event["click_offset"] = click_offset
					print("[REC] %sDrag %s:%s from=%s to=%s" % [
						mods, item_info.type, item_info.id.substr(0, 8), mouse_down_pos, event.global_position
					])
					print("  item_screen_pos=%s click_offset=%s delta=%s" % [
						item_info.screen_pos, click_offset, event.global_position - mouse_down_pos
					])
				else:
					# Store world coordinates for resolution-independent playback
					var has_screen_to_world = _parent and _parent.has_method("screen_to_world")
					var has_world_to_cell = _parent and _parent.has_method("world_to_cell")
					print("[REC] Checking world coord methods: screen_to_world=%s, world_to_cell=%s, _parent=%s" % [
						has_screen_to_world, has_world_to_cell, _parent != null
					])
					if has_screen_to_world and has_world_to_cell:
						var to_world = _parent.screen_to_world(event.global_position)
						var to_cell = _parent.world_to_cell(to_world)
						# Store both world coords (precise) and cell coords (grid-snapped)
						drag_event["to_world"] = to_world
						drag_event["to_cell"] = to_cell
						print("[REC] %sDrag (toolbar) from=%s to=%s" % [mods, mouse_down_pos, event.global_position])
						print("  to_world=%s to_cell=(%d, %d)" % [to_world, to_cell.x, to_cell.y])
					else:
						print("[REC] %sDrag (no object, no world coords) from=%s to=%s delta=%s" % [
							mods, mouse_down_pos, event.global_position, event.global_position - mouse_down_pos
						])
				recorded_events.append(drag_event)
				_add_recording_step_row(drag_event)
			mouse_is_down = false
			mouse_is_double_click = false

	# Middle mouse button - pan/scroll
	elif event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_MIDDLE:
		if is_click_on_hud(event.global_position):
			return
		if event.pressed:
			middle_mouse_down_pos = event.global_position
			middle_mouse_is_down = true
		else:
			if middle_mouse_is_down:
				var distance = event.global_position.distance_to(middle_mouse_down_pos)
				if distance >= 5.0:  # Only record if actually panned
					var pan_event = {
						"type": "pan",
						"from": middle_mouse_down_pos,
						"to": event.global_position,
						"time": time_offset
					}
					recorded_events.append(pan_event)
					_add_recording_step_row(pan_event)
					print("[REC] Pan from=%s to=%s delta=%s" % [
						middle_mouse_down_pos, event.global_position,
						event.global_position - middle_mouse_down_pos
					])
			middle_mouse_is_down = false

	# Right mouse button - cancel/context menu
	elif event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_RIGHT:
		if is_click_on_hud(event.global_position):
			return
		if event.pressed:
			var right_click_event = {
				"type": "right_click",
				"pos": event.global_position,
				"time": time_offset
			}
			recorded_events.append(right_click_event)
			_add_recording_step_row(right_click_event)
			print("[REC] Right-click at %s" % event.global_position)

	# Mouse wheel - zoom/scroll with modifier keys
	elif event is InputEventMouseButton and event.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN]:
		if is_click_on_hud(event.global_position):
			return
		if event.pressed:
			var direction = "in" if event.button_index == MOUSE_BUTTON_WHEEL_UP else "out"
			var scroll_event = {
				"type": "scroll",
				"direction": direction,
				"pos": event.global_position,
				"ctrl": event.ctrl_pressed,
				"shift": event.shift_pressed,
				"alt": event.alt_pressed,
				"factor": event.factor,  # Scroll intensity/amount
				"time": time_offset
			}
			recorded_events.append(scroll_event)
			_add_recording_step_row(scroll_event)
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

	# Skip if typing in recording UI (note input fields)
	if _is_typing_in_hud():
		return false

	# Ctrl+B during drag = terminate drag segment (record drag but keep mouse down)
	if event.ctrl_pressed and event.keycode == KEY_B and mouse_is_down:
		terminate_drag_segment()
		return true  # Consume Ctrl+B, don't record it

	var time_offset = Time.get_ticks_msec() - record_start_time
	var mouse_pos = _parent.get_viewport().get_mouse_position()
	var key_event = {
		"type": "key",
		"keycode": event.keycode,
		"shift": event.shift_pressed,
		"ctrl": event.ctrl_pressed,
		"mouse_pos": mouse_pos,
		"time": time_offset
	}
	recorded_events.append(key_event)
	_add_recording_step_row(key_event)

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
	_add_recording_step_row(drag_event)

	# Reset for next segment - keep mouse_is_down true, update start position
	mouse_down_pos = current_pos
	# Preserve ctrl/shift state for the continued drag

# Adds a screenshot validation as its own event step
func add_screenshot_record(path: String, region: Dictionary) -> void:
	var time_offset = Time.get_ticks_msec() - record_start_time
	# Add as a screenshot_validation event (its own visible step)
	var screenshot_event = {
		"type": "screenshot_validation",
		"path": path,
		"region": region,
		"time": time_offset,
		"wait_after": 100
	}
	recorded_events.append(screenshot_event)
	_add_recording_step_row(screenshot_event)

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
