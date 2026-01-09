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
## Screenshot comparison utilities for Godot UI Automation

const Utils = preload("res://addons/godot-ui-automation/utils/utils.gd")
const CompareMode = Utils.CompareMode

const CONFIG_PATH = "user://godot-ui-automation-config.cfg"

# =============================================================================
# COMPARISON SETTINGS
# =============================================================================

static var compare_mode: CompareMode = CompareMode.TOLERANT
static var compare_tolerance: float = 0.02  # 2% pixel mismatch allowed
static var compare_color_threshold: int = 5  # RGB difference allowed (0-255)
static var playback_speed: int = 2  # Default to NORMAL (index 2 in Speed enum)
static var _config_loaded: bool = false

# Recording HUD button visibility settings
static var show_clipboard_button: bool = false  # Hidden by default
static var show_capture_button: bool = true     # Visible by default
static var enable_last_step_capture: bool = true  # Auto-capture screenshot on last step

# Recording behavior settings
static var default_click_delay: int = 350  # Minimum ms between back-to-back clicks
static var auto_maximize_recording: bool = true  # Maximize window when recording starts
static var show_viewport_warnings: bool = true  # Show viewport mismatch warnings before tests

# Playback behavior settings
static var startup_delay: int = 3000  # Delay before test starts (ms) - time to remove hands from mouse

# =============================================================================
# CONFIGURATION
# =============================================================================

static func set_compare_mode(mode: CompareMode) -> void:
	compare_mode = mode
	print("[UITestRunner] Compare mode: ", CompareMode.keys()[mode])
	save_config()

static func set_tolerant_mode(tolerance: float = 0.02, color_threshold: int = 5) -> void:
	compare_mode = CompareMode.TOLERANT
	compare_tolerance = tolerance
	compare_color_threshold = color_threshold
	print("[UITestRunner] Tolerant mode: %.1f%% pixel threshold, %d color threshold" % [tolerance * 100, color_threshold])
	save_config()

static func get_compare_mode() -> CompareMode:
	return compare_mode

# =============================================================================
# CONFIG PERSISTENCE
# =============================================================================

static func save_config() -> void:
	var config = ConfigFile.new()
	config.set_value("comparison", "mode", compare_mode)
	config.set_value("comparison", "tolerance", compare_tolerance)
	config.set_value("comparison", "color_threshold", compare_color_threshold)
	config.set_value("playback", "speed", playback_speed)
	config.set_value("recording", "show_clipboard_button", show_clipboard_button)
	config.set_value("recording", "show_capture_button", show_capture_button)
	config.set_value("recording", "enable_last_step_capture", enable_last_step_capture)
	config.set_value("recording", "default_click_delay", default_click_delay)
	config.set_value("recording", "auto_maximize_recording", auto_maximize_recording)
	config.set_value("recording", "show_viewport_warnings", show_viewport_warnings)
	config.set_value("playback", "startup_delay", startup_delay)
	var err = config.save(CONFIG_PATH)
	if err == OK:
		print("[UITestRunner] Config saved to %s (speed=%d)" % [ProjectSettings.globalize_path(CONFIG_PATH), playback_speed])
	else:
		push_error("[UITestRunner] Failed to save config to %s: %d" % [CONFIG_PATH, err])

static func load_config() -> void:
	if _config_loaded:
		return
	_config_loaded = true

	var config = ConfigFile.new()
	var full_path = ProjectSettings.globalize_path(CONFIG_PATH)
	var err = config.load(CONFIG_PATH)
	if err != OK:
		# No config file yet - using defaults (config saved on first settings change)
		return

	compare_mode = config.get_value("comparison", "mode", CompareMode.TOLERANT)
	compare_tolerance = config.get_value("comparison", "tolerance", 0.02)
	compare_color_threshold = config.get_value("comparison", "color_threshold", 5)
	playback_speed = config.get_value("playback", "speed", 2)  # Default NORMAL
	show_clipboard_button = config.get_value("recording", "show_clipboard_button", false)
	show_capture_button = config.get_value("recording", "show_capture_button", true)
	enable_last_step_capture = config.get_value("recording", "enable_last_step_capture", true)
	default_click_delay = config.get_value("recording", "default_click_delay", 350)
	auto_maximize_recording = config.get_value("recording", "auto_maximize_recording", true)
	show_viewport_warnings = config.get_value("recording", "show_viewport_warnings", true)
	startup_delay = config.get_value("playback", "startup_delay", 3000)
	print("[UITestRunner] Config loaded from %s - Speed: %d, Mode: %s, ClickDelay: %dms, StartupDelay: %dms" % [
		full_path, playback_speed, CompareMode.keys()[compare_mode], default_click_delay, startup_delay
	])

# =============================================================================
# IMAGE COMPARISON
# =============================================================================

# Compares two images and returns a result dictionary
# Returns: {passed: bool, mismatch_ratio: float, message: String}
static func compare_images(current: Image, baseline: Image) -> Dictionary:
	# Size check
	if current.get_size() != baseline.get_size():
		return {
			"passed": false,
			"mismatch_ratio": 1.0,
			"message": "Size mismatch: %s vs %s" % [current.get_size(), baseline.get_size()]
		}

	if compare_mode == CompareMode.PIXEL_PERFECT:
		return _compare_pixel_perfect(current, baseline)
	else:
		return _compare_tolerant(current, baseline)

static func _compare_pixel_perfect(current: Image, baseline: Image) -> Dictionary:
	for y in range(current.get_height()):
		for x in range(current.get_width()):
			if current.get_pixel(x, y) != baseline.get_pixel(x, y):
				return {
					"passed": false,
					"mismatch_ratio": -1.0,  # Unknown when using pixel perfect
					"message": "Pixel mismatch at (%d, %d)" % [x, y],
					"mismatch_x": x,
					"mismatch_y": y
				}
	return {
		"passed": true,
		"mismatch_ratio": 0.0,
		"message": "Screenshot matches baseline (pixel perfect)!"
	}

static func _compare_tolerant(current: Image, baseline: Image) -> Dictionary:
	var total_pixels = current.get_width() * current.get_height()
	var mismatched_pixels = 0

	for y in range(current.get_height()):
		for x in range(current.get_width()):
			var c1 = current.get_pixel(x, y)
			var c2 = baseline.get_pixel(x, y)
			if not colors_match(c1, c2, compare_color_threshold):
				mismatched_pixels += 1

	var mismatch_ratio = float(mismatched_pixels) / total_pixels
	var passed = mismatch_ratio <= compare_tolerance

	return {
		"passed": passed,
		"mismatch_ratio": mismatch_ratio,
		"mismatched_pixels": mismatched_pixels,
		"total_pixels": total_pixels,
		"message": "%.2f%% pixels differ (threshold: %.1f%%)" % [mismatch_ratio * 100, compare_tolerance * 100]
	}

# =============================================================================
# COLOR COMPARISON
# =============================================================================

static func colors_match(c1: Color, c2: Color, threshold: int) -> bool:
	var t = threshold / 255.0
	return abs(c1.r - c2.r) <= t and abs(c1.g - c2.g) <= t and abs(c1.b - c2.b) <= t and abs(c1.a - c2.a) <= t

# =============================================================================
# DIFF IMAGE GENERATION
# =============================================================================

static func generate_diff_image(baseline: Image, actual: Image) -> Image:
	# Create diff image - show actual with red overlay where pixels differ
	var width = min(baseline.get_width(), actual.get_width())
	var height = min(baseline.get_height(), actual.get_height())

	var diff = Image.create(width, height, false, Image.FORMAT_RGBA8)

	for y in range(height):
		for x in range(width):
			var b_pixel = baseline.get_pixel(x, y)
			var a_pixel = actual.get_pixel(x, y)

			if b_pixel == a_pixel:
				# Same - show grayscale version of actual
				var gray = (a_pixel.r + a_pixel.g + a_pixel.b) / 3.0
				diff.set_pixel(x, y, Color(gray * 0.5, gray * 0.5, gray * 0.5, 1.0))
			else:
				# Different - show red tinted overlay
				diff.set_pixel(x, y, Color(1.0, 0.2, 0.2, 1.0))

	return diff

# =============================================================================
# DEBUG SCREENSHOT
# =============================================================================

static func save_debug_screenshot(current: Image, baseline_path: String, run_id: String = "") -> String:
	var suffix = "_actual.png"
	if not run_id.is_empty():
		suffix = "_run%s_actual.png" % run_id
	var debug_path = baseline_path.replace(".png", suffix)
	current.save_png(ProjectSettings.globalize_path(debug_path))
	print("[UITestRunner] Saved actual screenshot to: ", debug_path)
	return debug_path
