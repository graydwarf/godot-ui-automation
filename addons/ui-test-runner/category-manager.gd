class_name UICategoryManager
extends RefCounted
## Category management for UI Test Runner

const Utils = preload("res://addons/ui-test-runner/utils.gd")
const FileIO = preload("res://addons/ui-test-runner/file-io.gd")

# =============================================================================
# CATEGORY DATA STRUCTURES
# =============================================================================

# Shared state - accessible to main class
static var test_categories: Dictionary = {}       # test_name -> category
static var collapsed_categories: Dictionary = {}  # category -> is_collapsed
static var category_test_order: Dictionary = {}   # category -> [ordered test names]

# =============================================================================
# LOAD/SAVE OPERATIONS
# =============================================================================

# Loads category data from file
static func load_categories() -> void:
	test_categories.clear()
	collapsed_categories.clear()
	category_test_order.clear()

	var file = FileAccess.open(Utils.CATEGORIES_FILE, FileAccess.READ)
	if not file:
		return  # No categories file yet, that's fine

	var json_text = file.get_as_text()
	file.close()

	var json = JSON.new()
	if json.parse(json_text) == OK:
		var data = json.data
		if data.has("test_categories"):
			test_categories = data.test_categories
		if data.has("collapsed"):
			collapsed_categories = data.collapsed
		if data.has("test_order"):
			category_test_order = data.test_order

	# Clean up stale entries (tests that no longer exist)
	cleanup_stale_category_entries()

# Saves category data to file
static func save_categories() -> void:
	var data = {
		"test_categories": test_categories,
		"collapsed": collapsed_categories,
		"test_order": category_test_order
	}

	var file = FileAccess.open(Utils.CATEGORIES_FILE, FileAccess.WRITE)
	if file:
		file.store_string(JSON.stringify(data, "\t"))
		file.close()

# =============================================================================
# CATEGORY CRUD OPERATIONS
# =============================================================================

# Returns sorted list of all unique categories (including empty ones)
static func get_all_categories() -> Array:
	var categories = []
	# Include categories from test assignments
	for cat in test_categories.values():
		if cat and cat not in categories:
			categories.append(cat)
	# Include empty categories from category_test_order
	for cat in category_test_order.keys():
		if cat and cat not in categories:
			categories.append(cat)
	categories.sort()
	return categories

# Gets the category for a test (or empty string if uncategorized)
static func get_test_category(test_name: String) -> String:
	return test_categories.get(test_name, "")

# Assigns a test to a category with optional ordering
static func set_test_category(test_name: String, category: String, insert_index: int = -1) -> void:
	var old_category = test_categories.get(test_name, "")

	# Remove from old category order
	if old_category and category_test_order.has(old_category):
		category_test_order[old_category].erase(test_name)

	if category.is_empty():
		test_categories.erase(test_name)
	else:
		test_categories[test_name] = category
		# Add to new category order
		if not category_test_order.has(category):
			category_test_order[category] = []
		if test_name not in category_test_order[category]:
			if insert_index >= 0 and insert_index <= category_test_order[category].size():
				category_test_order[category].insert(insert_index, test_name)
			else:
				category_test_order[category].append(test_name)

	save_categories()

# Returns tests in saved order for a category
static func get_ordered_tests(category_name: String, tests: Array) -> Array:
	if not category_test_order.has(category_name):
		return tests

	var order = category_test_order[category_name]
	var ordered: Array = []

	# Add tests in saved order (if they still exist)
	for test_name in order:
		if test_name in tests:
			ordered.append(test_name)

	# Add any remaining tests not in saved order
	for test_name in tests:
		if test_name not in ordered:
			ordered.append(test_name)

	return ordered

# =============================================================================
# COLLAPSE STATE MANAGEMENT
# =============================================================================

# Checks if a category is collapsed (default: true = collapsed)
static func is_collapsed(category_name: String) -> bool:
	return collapsed_categories.get(category_name, true)

# Toggles collapse state for a category
static func toggle_collapsed(category_name: String) -> bool:
	var new_state = not collapsed_categories.get(category_name, true)
	collapsed_categories[category_name] = new_state
	save_categories()
	return new_state

# =============================================================================
# CLEANUP OPERATIONS
# =============================================================================

# Removes category entries for tests that no longer exist
static func cleanup_stale_category_entries() -> void:
	var saved_tests = FileIO.get_saved_tests()
	var stale_tests: Array = []

	# Find stale test_categories entries
	for test_name in test_categories.keys():
		if test_name not in saved_tests:
			stale_tests.append(test_name)

	# Remove stale entries
	for test_name in stale_tests:
		print("[UITestRunner] Removing stale category entry: ", test_name)
		test_categories.erase(test_name)

	# Clean up category_test_order
	for category_name in category_test_order.keys():
		var order: Array = category_test_order[category_name]
		var cleaned: Array = []
		for test_name in order:
			if test_name in saved_tests:
				cleaned.append(test_name)
		category_test_order[category_name] = cleaned

	# Save if we cleaned anything
	if not stale_tests.is_empty():
		save_categories()

# Deletes a category and moves all its tests to uncategorized
static func delete_category(category_name: String) -> void:
	# Remove all tests from this category
	for test_name in test_categories.keys():
		if test_categories[test_name] == category_name:
			test_categories.erase(test_name)

	# Remove category from order tracking
	category_test_order.erase(category_name)

	# Remove from collapsed state
	collapsed_categories.erase(category_name)

	save_categories()

# Renames a category, preserving test assignments and order
static func rename_category(old_name: String, new_name: String) -> void:
	if old_name == new_name or new_name.is_empty():
		return

	# Update all test category assignments
	for test_name in test_categories.keys():
		if test_categories[test_name] == old_name:
			test_categories[test_name] = new_name

	# Move test order to new category name
	if category_test_order.has(old_name):
		category_test_order[new_name] = category_test_order[old_name]
		category_test_order.erase(old_name)

	# Move collapsed state to new category name
	if collapsed_categories.has(old_name):
		collapsed_categories[new_name] = collapsed_categories[old_name]
		collapsed_categories.erase(old_name)

	save_categories()
