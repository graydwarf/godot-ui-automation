extends RefCounted
class_name UIRegionSelector
## Region selection overlay for screenshot capture

signal selection_completed(rect: Rect2)
signal selection_cancelled

# Required references (set via initialize)
var _tree: SceneTree
var _parent: CanvasLayer

# Selection state
var is_selecting: bool = false
var selection_start: Vector2 = Vector2.ZERO
var selection_rect: Rect2 = Rect2()

# UI elements
var _overlay: Control = null

# Initializes the region selector with required references
func initialize(tree: SceneTree, parent: CanvasLayer) -> void:
	_tree = tree
	_parent = parent

# ============================================================================
# SELECTION CONTROL
# ============================================================================

func start_selection() -> void:
	is_selecting = true
	print("[UIRegionSelector] Draw a rectangle to capture screenshot (ESC to cancel)")

	# Pause the game for clean capture
	_tree.paused = true

	_ensure_overlay_exists()
	_overlay.visible = true
	selection_rect = Rect2()
	_overlay.queue_redraw()

func cancel_selection() -> void:
	is_selecting = false
	if _overlay:
		_overlay.visible = false
	_tree.paused = false
	print("[UIRegionSelector] Selection cancelled")
	selection_cancelled.emit()

func finish_selection() -> void:
	is_selecting = false
	if _overlay:
		_overlay.visible = false
	_tree.paused = false

	if selection_rect.size.x < 10 or selection_rect.size.y < 10:
		print("[UIRegionSelector] Selection too small, cancelled")
		selection_cancelled.emit()
		return

	selection_completed.emit(selection_rect)

func get_selection_rect() -> Rect2:
	return selection_rect

func hide_overlay() -> void:
	if _overlay:
		_overlay.visible = false

# ============================================================================
# OVERLAY UI
# ============================================================================

func _ensure_overlay_exists() -> void:
	if _overlay:
		return

	_overlay = Control.new()
	_overlay.name = "RegionSelectionOverlay"
	_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	_overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	_overlay.process_mode = Node.PROCESS_MODE_ALWAYS
	_parent.add_child(_overlay)
	_overlay.draw.connect(_draw_overlay)
	_overlay.gui_input.connect(_on_overlay_gui_input)

func _on_overlay_gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			selection_start = event.global_position
			selection_rect = Rect2(selection_start, Vector2.ZERO)
		else:
			if selection_rect.size.length() > 10:
				finish_selection()

	elif event is InputEventMouseMotion:
		_overlay.queue_redraw()
		if Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
			var current = event.global_position
			selection_rect = Rect2(
				Vector2(min(selection_start.x, current.x), min(selection_start.y, current.y)),
				Vector2(abs(current.x - selection_start.x), abs(current.y - selection_start.y))
			)

	elif event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		cancel_selection()

func _draw_overlay() -> void:
	var viewport_size = _parent.get_viewport().get_visible_rect().size
	var overlay_color = Color(0, 0, 0, 0.6)
	var mouse_pos = _overlay.get_local_mouse_position()

	if selection_rect.size.length() > 5:
		_draw_selection_overlay(viewport_size, overlay_color)
	else:
		_draw_crosshair_overlay(viewport_size, overlay_color, mouse_pos)

	_draw_instructions(viewport_size)

func _draw_selection_overlay(viewport_size: Vector2, overlay_color: Color) -> void:
	# Draw darkened areas around selection (Win11 style)
	_overlay.draw_rect(Rect2(0, 0, viewport_size.x, selection_rect.position.y), overlay_color)
	_overlay.draw_rect(Rect2(0, selection_rect.end.y, viewport_size.x, viewport_size.y - selection_rect.end.y), overlay_color)
	_overlay.draw_rect(Rect2(0, selection_rect.position.y, selection_rect.position.x, selection_rect.size.y), overlay_color)
	_overlay.draw_rect(Rect2(selection_rect.end.x, selection_rect.position.y, viewport_size.x - selection_rect.end.x, selection_rect.size.y), overlay_color)

	# Draw selection border
	_overlay.draw_rect(selection_rect, Color(0.2, 0.8, 1.0, 1), false, 2.0)

	# Draw corner handles
	var handle_size = 8.0
	var corners = [
		selection_rect.position,
		Vector2(selection_rect.end.x, selection_rect.position.y),
		selection_rect.end,
		Vector2(selection_rect.position.x, selection_rect.end.y)
	]
	for corner in corners:
		_overlay.draw_rect(Rect2(corner - Vector2(handle_size/2, handle_size/2), Vector2(handle_size, handle_size)), Color(0.2, 0.8, 1.0, 1), true)

	# Draw size label
	var size_text = "%d x %d" % [int(selection_rect.size.x), int(selection_rect.size.y)]
	var font = ThemeDB.fallback_font
	var font_size = 14
	var text_pos = Vector2(selection_rect.position.x, selection_rect.position.y - 25)
	if text_pos.y < 30:
		text_pos.y = selection_rect.end.y + 20
	_overlay.draw_string(font, text_pos, size_text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, Color.WHITE)

func _draw_crosshair_overlay(viewport_size: Vector2, overlay_color: Color, mouse_pos: Vector2) -> void:
	# Full overlay
	_overlay.draw_rect(Rect2(Vector2.ZERO, viewport_size), overlay_color)

	# Draw crosshair at mouse position
	var crosshair_color = Color(1, 1, 1, 0.8)
	var line_width = 1.0
	_overlay.draw_line(Vector2(0, mouse_pos.y), Vector2(viewport_size.x, mouse_pos.y), crosshair_color, line_width)
	_overlay.draw_line(Vector2(mouse_pos.x, 0), Vector2(mouse_pos.x, viewport_size.y), crosshair_color, line_width)

	# Draw coordinate label near cursor
	var coord_text = "(%d, %d)" % [int(mouse_pos.x), int(mouse_pos.y)]
	var font = ThemeDB.fallback_font
	var font_size = 12
	_overlay.draw_string(font, mouse_pos + Vector2(15, -10), coord_text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, Color.WHITE)

func _draw_instructions(viewport_size: Vector2) -> void:
	var instructions = "Drag to select region  |  ESC to cancel"
	var font = ThemeDB.fallback_font
	var font_size = 16
	var text_width = font.get_string_size(instructions, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x
	var text_pos = Vector2((viewport_size.x - text_width) / 2, 40)

	var padding = 10
	var bg_rect = Rect2(text_pos.x - padding, text_pos.y - font_size - padding/2, text_width + padding * 2, font_size + padding)
	_overlay.draw_rect(bg_rect, Color(0, 0, 0, 0.8), true, -1, 4.0)
	_overlay.draw_string(font, text_pos, instructions, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, Color.WHITE)
