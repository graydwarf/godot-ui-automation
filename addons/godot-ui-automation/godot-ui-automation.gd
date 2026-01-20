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

extends CanvasLayer
## Godot UI Automation - Autoload singleton for automated UI testing
## Provides tweened mouse simulation with visible cursor feedback

# Import shared utilities
const Utils = preload("res://addons/godot-ui-automation/utils/utils.gd")
const FileIO = preload("res://addons/godot-ui-automation/utils/file-io.gd")
const CategoryManager = preload("res://addons/godot-ui-automation/utils/category-manager.gd")
const ScreenshotValidator = preload("res://addons/godot-ui-automation/utils/screenshot-validator.gd")
const PlaybackEngine = preload("res://addons/godot-ui-automation/core/playback-engine.gd")
const RecordingEngine = preload("res://addons/godot-ui-automation/core/recording-engine.gd")
const RegionSelector = preload("res://addons/godot-ui-automation/ui/region-selector.gd")
const TestExecutor = preload("res://addons/godot-ui-automation/core/test-executor.gd")
const ComparisonViewer = preload("res://addons/godot-ui-automation/ui/comparison-viewer.gd")
const TestManager = preload("res://addons/godot-ui-automation/ui/test-manager.gd")
const Speed = Utils.Speed
const CompareMode = Utils.CompareMode
const SPEED_MULTIPLIERS = Utils.SPEED_MULTIPLIERS
const DEFAULT_DELAYS = Utils.DEFAULT_DELAYS
const TESTS_DIR = Utils.TESTS_DIR
const CATEGORIES_FILE = Utils.CATEGORIES_FILE

signal test_started(test_name: String)
signal test_completed(test_name: String, passed: bool)
signal action_performed(action: String, details: Dictionary)
signal test_mode_changed(active: bool)

# App-facing signals for test automation setup/cleanup
# Apps can connect to these to configure their environment for testing
signal ui_test_runner_setup_environment()  # Emitted at start of test run (go fullscreen, navigate to test board)
signal ui_test_runner_test_starting(test_name: String, setup_config: Dictionary)  # Emitted before each test with recorded viewport info
signal ui_test_runner_test_ended(test_name: String, passed: bool)  # Emitted after each test
signal ui_test_runner_run_completed()  # Emitted when all tests complete (but session may continue)
signal ui_test_runner_session_ended()  # Emitted when Test Manager closes after running tests (restore window state)
signal ui_test_runner_recording_started()  # Emitted when recording starts (app can maximize window, etc.)

# Track if we've already warned about missing handlers this session
var _warned_missing_handlers: bool = false

# Check if app has connected handlers to the integration signals
# Returns array of warning messages for missing handlers
func _check_signal_handlers() -> Array[String]:
	var warnings: Array[String] = []

	if ui_test_runner_setup_environment.get_connections().is_empty():
		warnings.append("No handler for ui_test_runner_setup_environment - app won't configure test environment")

	if ui_test_runner_test_starting.get_connections().is_empty():
		warnings.append("No handler for ui_test_runner_test_starting - app won't reset state between tests")

	return warnings

# Print handler warnings once per session (non-blocking, console only)
func _warn_missing_handlers() -> void:
	if _warned_missing_handlers:
		return

	var warnings = _check_signal_handlers()
	if warnings.is_empty():
		return

	_warned_missing_handlers = true
	print("[UITestRunner] ⚠️  Missing signal handlers:")
	for warning in warnings:
		print("[UITestRunner]   - %s" % warning)
	print("[UITestRunner] Connect to these signals to configure window state and test environment.")

# Get setup config for a test (for passing to ui_test_runner_test_starting signal)
# Returns dictionary with recorded_viewport and window_mode info
func _get_test_setup_config(test_name: String) -> Dictionary:
	# Convert display name to filename format (e.g., "New Test 1" -> "new_test_1")
	var filename = Utils.sanitize_filename(test_name)
	var filepath = TESTS_DIR + "/" + filename + ".json"
	var test_data = FileIO.load_test(filepath)
	if test_data.is_empty():
		return {}

	var setup = test_data.get("setup", {})
	var recorded_viewport = test_data.get("recorded_viewport", {})

	return {
		"recorded_viewport": Vector2i(
			recorded_viewport.get("w", 1920),
			recorded_viewport.get("h", 1080)
		),
		"window_mode": setup.get("window_mode", "unknown")
	}

# Test mode flag - when true, board should disable auto-panning
var test_mode_active: bool = false:
	set(value):
		test_mode_active = value
		# Set generic automation flag on tree (decoupled from test framework)
		get_tree().set_meta("automation_mode", value)

# Injected test image for playback - bypasses system clipboard
# Set by playback engine, consumed by clipboard manager
var injected_clipboard_image: Image = null

var virtual_cursor: Node2D
var current_test_name: String = ""

# Playback engine instance (uses const type to avoid class_name resolution issues)
var _playback: PlaybackEngine

# Recording engine instance
var _recording: RecordingEngine

# Region selector instance
var _region_selector: RegionSelector

# Test executor instance
var _executor: TestExecutor

# UI components
var _comparison_viewer: ComparisonViewer
var _test_manager: TestManager

# Test Editor HUD (step debugger)
var _test_editor_hud: Control
var _test_editor_hud_step_label: Label
var _test_editor_hud_event_label: Label
var _test_editor_hud_pause_continue_btn: Button  # Play button: starts running, disabled while running
var _test_editor_hud_step_btn: Button
var _test_editor_hud_restart_btn: Button
var _test_editor_hud_rerecord_btn: Button
var _test_editor_hud_panel: Panel  # Panel for border color changes
var _test_editor_hud_details_btn: Button  # Toggle body visibility (renamed from steps_btn)
var _test_editor_hud_visibility_btn: Button  # Toggle HUD visibility during playback
var _test_editor_hud_body_container: VBoxContainer  # Collapsible body section
var _test_editor_hud_steps_scroll: ScrollContainer  # Scrollable step list
var _test_editor_hud_steps_list: VBoxContainer  # Container for step rows
var _test_editor_hud_step_rows: Array[Control] = []  # References to step row controls
var _test_editor_hud_current_events: Array[Dictionary] = []  # Current test events for editing
var _test_editor_hud_collapsed: bool = true  # Body collapsed state (default collapsed)
var _test_editor_hud_hidden_during_playback: bool = false  # Hide HUD during playback
var _auto_play_steps: Dictionary = {}  # Step indices that should auto-play (skip pause)
var _failed_step_index: int = -1  # Step that failed during step debugging (-1 = none)
var _passed_step_indices: Array[int] = []  # Steps that passed during test execution
var _step_mode_test_passed: bool = false  # Whether test passed in step mode (for restart and checkmark)
var _test_editor_hud_title_edit: LineEdit  # Editable test name in header
var _test_editor_hud_close_btn: Button  # Close button for F12 flash
var _test_editor_hud_env_warning: Control  # Yellow environment mismatch warning
var _hud_saved_focus: Control = null  # Saved focus owner when HUD button is pressed

# Pass/Fail result indicator (shown during test runs)
var _result_indicator: TextureRect = null
var _result_indicator_tween: Tween = null
var _pass_icon_texture: Texture2D = null
var _fail_icon_texture: Texture2D = null
var _test_warning_overlay: Control = null  # "Starting test..." warning overlay
var _test_warning_countdown_label: Label = null  # Countdown timer label
var _test_warning_countdown_timer: Timer = null  # Timer for countdown updates
var _test_warning_countdown_remaining: int = 0  # Remaining seconds
var _test_warning_active: bool = false  # True while warning overlay is visible and waiting
var _test_warning_cancelled: bool = false  # True if ESC pressed during warning
var _last_text_focus: Control = null  # Last TextEdit/LineEdit that had focus (for HUD button restore)
var _last_text_was_editable: bool = false  # Whether _last_text_focus was editable (LineEdit only)
var _last_caret_column: int = 0  # Saved caret position for LineEdit
var _last_selection_start: int = 0  # Saved selection start
var _last_selection_end: int = 0  # Saved selection end (if different from start, text is selected)

# Track current test for restart functionality
var _current_running_test_name: String = ""
var _debug_here_mode: bool = false  # Skip environment setup, run on current board
var _debug_from_results: bool = false  # True if step debugging was started from Results tab
var _skip_cursor_move_on_pause: bool = false  # Skip cursor warp to step button on next pause (after reset)
var _pending_failed_step_highlight: int = -1  # Failed step to highlight after HUD appears (-1 = none)

# Reference to main viewport for coordinate conversion
var main_viewport: Viewport

# Recording state (delegated to _recording engine)
var is_recording: bool:
	get: return _recording.is_recording if _recording else false
	set(value): if _recording: _recording.is_recording = value

var is_recording_paused: bool:
	get: return _recording.is_recording_paused if _recording else false
	set(value): if _recording: _recording.is_recording_paused = value

var recorded_events: Array[Dictionary]:
	get: return _recording.recorded_events if _recording else []

var recorded_screenshots: Array[Dictionary]:
	get: return _recording.recorded_screenshots if _recording else []

# Legacy mouse state for compatibility (still used in some places)
var last_mouse_pos: Vector2 = Vector2.ZERO

# Screenshot selection state (delegates to _region_selector)
var is_selecting_region: bool:
	get: return _region_selector.is_selecting if _region_selector else false
	set(value): if _region_selector: _region_selector.is_selecting = value

var selection_rect: Rect2:
	get: return _region_selector.selection_rect if _region_selector else Rect2()

# Business logic flags for during-recording capture (remain in main file)
var is_capturing_during_recording: bool = false  # True when capturing mid-recording
var was_paused_before_capture: bool = false  # To restore pause state after capture

# Test files (constants imported from Utils)
var test_selector_panel: Control = null
var is_selector_open: bool = false

# Batch test execution
var batch_results: Array[Dictionary] = []  # [{name, passed, baseline_path, actual_path}]
var is_batch_running: bool = false
var _batch_cancelled: bool = false  # Set to true to cancel batch run

# Test run history - stores last 100 test runs (not individual tests)
const MAX_RUN_HISTORY: int = 100
const RUN_HISTORY_FILE: String = "user://godot-ui-automation-history.json"
var test_run_history: Array[Dictionary] = []  # [{id, timestamp, datetime, results}]
var _current_run_id: String = ""  # ID of current run in progress
var _test_session_active: bool = false  # True when tests have run and window state needs restoring

# Re-recording state (for Update Baseline)
var rerecording_test_name: String = ""  # When non-empty, save will overwrite this test
var _sync_collapse_from_recording: bool = false  # Flag to sync collapse state after recording finishes

# Auto-run mode (command-line triggered)
var _auto_run_mode: bool = false
var _exit_on_complete: bool = false

# Recording indicator and HUD (now managed by _recording engine)
# Kept for backwards compatibility with any code referencing these
var recording_indicator: Control:
	get: return _recording._recording_indicator if _recording else null

# Comparison viewer
var comparison_viewer: Control = null
var last_baseline_path: String = ""
var last_actual_path: String = ""

# Event editor (post-recording)
var pending_baseline_path: String = ""
var pending_baseline_region: Dictionary = {}  # For legacy tests with baseline_region
var pending_test_name: String = ""
var editing_original_filename: String = ""  # When editing existing test, tracks original filename for rename/overwrite
var pending_screenshots: Array[Dictionary] = []  # Screenshots for editing (independent of recording engine)

func _ready():
	# Check for auto-run mode first (allows running outside editor)
	# User args (after --) are in get_cmdline_user_args(), engine args in get_cmdline_args()
	var user_args = OS.get_cmdline_user_args()
	_auto_run_mode = "--test-all" in user_args
	_exit_on_complete = "--exit-on-complete" in user_args

	# Don't initialize in exported/release builds - unless in auto-run mode
	if not OS.has_feature("editor") and not _auto_run_mode:
		queue_free()
		return

	main_viewport = get_viewport()
	layer = 200  # Above board loading overlay (layer 100) and other UI
	process_mode = Node.PROCESS_MODE_ALWAYS  # Work even when paused
	_setup_virtual_cursor()
	_setup_playback_engine()
	_setup_recording_engine()
	_setup_region_selector()
	_setup_test_executor()
	_setup_comparison_viewer()
	_setup_test_manager()
	_setup_focus_tracking()
	_setup_result_indicator()
	ScreenshotValidator.load_config()
	# Apply loaded playback speed
	_playback.set_speed(ScreenshotValidator.playback_speed as Speed)
	# Load test run history from file
	_load_run_history()

	# Start auto-run if enabled (flags set at top of _ready)
	if _auto_run_mode:
		print("[%s] Auto-run mode enabled" % Utils.PLUGIN_NAME)
		call_deferred("_auto_run_tests")
	else:
		print("[%s] Initialized - F12: Test Manager" % Utils.PLUGIN_NAME)

# Auto-run all tests when launched with --test-all flag
func _auto_run_tests() -> void:
	# Wait for scene tree to fully initialize
	await get_tree().process_frame
	await get_tree().process_frame

	# Mark test session as active (for environment setup signal)
	_test_session_active = true

	# Get all tests (use same logic as _run_all_tests but skip UI interactions)
	var saved_tests = _get_saved_tests()
	if saved_tests.is_empty():
		print("[UITestRunner] No tests found in res://tests/ui-tests/")
		if _exit_on_complete:
			get_tree().quit(1)
		return

	# Build ordered test list by category (copied from _run_all_tests)
	var tests: Array = []
	var categories = CategoryManager.get_all_categories()
	for category_name in categories:
		var tests_in_category: Array = []
		for test_name in CategoryManager.test_categories.keys():
			if CategoryManager.test_categories[test_name] == category_name:
				if test_name in saved_tests:
					tests_in_category.append(test_name)
		tests_in_category = _get_ordered_tests(category_name, tests_in_category)
		tests.append_array(tests_in_category)
	for test_name in saved_tests:
		if test_name not in tests:
			tests.append(test_name)

	print("[UITestRunner] === AUTO-RUNNING ALL TESTS (%d tests) ===" % tests.size())
	await _run_batch_tests(tests)

	# Print summary
	var passed = batch_results.filter(func(r): return r.get("passed", false)).size()
	var failed = batch_results.size() - passed
	print("[UITestRunner] === RESULTS: %d passed, %d failed ===" % [passed, failed])

	# Exit with code OR stay in app for review
	if _exit_on_complete:
		var exit_code = 0 if failed == 0 else 1
		print("[UITestRunner] Exiting with code %d" % exit_code)
		get_tree().quit(exit_code)
	else:
		# Stay in app - show Test Manager with results
		print("[UITestRunner] Tests complete - opening Test Manager for review")
		_show_results_panel()

# Track focus changes to preserve text input focus when HUD buttons are clicked
func _setup_focus_tracking():
	main_viewport.gui_focus_changed.connect(_on_gui_focus_changed)

func _on_gui_focus_changed(control: Control):
	# Track last text input that had focus
	if control is TextEdit or control is LineEdit:
		_last_text_focus = control

# Save current text focus state (called from _input before GUI processes click)
func _save_text_focus_state():
	var current_focus = get_viewport().gui_get_focus_owner()
	if current_focus is LineEdit:
		_last_text_focus = current_focus
		_last_text_was_editable = current_focus.editable
		_last_caret_column = current_focus.caret_column
		if current_focus.has_selection():
			_last_selection_start = 0
			_last_selection_end = current_focus.text.length()
		else:
			_last_selection_start = _last_caret_column
			_last_selection_end = _last_caret_column

# Setup pass/fail result indicator (large check/X shown during test runs)
func _setup_result_indicator():
	# Load FluentUI icons (pre-colored SVGs)
	_pass_icon_texture = load("res://addons/godot-ui-automation/icons/checkmark_pass.svg")
	_fail_icon_texture = load("res://addons/godot-ui-automation/icons/dismiss_fail.svg")

	_result_indicator = TextureRect.new()
	_result_indicator.name = "ResultIndicator"
	_result_indicator.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_result_indicator.visible = false
	_result_indicator.z_index = 150  # Above most UI but below test manager
	_result_indicator.expand_mode = 1  # EXPAND_IGNORE_SIZE
	_result_indicator.stretch_mode = 5  # STRETCH_KEEP_ASPECT_CENTERED
	_result_indicator.custom_minimum_size = Vector2(120, 120)
	add_child(_result_indicator)
	# Connect to test ended signal to show indicator
	ui_test_runner_test_ended.connect(_on_test_result_indicator)

var _result_indicator_passed: bool = true  # Current indicator state

func _on_test_result_indicator(test_name: String, passed: bool):
	_show_result_indicator(passed)

func _show_result_indicator(passed: bool):
	if not _result_indicator:
		return

	_result_indicator_passed = passed
	# Set the appropriate icon texture
	_result_indicator.texture = _pass_icon_texture if passed else _fail_icon_texture

	# Position at bottom right with margin
	var viewport_size = get_viewport().get_visible_rect().size
	var indicator_size = 120.0
	var margin = 40.0
	_result_indicator.position = Vector2(
		viewport_size.x - margin - indicator_size,
		viewport_size.y - margin - indicator_size
	)

	_result_indicator.visible = true
	_result_indicator.modulate = Color(1, 1, 1, 0)  # Start invisible

	# Kill existing tween if any
	if _result_indicator_tween and _result_indicator_tween.is_valid():
		_result_indicator_tween.kill()

	# Create tween: fade in, hold, fade out
	_result_indicator_tween = create_tween()
	_result_indicator_tween.tween_property(_result_indicator, "modulate:a", 0.5, 0.15)  # Fade to 50%
	_result_indicator_tween.tween_interval(0.4)  # Hold
	_result_indicator_tween.tween_property(_result_indicator, "modulate:a", 0.0, 0.25)  # Fade out
	_result_indicator_tween.tween_callback(_hide_result_indicator)

func _hide_result_indicator():
	if _result_indicator:
		_result_indicator.visible = false

func _setup_playback_engine():
	_playback = PlaybackEngine.new()
	_playback.initialize(get_tree(), main_viewport, virtual_cursor)
	_playback.action_performed.connect(_on_playback_action_performed)

func _on_playback_action_performed(action: String, details: Dictionary):
	action_performed.emit(action, details)

func _setup_recording_engine():
	_recording = RecordingEngine.new()
	_recording.initialize(get_tree(), self)
	_recording.recording_started.connect(_on_recording_started)
	_recording.recording_stopped.connect(_on_recording_stopped)
	_recording.recording_cancelled.connect(_on_recording_cancelled)
	_recording.screenshot_capture_requested.connect(_on_screenshot_capture_requested)
	_recording.replay_requested.connect(_on_recording_replay_requested)

func _setup_region_selector():
	_region_selector = RegionSelector.new()
	_region_selector.initialize(get_tree(), self)
	_region_selector.selection_completed.connect(_on_region_selection_completed)
	_region_selector.selection_cancelled.connect(_on_region_selection_cancelled)

func _setup_test_executor():
	_executor = TestExecutor.new()
	_executor.initialize(get_tree(), _playback, virtual_cursor, self)
	_executor.test_started.connect(_on_executor_test_started)
	_executor.test_completed.connect(_on_executor_test_completed)
	_executor.test_result_ready.connect(_on_executor_test_result)
	_executor.step_changed.connect(_on_executor_step_changed)
	_executor.paused_changed.connect(_on_executor_paused_changed)
	_setup_test_editor_hud()

func _set_test_mode(active: bool, set_recording_meta: bool = false) -> void:
	test_mode_active = active
	if set_recording_meta:
		get_tree().set_meta("automation_is_recording", active)
	test_mode_changed.emit(active)

func _on_executor_test_started(test_name: String):
	var is_restart = (current_test_name == test_name)
	var coming_from_recording = _sync_collapse_from_recording
	current_test_name = test_name
	_set_test_mode(true)
	test_started.emit(test_name)
	# Only show debug HUD when in step/debug mode
	if _executor and _executor.step_mode:
		# Copy events for the steps panel
		_test_editor_hud_current_events.clear()
		# Clear existing step rows so they get rebuilt with new events
		if _test_editor_hud_steps_list:
			for child in _test_editor_hud_steps_list.get_children():
				child.queue_free()
		_test_editor_hud_step_rows.clear()
		# Reset test state when coming from recording (new or re-record)
		if coming_from_recording:
			_auto_play_steps.clear()
			_failed_step_index = -1
			_passed_step_indices.clear()
			_step_mode_test_passed = false
			_set_test_editor_hud_border_color(Color(1.0, 1.0, 1.0, 1.0))  # White/neutral
			# Emit signal to trigger board cleanup (same as Reset Test button)
			ui_test_runner_test_starting.emit(test_name, _get_test_setup_config(test_name))
		elif not is_restart:
			# Also reset on new test (not from recording, not restart)
			_auto_play_steps.clear()
		for event in _executor._current_events:
			_test_editor_hud_current_events.append(event.duplicate())
		_show_test_editor_hud(coming_from_recording)
		_sync_collapse_from_recording = false  # Clear flag after use

		# Apply pending failed step highlight (from "Step X" button)
		if _pending_failed_step_highlight >= 0:
			_apply_failed_step_highlight.call_deferred(_pending_failed_step_highlight)
			_pending_failed_step_highlight = -1

func _on_executor_test_completed(test_name: String, passed: bool):
	# In step mode: keep HUD visible, don't clean up
	# - On failure: red highlight on failed step
	# - On success: nothing happens (HUD stays, user can restart or ESC)
	if _executor and _executor.step_mode:
		# Show HUD if it was hidden during playback (test finished)
		if _test_editor_hud_hidden_during_playback and _test_editor_hud:
			_test_editor_hud.visible = true
		test_completed.emit(test_name, passed)
		return

	_set_test_mode(false)
	test_completed.emit(test_name, passed)
	current_test_name = ""
	_debug_here_mode = false  # Reset debug mode
	_failed_step_index = -1  # Clear failed step
	_test_editor_hud_current_events.clear()
	_test_editor_hud_step_rows.clear()
	_hide_test_editor_hud()
	# Reset step mode for next test
	_executor.set_step_mode(false)

func _on_executor_step_changed(step_index: int, total_steps: int, event: Dictionary):
	# Mark previous step as passed (if moving forward)
	if step_index > 0:
		var prev_step = step_index - 1
		if not _passed_step_indices.has(prev_step):
			_passed_step_indices.append(prev_step)
	_update_test_editor_hud(step_index, total_steps, event)
	_highlight_test_editor_hud_step(step_index)

func _on_executor_paused_changed(paused: bool):
	_update_test_editor_hud_pause_state(paused)
	# Show/hide mouse cursor based on pause state
	if paused:
		Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
		# Move cursor to step button for easy re-clicking (unless skip flag is set)
		if _skip_cursor_move_on_pause:
			_skip_cursor_move_on_pause = false
			if virtual_cursor:
				virtual_cursor.visible = false
		else:
			_move_cursor_to_step_button()
		# Set white border when paused (unless test already completed with pass/fail)
		if not _step_mode_test_passed and _failed_step_index < 0:
			_set_test_editor_hud_border_color(Color(1.0, 1.0, 1.0, 1.0))  # White
	else:
		Input.set_mouse_mode(Input.MOUSE_MODE_HIDDEN)
		# Show virtual cursor when playback continues
		if virtual_cursor:
			virtual_cursor.visible = true
		# Set blue border when running
		_set_test_editor_hud_border_color(Color(0.3, 0.6, 0.95, 1.0))  # Blue

func _move_cursor_to_step_button():
	if not _test_editor_hud_step_btn or not _test_editor_hud_step_btn.is_visible_in_tree():
		return
	# Get center of step button in screen coordinates
	var btn_rect = _test_editor_hud_step_btn.get_global_rect()
	var btn_center = btn_rect.get_center()
	# Warp the real mouse cursor to the button
	get_viewport().warp_mouse(btn_center)
	# Hide virtual cursor when paused - only real mouse needed for clicking buttons
	if virtual_cursor:
		virtual_cursor.visible = false

func _on_executor_test_result(result: Dictionary):
	# In step mode: never navigate to results panel
	if _executor and _executor.step_mode:
		var passed = result.get("passed", true)
		if passed:
			# Test passed - show checkmark, green border, green step label, disable Play/Step
			_step_mode_test_passed = true
			_set_test_editor_hud_border_color(Color(0.4, 0.9, 0.4, 1.0))  # Green
			# Mark ALL steps as passed - use max of events and rows to ensure all get marked
			var total_steps = max(_test_editor_hud_current_events.size(), _test_editor_hud_step_rows.size())
			_passed_step_indices.clear()
			for i in range(total_steps):
				_passed_step_indices.append(i)
			# Use timer to ensure UI updates complete before marking all passed
			# This fixes screenshot_validation steps not turning green when they're the last step
			get_tree().create_timer(0.05).timeout.connect(_mark_all_steps_passed)
			# Green step label
			if _test_editor_hud_step_label:
				_test_editor_hud_step_label.add_theme_color_override("font_color", Color(0.4, 0.9, 0.4))
			# Disable Play and Step buttons - test completed, need Reset to continue
			_disable_step_controls()
			# Move cursor to play button
			_move_cursor_to_play_button()
		else:
			# On failure - red border, red X, red step label, highlight the failed step
			_set_test_editor_hud_border_color(Color(0.95, 0.3, 0.3, 1.0))  # Red
			# Red step label
			if _test_editor_hud_step_label:
				_test_editor_hud_step_label.add_theme_color_override("font_color", Color(0.95, 0.3, 0.3))
			var failed_step = result.get("failed_step", -1)
			if failed_step > 0:
				# failed_step is 1-based, convert to 0-based index
				_failed_step_index = failed_step - 1
				var baseline = result.get("baseline_path", "")
				var actual = result.get("actual_path", "")
				_highlight_failed_step(_failed_step_index, baseline, actual)
			# Disable Play and Step buttons - test completed, need Reset to continue
			_disable_step_controls()
			# Move cursor to play button
			_move_cursor_to_play_button()
		return

	# Store result and show panel (unless in batch mode)
	if not is_batch_running:
		batch_results.clear()
		batch_results.append(result)
		# Create a single-test run and add to history
		_start_test_run()
		_end_test_run(batch_results)
		_show_results_panel()

func _setup_comparison_viewer():
	_comparison_viewer = ComparisonViewer.new()
	_comparison_viewer.initialize(get_tree(), self)
	_comparison_viewer.closed.connect(_on_comparison_viewer_closed)

func _on_comparison_viewer_closed():
	# In step mode, stay in the playback HUD (don't open test manager)
	if _executor and _executor.step_mode and _test_editor_hud and _test_editor_hud.visible:
		return
	# Otherwise return to test manager results tab
	_open_test_selector()
	var tabs = test_selector_panel.get_node_or_null("VBoxContainer/TabContainer")
	if tabs:
		tabs.current_tab = 1  # Results tab

func _cancel_and_discard_test():
	# Delete any screenshots captured during this recording session
	for screenshot in pending_screenshots:
		var path = screenshot.get("path", "")
		if not path.is_empty():
			_safe_delete_file(path, "screenshot")

	# Also delete the pending baseline if it exists
	if not pending_baseline_path.is_empty():
		_safe_delete_file(pending_baseline_path, "baseline")

	# Clear all pending state
	pending_screenshots.clear()
	pending_baseline_path = ""
	pending_baseline_region = {}
	pending_test_name = ""
	recorded_events.clear()
	if _recording:
		_recording.recorded_events.clear()
		_recording.recorded_screenshots.clear()

	print("[UITestRunner] Test recording cancelled and discarded")

	# Emit run completed so app can restore state (exit fullscreen, return to original board)
	ui_test_runner_run_completed.emit()

	# Return to Test Manager
	_open_test_selector()

func _setup_test_manager():
	_test_manager = TestManager.new()
	_test_manager.initialize(get_tree(), self)
	_test_manager.test_run_requested.connect(_on_manager_test_run)
	_test_manager.test_debug_requested.connect(_on_manager_test_debug)
	_test_manager.test_delete_requested.connect(_on_delete_test)
	_test_manager.test_rename_requested.connect(_on_inline_rename_test)
	_test_manager.test_edit_requested.connect(_on_edit_test)
	_test_manager.test_update_baseline_requested.connect(_on_update_baseline)
	_test_manager.record_new_requested.connect(_on_record_new_test)
	_test_manager.run_all_requested.connect(_run_all_tests)
	_test_manager.run_tests_requested.connect(_run_specific_tests)
	_test_manager.category_play_requested.connect(_on_play_category)
	_test_manager.results_clear_requested.connect(_clear_results_history)
	_test_manager.view_failed_step_requested.connect(_on_view_failed_step)
	_test_manager.view_diff_requested.connect(_view_failed_test_diff)
	_test_manager.speed_changed.connect(_on_speed_selected)
	_test_manager.test_rerun_requested.connect(_on_rerun_test_from_results)
	_test_manager.test_debug_from_results_requested.connect(_on_debug_test_from_results)
	_test_manager.run_rerun_all_requested.connect(_on_rerun_all_from_run)
	_test_manager.run_delete_requested.connect(_delete_test_run)
	_test_manager.closed.connect(_on_test_manager_closed)

func _on_manager_test_run(test_name: String):
	_run_test_from_file(test_name)

func _on_manager_test_debug(test_name: String):
	# Run test in step mode, skip countdown (go directly to Test Editor)
	_executor.set_step_mode(true)
	_run_test_from_file(test_name, true)

func _on_test_manager_closed():
	print("[UITestRunner] Test Manager closed (session_active=%s)" % _test_session_active)
	is_selector_open = false
	# End test session when panel closes (restore window state)
	if _test_session_active:
		print("[UITestRunner] Ending test session, emitting session_ended")
		_test_session_active = false
		ui_test_runner_session_ended.emit()

func _on_rerun_test_from_results(test_name: String, result_index: int):
	if is_running:
		print("[UITestRunner] Cannot rerun - test already running")
		return
	_close_test_selector(true)
	# Show warning overlay BEFORE environment setup to prevent window resize during warning
	if await _show_startup_warning_and_wait():
		return
	_warn_missing_handlers()
	ui_test_runner_setup_environment.emit()
	await get_tree().create_timer(0.5).timeout
	ui_test_runner_test_starting.emit(test_name, _get_test_setup_config(test_name))
	await get_tree().create_timer(0.3).timeout
	var result = await _run_test_and_get_result(test_name)
	# Create a single-test run for history
	_start_test_run()
	_end_test_run([result])
	# Emit test ended and run completed (session continues until panel closes)
	ui_test_runner_test_ended.emit(test_name, result.get("passed", false))
	ui_test_runner_run_completed.emit()
	_open_test_selector()
	_test_manager.switch_to_results_tab()
	_update_results_tab()

func _on_rerun_all_from_run(test_names: Array):
	# Rerun all tests from a previous test run
	if is_running or is_batch_running:
		print("[UITestRunner] Cannot rerun - test already running")
		return
	if test_names.is_empty():
		print("[UITestRunner] No tests to rerun")
		return

	_close_test_selector(true)
	print("[UITestRunner] === RERUNNING %d TESTS ===" % test_names.size())
	await _run_batch_tests(test_names)

func _on_debug_test_from_results(test_name: String):
	# Debug/step through a test from Results tab
	# Uses same code path as Tests tab to ensure consistent behavior
	if is_running:
		print("[UITestRunner] Cannot debug - test already running")
		return
	_reset_step_highlights()  # Clear highlights from previous runs
	_close_test_selector(true)
	pending_test_name = ""  # Clear stale value so _show_test_editor_hud loads from _current_running_test_name
	_executor.set_step_mode(true)
	_debug_from_results = true  # Track that we came from Results tab (affects which tab to return to)
	_run_test_from_file(test_name, true)

func _on_region_selection_completed(rect: Rect2):
	# Handle during-recording screenshot capture
	if is_capturing_during_recording:
		_finish_screenshot_capture_during_recording()
	else:
		# Normal selection - capture and generate test code
		_on_normal_selection_completed()

func _on_region_selection_cancelled():
	# Handle during-recording cancel
	if is_capturing_during_recording:
		is_capturing_during_recording = false
		print("[UITestRunner] Screenshot capture cancelled")
		_restore_recording_after_capture()
	else:
		print("[UITestRunner] Selection cancelled")
		_generate_test_code(null)

func _on_normal_selection_completed():
	if selection_rect.size.x < 10 or selection_rect.size.y < 10:
		print("[UITestRunner] Selection too small, cancelled")
		_generate_test_code(null)
		return
	# Capture screenshot of region (async)
	_capture_and_generate()

func _on_recording_started():
	_set_test_mode(true, true)
	ui_test_runner_recording_started.emit()
	if rerecording_test_name != "":
		print("[UITestRunner] === RE-RECORDING '%s' === (F11 to stop)" % rerecording_test_name)
	else:
		print("[UITestRunner] === RECORDING STARTED === (F11 to stop)")

func _on_recording_stopped(event_count: int, screenshot_count: int):
	_set_test_mode(false, true)
	_sync_collapse_from_recording = true  # Sync collapse state when test editor HUD shows
	print("[UITestRunner] === RECORDING STOPPED === (%d events, %d screenshots)" % [event_count, screenshot_count])

	# Check if any screenshot_validation events were captured during recording
	var has_screenshot_events = _has_screenshot_validation_events()

	# If screenshots were captured during recording, skip the final region selection
	if has_screenshot_events:
		# Generate test name and show editor (pass null for baseline since screenshots exist)
		_generate_test_code(null)
	else:
		_start_region_selection()

func _on_recording_cancelled():
	_set_test_mode(false, true)
	print("[UITestRunner] === RECORDING CANCELLED ===")
	# Show Test Manager when recording is cancelled
	_test_manager.open()
	is_selector_open = true
	test_selector_panel = _test_manager.get_panel()

func _on_recording_replay_requested(events: Array):
	# Replay recorded steps, then continue recording
	print("[UITestRunner] === REPLAY REQUESTED === (%d events)" % events.size())

	# Hide recording indicator during replay to avoid recording replayed events
	_recording.set_indicator_visible(false)

	# Use executor to play events (without saving/loading test)
	_executor.play_events_for_replay(events)

	# Listen for replay completion
	if not _executor.test_completed.is_connected(_on_replay_completed):
		_executor.test_completed.connect(_on_replay_completed, CONNECT_ONE_SHOT)

func _on_replay_completed(_passed: bool, _failed_step: int):
	# Replay finished, continue recording
	print("[UITestRunner] === REPLAY COMPLETED ===")

	# Show recording indicator again
	_recording.set_indicator_visible(true)

	# Notify recording engine that replay is done
	_recording.on_replay_completed()

# Check if recorded_events contains any screenshot_validation events
func _has_screenshot_validation_events() -> bool:
	for event in _recording.recorded_events:
		if event.get("type", "") == "screenshot_validation":
			return true
	return false

func _on_screenshot_capture_requested():
	_capture_screenshot_during_recording()

func _setup_virtual_cursor():
	var cursor_scene = load("res://addons/godot-ui-automation/ui/virtual-cursor.tscn")
	if cursor_scene:
		virtual_cursor = cursor_scene.instantiate()
		add_child(virtual_cursor)
	else:
		push_warning("[UITestRunner] Could not load virtual cursor scene")
		_create_fallback_cursor()

func _create_fallback_cursor():
	virtual_cursor = Node2D.new()
	virtual_cursor.name = "VirtualCursor"
	virtual_cursor.z_index = 4096

	var sprite = Sprite2D.new()
	sprite.name = "Sprite2D"
	# Create a simple circle texture
	var img = Image.create(32, 32, false, Image.FORMAT_RGBA8)
	img.fill(Color(1, 0.4, 0.2, 0.9))
	sprite.texture = ImageTexture.create_from_image(img)
	virtual_cursor.add_child(sprite)

	add_child(virtual_cursor)

func _input(event):
	# Save LineEdit caret state on ANY mouse down, BEFORE GUI processes it
	# This captures caret position before focus_exited resets it
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		_save_text_focus_state()

	# ESC to cancel test startup during warning overlay countdown
	if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		if _test_warning_active:
			print("[UITestRunner] Test startup cancelled by ESC")
			_test_warning_cancelled = true
			get_viewport().set_input_as_handled()
			return

	# F12 to toggle Test Manager (high priority - handle before other nodes consume it)
	if event is InputEventKey and event.pressed and event.keycode == KEY_F12:
		# If Test Editor HUD is open, flash the close button instead
		if _test_editor_hud and _test_editor_hud.visible:
			_flash_test_editor_hud_close_button()
			get_viewport().set_input_as_handled()
			return
		_toggle_test_selector()
		get_viewport().set_input_as_handled()
		return

	# Forward mouse events to test manager for drag handling (needs _input, not _unhandled_input)
	if _test_manager and _test_manager.is_open:
		if event is InputEventMouseMotion or event is InputEventMouseButton:
			if _test_manager.handle_input(event):
				get_viewport().set_input_as_handled()
				return

	# Capture ALL input events while recording (before controls handle them)
	if is_recording and _recording:
		if event is InputEventMouseButton:
			# Skip recording clicks on HUD buttons (they're UI controls, not test actions)
			# Board checks _is_click_on_automation_ui() separately to avoid deselection
			# Don't mark as handled - let GUI (ScrollContainer etc) receive the event
			if not _recording.is_click_on_hud(event.global_position):
				_recording.capture_event(event)
		elif event is InputEventKey and event.pressed:
			if _recording.capture_key_event(event):
				_mark_key_recorded(event.keycode, event.ctrl_pressed, event.shift_pressed)

# Track keys for fallback detection (keys consumed before _input)
var _last_key_state: Dictionary = {}

func _process(_delta):
	# Fallback mouse UP detection for recording - catches events missed by _input()
	if is_recording and _recording:
		_recording.check_missed_mouse_up(get_viewport())

	# Fallback key detection for recording - catches keys consumed by other handlers
	if is_recording:
		_check_fallback_keys()

# Common keys to monitor for fallback detection (keys often consumed by apps)
# Note: ESC is excluded - it's used to stop/cancel recording, not recorded as an action
const FALLBACK_KEYS = [KEY_Z, KEY_Y, KEY_X, KEY_C, KEY_V, KEY_A, KEY_S, KEY_DELETE, KEY_BACKSPACE, KEY_ENTER]

func _check_fallback_keys():
	if not _recording:
		return

	var ctrl = Input.is_key_pressed(KEY_CTRL)
	var shift = Input.is_key_pressed(KEY_SHIFT)

	for keycode in FALLBACK_KEYS:
		var is_pressed = Input.is_key_pressed(keycode)
		var was_pressed = _last_key_state.get(keycode, false)

		# Detect new key press
		if is_pressed and not was_pressed:
			# Skip if typing in recording UI (note fields, etc.)
			if _recording._is_typing_in_hud():
				_last_key_state[keycode] = is_pressed
				continue
			# Check if we already recorded this key via _input
			var already_recorded = _was_key_recently_recorded(keycode, ctrl, shift)
			if not already_recorded:
				print("[REC-FALLBACK] Detected key: %s ctrl=%s shift=%s" % [OS.get_keycode_string(keycode), ctrl, shift])
				var time_offset = (Time.get_ticks_msec() - _recording.record_start_time) if _recording.record_start_time > 0 else 0
				_recording.recorded_events.append({
					"type": "key",
					"keycode": keycode,
					"shift": shift,
					"ctrl": ctrl,
					"time": time_offset
				})
				var mods = ""
				if ctrl:
					mods += "Ctrl+"
				if shift:
					mods += "Shift+"
				print("[REC] Key: ", mods, OS.get_keycode_string(keycode))

		_last_key_state[keycode] = is_pressed

var _recent_recorded_keys: Array = []  # [{keycode, ctrl, shift, time}]

func _was_key_recently_recorded(keycode: int, ctrl: bool, shift: bool) -> bool:
	var now = Time.get_ticks_msec()
	# Clean old entries (older than 100ms)
	_recent_recorded_keys = _recent_recorded_keys.filter(func(k): return now - k.time < 100)
	# Check if this key combo was recorded recently
	for k in _recent_recorded_keys:
		if k.keycode == keycode and k.ctrl == ctrl and k.shift == shift:
			return true
	return false

func _mark_key_recorded(keycode: int, ctrl: bool, shift: bool):
	_recent_recorded_keys.append({"keycode": keycode, "ctrl": ctrl, "shift": shift, "time": Time.get_ticks_msec()})

# Returns true if a debug key (P, Space, R) was handled
func _handle_debug_keys(event: InputEventKey) -> bool:
	# Only handle when paused or HUD visible after completion
	var can_handle = false
	if _executor and _executor.is_paused:
		can_handle = true
	elif _test_editor_hud and _test_editor_hud.visible and not is_running:
		can_handle = true

	if not can_handle:
		return false

	if event.keycode == KEY_P:
		if _executor and _executor.is_paused:
			_on_test_editor_hud_play()
		return true
	elif event.keycode == KEY_SPACE:
		if _executor and _executor.is_paused:
			_executor.step_forward()
		return true
	elif event.keycode == KEY_R:
		_on_test_editor_hud_restart()
		return true

	return false

# Returns true if ESC was handled
# gdlint:ignore-function:high-complexity=17
func _handle_escape_key() -> bool:
	# ESC during step debugger → abort and return to Tests tab
	if is_running and _executor and _executor.step_mode:
		print("[UITestRunner] ESC pressed in step debugger - returning to Tests tab")
		_abort_test_to_tests_tab()
		return true

	# ESC when playback HUD visible but test not running (completed in debug mode)
	if _test_editor_hud and _test_editor_hud.visible and not is_running:
		print("[UITestRunner] ESC pressed with debug HUD visible - closing and returning to Tests tab")
		_close_debug_hud_to_tests_tab()
		return true

	# ESC during normal test execution → cancel test and batch
	if is_running or is_batch_running:
		print("[UITestRunner] ESC pressed - cancelling test run")
		_executor.cancel_test()
		_batch_cancelled = true
		return true

	# ESC during region selection → cancel just the selection
	if is_selecting_region:
		_region_selector.cancel_selection()
		return true

	# ESC during recording → cancel recording
	if is_recording:
		_cancel_recording()
		return true

	# ESC to close comparison viewer
	if _comparison_viewer and _comparison_viewer.is_visible():
		_close_comparison_viewer()
		return true

	# ESC to close rename dialog
	if rename_dialog and rename_dialog.visible:
		_close_rename_dialog()
		return true

	# ESC to close test selector
	if is_selector_open:
		_close_test_selector()
		return true

	return false

# Handles F10/F11 recording keys
func _handle_recording_keys(event: InputEventKey) -> void:
	if event.keycode == KEY_F10 and is_recording:
		_capture_screenshot_during_recording()
	elif event.keycode == KEY_F11 and is_recording:
		_recording.stop_recording()

func _unhandled_input(event):
	# Forward mouse events to test manager for drag handling
	if _test_manager and _test_manager.is_open:
		if _test_manager.handle_input(event):
			get_viewport().set_input_as_handled()
			return

	if event is InputEventKey and event.pressed:
		if _handle_debug_keys(event):
			return
		if event.keycode == KEY_ESCAPE:
			if _handle_escape_key():
				return
		_handle_recording_keys(event)

func _start_demo_test():
	print("[UITestRunner] F9 pressed, is_running=", is_running)
	if not is_running:
		# Use call_deferred to run on next frame, avoiding input handler conflicts
		call_deferred("_run_demo_deferred")
	else:
		print("[UITestRunner] Test already running, ignoring")

func _run_demo_deferred():
	run_demo_test()

# ============================================================================
# PLAYBACK ENGINE DELEGATES - Forward to UIPlaybackEngine
# ============================================================================

# Property accessors for playback engine state
var is_running: bool:
	get: return _playback.is_running if _playback else false
	set(value): if _playback: _playback.is_running = value

var current_speed: Speed:
	get: return _playback.current_speed if _playback else Speed.NORMAL
	set(value): if _playback: _playback.current_speed = value

var action_log: Array[Dictionary]:
	get: return _playback.action_log if _playback else []

# Speed control
func set_speed(speed: Speed) -> void:
	_playback.set_speed(speed)
	ScreenshotValidator.playback_speed = speed as int
	ScreenshotValidator.save_config()

func cycle_speed() -> void:
	_playback.cycle_speed()
	ScreenshotValidator.playback_speed = _playback.current_speed as int
	ScreenshotValidator.save_config()

func get_delay_multiplier() -> float:
	return _playback.get_delay_multiplier()

# Coordinate conversion - uses board's global coordinate system for recording/playback
func world_to_screen(world_pos: Vector2) -> Vector2:
	var board = _find_active_board()
	if board and board.has_method("world_to_global_screen"):
		var result = board.world_to_global_screen(world_pos)
		var zoom = board.zoom_level if "zoom_level" in board else 1.0
		var offset = board.camera_offset if "camera_offset" in board else Vector2.ZERO
		print("[UITestRunner] world_to_screen: world=%s -> screen=%s" % [world_pos, result])
		print("  board: global_pos=%s, size=%s, zoom=%.2f, offset=%s" % [board.global_position, board.size, zoom, offset])
		return result
	print("[UITestRunner] world_to_screen: NO BOARD FOUND! Using playback fallback")
	return _playback.world_to_screen(world_pos)

func screen_to_world(screen_pos: Vector2) -> Vector2:
	var board = _find_active_board()
	if board and board.has_method("global_screen_to_world"):
		var result = board.global_screen_to_world(screen_pos)
		var zoom = board.zoom_level if "zoom_level" in board else 1.0
		var offset = board.camera_offset if "camera_offset" in board else Vector2.ZERO
		print("[UITestRunner] screen_to_world: screen=%s -> world=%s" % [screen_pos, result])
		print("  board: global_pos=%s, size=%s, zoom=%.2f, offset=%s" % [board.global_position, board.size, zoom, offset])
		return result
	print("[UITestRunner] screen_to_world: NO BOARD FOUND! Using playback fallback")
	return _playback.screen_to_world(screen_pos)

# Cell coordinate helpers - uses board's grid size (default 20x20)
const DEFAULT_GRID_SIZE := Vector2(20, 20)

func get_grid_size() -> Vector2:
	var board = _find_active_board()
	if board and "grid_size" in board:
		return board.grid_size
	return DEFAULT_GRID_SIZE

func world_to_cell(world_pos: Vector2) -> Vector2i:
	# Convert world position to cell coordinates (grid-snapped)
	var grid = get_grid_size()
	return Vector2i(
		roundi(world_pos.x / grid.x),
		roundi(world_pos.y / grid.y)
	)

func cell_to_world(cell: Vector2i) -> Vector2:
	# Convert cell coordinates to world position (top-left of cell)
	var grid = get_grid_size()
	return Vector2(cell.x * grid.x, cell.y * grid.y)

func cell_to_screen(cell: Vector2i) -> Vector2:
	# Convert cell coordinates to global screen position
	return world_to_screen(cell_to_world(cell))

func get_screen_pos(node: CanvasItem) -> Vector2:
	return _playback.get_screen_pos(node)

# Mouse actions
func move_to(pos: Vector2, duration: float = 0.3) -> void:
	await _playback.move_to(pos, duration)

func click() -> void:
	await _playback.click()

func click_at(pos: Vector2) -> void:
	await _playback.click_at(pos)

func drag_to(to: Vector2, duration: float = 0.5, hold_at_end: float = 0.0) -> void:
	await _playback.drag_to(to, duration, hold_at_end)

func drag(from: Vector2, to: Vector2, duration: float = 0.5, hold_at_end: float = 0.0) -> void:
	await _playback.drag(from, to, duration, hold_at_end)

func drag_node(node: CanvasItem, offset: Vector2, duration: float = 0.5) -> void:
	await _playback.drag_node(node, offset, duration)

func click_node(node: CanvasItem) -> void:
	await _playback.click_node(node)

func right_click() -> void:
	await _playback.right_click()

func double_click() -> void:
	await _playback.double_click()

# Keyboard actions
func press_key(keycode: int, shift: bool = false, ctrl: bool = false) -> void:
	await _playback.press_key(keycode, shift, ctrl)

func type_text(text: String, delay_per_char: float = 0.05) -> void:
	await _playback.type_text(text, delay_per_char)

# Wait
func wait(seconds: float, apply_speed_multiplier: bool = true) -> void:
	await _playback.wait(seconds, apply_speed_multiplier)

# ============================================================================
# OBJECT DETECTION - For robust recording/playback
# ============================================================================

# Finds the active board in the scene tree
func _find_active_board() -> Node:
	# Look for a Board node - check common locations
	var root = get_tree().root
	# Try Main/ContentContainer/Board pattern (Kilanote structure)
	var main = root.get_node_or_null("Main")
	if main:
		var content = main.get_node_or_null("ContentContainer")
		if content:
			for child in content.get_children():
				if child.has_method("find_item_at_screen_pos"):
					return child
	# Fallback: search all children recursively for any node with the method
	return _find_node_with_method(root, "find_item_at_screen_pos")

func _find_node_with_method(node: Node, method_name: String) -> Node:
	# Exclude self to prevent infinite recursion (UITestRunner also has find_item_at_screen_pos)
	if node.has_method(method_name) and node != self:
		return node
	for child in node.get_children():
		var found = _find_node_with_method(child, method_name)
		if found:
			return found
	return null

# Finds an item at the given screen position
# Returns: {type: String, id: String, screen_pos: Vector2, size: Vector2} or empty dict
func find_item_at_screen_pos(screen_pos: Vector2) -> Dictionary:
	var board = _find_active_board()
	if board:
		return board.find_item_at_screen_pos(screen_pos)
	return {}
	
# Finds an item by type and ID and returns its current screen position
# Returns Vector2.ZERO if not found
func get_item_screen_pos_by_id(item_type: String, item_id: String) -> Vector2:
	var board = _find_active_board()
	if board and board.has_method("get_item_screen_pos_by_id"):
		return board.get_item_screen_pos_by_id(item_type, item_id)
	return Vector2.ZERO

# ============================================================================
# TEST STRUCTURE
# ============================================================================

func begin_test(test_name: String) -> void:
	current_test_name = test_name
	_playback.is_running = true
	_set_test_mode(true)
	_playback.clear_action_log()
	virtual_cursor.visible = true
	virtual_cursor.show_cursor()
	test_started.emit(test_name)
	print("[UITestRunner] === BEGIN: ", test_name, " ===")
	# Ensure cursor is visible before proceeding
	await get_tree().process_frame

func end_test(passed: bool = true) -> void:
	var result = "PASSED" if passed else "FAILED"
	print("[UITestRunner] === END: ", current_test_name, " - ", result, " ===")
	virtual_cursor.hide_cursor()
	_playback.is_running = false
	_set_test_mode(false)
	test_completed.emit(current_test_name, passed)
	current_test_name = ""

# ============================================================================
# DEMO TEST - Pure coordinate-based demonstration
# ============================================================================

func run_demo_test() -> void:
	if is_running:
		print("[UITestRunner] Test already running")
		return

	await begin_test("Drag Demo")

	var viewport_size = get_viewport().get_visible_rect().size
	var center = viewport_size / 2
	print("[UITestRunner] Viewport: ", viewport_size, " Center: ", center)

	# Pure drag test - no click first, just grab and drag
	# This simulates: move to position, mouse down, drag, mouse up
	print("[UITestRunner] Dragging from center 200px right, 100px down...")
	await drag(center, center + Vector2(200, 100), 1.0)

	await wait(0.5)

	# Drag it back
	print("[UITestRunner] Dragging back to original position...")
	await drag(center + Vector2(200, 100), center, 1.0)

	await wait(0.3)
	end_test(true)
	print("[UITestRunner] Demo complete")

# ============================================================================
# RECORDING - Delegates to RecordingEngine
# ============================================================================

func _toggle_recording():
	if is_recording:
		_recording.stop_recording()
	else:
		_recording.start_recording()

func _cancel_recording():
	# Cancel recording without saving - discard everything and return to Tests tab
	if not is_recording:
		return

	print("[UITestRunner] === RECORDING CANCELLED === (ESC pressed)")

	# Stop the recording engine
	_recording.cancel_recording()

	# Clear any pending data
	recorded_events.clear()
	pending_screenshots.clear()
	rerecording_test_name = ""

	# Reset test mode state
	_set_test_mode(false, true)

	# Emit signal so app can restore state
	ui_test_runner_run_completed.emit()

	# Open the Tests tab
	call_deferred("_open_test_selector_to_tests_tab")

func _open_test_selector_to_tests_tab():
	_test_manager.open()
	# Actually switch to Tests tab (tab 0)
	var panel = _test_manager.get_panel()
	if panel:
		var tabs = panel.get_node_or_null("VBoxContainer/TabContainer")
		if tabs:
			tabs.current_tab = 0  # Tests tab

func _open_test_selector_to_results_tab():
	_open_test_selector()
	_test_manager.switch_to_results_tab()
	_update_results_tab()

# Abort test and return to appropriate tab (Tests or Results depending on where we came from)
func _abort_test_to_tests_tab():
	if not is_running or not _executor:
		return

	# Cancel the executor and stop playback immediately
	_executor._cancelled = true
	_executor._playback.is_cancelled = true
	is_running = false  # Force stop so _open_test_selector doesn't block
	if _executor.is_paused:
		_executor.is_paused = false

	# Clean up test mode state immediately (before test_completed would fire)
	_set_test_mode(false)
	current_test_name = ""
	_test_editor_hud_current_events.clear()
	_test_editor_hud_step_rows.clear()
	_hide_test_editor_hud()
	_executor.set_step_mode(false)

	# Restore mouse visibility
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
	if virtual_cursor:
		virtual_cursor.visible = false
		virtual_cursor.hide_cursor()

	# Emit signal so app can restore state
	ui_test_runner_run_completed.emit()

	# Open the appropriate tab based on where we started
	if _debug_from_results:
		_debug_from_results = false
		call_deferred("_open_test_selector_to_results_tab")
	else:
		call_deferred("_open_test_selector_to_tests_tab")

# Close debug HUD and return to appropriate tab (Tests or Results depending on where we came from)
func _close_debug_hud_to_tests_tab():
	# Clean up test mode state
	_set_test_mode(false)
	current_test_name = ""
	_debug_here_mode = false
	_failed_step_index = -1
	_step_mode_test_passed = false
	if _test_editor_hud_step_label:
		_test_editor_hud_step_label.add_theme_color_override("font_color", Color(0.7, 0.7, 0.75))
	_test_editor_hud_current_events.clear()
	_test_editor_hud_step_rows.clear()
	_hide_test_editor_hud()
	if _executor:
		_executor.set_step_mode(false)

	# Restore mouse visibility
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
	if virtual_cursor:
		virtual_cursor.visible = false
		virtual_cursor.hide_cursor()

	# Emit signal so app can restore state
	ui_test_runner_run_completed.emit()

	# Open the appropriate tab based on where we started
	if _debug_from_results:
		_debug_from_results = false
		call_deferred("_open_test_selector_to_results_tab")
	else:
		call_deferred("_open_test_selector_to_tests_tab")

func _capture_screenshot_during_recording():
	if not is_recording or not _recording:
		return

	# Temporarily pause to allow region selection without capturing events
	var was_paused = is_recording_paused
	is_recording_paused = true

	# Hide recording indicator temporarily for clean screenshot
	_recording.set_indicator_visible(false)

	# Start region selection for this screenshot
	_start_screenshot_capture_region(was_paused)

func _start_screenshot_capture_region(was_paused: bool):
	# Set business logic flags before starting selection
	is_capturing_during_recording = true
	was_paused_before_capture = was_paused
	# Delegate to region selector
	_region_selector.start_selection()

func _finish_screenshot_capture_during_recording():
	# Region selector already hid overlay and unpaused, just reset flags
	is_capturing_during_recording = false

	if selection_rect.size.x < 10 or selection_rect.size.y < 10:
		print("[UITestRunner] Selection too small, cancelled")
		_restore_recording_after_capture()
		return

	# Capture the screenshot asynchronously
	_capture_and_store_screenshot()

func _capture_and_store_screenshot():
	# Wait for overlay to disappear
	await get_tree().process_frame
	await get_tree().process_frame

	var image = get_viewport().get_texture().get_image()
	var cropped = image.get_region(selection_rect)

	# Generate unique filename for this screenshot
	var timestamp = Time.get_datetime_string_from_system().replace(":", "-").replace(" ", "_")
	var screenshot_index = recorded_screenshots.size()
	var filename = "screenshot_%s_%d.png" % [timestamp, screenshot_index]
	var dir_path = "res://tests/baselines"
	var full_path = "%s/%s" % [dir_path, filename]

	# Ensure directory exists
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir_path))

	# Save image
	cropped.save_png(ProjectSettings.globalize_path(full_path))
	print("[UITestRunner] Screenshot %d saved: %s" % [screenshot_index, full_path])

	# Store screenshot info via recording engine
	_recording.add_screenshot_record(full_path, {
		"x": selection_rect.position.x,
		"y": selection_rect.position.y,
		"w": selection_rect.size.x,
		"h": selection_rect.size.y
	})

	_restore_recording_after_capture()

func _restore_recording_after_capture():
	# Restore recording indicator
	if _recording:
		_recording.set_indicator_visible(true)

	# Restore pause state
	is_recording_paused = was_paused_before_capture

	print("[UITestRunner] === Recording resumed ===")

func _is_click_on_recording_hud(pos: Vector2) -> bool:
	if not _recording:
		return false
	return _recording.is_click_on_hud(pos)

# ============================================================================
# TEST FILE MANAGEMENT
# ============================================================================

func _save_test(test_name: String, baseline_path: Variant) -> String:
	print("[UITestRunner] Saving test with %d recorded events" % recorded_events.size())

	# Convert events to JSON-serializable format (Vector2 -> dict)
	var serializable_events = _serialize_events(recorded_events)

	# If baseline_path provided (from post-recording capture), add as screenshot_validation event
	if baseline_path:
		var screenshot_event = {
			"type": "screenshot_validation",
			"path": baseline_path,
			"region": {
				"x": selection_rect.position.x,
				"y": selection_rect.position.y,
				"w": selection_rect.size.x,
				"h": selection_rect.size.y
			},
			"time": 0,  # Time doesn't matter for final step
			"wait_after": 100
		}
		serializable_events.append(screenshot_event)
		print("[UITestRunner] Added final screenshot as event step: %s" % baseline_path)

	# Store viewport size for coordinate scaling during playback
	var viewport_size = get_viewport().get_visible_rect().size

	# Store window state for restoration during playback
	var window_mode = DisplayServer.window_get_mode()
	var window_pos = DisplayServer.window_get_position()
	var window_size = DisplayServer.window_get_size()

	# Capture environment info for mismatch detection
	var screen_idx = DisplayServer.window_get_current_screen()
	var screen_size = DisplayServer.screen_get_size(screen_idx)

	# Build setup section based on current window state
	var setup_config = {}
	if window_mode == DisplayServer.WINDOW_MODE_MAXIMIZED:
		setup_config["maximize_window"] = true

	# Build test data with support for multiple screenshots
	var test_data = {
		"name": test_name,
		"created": Time.get_datetime_string_from_system(),
		"recorded_environment": {
			"monitor_index": screen_idx,
			"monitor_resolution": {"w": screen_size.x, "h": screen_size.y},
			"viewport": {"w": viewport_size.x, "h": viewport_size.y},
			"window_mode": window_mode
		},
		"setup": setup_config,
		"recorded_viewport": {"w": viewport_size.x, "h": viewport_size.y},
		"recorded_window": {
			"mode": window_mode,
			"x": window_pos.x,
			"y": window_pos.y,
			"w": window_size.x,
			"h": window_size.y
		},
		"events": serializable_events,
		# Legacy baseline fields cleared - now stored as event step above
		"baseline_path": "",
		"baseline_region": null,
		# Multiple screenshots captured during recording
		"screenshots": pending_screenshots.duplicate()
	}

	var filename = test_name.to_snake_case().replace(" ", "_") + ".json"
	return FileIO.save_test_data(filename, test_data)

# Converts recorded events to JSON-serializable format
func _serialize_events(events: Array) -> Array:
	var serializable_events = []
	for event in events:
		var event_type = event.get("type", "")
		var ser_event = {"type": event_type, "time": event.get("time", 0)}
		match event_type:
			"click", "double_click":
				var pos = event.get("pos", Vector2.ZERO)
				ser_event["pos"] = {"x": pos.x, "y": pos.y}
				if event.get("ctrl", false):
					ser_event["ctrl"] = true
				if event.get("shift", false):
					ser_event["shift"] = true
			"drag":
				var from_pos = event.get("from", Vector2.ZERO)
				var to_pos = event.get("to", Vector2.ZERO)
				ser_event["from"] = {"x": from_pos.x, "y": from_pos.y}
				ser_event["to"] = {"x": to_pos.x, "y": to_pos.y}
				# Modifier keys
				if event.get("ctrl", false):
					ser_event["ctrl"] = true
				if event.get("shift", false):
					ser_event["shift"] = true
				# no_drop flag for drag segments (T key during recording)
				if event.get("no_drop", false):
					ser_event["no_drop"] = true
				# World coordinates for precise resolution-independent playback
				var to_world = event.get("to_world", null)
				if to_world != null and to_world is Vector2:
					ser_event["to_world"] = {"x": to_world.x, "y": to_world.y}
				# Cell coordinates for grid-snapped playback (fallback)
				var to_cell = event.get("to_cell", null)
				if to_cell != null and to_cell is Vector2i:
					ser_event["to_cell"] = {"x": to_cell.x, "y": to_cell.y}
				# Object-relative info for robust playback
				var object_type = event.get("object_type", "")
				if not object_type.is_empty():
					ser_event["object_type"] = object_type
					ser_event["object_id"] = event.get("object_id", "")
					var click_offset = event.get("click_offset", Vector2.ZERO)
					ser_event["click_offset"] = {"x": click_offset.x, "y": click_offset.y}
			"pan":
				var from_pos = event.get("from", Vector2.ZERO)
				var to_pos = event.get("to", Vector2.ZERO)
				ser_event["from"] = {"x": from_pos.x, "y": from_pos.y}
				ser_event["to"] = {"x": to_pos.x, "y": to_pos.y}
			"right_click":
				var pos = event.get("pos", Vector2.ZERO)
				ser_event["pos"] = {"x": pos.x, "y": pos.y}
			"scroll":
				ser_event["direction"] = event.get("direction", "in")
				ser_event["ctrl"] = event.get("ctrl", false)
				ser_event["shift"] = event.get("shift", false)
				ser_event["alt"] = event.get("alt", false)
				ser_event["factor"] = event.get("factor", 1.0)
				var pos = event.get("pos", Vector2.ZERO)
				ser_event["pos"] = {"x": pos.x, "y": pos.y}
			"key":
				ser_event["keycode"] = event.get("keycode", 0)
				ser_event["shift"] = event.get("shift", false)
				ser_event["ctrl"] = event.get("ctrl", false)
				var key_mouse_pos = event.get("mouse_pos", null)
				if key_mouse_pos != null and key_mouse_pos is Vector2:
					ser_event["mouse_pos"] = {"x": key_mouse_pos.x, "y": key_mouse_pos.y}
			"wait":
				ser_event["duration"] = event.get("duration", 1000)
			"set_clipboard_image":
				ser_event["path"] = event.get("path", "")
				var mouse_pos = event.get("mouse_pos", Vector2.ZERO)
				ser_event["mouse_pos"] = {"x": mouse_pos.x, "y": mouse_pos.y}
			"screenshot_validation":
				ser_event["path"] = event.get("path", "")
				ser_event["region"] = event.get("region", {})
		# Add wait_after and note for all events
		ser_event["wait_after"] = event.get("wait_after", 100)
		var note = event.get("note", "")
		if not note.is_empty():
			ser_event["note"] = note
		serializable_events.append(ser_event)
	return serializable_events

func _load_test(filepath: String) -> Dictionary:
	return FileIO.load_test(filepath)

func _get_saved_tests() -> Array:
	return FileIO.get_saved_tests()

# Category management delegated to CategoryManager
func _load_categories():
	CategoryManager.load_categories()

func _save_categories():
	CategoryManager.save_categories()

func _get_all_categories() -> Array:
	return CategoryManager.get_all_categories()

func _set_test_category(test_name: String, category: String, insert_index: int = -1):
	CategoryManager.set_test_category(test_name, category, insert_index)

func _get_ordered_tests(category_name: String, tests: Array) -> Array:
	return CategoryManager.get_ordered_tests(category_name, tests)

func _run_test_from_file(test_name: String, skip_setup_delays: bool = false):
	# Clear stale comparison paths from previous test runs
	last_baseline_path = ""
	last_actual_path = ""

	# Clear step tracking for fresh test run
	_passed_step_indices.clear()
	_failed_step_index = -1

	# Store for restart functionality
	_current_running_test_name = test_name

	print("[UITestRunner] _run_test_from_file: debug_here=%s, skip_delays=%s" % [_debug_here_mode, skip_setup_delays])
	if _debug_here_mode:
		# Debug Here mode: skip environment setup, run on current board
		print("[UITestRunner] Debug Here mode - running on current board")
		await get_tree().process_frame
	elif skip_setup_delays:
		# Restart mode: environment already set up, just wait one frame
		print("[UITestRunner] Restart mode - skipping setup delays")
		await get_tree().process_frame
	else:
		# Normal mode or Test Editor initial play: show warning BEFORE environment setup
		print("[UITestRunner] Normal mode - showing warning overlay")
		if await _show_startup_warning_and_wait():
			return
		_warn_missing_handlers()
		ui_test_runner_setup_environment.emit()
		await get_tree().create_timer(0.5).timeout

		# Emit test starting signal so app can cleanup before test
		ui_test_runner_test_starting.emit(test_name, _get_test_setup_config(test_name))
		await get_tree().create_timer(0.3).timeout

	# Run test and wait for result
	var was_step_mode = _executor.step_mode
	var result = await _executor.run_test_and_get_result(test_name)

	# In step mode: show checkmark/failure indicator, don't store result or show panel
	# HUD stays visible for user to ESC out or restart
	if was_step_mode:
		var passed = result.get("passed", true)
		if passed:
			_step_mode_test_passed = true
			_set_test_editor_hud_border_color(Color(0.4, 0.9, 0.4, 1.0))  # Green border
			# Mark ALL steps as passed - populate indices array for consistency
			var total_steps = max(_test_editor_hud_current_events.size(), _test_editor_hud_step_rows.size())
			_passed_step_indices.clear()
			for i in range(total_steps):
				_passed_step_indices.append(i)
			# Use timer to ensure UI updates complete before marking all passed
			# This fixes screenshot_validation steps not turning green when they're the last step
			get_tree().create_timer(0.05).timeout.connect(_mark_all_steps_passed)
			# Green step label
			if _test_editor_hud_step_label:
				_test_editor_hud_step_label.add_theme_color_override("font_color", Color(0.4, 0.9, 0.4))
			# Disable Play and Step buttons - test completed, need Reset to continue
			_disable_step_controls()
		else:
			# On failure - red border, red X, red step label
			_set_test_editor_hud_border_color(Color(0.95, 0.3, 0.3, 1.0))  # Red
			# Red step label
			if _test_editor_hud_step_label:
				_test_editor_hud_step_label.add_theme_color_override("font_color", Color(0.95, 0.3, 0.3))
			var failed_step = result.get("failed_step", -1)
			if failed_step > 0:
				_failed_step_index = failed_step - 1
				var baseline = result.get("baseline_path", "")
				var actual = result.get("actual_path", "")
				_highlight_failed_step(_failed_step_index, baseline, actual)
			# Disable Play and Step buttons - test completed, need Reset to continue
			_disable_step_controls()
		return

	# Store result for display
	batch_results.clear()
	batch_results.append(result)

	# Add to run history
	_start_test_run()
	_end_test_run(batch_results)

	# Emit test ended signal
	ui_test_runner_test_ended.emit(test_name, result.get("passed", false))

	# Emit run completed signal (single test counts as a run)
	ui_test_runner_run_completed.emit()

	# Show results panel
	_show_results_panel()

# ============================================================================
# TEST SELECTOR PANEL
# ============================================================================

func _toggle_test_selector():
	# Sync data before opening
	_test_manager.batch_results = batch_results
	_test_manager.test_run_history = test_run_history
	_test_manager.toggle()
	is_selector_open = _test_manager.is_open
	# Keep test_selector_panel in sync for backward compatibility
	test_selector_panel = _test_manager.get_panel()

func _open_test_selector():
	if is_running:
		print("[UITestRunner] Cannot open selector - test running")
		return

	# Ensure all overlays are hidden before showing Test Manager
	_region_selector.hide_overlay()
	if _comparison_viewer and _comparison_viewer.is_visible():
		_comparison_viewer.close()
	if _recording:
		_recording.set_indicator_visible(false)

	_test_manager.batch_results = batch_results
	_test_manager.test_run_history = test_run_history
	_test_manager.open()
	is_selector_open = true
	# Keep test_selector_panel in sync for backward compatibility
	test_selector_panel = _test_manager.get_panel()

func _close_test_selector(for_test_run: bool = false):
	# If closing to start a test run, clear session flag first to prevent window restore
	if for_test_run:
		_test_session_active = false
	_test_manager.close()
	is_selector_open = false


func _clear_results_history():
	# Delete all actual screenshots before clearing history
	for run in test_run_history:
		_delete_actual_screenshots_for_run(run)
	test_run_history.clear()
	batch_results.clear()
	_save_run_history()
	_update_results_tab()

# Deletes a specific test run and its actual screenshots
func _delete_test_run(run_id: String) -> void:
	# Find the run in history
	var run_index = -1
	for i in range(test_run_history.size()):
		if test_run_history[i].get("id", "") == run_id:
			run_index = i
			break

	if run_index == -1:
		print("[UITestRunner] Run not found: %s" % run_id)
		return

	# Delete actual screenshots for this run
	_delete_actual_screenshots_for_run(test_run_history[run_index])

	# Remove from history
	test_run_history.remove_at(run_index)
	_save_run_history()
	_update_results_tab()
	print("[UITestRunner] Deleted test run: %s" % run_id)

# Deletes all _actual.png screenshots associated with a test run
func _delete_actual_screenshots_for_run(run: Dictionary) -> void:
	var results = run.get("results", [])
	for result in results:
		var actual_path = result.get("actual_path", "")
		if actual_path.is_empty():
			continue

		# Delete the actual screenshot file
		var global_path = ProjectSettings.globalize_path(actual_path)
		if FileAccess.file_exists(actual_path):
			var err = DirAccess.remove_absolute(global_path)
			if err == OK:
				print("[UITestRunner] Deleted: %s" % actual_path)
			else:
				print("[UITestRunner] Failed to delete: %s (error %d)" % [actual_path, err])

		# Also delete the .import file if it exists
		var import_path = actual_path + ".import"
		if FileAccess.file_exists(import_path):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(import_path))

# Creates a new test run and returns its ID
func _start_test_run() -> String:
	var timestamp = Time.get_unix_time_from_system()
	var datetime_dict = Time.get_datetime_dict_from_system()
	var datetime_str = "%04d-%02d-%02d %02d:%02d:%02d" % [
		datetime_dict.year, datetime_dict.month, datetime_dict.day,
		datetime_dict.hour, datetime_dict.minute, datetime_dict.second
	]
	_current_run_id = "%d" % timestamp
	return _current_run_id

# Finalizes the current run and adds it to history
func _end_test_run(results: Array) -> void:
	if _current_run_id.is_empty():
		return

	var timestamp = Time.get_unix_time_from_system()
	var datetime_dict = Time.get_datetime_dict_from_system()
	var datetime_str = "%04d-%02d-%02d %02d:%02d:%02d" % [
		datetime_dict.year, datetime_dict.month, datetime_dict.day,
		datetime_dict.hour, datetime_dict.minute, datetime_dict.second
	]

	var run_data: Dictionary = {
		"id": _current_run_id,
		"timestamp": timestamp,
		"datetime": datetime_str,
		"results": results.duplicate(true)
	}

	# Insert at beginning (newest first)
	test_run_history.insert(0, run_data)

	# Set this run as the expanded one (collapse others)
	if _test_manager:
		_test_manager.set_expanded_run(run_data.id)

	# FIFO auto-cleanup if enabled, otherwise use default max
	var max_runs = MAX_RUN_HISTORY
	if ScreenshotValidator.auto_cleanup_enabled:
		max_runs = ScreenshotValidator.max_run_history

	# Trim to max history size, deleting screenshots from removed runs
	while test_run_history.size() > max_runs:
		var old_run = test_run_history.pop_back()
		_delete_actual_screenshots_for_run(old_run)
		print("[UITestRunner] Auto-cleanup: removed run %s" % old_run.get("id", "unknown"))

	_current_run_id = ""
	_save_run_history()

# Saves test run history to JSON file
func _save_run_history() -> void:
	print("[UITestRunner] Saving run history (%d runs) to: %s" % [test_run_history.size(), RUN_HISTORY_FILE])
	var file = FileAccess.open(RUN_HISTORY_FILE, FileAccess.WRITE)
	if not file:
		print("[UITestRunner] ERROR: Failed to open file for writing: %s" % FileAccess.get_open_error())
		return
	var json_str = JSON.stringify(test_run_history, "  ")
	file.store_string(json_str)
	file.close()
	print("[UITestRunner] Run history saved successfully (%d bytes)" % json_str.length())

# Loads test run history from JSON file
func _load_run_history() -> void:
	print("[UITestRunner] Loading run history from: %s" % RUN_HISTORY_FILE)
	if not FileAccess.file_exists(RUN_HISTORY_FILE):
		print("[UITestRunner] No history file found, starting fresh")
		return
	var file = FileAccess.open(RUN_HISTORY_FILE, FileAccess.READ)
	if not file:
		print("[UITestRunner] ERROR: Failed to open file for reading: %s" % FileAccess.get_open_error())
		return
	var json_str = file.get_as_text()
	file.close()
	print("[UITestRunner] Read %d bytes from history file" % json_str.length())
	var json = JSON.new()
	var error = json.parse(json_str)
	if error != OK:
		print("[UITestRunner] ERROR: Failed to parse JSON: %s at line %d" % [json.get_error_message(), json.get_error_line()])
		return
	var data = json.get_data()
	print("[UITestRunner] Parsed JSON data type: %s" % typeof(data))
	if data is Array:
		test_run_history.clear()
		for run in data:
			if run is Dictionary:
				test_run_history.append(run)
		print("[UITestRunner] Loaded %d test runs from history" % test_run_history.size())
	else:
		print("[UITestRunner] ERROR: Expected Array but got %s" % typeof(data))

func _on_record_new_test():
	# Clear editing tracker - this is a new test, not an edit
	editing_original_filename = ""

	_close_test_selector(true)
	# Small delay to let panel close
	await get_tree().create_timer(0.1).timeout

	# Emit setup signal so app can configure environment (window size, navigate to test board)
	_test_session_active = true
	_warn_missing_handlers()
	ui_test_runner_setup_environment.emit()
	# Wait for environment setup to complete (window resize, board navigation)
	await get_tree().create_timer(0.5).timeout

	# Emit test starting signal so app can cleanup before recording
	# Empty setup config since this is a new recording (no prior test data)
	ui_test_runner_test_starting.emit("Recording", {})
	# Wait for cleanup to complete (clear board, reset zoom, board fully loaded)
	await get_tree().create_timer(0.5).timeout

	_recording.start_recording()

func _refresh_test_list():
	_test_manager.refresh_test_list()

func _on_play_category(category_name: String):
	# Get all tests in this category (only those that exist on disk)
	var saved_tests = _get_saved_tests()
	var tests_in_category: Array = []
	for test_name in CategoryManager.test_categories.keys():
		if CategoryManager.test_categories[test_name] == category_name:
			# Validate test file exists
			if test_name in saved_tests:
				tests_in_category.append(test_name)
			else:
				print("[UITestRunner] Skipping missing test: ", test_name)

	if tests_in_category.is_empty():
		print("[UITestRunner] No tests in category: ", category_name)
		return

	# Apply saved order
	tests_in_category = _get_ordered_tests(category_name, tests_in_category)

	_close_test_selector(true)
	print("[UITestRunner] === RUNNING CATEGORY: %s (%d tests) ===" % [category_name, tests_in_category.size()])
	await _run_batch_tests(tests_in_category)

# ============================================================================
# TEST MANAGEMENT
# ============================================================================

var rename_dialog: Control = null
var rename_target_test: String = ""

func _on_inline_rename_test(old_name: String, new_display_name: String) -> void:
	"""Handle inline rename from test manager - directly renames without dialog"""
	print("[UITestRunner] Inline rename: old_name='%s', new_display_name='%s'" % [old_name, new_display_name])
	var display_name = new_display_name.strip_edges()
	var new_filename = _sanitize_filename(display_name)
	print("[UITestRunner] Sanitized: display_name='%s', new_filename='%s'" % [display_name, new_filename])

	if new_filename.is_empty() or new_filename == old_name:
		print("[UITestRunner] No change needed, refreshing list")
		_refresh_test_list()  # Revert display
		return

	# Perform the actual rename
	print("[UITestRunner] Performing rename: '%s' -> '%s'" % [old_name, new_filename])
	_perform_rename(old_name, display_name, new_filename)
	_refresh_test_list()

func _perform_rename(old_test_name: String, display_name: String, new_filename: String) -> void:
	"""Core rename logic used by both inline rename and dialog rename"""
	# Load old test
	var old_filepath = TESTS_DIR + "/" + old_test_name + ".json"
	print("[UITestRunner] Loading test from: %s" % old_filepath)
	var test_data = _load_test(old_filepath)
	if test_data.is_empty():
		print("[UITestRunner] ERROR: Failed to load test data!")
		return
	print("[UITestRunner] Loaded test with %d events, name='%s'" % [test_data.get("events", []).size(), test_data.get("name", "")])

	# Update test name in data (preserve display name, not sanitized)
	test_data.name = display_name

	# Rename baseline file if exists (use sanitized filename)
	if test_data.has("baseline_path") and test_data.baseline_path:
		var old_baseline = test_data.baseline_path
		var new_baseline = old_baseline.get_base_dir() + "/baseline_" + new_filename + ".png"

		var old_global = ProjectSettings.globalize_path(old_baseline)
		var new_global = ProjectSettings.globalize_path(new_baseline)

		if FileAccess.file_exists(old_global):
			DirAccess.rename_absolute(old_global, new_global)
			test_data.baseline_path = new_baseline
			print("[UITestRunner] Renamed baseline to: ", new_baseline)

	# Save with new filename (sanitized)
	var new_filepath = TESTS_DIR + "/" + new_filename + ".json"
	var file = FileAccess.open(new_filepath, FileAccess.WRITE)
	if file:
		file.store_string(JSON.stringify(test_data, "\t"))
		file.close()

	# Delete old test file (only if filename changed)
	if new_filename != old_test_name:
		_safe_delete_file(old_filepath)

	# Preserve category assignment (use filename for category keys)
	var old_category = CategoryManager.test_categories.get(old_test_name, "")
	if old_category:
		CategoryManager.test_categories.erase(old_test_name)
		CategoryManager.test_categories[new_filename] = old_category

		# Update order within category
		if CategoryManager.category_test_order.has(old_category):
			var order = CategoryManager.category_test_order[old_category]
			var idx = order.find(old_test_name)
			if idx >= 0:
				order[idx] = new_filename

		_save_categories()

	print("[UITestRunner] Renamed test: ", old_test_name, " -> ", new_filename, " (display: ", display_name, ")")

func _on_delete_test(test_name: String):
	# Load test data to get baseline path
	var filepath = TESTS_DIR + "/" + test_name + ".json"
	var test_data = _load_test(filepath)

	# Delete baseline if exists
	if test_data.has("baseline_path") and test_data.baseline_path:
		var baseline_global = ProjectSettings.globalize_path(test_data.baseline_path)
		_delete_file_and_import(baseline_global)
		print("[UITestRunner] Deleted baseline: ", test_data.baseline_path)

		# Delete all actual screenshots (may have multiple with different run IDs)
		_delete_actual_screenshots(test_data.baseline_path)

	# Delete test file
	_safe_delete_file(filepath, "test")

	_refresh_test_list()

func _delete_file_and_import(file_path: String):
	FileIO.delete_file_and_import(file_path)

func _safe_delete_file(path: String, debug_label: String = "") -> bool:
	var global_path = ProjectSettings.globalize_path(path)
	if FileAccess.file_exists(global_path):
		DirAccess.remove_absolute(global_path)
		if not debug_label.is_empty():
			print("[UITestRunner] Deleted %s: %s" % [debug_label, path])
		return true
	return false

# Deletes all actual screenshots for a baseline (handles both old and new naming patterns)
func _delete_actual_screenshots(baseline_path: String):
	var base_name = baseline_path.get_basename()  # e.g., "res://tests/baselines/screenshot_xxx"
	var dir_path = baseline_path.get_base_dir()
	var dir_global = ProjectSettings.globalize_path(dir_path)
	var dir = DirAccess.open(dir_global)
	if not dir:
		return

	var file_prefix = baseline_path.get_file().get_basename()  # e.g., "screenshot_xxx"
	dir.list_dir_begin()
	var file_name = dir.get_next()
	while file_name != "":
		# Match both old pattern (_actual.png) and new pattern (_run{id}_actual.png)
		if file_name.begins_with(file_prefix) and file_name.ends_with("_actual.png"):
			var full_path = dir_global + "/" + file_name
			_delete_file_and_import(full_path)
			print("[UITestRunner] Deleted actual: ", file_name)
		file_name = dir.get_next()
	dir.list_dir_end()

func _on_rename_test(test_name: String):
	rename_target_test = test_name
	# Load test data to get the actual display name (preserves casing)
	var filepath = TESTS_DIR + "/" + test_name + ".json"
	var test_data = _load_test(filepath)
	var display_name = _get_display_name(test_data, test_name)
	_show_rename_dialog(display_name)

# Returns a friendly display name from test data, with smart fallback for old sanitized names
func _get_display_name(test_data: Dictionary, fallback_filename: String) -> String:
	return Utils.get_display_name(test_data, fallback_filename)

func _show_rename_dialog(display_name: String):
	if not rename_dialog:
		_create_rename_dialog()

	# Hide test selector so it doesn't block the rename dialog
	if test_selector_panel:
		test_selector_panel.visible = false

	var input = rename_dialog.get_node("VBox/Input")
	input.text = display_name
	input.select_all()
	rename_dialog.visible = true
	rename_dialog.move_to_front()  # Ensure dialog is on top
	input.grab_focus()

func _create_rename_dialog():
	rename_dialog = Panel.new()
	rename_dialog.name = "RenameDialog"
	rename_dialog.process_mode = Node.PROCESS_MODE_ALWAYS

	var viewport_size = get_viewport().get_visible_rect().size
	var dialog_size = Vector2(350, 150)
	rename_dialog.position = (viewport_size - dialog_size) / 2
	rename_dialog.size = dialog_size

	var style = StyleBoxFlat.new()
	style.bg_color = Color(0.15, 0.15, 0.18, 0.98)
	style.border_color = Color(0.3, 0.6, 1.0, 1.0)
	style.set_border_width_all(2)
	style.set_corner_radius_all(8)
	rename_dialog.add_theme_stylebox_override("panel", style)

	var vbox = VBoxContainer.new()
	vbox.name = "VBox"
	vbox.set_anchors_preset(Control.PRESET_FULL_RECT)
	vbox.add_theme_constant_override("separation", 15)
	var margin = 15
	vbox.offset_left = margin
	vbox.offset_top = margin
	vbox.offset_right = -margin
	vbox.offset_bottom = -margin
	rename_dialog.add_child(vbox)

	var title = Label.new()
	title.text = "Rename Test"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 18)
	vbox.add_child(title)

	var input = LineEdit.new()
	input.name = "Input"
	input.placeholder_text = "Enter new name..."
	input.text_submitted.connect(_on_rename_submitted)
	vbox.add_child(input)

	var button_row = HBoxContainer.new()
	button_row.add_theme_constant_override("separation", 10)
	vbox.add_child(button_row)

	var cancel_btn = Button.new()
	cancel_btn.text = "Cancel"
	cancel_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cancel_btn.pressed.connect(_close_rename_dialog)
	button_row.add_child(cancel_btn)

	var save_btn = Button.new()
	save_btn.text = "Rename"
	save_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	save_btn.pressed.connect(_do_rename)
	button_row.add_child(save_btn)

	add_child(rename_dialog)

func _close_rename_dialog():
	if rename_dialog:
		rename_dialog.visible = false
	rename_target_test = ""
	# Restore test selector panel
	if test_selector_panel:
		test_selector_panel.visible = true

func _on_rename_submitted(_text: String):
	_do_rename()

func _sanitize_filename(text: String) -> String:
	return Utils.sanitize_filename(text)

func _do_rename():
	if rename_target_test.is_empty():
		return

	var input = rename_dialog.get_node("VBox/Input")
	var display_name = input.text.strip_edges()
	var new_filename = _sanitize_filename(display_name)

	if new_filename.is_empty() or new_filename == rename_target_test:
		_close_rename_dialog()
		return

	# Use shared rename logic
	_perform_rename(rename_target_test, display_name, new_filename)

	_close_rename_dialog()
	_refresh_test_list()

func _on_update_baseline(test_name: String):
	# Load test data to get the original display name (not the filename)
	var test_data = FileIO.load_test(Utils.TESTS_DIR + "/" + test_name + ".json")
	var display_name = _get_display_name(test_data, test_name)
	print("[UITestRunner] Re-recording test: ", display_name)
	rerecording_test_name = display_name  # Store display name to preserve on save
	_close_test_selector(true)
	# Small delay to let panel close
	await get_tree().create_timer(0.1).timeout

	# Emit setup signal so app can configure environment (window size, navigate to test board)
	_test_session_active = true
	_warn_missing_handlers()
	ui_test_runner_setup_environment.emit()
	# Wait for environment setup to complete (window resize, board navigation)
	await get_tree().create_timer(0.5).timeout

	# Emit test starting signal so app can cleanup before recording
	ui_test_runner_test_starting.emit(test_name, _get_test_setup_config(test_name))
	# Wait for cleanup to complete (clear board, reset zoom, board fully loaded)
	await get_tree().create_timer(0.5).timeout

	_recording.start_recording()

func _on_edit_test(test_name: String):
	print("[UITestRunner] Editing test: ", test_name)
	_reset_step_highlights()  # Clear highlights from previous runs
	_close_test_selector(true)  # Close Test Manager before opening Test Editor
	var filepath = TESTS_DIR + "/" + test_name + ".json"
	var test_data = _load_test(filepath)

	if test_data.is_empty():
		print("[UITestRunner] Failed to load test")
		return

	# Load events into recorded_events, converting JSON dicts to Vector2
	recorded_events.clear()
	for event in test_data.get("events", []):
		var event_type = event.get("type", "")
		var converted_event = {"type": event_type, "time": event.get("time", 0)}

		match event_type:
			"click", "double_click":
				var pos = event.get("pos", {})
				converted_event["pos"] = Vector2(pos.get("x", 0), pos.get("y", 0))
				if event.get("ctrl", false):
					converted_event["ctrl"] = true
				if event.get("shift", false):
					converted_event["shift"] = true
			"drag":
				var from_pos = event.get("from", {})
				var to_pos = event.get("to", {})
				converted_event["from"] = Vector2(from_pos.get("x", 0), from_pos.get("y", 0))
				converted_event["to"] = Vector2(to_pos.get("x", 0), to_pos.get("y", 0))
				if event.get("ctrl", false):
					converted_event["ctrl"] = true
				if event.get("shift", false):
					converted_event["shift"] = true
				# Object-relative info for robust playback
				var object_type = event.get("object_type", "")
				if not object_type.is_empty():
					converted_event["object_type"] = object_type
					converted_event["object_id"] = event.get("object_id", "")
					var click_offset = event.get("click_offset", {})
					converted_event["click_offset"] = Vector2(click_offset.get("x", 0), click_offset.get("y", 0))
			"key":
				converted_event["keycode"] = event.get("keycode", 0)
				converted_event["shift"] = event.get("shift", false)
				converted_event["ctrl"] = event.get("ctrl", false)
			"wait":
				converted_event["duration"] = event.get("duration", 1000)
			"screenshot_validation":
				converted_event["path"] = event.get("path", "")
				converted_event["region"] = event.get("region", {})
			"set_clipboard_image":
				converted_event["path"] = event.get("path", "")

		# Load wait_after and note
		var default_wait = DEFAULT_DELAYS.get(event_type, 100)
		converted_event["wait_after"] = event.get("wait_after", default_wait)
		converted_event["note"] = event.get("note", "")

		recorded_events.append(converted_event)

	# Load baseline region for re-saving
	var baseline_region = test_data.get("baseline_region")
	if baseline_region:
		selection_rect = Rect2(
			baseline_region.get("x", 0),
			baseline_region.get("y", 0),
			baseline_region.get("w", 0),
			baseline_region.get("h", 0)
		)
		pending_baseline_region = baseline_region
	else:
		pending_baseline_region = {}

	# Load screenshots (new format) or leave empty for legacy tests
	pending_screenshots.clear()
	for screenshot in test_data.get("screenshots", []):
		pending_screenshots.append(screenshot.duplicate())
	print("[UITestRunner] Loaded %d screenshots for editing" % pending_screenshots.size())

	# Set pending data for save (use actual display name from test data)
	pending_test_name = _get_display_name(test_data, test_name)
	pending_baseline_path = test_data.get("baseline_path", "")
	editing_original_filename = test_name  # Track original for rename detection

	# Open Test Editor dialog (run test in step mode, skip countdown)
	_executor.set_step_mode(true)
	_run_test_from_file(test_name, true)

func _run_test_for_baseline_update(test_name: String):
	var filepath = TESTS_DIR + "/" + test_name + ".json"
	var test_data = _load_test(filepath)

	if test_data.is_empty():
		print("[UITestRunner] Failed to load test")
		return

	# Load events
	recorded_events.clear()
	for event in test_data.get("events", []):
		var event_type = event.get("type", "")
		var converted_event = {"type": event_type, "time": event.get("time", 0)}

		match event_type:
			"click", "double_click":
				var pos = event.get("pos", {})
				converted_event["pos"] = Vector2(pos.get("x", 0), pos.get("y", 0))
				if event.get("ctrl", false):
					converted_event["ctrl"] = true
				if event.get("shift", false):
					converted_event["shift"] = true
			"drag":
				var from_pos = event.get("from", {})
				var to_pos = event.get("to", {})
				converted_event["from"] = Vector2(from_pos.get("x", 0), from_pos.get("y", 0))
				converted_event["to"] = Vector2(to_pos.get("x", 0), to_pos.get("y", 0))
				if event.get("ctrl", false):
					converted_event["ctrl"] = true
				if event.get("shift", false):
					converted_event["shift"] = true
				# Object-relative info for robust playback
				var object_type = event.get("object_type", "")
				if not object_type.is_empty():
					converted_event["object_type"] = object_type
					converted_event["object_id"] = event.get("object_id", "")
					var click_offset = event.get("click_offset", {})
					converted_event["click_offset"] = Vector2(click_offset.get("x", 0), click_offset.get("y", 0))
			"key":
				converted_event["keycode"] = event.get("keycode", 0)
				converted_event["shift"] = event.get("shift", false)
				converted_event["ctrl"] = event.get("ctrl", false)
			"wait":
				converted_event["duration"] = event.get("duration", 1000)

		var default_wait = DEFAULT_DELAYS.get(event_type, 100)
		converted_event["wait_after"] = event.get("wait_after", default_wait)
		recorded_events.append(converted_event)

	# Run the test without validation
	await begin_test(test_data.get("name", test_name) + " (Baseline Update)")

	for event in recorded_events:
		var event_type = event.get("type", "")
		var wait_after_ms = event.get("wait_after", 100)

		match event_type:
			"click":
				var pos = event.get("pos", Vector2.ZERO)
				await click_at(pos)
			"double_click":
				var pos = event.get("pos", Vector2.ZERO)
				await move_to(pos)
				await double_click()
			"drag":
				var from_pos = event.get("from", Vector2.ZERO)
				var to_pos = event.get("to", Vector2.ZERO)
				# For drags, use wait_after as hold time (keeps mouse pressed for hover navigation)
				var hold_time = wait_after_ms / 1000.0
				await drag(from_pos, to_pos, 0.5, hold_time)
				wait_after_ms = 0  # Already applied as hold time
			"key":
				var keycode = event.get("keycode", 0)
				await press_key(keycode, event.get("shift", false), event.get("ctrl", false))
			"wait":
				var duration_ms = event.get("duration", 1000)
				await wait(duration_ms / 1000.0, false)  # Explicit waits ignore speed setting

		# Apply wait_after delay (user-configured, not affected by speed)
		if wait_after_ms > 0:
			await wait(wait_after_ms / 1000.0, false)

	await wait(0.3)
	end_test(true)

	# Now capture new baseline using the stored region
	var baseline_region = test_data.get("baseline_region")
	if baseline_region:
		selection_rect = Rect2(
			baseline_region.get("x", 0),
			baseline_region.get("y", 0),
			baseline_region.get("w", 0),
			baseline_region.get("h", 0)
		)

		# Capture new baseline
		var new_baseline = await _capture_baseline_for_update(test_data.get("baseline_path", ""))

		# Update test data with new baseline path (in case filename changed)
		test_data.baseline_path = new_baseline

		# Save updated test
		var file = FileAccess.open(filepath, FileAccess.WRITE)
		if file:
			file.store_string(JSON.stringify(test_data, "\t"))
			file.close()

		print("[UITestRunner] Baseline updated for: ", test_name)
	else:
		print("[UITestRunner] No baseline region found - cannot update")

func _capture_baseline_for_update(existing_path: String) -> String:
	# Hide UI elements
	virtual_cursor.visible = false
	if recording_indicator:
		recording_indicator.visible = false
	_region_selector.hide_overlay()

	await get_tree().process_frame
	await get_tree().process_frame
	await get_tree().process_frame

	var image = get_viewport().get_texture().get_image()
	var cropped = image.get_region(selection_rect)

	# Use existing path or generate new one
	var save_path = existing_path
	if save_path.is_empty():
		var timestamp = Time.get_datetime_string_from_system().replace(":", "-").replace(" ", "_")
		save_path = "res://tests/baselines/baseline_%s.png" % timestamp

	# Save image
	cropped.save_png(ProjectSettings.globalize_path(save_path))
	print("[UITestRunner] New baseline saved: ", save_path)

	return save_path

# ============================================================================
# BATCH TEST EXECUTION
# ============================================================================

func _run_all_tests():
	var saved_tests = _get_saved_tests()
	if saved_tests.is_empty():
		print("[UITestRunner] No tests to run")
		return

	# Build ordered test list by category (same order as category playback)
	var tests: Array = []
	var categories = CategoryManager.get_all_categories()

	# Add tests from each category in order
	for category_name in categories:
		var tests_in_category: Array = []
		for test_name in CategoryManager.test_categories.keys():
			if CategoryManager.test_categories[test_name] == category_name:
				if test_name in saved_tests:
					tests_in_category.append(test_name)
		# Apply category ordering
		tests_in_category = _get_ordered_tests(category_name, tests_in_category)
		tests.append_array(tests_in_category)

	# Add uncategorized tests at the end
	for test_name in saved_tests:
		if test_name not in tests:
			tests.append(test_name)

	_close_test_selector(true)
	print("[UITestRunner] === RUNNING ALL TESTS (%d tests) ===" % tests.size())
	await _run_batch_tests(tests)

func _run_specific_tests(tests: Array):
	"""Run a specific list of tests (used when env dialog filters out some tests)."""
	if tests.is_empty():
		print("[UITestRunner] No tests to run")
		return

	_close_test_selector(true)
	print("[UITestRunner] === RUNNING %d TESTS ===" % tests.size())
	await _run_batch_tests(tests)

func _run_test_and_get_result(test_name: String) -> Dictionary:
	# Delegate to TestExecutor
	return await _executor.run_test_and_get_result(test_name)

func _show_results_panel():
	# Open Test Manager and switch to Results tab
	_open_test_selector()
	_update_results_tab()
	# Switch to Results tab
	if _test_manager and _test_manager._panel:
		var tabs = _test_manager._panel.get_node_or_null("VBoxContainer/TabContainer")
		if tabs:
			tabs.current_tab = 1  # Results tab

# ============================================================================
# TEST EDITOR HUD
# ============================================================================

func _setup_test_editor_hud():
	_test_editor_hud = Control.new()
	_test_editor_hud.name = "TestEditorHUD"
	_test_editor_hud.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_test_editor_hud.set_anchors_preset(Control.PRESET_FULL_RECT)
	_test_editor_hud.visible = false
	_test_editor_hud.z_index = 25
	_test_editor_hud.process_mode = Node.PROCESS_MODE_ALWAYS
	add_child(_test_editor_hud)

	# Main panel - styled like Test Editor dialog
	var panel = Panel.new()
	panel.name = "HUDPanel"
	panel.mouse_filter = Control.MOUSE_FILTER_STOP
	panel.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	panel.anchor_left = 1.0
	panel.anchor_top = 1.0
	panel.anchor_right = 1.0
	panel.anchor_bottom = 1.0
	panel.offset_left = -436  # Narrower for collapsed state (+16px from original)
	panel.offset_top = -70  # Start collapsed
	panel.offset_right = -10
	panel.offset_bottom = -10
	_test_editor_hud_panel = panel  # Store reference for border color changes

	# Style: dark background with white border (neutral state)
	var panel_style = StyleBoxFlat.new()
	panel_style.bg_color = Color(0.12, 0.12, 0.15, 0.98)
	panel_style.border_color = Color(0.7, 0.7, 0.75, 1.0)  # White/neutral
	panel_style.set_border_width_all(2)
	panel_style.set_corner_radius_all(10)
	panel.add_theme_stylebox_override("panel", panel_style)
	panel.gui_input.connect(_on_test_editor_hud_panel_gui_input)
	_test_editor_hud.add_child(panel)

	# Main VBox with margins
	var margin = MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	margin.add_theme_constant_override("margin_left", 12)
	margin.add_theme_constant_override("margin_right", 12)
	margin.add_theme_constant_override("margin_top", 10)
	margin.add_theme_constant_override("margin_bottom", 10)
	panel.add_child(margin)

	var vbox = VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 8)
	vbox.mouse_filter = Control.MOUSE_FILTER_STOP
	margin.add_child(vbox)

	# === HEADER ROW === (always visible, contains controls)
	var header = HBoxContainer.new()
	header.add_theme_constant_override("separation", 8)
	vbox.add_child(header)

	# Load icons
	var icon_next_frame = load("res://addons/godot-ui-automation/icons/next-frame.svg")
	var icon_play = load("res://addons/godot-ui-automation/icons/play.svg")
	var icon_replay = load("res://addons/godot-ui-automation/icons/replay.svg")
	var icon_record = load("res://addons/godot-ui-automation/icons/record.svg")
	var icon_eye = load("res://addons/godot-ui-automation/icons/eye.svg")

	# Step button (only enabled when paused)
	_test_editor_hud_step_btn = Button.new()
	_test_editor_hud_step_btn.icon = icon_next_frame
	_test_editor_hud_step_btn.tooltip_text = "Step Forward (Space)"
	_test_editor_hud_step_btn.custom_minimum_size = Vector2(40, 40)
	_test_editor_hud_step_btn.expand_icon = true
	_test_editor_hud_step_btn.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_test_editor_hud_step_btn.focus_mode = Control.FOCUS_NONE
	_test_editor_hud_step_btn.button_down.connect(_on_hud_button_down)
	_test_editor_hud_step_btn.pressed.connect(_on_test_editor_hud_step)
	_test_editor_hud_step_btn.disabled = true
	header.add_child(_test_editor_hud_step_btn)

	# Play button (starts test running through all steps)
	_test_editor_hud_pause_continue_btn = Button.new()
	_test_editor_hud_pause_continue_btn.icon = icon_play
	_test_editor_hud_pause_continue_btn.tooltip_text = "Play to End (P)"
	_test_editor_hud_pause_continue_btn.custom_minimum_size = Vector2(40, 40)
	_test_editor_hud_pause_continue_btn.expand_icon = true
	_test_editor_hud_pause_continue_btn.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_test_editor_hud_pause_continue_btn.focus_mode = Control.FOCUS_NONE
	_test_editor_hud_pause_continue_btn.disabled = true  # Start disabled to prevent accidental clicks
	_test_editor_hud_pause_continue_btn.button_down.connect(_on_hud_button_down)
	_test_editor_hud_pause_continue_btn.pressed.connect(_on_test_editor_hud_play)
	header.add_child(_test_editor_hud_pause_continue_btn)

	# Reset button
	_test_editor_hud_restart_btn = Button.new()
	_test_editor_hud_restart_btn.icon = icon_replay
	_test_editor_hud_restart_btn.tooltip_text = "Reset Test (R)"
	_test_editor_hud_restart_btn.custom_minimum_size = Vector2(40, 40)
	_test_editor_hud_restart_btn.expand_icon = true
	_test_editor_hud_restart_btn.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_test_editor_hud_restart_btn.focus_mode = Control.FOCUS_NONE
	_test_editor_hud_restart_btn.button_down.connect(_on_hud_button_down)
	_test_editor_hud_restart_btn.pressed.connect(_on_test_editor_hud_restart)
	header.add_child(_test_editor_hud_restart_btn)

	# Re-record button
	_test_editor_hud_rerecord_btn = Button.new()
	_test_editor_hud_rerecord_btn.icon = icon_record
	_test_editor_hud_rerecord_btn.tooltip_text = "Re-record Test"
	_test_editor_hud_rerecord_btn.custom_minimum_size = Vector2(40, 40)
	_test_editor_hud_rerecord_btn.expand_icon = true
	_test_editor_hud_rerecord_btn.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_test_editor_hud_rerecord_btn.focus_mode = Control.FOCUS_NONE
	_test_editor_hud_rerecord_btn.button_down.connect(_on_hud_button_down)
	_test_editor_hud_rerecord_btn.pressed.connect(_on_test_editor_hud_rerecord)
	header.add_child(_test_editor_hud_rerecord_btn)

	# Visibility toggle button (hide HUD during playback)
	_test_editor_hud_visibility_btn = Button.new()
	_test_editor_hud_visibility_btn.icon = icon_eye
	_test_editor_hud_visibility_btn.tooltip_text = "Hide UI during playback"
	_test_editor_hud_visibility_btn.custom_minimum_size = Vector2(40, 40)
	_test_editor_hud_visibility_btn.expand_icon = true
	_test_editor_hud_visibility_btn.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_test_editor_hud_visibility_btn.focus_mode = Control.FOCUS_NONE
	_test_editor_hud_visibility_btn.toggle_mode = true
	_test_editor_hud_visibility_btn.button_down.connect(_on_hud_button_down)
	_test_editor_hud_visibility_btn.toggled.connect(_on_test_editor_hud_visibility_toggled)
	header.add_child(_test_editor_hud_visibility_btn)

	var header_spacer = Control.new()
	header_spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(header_spacer)

	# Details toggle button
	_test_editor_hud_details_btn = Button.new()
	_test_editor_hud_details_btn.text = "▶ Details"
	_test_editor_hud_details_btn.tooltip_text = "Show/hide test details"
	_test_editor_hud_details_btn.custom_minimum_size = Vector2(90, 36)
	_test_editor_hud_details_btn.focus_mode = Control.FOCUS_NONE
	_test_editor_hud_details_btn.button_down.connect(_on_hud_button_down)
	_test_editor_hud_details_btn.pressed.connect(_on_test_editor_hud_toggle_details)
	header.add_child(_test_editor_hud_details_btn)

	# Spacer before close button
	var close_spacer = Control.new()
	close_spacer.custom_minimum_size.x = 8
	header.add_child(close_spacer)

	# Close button (X)
	_test_editor_hud_close_btn = Button.new()
	_test_editor_hud_close_btn.icon = load("res://addons/godot-ui-automation/icons/dismiss_circle.svg")
	_test_editor_hud_close_btn.tooltip_text = "Close (Esc)"
	_test_editor_hud_close_btn.custom_minimum_size = Vector2(40, 40)
	_test_editor_hud_close_btn.expand_icon = true
	_test_editor_hud_close_btn.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_test_editor_hud_close_btn.focus_mode = Control.FOCUS_NONE
	_test_editor_hud_close_btn.flat = true
	_test_editor_hud_close_btn.pressed.connect(_on_test_editor_hud_close)
	header.add_child(_test_editor_hud_close_btn)

	# === BODY CONTAINER === (collapsible, hidden by default)
	_test_editor_hud_body_container = VBoxContainer.new()
	_test_editor_hud_body_container.visible = false  # Start collapsed
	_test_editor_hud_body_container.add_theme_constant_override("separation", 8)
	_test_editor_hud_body_container.mouse_filter = Control.MOUSE_FILTER_STOP
	vbox.add_child(_test_editor_hud_body_container)

	# Body separator
	var body_sep = HSeparator.new()
	body_sep.add_theme_stylebox_override("separator", _create_separator_style())
	_test_editor_hud_body_container.add_child(body_sep)

	# Title row (Test Name label + editable field)
	var title_row = HBoxContainer.new()
	title_row.add_theme_constant_override("separation", 8)
	_test_editor_hud_body_container.add_child(title_row)

	var title_label = Label.new()
	title_label.text = "Test:"
	title_label.add_theme_font_size_override("font_size", 14)
	title_label.add_theme_color_override("font_color", Color(0.7, 0.7, 0.75))
	title_row.add_child(title_label)

	_test_editor_hud_title_edit = LineEdit.new()
	_test_editor_hud_title_edit.name = "TitleEdit"
	_test_editor_hud_title_edit.text = "New Test"
	_test_editor_hud_title_edit.add_theme_font_size_override("font_size", 16)
	_test_editor_hud_title_edit.add_theme_color_override("font_color", Color(0.9, 0.9, 0.95))
	_test_editor_hud_title_edit.add_theme_color_override("caret_color", Color(0.9, 0.9, 0.95))
	_test_editor_hud_title_edit.flat = true
	_test_editor_hud_title_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_test_editor_hud_title_edit.text_submitted.connect(_on_test_name_submitted)
	_test_editor_hud_title_edit.focus_exited.connect(_on_test_name_focus_exited)
	title_row.add_child(_test_editor_hud_title_edit)

	# Environment mismatch warning (yellow banner, hidden by default)
	_test_editor_hud_env_warning = PanelContainer.new()
	_test_editor_hud_env_warning.visible = false
	var warning_style = StyleBoxFlat.new()
	warning_style.bg_color = Color(1.0, 0.8, 0.2, 0.15)  # Yellow background
	warning_style.border_color = Color(1.0, 0.7, 0.2, 1.0)  # Orange border
	warning_style.set_border_width_all(1)
	warning_style.set_corner_radius_all(4)
	warning_style.set_content_margin_all(6)
	_test_editor_hud_env_warning.add_theme_stylebox_override("panel", warning_style)
	var warning_label = Label.new()
	warning_label.name = "WarningLabel"
	warning_label.text = "⚠ Environment mismatch"
	warning_label.add_theme_font_size_override("font_size", 12)
	warning_label.add_theme_color_override("font_color", Color(1.0, 0.8, 0.3))
	warning_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_test_editor_hud_env_warning.add_child(warning_label)
	_test_editor_hud_body_container.add_child(_test_editor_hud_env_warning)

	# Step counter
	_test_editor_hud_step_label = Label.new()
	_test_editor_hud_step_label.text = "Step: 0/0"
	_test_editor_hud_step_label.add_theme_font_size_override("font_size", 14)
	_test_editor_hud_step_label.add_theme_color_override("font_color", Color(0.7, 0.7, 0.75))
	_test_editor_hud_body_container.add_child(_test_editor_hud_step_label)

	# Current event description
	_test_editor_hud_event_label = Label.new()
	_test_editor_hud_event_label.text = "Ready..."
	_test_editor_hud_event_label.add_theme_font_size_override("font_size", 13)
	_test_editor_hud_event_label.add_theme_color_override("font_color", Color(0.8, 0.8, 0.85))
	_test_editor_hud_body_container.add_child(_test_editor_hud_event_label)

	# Scrollable step list
	_test_editor_hud_steps_scroll = ScrollContainer.new()
	_test_editor_hud_steps_scroll.custom_minimum_size.y = 350
	_test_editor_hud_steps_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_test_editor_hud_steps_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_test_editor_hud_steps_scroll.mouse_filter = Control.MOUSE_FILTER_STOP
	_test_editor_hud_body_container.add_child(_test_editor_hud_steps_scroll)

	# Style wider scrollbar (2x default width ~24px)
	var vscroll = _test_editor_hud_steps_scroll.get_v_scroll_bar()
	if vscroll:
		vscroll.custom_minimum_size.x = 24
		# Style the grabber
		var grabber_style = StyleBoxFlat.new()
		grabber_style.bg_color = Color(0.5, 0.5, 0.55, 0.8)
		grabber_style.set_corner_radius_all(4)
		vscroll.add_theme_stylebox_override("grabber", grabber_style)
		vscroll.add_theme_stylebox_override("grabber_highlight", grabber_style)
		vscroll.add_theme_stylebox_override("grabber_pressed", grabber_style)
		# Style the scroll track
		var scroll_style = StyleBoxFlat.new()
		scroll_style.bg_color = Color(0.2, 0.2, 0.25, 0.5)
		scroll_style.set_corner_radius_all(4)
		vscroll.add_theme_stylebox_override("scroll", scroll_style)

	# Margin container to add space between steps and scroll bar (right margin accounts for 24px scrollbar)
	var steps_margin = MarginContainer.new()
	steps_margin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	steps_margin.add_theme_constant_override("margin_right", 28)
	_test_editor_hud_steps_scroll.add_child(steps_margin)

	_test_editor_hud_steps_list = VBoxContainer.new()
	_test_editor_hud_steps_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_test_editor_hud_steps_list.add_theme_constant_override("separation", 4)
	steps_margin.add_child(_test_editor_hud_steps_list)

func _show_test_editor_hud(sync_collapse_from_recording: bool = false):
	if _test_editor_hud:
		_test_editor_hud.visible = true

		# Sync collapse state from Recording UI if transitioning from recording
		if sync_collapse_from_recording and _recording:
			var recording_collapsed = _recording.is_collapsed()
			if _test_editor_hud_collapsed != recording_collapsed:
				_test_editor_hud_collapsed = recording_collapsed
				if _test_editor_hud_body_container:
					_test_editor_hud_body_container.visible = not _test_editor_hud_collapsed
				if _test_editor_hud_details_btn:
					_test_editor_hud_details_btn.text = "▼ Details" if not _test_editor_hud_collapsed else "▶ Details"

		# NOTE: Do NOT reset collapsed state or visibility toggle - they should persist across test restarts

		# Update title with current test name
		if _test_editor_hud_title_edit:
			var display_name = pending_test_name
			if display_name.is_empty() and not _current_running_test_name.is_empty():
				# Load test data to get display name (only when not already set)
				# Use _current_running_test_name (filename) not current_test_name (display name from executor)
				var test_data = _load_test(TESTS_DIR + "/" + _current_running_test_name + ".json")
				display_name = _get_display_name(test_data, _current_running_test_name)
			if display_name.is_empty():
				display_name = "New Test"
			_test_editor_hud_title_edit.text = display_name

		# Buttons will be enabled when paused_changed(true) signal arrives from executor
		# Pre-populate steps so they're ready when user expands
		if _test_editor_hud_current_events.size() > 0 and _test_editor_hud_step_rows.is_empty():
			_populate_test_editor_hud_steps()

		# Check environment and show warning if mismatched
		_update_test_editor_env_warning()

		# Ensure panel is properly sized
		_update_test_editor_hud_panel_height()

func _hide_test_editor_hud():
	if _test_editor_hud:
		_test_editor_hud.visible = false

func _update_test_editor_hud(step_index: int, total_steps: int, event: Dictionary):
	if not _test_editor_hud or not _test_editor_hud.visible:
		return
	_test_editor_hud_step_label.text = "Step: %d/%d" % [step_index + 1, total_steps]
	_test_editor_hud_event_label.text = _executor.get_event_description(event)

	# Show breakpoint indicator
	if _executor.has_breakpoint(step_index):
		_test_editor_hud_step_label.text += " 🔴"

func _update_test_editor_hud_pause_state(paused: bool):
	if not _test_editor_hud:
		return

	if paused:
		# Paused: Play button enabled, Step button enabled
		_test_editor_hud_pause_continue_btn.disabled = false
		_test_editor_hud_step_btn.disabled = false
		# Show HUD when paused (step completed) if it was hidden during playback
		if _test_editor_hud_hidden_during_playback:
			_test_editor_hud.visible = true
	else:
		# Running: Play button disabled (grayed out), Step button disabled
		_test_editor_hud_pause_continue_btn.disabled = true
		_test_editor_hud_step_btn.disabled = true

func _on_test_editor_hud_panel_gui_input(_event: InputEvent):
	# Panel with MOUSE_FILTER_STOP handles event consumption automatically
	# No need to manually consume - just having MOUSE_FILTER_STOP prevents propagation
	pass

func _create_separator_style() -> StyleBoxFlat:
	var style = StyleBoxFlat.new()
	style.bg_color = Color(0.35, 0.35, 0.4, 0.6)
	style.set_content_margin(SIDE_TOP, 1)
	style.set_content_margin(SIDE_BOTTOM, 1)
	return style

func _set_test_editor_hud_border_color(color: Color) -> void:
	if not _test_editor_hud_panel:
		return
	var style = _test_editor_hud_panel.get_theme_stylebox("panel").duplicate()
	style.border_color = color
	_test_editor_hud_panel.add_theme_stylebox_override("panel", style)

func _disable_step_controls() -> void:
	if _test_editor_hud_pause_continue_btn:
		_test_editor_hud_pause_continue_btn.disabled = true
	if _test_editor_hud_step_btn:
		_test_editor_hud_step_btn.disabled = true

# Check environment and update the warning banner in Test Editor HUD
func _update_test_editor_env_warning() -> void:
	if not _test_editor_hud_env_warning or not _executor:
		print("[EnvWarning] No HUD or executor")
		return

	# Skip if warnings are globally disabled
	if not ScreenshotValidator.show_viewport_warnings:
		_test_editor_hud_env_warning.visible = false
		print("[EnvWarning] Warnings disabled globally")
		return

	# Load current test data to check environment
	if _current_running_test_name.is_empty():
		_test_editor_hud_env_warning.visible = false
		print("[EnvWarning] No current test name")
		return

	var test_data = _load_test(TESTS_DIR + "/" + _current_running_test_name + ".json")
	if not test_data:
		_test_editor_hud_env_warning.visible = false
		print("[EnvWarning] Could not load test data")
		return

	var env_check = _executor.check_environment_match(test_data)
	print("[EnvWarning] env_check: matches=%s, status=%s, message=%s" % [env_check.matches, env_check.get("status", ""), env_check.get("message", "")])
	if env_check.matches:
		_test_editor_hud_env_warning.visible = false
	else:
		_test_editor_hud_env_warning.visible = true
		# Update warning text with specific mismatch info
		var warning_label = _test_editor_hud_env_warning.get_node_or_null("WarningLabel")
		if warning_label:
			var current = env_check.get("current", {})
			var recorded = env_check.get("recorded", {})
			var curr_vp = current.get("viewport", {})
			var rec_vp = recorded.get("viewport", {})
			warning_label.text = "⚠ Resolution mismatch: %dx%d (recorded %dx%d)" % [
				curr_vp.get("w", 0), curr_vp.get("h", 0),
				rec_vp.get("w", 0), rec_vp.get("h", 0)
			]

# Flash the close button to indicate user should close Test Editor first (called when F12 pressed while HUD is open)
func _flash_test_editor_hud_close_button() -> void:
	if not _test_editor_hud_close_btn:
		return

	# Create a tween to flash the button
	var tween = create_tween()
	var original_modulate = _test_editor_hud_close_btn.modulate

	# Flash red 3 times
	for i in range(3):
		tween.tween_property(_test_editor_hud_close_btn, "modulate", Color(1.0, 0.3, 0.3), 0.1)
		tween.tween_property(_test_editor_hud_close_btn, "modulate", original_modulate, 0.1)

func _move_cursor_to_play_button() -> void:
	if not _test_editor_hud_pause_continue_btn or not _test_editor_hud_pause_continue_btn.is_visible_in_tree():
		return
	# Get center of play button in screen coordinates
	var btn_rect = _test_editor_hud_pause_continue_btn.get_global_rect()
	var btn_center = btn_rect.get_center()
	# Warp the real mouse cursor to the button
	get_viewport().warp_mouse(btn_center)
	# Hide virtual cursor when moving to HUD buttons
	if virtual_cursor:
		virtual_cursor.visible = false

func _on_test_editor_hud_toggle_details():
	if not _test_editor_hud_body_container or not _test_editor_hud_details_btn:
		return

	_test_editor_hud_collapsed = not _test_editor_hud_collapsed
	_test_editor_hud_body_container.visible = not _test_editor_hud_collapsed
	_test_editor_hud_details_btn.text = "▼ Details" if not _test_editor_hud_collapsed else "▶ Details"

	# Populate steps only if not already populated (when expanding)
	if not _test_editor_hud_collapsed and _test_editor_hud_current_events.size() > 0 and _test_editor_hud_step_rows.is_empty():
		_populate_test_editor_hud_steps()

	# Re-apply highlighting when expanding (preserve pass/fail state)
	if not _test_editor_hud_collapsed and not _test_editor_hud_step_rows.is_empty():
		if _step_mode_test_passed:
			_mark_all_steps_passed()
		elif _failed_step_index >= 0:
			_highlight_test_editor_hud_step(-1)  # Show passed steps, failed step keeps red
		else:
			_highlight_test_editor_hud_step(_executor.current_step if _executor and _executor.is_running else -1)

	# Adjust panel height and width based on visibility
	_update_test_editor_hud_panel_height()
	_restore_hud_focus()

func _update_test_editor_hud_panel_height():
	var panel = _test_editor_hud.get_node_or_null("HUDPanel")
	if not panel:
		return

	if _test_editor_hud_collapsed:
		# Collapsed: header only
		panel.offset_top = -70
		panel.offset_left = -436
	else:
		# Expanded: header + body with steps
		panel.offset_top = -580
		panel.offset_left = -618

const PLAYBACK_DELAY_OPTIONS = [0, 50, 100, 250, 350, 500, 1000, 1500, 2000, 3000, 5000]

func _populate_test_editor_hud_steps():
	if not _test_editor_hud_steps_list:
		return

	# Clear existing rows
	for child in _test_editor_hud_steps_list.get_children():
		child.queue_free()
	_test_editor_hud_step_rows.clear()

	# Create rows for each event
	for i in range(_test_editor_hud_current_events.size()):
		var event = _test_editor_hud_current_events[i]
		var row = _create_test_editor_hud_step_row(i, event)
		_test_editor_hud_steps_list.add_child(row)
		_test_editor_hud_step_rows.append(row)

func _create_test_editor_hud_step_row(index: int, event: Dictionary) -> Control:
	var container = VBoxContainer.new()
	container.add_theme_constant_override("separation", 2)

	# Main row panel - styled like Test Editor
	var panel = PanelContainer.new()
	panel.name = "StepPanel"
	var panel_style = StyleBoxFlat.new()
	panel_style.bg_color = Color(0.18, 0.18, 0.22, 0.9)
	panel_style.set_corner_radius_all(4)
	panel.add_theme_stylebox_override("panel", panel_style)

	var inner_row = HBoxContainer.new()
	inner_row.name = "InnerRow"
	inner_row.add_theme_constant_override("separation", 10)
	panel.add_child(inner_row)

	# Index label - left margin spacer
	var idx_spacer = Control.new()
	idx_spacer.custom_minimum_size.x = 3
	inner_row.add_child(idx_spacer)

	# Index label
	var idx_label = Label.new()
	idx_label.text = "%d." % (index + 1)
	idx_label.custom_minimum_size.x = 28
	idx_label.add_theme_font_size_override("font_size", 15)
	idx_label.add_theme_color_override("font_color", Color(0.6, 0.6, 0.65))
	idx_label.label_settings = LabelSettings.new()
	idx_label.label_settings.font_size = 15
	idx_label.label_settings.font_color = Color(0.6, 0.6, 0.65)
	idx_label.label_settings.outline_size = 1
	idx_label.label_settings.outline_color = Color(0.6, 0.6, 0.65)
	inner_row.add_child(idx_label)

	# Auto-play checkbox - when checked, this step plays automatically without pausing
	var auto_checkbox = CheckBox.new()
	auto_checkbox.name = "AutoPlayCheckbox"
	auto_checkbox.tooltip_text = "Auto-play this step (don't pause)"
	auto_checkbox.button_pressed = _auto_play_steps.has(index)
	auto_checkbox.focus_mode = Control.FOCUS_NONE
	auto_checkbox.toggled.connect(_on_step_auto_play_toggled.bind(index))
	inner_row.add_child(auto_checkbox)

	# Event description
	var desc_label = Label.new()
	desc_label.name = "DescLabel"
	desc_label.text = _get_step_description(event)
	desc_label.add_theme_font_size_override("font_size", 13)
	desc_label.add_theme_color_override("font_color", Color(0.85, 0.85, 0.9))
	inner_row.add_child(desc_label)

	# Add thumbnail and Diff button for screenshot_validation events
	if event.get("type") == "screenshot_validation":
		var thumb = _create_step_thumbnail(event)
		if thumb:
			inner_row.add_child(thumb)
		# Add Diff button (hidden by default, shown when validation fails)
		var diff_btn = Button.new()
		diff_btn.name = "DiffBtn"
		diff_btn.icon = load("res://addons/godot-ui-automation/icons/branch_compare.svg")
		diff_btn.tooltip_text = "View comparison (Expected vs Actual)"
		diff_btn.custom_minimum_size = Vector2(36, 28)
		diff_btn.expand_icon = true
		diff_btn.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
		diff_btn.focus_mode = Control.FOCUS_NONE
		diff_btn.visible = false  # Hidden until validation fails
		diff_btn.pressed.connect(_on_step_diff_btn_pressed)
		inner_row.add_child(diff_btn)
		# Add spacer after thumbnail/diff button
		var spacer = Control.new()
		spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		inner_row.add_child(spacer)
	else:
		desc_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	# "then wait" label
	var wait_label = Label.new()
	wait_label.text = "then wait"
	wait_label.add_theme_font_size_override("font_size", 12)
	wait_label.add_theme_color_override("font_color", Color(0.6, 0.6, 0.65))
	inner_row.add_child(wait_label)

	# Wait dropdown
	var delay_dropdown = OptionButton.new()
	delay_dropdown.name = "DelayDropdown"
	delay_dropdown.custom_minimum_size.x = 80
	var current_delay = event.get("wait_after", 100)
	var selected_idx = 0
	for j in range(PLAYBACK_DELAY_OPTIONS.size()):
		var d = PLAYBACK_DELAY_OPTIONS[j]
		if d < 1000:
			delay_dropdown.add_item("%dms" % d, d)
		else:
			delay_dropdown.add_item("%.1fs" % (d / 1000.0), d)
		if d == current_delay:
			selected_idx = j
	delay_dropdown.select(selected_idx)
	delay_dropdown.item_selected.connect(_on_playback_step_delay_changed.bind(index))
	inner_row.add_child(delay_dropdown)

	# Delete step button (red X)
	var delete_btn = Button.new()
	delete_btn.name = "DeleteBtn"
	delete_btn.icon = load("res://addons/godot-ui-automation/icons/delete_x.svg")
	delete_btn.tooltip_text = "Delete step"
	delete_btn.custom_minimum_size = Vector2(29, 29)
	delete_btn.expand_icon = true
	delete_btn.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
	delete_btn.focus_mode = Control.FOCUS_NONE
	delete_btn.flat = true
	delete_btn.pressed.connect(_on_playback_step_delete.bind(index))
	inner_row.add_child(delete_btn)

	# Right margin spacer
	var right_spacer = Control.new()
	right_spacer.custom_minimum_size.x = 4
	inner_row.add_child(right_spacer)

	container.add_child(panel)

	# Note row with icon (like Test Editor)
	var note_row = HBoxContainer.new()
	note_row.add_theme_constant_override("separation", 5)

	var note_spacer = Control.new()
	note_spacer.custom_minimum_size.x = 28
	note_row.add_child(note_spacer)

	var note_icon = Label.new()
	note_icon.text = "📝"
	note_icon.add_theme_color_override("font_color", Color(0.5, 0.5, 0.55))
	note_row.add_child(note_icon)

	var note_input = LineEdit.new()
	note_input.name = "NoteInput"
	note_input.placeholder_text = "Add note (e.g., 'drag card to column')"
	note_input.text = event.get("note", "")
	note_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	note_input.add_theme_font_size_override("font_size", 12)
	note_input.add_theme_color_override("font_placeholder_color", Color(0.4, 0.4, 0.45))
	note_input.text_changed.connect(_on_playback_step_note_changed.bind(index))
	note_row.add_child(note_input)

	container.add_child(note_row)
	return container

func _get_step_description(event: Dictionary) -> String:
	var event_type = event.get("type", "unknown")
	match event_type:
		"click":
			var pos = event.get("pos", Vector2.ZERO)
			if pos is Dictionary:
				pos = Vector2(pos.get("x", 0), pos.get("y", 0))
			var mods = ""
			if event.get("ctrl", false):
				mods += "Ctrl+"
			if event.get("shift", false):
				mods += "Shift+"
			return "%sClick at (%d, %d)" % [mods, int(pos.x), int(pos.y)]
		"double_click":
			var pos = event.get("pos", Vector2.ZERO)
			if pos is Dictionary:
				pos = Vector2(pos.get("x", 0), pos.get("y", 0))
			var mods = ""
			if event.get("ctrl", false):
				mods += "Ctrl+"
			if event.get("shift", false):
				mods += "Shift+"
			return "%sDouble-click at (%d, %d)" % [mods, int(pos.x), int(pos.y)]
		"drag":
			var from_pos = event.get("from", Vector2.ZERO)
			var to_pos = event.get("to", Vector2.ZERO)
			if from_pos is Dictionary:
				from_pos = Vector2(from_pos.get("x", 0), from_pos.get("y", 0))
			if to_pos is Dictionary:
				to_pos = Vector2(to_pos.get("x", 0), to_pos.get("y", 0))
			var mods = ""
			if event.get("ctrl", false):
				mods += "Ctrl+"
			if event.get("shift", false):
				mods += "Shift+"
			return "%sDrag (%d,%d) → (%d,%d)" % [mods, int(from_pos.x), int(from_pos.y), int(to_pos.x), int(to_pos.y)]
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
		"pan":
			var from_pos = event.get("from", Vector2.ZERO)
			var to_pos = event.get("to", Vector2.ZERO)
			# Handle both Vector2 and Dictionary formats
			if from_pos is Dictionary:
				from_pos = Vector2(from_pos.get("x", 0), from_pos.get("y", 0))
			if to_pos is Dictionary:
				to_pos = Vector2(to_pos.get("x", 0), to_pos.get("y", 0))
			return "Pan (%d,%d) → (%d,%d)" % [int(from_pos.x), int(from_pos.y), int(to_pos.x), int(to_pos.y)]
		"right_click":
			var pos = event.get("pos", Vector2.ZERO)
			if pos is Dictionary:
				pos = Vector2(pos.get("x", 0), pos.get("y", 0))
			return "Right-click at (%d, %d)" % [int(pos.x), int(pos.y)]
		"scroll":
			var direction = event.get("direction", "in")
			return "Scroll %s" % direction
		"screenshot_validation":
			return "📷 Validate Screenshot"
		"set_clipboard_image":
			return "📋 Set clipboard image"
		_:
			return "Unknown event"

# Creates a clickable thumbnail for screenshot_validation events in the playback HUD
func _create_step_thumbnail(event: Dictionary) -> Control:
	var path = event.get("path", "")
	if path.is_empty():
		return null

	var thumb_container = Control.new()
	thumb_container.custom_minimum_size = Vector2(60, 40)
	thumb_container.mouse_filter = Control.MOUSE_FILTER_STOP
	thumb_container.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	thumb_container.tooltip_text = "Click to view full size"

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
			thumb.custom_minimum_size = Vector2(60, 40)
			thumb.mouse_filter = Control.MOUSE_FILTER_IGNORE
			thumb_container.add_child(thumb)
		else:
			var placeholder = Label.new()
			placeholder.text = "[Error]"
			placeholder.add_theme_font_size_override("font_size", 10)
			placeholder.add_theme_color_override("font_color", Color(0.8, 0.4, 0.4))
			thumb_container.add_child(placeholder)
	else:
		var placeholder = Label.new()
		placeholder.text = "[No Img]"
		placeholder.add_theme_font_size_override("font_size", 10)
		placeholder.add_theme_color_override("font_color", Color(0.5, 0.5, 0.6))
		thumb_container.add_child(placeholder)

	thumb_container.gui_input.connect(_on_step_thumbnail_clicked.bind(path))
	return thumb_container

func _on_step_thumbnail_clicked(event: InputEvent, image_path: String):
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		_show_step_screenshot_fullsize(image_path)

func _on_step_diff_btn_pressed():
	# Show comparison viewer with baseline and actual screenshots
	if last_baseline_path.is_empty() or last_actual_path.is_empty():
		print("[UITestRunner] No diff available - baseline or actual path missing")
		return
	_show_comparison_viewer()

func _show_step_screenshot_fullsize(image_path: String):
	var global_path = ProjectSettings.globalize_path(image_path)
	if image_path.is_empty() or not FileAccess.file_exists(global_path):
		print("[UITestRunner] Screenshot not found: %s" % image_path)
		return

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
	close_btn.icon = load("res://addons/godot-ui-automation/icons/dismiss_circle.svg")
	close_btn.tooltip_text = "Close (Esc or click anywhere)"
	close_btn.custom_minimum_size = Vector2(48, 48)
	close_btn.expand_icon = true
	close_btn.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
	close_btn.focus_mode = Control.FOCUS_NONE
	close_btn.flat = true
	header.add_child(close_btn)

	var scroll = ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	vbox.add_child(scroll)

	var center = CenterContainer.new()
	center.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	center.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.add_child(center)

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

	var canvas = CanvasLayer.new()
	canvas.layer = 250  # Above playback HUD
	canvas.add_child(viewer)
	get_tree().root.add_child(canvas)

	close_btn.pressed.connect(func(): canvas.queue_free())

	# Click anywhere or ESC to close
	var click_overlay = Control.new()
	click_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	click_overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	click_overlay.gui_input.connect(func(ev):
		if ev is InputEventKey and ev.pressed and ev.keycode == KEY_ESCAPE:
			canvas.queue_free()
		elif ev is InputEventMouseButton and ev.pressed and ev.button_index == MOUSE_BUTTON_LEFT:
			canvas.queue_free()
	)
	viewer.add_child(click_overlay)
	click_overlay.focus_mode = Control.FOCUS_ALL
	click_overlay.grab_focus()

func _on_playback_step_delay_changed(dropdown_index: int, event_index: int):
	if event_index < 0 or event_index >= _test_editor_hud_current_events.size():
		return
	var delay_value = PLAYBACK_DELAY_OPTIONS[dropdown_index]
	_test_editor_hud_current_events[event_index]["wait_after"] = delay_value
	# Also update executor's events so changes persist through restart
	if _executor and event_index < _executor._current_events.size():
		_executor._current_events[event_index]["wait_after"] = delay_value
	# Auto-save the test with updated delay
	_auto_save_current_test_events()

func _on_playback_step_delete(event_index: int):
	if event_index < 0 or event_index >= _test_editor_hud_current_events.size():
		return

	# Remove from both event arrays
	_test_editor_hud_current_events.remove_at(event_index)
	if _executor and event_index < _executor._current_events.size():
		_executor._current_events.remove_at(event_index)

	# Update auto-play indices (shift down indices above the deleted one)
	var new_auto_play = {}
	for idx in _auto_play_steps.keys():
		if idx < event_index:
			new_auto_play[idx] = true
		elif idx > event_index:
			new_auto_play[idx - 1] = true
		# Skip idx == event_index (deleted)
	_auto_play_steps = new_auto_play

	# Repopulate the steps UI
	_populate_test_editor_hud_steps()

	# Update step counter in HUD
	if _test_editor_hud_step_label:
		var total = _test_editor_hud_current_events.size()
		var current = _executor.current_step if _executor else 0
		_test_editor_hud_step_label.text = "Step: %d/%d" % [current + 1, total]

	# Auto-save the test
	_auto_save_current_test_events()
	print("[UITestRunner] Deleted step %d" % (event_index + 1))

# Auto-saves the current test file with updated event data (wait times, notes, etc.)
func _auto_save_current_test_events():
	if _current_running_test_name.is_empty():
		return

	var filepath = TESTS_DIR + "/" + _current_running_test_name + ".json"
	var test_data = FileIO.load_test(filepath)
	if test_data.is_empty():
		return

	# Update the events in the test data with current values
	var updated_events = []
	for event in _test_editor_hud_current_events:
		# Create a serializable copy
		var ser_event = event.duplicate()
		# Convert Vector2 to dict for JSON
		if ser_event.has("pos") and ser_event["pos"] is Vector2:
			var pos = ser_event["pos"]
			ser_event["pos"] = {"x": pos.x, "y": pos.y}
		if ser_event.has("from") and ser_event["from"] is Vector2:
			var from = ser_event["from"]
			ser_event["from"] = {"x": from.x, "y": from.y}
		if ser_event.has("to") and ser_event["to"] is Vector2:
			var to = ser_event["to"]
			ser_event["to"] = {"x": to.x, "y": to.y}
		if ser_event.has("to_world") and ser_event["to_world"] is Vector2:
			var tw = ser_event["to_world"]
			ser_event["to_world"] = {"x": tw.x, "y": tw.y}
		if ser_event.has("to_cell") and ser_event["to_cell"] is Vector2i:
			var tc = ser_event["to_cell"]
			ser_event["to_cell"] = {"x": tc.x, "y": tc.y}
		if ser_event.has("click_offset") and ser_event["click_offset"] is Vector2:
			var co = ser_event["click_offset"]
			ser_event["click_offset"] = {"x": co.x, "y": co.y}
		updated_events.append(ser_event)

	test_data["events"] = updated_events
	FileIO.save_test_data(_current_running_test_name + ".json", test_data)

func _on_step_auto_play_toggled(toggled: bool, step_index: int):
	if toggled:
		_auto_play_steps[step_index] = true
	else:
		_auto_play_steps.erase(step_index)

# Check if a step should auto-play (called by executor)
func should_auto_play_step(step_index: int) -> bool:
	return _auto_play_steps.has(step_index)

func _on_playback_step_note_changed(new_text: String, event_index: int):
	if event_index < 0 or event_index >= _test_editor_hud_current_events.size():
		return
	_test_editor_hud_current_events[event_index]["note"] = new_text
	# Also update executor's events so changes persist through restart
	if _executor and event_index < _executor._current_events.size():
		_executor._current_events[event_index]["note"] = new_text
	# Auto-save the test with updated note
	_auto_save_current_test_events()

func _highlight_test_editor_hud_step(step_index: int):
	if not _test_editor_hud_steps_list or _test_editor_hud_step_rows.is_empty():
		return

	# Style each step based on its state: passed (green), failed (red), current (blue), pending (default)
	for i in range(_test_editor_hud_step_rows.size()):
		if i == _failed_step_index:
			continue  # Don't reset failed step's red highlight
		var row = _test_editor_hud_step_rows[i]
		var panel = row.get_node_or_null("StepPanel")
		if not panel:
			continue

		var style = StyleBoxFlat.new()
		style.set_corner_radius_all(4)

		# Use .has() instead of 'in' for typed array compatibility
		if _passed_step_indices.has(i):
			# Passed step - green
			style.bg_color = Color(0.15, 0.25, 0.18, 0.95)  # Slight green tint
			style.border_color = Color(0.4, 0.9, 0.4, 1.0)  # Green border
			style.set_border_width_all(2)
		elif i == step_index:
			# Current step - blue
			style.bg_color = Color(0.18, 0.22, 0.28, 0.95)  # Slight blue tint
			style.border_color = Color(0.4, 0.6, 1.0, 1.0)  # Blue border
			style.set_border_width_all(2)
		else:
			# Pending step - default
			style.bg_color = Color(0.18, 0.18, 0.22, 0.9)

		panel.add_theme_stylebox_override("panel", style)

	# Auto-scroll to current step
	if step_index >= 0 and step_index < _test_editor_hud_step_rows.size():
		var row = _test_editor_hud_step_rows[step_index]
		if _test_editor_hud_steps_scroll:
			_test_editor_hud_steps_scroll.call_deferred("ensure_control_visible", row)

# Force all step rows to show green (passed) styling - used when test passes
func _mark_all_steps_passed():
	if _test_editor_hud_step_rows.is_empty():
		return

	for row in _test_editor_hud_step_rows:
		var panel = row.get_node_or_null("StepPanel")
		if not panel:
			continue
		var style = StyleBoxFlat.new()
		style.set_corner_radius_all(4)
		style.bg_color = Color(0.15, 0.25, 0.18, 0.95)  # Slight green tint
		style.border_color = Color(0.4, 0.9, 0.4, 1.0)  # Green border
		style.set_border_width_all(2)
		panel.add_theme_stylebox_override("panel", style)

# Reset all step highlights to default (unplayed) state
func _reset_step_highlights():
	# Clear tracking state
	_passed_step_indices.clear()
	_failed_step_index = -1
	_step_mode_test_passed = false

	# Reset border to neutral
	_set_test_editor_hud_border_color(Color(1.0, 1.0, 1.0, 1.0))  # White

	# Hide pass/fail indicators

	# Reset step label color to default
	if _test_editor_hud_step_label:
		_test_editor_hud_step_label.add_theme_color_override("font_color", Color(0.7, 0.7, 0.75))

	# Reset all step row highlights to default styling
	for row in _test_editor_hud_step_rows:
		var panel = row.get_node_or_null("StepPanel")
		if panel:
			var style = StyleBoxFlat.new()
			style.bg_color = Color(0.18, 0.18, 0.22, 1.0)  # Default color
			style.set_corner_radius_all(6)
			panel.add_theme_stylebox_override("panel", style)

# Apply failed step highlighting (called from "Step X" button)
# Shows which steps passed before the failure and highlights the failed step in red
# Note: failed_step is 1-based (from UI display), convert to 0-based index
func _apply_failed_step_highlight(failed_step: int):
	# Convert from 1-based (UI display) to 0-based (array index)
	var step_index = failed_step - 1
	if step_index < 0:
		return

	# Expand the Test Editor HUD if collapsed (so user can see the steps)
	if _test_editor_hud_collapsed:
		_test_editor_hud_collapsed = false
		if _test_editor_hud_body_container:
			_test_editor_hud_body_container.visible = true
		if _test_editor_hud_details_btn:
			_test_editor_hud_details_btn.text = "▼ Details"
		_update_test_editor_hud_panel_height()

	# Populate steps if not already done
	if _test_editor_hud_step_rows.is_empty() and _test_editor_hud_current_events.size() > 0:
		_populate_test_editor_hud_steps()

	if _test_editor_hud_step_rows.is_empty():
		# Steps not populated yet, wait a frame and retry
		get_tree().create_timer(0.1).timeout.connect(_apply_failed_step_highlight.bind(failed_step))
		return

	# Mark steps 0 to step_index-1 as passed (green)
	_passed_step_indices.clear()
	for i in range(step_index):
		_passed_step_indices.append(i)

	# Mark the failed step
	_failed_step_index = step_index

	# Set red border to indicate failure state
	_set_test_editor_hud_border_color(Color(0.95, 0.3, 0.3, 1.0))

	# Apply red styling to the failed step row
	_highlight_failed_step(step_index)

	# Apply visual highlighting to all other steps (passed = green, pending = default)
	_highlight_test_editor_hud_step(step_index)

	# Scroll to the failed step (wait for UI to fully render)
	if _test_editor_hud_steps_scroll and step_index < _test_editor_hud_step_rows.size():
		var row = _test_editor_hud_step_rows[step_index]
		# Wait two frames for layout to complete before scrolling
		await get_tree().process_frame
		await get_tree().process_frame
		_test_editor_hud_steps_scroll.ensure_control_visible(row)

# Highlight a step with red border to indicate failure
# Optionally stores baseline_path and actual_path for screenshot diff viewing
func _highlight_failed_step(step_index: int, baseline_path: String = "", actual_path: String = ""):
	if not _test_editor_hud_steps_list or _test_editor_hud_step_rows.is_empty():
		return
	if step_index < 0 or step_index >= _test_editor_hud_step_rows.size():
		return

	var row = _test_editor_hud_step_rows[step_index]
	var panel = row.get_node_or_null("StepPanel")
	if panel:
		var style = StyleBoxFlat.new()
		style.bg_color = Color(0.28, 0.18, 0.18, 0.95)  # Dark red background
		style.border_color = Color(0.9, 0.3, 0.3, 1.0)  # Red border
		style.set_border_width_all(2)
		style.set_corner_radius_all(4)
		panel.add_theme_stylebox_override("panel", style)

	# Store paths for diff viewing and show/enable Diff button
	if not baseline_path.is_empty() and not actual_path.is_empty():
		last_baseline_path = baseline_path
		last_actual_path = actual_path
		# Show the Diff button if it exists on this row
		var diff_btn = row.get_node_or_null("StepPanel/InnerRow/DiffBtn")
		if diff_btn:
			diff_btn.visible = true

	# Auto-scroll to make visible
	if _test_editor_hud_steps_scroll:
		_test_editor_hud_steps_scroll.call_deferred("ensure_control_visible", row)

# Handle HUD button clicks manually to preserve focus (called from _input before GUI processing)
func _handle_hud_button_click(pos: Vector2) -> bool:
	# Save current focus before any action
	var focused = get_viewport().gui_get_focus_owner()
	var handled = false

	# Check each button
	if _test_editor_hud_step_btn and _test_editor_hud_step_btn.visible and not _test_editor_hud_step_btn.disabled:
		if _test_editor_hud_step_btn.get_global_rect().has_point(pos):
			if _executor:
				_executor.step_forward()
			handled = true
	elif _test_editor_hud_pause_continue_btn and _test_editor_hud_pause_continue_btn.visible:
		if _test_editor_hud_pause_continue_btn.get_global_rect().has_point(pos):
			if _executor:
				if _executor.is_paused:
					_executor.resume()
				else:
					_executor.pause()
			handled = true
	elif _test_editor_hud_restart_btn and _test_editor_hud_restart_btn.visible:
		if _test_editor_hud_restart_btn.get_global_rect().has_point(pos):
			if _executor and _executor.is_running:
				ui_test_runner_test_starting.emit(current_test_name, _get_test_setup_config(current_test_name))
				_executor.restart_from_beginning()
				_highlight_test_editor_hud_step(0)
			handled = true
	elif _test_editor_hud_visibility_btn and _test_editor_hud_visibility_btn.visible:
		if _test_editor_hud_visibility_btn.get_global_rect().has_point(pos):
			# Toggle the button state manually (it's a toggle button)
			_test_editor_hud_visibility_btn.button_pressed = not _test_editor_hud_visibility_btn.button_pressed
			handled = true
	elif _test_editor_hud_details_btn and _test_editor_hud_details_btn.visible:
		if _test_editor_hud_details_btn.get_global_rect().has_point(pos):
			_on_test_editor_hud_toggle_details_internal()
			handled = true

	# Restore focus if we handled a button click
	if handled and focused and is_instance_valid(focused):
		focused.call_deferred("grab_focus")

	return handled

# Internal toggle function (without focus handling - that's done by _handle_hud_button_click)
func _on_test_editor_hud_toggle_details_internal():
	if not _test_editor_hud_body_container or not _test_editor_hud_details_btn:
		return
	_test_editor_hud_collapsed = not _test_editor_hud_collapsed
	_test_editor_hud_body_container.visible = not _test_editor_hud_collapsed
	_test_editor_hud_details_btn.text = "▼ Details" if not _test_editor_hud_collapsed else "▶ Details"
	# Populate steps only if not already populated (when expanding)
	if not _test_editor_hud_collapsed and _test_editor_hud_current_events.size() > 0 and _test_editor_hud_step_rows.is_empty():
		_populate_test_editor_hud_steps()
	# Re-apply highlighting when expanding (preserve pass/fail state)
	if not _test_editor_hud_collapsed and not _test_editor_hud_step_rows.is_empty():
		if _step_mode_test_passed:
			_mark_all_steps_passed()
		elif _failed_step_index >= 0:
			_highlight_test_editor_hud_step(-1)  # Show passed steps, failed step keeps red
		else:
			_highlight_test_editor_hud_step(_executor.current_step if _executor and _executor.is_running else -1)
	_update_test_editor_hud_panel_height()

# Save focus when any HUD button is pressed down (backup - state already saved in _input)
func _on_hud_button_down():
	_hud_saved_focus = get_viewport().gui_get_focus_owner()

# Restore focus to the last text input after HUD button action (deferred)
func _restore_hud_focus():
	var to_restore = _get_focus_to_restore()
	if to_restore:
		to_restore.call_deferred("grab_focus")
	_hud_saved_focus = null

# Restore focus immediately (for use before test step execution)
# Note: Uses double-deferred call to run AFTER any call_deferred("release_focus") from focus_exited handlers
func _restore_hud_focus_immediate():
	var to_restore = _get_focus_to_restore()
	if to_restore:
		# For LineEdit: restore editable state BEFORE grab_focus (so focus_exited handler
		# from button click doesn't disable editing, which would prevent cursor activation)
		if to_restore is LineEdit and _last_text_was_editable:
			to_restore.editable = true
			to_restore.selecting_enabled = true
		# Defer focus grab to run AFTER any pending release_focus calls
		# Double deferred ensures we run after single-deferred release_focus
		call_deferred("_do_focus_restore", to_restore)
	_hud_saved_focus = null

func _do_focus_restore(control: Control):
	if not is_instance_valid(control):
		return
	# Re-enable editable in case release_focus disabled it
	if control is LineEdit and _last_text_was_editable:
		control.editable = true
		control.selecting_enabled = true
	control.grab_focus()
	# Restore caret position and selection state exactly as it was
	if control is LineEdit:
		if _last_selection_start != _last_selection_end:
			# Had selection - restore it
			control.select(_last_selection_start, _last_selection_end)
		else:
			# No selection - just restore caret position
			control.caret_column = _last_caret_column
	elif control is TextEdit:
		# For TextEdit, just position caret at end (simpler case)
		control.set_caret_column(control.get_line(control.get_caret_line()).length())

# Get the control that should receive focus
func _get_focus_to_restore() -> Control:
	# Prefer _last_text_focus (tracked via gui_focus_changed signal)
	# Fall back to _hud_saved_focus (saved on button_down)
	if _last_text_focus and is_instance_valid(_last_text_focus):
		return _last_text_focus
	elif _hud_saved_focus and is_instance_valid(_hud_saved_focus):
		return _hud_saved_focus
	return null

func _on_test_editor_hud_play():
	if not _executor:
		return
	# Update environment warning (user may have moved window to different monitor)
	_update_test_editor_env_warning()
	if _executor.is_paused:
		# Play to end: mark all remaining steps as auto-play and run
		_mark_remaining_steps_auto_play()
		# Hide HUD during full playback if visibility toggle is enabled
		if _test_editor_hud_hidden_during_playback and _test_editor_hud:
			_test_editor_hud.visible = false
		_executor.unpause()
	_restore_hud_focus()

# Mark all steps from current position to end as auto-play (for Play/Continue)
func _mark_remaining_steps_auto_play():
	var current = _executor.current_step if _executor else 0
	var total = _test_editor_hud_current_events.size()
	for i in range(current, total):
		_auto_play_steps[i] = true

func _on_test_editor_hud_step():
	if not _executor:
		return
	# Update environment warning (user may have moved window to different monitor)
	_update_test_editor_env_warning()
	# Hide HUD during step execution if visibility toggle is enabled
	if _test_editor_hud_hidden_during_playback and _test_editor_hud:
		_test_editor_hud.visible = false
	# Restore focus BEFORE stepping so the test step can use it
	_restore_hud_focus_immediate()
	_executor.step_forward()

func _on_test_editor_hud_close():
	# Behave the same as ESC - close HUD and return to Test Manager
	if is_running:
		_abort_test_to_tests_tab()
	else:
		_close_debug_hud_to_tests_tab()

func _on_test_editor_hud_visibility_toggled(button_pressed: bool):
	# Toggle hide-during-playback mode
	_test_editor_hud_hidden_during_playback = button_pressed

	# Update icon based on state
	if _test_editor_hud_visibility_btn:
		if button_pressed:
			_test_editor_hud_visibility_btn.icon = load("res://addons/godot-ui-automation/icons/eye-off.svg")
			_test_editor_hud_visibility_btn.tooltip_text = "UI hidden during playback (click to show)"
		else:
			_test_editor_hud_visibility_btn.icon = load("res://addons/godot-ui-automation/icons/eye.svg")
			_test_editor_hud_visibility_btn.tooltip_text = "Hide UI during playback"

func _on_test_name_submitted(_new_text: String):
	# Called when user presses Enter in the title edit
	_save_test_name_change()
	_test_editor_hud_title_edit.release_focus()

func _on_test_name_focus_exited():
	# Called when the title edit loses focus
	_save_test_name_change()

func _save_test_name_change():
	if not _test_editor_hud_title_edit:
		return
	var new_name = _test_editor_hud_title_edit.text.strip_edges()
	if new_name.is_empty():
		# Restore previous name if empty
		var display_name = pending_test_name if not pending_test_name.is_empty() else current_test_name
		if display_name.is_empty():
			display_name = "New Test"
		_test_editor_hud_title_edit.text = display_name
		return

	# Get the old name for comparison
	var old_name = pending_test_name if not pending_test_name.is_empty() else current_test_name
	if old_name == new_name:
		return  # No change

	# Update pending_test_name (will be used when saving)
	pending_test_name = new_name

	# If we have a saved test file, rename it
	if not old_name.is_empty():
		var old_filename = old_name.to_snake_case().replace(" ", "_") + ".json"
		var new_filename = new_name.to_snake_case().replace(" ", "_") + ".json"
		var old_path = TESTS_DIR.path_join(old_filename)
		var new_path = TESTS_DIR.path_join(new_filename)

		# Check if file exists
		var dir = DirAccess.open(TESTS_DIR)
		if dir and dir.file_exists(old_filename):
			# Rename the file
			var err = dir.rename(old_filename, new_filename)
			if err == OK:
				print("[UITestRunner] Renamed test file: %s -> %s" % [old_filename, new_filename])
				# Update the test data name field
				var test_data = _load_test(new_path)
				if test_data:
					test_data["name"] = new_name
					var file = FileAccess.open(new_path, FileAccess.WRITE)
					if file:
						file.store_string(JSON.stringify(test_data, "\t"))
						file.close()
						print("[UITestRunner] Updated test name in file: %s" % new_name)

				# Transfer category from old filename to new filename
				var old_test_name = old_filename.replace(".json", "")
				var new_test_name = new_filename.replace(".json", "")
				var old_category = CategoryManager.get_test_category(old_test_name)
				if not old_category.is_empty():
					CategoryManager.set_test_category(new_test_name, old_category)
					CategoryManager.set_test_category(old_test_name, "")
					print("[UITestRunner] Transferred category '%s' to renamed test" % old_category)

				# Update editing_original_filename to track the new name
				editing_original_filename = new_test_name
			else:
				push_error("[UITestRunner] Failed to rename test file: %s" % err)
				_test_editor_hud_title_edit.text = old_name  # Restore old name on failure

func _on_test_editor_hud_restart():
	if not _executor:
		return
	# Allow restart if: running, failed, or passed in step mode
	if not _executor.is_running and _failed_step_index < 0 and not _step_mode_test_passed:
		return

	# Clear failed step highlight, passed steps, and pass indicator
	_failed_step_index = -1
	_passed_step_indices.clear()
	_step_mode_test_passed = false
	# Clear auto-play steps - reset should start fresh, pausing at step 1
	_auto_play_steps.clear()

	# Reset border to white (neutral)
	_set_test_editor_hud_border_color(Color(1.0, 1.0, 1.0, 1.0))  # White

	# Update environment warning (user may have moved window to different monitor)
	_update_test_editor_env_warning()

	# Re-enable Play button (was disabled during running)
	if _test_editor_hud_pause_continue_btn:
		_test_editor_hud_pause_continue_btn.disabled = false
	if _test_editor_hud_step_btn:
		_test_editor_hud_step_btn.disabled = false

	# Hide pass/fail indicators

	# Reset step label color to default
	if _test_editor_hud_step_label:
		_test_editor_hud_step_label.add_theme_color_override("font_color", Color(0.7, 0.7, 0.75))

	# Reset all step row highlights (clear red/green)
	for row in _test_editor_hud_step_rows:
		var panel = row.get_node_or_null("StepPanel")
		if panel:
			var style = StyleBoxFlat.new()
			style.bg_color = Color(0.18, 0.18, 0.22, 1.0)  # Default color
			style.set_corner_radius_all(6)
			panel.add_theme_stylebox_override("panel", style)

	# Emit signal to trigger board cleanup (same as test start)
	ui_test_runner_test_starting.emit(current_test_name, _get_test_setup_config(current_test_name))

	# Reset step label to show step 1
	if _test_editor_hud_step_label:
		var total = _test_editor_hud_current_events.size()
		_test_editor_hud_step_label.text = "Step: 1/%d" % total

	# Skip cursor warp on the pause that follows restart
	_skip_cursor_move_on_pause = true

	# Check if test is still running (mid-test restart) vs completed (re-run)
	if _executor.is_running:
		# Test still running - use internal restart
		# Ensure step mode is enabled so we pause at step 1
		_executor.set_step_mode(true)
		_executor.restart_from_beginning()
	else:
		# Test completed - re-run from scratch in step mode
		# Skip setup delays since environment is already configured
		_executor.set_step_mode(true)
		_run_test_from_file(_current_running_test_name, true)

	# Highlight step 0 in the UI
	_highlight_test_editor_hud_step(0)
	# Don't restore focus after Reset - we don't want focus going to the title
	# Use call_deferred to ensure buttons are enabled after any test initialization that might disable them
	call_deferred("_enable_playback_buttons")

# Helper to enable playback buttons (used via call_deferred)
func _enable_playback_buttons():
	if _test_editor_hud_pause_continue_btn:
		_test_editor_hud_pause_continue_btn.disabled = false
	if _test_editor_hud_step_btn:
		_test_editor_hud_step_btn.disabled = false

func _on_test_editor_hud_rerecord():
	if not _current_running_test_name:
		return

	# Stop any running test
	if _executor and _executor.is_running:
		_executor.cancel_test()

	# Store test name for re-recording
	rerecording_test_name = _current_running_test_name

	# Reset step highlights so new recording starts fresh
	_reset_step_highlights()

	# Sync collapse state from playback to recording
	_recording.set_collapsed(_test_editor_hud_collapsed)

	# Hide the Test Editor HUD
	_hide_test_editor_hud()

	# Start recording - when done, we'll return to Test Editor dialog
	_test_session_active = true
	_warn_missing_handlers()
	ui_test_runner_setup_environment.emit()
	ui_test_runner_recording_started.emit()
	_recording.start_recording()
	_set_test_mode(true, true)

func _close_results_panel():
	# Legacy - now just closes test selector
	_close_test_selector()

func _update_results_tab():
	_test_manager.batch_results = batch_results
	_test_manager.test_run_history = test_run_history
	_test_manager.update_results_tab()

func _on_view_failed_step(test_name: String, failed_step: int):
	# Run test in step mode (same as "Test Editor" button from Results tab)
	# but with pre-highlighted passed/failed steps to show where failure occurred
	if is_running:
		print("[UITestRunner] Cannot view failed step - test already running")
		return

	# Store the failed step to highlight after HUD appears
	_pending_failed_step_highlight = failed_step

	# Load test data to get display name for the title
	var filepath = TESTS_DIR + "/" + test_name + ".json"
	var test_data = _load_test(filepath)
	if not test_data.is_empty():
		pending_test_name = _get_display_name(test_data, test_name)

	# Use same flow as "Test Editor" button from Results tab
	_reset_step_highlights()
	_close_test_selector(true)
	_executor.set_step_mode(true)
	_debug_from_results = true
	_run_test_from_file(test_name, true)  # Skip countdown - just open Test Editor

func _view_failed_test_diff(result: Dictionary):
	last_baseline_path = result.baseline_path
	last_actual_path = result.actual_path
	_close_results_panel()
	_show_comparison_viewer()

# ============================================================================
# SCREENSHOT REGION SELECTION
# ============================================================================

func _start_region_selection():
	# Delegate to region selector (handles overlay, pause, and input)
	_region_selector.start_selection()

func _capture_and_generate():
	var baseline_path = await _capture_baseline_screenshot()
	_generate_test_code(baseline_path)

func _capture_baseline_screenshot() -> String:
	# Hide ALL UI elements that shouldn't be in screenshot
	virtual_cursor.visible = false
	if recording_indicator:
		recording_indicator.visible = false
	_region_selector.hide_overlay()

	# Wait for elements to disappear from render
	await get_tree().process_frame
	await get_tree().process_frame
	await get_tree().process_frame  # Extra frame to ensure overlay is gone

	# Debug: print viewport and selection info
	var viewport_size = get_viewport().get_visible_rect().size
	print("[UITestRunner] Viewport size: ", viewport_size)
	print("[UITestRunner] Selection rect: ", selection_rect)

	var image = get_viewport().get_texture().get_image()

	# Crop to selection region
	var cropped = image.get_region(selection_rect)

	# Generate filename
	var timestamp = Time.get_datetime_string_from_system().replace(":", "-").replace(" ", "_")
	var filename = "baseline_%s.png" % timestamp
	var dir_path = "res://tests/baselines"
	var full_path = "%s/%s" % [dir_path, filename]

	# Ensure directory exists
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir_path))

	# Save image
	cropped.save_png(ProjectSettings.globalize_path(full_path))
	print("[UITestRunner] Baseline saved: ", full_path)
	print("[UITestRunner] Region: ", selection_rect)

	return full_path

func _generate_test_code(baseline_path: Variant):
	# Use re-recording name if set (Update Baseline flow), otherwise generate new name
	var test_name: String
	if rerecording_test_name != "":
		test_name = rerecording_test_name
		rerecording_test_name = ""  # Clear after use
		print("[UITestRunner] Re-recording test: ", test_name)
	else:
		# Generate a friendly unique name
		var existing_tests = _get_saved_tests()
		var counter = 1
		test_name = "New Test %d" % counter
		# existing_tests returns filenames without .json, so don't add it
		while test_name.to_snake_case().replace(" ", "_") in existing_tests:
			counter += 1
			test_name = "New Test %d" % counter

	# Add default delays to recorded events
	for event in recorded_events:
		if not event.has("wait_after"):
			var event_type = event.get("type", "click")
			event["wait_after"] = DEFAULT_DELAYS.get(event_type, 100)

	# Store pending data
	pending_baseline_path = baseline_path if baseline_path else ""
	pending_test_name = test_name

	# Copy screenshots from recording engine to pending array
	pending_screenshots.clear()
	for screenshot in recorded_screenshots:
		pending_screenshots.append(screenshot.duplicate())
	print("[UITestRunner] Prepared %d screenshots for editing" % pending_screenshots.size())

	# Auto-save the test
	var saved_path = _save_test(test_name, pending_baseline_path if not pending_baseline_path.is_empty() else null)
	if saved_path:
		print("[UITestRunner] Test auto-saved: ", test_name)

	# Get the filename for running
	var test_filename = test_name.to_snake_case().replace(" ", "_")

	# Open Test Editor dialog (run the saved test in step mode)
	# Clear auto-play steps from any previous test run to ensure fresh recording pauses at step 1
	_auto_play_steps.clear()
	_executor.set_step_mode(true)

	# Skip setup delays - environment was already set up during recording
	# Note: Don't emit ui_test_runner_test_starting here - it would reset board state
	# and cause coordinate drift. Recording already starts with a reset (line 1741).
	_run_test_from_file(test_filename, true)

# ============================================================================
# SCREENSHOT VALIDATION
# ============================================================================

# Comparison settings delegated to ScreenshotValidator
# Access via: ScreenshotValidator.compare_mode, ScreenshotValidator.compare_tolerance, etc.

func validate_screenshot(baseline_path: String, region: Rect2) -> bool:
	# Hide UI elements before capturing
	var cursor_was_visible = virtual_cursor.visible
	var hud_was_visible = _test_editor_hud.visible if _test_editor_hud else false
	virtual_cursor.visible = false
	if recording_indicator:
		recording_indicator.visible = false
	if _test_editor_hud:
		_test_editor_hud.visible = false

	# Wait for UI to settle and elements to disappear
	await get_tree().process_frame
	await get_tree().process_frame

	# Debug: print capture info
	var viewport_size = get_viewport().get_visible_rect().size
	print("[UITestRunner] Validation - Viewport: ", viewport_size, " Region: ", region)

	# Capture current region
	var image = get_viewport().get_texture().get_image()
	print("[UITestRunner] Captured image size: ", image.get_size())
	var current = image.get_region(region)
	print("[UITestRunner] Cropped region size: ", current.get_size())

	# Restore UI visibility
	virtual_cursor.visible = cursor_was_visible
	if _test_editor_hud:
		_test_editor_hud.visible = hud_was_visible

	# Load baseline
	var baseline = Image.load_from_file(ProjectSettings.globalize_path(baseline_path))
	if not baseline:
		push_error("[UITestRunner] Could not load baseline: " + baseline_path)
		return false
	print("[UITestRunner] Baseline: %s size=%s" % [baseline_path.get_file(), baseline.get_size()])
	print("[UITestRunner] Current cropped size=%s, Baseline size=%s" % [current.get_size(), baseline.get_size()])

	# Use ScreenshotValidator for comparison
	var result = ScreenshotValidator.compare_images(current, baseline)
	print("[UITestRunner] Comparison: %s" % result.message)

	if not result.passed:
		_save_debug_screenshot(current, baseline_path)

	return result.passed

func _save_debug_screenshot(current: Image, baseline_path: String):
	var debug_path = ScreenshotValidator.save_debug_screenshot(current, baseline_path, _current_run_id)

	# Store paths for later viewing (user can click "View Diff" in results)
	last_baseline_path = baseline_path
	last_actual_path = debug_path
	# Note: Comparison viewer is no longer auto-shown - user clicks "View Diff" in results

func set_compare_mode(mode: CompareMode):
	ScreenshotValidator.set_compare_mode(mode)

func set_tolerant_mode(tolerance: float = 0.02, color_threshold: int = 5):
	ScreenshotValidator.set_tolerant_mode(tolerance, color_threshold)

# ============================================================================
# CONFIG TAB CALLBACKS
# ============================================================================

func _get_speed_index(speed: Speed) -> int:
	# Map Speed enum to dropdown index
	match speed:
		Speed.INSTANT: return 0
		Speed.FAST: return 1
		Speed.NORMAL: return 2
		Speed.SLOW: return 3
		Speed.STEP: return 4
	return 2  # Default to NORMAL

func _on_speed_selected(index: int):
	var speeds = [Speed.INSTANT, Speed.FAST, Speed.NORMAL, Speed.SLOW, Speed.STEP]
	if index >= 0 and index < speeds.size():
		set_speed(speeds[index])

func _on_compare_mode_selected(index: int):
	ScreenshotValidator.compare_mode = index as CompareMode
	print("[UITestRunner] Compare mode: ", CompareMode.keys()[ScreenshotValidator.compare_mode])
	_update_tolerance_visibility()
	ScreenshotValidator.save_config()

func _on_pixel_tolerance_changed(value: float):
	ScreenshotValidator.compare_tolerance = value / 100.0
	_update_pixel_tolerance_label()
	ScreenshotValidator.save_config()

func _on_color_threshold_changed(value: float):
	ScreenshotValidator.compare_color_threshold = int(value)
	_update_color_threshold_label()
	ScreenshotValidator.save_config()

func _update_tolerance_visibility():
	if not test_selector_panel:
		return
	var tolerance_settings = test_selector_panel.get_node_or_null("VBoxContainer/TabContainer/Config/VBoxContainer/ToleranceSettings")
	if not tolerance_settings:
		# Try alternate path (directly under compare section)
		var config_tab = test_selector_panel.get_node_or_null("VBoxContainer/TabContainer/Config")
		if config_tab:
			for child in config_tab.get_children():
				var settings = child.get_node_or_null("ToleranceSettings")
				if settings:
					tolerance_settings = settings
					break
	if tolerance_settings:
		tolerance_settings.visible = (ScreenshotValidator.compare_mode == CompareMode.TOLERANT)

func _update_pixel_tolerance_label():
	if not test_selector_panel:
		return
	var label = _find_node_recursive(test_selector_panel, "PixelToleranceValue")
	if label:
		label.text = "%.1f%%" % (ScreenshotValidator.compare_tolerance * 100)

func _update_color_threshold_label():
	if not test_selector_panel:
		return
	var label = _find_node_recursive(test_selector_panel, "ColorThresholdValue")
	if label:
		label.text = "%d" % ScreenshotValidator.compare_color_threshold

func _find_node_recursive(node: Node, node_name: String) -> Node:
	return Utils.find_node_recursive(node, node_name)

# ============================================================================
# COMPARISON VIEWER (delegated to ComparisonViewer)
# ============================================================================

func _show_comparison_viewer():
	print("[UITestRunner] Showing comparison - Baseline: %s" % last_baseline_path)
	print("[UITestRunner] Showing comparison - Actual: %s" % last_actual_path)
	_comparison_viewer.show_comparison(last_baseline_path, last_actual_path)

func _close_comparison_viewer():
	_comparison_viewer.close()

func _comparison_input(event: InputEvent):
	if _comparison_viewer.is_visible():
		if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
			_close_comparison_viewer()

# ============================================================================
# TEST WARNING OVERLAY
# ============================================================================

func _show_test_warning_overlay() -> void:
	print("[UITestRunner] Showing warning overlay (delay: %dms)" % ScreenshotValidator.startup_delay)
	# Create overlay if it doesn't exist - use CanvasLayer to ensure it's on top of everything
	if not _test_warning_overlay:
		var canvas_layer = CanvasLayer.new()
		canvas_layer.layer = 100  # High layer to be on top of everything
		canvas_layer.name = "TestWarningLayer"
		get_tree().root.add_child(canvas_layer)

		_test_warning_overlay = ColorRect.new()
		_test_warning_overlay.color = Color(0, 0, 0, 0.85)
		_test_warning_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
		_test_warning_overlay.mouse_filter = Control.MOUSE_FILTER_STOP

		# Container for centered content
		var vbox = VBoxContainer.new()
		vbox.set_anchors_preset(Control.PRESET_FULL_RECT)
		vbox.alignment = BoxContainer.ALIGNMENT_CENTER
		_test_warning_overlay.add_child(vbox)

		# Main message label
		var label = Label.new()
		label.text = "Starting Test...\nDo not move the mouse"
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		label.add_theme_font_size_override("font_size", 32)
		label.add_theme_color_override("font_color", Color(1, 1, 1))
		vbox.add_child(label)

		# Countdown label
		_test_warning_countdown_label = Label.new()
		_test_warning_countdown_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_test_warning_countdown_label.add_theme_font_size_override("font_size", 48)
		_test_warning_countdown_label.add_theme_color_override("font_color", Color(1, 0.8, 0.2))
		vbox.add_child(_test_warning_countdown_label)

		# Create countdown timer
		_test_warning_countdown_timer = Timer.new()
		_test_warning_countdown_timer.wait_time = 1.0
		_test_warning_countdown_timer.timeout.connect(_on_countdown_tick)
		_test_warning_overlay.add_child(_test_warning_countdown_timer)

		canvas_layer.add_child(_test_warning_overlay)

	# Start countdown
	_test_warning_countdown_remaining = ceili(ScreenshotValidator.startup_delay / 1000.0)
	_update_countdown_label()
	_test_warning_countdown_timer.start()
	_test_warning_overlay.visible = true
	_test_warning_active = true
	_test_warning_cancelled = false

func _on_countdown_tick() -> void:
	_test_warning_countdown_remaining -= 1
	if _test_warning_countdown_remaining <= 0:
		_test_warning_countdown_timer.stop()
	else:
		_update_countdown_label()

func _update_countdown_label() -> void:
	if _test_warning_countdown_label:
		_test_warning_countdown_label.text = "%d" % _test_warning_countdown_remaining

func _hide_test_warning_overlay() -> void:
	_test_warning_active = false
	if _test_warning_countdown_timer:
		_test_warning_countdown_timer.stop()
	if _test_warning_overlay:
		_test_warning_overlay.visible = false

# Waits for startup delay, checking for ESC cancellation. Returns true if cancelled.
func _wait_for_startup_delay() -> bool:
	var delay_seconds = ScreenshotValidator.startup_delay / 1000.0
	var elapsed = 0.0
	var check_interval = 0.05  # Check every 50ms for responsiveness
	while elapsed < delay_seconds:
		await get_tree().create_timer(check_interval).timeout
		elapsed += check_interval
		if _test_warning_cancelled:
			_hide_test_warning_overlay()
			return true
	return false

# Shows warning overlay, waits for startup delay, handles cancellation.
# Returns true if cancelled (caller should return early).
func _show_startup_warning_and_wait() -> bool:
	# Skip warning in auto-run mode
	if _auto_run_mode:
		_test_session_active = true
		return false

	_test_session_active = true
	_show_test_warning_overlay()
	if await _wait_for_startup_delay():
		# Cancelled - cleanup and return to test manager
		_test_session_active = false
		_open_test_selector()
		return true
	_hide_test_warning_overlay()
	return false

# Runs a batch of tests with startup warning, environment setup, and result tracking.
# Handles cancellation, emits signals, and shows results panel when complete.
func _run_batch_tests(tests: Array) -> void:
	if await _show_startup_warning_and_wait():
		return
	_warn_missing_handlers()
	ui_test_runner_setup_environment.emit()
	await get_tree().create_timer(0.5).timeout

	is_batch_running = true
	_batch_cancelled = false
	batch_results.clear()
	_start_test_run()

	for test_name in tests:
		if _batch_cancelled:
			print("[UITestRunner] Batch cancelled - stopping remaining tests")
			break

		print("[UITestRunner] --- Running: %s ---" % test_name)
		ui_test_runner_test_starting.emit(test_name, _get_test_setup_config(test_name))
		await get_tree().create_timer(0.3).timeout

		var result = await _run_test_and_get_result(test_name)
		batch_results.append(result)
		ui_test_runner_test_ended.emit(test_name, result.get("passed", false))

		if _batch_cancelled:
			print("[UITestRunner] Batch cancelled after test")
			break

		await get_tree().create_timer(0.3).timeout

	is_batch_running = false
	_end_test_run(batch_results)
	ui_test_runner_run_completed.emit()
	_show_results_panel()
