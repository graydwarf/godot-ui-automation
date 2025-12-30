extends Node2D
class_name VirtualCursor
## Visual cursor overlay for UI test automation
## Displays a cursor sprite that moves with tweened animations

@onready var sprite: Sprite2D = $Sprite2D
@onready var click_indicator: Sprite2D = $ClickIndicator
@onready var trail: Line2D = $Trail

var trail_points: Array[Vector2] = []
const MAX_TRAIL_POINTS = 30

func _ready():
	visible = false
	_create_cursor_textures()
	if click_indicator:
		click_indicator.visible = false

func _create_cursor_textures():
	# Create cursor arrow texture
	if sprite and not sprite.texture:
		sprite.texture = _make_arrow_texture(24, Color(1, 0.3, 0.1))

	# Create click ring texture
	if click_indicator and not click_indicator.texture:
		click_indicator.texture = _make_ring_texture(32, Color(1, 1, 0))

func _make_arrow_texture(size: int, color: Color) -> ImageTexture:
	var img = Image.create(size, size, false, Image.FORMAT_RGBA8)
	# Draw a simple arrow/pointer shape
	for y in range(size):
		for x in range(size):
			# Triangle pointing down-right
			if x <= y and x + y <= size:
				img.set_pixel(x, y, color)
			elif x < 4 and y < size - 4:
				img.set_pixel(x, y, color)
	return ImageTexture.create_from_image(img)

func _make_ring_texture(size: int, color: Color) -> ImageTexture:
	var img = Image.create(size, size, false, Image.FORMAT_RGBA8)
	var center = size / 2.0
	var outer_r = size / 2.0 - 1
	var inner_r = size / 2.0 - 4
	for y in range(size):
		for x in range(size):
			var dist = Vector2(x - center, y - center).length()
			if dist <= outer_r and dist >= inner_r:
				img.set_pixel(x, y, color)
	return ImageTexture.create_from_image(img)

func show_cursor():
	visible = true

func hide_cursor():
	visible = false
	clear_trail()

func move_to(pos: Vector2):
	global_position = pos
	_add_trail_point(pos)

func show_click():
	if click_indicator:
		click_indicator.visible = true
		click_indicator.scale = Vector2(1.5, 1.5)
		click_indicator.modulate.a = 1.0

		var tween = create_tween()
		tween.set_parallel(true)
		tween.tween_property(click_indicator, "scale", Vector2(0.5, 0.5), 0.2)
		tween.tween_property(click_indicator, "modulate:a", 0.0, 0.2)
		tween.chain().tween_callback(func(): click_indicator.visible = false)

func _add_trail_point(pos: Vector2):
	if not trail:
		return
	trail_points.append(pos)
	if trail_points.size() > MAX_TRAIL_POINTS:
		trail_points.pop_front()
	trail.clear_points()
	for point in trail_points:
		trail.add_point(point - global_position)

func clear_trail():
	trail_points.clear()
	if trail:
		trail.clear_points()
