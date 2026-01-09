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
## Shared constants, enums, and utility functions for Godot UI Automation

# =============================================================================
# ENUMS
# =============================================================================

enum Speed { INSTANT, FAST, NORMAL, SLOW, STEP }

enum CompareMode { PIXEL_PERFECT, TOLERANT }

# =============================================================================
# PLUGIN IDENTITY
# =============================================================================

const PLUGIN_NAME = "Godot UI Automation"
const PLUGIN_SUBTITLE = "Visual UI Automation Testing for Godot"

# =============================================================================
# CONSTANTS
# =============================================================================

const TESTS_DIR = "res://tests/ui-tests"
const CATEGORIES_FILE = "res://tests/ui-tests/categories.json"

const SPEED_MULTIPLIERS = {
	Speed.INSTANT: 0.0,
	Speed.FAST: 0.25,
	Speed.NORMAL: 1.0,
	Speed.SLOW: 2.5,
	Speed.STEP: -1.0  # Wait for keypress
}

const DEFAULT_DELAYS = {
	"click": 100,
	"double_click": 100,
	"drag": 100,
	"key": 50,
	"wait": 1000
}

# =============================================================================
# BUTTON TOOLTIPS
# =============================================================================

const TOOLTIP_RUN_TEST = "Run test"
const TOOLTIP_EDIT_TEST = "View/edit test steps"
const TOOLTIP_RERECORD_TEST = "Rerecord test"
const TOOLTIP_DELETE_TEST = "Delete test"
const TOOLTIP_VIEW_FAILED_STEP = "View failed step"
const TOOLTIP_COMPARE_SCREENSHOTS = "Compare screenshots"

# =============================================================================
# FILE UTILITIES
# =============================================================================

# Converts text to a safe filename, removing/replacing invalid characters
static func sanitize_filename(text: String) -> String:
	# First convert to snake_case and replace spaces
	var result = text.to_snake_case().replace(" ", "_")
	# Remove characters invalid in filenames (Windows: \ / : * ? " < > |)
	result = result.replace("/", "_").replace("\\", "_")
	result = result.replace(":", "_").replace("*", "_")
	result = result.replace("?", "_").replace("\"", "_")
	result = result.replace("<", "_").replace(">", "_")
	result = result.replace("|", "_")
	# Collapse multiple underscores
	while result.contains("__"):
		result = result.replace("__", "_")
	# Trim leading/trailing underscores
	result = result.strip_edges().trim_prefix("_").trim_suffix("_")
	return result

# Gets display name from test data with fallback to formatted filename
static func get_display_name(test_data: Dictionary, fallback_filename: String) -> String:
	var stored_name = test_data.get("name", "")
	# Use stored name if it looks like a proper display name (not sanitized)
	if stored_name.is_empty() or (stored_name.contains("_") and stored_name == stored_name.to_lower()):
		# Looks like a sanitized filename - format it nicely
		return fallback_filename.replace("_", " ").capitalize()
	else:
		# Use the stored display name as-is
		return stored_name

# =============================================================================
# NODE UTILITIES
# =============================================================================

# Recursively searches for a node by name
static func find_node_recursive(node: Node, node_name: String) -> Node:
	if node.name == node_name:
		return node
	for child in node.get_children():
		var found = find_node_recursive(child, node_name)
		if found:
			return found
	return null
