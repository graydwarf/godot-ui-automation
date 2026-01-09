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
## Shared settings component for Godot UI Automation
## Used by both Recording Settings popup and Test Manager Settings tab

const ScreenshotValidator = preload("res://addons/godot-ui-automation/utils/screenshot-validator.gd")
const Utils = preload("res://addons/godot-ui-automation/utils/utils.gd")

signal settings_changed()  # Emitted when settings affecting HUD visibility change
signal speed_changed(index: int)  # Emitted when playback speed changes

var _tree: SceneTree
var _content: VBoxContainer
var _button_visibility_callback: Callable

# UI element references for updates
var _pixel_row: HBoxContainer
var _color_row: HBoxContainer
var _pixel_slider: HSlider
var _pixel_value: Label
var _color_slider: HSlider
var _color_value: Label

# Initializes the settings component
func initialize(tree: SceneTree) -> void:
	_tree = tree

# Sets a callback for when button visibility settings change
func set_button_visibility_callback(callback: Callable) -> void:
	_button_visibility_callback = callback

# Creates and returns the settings content wrapped in styled container
func create_settings_content() -> PanelContainer:
	ScreenshotValidator.load_config()

	# Outer styled panel with About-style border
	var outer_panel = PanelContainer.new()
	var outer_style = StyleBoxFlat.new()
	outer_style.bg_color = Color(0.12, 0.15, 0.2, 0.8)
	outer_style.border_color = Color(0.3, 0.5, 0.8, 0.6)
	outer_style.set_border_width_all(1)
	outer_style.set_corner_radius_all(8)
	outer_style.set_content_margin_all(10)
	outer_panel.add_theme_stylebox_override("panel", outer_style)
	outer_panel.size_flags_vertical = Control.SIZE_EXPAND_FILL

	# ScrollContainer for future growth
	var scroll = ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	outer_panel.add_child(scroll)

	_content = VBoxContainer.new()
	_content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_content.add_theme_constant_override("separation", 12)
	scroll.add_child(_content)

	_create_playback_section()
	_create_recording_options_section()

	return outer_panel

# ============================================================================
# PLAYBACK SETTINGS SECTION
# ============================================================================

func _create_playback_section() -> void:
	var section = PanelContainer.new()
	var style = StyleBoxFlat.new()
	style.bg_color = Color(0.08, 0.08, 0.1, 0.4)
	style.border_color = Color(0.35, 0.35, 0.4, 0.8)
	style.set_border_width_all(1)
	style.set_corner_radius_all(6)
	style.set_content_margin_all(16)
	section.add_theme_stylebox_override("panel", style)
	_content.add_child(section)

	var vbox = VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 15)
	section.add_child(vbox)

	# Section header with blue title and separator
	var header_container = VBoxContainer.new()
	header_container.add_theme_constant_override("separation", 4)
	vbox.add_child(header_container)

	var label = Label.new()
	label.text = "Playback Options"
	label.add_theme_font_size_override("font_size", 17)
	label.add_theme_color_override("font_color", Color(0.5, 0.8, 0.95))
	header_container.add_child(label)

	var sep = HSeparator.new()
	sep.add_theme_stylebox_override("separator", _create_separator_style())
	header_container.add_child(sep)

	# Playback Speed
	var speed_row = HBoxContainer.new()
	speed_row.add_theme_constant_override("separation", 10)
	vbox.add_child(speed_row)

	var speed_label = Label.new()
	speed_label.text = "Playback Speed:"
	speed_label.add_theme_font_size_override("font_size", 14)
	speed_label.custom_minimum_size.x = 150
	speed_row.add_child(speed_label)

	var speed_dropdown = OptionButton.new()
	speed_dropdown.name = "SpeedDropdown"
	speed_dropdown.add_item("Instant", Utils.Speed.INSTANT)
	speed_dropdown.add_item("Fast (4x)", Utils.Speed.FAST)
	speed_dropdown.add_item("Normal (1x)", Utils.Speed.NORMAL)
	speed_dropdown.add_item("Slow (0.4x)", Utils.Speed.SLOW)
	speed_dropdown.add_item("Step (manual)", Utils.Speed.STEP)
	speed_dropdown.custom_minimum_size.x = 150
	speed_dropdown.item_selected.connect(_on_speed_selected)
	speed_dropdown.select(ScreenshotValidator.playback_speed)
	speed_row.add_child(speed_dropdown)

	# Compare Mode
	var mode_row = HBoxContainer.new()
	mode_row.add_theme_constant_override("separation", 10)
	vbox.add_child(mode_row)

	var mode_label = Label.new()
	mode_label.text = "Compare Mode:"
	mode_label.add_theme_font_size_override("font_size", 14)
	mode_label.custom_minimum_size.x = 150
	mode_row.add_child(mode_label)

	var mode_dropdown = OptionButton.new()
	mode_dropdown.name = "ModeDropdown"
	mode_dropdown.add_item("Pixel Perfect", 0)
	mode_dropdown.add_item("Tolerant", 1)
	mode_dropdown.custom_minimum_size.x = 150
	mode_dropdown.item_selected.connect(_on_compare_mode_selected)
	mode_dropdown.select(ScreenshotValidator.compare_mode)
	mode_row.add_child(mode_dropdown)

	var show_tolerances = (ScreenshotValidator.compare_mode == ScreenshotValidator.CompareMode.TOLERANT)
	var saved_pixel_pct = ScreenshotValidator.compare_tolerance * 100.0
	var saved_color_threshold = ScreenshotValidator.compare_color_threshold

	# Pixel Tolerance
	_pixel_row = HBoxContainer.new()
	_pixel_row.name = "PixelToleranceRow"
	_pixel_row.add_theme_constant_override("separation", 10)
	_pixel_row.visible = show_tolerances
	vbox.add_child(_pixel_row)

	var pixel_label = Label.new()
	pixel_label.text = "Pixel Tolerance:"
	pixel_label.add_theme_font_size_override("font_size", 14)
	pixel_label.custom_minimum_size.x = 150
	_pixel_row.add_child(pixel_label)

	_pixel_slider = HSlider.new()
	_pixel_slider.name = "PixelSlider"
	_pixel_slider.min_value = 0.0
	_pixel_slider.max_value = 10.0
	_pixel_slider.step = 0.1
	_pixel_slider.value = saved_pixel_pct
	_pixel_slider.custom_minimum_size.x = 150
	_pixel_slider.value_changed.connect(_on_pixel_tolerance_changed)
	_pixel_row.add_child(_pixel_slider)

	_pixel_value = Label.new()
	_pixel_value.name = "PixelValue"
	_pixel_value.text = "%.1f%%" % saved_pixel_pct
	_pixel_value.custom_minimum_size.x = 50
	_pixel_row.add_child(_pixel_value)

	var pixel_reset = Button.new()
	pixel_reset.text = "↺"
	pixel_reset.tooltip_text = "Reset to default (2%)"
	pixel_reset.custom_minimum_size = Vector2(28, 24)
	pixel_reset.pressed.connect(_on_pixel_reset)
	_pixel_row.add_child(pixel_reset)

	# Color Threshold
	_color_row = HBoxContainer.new()
	_color_row.name = "ColorThresholdRow"
	_color_row.add_theme_constant_override("separation", 10)
	_color_row.visible = show_tolerances
	vbox.add_child(_color_row)

	var color_label = Label.new()
	color_label.text = "Color Threshold:"
	color_label.add_theme_font_size_override("font_size", 14)
	color_label.custom_minimum_size.x = 150
	_color_row.add_child(color_label)

	_color_slider = HSlider.new()
	_color_slider.name = "ColorSlider"
	_color_slider.min_value = 0
	_color_slider.max_value = 50
	_color_slider.step = 1
	_color_slider.value = saved_color_threshold
	_color_slider.custom_minimum_size.x = 150
	_color_slider.value_changed.connect(_on_color_threshold_changed)
	_color_row.add_child(_color_slider)

	_color_value = Label.new()
	_color_value.name = "ColorValue"
	_color_value.text = "%d" % saved_color_threshold
	_color_value.custom_minimum_size.x = 50
	_color_row.add_child(_color_value)

	var color_reset = Button.new()
	color_reset.text = "↺"
	color_reset.tooltip_text = "Reset to default (5)"
	color_reset.custom_minimum_size = Vector2(28, 24)
	color_reset.pressed.connect(_on_color_reset)
	_color_row.add_child(color_reset)

	# Startup Delay
	var startup_row = HBoxContainer.new()
	startup_row.add_theme_constant_override("separation", 10)
	vbox.add_child(startup_row)

	var startup_label = Label.new()
	startup_label.text = "Startup Delay:"
	startup_label.add_theme_font_size_override("font_size", 14)
	startup_label.custom_minimum_size.x = 150
	startup_row.add_child(startup_label)

	var startup_dropdown = OptionButton.new()
	startup_dropdown.name = "StartupDelayDropdown"
	startup_dropdown.add_item("0s (None)", 0)
	startup_dropdown.add_item("1s", 1000)
	startup_dropdown.add_item("2s", 2000)
	startup_dropdown.add_item("3s (Default)", 3000)
	startup_dropdown.add_item("5s", 5000)
	startup_dropdown.add_item("10s", 10000)
	startup_dropdown.add_item("20s", 20000)
	startup_dropdown.add_item("30s", 30000)
	startup_dropdown.add_item("60s", 60000)
	startup_dropdown.custom_minimum_size.x = 150
	startup_dropdown.item_selected.connect(_on_startup_delay_selected)
	# Select the current startup delay value
	var current_startup = ScreenshotValidator.startup_delay
	for i in range(startup_dropdown.item_count):
		if startup_dropdown.get_item_id(i) == current_startup:
			startup_dropdown.select(i)
			break
	startup_row.add_child(startup_dropdown)

# ============================================================================
# RECORDING OPTIONS SECTION
# ============================================================================

func _create_recording_options_section() -> void:
	var section = PanelContainer.new()
	var style = StyleBoxFlat.new()
	style.bg_color = Color(0.08, 0.08, 0.1, 0.4)
	style.border_color = Color(0.35, 0.35, 0.4, 0.8)
	style.set_border_width_all(1)
	style.set_corner_radius_all(6)
	style.set_content_margin_all(16)
	section.add_theme_stylebox_override("panel", style)
	_content.add_child(section)

	var vbox = VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 15)
	section.add_child(vbox)

	# Section header with blue title and separator
	var header_container = VBoxContainer.new()
	header_container.add_theme_constant_override("separation", 4)
	vbox.add_child(header_container)

	var label = Label.new()
	label.text = "Recording Options"
	label.add_theme_font_size_override("font_size", 17)
	label.add_theme_color_override("font_color", Color(0.5, 0.8, 0.95))
	header_container.add_child(label)

	var sep = HSeparator.new()
	sep.add_theme_stylebox_override("separator", _create_separator_style())
	header_container.add_child(sep)

	var last_step_check = CheckBox.new()
	last_step_check.name = "LastStepCheck"
	last_step_check.text = "Enable last step image capture"
	last_step_check.add_theme_font_size_override("font_size", 16)
	last_step_check.button_pressed = ScreenshotValidator.enable_last_step_capture
	last_step_check.toggled.connect(_on_last_step_toggle)
	vbox.add_child(last_step_check)

	var capture_check = CheckBox.new()
	capture_check.name = "CaptureCheck"
	capture_check.text = "Show Screenshot Capture button"
	capture_check.add_theme_font_size_override("font_size", 16)
	capture_check.button_pressed = ScreenshotValidator.show_capture_button
	capture_check.toggled.connect(_on_capture_toggle)
	vbox.add_child(capture_check)

	var clipboard_check = CheckBox.new()
	clipboard_check.name = "ClipboardCheck"
	clipboard_check.text = "Show Test Image button"
	clipboard_check.add_theme_font_size_override("font_size", 16)
	clipboard_check.button_pressed = ScreenshotValidator.show_clipboard_button
	clipboard_check.toggled.connect(_on_clipboard_toggle)
	vbox.add_child(clipboard_check)

	var maximize_check = CheckBox.new()
	maximize_check.name = "MaximizeCheck"
	maximize_check.text = "Auto-maximize window when recording"
	maximize_check.add_theme_font_size_override("font_size", 16)
	maximize_check.button_pressed = ScreenshotValidator.auto_maximize_recording
	maximize_check.toggled.connect(_on_maximize_toggle)
	vbox.add_child(maximize_check)

	var warnings_check = CheckBox.new()
	warnings_check.name = "WarningsCheck"
	warnings_check.text = "Show viewport mismatch warnings"
	warnings_check.add_theme_font_size_override("font_size", 16)
	warnings_check.button_pressed = ScreenshotValidator.show_viewport_warnings
	warnings_check.toggled.connect(_on_warnings_toggle)
	vbox.add_child(warnings_check)

	# Default Click Delay
	var delay_row = HBoxContainer.new()
	delay_row.add_theme_constant_override("separation", 10)
	vbox.add_child(delay_row)

	var delay_label = Label.new()
	delay_label.text = "Default Click Delay:"
	delay_label.add_theme_font_size_override("font_size", 14)
	delay_label.custom_minimum_size.x = 150
	delay_row.add_child(delay_label)

	var delay_dropdown = OptionButton.new()
	delay_dropdown.name = "DelayDropdown"
	delay_dropdown.add_item("0ms (None)", 0)
	delay_dropdown.add_item("100ms", 100)
	delay_dropdown.add_item("200ms", 200)
	delay_dropdown.add_item("350ms (Default)", 350)
	delay_dropdown.add_item("500ms", 500)
	delay_dropdown.add_item("750ms", 750)
	delay_dropdown.add_item("1000ms", 1000)
	delay_dropdown.custom_minimum_size.x = 150
	delay_dropdown.item_selected.connect(_on_delay_selected)
	# Select the current delay value
	var current_delay = ScreenshotValidator.default_click_delay
	for i in range(delay_dropdown.item_count):
		if delay_dropdown.get_item_id(i) == current_delay:
			delay_dropdown.select(i)
			break
	delay_row.add_child(delay_dropdown)

# ============================================================================
# HELPERS
# ============================================================================

func _create_separator_style() -> StyleBoxLine:
	var style = StyleBoxLine.new()
	style.color = Color(0.35, 0.55, 0.8, 0.6)
	style.thickness = 1
	return style

# ============================================================================
# EVENT HANDLERS
# ============================================================================

func _on_speed_selected(index: int) -> void:
	ScreenshotValidator.playback_speed = index
	ScreenshotValidator.save_config()
	speed_changed.emit(index)

func _on_compare_mode_selected(index: int) -> void:
	if _pixel_row:
		_pixel_row.visible = (index == 1)
	if _color_row:
		_color_row.visible = (index == 1)
	ScreenshotValidator.set_compare_mode(index as ScreenshotValidator.CompareMode)

func _on_pixel_tolerance_changed(value: float) -> void:
	if _pixel_value:
		_pixel_value.text = "%.1f%%" % value
	ScreenshotValidator.compare_tolerance = value / 100.0
	ScreenshotValidator.save_config()

func _on_color_threshold_changed(value: float) -> void:
	if _color_value:
		_color_value.text = "%d" % int(value)
	ScreenshotValidator.compare_color_threshold = int(value)
	ScreenshotValidator.save_config()

func _on_pixel_reset() -> void:
	if _pixel_slider:
		_pixel_slider.value = 2.0

func _on_color_reset() -> void:
	if _color_slider:
		_color_slider.value = 5

func _on_last_step_toggle(pressed: bool) -> void:
	ScreenshotValidator.enable_last_step_capture = pressed
	ScreenshotValidator.save_config()

func _on_capture_toggle(pressed: bool) -> void:
	ScreenshotValidator.show_capture_button = pressed
	ScreenshotValidator.save_config()
	settings_changed.emit()
	if _button_visibility_callback.is_valid():
		_button_visibility_callback.call()

func _on_clipboard_toggle(pressed: bool) -> void:
	ScreenshotValidator.show_clipboard_button = pressed
	ScreenshotValidator.save_config()
	settings_changed.emit()
	if _button_visibility_callback.is_valid():
		_button_visibility_callback.call()

func _on_maximize_toggle(pressed: bool) -> void:
	ScreenshotValidator.auto_maximize_recording = pressed
	ScreenshotValidator.save_config()

func _on_warnings_toggle(pressed: bool) -> void:
	ScreenshotValidator.show_viewport_warnings = pressed
	ScreenshotValidator.save_config()

func _on_delay_selected(index: int) -> void:
	var dropdown = _content.get_node_or_null("PanelContainer/VBoxContainer/HBoxContainer/DelayDropdown")
	if not dropdown:
		# Try finding it differently
		for child in _content.get_children():
			if child is PanelContainer:
				var delay_dd = child.find_child("DelayDropdown", true, false)
				if delay_dd:
					ScreenshotValidator.default_click_delay = delay_dd.get_item_id(index)
					ScreenshotValidator.save_config()
					return
	elif dropdown:
		ScreenshotValidator.default_click_delay = dropdown.get_item_id(index)
		ScreenshotValidator.save_config()

func _on_startup_delay_selected(index: int) -> void:
	for child in _content.get_children():
		if child is PanelContainer:
			var startup_dd = child.find_child("StartupDelayDropdown", true, false)
			if startup_dd:
				ScreenshotValidator.startup_delay = startup_dd.get_item_id(index)
				ScreenshotValidator.save_config()
				return
