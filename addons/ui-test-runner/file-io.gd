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
## File I/O operations for UI Test Runner

const Utils = preload("res://addons/ui-test-runner/utils.gd")

# =============================================================================
# DIRECTORY OPERATIONS
# =============================================================================

# Ensures the tests directory exists
static func ensure_tests_dir_exists() -> void:
	DirAccess.make_dir_recursive_absolute(
		ProjectSettings.globalize_path(Utils.TESTS_DIR)
	)

# =============================================================================
# TEST FILE OPERATIONS
# =============================================================================

# Saves test data to a JSON file
# Returns the filepath on success, empty string on failure
static func save_test_data(filename: String, test_data: Dictionary) -> String:
	ensure_tests_dir_exists()

	var filepath = Utils.TESTS_DIR + "/" + filename
	var file = FileAccess.open(filepath, FileAccess.WRITE)
	if file:
		file.store_string(JSON.stringify(test_data, "\t"))
		file.close()
		print("[UITestRunner] Test saved: ", filepath)
		return filepath
	else:
		push_error("[UITestRunner] Failed to save test: " + filepath)
		return ""

# Loads test data from a JSON file
static func load_test(filepath: String) -> Dictionary:
	var file = FileAccess.open(filepath, FileAccess.READ)
	if not file:
		push_error("[UITestRunner] Failed to load test: " + filepath)
		return {}

	var json_text = file.get_as_text()
	file.close()

	var json = JSON.new()
	var error = json.parse(json_text)
	if error != OK:
		push_error("[UITestRunner] Failed to parse test JSON: " + filepath)
		return {}

	return json.data

# Gets a list of all saved test names (without .json extension)
static func get_saved_tests() -> Array:
	var tests = []
	var dir = DirAccess.open(Utils.TESTS_DIR)
	if dir:
		dir.list_dir_begin()
		var filename = dir.get_next()
		while filename != "":
			if filename.ends_with(".json") and filename != "categories.json":
				tests.append(filename.replace(".json", ""))
			filename = dir.get_next()
		dir.list_dir_end()
	return tests

# Checks if a test file exists
static func test_exists(test_name: String) -> bool:
	var filepath = Utils.TESTS_DIR + "/" + test_name + ".json"
	return FileAccess.file_exists(filepath)

# Gets the full filepath for a test
static func get_test_filepath(test_name: String) -> String:
	return Utils.TESTS_DIR + "/" + test_name + ".json"

# =============================================================================
# FILE DELETION
# =============================================================================

# Deletes a file and its .import file (to prevent Godot reimport errors)
static func delete_file_and_import(file_path: String) -> void:
	# Delete the file itself
	if FileAccess.file_exists(file_path):
		DirAccess.remove_absolute(file_path)
	# Also delete the .import file to prevent Godot reimport errors
	var import_path = file_path + ".import"
	if FileAccess.file_exists(import_path):
		DirAccess.remove_absolute(import_path)

# Deletes a test by name
static func delete_test(test_name: String) -> void:
	var filepath = get_test_filepath(test_name)
	delete_file_and_import(filepath)
