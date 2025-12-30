extends Node
## Demo UI test for Kilanote card dragging
## Press F9 to run, F10 to change speed

func _ready():
	# Give the app time to load
	await get_tree().create_timer(1.0).timeout
	print("[Demo Test] Ready - Press F9 to run card drag demo")

func _unhandled_input(event):
	if event is InputEventKey and event.pressed and event.keycode == KEY_F9:
		run_card_drag_test()

func run_card_drag_test():
	var runner = get_node_or_null("/root/UITestRunner")
	if not runner:
		push_error("UITestRunner not found - is the plugin enabled?")
		return

	# Find the board
	var board = _find_board()
	if not board:
		push_error("No board found in scene tree")
		return

	runner.begin_test("Card Drag Demo")

	# Find a card to drag
	var cards = board.get_node_or_null("Cards")
	if cards and cards.get_child_count() > 0:
		var card = cards.get_child(0)
		var card_pos = card.global_position + Vector2(50, 30)
		var target_pos = card_pos + Vector2(200, 100)

		print("[Demo Test] Found card at: ", card.global_position)

		# Drag the card
		await runner.drag(card_pos, target_pos, 0.8)
		await runner.wait(0.5)

		# Verify it moved
		var new_pos = card.global_position
		var moved = new_pos.distance_to(card_pos - Vector2(50, 30)) > 50
		print("[Demo Test] Card moved: ", moved, " - New pos: ", new_pos)

		runner.end_test(moved)
	else:
		print("[Demo Test] No cards found - create a card first")
		runner.end_test(false)

func _find_board() -> Node:
	# Try common paths
	var paths = [
		"/root/Main/ContentContainer/BoardContainer/Board",
		"/root/Main/Board",
	]
	for path in paths:
		var node = get_node_or_null(path)
		if node:
			return node

	# Fallback: search for a node named "Board"
	return _find_node_by_name(get_tree().root, "Board")

func _find_node_by_name(node: Node, target_name: String) -> Node:
	if node.name == target_name:
		return node
	for child in node.get_children():
		var result = _find_node_by_name(child, target_name)
		if result:
			return result
	return null
