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
## Test Manager panel for Godot UI Automation

const Utils = preload("res://addons/godot-ui-automation/utils/utils.gd")
const FileIO = preload("res://addons/godot-ui-automation/utils/file-io.gd")
const CategoryManager = preload("res://addons/godot-ui-automation/utils/category-manager.gd")
const ScreenshotValidator = preload("res://addons/godot-ui-automation/utils/screenshot-validator.gd")
const UITestSettings = preload("res://addons/godot-ui-automation/ui/ui-settings.gd")
const UITestHelp = preload("res://addons/godot-ui-automation/ui/ui-help.gd")
const UITestAbout = preload("res://addons/godot-ui-automation/ui/ui-about.gd")
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
signal run_tests_requested(test_names: Array)  # Run specific list of tests
signal category_play_requested(category_name: String)
signal results_clear_requested()
signal view_failed_step_requested(test_name: String, failed_step: int)
signal view_diff_requested(result: Dictionary)
signal speed_changed(speed_index: int)
signal test_rerun_requested(test_name: String, result_index: int)
signal test_debug_from_results_requested(test_name: String)
signal run_rerun_all_requested(test_names: Array)
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
var test_run_history: Array = []  # [{id, timestamp, datetime, results}]
var _collapsed_runs: Dictionary = {}  # {run_id: bool} tracks collapsed state
var _expanded_run_id: String = ""  # The one run that's expanded (empty = all collapsed)
var _expanded_categories_in_runs: Dictionary = {}  # {run_id: {category: bool}} tracks category expansion

# Confirmation dialog
var _confirm_dialog: Panel = null
var _confirm_backdrop: ColorRect = null
var _pending_delete_test: String = ""
var _pending_delete_category: String = ""
var _pending_clear_history: bool = false

# Input dialog (for new category or rename)
var _input_dialog: Panel = null
var _input_backdrop: ColorRect = null
var _input_field: LineEdit = null
var _editing_category_name: String = ""  # Non-empty when renaming a category

# Environment mismatch dialog
var _env_dialog: Panel = null
var _env_backdrop: ColorRect = null
var _env_test_checkboxes: Dictionary = {}  # {test_name: CheckBox}
var _pending_run_tests: Array = []  # Tests waiting to run after env dialog
var _pending_run_mode: String = ""  # "single", "batch", "category", "rerun"
var _pending_category_name: String = ""  # For category runs
var _ui_settings: UITestSettings = null  # Shared settings component

func initialize(tree: SceneTree, parent: CanvasLayer) -> void:
	_tree = tree
	_parent = parent
	# Connect to viewport size changes to re-center dialogs
	if not _tree.root.size_changed.is_connected(_on_viewport_size_changed):
		_tree.root.size_changed.connect(_on_viewport_size_changed)

func is_visible() -> bool:
	return _panel and _panel.visible

func open() -> void:
	is_open = true
	_tree.paused = true

	if not _panel:
		_create_panel()

	refresh_test_list()
	update_results_tab()
	_backdrop.visible = true
	_panel.visible = true
	# Center immediately and again after short delay to handle viewport size changes (e.g., after fullscreen)
	_center_panel()
	_tree.create_timer(0.05).timeout.connect(_center_panel)

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

func _on_viewport_size_changed() -> void:
	"""Re-center all visible dialogs when viewport size changes."""
	_center_panel()
	_center_confirm_dialog()
	_center_input_dialog()
	_center_env_dialog()

func _center_panel() -> void:
	"""Center the main panel in the viewport."""
	if not _panel or not _panel.visible:
		return
	var viewport_size = _tree.root.get_visible_rect().size
	_panel.position = (viewport_size - _panel.size) / 2

func _center_confirm_dialog() -> void:
	"""Center the confirmation dialog in the viewport."""
	if not _confirm_dialog or not _confirm_dialog.visible:
		return
	var viewport_size = _tree.root.get_visible_rect().size
	_confirm_dialog.position = (viewport_size - _confirm_dialog.size) / 2

func _center_input_dialog() -> void:
	"""Center the input dialog in the viewport."""
	if not _input_dialog or not _input_dialog.visible:
		return
	var viewport_size = _tree.root.get_visible_rect().size
	_input_dialog.position = (viewport_size - _input_dialog.size) / 2

func _center_env_dialog() -> void:
	"""Center the environment dialog in the viewport."""
	if not _env_dialog or not _env_dialog.visible:
		return
	var viewport_size = _tree.root.get_visible_rect().size
	_env_dialog.position = (viewport_size - _env_dialog.size) / 2

func switch_to_results_tab() -> void:
	if not _panel:
		return
	var tabs = _panel.get_node_or_null("VBoxContainer/TabContainer")
	if tabs:
		tabs.current_tab = 1
	# Scroll results to top
	var results_scroll = _panel.find_child("ResultsScroll", true, false) as ScrollContainer
	if results_scroll:
		results_scroll.scroll_vertical = 0

func set_expanded_run(run_id: String) -> void:
	_expanded_run_id = run_id

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
	close_btn.icon = load("res://addons/godot-ui-automation/icons/dismiss_circle.svg")
	close_btn.tooltip_text = "Close (ESC)"
	close_btn.custom_minimum_size = Vector2(48, 48)
	close_btn.expand_icon = true
	close_btn.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
	close_btn.focus_mode = Control.FOCUS_NONE
	close_btn.flat = true
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
	_create_help_tab(tabs)
	_create_about_tab(tabs)

	# Rename tabs with padding for equal width
	tabs.set_tab_title(0, "   Tests   ")
	tabs.set_tab_title(1, "  Results  ")
	tabs.set_tab_title(2, "  Settings  ")
	tabs.set_tab_title(3, "   Help   ")
	tabs.set_tab_title(4, "   About   ")

func _create_tests_tab(tabs: TabContainer) -> void:
	var tests_tab = MarginContainer.new()
	tests_tab.name = "Tests"
	tests_tab.add_theme_constant_override("margin_left", 10)
	tests_tab.add_theme_constant_override("margin_right", 10)
	tests_tab.add_theme_constant_override("margin_bottom", 10)
	tabs.add_child(tests_tab)

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
	tests_tab.add_child(outer_panel)

	var inner_vbox = VBoxContainer.new()
	inner_vbox.add_theme_constant_override("separation", 12)
	inner_vbox.size_flags_vertical = Control.SIZE_EXPAND_FILL
	outer_panel.add_child(inner_vbox)

	# === ACTIONS SECTION ===
	var actions_section = PanelContainer.new()
	var actions_style = StyleBoxFlat.new()
	actions_style.bg_color = Color(0.1, 0.1, 0.12, 0.6)
	actions_style.set_corner_radius_all(6)
	actions_style.set_content_margin_all(12)
	actions_section.add_theme_stylebox_override("panel", actions_style)
	inner_vbox.add_child(actions_section)

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
	record_btn.icon = load("res://addons/godot-ui-automation/icons/record.svg")
	record_btn.icon_alignment = HORIZONTAL_ALIGNMENT_LEFT
	record_btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
	record_btn.custom_minimum_size = Vector2(240, 48)
	record_btn.add_theme_font_override("font", bold_font)
	record_btn.add_theme_font_size_override("font_size", 21)
	record_btn.add_theme_constant_override("h_separation", 10)  # Icon to text spacing
	var record_style = StyleBoxFlat.new()
	record_style.bg_color = Color(0.25, 0.25, 0.3, 0.8)
	record_style.set_corner_radius_all(6)
	record_style.set_content_margin(SIDE_LEFT, 16)
	record_style.set_content_margin(SIDE_RIGHT, 4)
	record_btn.add_theme_stylebox_override("normal", record_style)
	# Hover style with same margins
	var record_hover = StyleBoxFlat.new()
	record_hover.bg_color = Color(0.35, 0.35, 0.4, 0.9)
	record_hover.set_corner_radius_all(6)
	record_hover.set_content_margin(SIDE_LEFT, 16)
	record_hover.set_content_margin(SIDE_RIGHT, 4)
	record_btn.add_theme_stylebox_override("hover", record_hover)
	# Pressed style with same margins
	var record_pressed = StyleBoxFlat.new()
	record_pressed.bg_color = Color(0.2, 0.2, 0.25, 0.9)
	record_pressed.set_corner_radius_all(6)
	record_pressed.set_content_margin(SIDE_LEFT, 16)
	record_pressed.set_content_margin(SIDE_RIGHT, 4)
	record_btn.add_theme_stylebox_override("pressed", record_pressed)
	record_btn.add_theme_color_override("font_color", Color.WHITE)
	record_btn.pressed.connect(_on_record_new)
	actions_row.add_child(record_btn)

	var run_all_btn = Button.new()
	run_all_btn.text = "Run All Tests"
	run_all_btn.icon = load("res://addons/godot-ui-automation/icons/play.svg")
	run_all_btn.icon_alignment = HORIZONTAL_ALIGNMENT_LEFT
	run_all_btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
	run_all_btn.custom_minimum_size = Vector2(220, 48)
	run_all_btn.add_theme_font_override("font", bold_font)
	run_all_btn.add_theme_font_size_override("font_size", 21)
	run_all_btn.add_theme_constant_override("h_separation", 10)  # Icon to text spacing
	var run_all_style = StyleBoxFlat.new()
	run_all_style.bg_color = Color(0.15, 0.35, 0.15, 0.8)
	run_all_style.set_corner_radius_all(6)
	run_all_style.set_content_margin(SIDE_LEFT, 16)
	run_all_style.set_content_margin(SIDE_RIGHT, 4)
	run_all_btn.add_theme_stylebox_override("normal", run_all_style)
	# Hover style with same margins
	var run_all_hover = StyleBoxFlat.new()
	run_all_hover.bg_color = Color(0.2, 0.45, 0.2, 0.9)
	run_all_hover.set_corner_radius_all(6)
	run_all_hover.set_content_margin(SIDE_LEFT, 16)
	run_all_hover.set_content_margin(SIDE_RIGHT, 4)
	run_all_btn.add_theme_stylebox_override("hover", run_all_hover)
	# Pressed style with same margins
	var run_all_pressed = StyleBoxFlat.new()
	run_all_pressed.bg_color = Color(0.1, 0.28, 0.1, 0.9)
	run_all_pressed.set_corner_radius_all(6)
	run_all_pressed.set_content_margin(SIDE_LEFT, 16)
	run_all_pressed.set_content_margin(SIDE_RIGHT, 4)
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
	tests_style.set_content_margin(SIDE_LEFT, 8)
	tests_style.set_content_margin(SIDE_TOP, 8)
	tests_style.set_content_margin(SIDE_RIGHT, 12)  # 8 + 4 = 12 for delete button spacing
	tests_style.set_content_margin(SIDE_BOTTOM, 8)
	tests_section.add_theme_stylebox_override("panel", tests_style)
	inner_vbox.add_child(tests_section)

	var scroll = ScrollContainer.new()
	scroll.name = "TestScroll"
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	tests_section.add_child(scroll)

	var scroll_margin = MarginContainer.new()
	scroll_margin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll_margin.add_theme_constant_override("margin_right", 10)
	scroll.add_child(scroll_margin)

	var test_list = VBoxContainer.new()
	test_list.name = "TestList"
	test_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	test_list.add_theme_constant_override("separation", 2)
	scroll_margin.add_child(test_list)

func _create_results_tab(tabs: TabContainer) -> void:
	var results_tab = MarginContainer.new()
	results_tab.name = "Results"
	results_tab.add_theme_constant_override("margin_left", 10)
	results_tab.add_theme_constant_override("margin_right", 10)
	results_tab.add_theme_constant_override("margin_bottom", 10)
	tabs.add_child(results_tab)

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
	results_tab.add_child(outer_panel)

	var inner_vbox = VBoxContainer.new()
	inner_vbox.add_theme_constant_override("separation", 12)
	inner_vbox.size_flags_vertical = Control.SIZE_EXPAND_FILL
	outer_panel.add_child(inner_vbox)

	# === HEADER SECTION with styled title ===
	var header_vbox = VBoxContainer.new()
	header_vbox.add_theme_constant_override("separation", 8)
	inner_vbox.add_child(header_vbox)

	var title_row = HBoxContainer.new()
	title_row.add_theme_constant_override("separation", 12)
	header_vbox.add_child(title_row)

	var results_label = Label.new()
	results_label.name = "ResultsLabel"
	results_label.text = "Test Run History"
	results_label.add_theme_font_size_override("font_size", 17)
	results_label.add_theme_color_override("font_color", Color(0.5, 0.8, 0.95))
	title_row.add_child(results_label)

	var results_spacer = Control.new()
	results_spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title_row.add_child(results_spacer)

	var clear_btn = Button.new()
	clear_btn.text = "Clear History"
	clear_btn.custom_minimum_size = Vector2(110, 32)
	clear_btn.pressed.connect(_on_clear_results)
	title_row.add_child(clear_btn)

	# Separator line under title
	var sep = HSeparator.new()
	var sep_style = StyleBoxLine.new()
	sep_style.color = Color(0.35, 0.55, 0.8, 0.6)
	sep_style.thickness = 1
	sep.add_theme_stylebox_override("separator", sep_style)
	header_vbox.add_child(sep)

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
	inner_vbox.add_child(results_section)

	var results_scroll = ScrollContainer.new()
	results_scroll.name = "ResultsScroll"
	results_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	results_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	results_section.add_child(results_scroll)

	var results_margin = MarginContainer.new()
	results_margin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	results_margin.add_theme_constant_override("margin_right", 10)
	results_scroll.add_child(results_margin)

	var results_list = VBoxContainer.new()
	results_list.name = "ResultsList"
	results_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	results_list.add_theme_constant_override("separation", 4)
	results_margin.add_child(results_list)

func _create_settings_tab(tabs: TabContainer) -> void:
	var settings_tab = MarginContainer.new()
	settings_tab.name = "Settings"
	settings_tab.add_theme_constant_override("margin_left", 10)
	settings_tab.add_theme_constant_override("margin_right", 10)
	settings_tab.add_theme_constant_override("margin_bottom", 10)
	tabs.add_child(settings_tab)

	# Create shared settings content
	_ui_settings = UITestSettings.new()
	_ui_settings.initialize(_tree)
	_ui_settings.speed_changed.connect(_on_ui_settings_speed_changed)
	var settings_content = _ui_settings.create_settings_content()
	settings_content.size_flags_vertical = Control.SIZE_EXPAND_FILL
	settings_tab.add_child(settings_content)

func _on_ui_settings_speed_changed(index: int) -> void:
	speed_changed.emit(index)


func _create_help_tab(tabs: TabContainer) -> void:
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


func _create_about_tab(tabs: TabContainer) -> void:
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


func refresh_test_list() -> void:
	if not _panel:
		return

	# Use find_child to handle nested structure
	var scroll = _panel.find_child("TestScroll", true, false)
	if not scroll:
		return
	var test_list = scroll.find_child("TestList", true, false)
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
	play_btn.icon = load("res://addons/godot-ui-automation/icons/play.svg")
	play_btn.tooltip_text = "Run all tests in category"
	play_btn.custom_minimum_size = Vector2(28, 28)
	play_btn.expand_icon = true
	play_btn.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
	play_btn.pressed.connect(_on_play_category.bind(category_name))
	header.add_child(play_btn)

	# Edit button
	var edit_btn = Button.new()
	edit_btn.icon = load("res://addons/godot-ui-automation/icons/edit_pencil.svg")
	edit_btn.tooltip_text = "Rename category"
	edit_btn.custom_minimum_size = Vector2(28, 28)
	edit_btn.expand_icon = true
	edit_btn.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
	edit_btn.pressed.connect(_on_edit_category.bind(category_name))
	header.add_child(edit_btn)

	# Delete button with red X
	var del_btn = Button.new()
	del_btn.icon = load("res://addons/godot-ui-automation/icons/delete_x.svg")
	del_btn.tooltip_text = "Delete category (tests will become uncategorized)"
	del_btn.custom_minimum_size = Vector2(29, 25)
	del_btn.expand_icon = true
	del_btn.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
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
	play_btn.icon = load("res://addons/godot-ui-automation/icons/play.svg")
	play_btn.tooltip_text = Utils.TOOLTIP_RUN_TEST
	play_btn.custom_minimum_size = Vector2(28, 28)
	play_btn.expand_icon = true
	play_btn.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
	play_btn.pressed.connect(_on_test_run.bind(test_name))
	row.add_child(play_btn)

	var edit_btn = Button.new()
	edit_btn.icon = load("res://addons/godot-ui-automation/icons/edit_pencil.svg")
	edit_btn.tooltip_text = Utils.TOOLTIP_EDIT_TEST
	edit_btn.custom_minimum_size = Vector2(28, 28)
	edit_btn.expand_icon = true
	edit_btn.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
	edit_btn.pressed.connect(_on_test_edit.bind(test_name))
	row.add_child(edit_btn)

	var baseline_btn = Button.new()
	baseline_btn.icon = load("res://addons/godot-ui-automation/icons/record.svg")
	baseline_btn.tooltip_text = Utils.TOOLTIP_RERECORD_TEST
	baseline_btn.custom_minimum_size = Vector2(28, 28)
	baseline_btn.expand_icon = true
	baseline_btn.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
	baseline_btn.pressed.connect(_on_test_update_baseline.bind(test_name))
	row.add_child(baseline_btn)

	# Delete button with red X
	var del_btn = Button.new()
	del_btn.icon = load("res://addons/godot-ui-automation/icons/delete_x.svg")
	del_btn.tooltip_text = Utils.TOOLTIP_DELETE_TEST
	del_btn.custom_minimum_size = Vector2(29, 29)
	del_btn.expand_icon = true
	del_btn.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
	del_btn.pressed.connect(_on_test_delete_confirm.bind(test_name))
	row.add_child(del_btn)

	return row

# Check if test environment matches current environment
func _get_environment_status(test_data: Dictionary) -> String:
	var recorded_env = test_data.get("recorded_environment", {})

	# No recorded environment = unknown (legacy test)
	if recorded_env.is_empty():
		return "unknown"

	# Get current environment
	var screen_idx = DisplayServer.window_get_current_screen()
	var screen_size = DisplayServer.screen_get_size(screen_idx)
	var viewport_size = _tree.root.get_viewport().get_visible_rect().size

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

	if viewport_matches and monitor_matches:
		return "match"
	else:
		return "mismatch"

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
	var results_list = results_scroll.find_child("ResultsList", true, false) if results_scroll else null
	var results_label = _panel.find_child("ResultsLabel", true, false)
	if not results_list:
		return

	# Clear existing
	for child in results_list.get_children():
		child.queue_free()

	if test_run_history.is_empty():
		var empty_label = Label.new()
		empty_label.text = "No test results yet. Run tests to see results."
		empty_label.add_theme_color_override("font_color", Color(0.5, 0.5, 0.55))
		results_list.add_child(empty_label)
		if results_label:
			results_label.text = "Test Run History"
		return

	# Update header with run count
	if results_label:
		results_label.text = "Test Run History (%d runs)" % test_run_history.size()

	# Add each run as a collapsible section (newest first - already sorted)
	for run_data in test_run_history:
		_add_run_section(results_list, run_data)

# Adds a collapsible run section with header and test results
func _add_run_section(results_list: Control, run_data: Dictionary) -> void:
	var run_id = run_data.get("id", "")
	var datetime_str = run_data.get("datetime", "Unknown")
	var results = run_data.get("results", [])
	# Collapsed by default, only expanded if it's the designated expanded run
	var is_collapsed = (run_id != _expanded_run_id)

	# Count passed/failed/cancelled for summary
	var passed_count = 0
	var failed_count = 0
	var cancelled_count = 0
	for result in results:
		if result.get("cancelled", false):
			cancelled_count += 1
		elif result.get("passed", false):
			passed_count += 1
		else:
			failed_count += 1

	# Run header row
	var header = HBoxContainer.new()
	header.name = "Run_" + run_id
	header.add_theme_constant_override("separation", 8)
	results_list.add_child(header)

	# Expand/collapse button
	var expand_btn = Button.new()
	expand_btn.text = "▶" if is_collapsed else "▼"
	expand_btn.custom_minimum_size = Vector2(24, 24)
	expand_btn.pressed.connect(_on_toggle_run.bind(run_id))
	header.add_child(expand_btn)

	# Status indicator (green checkmark if all passed, red X if any failed)
	var status_icon = Label.new()
	if failed_count > 0:
		status_icon.text = "✗"
		status_icon.add_theme_color_override("font_color", Color(1, 0.4, 0.4))
	elif cancelled_count == results.size():
		status_icon.text = "⊘"
		status_icon.add_theme_color_override("font_color", Color(1, 0.7, 0.2))
	else:
		status_icon.text = "✓"
		status_icon.add_theme_color_override("font_color", Color(0.3, 0.9, 0.3))
	status_icon.add_theme_font_size_override("font_size", 16)
	header.add_child(status_icon)

	# Datetime and summary label (clickable to toggle) - includes test count
	var summary_text = "%s  •  %d passed" % [datetime_str, passed_count]
	if failed_count > 0:
		summary_text += ", %d failed" % failed_count
	if cancelled_count > 0:
		summary_text += ", %d cancelled" % cancelled_count
	summary_text += " (%d)" % results.size()

	var summary_btn = Button.new()
	summary_btn.text = summary_text
	summary_btn.flat = true
	summary_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	summary_btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
	summary_btn.add_theme_font_size_override("font_size", 14)
	summary_btn.add_theme_color_override("font_color", Color(0.75, 0.85, 1.0))
	summary_btn.pressed.connect(_on_toggle_run.bind(run_id))
	header.add_child(summary_btn)

	# Rerun all button - reruns all tests from this run
	var rerun_all_btn = Button.new()
	rerun_all_btn.icon = load("res://addons/godot-ui-automation/icons/play.svg")
	rerun_all_btn.tooltip_text = "Rerun all %d tests from this run" % results.size()
	rerun_all_btn.custom_minimum_size = Vector2(28, 28)
	rerun_all_btn.expand_icon = true
	rerun_all_btn.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
	# Collect test names for rerun
	var test_names: Array = []
	for result in results:
		var name = result.get("name", "")
		if not name.is_empty():
			test_names.append(name)
	rerun_all_btn.pressed.connect(_on_rerun_all_from_run.bind(test_names))
	header.add_child(rerun_all_btn)

	# Results container (collapsible)
	var results_container = VBoxContainer.new()
	results_container.name = "Results_" + run_id
	results_container.add_theme_constant_override("separation", 2)
	results_container.visible = not is_collapsed
	results_list.add_child(results_container)

	# Group results by category
	var categorized_results: Dictionary = {}  # category -> [results]
	var uncategorized_results: Array = []

	for i in range(results.size()):
		var result = results[i]
		var test_name = result.get("name", "")
		var category = CategoryManager.get_test_category(test_name)
		if category.is_empty():
			uncategorized_results.append({"result": result, "index": i})
		else:
			if not categorized_results.has(category):
				categorized_results[category] = []
			categorized_results[category].append({"result": result, "index": i})

	# Get sorted category names
	var sorted_categories = categorized_results.keys()
	sorted_categories.sort()

	# Add category sections
	for category_name in sorted_categories:
		_add_category_section_in_run(results_container, category_name, categorized_results[category_name], run_id)

	# Add uncategorized results at the end (no category header)
	for item in uncategorized_results:
		_add_result_row_in_run(results_container, item.result, run_id, item.index, 32)

# Toggle run collapsed state
func _on_toggle_run(run_id: String) -> void:
	# Toggle: if this run is expanded, collapse it; otherwise expand it (and collapse others)
	if _expanded_run_id == run_id:
		_expanded_run_id = ""  # Collapse all
	else:
		_expanded_run_id = run_id  # Expand this one
	update_results_tab()

# Adds a category section within a run with collapsible header and test results
func _add_category_section_in_run(container: Control, category_name: String, results_with_indices: Array, run_id: String) -> void:
	# Count passed/failed/cancelled for this category first (needed for default expansion)
	var passed_count = 0
	var failed_count = 0
	var cancelled_count = 0
	for item in results_with_indices:
		var result = item.result
		if result.get("cancelled", false):
			cancelled_count += 1
		elif result.get("passed", false):
			passed_count += 1
		else:
			failed_count += 1

	# Initialize category tracking for this run if needed
	if not _expanded_categories_in_runs.has(run_id):
		_expanded_categories_in_runs[run_id] = {}

	# Categories default to collapsed unless they have failures
	var default_expanded = failed_count > 0
	# Store default explicitly so toggle knows the current state
	if not _expanded_categories_in_runs[run_id].has(category_name):
		_expanded_categories_in_runs[run_id][category_name] = default_expanded
	var is_expanded = _expanded_categories_in_runs[run_id][category_name]

	# Category header row
	var header = HBoxContainer.new()
	header.add_theme_constant_override("separation", 6)
	container.add_child(header)

	# Indent for category level (under run)
	var indent_spacer = Control.new()
	indent_spacer.custom_minimum_size.x = 24
	header.add_child(indent_spacer)

	# Expand/collapse button
	var expand_btn = Button.new()
	expand_btn.text = "▼" if is_expanded else "▶"
	expand_btn.custom_minimum_size = Vector2(20, 20)
	expand_btn.add_theme_font_size_override("font_size", 10)
	expand_btn.pressed.connect(_on_toggle_category_in_run.bind(run_id, category_name))
	header.add_child(expand_btn)

	# Status indicator
	var status_icon = Label.new()
	if failed_count > 0:
		status_icon.text = "✗"
		status_icon.add_theme_color_override("font_color", Color(1, 0.4, 0.4))
	elif cancelled_count == results_with_indices.size():
		status_icon.text = "⊘"
		status_icon.add_theme_color_override("font_color", Color(1, 0.7, 0.2))
	else:
		status_icon.text = "✓"
		status_icon.add_theme_color_override("font_color", Color(0.3, 0.9, 0.3))
	status_icon.add_theme_font_size_override("font_size", 12)
	header.add_child(status_icon)

	# Category name and summary (clickable)
	var summary_text = "%s  •  %d passed" % [category_name, passed_count]
	if failed_count > 0:
		summary_text += ", %d failed" % failed_count
	if cancelled_count > 0:
		summary_text += ", %d cancelled" % cancelled_count

	var summary_btn = Button.new()
	summary_btn.text = summary_text
	summary_btn.flat = true
	summary_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	summary_btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
	summary_btn.add_theme_font_size_override("font_size", 12)
	summary_btn.add_theme_color_override("font_color", Color(0.7, 0.75, 0.85))
	summary_btn.pressed.connect(_on_toggle_category_in_run.bind(run_id, category_name))
	header.add_child(summary_btn)

	# Rerun category button
	var test_names: Array = []
	for item in results_with_indices:
		var tname = item.result.get("name", "")
		if not tname.is_empty():
			test_names.append(tname)

	var rerun_btn = Button.new()
	rerun_btn.icon = load("res://addons/godot-ui-automation/icons/play.svg")
	rerun_btn.tooltip_text = "Rerun %d tests in %s" % [test_names.size(), category_name]
	rerun_btn.custom_minimum_size = Vector2(28, 28)
	rerun_btn.expand_icon = true
	rerun_btn.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
	rerun_btn.pressed.connect(_on_rerun_all_from_run.bind(test_names))
	header.add_child(rerun_btn)

	# Tests container (collapsible)
	var tests_container = VBoxContainer.new()
	tests_container.add_theme_constant_override("separation", 2)
	tests_container.visible = is_expanded
	container.add_child(tests_container)

	# Add test result rows under this category
	for item in results_with_indices:
		_add_result_row_in_run(tests_container, item.result, run_id, item.index, 56)

# Toggle category collapsed state within a run
func _on_toggle_category_in_run(run_id: String, category_name: String) -> void:
	if not _expanded_categories_in_runs.has(run_id):
		_expanded_categories_in_runs[run_id] = {}

	var current = _expanded_categories_in_runs[run_id].get(category_name, true)
	_expanded_categories_in_runs[run_id][category_name] = not current
	update_results_tab()

# Adds a result row within a run (indented, with run context)
func _add_result_row_in_run(container: Control, result: Dictionary, run_id: String, result_index: int, indent: int = 32) -> void:
	var row = HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	container.add_child(row)

	# Indent spacer
	var spacer = Control.new()
	spacer.custom_minimum_size.x = indent
	row.add_child(spacer)

	var is_cancelled = result.get("cancelled", false)

	var status = Label.new()
	if is_cancelled:
		status.text = "⊘"
		status.add_theme_color_override("font_color", Color(1, 0.7, 0.2))
	elif result.get("passed", false):
		status.text = "✓"
		status.add_theme_color_override("font_color", Color(0.3, 0.9, 0.3))
	else:
		status.text = "✗"
		status.add_theme_color_override("font_color", Color(1, 0.4, 0.4))
	status.add_theme_font_size_override("font_size", 14)
	status.custom_minimum_size.x = 20
	row.add_child(status)

	var name_label = Label.new()
	var test_name = result.get("name", "Unknown")
	name_label.text = test_name + (" (cancelled)" if is_cancelled else "")
	name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_label.add_theme_font_size_override("font_size", 13)
	name_label.add_theme_color_override("font_color", Color(0.8, 0.8, 0.85))
	row.add_child(name_label)

	# Rerun button - runs test again (creates new run entry)
	var rerun_btn = Button.new()
	rerun_btn.icon = load("res://addons/godot-ui-automation/icons/play.svg")
	rerun_btn.tooltip_text = Utils.TOOLTIP_RUN_TEST
	rerun_btn.custom_minimum_size = Vector2(28, 28)
	rerun_btn.expand_icon = true
	rerun_btn.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
	rerun_btn.pressed.connect(_on_rerun_test.bind(test_name, -1))  # -1 means don't update in-place
	row.add_child(rerun_btn)

	# Test Editor button - show for all tests (not cancelled)
	if not is_cancelled:
		var debug_btn = Button.new()
		debug_btn.icon = load("res://addons/godot-ui-automation/icons/edit_pencil.svg")
		debug_btn.tooltip_text = Utils.TOOLTIP_EDIT_TEST
		debug_btn.custom_minimum_size = Vector2(28, 28)
		debug_btn.expand_icon = true
		debug_btn.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
		debug_btn.pressed.connect(_on_debug_from_results.bind(test_name))
		row.add_child(debug_btn)

		# Re-record button - show for all tests (not cancelled)
		var rerecord_btn = Button.new()
		rerecord_btn.icon = load("res://addons/godot-ui-automation/icons/record.svg")
		rerecord_btn.tooltip_text = Utils.TOOLTIP_RERECORD_TEST
		rerecord_btn.custom_minimum_size = Vector2(28, 28)
		rerecord_btn.expand_icon = true
		rerecord_btn.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
		rerecord_btn.pressed.connect(_on_test_update_baseline.bind(test_name))
		row.add_child(rerecord_btn)

	# Only show View Diff for failed tests
	if not result.get("passed", false) and not is_cancelled:
		var failed_step = result.get("failed_step", -1)
		if failed_step > 0:
			var step_btn = Button.new()
			step_btn.text = "Step %d" % failed_step
			step_btn.tooltip_text = Utils.TOOLTIP_VIEW_FAILED_STEP
			step_btn.custom_minimum_size = Vector2(60, 28)
			step_btn.add_theme_font_size_override("font_size", 12)
			step_btn.pressed.connect(_on_view_failed_step.bind(test_name, failed_step))
			row.add_child(step_btn)

		var diff_btn = Button.new()
		diff_btn.text = "Diff"
		diff_btn.tooltip_text = Utils.TOOLTIP_COMPARE_SCREENSHOTS
		diff_btn.custom_minimum_size = Vector2(50, 28)
		diff_btn.add_theme_font_size_override("font_size", 12)
		diff_btn.pressed.connect(_on_view_diff.bind(result))
		row.add_child(diff_btn)

func _add_result_row(results_list: Control, result: Dictionary, result_index: int) -> void:
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

	# Rerun button - always show
	var rerun_btn = Button.new()
	rerun_btn.icon = load("res://addons/godot-ui-automation/icons/play.svg")
	rerun_btn.tooltip_text = Utils.TOOLTIP_RUN_TEST
	rerun_btn.custom_minimum_size = Vector2(28, 28)
	rerun_btn.expand_icon = true
	rerun_btn.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
	rerun_btn.pressed.connect(_on_rerun_test.bind(result.name, result_index))
	row.add_child(rerun_btn)

	# Edit button - show for failed tests to step through and diagnose
	if not result.passed and not is_cancelled:
		var edit_btn = Button.new()
		var icon_next_frame = load("res://addons/godot-ui-automation/icons/next-frame.svg")
		if icon_next_frame:
			edit_btn.icon = icon_next_frame
			edit_btn.expand_icon = true
		else:
			edit_btn.text = ">|"
		edit_btn.tooltip_text = Utils.TOOLTIP_EDIT_TEST
		edit_btn.custom_minimum_size = Vector2(28, 28)
		edit_btn.pressed.connect(_on_debug_from_results.bind(result.name))
		row.add_child(edit_btn)

		# Re-record button - show for failed tests
		var rerecord_btn = Button.new()
		rerecord_btn.icon = load("res://addons/godot-ui-automation/icons/record.svg")
		rerecord_btn.tooltip_text = Utils.TOOLTIP_RERECORD_TEST
		rerecord_btn.custom_minimum_size = Vector2(28, 28)
		rerecord_btn.expand_icon = true
		rerecord_btn.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
		rerecord_btn.pressed.connect(_on_test_update_baseline.bind(result.name))
		row.add_child(rerecord_btn)

	# Only show View Diff for failed tests (not cancelled, not passed)
	if not result.passed and not is_cancelled:
		if result.failed_step > 0:
			var step_btn = Button.new()
			step_btn.text = "Step %d" % result.failed_step
			step_btn.tooltip_text = Utils.TOOLTIP_VIEW_FAILED_STEP
			step_btn.custom_minimum_size = Vector2(70, 28)
			step_btn.pressed.connect(_on_view_failed_step.bind(result.name, result.failed_step))
			row.add_child(step_btn)

		var diff_btn = Button.new()
		diff_btn.text = "View Diff"
		diff_btn.tooltip_text = Utils.TOOLTIP_COMPARE_SCREENSHOTS
		diff_btn.custom_minimum_size = Vector2(80, 28)
		diff_btn.pressed.connect(_on_view_diff.bind(result))
		row.add_child(diff_btn)

# Signal handlers
func _on_record_new() -> void:
	close()
	record_new_requested.emit()

func _on_run_all() -> void:
	var all_tests = FileIO.get_saved_tests()
	if all_tests.is_empty():
		return
	# Check environment first
	if _check_and_show_env_dialog(all_tests, "batch"):
		return  # Dialog will handle the run
	run_all_requested.emit()

func _on_rerun_all_from_run(test_names: Array) -> void:
	run_rerun_all_requested.emit(test_names)

func _on_new_category() -> void:
	_editing_category_name = ""
	_show_input_dialog("New Category", "Enter category name:", "")

func _on_edit_category(category_name: String) -> void:
	_editing_category_name = category_name
	_show_input_dialog("Rename Category", "Enter new name:", category_name)

func _on_clear_results() -> void:
	_pending_clear_history = true
	_pending_delete_test = ""
	_pending_delete_category = ""
	_show_confirm_dialog("Clear History", "Are you sure you want to clear all test run history?\n\nThis cannot be undone.", "Clear")

func _on_rerun_test(test_name: String, result_index: int) -> void:
	test_rerun_requested.emit(test_name, result_index)

func _on_debug_from_results(test_name: String) -> void:
	test_debug_from_results_requested.emit(test_name)

func _on_toggle_category(category_name: String) -> void:
	var is_collapsed = CategoryManager.collapsed_categories.get(category_name, false)
	CategoryManager.collapsed_categories[category_name] = not is_collapsed
	CategoryManager.save_categories()
	refresh_test_list()

func _on_play_category(category_name: String) -> void:
	# Get tests in this category
	var tests_in_category: Array = []
	for test_name in CategoryManager.test_categories:
		if CategoryManager.test_categories[test_name] == category_name:
			tests_in_category.append(test_name)

	if tests_in_category.is_empty():
		return

	# Check environment first
	if _check_and_show_env_dialog(tests_in_category, "category", category_name):
		return  # Dialog will handle the run
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
	# Check environment first
	if _check_and_show_env_dialog([test_name], "single"):
		return  # Dialog will handle the run
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

func _show_confirm_dialog(title: String, message: String, confirm_text: String = "Delete") -> void:
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
	confirm_btn.text = confirm_text
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
	_pending_clear_history = false
	_close_confirm_dialog()

func _on_confirm_delete() -> void:
	if _pending_clear_history:
		results_clear_requested.emit()
	elif not _pending_delete_test.is_empty():
		_on_test_delete(_pending_delete_test)
	elif not _pending_delete_category.is_empty():
		_on_delete_category(_pending_delete_category)
	_pending_delete_test = ""
	_pending_delete_category = ""
	_pending_clear_history = false
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
# ENVIRONMENT MISMATCH DIALOG
# =============================================================================

# Check environment for a list of tests, returns dict with mismatches
func _check_tests_environment(test_names: Array) -> Dictionary:
	# Skip all environment checks if warnings are disabled
	if not ScreenshotValidator.show_viewport_warnings:
		return {
			"has_mismatches": false,
			"mismatches": [],
			"current_env": {}
		}

	var mismatches: Array = []
	var current_env = _get_current_environment()

	for test_name in test_names:
		var filepath = TESTS_DIR + "/" + test_name + ".json"
		var test_data = FileIO.load_test(filepath)
		if test_data.is_empty():
			continue

		var status = _get_environment_status(test_data)
		if status == "mismatch":
			var recorded_env = test_data.get("recorded_environment", {})
			var differences = _get_environment_differences(recorded_env, current_env)

			# Skip viewport mismatch if test will maximize window (viewport will be correct after maximize)
			var will_maximize = test_data.get("setup", {}).get("maximize_window", false)
			if will_maximize:
				differences = differences.filter(func(d): return not d.begins_with("viewport:"))
				if differences.is_empty():
					continue  # No real mismatch after filtering viewport

			mismatches.append({
				"test_name": test_name,
				"display_name": test_data.get("name", test_name),
				"recorded_env": recorded_env,
				"differences": differences
			})

	return {
		"has_mismatches": mismatches.size() > 0,
		"mismatches": mismatches,
		"current_env": current_env
	}

# Get specific differences between recorded and current environment
func _get_environment_differences(recorded: Dictionary, current: Dictionary) -> Array:
	var diffs: Array = []

	# Check viewport
	var rec_vp = recorded.get("viewport", {})
	var cur_vp = current.get("viewport", {})
	if rec_vp.get("w", 0) != cur_vp.get("w", 0) or rec_vp.get("h", 0) != cur_vp.get("h", 0):
		diffs.append("viewport: %dx%d → %dx%d" % [
			rec_vp.get("w", 0), rec_vp.get("h", 0),
			cur_vp.get("w", 0), cur_vp.get("h", 0)
		])

	# Check monitor resolution
	var rec_mon = recorded.get("monitor_resolution", {})
	var cur_mon = current.get("monitor_resolution", {})
	if rec_mon.get("w", 0) != cur_mon.get("w", 0) or rec_mon.get("h", 0) != cur_mon.get("h", 0):
		diffs.append("monitor: %dx%d → %dx%d" % [
			rec_mon.get("w", 0), rec_mon.get("h", 0),
			cur_mon.get("w", 0), cur_mon.get("h", 0)
		])

	# Check monitor index
	var rec_idx = recorded.get("monitor_index", -1)
	var cur_idx = current.get("monitor_index", -1)
	if rec_idx != cur_idx and rec_idx >= 0:
		diffs.append("monitor #%d → #%d" % [rec_idx, cur_idx])

	return diffs

func _get_current_environment() -> Dictionary:
	var screen_idx = DisplayServer.window_get_current_screen()
	var screen_size = DisplayServer.screen_get_size(screen_idx)
	var viewport_size = _tree.root.get_viewport().get_visible_rect().size
	return {
		"monitor_index": screen_idx,
		"monitor_resolution": {"w": int(screen_size.x), "h": int(screen_size.y)},
		"viewport": {"w": int(viewport_size.x), "h": int(viewport_size.y)}
	}

# Show environment mismatch dialog with checkboxes for mismatching tests
func _show_env_mismatch_dialog(env_result: Dictionary) -> void:
	var mismatches = env_result.mismatches
	var current_env = env_result.current_env

	# Create backdrop
	if _env_backdrop:
		_env_backdrop.queue_free()
	_env_backdrop = ColorRect.new()
	_env_backdrop.name = "EnvBackdrop"
	_env_backdrop.set_anchors_preset(Control.PRESET_FULL_RECT)
	_env_backdrop.color = Color(0, 0, 0, 0.6)
	_env_backdrop.mouse_filter = Control.MOUSE_FILTER_STOP
	_env_backdrop.process_mode = Node.PROCESS_MODE_ALWAYS
	_env_backdrop.z_index = 110
	_parent.add_child(_env_backdrop)

	# Create dialog panel
	if _env_dialog:
		_env_dialog.queue_free()
	_env_dialog = Panel.new()
	_env_dialog.name = "EnvDialog"
	_env_dialog.process_mode = Node.PROCESS_MODE_ALWAYS
	_env_dialog.z_index = 120

	# Size based on number of mismatches
	var dialog_height = min(200 + mismatches.size() * 32, 500)
	var dialog_size = Vector2(550, dialog_height)
	var viewport_size = _tree.root.get_visible_rect().size
	_env_dialog.position = (viewport_size - dialog_size) / 2
	_env_dialog.size = dialog_size

	# Style - orange/yellow for warning
	var style = StyleBoxFlat.new()
	style.bg_color = Color(0.15, 0.15, 0.18, 0.98)
	style.border_color = Color(1.0, 0.7, 0.2, 1.0)  # Orange border for warning
	style.set_border_width_all(2)
	style.set_corner_radius_all(10)
	_env_dialog.add_theme_stylebox_override("panel", style)

	var vbox = VBoxContainer.new()
	vbox.set_anchors_preset(Control.PRESET_FULL_RECT)
	vbox.add_theme_constant_override("separation", 12)
	var margin = 20
	vbox.offset_left = margin
	vbox.offset_top = margin
	vbox.offset_right = -margin
	vbox.offset_bottom = -margin
	_env_dialog.add_child(vbox)

	# Title
	var title_label = Label.new()
	title_label.text = "Environment Mismatch"
	title_label.add_theme_font_size_override("font_size", 20)
	title_label.add_theme_color_override("font_color", Color(1.0, 0.8, 0.3))
	title_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(title_label)

	# Current environment info
	var current_label = Label.new()
	current_label.text = "Current: %dx%d viewport, %dx%d monitor" % [
		current_env.viewport.w, current_env.viewport.h,
		current_env.monitor_resolution.w, current_env.monitor_resolution.h
	]
	current_label.add_theme_font_size_override("font_size", 12)
	current_label.add_theme_color_override("font_color", Color(0.6, 0.8, 0.6))
	current_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(current_label)

	# Message
	var message_label = Label.new()
	var test_word = "test" if mismatches.size() == 1 else "tests"
	message_label.text = "%d %s recorded on different environment.\nUncheck to skip, or continue anyway:" % [mismatches.size(), test_word]
	message_label.add_theme_font_size_override("font_size", 13)
	message_label.add_theme_color_override("font_color", Color(0.85, 0.85, 0.9))
	message_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(message_label)

	# Scroll container for test checkboxes
	var scroll = ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	vbox.add_child(scroll)

	var check_vbox = VBoxContainer.new()
	check_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	check_vbox.add_theme_constant_override("separation", 4)
	scroll.add_child(check_vbox)

	# Add checkboxes for each mismatching test
	_env_test_checkboxes.clear()
	for mismatch in mismatches:
		var item_vbox = VBoxContainer.new()
		item_vbox.add_theme_constant_override("separation", 2)
		check_vbox.add_child(item_vbox)

		var hbox = HBoxContainer.new()
		hbox.add_theme_constant_override("separation", 8)
		item_vbox.add_child(hbox)

		var checkbox = CheckBox.new()
		checkbox.button_pressed = true  # Checked by default - will run
		checkbox.add_theme_font_size_override("font_size", 13)
		hbox.add_child(checkbox)
		_env_test_checkboxes[mismatch.test_name] = checkbox

		var name_label = Label.new()
		name_label.text = mismatch.display_name
		name_label.add_theme_font_size_override("font_size", 13)
		name_label.add_theme_color_override("font_color", Color(0.85, 0.85, 0.9))
		hbox.add_child(name_label)

		# Show specific differences
		var differences = mismatch.get("differences", [])
		if differences.size() > 0:
			var diff_label = Label.new()
			diff_label.text = "        " + ", ".join(differences)
			diff_label.add_theme_font_size_override("font_size", 11)
			diff_label.add_theme_color_override("font_color", Color(1.0, 0.7, 0.4))  # Orange for visibility
			item_vbox.add_child(diff_label)

	# Buttons row
	var btn_row = HBoxContainer.new()
	btn_row.add_theme_constant_override("separation", 20)
	btn_row.alignment = BoxContainer.ALIGNMENT_CENTER
	vbox.add_child(btn_row)

	var cancel_btn = Button.new()
	cancel_btn.text = "Cancel"
	cancel_btn.custom_minimum_size = Vector2(100, 36)
	cancel_btn.pressed.connect(_on_env_cancel)
	btn_row.add_child(cancel_btn)

	var continue_btn = Button.new()
	continue_btn.text = "Continue"
	continue_btn.custom_minimum_size = Vector2(100, 36)
	continue_btn.pressed.connect(_on_env_continue)
	btn_row.add_child(continue_btn)

	_parent.add_child(_env_dialog)

func _on_env_cancel() -> void:
	_pending_run_tests.clear()
	_pending_run_mode = ""
	_pending_category_name = ""
	_close_env_dialog()

func _on_env_continue() -> void:
	# Build list of tests to run (only checked ones)
	var tests_to_run: Array = []
	for test_name in _pending_run_tests:
		# If test has a checkbox, check if it's still checked
		if _env_test_checkboxes.has(test_name):
			if _env_test_checkboxes[test_name].button_pressed:
				tests_to_run.append(test_name)
		else:
			# Test wasn't mismatched, include it
			tests_to_run.append(test_name)

	_close_env_dialog()

	if tests_to_run.is_empty():
		print("[TestManager] No tests selected to run")
		return

	# Execute the run based on mode
	match _pending_run_mode:
		"single":
			close()
			test_run_requested.emit(tests_to_run[0])
		"batch", "category", "rerun":
			close()
			run_tests_requested.emit(tests_to_run)

	_pending_run_tests.clear()
	_pending_run_mode = ""
	_pending_category_name = ""

func _close_env_dialog() -> void:
	if _env_backdrop:
		_env_backdrop.queue_free()
		_env_backdrop = null
	if _env_dialog:
		_env_dialog.queue_free()
		_env_dialog = null
	_env_test_checkboxes.clear()

# Check tests and show dialog if needed, returns true if dialog shown
func _check_and_show_env_dialog(test_names: Array, run_mode: String, category_name: String = "") -> bool:
	var env_result = _check_tests_environment(test_names)

	if not env_result.has_mismatches:
		return false  # No dialog needed, proceed with run

	# Store pending run info
	_pending_run_tests = test_names.duplicate()
	_pending_run_mode = run_mode
	_pending_category_name = category_name

	# Show dialog
	_show_env_mismatch_dialog(env_result)
	return true  # Dialog shown, run will happen from dialog callback

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
	var test_list = scroll.find_child("TestList", true, false)
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
