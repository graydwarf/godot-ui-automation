extends RefCounted
class_name UIComparisonViewer
## Screenshot comparison viewer for UI Test Runner

const ScreenshotValidator = preload("res://addons/ui-test-runner/screenshot-validator.gd")

signal closed()

var _viewer: Panel = null
var _tree: SceneTree
var _parent: CanvasLayer

var baseline_path: String = ""
var actual_path: String = ""

func initialize(tree: SceneTree, parent: CanvasLayer) -> void:
	_tree = tree
	_parent = parent

func show_comparison(p_baseline_path: String, p_actual_path: String) -> void:
	baseline_path = p_baseline_path
	actual_path = p_actual_path

	if not _viewer:
		_create_viewer()

	_update_images()
	_viewer.visible = true
	_tree.paused = true

func close() -> void:
	if _viewer:
		_viewer.visible = false
	_tree.paused = false
	closed.emit()

func is_visible() -> bool:
	return _viewer and _viewer.visible

func handle_input(event: InputEvent) -> bool:
	if is_visible() and event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		close()
		return true
	return false

func _create_viewer() -> void:
	_viewer = Panel.new()
	_viewer.name = "ComparisonViewer"
	_viewer.process_mode = Node.PROCESS_MODE_ALWAYS
	_viewer.set_anchors_preset(Control.PRESET_FULL_RECT)

	var style = StyleBoxFlat.new()
	style.bg_color = Color(0.1, 0.1, 0.12, 0.98)
	_viewer.add_theme_stylebox_override("panel", style)

	var vbox = VBoxContainer.new()
	vbox.name = "VBox"
	vbox.set_anchors_preset(Control.PRESET_FULL_RECT)
	vbox.add_theme_constant_override("separation", 10)
	var margin = 20
	vbox.offset_left = margin
	vbox.offset_top = margin
	vbox.offset_right = -margin
	vbox.offset_bottom = -margin
	_viewer.add_child(vbox)

	_create_header(vbox)
	_create_labels_row(vbox)
	_create_images_container(vbox)
	_create_footer(vbox)

	_parent.add_child(_viewer)

func _create_header(vbox: VBoxContainer) -> void:
	var header = HBoxContainer.new()
	header.add_theme_constant_override("separation", 20)
	vbox.add_child(header)

	var title = Label.new()
	title.text = "Screenshot Comparison - FAILED"
	title.add_theme_font_size_override("font_size", 24)
	title.add_theme_color_override("font_color", Color(1, 0.4, 0.4))
	header.add_child(title)

	var spacer = Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(spacer)

	var close_btn = Button.new()
	close_btn.text = "Close (ESC)"
	close_btn.pressed.connect(close)
	header.add_child(close_btn)

func _create_labels_row(vbox: VBoxContainer) -> void:
	var labels_row = HBoxContainer.new()
	labels_row.add_theme_constant_override("separation", 20)
	vbox.add_child(labels_row)

	var baseline_label = Label.new()
	baseline_label.text = "BASELINE (Expected)"
	baseline_label.add_theme_font_size_override("font_size", 16)
	baseline_label.add_theme_color_override("font_color", Color(0.4, 1, 0.4))
	baseline_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	baseline_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	labels_row.add_child(baseline_label)

	var actual_label = Label.new()
	actual_label.text = "ACTUAL (Current)"
	actual_label.add_theme_font_size_override("font_size", 16)
	actual_label.add_theme_color_override("font_color", Color(1, 0.4, 0.4))
	actual_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	actual_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	labels_row.add_child(actual_label)

	var diff_label = Label.new()
	diff_label.text = "DIFF (Red = Different)"
	diff_label.add_theme_font_size_override("font_size", 16)
	diff_label.add_theme_color_override("font_color", Color(1, 0.6, 0.2))
	diff_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	diff_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	labels_row.add_child(diff_label)

func _create_images_container(vbox: VBoxContainer) -> void:
	var images_container = HBoxContainer.new()
	images_container.name = "ImagesContainer"
	images_container.add_theme_constant_override("separation", 20)
	images_container.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vbox.add_child(images_container)

	# Baseline panel
	var baseline_panel = _create_image_panel(Color(0.15, 0.2, 0.15), Color(0.4, 1, 0.4, 0.5))
	images_container.add_child(baseline_panel)
	var baseline_texture = _create_texture_rect("BaselineTexture")
	baseline_panel.add_child(baseline_texture)

	# Actual panel
	var actual_panel = _create_image_panel(Color(0.2, 0.15, 0.15), Color(1, 0.4, 0.4, 0.5))
	images_container.add_child(actual_panel)
	var actual_texture = _create_texture_rect("ActualTexture")
	actual_panel.add_child(actual_texture)

	# Diff panel
	var diff_panel = _create_image_panel(Color(0.18, 0.15, 0.1), Color(1, 0.6, 0.2, 0.5))
	images_container.add_child(diff_panel)
	var diff_texture = _create_texture_rect("DiffTexture")
	diff_panel.add_child(diff_texture)

func _create_image_panel(bg_color: Color, border_color: Color) -> Panel:
	var panel = Panel.new()
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	var style = StyleBoxFlat.new()
	style.bg_color = bg_color
	style.set_border_width_all(2)
	style.border_color = border_color
	panel.add_theme_stylebox_override("panel", style)
	return panel

func _create_texture_rect(rect_name: String) -> TextureRect:
	var texture_rect = TextureRect.new()
	texture_rect.name = rect_name
	texture_rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	texture_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	texture_rect.offset_left = 5
	texture_rect.offset_top = 5
	texture_rect.offset_right = -5
	texture_rect.offset_bottom = -5
	return texture_rect

func _create_footer(vbox: VBoxContainer) -> void:
	var footer = VBoxContainer.new()
	footer.name = "Footer"
	footer.add_theme_constant_override("separation", 5)
	vbox.add_child(footer)

	var baseline_path_label = Label.new()
	baseline_path_label.name = "BaselinePathLabel"
	baseline_path_label.add_theme_font_size_override("font_size", 12)
	baseline_path_label.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6))
	footer.add_child(baseline_path_label)

	var actual_path_label = Label.new()
	actual_path_label.name = "ActualPathLabel"
	actual_path_label.add_theme_font_size_override("font_size", 12)
	actual_path_label.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6))
	footer.add_child(actual_path_label)

func _update_images() -> void:
	if not _viewer:
		return

	var vbox = _viewer.get_node("VBox")
	var images_container = vbox.get_node("ImagesContainer")
	var footer = vbox.get_node("Footer")

	# Load baseline image
	var baseline_texture_rect = images_container.get_child(0).get_node("BaselineTexture")
	var baseline_image = Image.load_from_file(ProjectSettings.globalize_path(baseline_path))
	if baseline_image:
		var baseline_tex = ImageTexture.create_from_image(baseline_image)
		baseline_texture_rect.texture = baseline_tex

	# Load actual image
	var actual_texture_rect = images_container.get_child(1).get_node("ActualTexture")
	var actual_image = Image.load_from_file(ProjectSettings.globalize_path(actual_path))
	if actual_image:
		var actual_tex = ImageTexture.create_from_image(actual_image)
		actual_texture_rect.texture = actual_tex

	# Generate and show diff image
	var diff_texture_rect = images_container.get_child(2).get_node("DiffTexture")
	if baseline_image and actual_image:
		var diff_image = ScreenshotValidator.generate_diff_image(baseline_image, actual_image)
		var diff_tex = ImageTexture.create_from_image(diff_image)
		diff_texture_rect.texture = diff_tex

	# Update path labels
	var baseline_path_label = footer.get_node("BaselinePathLabel")
	var actual_path_label = footer.get_node("ActualPathLabel")
	baseline_path_label.text = "Baseline: " + baseline_path
	actual_path_label.text = "Actual: " + actual_path
