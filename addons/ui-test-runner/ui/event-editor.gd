# =============================================================================
# UI Test Runner - Visual UI Automation Testing for Godot
# =============================================================================
# MIT License - Copyright (c) 2025 Poplava
#
# Support & Community:
#   Discord: https://discord.gg/9GnrTKXGfq
#   GitHub:  https://github.com/graydwarf/godot-ui-test-runner
#   More Tools: https://poplava.itch.io
# =============================================================================

extends RefCounted
## Post-recording event editor for UI Test Runner

const Utils = preload("res://addons/ui-test-runner/utils.gd")

signal cancelled()
signal save_requested(test_name: String)

var _editor: Panel = null
var _tree: SceneTree
var _parent: CanvasLayer

# Data references (set externally before showing)
var recorded_events: Array[Dictionary] = []
var pending_screenshots: Array = []
var pending_test_name: String = ""
var pending_baseline_path: String = ""
var pending_baseline_region: Dictionary = {}
var selection_rect: Rect2 = Rect2()

func initialize(tree: SceneTree, parent: CanvasLayer) -> void:
	_tree = tree
	_parent = parent

func show_editor() -> void:
	if not _editor:
		_create_editor()
	_populate_event_list()
	_editor.visible = true
	_tree.paused = true

func close() -> void:
	if _editor:
		_editor.visible = false
	_tree.paused = false

func is_visible() -> bool:
	return _editor and _editor.visible

func _create_editor() -> void:
	_editor = Panel.new()
	_editor.name = "EventEditor"
	_editor.process_mode = Node.PROCESS_MODE_ALWAYS

	var viewport_size = _tree.root.get_visible_rect().size
	var panel_size = Vector2(600, 500)
	_editor.position = (viewport_size - panel_size) / 2
	_editor.size = panel_size

	# Style
	var style = StyleBoxFlat.new()
	style.bg_color = Color(0.12, 0.12, 0.15, 0.98)
	style.border_color = Color(0.4, 0.8, 0.4, 1.0)
	style.set_border_width_all(2)
	style.set_corner_radius_all(10)
	_editor.add_theme_stylebox_override("panel", style)

	var vbox = VBoxContainer.new()
	vbox.name = "VBox"
	vbox.set_anchors_preset(Control.PRESET_FULL_RECT)
	vbox.add_theme_constant_override("separation", 12)
	var margin = 20
	vbox.offset_left = margin
	vbox.offset_top = margin
	vbox.offset_right = -margin
	vbox.offset_bottom = -margin
	_editor.add_child(vbox)

	# Header
	var header = HBoxContainer.new()
	header.name = "Header"
	header.add_theme_constant_override("separation", 10)
	vbox.add_child(header)

	var title = Label.new()
	title.text = "Edit Test Steps"
	title.add_theme_font_size_override("font_size", 20)
	title.add_theme_color_override("font_color", Color(0.9, 0.9, 0.95))
	header.add_child(title)

	var spacer = Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(spacer)

	# Test name row
	var name_row = HBoxContainer.new()
	name_row.name = "NameRow"
	name_row.add_theme_constant_override("separation", 8)
	vbox.add_child(name_row)

	var name_label = Label.new()
	name_label.text = "Test Name:"
	name_label.add_theme_font_size_override("font_size", 14)
	name_label.add_theme_color_override("font_color", Color(0.7, 0.7, 0.75))
	name_row.add_child(name_label)

	var test_name_input = LineEdit.new()
	test_name_input.name = "TestNameInput"
	test_name_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	test_name_input.placeholder_text = "Enter test name..."
	test_name_input.add_theme_font_size_override("font_size", 14)
	test_name_input.text_changed.connect(_on_test_name_changed)
	name_row.add_child(test_name_input)

	# Instructions
	var instructions = Label.new()
	instructions.text = "Adjust delays after each step. Click [+Wait] to insert wait events."
	instructions.add_theme_font_size_override("font_size", 12)
	instructions.add_theme_color_override("font_color", Color(0.6, 0.6, 0.65))
	vbox.add_child(instructions)

	# Event list scroll container
	var scroll = ScrollContainer.new()
	scroll.name = "EventScroll"
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vbox.add_child(scroll)

	var event_list = VBoxContainer.new()
	event_list.name = "EventList"
	event_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	event_list.add_theme_constant_override("separation", 2)
	scroll.add_child(event_list)

	# Button row
	var btn_row = HBoxContainer.new()
	btn_row.add_theme_constant_override("separation", 10)
	vbox.add_child(btn_row)

	var btn_spacer = Control.new()
	btn_spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	btn_row.add_child(btn_spacer)

	var cancel_btn = Button.new()
	cancel_btn.text = "Cancel"
	cancel_btn.custom_minimum_size = Vector2(100, 36)
	cancel_btn.pressed.connect(_on_cancel)
	btn_row.add_child(cancel_btn)

	var save_btn = Button.new()
	save_btn.text = "Save Test"
	save_btn.custom_minimum_size = Vector2(100, 36)
	var save_style = StyleBoxFlat.new()
	save_style.bg_color = Color(0.2, 0.5, 0.3, 0.8)
	save_style.set_corner_radius_all(6)
	save_btn.add_theme_stylebox_override("normal", save_style)
	var save_hover = StyleBoxFlat.new()
	save_hover.bg_color = Color(0.25, 0.6, 0.35, 0.9)
	save_hover.set_corner_radius_all(6)
	save_btn.add_theme_stylebox_override("hover", save_hover)
	save_btn.pressed.connect(_on_save)
	btn_row.add_child(save_btn)

	_parent.add_child(_editor)

func _populate_event_list() -> void:
	var event_list = _editor.get_node("VBox/EventScroll/EventList")
	var test_name_input = _editor.get_node("VBox/NameRow/TestNameInput")

	# Update test name input and select all text so user can immediately type to replace
	test_name_input.text = pending_test_name
	test_name_input.select_all()
	test_name_input.grab_focus()

	# Clear existing
	for child in event_list.get_children():
		child.queue_free()

	# Build a map of screenshots by their position (after_event_index)
	var screenshots_by_index: Dictionary = {}
	for screenshot in pending_screenshots:
		# Convert to int - JSON parsing returns floats for numbers
		var after_idx = int(screenshot.get("after_event_index", -1))
		if not screenshots_by_index.has(after_idx):
			screenshots_by_index[after_idx] = []
		screenshots_by_index[after_idx].append(screenshot)

	# Add each event as a row
	for i in range(recorded_events.size()):
		var event = recorded_events[i]
		var row = _create_event_row(i, event)
		event_list.add_child(row)

		# Add screenshot markers after this event if any
		if screenshots_by_index.has(i):
			for screenshot in screenshots_by_index[i]:
				var screenshot_row = _create_screenshot_row(screenshot)
				event_list.add_child(screenshot_row)

		# Add insert button after each event
		var insert_btn = Button.new()
		insert_btn.text = "+ Insert Wait"
		insert_btn.add_theme_font_size_override("font_size", 11)
		insert_btn.add_theme_color_override("font_color", Color(0.5, 0.7, 0.5))
		insert_btn.custom_minimum_size = Vector2(0, 24)
		insert_btn.pressed.connect(_on_insert_wait.bind(i + 1))
		event_list.add_child(insert_btn)

	# Show legacy baseline at the end if no inline screenshots and baseline exists
	if pending_screenshots.is_empty() and not pending_baseline_path.is_empty():
		var legacy_screenshot = {
			"path": pending_baseline_path,
			"region": pending_baseline_region,
			"after_event_index": recorded_events.size() - 1,
			"is_legacy": true
		}
		var screenshot_row = _create_screenshot_row(legacy_screenshot)
		event_list.add_child(screenshot_row)

func _on_test_name_changed(new_text: String) -> void:
	pending_test_name = new_text

func _create_screenshot_row(screenshot: Dictionary) -> Control:
	var panel = PanelContainer.new()
	var panel_style = StyleBoxFlat.new()
	panel_style.bg_color = Color(0.15, 0.25, 0.35, 0.9)
	panel_style.border_color = Color(0.3, 0.6, 0.8, 0.8)
	panel_style.set_border_width_all(1)
	panel_style.set_corner_radius_all(4)
	panel.add_theme_stylebox_override("panel", panel_style)

	var row = HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	panel.add_child(row)

	# Camera icon
	var icon = Label.new()
	icon.text = "📷"
	icon.add_theme_font_size_override("font_size", 16)
	row.add_child(icon)

	# Screenshot thumbnail (clickable)
	var path = screenshot.get("path", "")
	var region = screenshot.get("region", {})
	var region_text = "%dx%d" % [int(region.get("w", 0)), int(region.get("h", 0))]

	var thumb_container = Control.new()
	thumb_container.custom_minimum_size = Vector2(80, 50)
	thumb_container.mouse_filter = Control.MOUSE_FILTER_STOP
	thumb_container.tooltip_text = "Click to view full size"

	# Load and display thumbnail
	var global_path = ProjectSettings.globalize_path(path)
	if FileAccess.file_exists(global_path):
		var image = Image.new()
		var err = image.load(global_path)
		if err == OK:
			var texture = ImageTexture.create_from_image(image)
			var thumb = TextureRect.new()
			thumb.texture = texture
			thumb.expand_mode = TextureRect.EXPAND_FIT_WIDTH_PROPORTIONAL
			thumb.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
			thumb.custom_minimum_size = Vector2(80, 50)
			thumb.mouse_filter = Control.MOUSE_FILTER_IGNORE
			thumb_container.add_child(thumb)
	else:
		# No image - show placeholder
		var placeholder = Label.new()
		placeholder.text = "[No Image]"
		placeholder.add_theme_font_size_override("font_size", 10)
		placeholder.add_theme_color_override("font_color", Color(0.5, 0.5, 0.6))
		thumb_container.add_child(placeholder)

	# Click handler for thumbnail
	thumb_container.gui_input.connect(_on_screenshot_thumbnail_clicked.bind(path))
	row.add_child(thumb_container)

	# Screenshot label
	var label = Label.new()
	label.text = "Screenshot (%s)" % region_text
	label.add_theme_font_size_override("font_size", 12)
	label.add_theme_color_override("font_color", Color(0.7, 0.85, 1.0))
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(label)

	# View button
	var view_btn = Button.new()
	view_btn.text = "👁"
	view_btn.tooltip_text = "View full size"
	view_btn.custom_minimum_size = Vector2(28, 28)
	view_btn.pressed.connect(_show_screenshot_fullsize.bind(path))
	row.add_child(view_btn)

	# Delete button
	var delete_btn = Button.new()
	delete_btn.text = "✕"
	delete_btn.tooltip_text = "Remove screenshot"
	delete_btn.custom_minimum_size = Vector2(28, 28)
	delete_btn.pressed.connect(_on_delete_screenshot.bind(screenshot))
	row.add_child(delete_btn)

	return panel

func _on_screenshot_thumbnail_clicked(event: InputEvent, image_path: String) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		_show_screenshot_fullsize(image_path)

func _show_screenshot_fullsize(image_path: String) -> void:
	var global_path = ProjectSettings.globalize_path(image_path)
	if image_path.is_empty() or not FileAccess.file_exists(global_path):
		print("[EventEditor] Screenshot not found: %s" % image_path)
		return

	# Create fullsize viewer overlay
	var viewer = Panel.new()
	viewer.name = "ScreenshotViewer"

	var viewer_style = StyleBoxFlat.new()
	viewer_style.bg_color = Color(0.05, 0.05, 0.08, 0.95)
	viewer.add_theme_stylebox_override("panel", viewer_style)

	viewer.set_anchors_preset(Control.PRESET_FULL_RECT)
	viewer.process_mode = Node.PROCESS_MODE_ALWAYS

	var vbox = VBoxContainer.new()
	vbox.set_anchors_preset(Control.PRESET_FULL_RECT)
	vbox.set_offsets_preset(Control.PRESET_FULL_RECT, Control.PRESET_MODE_MINSIZE, 20)
	viewer.add_child(vbox)

	# Header with title and close button
	var header = HBoxContainer.new()
	header.add_theme_constant_override("separation", 10)
	vbox.add_child(header)

	var title = Label.new()
	title.text = "Screenshot: %s" % image_path.get_file()
	title.add_theme_font_size_override("font_size", 16)
	title.add_theme_color_override("font_color", Color(0.9, 0.9, 0.95))
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(title)

	var close_btn = Button.new()
	close_btn.text = "✕ Close"
	close_btn.custom_minimum_size = Vector2(80, 32)
	header.add_child(close_btn)

	# Image container with scroll
	var scroll = ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	vbox.add_child(scroll)

	var center = CenterContainer.new()
	center.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	center.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.add_child(center)

	# Load and display full image
	var image = Image.new()
	var err = image.load(global_path)
	if err == OK:
		var texture = ImageTexture.create_from_image(image)
		var img_rect = TextureRect.new()
		img_rect.texture = texture
		img_rect.stretch_mode = TextureRect.STRETCH_KEEP
		center.add_child(img_rect)
	else:
		var error_label = Label.new()
		error_label.text = "Failed to load image"
		error_label.add_theme_color_override("font_color", Color(1, 0.5, 0.5))
		center.add_child(error_label)

	# Add to CanvasLayer to be on top
	var canvas = CanvasLayer.new()
	canvas.layer = 200
	canvas.add_child(viewer)
	_tree.root.add_child(canvas)

	# Connect close button
	close_btn.pressed.connect(func(): canvas.queue_free())

	# Close on Escape key
	viewer.gui_input.connect(func(ev):
		if ev is InputEventKey and ev.pressed and ev.keycode == KEY_ESCAPE:
			canvas.queue_free()
	)
	viewer.focus_mode = Control.FOCUS_ALL
	viewer.grab_focus()

func _on_delete_screenshot(screenshot: Dictionary) -> void:
	var idx = pending_screenshots.find(screenshot)
	if idx >= 0:
		pending_screenshots.remove_at(idx)
		_populate_event_list()

func _create_event_row(index: int, event: Dictionary) -> Control:
	var container = VBoxContainer.new()
	container.add_theme_constant_override("separation", 2)

	# Main row background
	var panel = PanelContainer.new()
	panel.name = "Panel"
	var panel_style = StyleBoxFlat.new()
	panel_style.bg_color = Color(0.18, 0.18, 0.22, 0.8)
	panel_style.set_corner_radius_all(4)
	panel.add_theme_stylebox_override("panel", panel_style)

	var inner_row = HBoxContainer.new()
	inner_row.name = "InnerRow"
	inner_row.add_theme_constant_override("separation", 10)
	panel.add_child(inner_row)

	# Index
	var idx_label = Label.new()
	idx_label.text = "%d." % (index + 1)
	idx_label.custom_minimum_size.x = 30
	idx_label.add_theme_color_override("font_color", Color(0.5, 0.5, 0.55))
	inner_row.add_child(idx_label)

	# Event description
	var desc_label = Label.new()
	desc_label.text = _get_event_description(event)
	desc_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	desc_label.add_theme_color_override("font_color", Color(0.85, 0.85, 0.9))
	inner_row.add_child(desc_label)

	# Delay dropdown
	var delay_label = Label.new()
	delay_label.text = "then wait"
	delay_label.add_theme_color_override("font_color", Color(0.6, 0.6, 0.65))
	inner_row.add_child(delay_label)

	var delay_dropdown = OptionButton.new()
	delay_dropdown.name = "DelayDropdown"
	delay_dropdown.custom_minimum_size.x = 90
	var delays = [0, 50, 100, 250, 500, 1000, 1500, 2000, 3000, 5000]
	var current_delay = event.get("wait_after", 100)
	var selected_idx = 0
	for j in range(delays.size()):
		var d = delays[j]
		if d < 1000:
			delay_dropdown.add_item("%dms" % d, d)
		else:
			delay_dropdown.add_item("%.1fs" % (d / 1000.0), d)
		if d == current_delay:
			selected_idx = j
	delay_dropdown.select(selected_idx)
	delay_dropdown.item_selected.connect(_on_delay_changed.bind(index))
	inner_row.add_child(delay_dropdown)

	# Delete button (for wait events only)
	if event.get("type") == "wait":
		var del_btn = Button.new()
		del_btn.text = "✕"
		del_btn.custom_minimum_size = Vector2(28, 0)
		del_btn.pressed.connect(_on_delete_event.bind(index))
		inner_row.add_child(del_btn)

	container.add_child(panel)
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	# Note row
	var note_row = HBoxContainer.new()
	note_row.add_theme_constant_override("separation", 5)

	var note_spacer = Control.new()
	note_spacer.custom_minimum_size.x = 30
	note_row.add_child(note_spacer)

	var note_label = Label.new()
	note_label.text = "📝"
	note_label.add_theme_color_override("font_color", Color(0.5, 0.5, 0.55))
	note_row.add_child(note_label)

	var note_input = LineEdit.new()
	note_input.name = "NoteInput"
	note_input.placeholder_text = "Add note (e.g., 'drag card to column')"
	note_input.text = event.get("note", "")
	note_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	note_input.add_theme_font_size_override("font_size", 12)
	note_input.add_theme_color_override("font_placeholder_color", Color(0.4, 0.4, 0.45))
	note_input.text_changed.connect(_on_note_changed.bind(index))
	note_row.add_child(note_input)

	container.add_child(note_row)

	return container

func _get_event_description(event: Dictionary) -> String:
	var event_type = event.get("type", "unknown")
	match event_type:
		"click":
			var pos = event.get("pos", Vector2.ZERO)
			return "Click at (%d, %d)" % [int(pos.x), int(pos.y)]
		"double_click":
			var pos = event.get("pos", Vector2.ZERO)
			return "Double-click at (%d, %d)" % [int(pos.x), int(pos.y)]
		"drag":
			var from_pos = event.get("from", Vector2.ZERO)
			var to_pos = event.get("to", Vector2.ZERO)
			return "Drag (%d,%d) → (%d,%d)" % [int(from_pos.x), int(from_pos.y), int(to_pos.x), int(to_pos.y)]
		"key":
			var keycode = event.get("keycode", 0)
			var key_str = OS.get_keycode_string(keycode)
			var mods = ""
			if event.get("ctrl", false):
				mods += "Ctrl+"
			if event.get("shift", false):
				mods += "Shift+"
			return "Key: %s%s" % [mods, key_str]
		"wait":
			var duration = event.get("duration", 1000)
			if duration < 1000:
				return "⏱ Wait %dms" % duration
			else:
				return "⏱ Wait %.1fs" % (duration / 1000.0)
		_:
			return "Unknown event"

func _on_delay_changed(dropdown_index: int, event_index: int) -> void:
	var event_list = _editor.get_node("VBox/EventScroll/EventList")
	# Find the container (containers are at even indices, insert buttons at odd)
	var container = event_list.get_child(event_index * 2)
	var dropdown = container.get_node("Panel/InnerRow/DelayDropdown")
	var delay_value = dropdown.get_item_id(dropdown_index)
	recorded_events[event_index]["wait_after"] = delay_value

func _on_note_changed(new_text: String, event_index: int) -> void:
	recorded_events[event_index]["note"] = new_text

func _on_insert_wait(after_index: int) -> void:
	# Insert a wait event at the specified position
	var wait_event: Dictionary = {
		"type": "wait",
		"duration": 1000,
		"wait_after": 0,
		"time": 0
	}
	recorded_events.insert(after_index, wait_event)
	_populate_event_list()

func _on_delete_event(index: int) -> void:
	recorded_events.remove_at(index)
	_populate_event_list()

func _on_cancel() -> void:
	close()
	recorded_events.clear()
	pending_screenshots.clear()
	pending_baseline_region = {}
	print("[EventEditor] Test recording cancelled")
	cancelled.emit()

func _on_save() -> void:
	# Validate name is not empty
	var sanitized_name = Utils.sanitize_filename(pending_test_name)
	if sanitized_name.is_empty():
		# Flash the name input red to indicate error
		var test_name_input = _editor.get_node("VBox/NameRow/TestNameInput")
		test_name_input.add_theme_color_override("font_color", Color.RED)
		test_name_input.placeholder_text = "Name required!"
		test_name_input.grab_focus()
		# Reset color after a moment
		await _tree.create_timer(1.5).timeout
		test_name_input.remove_theme_color_override("font_color")
		test_name_input.placeholder_text = "Enter test name..."
		return

	close()
	save_requested.emit(pending_test_name)

func highlight_failed_step(step_index: int) -> void:
	if not _editor:
		return

	var event_list = _editor.get_node_or_null("VBox/EventScroll/EventList")
	var scroll = _editor.get_node_or_null("VBox/EventScroll")
	if not event_list or not scroll:
		return

	# Find the row for this step (accounting for screenshot rows and insert buttons)
	var target_row: Control = null
	var current_event_index = 0
	for child in event_list.get_children():
		if child.name.begins_with("Panel"):  # Event rows have Panel containers
			current_event_index += 1
			if current_event_index == step_index:
				target_row = child
				break

	if target_row:
		# Highlight with red border
		var style = StyleBoxFlat.new()
		style.bg_color = Color(0.3, 0.15, 0.15, 0.9)
		style.border_color = Color(1, 0.4, 0.4, 1.0)
		style.set_border_width_all(2)
		style.set_corner_radius_all(4)
		target_row.add_theme_stylebox_override("panel", style)

		# Scroll to the failed step
		await _tree.process_frame
		scroll.ensure_control_visible(target_row)

# Print generated test code for reference
func print_test_code() -> void:
	print("\n" + "=".repeat(60))
	print("# GENERATED TEST CODE")
	print("=".repeat(60))
	print("")
	print("func test_recorded():")
	print("\tvar runner = UITestRunner")
	print("\tawait runner.begin_test(\"Recorded Test\")")
	print("")

	for event in recorded_events:
		var wait_after = event.get("wait_after", 100)
		match event.get("type", ""):
			"click":
				print("\tawait runner.click_at(Vector2(%d, %d))" % [event.pos.x, event.pos.y])
			"double_click":
				print("\tawait runner.move_to(Vector2(%d, %d))" % [event.pos.x, event.pos.y])
				print("\tawait runner.double_click()")
			"drag":
				print("\tawait runner.drag(Vector2(%d, %d), Vector2(%d, %d))" % [event.from.x, event.from.y, event.to.x, event.to.y])
			"key":
				var key_str = OS.get_keycode_string(event.keycode)
				if event.get("ctrl", false) or event.get("shift", false):
					print("\tawait runner.press_key(KEY_%s, %s, %s)" % [key_str.to_upper(), event.get("shift", false), event.get("ctrl", false)])
				else:
					print("\tawait runner.press_key(KEY_%s)" % key_str.to_upper())
			"wait":
				var duration = event.get("duration", 1000)
				print("\tawait runner.wait(%.2f)" % (duration / 1000.0))

		if wait_after > 0:
			print("\tawait runner.wait(%.2f)" % (wait_after / 1000.0))

	print("")
	if not pending_baseline_path.is_empty():
		print("\t# Visual validation")
		print("\tvar match = await runner.validate_screenshot(\"%s\", Rect2(%d, %d, %d, %d))" % [
			pending_baseline_path, selection_rect.position.x, selection_rect.position.y, selection_rect.size.x, selection_rect.size.y
		])
		print("\tassert(match, \"Screenshot should match baseline\")")
		print("")

	print("\trunner.end_test(true)")
	print("")
	print("=".repeat(60))
