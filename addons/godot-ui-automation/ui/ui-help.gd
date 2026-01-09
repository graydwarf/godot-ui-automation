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
## Shared Help component for Godot UI Automation
## Combines tips and help topics in one scrollable view

const Utils = preload("res://addons/godot-ui-automation/utils/utils.gd")

var _tree: SceneTree
var _content: VBoxContainer

func initialize(tree: SceneTree) -> void:
	_tree = tree

# Creates and returns the help content wrapped in styled container
func create_help_content() -> PanelContainer:
	# Outer styled panel with About-style border
	var outer_panel = PanelContainer.new()
	var outer_style = StyleBoxFlat.new()
	outer_style.bg_color = Color(0.12, 0.15, 0.2, 0.8)
	outer_style.border_color = Color(0.3, 0.5, 0.8, 0.6)
	outer_style.set_border_width_all(1)
	outer_style.set_corner_radius_all(8)
	outer_style.set_content_margin_all(10)
	outer_panel.add_theme_stylebox_override("panel", outer_style)
	outer_panel.size_flags_vertical = Control.SIZE_EXPAND_FILL

	var scroll = ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	outer_panel.add_child(scroll)

	var help_vbox = VBoxContainer.new()
	help_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	help_vbox.add_theme_constant_override("separation", 16)
	scroll.add_child(help_vbox)

	# === GETTING STARTED ===
	_add_section_header(help_vbox, "Getting Started")

	_add_help_topic(help_vbox, "What is %s?" % Utils.PLUGIN_NAME,
		"%s is a visual regression testing tool that uses coordinate-based automation. " % Utils.PLUGIN_NAME +
		"It records your mouse clicks, drags, and keyboard input at specific screen coordinates, " +
		"then replays them exactly during test execution. Screenshots are captured and compared " +
		"pixel-by-pixel to detect visual changes in your UI.\n\n" +
		"This approach is best suited for:\n" +
		"  - Catching unintended visual regressions\n" +
		"  - Testing UI layouts and styling\n" +
		"  - Verifying drag-and-drop interactions\n" +
		"  - End-to-end workflow validation\n\n" +
		"Note: Tests are resolution-dependent. Record and run tests at the same window size for best results.")

	# === KEYBOARD SHORTCUTS ===
	_add_section_header(help_vbox, "Keyboard Shortcuts")

	_add_help_topic(help_vbox, "General",
		"F12: Toggle Test Manager\n" +
		"ESC: Close dialogs / Stop test")

	_add_help_topic(help_vbox, "Recording",
		"F10: Capture screenshot\n" +
		"F11: Stop recording\n" +
		"Ctrl+B: Terminate current drag step")

	_add_help_topic(help_vbox, "Playback",
		"Space: Step forward\n" +
		"R: Restart current test\n" +
		"P: Play to end")

	# === RECORDING ===
	_add_section_header(help_vbox, "Recording")

	_add_help_topic(help_vbox, "Recording Basics",
		"Press F11 to stop recording. Interact with your UI - clicks, drags, and text input are captured. " +
		"Press F10 to take screenshots at key moments. Press ESC to cancel recording without saving.")

	_add_help_topic(help_vbox, "Screenshot Capture",
		"Use F10 or the camera button to capture screenshots during recording. These become the baseline " +
		"images that tests compare against. Capture at key moments where UI state matters.")

	_add_help_topic(help_vbox, "Focus & Recording UI",
		"Clicking buttons in the Recording UI (camera, stop, etc.) can steal focus from your app's " +
		"controls. Use keyboard shortcuts to avoid this: F10 for screenshot capture and F11 to stop " +
		"recording. This keeps focus on your app's text fields or other controls.")

	_add_help_topic(help_vbox, "Terminate Drag (Ctrl+B)",
		"Press Ctrl+B during recording to terminate a drag step. This is useful for complex drag " +
		"operations that should be split into multiple steps, or when you need precise control " +
		"over where drag operations end.")

	_add_help_topic(help_vbox, "Last Step Capture",
		"When enabled, automatically enters screenshot mode after the final step. Useful for validation " +
		"tests where you want to verify the end state without manually triggering capture. " +
		"Press ESC to cancel the screenshot if you don't need it.")

	_add_help_topic(help_vbox, "Test Image Button",
		"The test image button places a checkerboard pattern in your clipboard. Use Ctrl+V to paste " +
		"during recording to test image handling features in your application. " +
		"This is a hidden option by default - see toggle options in Settings.")

	_add_help_topic(help_vbox, "Environment & Resolution",
		"Tests record your viewport size and window state. If you play back at a different resolution, " +
		"you'll see a warning indicator. For best results, record and play tests at the same window size. " +
		"By default, test runs will maximize the window to match recording settings.")

	# === RUNNING TESTS ===
	_add_section_header(help_vbox, "Running Tests")

	_add_help_topic(help_vbox, "Running Tests",
		"Click the play button next to any test to run it. Use 'Run All Tests' to execute " +
		"the entire suite. Tests replay your recorded actions and compare screenshots to detect UI changes.")

	_add_help_topic(help_vbox, "Click Timing",
		"To prevent consecutive clicks from being interpreted as double-clicks by the OS, " +
		"a minimum 350ms delay is automatically added between clicks during playback. " +
		"This ensures single-click actions remain single-clicks even when recorded quickly.")

	_add_help_topic(help_vbox, "Screenshot Comparison",
		"Tests validate UI by comparing screenshots. Use 'Pixel Perfect' mode for exact matches, " +
		"or 'Tolerant' mode to allow minor differences. Adjust tolerance in Settings if tests fail due to anti-aliasing or fonts.")

	# === EDITING & ORGANIZATION ===
	_add_section_header(help_vbox, "Editing & Organization")

	_add_help_topic(help_vbox, "Test Editor",
		"Click the edit button (pencil icon) to open the Test Editor. This shows all " +
		"recorded actions and lets you step through them one at a time. Press Space to step forward, " +
		"R to restart, or use the Re-record button to capture new actions.")

	_add_help_topic(help_vbox, "Adding Delays",
		"Use the wait dropdown in the Test Editor to adjust delays for each step.")

	_add_help_topic(help_vbox, "Categories",
		"Organize tests into categories using '+ New Category'. Drag tests between categories " +
		"using the handle. Click category headers to collapse/expand. Run all tests in a category with its play button.")

	_add_help_topic(help_vbox, "Updating Baselines",
		"When UI intentionally changes, click the rerecord button to capture new baseline screenshots. " +
		"This runs the test and saves new reference images without failing on differences.")

	# === INTEGRATION ===
	_add_section_header(help_vbox, "App Integration")

	_add_help_topic(help_vbox, "Integration Signals",
		"Connect to these signals on the UITestRunner autoload to integrate with your app:\n\n" +
		"ui_test_runner_setup_environment() - Emitted at start of run. Use to go fullscreen, " +
		"navigate to test board, or configure window size.\n\n" +
		"ui_test_runner_test_starting(test_name) - Emitted before each test. Use to clear " +
		"the board, reset zoom, or prepare a clean state.\n\n" +
		"ui_test_runner_test_ended(test_name, passed) - Emitted after each test completes. " +
		"Use for logging or per-test cleanup.\n\n" +
		"ui_test_runner_run_completed() - Emitted when all tests finish. Use to restore " +
		"app state, exit fullscreen, or show summary.")

	_add_help_topic(help_vbox, "Settings & Config",
		"Your preferences (comparison mode, tolerance, playback speed) are saved to " +
		"'user://godot-ui-automation-config.cfg'. This file is created automatically when you " +
		"change settings. Tests are stored in 'res://tests/ui-tests/' within your project.")

	return outer_panel

func _add_section_header(container: VBoxContainer, header_text: String) -> void:
	# Add spacing before header (except for first one)
	if container.get_child_count() > 0:
		var spacer = Control.new()
		spacer.custom_minimum_size = Vector2(0, 8)
		container.add_child(spacer)

	var header_container = VBoxContainer.new()
	header_container.add_theme_constant_override("separation", 4)
	container.add_child(header_container)

	var header = Label.new()
	header.text = header_text
	header.add_theme_font_size_override("font_size", 17)
	header.add_theme_color_override("font_color", Color(0.5, 0.8, 0.95))
	header_container.add_child(header)

	# Separator line
	var sep = HSeparator.new()
	sep.add_theme_stylebox_override("separator", _create_separator_style())
	header_container.add_child(sep)

func _create_separator_style() -> StyleBoxLine:
	var style = StyleBoxLine.new()
	style.color = Color(0.35, 0.55, 0.8, 0.6)
	style.thickness = 1
	return style

func _add_help_topic(container: VBoxContainer, topic_title: String, topic_text: String) -> void:
	var topic_vbox = VBoxContainer.new()
	topic_vbox.add_theme_constant_override("separation", 4)
	container.add_child(topic_vbox)

	var title_label = Label.new()
	title_label.text = topic_title
	title_label.add_theme_font_size_override("font_size", 15)
	title_label.add_theme_color_override("font_color", Color(0.85, 0.85, 0.9))
	topic_vbox.add_child(title_label)

	var text_label = Label.new()
	text_label.text = topic_text
	text_label.add_theme_font_size_override("font_size", 13)
	text_label.add_theme_color_override("font_color", Color(0.65, 0.65, 0.7))
	text_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	topic_vbox.add_child(text_label)
