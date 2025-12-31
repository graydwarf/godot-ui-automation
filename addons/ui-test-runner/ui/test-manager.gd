extends RefCounted
class_name UITestManager
## Test Manager panel for UI Test Runner

const Utils = preload("res://addons/ui-test-runner/utils.gd")
const FileIO = preload("res://addons/ui-test-runner/file-io.gd")
const CategoryManager = preload("res://addons/ui-test-runner/category-manager.gd")
const TESTS_DIR = Utils.TESTS_DIR

signal test_selected(test_name: String)
signal test_run_requested(test_name: String)
signal test_delete_requested(test_name: String)
signal test_rename_requested(test_name: String)
signal test_edit_requested(test_name: String)
signal test_update_baseline_requested(test_name: String)
signal record_new_requested()
signal run_all_requested()
signal category_play_requested(category_name: String)
signal results_clear_requested()
signal view_failed_step_requested(test_name: String, failed_step: int)
signal view_diff_requested(result: Dictionary)
signal closed()

var _panel: Panel = null
var _tree: SceneTree
var _parent: CanvasLayer

var is_open: bool = false

# Drag and drop state
var dragging_test_name: String = ""
var drag_indicator: Control = null
var drop_line: Control = null
var drop_target_category: String = ""
var drop_target_index: int = -1

# Results data (set by main runner)
var batch_results: Array = []

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
	_panel.visible = true

func close() -> void:
	is_open = false
	_tree.paused = false
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
	if is_open and event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		close()
		return true
	return false

func _create_panel() -> void:
	_panel = Panel.new()
	_panel.name = "TestManagerPanel"
	_panel.process_mode = Node.PROCESS_MODE_ALWAYS

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
	tests_tab.add_theme_constant_override("separation", 10)
	tabs.add_child(tests_tab)

	# Action buttons row
	var actions_row = HBoxContainer.new()
	actions_row.add_theme_constant_override("separation", 10)
	tests_tab.add_child(actions_row)

	var record_btn = Button.new()
	record_btn.text = "⏺ Record New Test"
	record_btn.custom_minimum_size = Vector2(166, 52)
	var record_style = StyleBoxFlat.new()
	record_style.bg_color = Color(0.5, 0.2, 0.2, 0.8)
	record_style.set_corner_radius_all(6)
	record_btn.add_theme_stylebox_override("normal", record_style)
	record_btn.pressed.connect(_on_record_new)
	actions_row.add_child(record_btn)

	var run_all_btn = Button.new()
	run_all_btn.text = "▶ Run All Tests"
	run_all_btn.custom_minimum_size = Vector2(166, 52)
	var run_all_style = StyleBoxFlat.new()
	run_all_style.bg_color = Color(0.2, 0.4, 0.2, 0.8)
	run_all_style.set_corner_radius_all(6)
	run_all_btn.add_theme_stylebox_override("normal", run_all_style)
	run_all_btn.pressed.connect(_on_run_all)
	actions_row.add_child(run_all_btn)

	# Second row for New Category
	var actions_row2 = HBoxContainer.new()
	actions_row2.add_theme_constant_override("separation", 10)
	tests_tab.add_child(actions_row2)

	var new_cat_btn = Button.new()
	new_cat_btn.text = "+ New Category"
	new_cat_btn.custom_minimum_size = Vector2(150, 36)
	new_cat_btn.pressed.connect(_on_new_category)
	actions_row2.add_child(new_cat_btn)

	# Scroll container for test list
	var scroll = ScrollContainer.new()
	scroll.name = "TestScroll"
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	tests_tab.add_child(scroll)

	var test_list = VBoxContainer.new()
	test_list.name = "TestList"
	test_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	test_list.add_theme_constant_override("separation", 2)
	scroll.add_child(test_list)

func _create_results_tab(tabs: TabContainer) -> void:
	var results_tab = VBoxContainer.new()
	results_tab.name = "Results"
	results_tab.add_theme_constant_override("separation", 10)
	tabs.add_child(results_tab)

	# Results header
	var results_header = HBoxContainer.new()
	results_header.add_theme_constant_override("separation", 10)
	results_tab.add_child(results_header)

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
	clear_btn.custom_minimum_size = Vector2(100, 30)
	clear_btn.pressed.connect(_on_clear_results)
	results_header.add_child(clear_btn)

	# Results scroll
	var results_scroll = ScrollContainer.new()
	results_scroll.name = "ResultsScroll"
	results_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	results_tab.add_child(results_scroll)

	var results_list = VBoxContainer.new()
	results_list.name = "ResultsList"
	results_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	results_list.add_theme_constant_override("separation", 4)
	results_scroll.add_child(results_list)

func _create_settings_tab(tabs: TabContainer) -> void:
	var settings_tab = VBoxContainer.new()
	settings_tab.name = "Settings"
	settings_tab.add_theme_constant_override("separation", 15)
	tabs.add_child(settings_tab)

	var settings_label = Label.new()
	settings_label.text = "Test Runner Settings"
	settings_label.add_theme_font_size_override("font_size", 18)
	settings_label.add_theme_color_override("font_color", Color(0.85, 0.85, 0.9))
	settings_tab.add_child(settings_label)

	# Playback Speed
	var speed_row = HBoxContainer.new()
	speed_row.add_theme_constant_override("separation", 10)
	settings_tab.add_child(speed_row)

	var speed_label = Label.new()
	speed_label.text = "Playback Speed:"
	speed_label.add_theme_font_size_override("font_size", 14)
	speed_label.custom_minimum_size.x = 150
	speed_row.add_child(speed_label)

	var speed_dropdown = OptionButton.new()
	speed_dropdown.name = "SpeedDropdown"
	speed_dropdown.add_item("Slow (0.5x)", 0)
	speed_dropdown.add_item("Normal (1x)", 1)
	speed_dropdown.add_item("Fast (2x)", 2)
	speed_dropdown.add_item("Very Fast (4x)", 3)
	speed_dropdown.add_item("Ultra (8x)", 4)
	speed_dropdown.add_item("Instant", 5)
	speed_dropdown.custom_minimum_size.x = 150
	speed_row.add_child(speed_dropdown)

	# Compare Mode
	var mode_row = HBoxContainer.new()
	mode_row.add_theme_constant_override("separation", 10)
	settings_tab.add_child(mode_row)

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
	mode_row.add_child(mode_dropdown)

	# Pixel Tolerance
	var pixel_row = HBoxContainer.new()
	pixel_row.name = "PixelToleranceRow"
	pixel_row.add_theme_constant_override("separation", 10)
	settings_tab.add_child(pixel_row)

	var pixel_label = Label.new()
	pixel_label.text = "Pixel Tolerance:"
	pixel_label.add_theme_font_size_override("font_size", 14)
	pixel_label.custom_minimum_size.x = 150
	pixel_row.add_child(pixel_label)

	var pixel_slider = HSlider.new()
	pixel_slider.name = "PixelSlider"
	pixel_slider.min_value = 0.0
	pixel_slider.max_value = 5.0
	pixel_slider.step = 0.1
	pixel_slider.custom_minimum_size.x = 150
	pixel_row.add_child(pixel_slider)

	var pixel_value = Label.new()
	pixel_value.name = "PixelValue"
	pixel_value.text = "0.0%"
	pixel_value.custom_minimum_size.x = 60
	pixel_row.add_child(pixel_value)

	# Color Threshold
	var color_row = HBoxContainer.new()
	color_row.name = "ColorThresholdRow"
	color_row.add_theme_constant_override("separation", 10)
	settings_tab.add_child(color_row)

	var color_label = Label.new()
	color_label.text = "Color Threshold:"
	color_label.add_theme_font_size_override("font_size", 14)
	color_label.custom_minimum_size.x = 150
	color_row.add_child(color_label)

	var color_slider = HSlider.new()
	color_slider.name = "ColorSlider"
	color_slider.min_value = 0.0
	color_slider.max_value = 0.5
	color_slider.step = 0.01
	color_slider.custom_minimum_size.x = 150
	color_row.add_child(color_slider)

	var color_value = Label.new()
	color_value.name = "ColorValue"
	color_value.text = "0.00"
	color_value.custom_minimum_size.x = 60
	color_row.add_child(color_value)

func refresh_test_list() -> void:
	if not _panel:
		return

	var test_list = _panel.get_node_or_null("VBoxContainer/TabContainer/Tests/TestScroll/TestList")
	if not test_list:
		return

	# Clear existing
	for child in test_list.get_children():
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
	play_btn.pressed.connect(_on_play_category.bind(category_name))
	header.add_child(play_btn)

	var del_btn = Button.new()
	del_btn.text = "🗑"
	del_btn.tooltip_text = "Delete category (tests will become uncategorized)"
	del_btn.custom_minimum_size = Vector2(28, 24)
	del_btn.pressed.connect(_on_delete_category.bind(category_name))
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

	# Load test data for display name
	var filepath = TESTS_DIR + "/" + test_name + ".json"
	var test_data = FileIO.load_test(filepath)
	var display_name = test_data.get("name", test_name) if not test_data.is_empty() else test_name

	var name_btn = Button.new()
	name_btn.text = display_name
	name_btn.flat = true
	name_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
	name_btn.add_theme_color_override("font_color", Color(0.85, 0.85, 0.9))
	name_btn.pressed.connect(_on_test_selected.bind(test_name))
	row.add_child(name_btn)

	# Action buttons
	var play_btn = Button.new()
	play_btn.text = "▶"
	play_btn.tooltip_text = "Run test"
	play_btn.custom_minimum_size = Vector2(28, 28)
	play_btn.pressed.connect(_on_test_run.bind(test_name))
	row.add_child(play_btn)

	var edit_btn = Button.new()
	edit_btn.text = "✏"
	edit_btn.tooltip_text = "Edit test steps"
	edit_btn.custom_minimum_size = Vector2(28, 28)
	edit_btn.pressed.connect(_on_test_edit.bind(test_name))
	row.add_child(edit_btn)

	var baseline_btn = Button.new()
	baseline_btn.text = "📷"
	baseline_btn.tooltip_text = "Update baseline screenshot"
	baseline_btn.custom_minimum_size = Vector2(28, 28)
	baseline_btn.pressed.connect(_on_test_update_baseline.bind(test_name))
	row.add_child(baseline_btn)

	var rename_btn = Button.new()
	rename_btn.text = "✎"
	rename_btn.tooltip_text = "Rename test"
	rename_btn.custom_minimum_size = Vector2(28, 28)
	rename_btn.pressed.connect(_on_test_rename.bind(test_name))
	row.add_child(rename_btn)

	var del_btn = Button.new()
	del_btn.text = "🗑"
	del_btn.tooltip_text = "Delete test"
	del_btn.custom_minimum_size = Vector2(28, 28)
	del_btn.pressed.connect(_on_test_delete.bind(test_name))
	row.add_child(del_btn)

	return row

func update_results_tab() -> void:
	if not _panel:
		return

	var results_list = _panel.get_node_or_null("VBoxContainer/TabContainer/Results/ResultsScroll/ResultsList")
	var results_label = _panel.get_node_or_null("VBoxContainer/TabContainer/Results/ResultsLabel")
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

	# Count passed/failed
	var passed_count = 0
	var failed_count = 0
	for result in batch_results:
		if result.passed:
			passed_count += 1
		else:
			failed_count += 1

	if results_label:
		results_label.text = "Test Results: %d passed, %d failed" % [passed_count, failed_count]

	# Add result rows
	for result in batch_results:
		_add_result_row(results_list, result)

func _add_result_row(results_list: Control, result: Dictionary) -> void:
	var row = HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	results_list.add_child(row)

	var status = Label.new()
	status.text = "✓" if result.passed else "✗"
	status.add_theme_font_size_override("font_size", 16)
	status.add_theme_color_override("font_color", Color(0.3, 0.9, 0.3) if result.passed else Color(1, 0.4, 0.4))
	status.custom_minimum_size.x = 24
	row.add_child(status)

	var name_label = Label.new()
	name_label.text = result.name
	name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_label.add_theme_color_override("font_color", Color(0.85, 0.85, 0.9))
	row.add_child(name_label)

	if not result.passed:
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
	# Will be handled by main runner with dialog
	pass

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
	# Remove category but keep tests (they become uncategorized)
	var tests_to_uncategorize = []
	for test_name in CategoryManager.test_categories:
		if CategoryManager.test_categories[test_name] == category_name:
			tests_to_uncategorize.append(test_name)

	for test_name in tests_to_uncategorize:
		CategoryManager.test_categories.erase(test_name)

	CategoryManager.collapsed_categories.erase(category_name)
	if CategoryManager.category_test_order.has(category_name):
		CategoryManager.category_test_order.erase(category_name)

	CategoryManager.save_categories()
	refresh_test_list()

func _on_test_selected(test_name: String) -> void:
	test_selected.emit(test_name)

func _on_test_run(test_name: String) -> void:
	close()
	test_run_requested.emit(test_name)

func _on_test_edit(test_name: String) -> void:
	test_edit_requested.emit(test_name)

func _on_test_update_baseline(test_name: String) -> void:
	test_update_baseline_requested.emit(test_name)

func _on_test_rename(test_name: String) -> void:
	test_rename_requested.emit(test_name)

func _on_test_delete(test_name: String) -> void:
	test_delete_requested.emit(test_name)

func _on_view_failed_step(test_name: String, failed_step: int) -> void:
	view_failed_step_requested.emit(test_name, failed_step)

func _on_view_diff(result: Dictionary) -> void:
	view_diff_requested.emit(result)
