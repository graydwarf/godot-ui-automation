extends RefCounted
class_name UITestManager
## Test Manager panel for UI Test Runner

const Utils = preload("res://addons/ui-test-runner/utils.gd")
const FileIO = preload("res://addons/ui-test-runner/file-io.gd")
const CategoryManager = preload("res://addons/ui-test-runner/category-manager.gd")
const ScreenshotValidator = preload("res://addons/ui-test-runner/screenshot-validator.gd")
const Speed = Utils.Speed
const TESTS_DIR = Utils.TESTS_DIR

signal test_run_requested(test_name: String)
signal test_debug_requested(test_name: String)  # Run in step mode
signal test_delete_requested(test_name: String)
signal test_rename_requested(old_name: String, new_display_name: String)
signal test_edit_requested(test_name: String)
signal test_update_baseline_requested(test_name: String)
signal record_new_requested()
signal run_all_requested()
signal category_play_requested(category_name: String)
signal results_clear_requested()
signal view_failed_step_requested(test_name: String, failed_step: int)
signal view_diff_requested(result: Dictionary)
signal speed_changed(speed_index: int)
signal closed()

var _panel: Panel = null
var _backdrop: ColorRect = null  # Modal backdrop to block background clicks
var _tree: SceneTree
var _parent: CanvasLayer

var is_open: bool = false

# Drag and drop state
var dragging_test_name: String = ""
var drag_indicator: Control = null
var drop_line: Control = null
var drop_target_category: String = ""
var drop_target_index: int = -1
var _drag_start_pos: Vector2 = Vector2.ZERO
var _is_dragging: bool = false
var _mouse_down_on_test: String = ""
const DRAG_THRESHOLD: float = 5.0

# Results data (set by main runner)
var batch_results: Array = []

# Confirmation dialog
var _confirm_dialog: Panel = null
var _confirm_backdrop: ColorRect = null
var _pending_delete_test: String = ""
var _pending_delete_category: String = ""

# Input dialog (for new category or rename)
var _input_dialog: Panel = null
var _input_backdrop: ColorRect = null
var _input_field: LineEdit = null
var _editing_category_name: String = ""  # Non-empty when renaming a category

func initialize(tree: SceneTree, parent: CanvasLayer) -> void:
	_tree = tree
	_parent = parent

func is_visible() -> bool:
	return _panel and _panel.visible

func open() -> void:
	is_open = true
	_tree.paused = true

	if not _panel:
		_create_panel()

	refresh_test_list()
	_backdrop.visible = true
	_panel.visible = true

func close() -> void:
	is_open = false
	_tree.paused = false
	# Clear any in-progress drag state to prevent input lockup on reopen
	_cancel_drag()
	if _backdrop:
		_backdrop.visible = false
	if _panel:
		_panel.visible = false
	closed.emit()

func toggle() -> void:
	if is_open:
		close()
	else:
		open()

func switch_to_results_tab() -> void:
	if not _panel:
		return
	var tabs = _panel.get_node_or_null("VBoxContainer/TabContainer")
	if tabs:
		tabs.current_tab = 1

func get_panel() -> Panel:
	return _panel

func handle_input(event: InputEvent) -> bool:
	# Handle drag operations (both during drag and when mouse is down pre-drag)
	if _is_dragging or not _mouse_down_on_test.is_empty():
		if handle_drag_input(event):
			return true

	if is_open and event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		if _is_dragging:
			_cancel_drag(true)  # Cancel drag and refresh
			return true
		close()
		return true
	return false

func _create_panel() -> void:
	# Create modal backdrop first (added before panel so it's behind)
	_backdrop = ColorRect.new()
	_backdrop.name = "TestManagerBackdrop"
	_backdrop.set_anchors_preset(Control.PRESET_FULL_RECT)
	_backdrop.color = Color(0, 0, 0, 0.5)
	_backdrop.mouse_filter = Control.MOUSE_FILTER_STOP
	_backdrop.process_mode = Node.PROCESS_MODE_ALWAYS
	_backdrop.z_index = 90  # Below panel but above other content
	_backdrop.visible = false
	_parent.add_child(_backdrop)

	_panel = Panel.new()
	_panel.name = "TestManagerPanel"
	_panel.process_mode = Node.PROCESS_MODE_ALWAYS
	_panel.z_index = 100  # High z-index - dialogs appear above backdrop

	var viewport_size = _tree.root.get_visible_rect().size
	var panel_size = Vector2(825, 650)
	_panel.position = (viewport_size - panel_size) / 2
	_panel.size = panel_size

	# Style
	var style = StyleBoxFlat.new()
	style.bg_color = Color(0.12, 0.12, 0.15, 0.98)
	style.border_color = Color(0.3, 0.6, 1.0, 1.0)
	style.set_border_width_all(2)
	style.set_corner_radius_all(10)
	_panel.add_theme_stylebox_override("panel", style)

	var vbox = VBoxContainer.new()
	vbox.name = "VBoxContainer"
	vbox.set_anchors_preset(Control.PRESET_FULL_RECT)
	vbox.add_theme_constant_override("separation", 12)
	var margin = 20
	vbox.offset_left = margin
	vbox.offset_top = margin
	vbox.offset_right = -margin
	vbox.offset_bottom = -margin
	_panel.add_child(vbox)

	_create_header(vbox)
	_create_tabs(vbox)

	_parent.add_child(_panel)

func _create_header(vbox: VBoxContainer) -> void:
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
	close_btn.pressed.connect(close)
	header.add_child(close_btn)

func _create_tabs(vbox: VBoxContainer) -> void:
	var tabs = TabContainer.new()
	tabs.name = "TabContainer"
	tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL
	tabs.tab_alignment = TabBar.ALIGNMENT_CENTER
	vbox.add_child(tabs)

	_create_tests_tab(tabs)
	_create_results_tab(tabs)
	_create_settings_tab(tabs)

	# Rename tabs with padding for equal width
	tabs.set_tab_title(0, "   Tests   ")
	tabs.set_tab_title(1, "  Results  ")
	tabs.set_tab_title(2, "  Settings  ")

func _create_tests_tab(tabs: TabContainer) -> void:
	var tests_tab = VBoxContainer.new()
	tests_tab.name = "Tests"
	tests_tab.add_theme_constant_override("separation", 12)
	tabs.add_child(tests_tab)

	# === ACTIONS SECTION ===
	var actions_section = PanelContainer.new()
	var actions_style = StyleBoxFlat.new()
	actions_style.bg_color = Color(0.1, 0.1, 0.12, 0.6)
	actions_style.set_corner_radius_all(6)
	actions_style.set_content_margin_all(12)
	actions_section.add_theme_stylebox_override("panel", actions_style)
	tests_tab.add_child(actions_section)

	var actions_vbox = VBoxContainer.new()
	actions_vbox.add_theme_constant_override("separation", 10)
	actions_section.add_child(actions_vbox)

	# First row: Record and Run All
	var actions_row = HBoxContainer.new()
	actions_row.add_theme_constant_override("separation", 12)
	actions_vbox.add_child(actions_row)

	# Load bold font for action buttons
	var bold_font = SystemFont.new()
	bold_font.font_weight = 700  # Bold weight

	var record_btn = Button.new()
	record_btn.text = "Record New Test"
	record_btn.icon = load("res://addons/ui-test-runner/icons/record.svg")
	record_btn.icon_alignment = HORIZONTAL_ALIGNMENT_LEFT
	record_btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
	record_btn.custom_minimum_size = Vector2(240, 48)
	record_btn.add_theme_font_override("font", bold_font)
	record_btn.add_theme_font_size_override("font_size", 21)
	record_btn.add_theme_constant_override("h_separation", 6)  # Icon to text spacing
	var record_style = StyleBoxFlat.new()
	record_style.bg_color = Color(0.25, 0.25, 0.3, 0.8)
	record_style.set_corner_radius_all(6)
	record_style.set_content_margin(SIDE_LEFT, 22)
	record_btn.add_theme_stylebox_override("normal", record_style)
	# Hover style with same margins
	var record_hover = StyleBoxFlat.new()
	record_hover.bg_color = Color(0.35, 0.35, 0.4, 0.9)
	record_hover.set_corner_radius_all(6)
	record_hover.set_content_margin(SIDE_LEFT, 22)
	record_btn.add_theme_stylebox_override("hover", record_hover)
	# Pressed style with same margins
	var record_pressed = StyleBoxFlat.new()
	record_pressed.bg_color = Color(0.2, 0.2, 0.25, 0.9)
	record_pressed.set_corner_radius_all(6)
	record_pressed.set_content_margin(SIDE_LEFT, 22)
	record_btn.add_theme_stylebox_override("pressed", record_pressed)
	record_btn.add_theme_color_override("font_color", Color.WHITE)
	record_btn.pressed.connect(_on_record_new)
	actions_row.add_child(record_btn)

	var run_all_btn = Button.new()
	run_all_btn.text = "Run All Tests"
	run_all_btn.icon = load("res://addons/ui-test-runner/icons/play.svg")
	run_all_btn.icon_alignment = HORIZONTAL_ALIGNMENT_LEFT
	run_all_btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
	run_all_btn.custom_minimum_size = Vector2(220, 48)
	run_all_btn.add_theme_font_override("font", bold_font)
	run_all_btn.add_theme_font_size_override("font_size", 21)
	run_all_btn.add_theme_constant_override("h_separation", 6)  # Icon to text spacing
	var run_all_style = StyleBoxFlat.new()
	run_all_style.bg_color = Color(0.15, 0.35, 0.15, 0.8)
	run_all_style.set_corner_radius_all(6)
	run_all_style.set_content_margin(SIDE_LEFT, 22)
	run_all_btn.add_theme_stylebox_override("normal", run_all_style)
	# Hover style with same margins
	var run_all_hover = StyleBoxFlat.new()
	run_all_hover.bg_color = Color(0.2, 0.45, 0.2, 0.9)
	run_all_hover.set_corner_radius_all(6)
	run_all_hover.set_content_margin(SIDE_LEFT, 22)
	run_all_btn.add_theme_stylebox_override("hover", run_all_hover)
	# Pressed style with same margins
	var run_all_pressed = StyleBoxFlat.new()
	run_all_pressed.bg_color = Color(0.1, 0.28, 0.1, 0.9)
	run_all_pressed.set_corner_radius_all(6)
	run_all_pressed.set_content_margin(SIDE_LEFT, 22)
	run_all_btn.add_theme_stylebox_override("pressed", run_all_pressed)
	run_all_btn.add_theme_color_override("font_color", Color(0.4, 0.95, 0.4))
	run_all_btn.add_theme_color_override("icon_normal_color", Color(0.4, 0.95, 0.4))  # Green tint
	run_all_btn.pressed.connect(_on_run_all)
	actions_row.add_child(run_all_btn)

	# Second row: New Category
	var actions_row2 = HBoxContainer.new()
	actions_row2.add_theme_constant_override("separation", 12)
	actions_vbox.add_child(actions_row2)

	var new_cat_btn = Button.new()
	new_cat_btn.text = "+ New Category"
	new_cat_btn.custom_minimum_size = Vector2(150, 36)
	new_cat_btn.pressed.connect(_on_new_category)
	actions_row2.add_child(new_cat_btn)

	# === TESTS LIST SECTION ===
	var tests_section = PanelContainer.new()
	tests_section.size_flags_vertical = Control.SIZE_EXPAND_FILL
	var tests_style = StyleBoxFlat.new()
	tests_style.bg_color = Color(0.08, 0.08, 0.1, 0.4)
	tests_style.border_color = Color(0.35, 0.35, 0.4, 0.8)
	tests_style.set_border_width_all(1)
	tests_style.set_corner_radius_all(6)
	tests_style.set_content_margin_all(8)
	tests_section.add_theme_stylebox_override("panel", tests_style)
	tests_tab.add_child(tests_section)

	var scroll = ScrollContainer.new()
	scroll.name = "TestScroll"
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	tests_section.add_child(scroll)

	var test_list = VBoxContainer.new()
	test_list.name = "TestList"
	test_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	test_list.add_theme_constant_override("separation", 2)
	scroll.add_child(test_list)

func _create_results_tab(tabs: TabContainer) -> void:
	var results_tab = VBoxContainer.new()
	results_tab.name = "Results"
	results_tab.add_theme_constant_override("separation", 12)
	tabs.add_child(results_tab)

	# === HEADER SECTION ===
	var header_section = PanelContainer.new()
	var header_style = StyleBoxFlat.new()
	header_style.bg_color = Color(0.1, 0.1, 0.12, 0.6)
	header_style.set_corner_radius_all(6)
	header_style.set_content_margin_all(12)
	header_section.add_theme_stylebox_override("panel", header_style)
	results_tab.add_child(header_section)

	var results_header = HBoxContainer.new()
	results_header.add_theme_constant_override("separation", 12)
	header_section.add_child(results_header)

	var results_label = Label.new()
	results_label.name = "ResultsLabel"
	results_label.text = "Test Results"
	results_label.add_theme_font_size_override("font_size", 18)
	results_label.add_theme_color_override("font_color", Color(0.85, 0.85, 0.9))
	results_header.add_child(results_label)

	var results_spacer = Control.new()
	results_spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	results_header.add_child(results_spacer)

	var clear_btn = Button.new()
	clear_btn.text = "Clear History"
	clear_btn.custom_minimum_size = Vector2(110, 32)
	clear_btn.pressed.connect(_on_clear_results)
	results_header.add_child(clear_btn)

	# === RESULTS LIST SECTION ===
	var results_section = PanelContainer.new()
	results_section.size_flags_vertical = Control.SIZE_EXPAND_FILL
	var results_style = StyleBoxFlat.new()
	results_style.bg_color = Color(0.08, 0.08, 0.1, 0.4)
	results_style.border_color = Color(0.35, 0.35, 0.4, 0.8)
	results_style.set_border_width_all(1)
	results_style.set_corner_radius_all(6)
	results_style.set_content_margin_all(8)
	results_section.add_theme_stylebox_override("panel", results_style)
	results_tab.add_child(results_section)

	var results_scroll = ScrollContainer.new()
	results_scroll.name = "ResultsScroll"
	results_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	results_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	results_section.add_child(results_scroll)

	var results_list = VBoxContainer.new()
	results_list.name = "ResultsList"
	results_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	results_list.add_theme_constant_override("separation", 4)
	results_scroll.add_child(results_list)

func _create_settings_tab(tabs: TabContainer) -> void:
	# Load saved config first
	ScreenshotValidator.load_config()

	var settings_tab = VBoxContainer.new()
	settings_tab.name = "Settings"
	settings_tab.add_theme_constant_override("separation", 12)
	tabs.add_child(settings_tab)

	# === SETTINGS SECTION ===
	var settings_section = PanelContainer.new()
	var settings_style = StyleBoxFlat.new()
	settings_style.bg_color = Color(0.08, 0.08, 0.1, 0.4)
	settings_style.border_color = Color(0.35, 0.35, 0.4, 0.8)
	settings_style.set_border_width_all(1)
	settings_style.set_corner_radius_all(6)
	settings_style.set_content_margin_all(16)
	settings_section.add_theme_stylebox_override("panel", settings_style)
	settings_tab.add_child(settings_section)

	var settings_vbox = VBoxContainer.new()
	settings_vbox.add_theme_constant_override("separation", 15)
	settings_section.add_child(settings_vbox)

	var settings_label = Label.new()
	settings_label.text = "Test Runner Settings"
	settings_label.add_theme_font_size_override("font_size", 18)
	settings_label.add_theme_color_override("font_color", Color(0.85, 0.85, 0.9))
	settings_vbox.add_child(settings_label)

	# Playback Speed
	var speed_row = HBoxContainer.new()
	speed_row.add_theme_constant_override("separation", 10)
	settings_vbox.add_child(speed_row)

	var speed_label = Label.new()
	speed_label.text = "Playback Speed:"
	speed_label.add_theme_font_size_override("font_size", 14)
	speed_label.custom_minimum_size.x = 150
	speed_row.add_child(speed_label)

	var speed_dropdown = OptionButton.new()
	speed_dropdown.name = "SpeedDropdown"
	# Order matches Speed enum: INSTANT=0, FAST=1, NORMAL=2, SLOW=3, STEP=4
	speed_dropdown.add_item("Instant", Speed.INSTANT)
	speed_dropdown.add_item("Fast (4x)", Speed.FAST)
	speed_dropdown.add_item("Normal (1x)", Speed.NORMAL)
	speed_dropdown.add_item("Slow (0.4x)", Speed.SLOW)
	speed_dropdown.add_item("Step (manual)", Speed.STEP)
	speed_dropdown.custom_minimum_size.x = 150
	speed_dropdown.item_selected.connect(_on_speed_dropdown_selected)
	# Initialize from saved config
	speed_dropdown.select(ScreenshotValidator.playback_speed)
	speed_row.add_child(speed_dropdown)

	# Compare Mode
	var mode_row = HBoxContainer.new()
	mode_row.add_theme_constant_override("separation", 10)
	settings_vbox.add_child(mode_row)

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
	# Initialize from saved config
	mode_dropdown.select(ScreenshotValidator.compare_mode)
	mode_row.add_child(mode_dropdown)

	# Determine if tolerance rows should be visible based on saved compare mode
	var show_tolerances = (ScreenshotValidator.compare_mode == ScreenshotValidator.CompareMode.TOLERANT)

	# Get saved tolerance values (convert from ratio to percentage for display)
	var saved_pixel_pct = ScreenshotValidator.compare_tolerance * 100.0
	var saved_color_threshold = ScreenshotValidator.compare_color_threshold

	# Pixel Tolerance (visible when Tolerant mode selected)
	var pixel_row = HBoxContainer.new()
	pixel_row.name = "PixelToleranceRow"
	pixel_row.add_theme_constant_override("separation", 10)
	pixel_row.visible = show_tolerances
	settings_vbox.add_child(pixel_row)

	var pixel_label = Label.new()
	pixel_label.text = "Pixel Tolerance:"
	pixel_label.add_theme_font_size_override("font_size", 14)
	pixel_label.custom_minimum_size.x = 150
	pixel_row.add_child(pixel_label)

	var pixel_slider = HSlider.new()
	pixel_slider.name = "PixelSlider"
	pixel_slider.min_value = 0.0
	pixel_slider.max_value = 10.0  # 0-10% range
	pixel_slider.step = 0.1
	pixel_slider.value = saved_pixel_pct
	pixel_slider.custom_minimum_size.x = 150
	pixel_slider.value_changed.connect(_on_pixel_tolerance_changed)
	pixel_row.add_child(pixel_slider)

	var pixel_value = Label.new()
	pixel_value.name = "PixelValue"
	pixel_value.text = "%.1f%%" % saved_pixel_pct
	pixel_value.custom_minimum_size.x = 50
	pixel_row.add_child(pixel_value)

	var pixel_reset = Button.new()
	pixel_reset.text = "↺"
	pixel_reset.tooltip_text = "Reset to default (2%)"
	pixel_reset.custom_minimum_size = Vector2(28, 24)
	pixel_reset.pressed.connect(_on_pixel_tolerance_reset)
	pixel_row.add_child(pixel_reset)

	# Color Threshold (visible when Tolerant mode selected)
	var color_row = HBoxContainer.new()
	color_row.name = "ColorThresholdRow"
	color_row.add_theme_constant_override("separation", 10)
	color_row.visible = show_tolerances
	settings_vbox.add_child(color_row)

	var color_label = Label.new()
	color_label.text = "Color Threshold:"
	color_label.add_theme_font_size_override("font_size", 14)
	color_label.custom_minimum_size.x = 150
	color_row.add_child(color_label)

	var color_slider = HSlider.new()
	color_slider.name = "ColorSlider"
	color_slider.min_value = 0
	color_slider.max_value = 50  # RGB difference 0-50
	color_slider.step = 1
	color_slider.value = saved_color_threshold
	color_slider.custom_minimum_size.x = 150
	color_slider.value_changed.connect(_on_color_threshold_changed)
	color_row.add_child(color_slider)

	var color_value = Label.new()
	color_value.name = "ColorValue"
	color_value.text = "%d" % saved_color_threshold
	color_value.custom_minimum_size.x = 50
	color_row.add_child(color_value)

	var color_reset = Button.new()
	color_reset.text = "↺"
	color_reset.tooltip_text = "Reset to default (5)"
	color_reset.custom_minimum_size = Vector2(28, 24)
	color_reset.pressed.connect(_on_color_threshold_reset)
	color_row.add_child(color_reset)

func refresh_test_list() -> void:
	if not _panel:
		return

	# Use find_child to handle nested structure
	var scroll = _panel.find_child("TestScroll", true, false)
	if not scroll:
		return
	var test_list = scroll.get_node_or_null("TestList")
	if not test_list:
		return

	# Clear existing - must remove from tree before queue_free to avoid name collisions
	# (queue_free doesn't remove immediately, so new nodes would get auto-generated names)
	for child in test_list.get_children():
		test_list.remove_child(child)
		child.queue_free()

	CategoryManager.load_categories()
	var all_tests = FileIO.get_saved_tests()
	var categorized_tests: Dictionary = {}
	var uncategorized: Array = []

	# Group tests by category
	for test_name in all_tests:
		var category = CategoryManager.test_categories.get(test_name, "")
		if category.is_empty():
			uncategorized.append(test_name)
		else:
			if not categorized_tests.has(category):
				categorized_tests[category] = []
			categorized_tests[category].append(test_name)

	# Add categorized tests
	var all_categories = CategoryManager.get_all_categories()
	for category_name in all_categories:
		var tests = categorized_tests.get(category_name, [])
		var ordered_tests = CategoryManager.get_ordered_tests(category_name, tests)
		_add_category_section(test_list, category_name, ordered_tests)

	# Add uncategorized tests
	for test_name in uncategorized:
		_add_test_row(test_list, test_name, false)

func _add_category_section(test_list: Control, category_name: String, test_names: Array) -> void:
	var is_collapsed = CategoryManager.collapsed_categories.get(category_name, false)

	# Category header
	var header = HBoxContainer.new()
	header.name = "Category_" + category_name
	header.add_theme_constant_override("separation", 8)
	test_list.add_child(header)

	var expand_btn = Button.new()
	expand_btn.text = "▶" if is_collapsed else "▼"
	expand_btn.custom_minimum_size = Vector2(24, 24)
	expand_btn.pressed.connect(_on_toggle_category.bind(category_name))
	header.add_child(expand_btn)

	var cat_label = Button.new()
	cat_label.text = "%s (%d)" % [category_name, test_names.size()]
	cat_label.flat = true
	cat_label.add_theme_font_size_override("font_size", 15)
	cat_label.add_theme_color_override("font_color", Color(0.7, 0.85, 1.0))
	cat_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cat_label.alignment = HORIZONTAL_ALIGNMENT_LEFT
	cat_label.pressed.connect(_on_toggle_category.bind(category_name))
	header.add_child(cat_label)

	var play_btn = Button.new()
	play_btn.text = "▶"
	play_btn.tooltip_text = "Run all tests in category"
	play_btn.custom_minimum_size = Vector2(28, 24)
	play_btn.add_theme_color_override("font_color", Color(0.3, 0.85, 0.3))
	play_btn.add_theme_color_override("font_hover_color", Color(0.5, 1.0, 0.5))
	play_btn.pressed.connect(_on_play_category.bind(category_name))
	header.add_child(play_btn)

	# Edit button
	var edit_btn = Button.new()
	edit_btn.text = "✏"
	edit_btn.tooltip_text = "Rename category"
	edit_btn.custom_minimum_size = Vector2(28, 24)
	edit_btn.pressed.connect(_on_edit_category.bind(category_name))
	header.add_child(edit_btn)

	# Delete button with red X
	var del_btn = Button.new()
	del_btn.text = "✕"
	del_btn.add_theme_color_override("font_color", Color(1, 0.35, 0.35))
	del_btn.add_theme_color_override("font_hover_color", Color(1, 0.5, 0.5))
	del_btn.add_theme_font_size_override("font_size", 16)
	del_btn.tooltip_text = "Delete category (tests will become uncategorized)"
	del_btn.custom_minimum_size = Vector2(28, 24)
	del_btn.pressed.connect(_on_delete_category_confirm.bind(category_name))
	header.add_child(del_btn)

	# Tests container
	var tests_container = VBoxContainer.new()
	tests_container.name = "Tests_" + category_name
	tests_container.add_theme_constant_override("separation", 2)
	tests_container.visible = not is_collapsed
	test_list.add_child(tests_container)

	for test_name in test_names:
		_add_test_row(tests_container, test_name, true)

func _add_test_row(container: Control, test_name: String, indented: bool = false) -> Control:
	var row = HBoxContainer.new()
	row.name = "Test_" + test_name
	row.add_theme_constant_override("separation", 8)
	container.add_child(row)

	if indented:
		var spacer = Control.new()
		spacer.custom_minimum_size.x = 24
		row.add_child(spacer)

	# Drag handle
	var drag_handle = Label.new()
	drag_handle.text = "≡"
	drag_handle.add_theme_font_size_override("font_size", 16)
	drag_handle.add_theme_color_override("font_color", Color(0.5, 0.5, 0.55))
	drag_handle.tooltip_text = "Drag to reorder"
	drag_handle.mouse_filter = Control.MOUSE_FILTER_STOP
	drag_handle.custom_minimum_size = Vector2(20, 0)
	drag_handle.gui_input.connect(_on_drag_handle_input.bind(test_name, row))
	row.add_child(drag_handle)

	# Load test data for display name
	var filepath = TESTS_DIR + "/" + test_name + ".json"
	var test_data = FileIO.load_test(filepath)
	var display_name = test_data.get("name", test_name) if not test_data.is_empty() else test_name

	# Editable test name - click to rename inline
	var name_edit = LineEdit.new()
	name_edit.name = "NameEdit"
	name_edit.text = display_name
	name_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_edit.editable = false  # Start as read-only, click to edit
	name_edit.selecting_enabled = false
	name_edit.add_theme_color_override("font_color", Color(0.85, 0.85, 0.9))
	name_edit.add_theme_color_override("font_uneditable_color", Color(0.85, 0.85, 0.9))
	# Make it look like a label when not editing
	var readonly_style = StyleBoxFlat.new()
	readonly_style.bg_color = Color(0, 0, 0, 0)
	name_edit.add_theme_stylebox_override("read_only", readonly_style)
	# Click to enter edit mode (only if not dragging)
	name_edit.gui_input.connect(_on_name_edit_gui_input.bind(name_edit, test_name))
	name_edit.text_submitted.connect(_on_name_edit_submitted.bind(name_edit, test_name))
	name_edit.focus_exited.connect(_on_name_edit_focus_exited.bind(name_edit, test_name))
	row.add_child(name_edit)

	# Action buttons
	var play_btn = Button.new()
	play_btn.text = "▶"
	play_btn.tooltip_text = "Run test"
	play_btn.custom_minimum_size = Vector2(28, 28)
	play_btn.add_theme_color_override("font_color", Color(0.3, 0.85, 0.3))
	play_btn.add_theme_color_override("font_hover_color", Color(0.5, 1.0, 0.5))
	play_btn.pressed.connect(_on_test_run.bind(test_name))
	row.add_child(play_btn)

	# Debug/step mode button - runs test with position debug info
	var debug_btn = Button.new()
	debug_btn.text = ">|"
	debug_btn.tooltip_text = "Debug: step through with position info"
	debug_btn.custom_minimum_size = Vector2(28, 28)
	debug_btn.add_theme_color_override("font_color", Color(1.0, 0.7, 0.2))
	debug_btn.add_theme_color_override("font_hover_color", Color(1.0, 0.85, 0.4))
	debug_btn.pressed.connect(_on_test_debug.bind(test_name))
	row.add_child(debug_btn)

	var edit_btn = Button.new()
	edit_btn.text = "✏"
	edit_btn.tooltip_text = "Edit test steps"
	edit_btn.custom_minimum_size = Vector2(28, 28)
	edit_btn.pressed.connect(_on_test_edit.bind(test_name))
	row.add_child(edit_btn)

	var baseline_btn = Button.new()
	baseline_btn.text = "↻"
	baseline_btn.tooltip_text = "Rerecord test"
	baseline_btn.custom_minimum_size = Vector2(32, 28)
	baseline_btn.add_theme_font_size_override("font_size", 18)  # 15% larger
	baseline_btn.add_theme_color_override("font_color", Color.WHITE)
	baseline_btn.pressed.connect(_on_test_update_baseline.bind(test_name))
	row.add_child(baseline_btn)

	# Delete button with red X
	var del_btn = Button.new()
	del_btn.text = "✕"
	del_btn.add_theme_color_override("font_color", Color(1, 0.35, 0.35))
	del_btn.add_theme_color_override("font_hover_color", Color(1, 0.5, 0.5))
	del_btn.add_theme_font_size_override("font_size", 16)
	del_btn.tooltip_text = "Delete test"
	del_btn.custom_minimum_size = Vector2(28, 28)
	del_btn.pressed.connect(_on_test_delete_confirm.bind(test_name))
	row.add_child(del_btn)

	return row

# Inline rename handlers
func _on_name_edit_gui_input(event: InputEvent, name_edit: LineEdit, _test_name: String) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		if not name_edit.editable:
			name_edit.editable = true
			name_edit.selecting_enabled = true
			name_edit.select_all()
			name_edit.grab_focus()

func _on_name_edit_submitted(new_text: String, name_edit: LineEdit, test_name: String) -> void:
	name_edit.editable = false
	name_edit.selecting_enabled = false
	name_edit.deselect()
	name_edit.release_focus()
	_do_inline_rename(test_name, new_text)

func _on_name_edit_focus_exited(name_edit: LineEdit, test_name: String) -> void:
	if name_edit.editable:
		name_edit.editable = false
		name_edit.selecting_enabled = false
		name_edit.deselect()
		_do_inline_rename(test_name, name_edit.text)

func _do_inline_rename(old_test_name: String, new_display_name: String) -> void:
	var display_name = new_display_name.strip_edges()
	if display_name.is_empty():
		refresh_test_list()  # Revert to original
		return

	var new_filename = Utils.sanitize_filename(display_name)
	if new_filename.is_empty() or new_filename == old_test_name:
		return  # No change

	# Emit rename request to be handled by main runner
	test_rename_requested.emit(old_test_name, new_display_name)

func update_results_tab() -> void:
	if not _panel:
		return

	# Use find_child to handle nested structure
	var results_scroll = _panel.find_child("ResultsScroll", true, false)
	var results_list = results_scroll.get_node_or_null("ResultsList") if results_scroll else null
	var results_label = _panel.find_child("ResultsLabel", true, false)
	if not results_list:
		return

	# Clear existing
	for child in results_list.get_children():
		child.queue_free()

	if batch_results.is_empty():
		var empty_label = Label.new()
		empty_label.text = "No test results yet. Run tests to see results."
		empty_label.add_theme_color_override("font_color", Color(0.5, 0.5, 0.55))
		results_list.add_child(empty_label)
		if results_label:
			results_label.text = "Test Results"
		return

	# Count passed/failed/cancelled
	var passed_count = 0
	var failed_count = 0
	var cancelled_count = 0
	for result in batch_results:
		if result.get("cancelled", false):
			cancelled_count += 1
		elif result.passed:
			passed_count += 1
		else:
			failed_count += 1

	if results_label:
		var text = "Test Results: %d passed, %d failed" % [passed_count, failed_count]
		if cancelled_count > 0:
			text += ", %d cancelled" % cancelled_count
		results_label.text = text

	# Add result rows
	for result in batch_results:
		_add_result_row(results_list, result)

func _add_result_row(results_list: Control, result: Dictionary) -> void:
	var row = HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	results_list.add_child(row)

	var is_cancelled = result.get("cancelled", false)

	var status = Label.new()
	if is_cancelled:
		status.text = "⊘"  # Cancelled symbol
		status.add_theme_color_override("font_color", Color(1, 0.7, 0.2))  # Orange
	elif result.passed:
		status.text = "✓"
		status.add_theme_color_override("font_color", Color(0.3, 0.9, 0.3))  # Green
	else:
		status.text = "✗"
		status.add_theme_color_override("font_color", Color(1, 0.4, 0.4))  # Red
	status.add_theme_font_size_override("font_size", 16)
	status.custom_minimum_size.x = 24
	row.add_child(status)

	var name_label = Label.new()
	name_label.text = result.name + (" (cancelled)" if is_cancelled else "")
	name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_label.add_theme_color_override("font_color", Color(0.85, 0.85, 0.9))
	row.add_child(name_label)

	# Only show View Diff for failed tests (not cancelled, not passed)
	if not result.passed and not is_cancelled:
		if result.failed_step > 0:
			var step_btn = Button.new()
			step_btn.text = "Step %d" % result.failed_step
			step_btn.tooltip_text = "View failed step"
			step_btn.custom_minimum_size = Vector2(70, 28)
			step_btn.pressed.connect(_on_view_failed_step.bind(result.name, result.failed_step))
			row.add_child(step_btn)

		var diff_btn = Button.new()
		diff_btn.text = "View Diff"
		diff_btn.tooltip_text = "Compare screenshots"
		diff_btn.custom_minimum_size = Vector2(80, 28)
		diff_btn.pressed.connect(_on_view_diff.bind(result))
		row.add_child(diff_btn)

# Signal handlers
func _on_record_new() -> void:
	close()
	record_new_requested.emit()

func _on_run_all() -> void:
	run_all_requested.emit()

func _on_new_category() -> void:
	_editing_category_name = ""
	_show_input_dialog("New Category", "Enter category name:", "")

func _on_edit_category(category_name: String) -> void:
	_editing_category_name = category_name
	_show_input_dialog("Rename Category", "Enter new name:", category_name)

func _on_clear_results() -> void:
	results_clear_requested.emit()

func _on_toggle_category(category_name: String) -> void:
	var is_collapsed = CategoryManager.collapsed_categories.get(category_name, false)
	CategoryManager.collapsed_categories[category_name] = not is_collapsed
	CategoryManager.save_categories()
	refresh_test_list()

func _on_play_category(category_name: String) -> void:
	category_play_requested.emit(category_name)

func _on_delete_category(category_name: String) -> void:
	# Delete all tests in this category
	var tests_to_delete = []
	for test_name in CategoryManager.test_categories:
		if CategoryManager.test_categories[test_name] == category_name:
			tests_to_delete.append(test_name)

	# Delete each test file and emit signal
	for test_name in tests_to_delete:
		test_delete_requested.emit(test_name)
		CategoryManager.test_categories.erase(test_name)

	# Remove category from tracking
	CategoryManager.collapsed_categories.erase(category_name)
	if CategoryManager.category_test_order.has(category_name):
		CategoryManager.category_test_order.erase(category_name)

	CategoryManager.save_categories()
	refresh_test_list()

func _on_test_run(test_name: String) -> void:
	close()
	test_run_requested.emit(test_name)

func _on_test_debug(test_name: String) -> void:
	close()
	test_debug_requested.emit(test_name)

func _on_test_edit(test_name: String) -> void:
	test_edit_requested.emit(test_name)

func _on_test_update_baseline(test_name: String) -> void:
	test_update_baseline_requested.emit(test_name)

func _on_test_delete(test_name: String) -> void:
	test_delete_requested.emit(test_name)

func _on_view_failed_step(test_name: String, failed_step: int) -> void:
	view_failed_step_requested.emit(test_name, failed_step)

func _on_view_diff(result: Dictionary) -> void:
	view_diff_requested.emit(result)

func _on_speed_dropdown_selected(index: int) -> void:
	ScreenshotValidator.playback_speed = index
	ScreenshotValidator.save_config()
	speed_changed.emit(index)

func _on_compare_mode_selected(index: int) -> void:
	# index 0 = Pixel Perfect, index 1 = Tolerant
	var pixel_row = _panel.find_child("PixelToleranceRow", true, false)
	var color_row = _panel.find_child("ColorThresholdRow", true, false)
	if pixel_row:
		pixel_row.visible = (index == 1)
	if color_row:
		color_row.visible = (index == 1)
	# Save to config
	ScreenshotValidator.set_compare_mode(index as ScreenshotValidator.CompareMode)

func _on_pixel_tolerance_changed(value: float) -> void:
	var pixel_value = _panel.find_child("PixelValue", true, false)
	if pixel_value:
		pixel_value.text = "%.1f%%" % value
	# Save to config (convert from percentage to ratio)
	ScreenshotValidator.compare_tolerance = value / 100.0
	ScreenshotValidator.save_config()

func _on_color_threshold_changed(value: float) -> void:
	var color_value = _panel.find_child("ColorValue", true, false)
	if color_value:
		color_value.text = "%d" % int(value)
	# Save to config (integer RGB difference 0-255)
	ScreenshotValidator.compare_color_threshold = int(value)
	ScreenshotValidator.save_config()

func _on_pixel_tolerance_reset() -> void:
	var default_pct = 2.0  # 2% default
	var pixel_slider = _panel.find_child("PixelSlider", true, false)
	if pixel_slider:
		pixel_slider.value = default_pct  # This triggers _on_pixel_tolerance_changed

func _on_color_threshold_reset() -> void:
	var default_threshold = 5  # Default color threshold
	var color_slider = _panel.find_child("ColorSlider", true, false)
	if color_slider:
		color_slider.value = default_threshold  # This triggers _on_color_threshold_changed

# Confirmation dialog methods
func _on_test_delete_confirm(test_name: String) -> void:
	_pending_delete_test = test_name
	_pending_delete_category = ""
	_show_confirm_dialog("Delete Test", "Are you sure you want to delete '%s'?" % test_name)

func _on_delete_category_confirm(category_name: String) -> void:
	_pending_delete_test = ""
	_pending_delete_category = category_name
	# Count tests in this category
	var test_count = 0
	for test_name in CategoryManager.test_categories:
		if CategoryManager.test_categories[test_name] == category_name:
			test_count += 1
	var test_warning = ""
	if test_count > 0:
		test_warning = "\n\n%d test%s will be permanently deleted." % [test_count, "s" if test_count != 1 else ""]
	_show_confirm_dialog("Delete Category", "Are you sure you want to delete category '%s'?%s" % [category_name, test_warning])

func _show_confirm_dialog(title: String, message: String) -> void:
	# Create backdrop
	if _confirm_backdrop:
		_confirm_backdrop.queue_free()
	_confirm_backdrop = ColorRect.new()
	_confirm_backdrop.name = "ConfirmBackdrop"
	_confirm_backdrop.set_anchors_preset(Control.PRESET_FULL_RECT)
	_confirm_backdrop.color = Color(0, 0, 0, 0.6)
	_confirm_backdrop.mouse_filter = Control.MOUSE_FILTER_STOP
	_confirm_backdrop.process_mode = Node.PROCESS_MODE_ALWAYS
	_confirm_backdrop.z_index = 110  # Above test manager panel
	_parent.add_child(_confirm_backdrop)

	# Create dialog panel
	if _confirm_dialog:
		_confirm_dialog.queue_free()
	_confirm_dialog = Panel.new()
	_confirm_dialog.name = "ConfirmDialog"
	_confirm_dialog.process_mode = Node.PROCESS_MODE_ALWAYS
	_confirm_dialog.z_index = 120  # Above backdrop

	var dialog_size = Vector2(440, 200)  # 10% larger to prevent button overlap
	var viewport_size = _tree.root.get_visible_rect().size
	_confirm_dialog.position = (viewport_size - dialog_size) / 2
	_confirm_dialog.size = dialog_size

	# Style matching Test Manager
	var style = StyleBoxFlat.new()
	style.bg_color = Color(0.15, 0.15, 0.18, 0.98)
	style.border_color = Color(1, 0.4, 0.4, 1.0)  # Red border for delete warning
	style.set_border_width_all(2)
	style.set_corner_radius_all(10)
	_confirm_dialog.add_theme_stylebox_override("panel", style)

	var vbox = VBoxContainer.new()
	vbox.set_anchors_preset(Control.PRESET_FULL_RECT)
	vbox.add_theme_constant_override("separation", 15)
	var margin = 20
	vbox.offset_left = margin
	vbox.offset_top = margin
	vbox.offset_right = -margin
	vbox.offset_bottom = -margin
	_confirm_dialog.add_child(vbox)

	# Title
	var title_label = Label.new()
	title_label.text = title
	title_label.add_theme_font_size_override("font_size", 20)
	title_label.add_theme_color_override("font_color", Color(1, 0.5, 0.5))  # Red tint
	title_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(title_label)

	# Message
	var message_label = Label.new()
	message_label.text = message
	message_label.add_theme_font_size_override("font_size", 14)
	message_label.add_theme_color_override("font_color", Color(0.85, 0.85, 0.9))
	message_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	message_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	message_label.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vbox.add_child(message_label)

	# Buttons row
	var btn_row = HBoxContainer.new()
	btn_row.add_theme_constant_override("separation", 20)
	btn_row.alignment = BoxContainer.ALIGNMENT_CENTER
	vbox.add_child(btn_row)

	var cancel_btn = Button.new()
	cancel_btn.text = "Cancel"
	cancel_btn.custom_minimum_size = Vector2(100, 36)
	cancel_btn.pressed.connect(_on_confirm_cancel)
	btn_row.add_child(cancel_btn)

	var confirm_btn = Button.new()
	confirm_btn.text = "Delete"
	confirm_btn.custom_minimum_size = Vector2(100, 36)
	var confirm_style = StyleBoxFlat.new()
	confirm_style.bg_color = Color(0.6, 0.2, 0.2, 0.9)
	confirm_style.set_corner_radius_all(4)
	confirm_btn.add_theme_stylebox_override("normal", confirm_style)
	confirm_btn.pressed.connect(_on_confirm_delete)
	btn_row.add_child(confirm_btn)

	_parent.add_child(_confirm_dialog)

func _on_confirm_cancel() -> void:
	_pending_delete_test = ""
	_pending_delete_category = ""
	_close_confirm_dialog()

func _on_confirm_delete() -> void:
	if not _pending_delete_test.is_empty():
		_on_test_delete(_pending_delete_test)
	elif not _pending_delete_category.is_empty():
		_on_delete_category(_pending_delete_category)
	_pending_delete_test = ""
	_pending_delete_category = ""
	_close_confirm_dialog()

func _close_confirm_dialog() -> void:
	if _confirm_backdrop:
		_confirm_backdrop.queue_free()
		_confirm_backdrop = null
	if _confirm_dialog:
		_confirm_dialog.queue_free()
		_confirm_dialog = null

# Input dialog methods (for new category or rename)
func _show_input_dialog(title: String, message: String, initial_value: String = "") -> void:
	# Create backdrop
	if _input_backdrop:
		_input_backdrop.queue_free()
	_input_backdrop = ColorRect.new()
	_input_backdrop.name = "InputBackdrop"
	_input_backdrop.set_anchors_preset(Control.PRESET_FULL_RECT)
	_input_backdrop.color = Color(0, 0, 0, 0.6)
	_input_backdrop.mouse_filter = Control.MOUSE_FILTER_STOP
	_input_backdrop.process_mode = Node.PROCESS_MODE_ALWAYS
	_input_backdrop.z_index = 110
	_parent.add_child(_input_backdrop)

	# Create dialog panel
	if _input_dialog:
		_input_dialog.queue_free()
	_input_dialog = Panel.new()
	_input_dialog.name = "InputDialog"
	_input_dialog.process_mode = Node.PROCESS_MODE_ALWAYS
	_input_dialog.z_index = 120

	var dialog_size = Vector2(400, 180)
	var viewport_size = _tree.root.get_visible_rect().size
	_input_dialog.position = (viewport_size - dialog_size) / 2
	_input_dialog.size = dialog_size

	# Style matching Test Manager
	var style = StyleBoxFlat.new()
	style.bg_color = Color(0.15, 0.15, 0.18, 0.98)
	style.border_color = Color(0.3, 0.6, 1.0, 1.0)  # Blue border
	style.set_border_width_all(2)
	style.set_corner_radius_all(10)
	_input_dialog.add_theme_stylebox_override("panel", style)

	var vbox = VBoxContainer.new()
	vbox.set_anchors_preset(Control.PRESET_FULL_RECT)
	vbox.add_theme_constant_override("separation", 12)
	var margin = 20
	vbox.offset_left = margin
	vbox.offset_top = margin
	vbox.offset_right = -margin
	vbox.offset_bottom = -margin
	_input_dialog.add_child(vbox)

	# Title
	var title_label = Label.new()
	title_label.text = title
	title_label.add_theme_font_size_override("font_size", 20)
	title_label.add_theme_color_override("font_color", Color(0.7, 0.85, 1.0))
	title_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(title_label)

	# Message
	var message_label = Label.new()
	message_label.text = message
	message_label.add_theme_font_size_override("font_size", 14)
	message_label.add_theme_color_override("font_color", Color(0.85, 0.85, 0.9))
	vbox.add_child(message_label)

	# Input field
	_input_field = LineEdit.new()
	_input_field.placeholder_text = "Category name..."
	_input_field.text = initial_value
	_input_field.custom_minimum_size.y = 32
	_input_field.text_submitted.connect(_on_input_submitted)
	vbox.add_child(_input_field)

	# Buttons row
	var btn_row = HBoxContainer.new()
	btn_row.add_theme_constant_override("separation", 20)
	btn_row.alignment = BoxContainer.ALIGNMENT_CENTER
	vbox.add_child(btn_row)

	var cancel_btn = Button.new()
	cancel_btn.text = "Cancel"
	cancel_btn.custom_minimum_size = Vector2(100, 36)
	cancel_btn.pressed.connect(_on_input_cancel)
	btn_row.add_child(cancel_btn)

	var action_btn = Button.new()
	action_btn.text = "Rename" if not _editing_category_name.is_empty() else "Create"
	action_btn.custom_minimum_size = Vector2(100, 36)
	var action_style = StyleBoxFlat.new()
	action_style.bg_color = Color(0.2, 0.4, 0.6, 0.9)
	action_style.set_corner_radius_all(4)
	action_btn.add_theme_stylebox_override("normal", action_style)
	action_btn.pressed.connect(_on_input_create)
	btn_row.add_child(action_btn)

	_parent.add_child(_input_dialog)

	# Focus the input field and select all if editing
	_input_field.call_deferred("grab_focus")
	if not initial_value.is_empty():
		_input_field.call_deferred("select_all")

func _on_input_submitted(_text: String) -> void:
	_on_input_create()

func _on_input_cancel() -> void:
	_close_input_dialog()

func _on_input_create() -> void:
	var new_name = _input_field.text.strip_edges()
	if new_name.is_empty():
		_close_input_dialog()
		return

	if not _editing_category_name.is_empty():
		# Renaming existing category
		if new_name != _editing_category_name:
			CategoryManager.rename_category(_editing_category_name, new_name)
			refresh_test_list()
	else:
		# Creating new category
		if not CategoryManager.category_test_order.has(new_name):
			CategoryManager.category_test_order[new_name] = []
			CategoryManager.save_categories()
			refresh_test_list()

	_close_input_dialog()

func _close_input_dialog() -> void:
	if _input_backdrop:
		_input_backdrop.queue_free()
		_input_backdrop = null
	if _input_dialog:
		_input_dialog.queue_free()
		_input_dialog = null
	_input_field = null
	_editing_category_name = ""

# =============================================================================
# DRAG AND DROP
# =============================================================================

var _dragging_row: Control = null

func handle_drag_input(event: InputEvent) -> bool:
	"""Called from main input handler to track drag during motion."""

	# Handle pre-drag state (mouse down but not yet dragging)
	if not _mouse_down_on_test.is_empty() and not _is_dragging:
		if event is InputEventMouseMotion:
			var distance = event.global_position.distance_to(_drag_start_pos)
			if distance > DRAG_THRESHOLD and _dragging_row:
				_start_drag(_mouse_down_on_test, _dragging_row)
				return true
		elif event is InputEventMouseButton:
			if event.button_index == MOUSE_BUTTON_LEFT and not event.pressed:
				# Mouse released without drag - just reset
				_mouse_down_on_test = ""
				_dragging_row = null
				return false
		return false

	# Handle active drag state
	if not _is_dragging:
		return false

	if event is InputEventMouseMotion:
		_update_drag(event.global_position)
		return true
	elif event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT and not event.pressed:
			_end_drag()
			return true

	return false

func _on_drag_handle_input(event: InputEvent, test_name: String, row: Control) -> void:
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT:
			if event.pressed:
				_mouse_down_on_test = test_name
				_drag_start_pos = event.global_position
				_is_dragging = false
				_dragging_row = row
			else:
				# Mouse released
				if _is_dragging:
					_end_drag()
				_mouse_down_on_test = ""
				_is_dragging = false
				_dragging_row = null

	elif event is InputEventMouseMotion:
		if _mouse_down_on_test == test_name and not _is_dragging:
			var distance = event.global_position.distance_to(_drag_start_pos)
			if distance > DRAG_THRESHOLD:
				_start_drag(test_name, row)

func _start_drag(test_name: String, row: Control) -> void:
	_is_dragging = true
	dragging_test_name = test_name

	# Create drag indicator
	if drag_indicator:
		drag_indicator.queue_free()
	drag_indicator = Panel.new()
	drag_indicator.name = "DragIndicator"
	drag_indicator.z_index = 200
	drag_indicator.size = Vector2(300, 28)
	drag_indicator.mouse_filter = Control.MOUSE_FILTER_IGNORE

	var style = StyleBoxFlat.new()
	style.bg_color = Color(0.3, 0.5, 0.8, 0.9)
	style.set_corner_radius_all(4)
	drag_indicator.add_theme_stylebox_override("panel", style)

	var label = Label.new()
	label.text = "  ≡  " + test_name
	label.add_theme_color_override("font_color", Color.WHITE)
	label.set_anchors_preset(Control.PRESET_FULL_RECT)
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	drag_indicator.add_child(label)

	_parent.add_child(drag_indicator)
	drag_indicator.global_position = _drag_start_pos - Vector2(10, 14)

	# Create drop line indicator
	if drop_line:
		drop_line.queue_free()
	drop_line = ColorRect.new()
	drop_line.name = "DropLine"
	drop_line.z_index = 199
	drop_line.color = Color(0.3, 0.8, 0.3, 0.8)
	drop_line.size = Vector2(350, 3)
	drop_line.visible = false
	drop_line.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_parent.add_child(drop_line)

	# Dim the original row
	row.modulate = Color(1, 1, 1, 0.3)

func _update_drag(mouse_pos: Vector2) -> void:
	if not drag_indicator:
		return

	drag_indicator.global_position = mouse_pos - Vector2(10, 14)

	# Find drop target
	var target = _find_drop_target(mouse_pos)
	drop_target_category = target.category
	drop_target_index = target.index

	if drop_line:
		if not target.category.is_empty() or target.index >= 0:
			drop_line.visible = true
			drop_line.global_position = target.line_pos
		else:
			drop_line.visible = false

func _end_drag() -> void:
	if not _is_dragging:
		return

	var test_name = dragging_test_name

	# Move test to new category/position
	if not drop_target_category.is_empty() or drop_target_index >= 0:
		var old_category = CategoryManager.test_categories.get(test_name, "")

		# Update category assignment
		if not drop_target_category.is_empty():
			CategoryManager.set_test_category(test_name, drop_target_category, drop_target_index)
		else:
			# Dropped outside categories - uncategorize
			if old_category:
				CategoryManager.test_categories.erase(test_name)

		CategoryManager.save_categories()

	_cancel_drag()
	refresh_test_list()

func _cancel_drag(do_refresh: bool = false) -> void:
	_is_dragging = false
	dragging_test_name = ""
	_mouse_down_on_test = ""
	drop_target_category = ""
	drop_target_index = -1

	if drag_indicator:
		drag_indicator.queue_free()
		drag_indicator = null
	if drop_line:
		drop_line.queue_free()
		drop_line = null

	_dragging_row = null

	if do_refresh:
		refresh_test_list()

func _find_drop_target(mouse_pos: Vector2) -> Dictionary:
	var result = {"category": "", "index": -1, "line_pos": Vector2.ZERO}

	if not _panel:
		return result

	var scroll = _panel.find_child("TestScroll", true, false)
	if not scroll:
		return result
	var test_list = scroll.get_node_or_null("TestList")
	if not test_list:
		return result

	# Check each category
	for child in test_list.get_children():
		if child.name.begins_with("Category_"):
			var cat_name = child.name.substr(9)  # Remove "Category_" prefix
			var cat_rect = Rect2(child.global_position, child.size)

			# Check if mouse is over category header
			if cat_rect.has_point(mouse_pos):
				result.category = cat_name
				result.index = 0
				result.line_pos = Vector2(child.global_position.x, child.global_position.y + child.size.y)
				return result

		elif child.name.begins_with("Tests_"):
			var cat_name = child.name.substr(6)  # Remove "Tests_" prefix
			if not child.visible:
				continue

			# Check tests in this category
			var test_idx = 0
			for test_row in child.get_children():
				var row_rect = Rect2(test_row.global_position, test_row.size)
				var mid_y = test_row.global_position.y + test_row.size.y / 2

				if mouse_pos.y < mid_y:
					result.category = cat_name
					result.index = test_idx
					result.line_pos = Vector2(test_row.global_position.x, test_row.global_position.y)
					return result

				test_idx += 1

			# Check if mouse is below last test in category
			if child.get_child_count() > 0:
				var last_row = child.get_child(-1)
				var last_bottom = last_row.global_position.y + last_row.size.y
				if mouse_pos.y >= last_row.global_position.y and mouse_pos.y < last_bottom + 20:
					result.category = cat_name
					result.index = child.get_child_count()
					result.line_pos = Vector2(last_row.global_position.x, last_bottom)
					return result

	return result
